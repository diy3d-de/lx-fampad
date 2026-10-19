// SyncController: wann abgeglichen wird (Start, Änderungen entprellt, WebSocket-Hinweis, Zeitgeber, Vordergrund), genau ein Abgleich
// zugleich, Backoff bei Fehlern, 401 (kein Wiederholen), 426 (Update-Seite). Mit Fake-Zeit (pump) und Fake-Server.
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/lists/list_repository.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/features/update/update_service.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

class _FesterZufall implements Random {
  @override
  double nextDouble() => 0.5; // Jitter-Faktor genau 1.0
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

Future<void> ruhe(WidgetTester tester, [Duration dauer = const Duration(milliseconds: 50)]) async {
  await tester.pump(dauer);
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  late TestUmgebung env;
  late ProviderContainer c;
  late SyncController sync;

  /// Wie testWidgets, beendet aber am Ende den Sync-Dienst (sonst blieben Zeitgeber stehen, bevor die Aufräumhandler laufen).
  void lauf(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      await body(tester);
      sync.stoppen();
      await tester.pump();
      c.dispose();
    });
  }

  Future<void> start(WidgetTester tester, {bool offline = false}) async {
    env = await angemeldeteUmgebung();
    env.sync.offline = offline;
    env.sockets.autoBereit = true;
    c = ProviderContainer(overrides: [...env.overrides, syncZufallProvider.overrideWithValue(_FesterZufall())]);
    sync = c.read(syncProvider.notifier);
    // GET /me für die Geräte-ID wird nicht gebraucht: sie steht im Token-Speicher
    sync.starten();
    await ruhe(tester);
  }

  /// Anzahl der Sync-Aufrufe beim Server (auch fehlgeschlagene).
  int anfragen() => env.server.anfragen('POST /sync').length;

  lauf('Start: sofort ein Abgleich, danach "synchron"; der WebSocket verbindet sich', (tester) async {
    await start(tester);
    expect(anfragen(), 1);
    expect(c.read(syncProvider).status, SyncStatus.synchron);
    expect(c.read(syncProvider).letzterAbgleich, isNotNull);
    expect(c.read(syncProvider).live, isTrue);
    expect(env.sockets.sockets, hasLength(1));
  });

  lauf('mehrere lokale Änderungen innerhalb von 2 s ergeben genau einen Abgleich (entprellt), der UI-Zähler zeigt die offenen', (tester) async {
    await start(tester);
    final repo = c.read(listenRepositoryProvider);
    final l = await repo.listeAnlegen(name: 'Einkauf');
    await repo.eintragAnlegen(l, 'Milch');
    await repo.eintragAnlegen(l, 'Brot');
    await ruhe(tester, const Duration(milliseconds: 500));
    expect(c.read(syncProvider).offeneAenderungen, 3);
    expect(anfragen(), 1, reason: 'noch nicht gesendet');
    await ruhe(tester, const Duration(milliseconds: 1300)); // 1,8 s nach der letzten Änderung
    expect(anfragen(), 1);
    await ruhe(tester, const Duration(milliseconds: 500));
    expect(anfragen(), 2);
    expect((env.sync.anfragen.last['ops'] as List), hasLength(3));
    expect(c.read(syncProvider).offeneAenderungen, 0);
    expect(c.read(syncProvider).status, SyncStatus.synchron);
  });

  lauf('die Oberfläche wartet nie: lokale Änderungen sind sofort da, auch wenn der Server hängt', (tester) async {
    await start(tester);
    final haengt = Completer<void>();
    env.server.on('POST /sync', (req) async {
      await haengt.future;
      return jsonAntwort(env.sync.verarbeiten(req.json));
    });
    final repo = c.read(listenRepositoryProvider);
    final l = await repo.listeAnlegen(name: 'Einkauf');
    final liste = await env.db.select(env.db.listen).get();
    expect(liste.single.id, l);
    await ruhe(tester, const Duration(seconds: 3));
    expect(c.read(syncProvider).status, SyncStatus.laeuft);
    // weitere Änderung während des Hängens: sofort sichtbar
    await repo.eintragAnlegen(l, 'Milch');
    expect((await env.db.select(env.db.listenEintraege).get()).single.inhalt, 'Milch');
    haengt.complete();
    await ruhe(tester, const Duration(seconds: 3));
    expect(c.read(syncProvider).status, SyncStatus.synchron);
    expect(c.read(syncProvider).offeneAenderungen, 0);
  });

  lauf('genau ein Abgleich zugleich; ein Auslöser währenddessen ergibt genau einen weiteren Lauf', (tester) async {
    await start(tester);
    var offen = 0;
    var gleichzeitig = 0;
    var hoechstens = 0;
    final tor = Completer<void>();
    env.server.on('POST /sync', (req) async {
      offen++;
      gleichzeitig++;
      hoechstens = max(hoechstens, gleichzeitig);
      if (offen == 1) await tor.future;
      gleichzeitig--;
      return jsonAntwort(env.sync.verarbeiten(req.json));
    });
    unawaited(sync.synchronisieren(manuell: true));
    await ruhe(tester);
    unawaited(sync.synchronisieren(manuell: true));
    unawaited(sync.synchronisieren(manuell: true));
    unawaited(sync.synchronisieren());
    await ruhe(tester);
    expect(offen, 1);
    tor.complete();
    await ruhe(tester, const Duration(seconds: 1));
    expect(offen, 2, reason: 'die drei Auslöser ergeben zusammen einen weiteren Lauf');
    expect(hoechstens, 1);
  });

  lauf('Backoff: 2 s, 4 s, 8 s ...; Auslöser während des Backoffs werden ignoriert, Antippen geht sofort, Erfolg setzt zurück', (tester) async {
    await start(tester, offline: true);
    expect(c.read(syncProvider).status, SyncStatus.offline);
    final start1 = anfragen();
    expect(start1, 1);

    await ruhe(tester, const Duration(milliseconds: 1900));
    expect(anfragen(), 1);
    await ruhe(tester, const Duration(milliseconds: 200)); // t = 2 s
    expect(anfragen(), 2);
    await ruhe(tester, const Duration(milliseconds: 3800));
    expect(anfragen(), 2, reason: 'zweiter Abstand: 4 s');
    // weitere Auslöser im Backoff laufen ins Leere
    unawaited(sync.synchronisieren());
    sync.lokaleAenderung();
    await ruhe(tester, const Duration(milliseconds: 2500));
    expect(anfragen(), 3, reason: 'der geplante Versuch nach 4 s');
    // Antippen: sofort
    unawaited(sync.synchronisieren(manuell: true));
    await ruhe(tester);
    expect(anfragen(), 4);
    // Server wieder da: der nächste Versuch klappt, der Backoff ist danach beendet
    env.sync.offline = false;
    await ruhe(tester, const Duration(seconds: 17));
    expect(c.read(syncProvider).status, SyncStatus.synchron);
    final nachErfolg = anfragen();
    await ruhe(tester, const Duration(seconds: 30));
    expect(anfragen(), nachErfolg, reason: 'kein weiterer Backoff-Versuch nach dem Erfolg');
  });

  lauf('429 mit Retry-After: nicht früher als die Wartezeit des Servers', (tester) async {
    env = await angemeldeteUmgebung();
    env.sync.fehlerQueue.add((429, 'rate_limited'));
    c = ProviderContainer(overrides: [...env.overrides, syncZufallProvider.overrideWithValue(_FesterZufall())]);
    sync = c.read(syncProvider.notifier)..starten();
    await ruhe(tester);
    expect(c.read(syncProvider).status, SyncStatus.fehler);
    await ruhe(tester, const Duration(seconds: 6));
    expect(anfragen(), 1, reason: 'Retry-After: 7 s schlägt den Backoff von 2 s');
    await ruhe(tester, const Duration(seconds: 2));
    expect(anfragen(), 2);
    expect(c.read(syncProvider).status, SyncStatus.synchron);
  });

  lauf('alle 3 Minuten wird abgeglichen', (tester) async {
    await start(tester);
    await ruhe(tester, const Duration(minutes: 3));
    expect(anfragen(), 2);
    await ruhe(tester, const Duration(minutes: 3));
    expect(anfragen(), 3);
  });

  lauf('WebSocket-Hinweis "rev N": neuer als bekannt -> Abgleich; nicht neuer -> nichts', (tester) async {
    await start(tester);
    final vorher = anfragen();
    env.sync.andereAendert('list', '11111111-1111-4111-8111-111111111111', {'name': 'Von drüben'});
    env.sockets.letzter.vomServer({'type': 'rev', 'rev': env.sync.rev});
    await ruhe(tester);
    expect(anfragen(), vorher + 1);
    expect((await env.db.select(env.db.listen).get()).single.name, 'Von drüben');
    env.sockets.letzter.vomServer({'type': 'rev', 'rev': env.sync.rev});
    await ruhe(tester);
    expect(anfragen(), vorher + 1, reason: 'Stand schon bekannt');
  });

  lauf('Reconnect: bricht der Socket ab, verbindet er sich wieder und der Status folgt (live)', (tester) async {
    await start(tester);
    expect(c.read(syncProvider).live, isTrue);
    env.sockets.letzter.serverSchliesst(1006);
    await ruhe(tester);
    expect(c.read(syncProvider).live, isFalse);
    await ruhe(tester, const Duration(seconds: 3));
    expect(env.sockets.sockets, hasLength(2));
    expect(c.read(syncProvider).live, isTrue);
  });

  lauf('401: keine Sync-Schleife (der Auth-Zustand übernimmt), kein Backoff, Ausgang bleibt', (tester) async {
    env = await angemeldeteUmgebung();
    env.server.on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
    env.sync.fehlerQueue.add((401, 'unauthenticated'));
    c = ProviderContainer(overrides: [...env.overrides, syncZufallProvider.overrideWithValue(_FesterZufall())]);
    final repo = c.read(listenRepositoryProvider);
    await repo.listeAnlegen(name: 'Einkauf');
    sync = c.read(syncProvider.notifier)..starten();
    await ruhe(tester);
    expect(c.read(authProvider).status, AuthStatus.abgemeldet, reason: 'der ApiClient meldet den Sitzungsverlust, der Auth-Zustand übernimmt');
    expect(c.read(syncProvider).status, SyncStatus.getrennt);
    final n = anfragen();
    await ruhe(tester, const Duration(minutes: 20));
    expect(anfragen(), n, reason: 'kein Wiederholen ohne Sitzung');
    expect(c.read(syncProvider).offeneAenderungen, 1);
  });

  lauf('426: Pflicht-Update-Seite, kein weiterer Versuch', (tester) async {
    env = await angemeldeteUmgebung();
    env.sync.fehlerQueue.add((426, 'update_required'));
    c = ProviderContainer(overrides: [...env.overrides, syncZufallProvider.overrideWithValue(_FesterZufall())]);
    sync = c.read(syncProvider.notifier)..starten();
    await ruhe(tester);
    expect(c.read(syncProvider).status, SyncStatus.updateNoetig);
    expect(c.read(updateProvider).pflicht, isTrue);
    final n = anfragen();
    await ruhe(tester, const Duration(minutes: 10));
    expect(anfragen(), n);
  });

  lauf('Vordergrund: im Hintergrund kein Socket und keine Zeitgeber, bei der Rückkehr sofort ein Abgleich', (tester) async {
    await start(tester);
    final n = anfragen();
    sync.vordergrund(false);
    await ruhe(tester);
    expect(c.read(syncProvider).live, isFalse);
    expect(env.sockets.letzter.geschlossen, isTrue);
    await ruhe(tester, const Duration(minutes: 10));
    expect(anfragen(), n, reason: 'im Hintergrund kein Zeitgeber');
    sync.vordergrund(true);
    await ruhe(tester);
    expect(anfragen(), n + 1);
    expect(env.sockets.sockets, hasLength(2));
    expect(c.read(syncProvider).live, isTrue);
  });

  lauf('stoppen: keine Abgleiche mehr, kein Socket', (tester) async {
    await start(tester);
    sync.stoppen();
    final n = anfragen();
    await ruhe(tester, const Duration(minutes: 10));
    expect(anfragen(), n);
    expect(c.read(syncProvider).status, SyncStatus.getrennt);
    expect(env.sockets.letzter.geschlossen, isTrue);
    await sync.synchronisieren(manuell: true);
    expect(anfragen(), n);
  });

  testWidgets('Abmelden während eines Abgleichs: der Wiper hält den Sync an, die späte Antwort schreibt nichts in die geleerte Datenbank', (tester) async {
    env = await angemeldeteUmgebung();
    env.wiperEcht = true;
    c = ProviderContainer(overrides: [...env.overrides, syncZufallProvider.overrideWithValue(_FesterZufall())]);
    sync = c.read(syncProvider.notifier);
    env.sync.andereAendert('list', '11111111-1111-4111-8111-111111111111', {'name': 'Einkauf'});
    final tor = Completer<void>();
    env.server.on('POST /sync', (req) async {
      final antwort = env.sync.verarbeiten(req.json);
      await tor.future;
      return jsonAntwort(antwort);
    });
    sync.starten();
    await ruhe(tester);
    expect(c.read(syncProvider).status, SyncStatus.laeuft);
    await c.read(localDataWiperProvider)(); // wie Abmelden
    tor.complete();
    await ruhe(tester, const Duration(seconds: 1));
    expect(await env.db.select(env.db.listen).get(), isEmpty, reason: 'die Antwort kam nach dem Löschen und wurde verworfen');
    expect(await env.db.select(env.db.syncMeta).get(), isEmpty);
    expect(sync.aktiv, isFalse);
    c.dispose();
  });

  lauf('Hinweise (z. B. anderswo gelöscht) erscheinen im Zustand und lassen sich schließen; höchstens 5', (tester) async {
    await start(tester);
    final repo = c.read(listenRepositoryProvider);
    final l = await repo.listeAnlegen(name: 'Einkauf');
    final ids = [for (var i = 0; i < 7; i++) await repo.eintragAnlegen(l, 'E$i')];
    await ruhe(tester, const Duration(seconds: 3));
    for (final id in ids) {
      env.sync.andereLoescht('list_item', id);
    }
    for (final id in ids) {
      await repo.eintragText(id, 'geändert $id');
    }
    await sync.synchronisieren(manuell: true);
    await ruhe(tester);
    final hinweise = c.read(syncProvider).hinweise;
    expect(hinweise, hasLength(5));
    expect(hinweise.first.text, contains('gelöscht'));
    sync.hinweisSchliessen(hinweise.first.id);
    expect(c.read(syncProvider).hinweise, hasLength(4));
  });
}
