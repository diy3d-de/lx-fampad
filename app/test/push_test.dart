// Push (Android): Zustand und Ablauf mit einem Fake-Verteiler (ntfy-App) und dem Fake-Server, Wecker -> Abgleich -> neueEreignisse,
// Hintergrund-Start, Abmelden. Die Oberfläche steht in push_screen_test.dart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/database_provider.dart';
import 'package:lx_fampad/data/push/push_hintergrund.dart';
import 'package:lx_fampad/data/push/push_plattform.dart';
import 'package:lx_fampad/data/push/push_state.dart';
import 'package:lx_fampad/data/push/push_wecker.dart';
import 'package:lx_fampad/data/sync_state.dart';

import 'support/fake_push.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

class _Ereignisse implements EreignisBenachrichtiger {
  final List<(int, int)> aufrufe = [];
  Object? wirft;
  @override
  Future<void> neueEreignisse(int rev, {required int vorher}) async {
    aufrufe.add((rev, vorher));
    if (wirft != null) throw wirft!;
  }
}

/// Server-Zustand von /me/push (angemeldet ja/nein) auf dem Fake-Server.
class _PushServer {
  bool registriert = false;
  bool aktiv = true;
  bool verfuegbar = true;
  int? putFehler;
  String? putCode;
  int testStatus = 200;
  String testCode = 'x';
  final List<String> endpunkte = [];

  void registrieren(FakeServer s) {
    s.on('GET /me/push', (_) => jsonAntwort({'available': verfuegbar, 'server': 'https://ntfy.familie.lx-labs.dev', 'registered': registriert, 'active': registriert && aktiv, 'lastOkAt': null, 'lastErrorAt': null}));
    s.on('PUT /me/push', (req) {
      if (putFehler != null) return fehler(putFehler!, putCode ?? 'invalid_endpoint');
      endpunkte.add(req.json['endpoint'] as String);
      registriert = true;
      return jsonAntwort({'ok': true});
    });
    s.on('DELETE /me/push', (_) {
      registriert = false;
      return jsonAntwort({'ok': true});
    });
    s.on('POST /me/push/test', (_) => testStatus == 200 ? jsonAntwort({'result': 'sent'}) : fehler(testStatus, testCode));
    s.on('POST /auth/logout', (_) => jsonAntwort({'ok': true}));
  }
}

Future<void> ruhe([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  late TestUmgebung env;
  late FakePush fake;
  late _PushServer ps;
  late _Ereignisse ereignisse;
  late ProviderContainer c;

  Future<void> start({bool plattformOk = true}) async {
    env = await angemeldeteUmgebung();
    ps = _PushServer()..registrieren(env.server);
    fake = FakePush()..unterstuetzt = plattformOk;
    ereignisse = _Ereignisse();
    c = ProviderContainer(
      overrides: [
        ...env.overrides,
        pushPlattformProvider.overrideWithValue(fake),
        pushTestWartezeitProvider.overrideWithValue(const Duration(milliseconds: 150)),
        ereignisBenachrichtigerProvider.overrideWithValue(ereignisse),
        pushAbmeldenProvider.overrideWith((ref) => ({required bool serverLoeschen}) => ref.read(pushProvider.notifier).beimAbmelden(serverLoeschen: serverLoeschen)),
      ],
    );
    addTearDown(() {
      c.read(syncProvider.notifier).stoppen(zustandAendern: false);
      c.dispose();
    });
  }

  PushController push() => c.read(pushProvider.notifier);
  PushZustand z() => c.read(pushProvider);
  Future<String?> meta() => c.read(appDatabaseProvider).metaLesen(kPushAn);

  group('Einschalten und Ausschalten', () {
    test('ohne installierte ntfy-App: Hinweis, nichts wird registriert oder gemeldet', () async {
      await start();
      fake.installiert = [];
      await push().einschalten();
      expect(z().verteilerFehlt, isTrue);
      expect(z().gewuenscht, isFalse);
      expect(fake.registriert, 0);
      expect(env.server.anfragen('PUT /me/push'), isEmpty);
      expect(await meta(), isNull);
    });

    test('ein Verteiler: wird genommen, registriert, Endpunkt geht an den Server, Zustand "angemeldet"', () async {
      await start();
      await push().einschalten();
      await ruhe();
      expect(fake.registriert, 1);
      expect(fake.gespeichert, 'io.heckel.ntfy');
      expect(ps.endpunkte, [fixEndpunkt]);
      expect(z().gewuenscht, isTrue);
      expect(z().angemeldet, isTrue);
      expect(z().verteiler, 'io.heckel.ntfy');
      expect(z().fehler, isNull);
      expect(await meta(), '1');
    });

    test('mehrere Verteiler: die Person wählt, danach wird registriert', () async {
      await start();
      fake.installiert = ['io.heckel.ntfy', 'org.andere.verteiler'];
      await push().einschalten();
      expect(z().auswahl, hasLength(2));
      expect(fake.registriert, 0);
      await push().verteilerWaehlen('org.andere.verteiler');
      await ruhe();
      expect(fake.gespeichert, 'org.andere.verteiler');
      expect(fake.registriert, 1);
      expect(z().auswahl, isEmpty);
      expect(z().angemeldet, isTrue);
    });

    test('der Server lehnt den Endpunkt ab (falscher ntfy-Server): verständliche Meldung, nicht angemeldet', () async {
      await start();
      ps
        ..putFehler = 400
        ..putCode = 'invalid_endpoint';
      await push().einschalten();
      await ruhe();
      expect(z().angemeldet, isFalse);
      expect(z().fehler, contains('https://ntfy.familie.lx-labs.dev'));
      expect(z().fehler, isNot(contains('Meldung des Servers')));
    });

    test('Push auf dem Server nicht eingerichtet (503 push_unavailable): eigene Meldung statt "ausgelastet"', () async {
      await start();
      ps
        ..putFehler = 503
        ..putCode = 'push_unavailable';
      await push().einschalten();
      await ruhe();
      expect(z().fehler, contains('noch nicht eingerichtet'));
    });

    test('Fehler beim Registrieren: Meldung, Schalter bleibt bedienbar', () async {
      await start();
      fake.registrierenFehler = StateError('kaputt');
      await push().einschalten();
      expect(z().fehler, isNotNull);
      expect(z().beschaeftigt, isFalse);
    });

    test('Registrierung scheitert im Verteiler (Rückruf): Meldung', () async {
      await start();
      fake.endpunktMelden = false;
      await push().einschalten();
      fake.rueckrufe!.beiFehler('network');
      expect(z().fehler, contains('Netz'));
      fake.rueckrufe!.beiFehler('actionRequired');
      expect(z().fehler, contains('ntfy-App'));
    });

    test('Ausschalten: Endpunkt beim Server gelöscht, beim Verteiler abgemeldet, Schalter aus', () async {
      await start();
      await push().einschalten();
      await ruhe();
      await push().ausschalten();
      expect(env.server.anfragen('DELETE /me/push'), hasLength(1));
      expect(fake.abgemeldet, 1);
      expect(z().gewuenscht, isFalse);
      expect(z().angemeldet, isFalse);
      expect(await meta(), '0');
    });

    test('Ausschalten ohne Netz: lokal aus, Hinweis auf den Server', () async {
      await start();
      await push().einschalten();
      await ruhe();
      env.server.on('DELETE /me/push', (_) => throw Exception('offline'));
      await push().ausschalten();
      expect(z().gewuenscht, isFalse);
      expect(fake.abgemeldet, 1);
    });

    test('Der Verteiler beendet die Anmeldung (ntfy-App deinstalliert): Schalter aus mit Hinweis, Server-Endpunkt gelöscht', () async {
      await start();
      await push().einschalten();
      await ruhe();
      fake.rueckrufe!.beiAbgemeldet();
      await ruhe();
      expect(z().gewuenscht, isFalse);
      expect(z().fehler, contains('Schalte Benachrichtigungen neu ein'));
      expect(ps.registriert, isFalse);
    });

    test('Plattform ohne Push (Web): Einschalten tut nichts, keine Anfrage', () async {
      await start(plattformOk: false);
      await push().starten();
      await push().einschalten();
      expect(z().unterstuetzt, isFalse);
      expect(fake.initialisiert, 0);
      expect(env.server.anfragen('GET /me/push'), isEmpty);
      expect(env.server.anfragen('PUT /me/push'), isEmpty);
    });
  });

  group('Start', () {
    test('eingeschaltet: bei jedem Start erneut beim Verteiler registrieren (neuer Endpunkt ersetzt den alten)', () async {
      await start();
      await push().einschalten();
      await ruhe();
      // "Neustart": neuer Container auf derselben Datenbank
      final fake2 = FakePush()..gespeichert = 'io.heckel.ntfy'..endpunkt = 'https://ntfy.familie.lx-labs.dev/upNeuerEndpunkt1?up=1';
      final c2 = ProviderContainer(overrides: [...env.overrides, pushPlattformProvider.overrideWithValue(fake2), pushAbmeldenProvider.overrideWithValue(({required bool serverLoeschen}) async {})]);
      addTearDown(c2.dispose);
      await c2.read(pushProvider.notifier).starten();
      await ruhe();
      expect(fake2.initialisiert, 1);
      expect(fake2.registriert, 1);
      expect(ps.endpunkte.last, 'https://ntfy.familie.lx-labs.dev/upNeuerEndpunkt1?up=1');
      expect(c2.read(pushProvider).gewuenscht, isTrue);
    });

    test('ausgeschaltet: Rückrufe werden eingehängt, aber nicht registriert', () async {
      await start();
      await push().starten();
      expect(fake.initialisiert, 1);
      expect(fake.registriert, 0);
      expect(z().geladen, isTrue);
      expect(z().gewuenscht, isFalse);
    });

    test('Server ohne Push: serverBereit=false', () async {
      await start();
      ps.verfuegbar = false;
      await push().starten();
      expect(z().serverBereit, isFalse);
    });

    test('ein zweiter Start hängt die Rückrufe nicht doppelt ein', () async {
      await start();
      await push().starten();
      await push().starten();
      expect(fake.initialisiert, 1);
    });
  });

  group('Test-Wecker', () {
    test('Server sendet, Wecker trifft ein: "angekommen"', () async {
      await start();
      await push().einschalten();
      await ruhe();
      final f = push().testen();
      await ruhe(20);
      expect(z().test, PushTest.laeuft);
      fake.wecker();
      await f;
      expect(z().test, PushTest.angekommen);
      expect(z().letzterWecker, isNotNull);
    });

    test('nichts trifft ein: "nicht angekommen" nach der Wartezeit', () async {
      await start();
      await push().einschalten();
      await ruhe();
      await push().testen();
      expect(z().test, PushTest.nichtAngekommen);
      expect(env.server.anfragen('POST /me/push/test'), hasLength(1));
    });

    test('Server lehnt ab (Push nicht angemeldet): Fehlertext aus der App, kein Servertext', () async {
      await start();
      ps
        ..testStatus = 409
        ..testCode = 'no_endpoint';
      await push().testen();
      expect(z().test, PushTest.serverFehler);
      expect(z().fehler, 'Für dieses Gerät ist Push noch nicht angemeldet.');
    });

    test('zu schnell hintereinander (429): Meldung "Zu viele Versuche"', () async {
      await start();
      ps
        ..testStatus = 429
        ..testCode = 'rate_limited';
      await push().testen();
      expect(z().fehler, contains('Zu viele Versuche'));
    });
  });

  group('Wecker', () {
    test('weckerAbgleichen: meldet neue Ereignisse nur, wenn der Stand steigt; ein Fehler der Meldung bricht nichts ab', () async {
      await start();
      final store = c.read(syncStoreProvider);
      await store.sinceRevSetzen(3);
      await weckerAbgleichen(store: store, abgleich: () async {}, ereignisse: ereignisse);
      expect(ereignisse.aufrufe, isEmpty);
      await weckerAbgleichen(store: store, abgleich: () => store.sinceRevSetzen(7), ereignisse: ereignisse);
      expect(ereignisse.aufrufe, [(7, 3)]);
      ereignisse.wirft = StateError('Plugin fehlt');
      await weckerAbgleichen(store: store, abgleich: () => store.sinceRevSetzen(9), ereignisse: ereignisse);
      expect(ereignisse.aufrufe.last, (9, 7));
    });

    test('Wecker bei laufender App: Abgleich beim Server (ohne den Inhalt zu lesen)', () async {
      await start();
      env.sockets.autoBereit = true;
      await push().einschalten();
      await ruhe();
      c.read(syncProvider.notifier).starten();
      await ruhe(100);
      final vorher = env.server.anfragen('POST /sync').length;
      fake.wecker();
      await ruhe(100);
      expect(env.server.anfragen('POST /sync').length, greaterThan(vorher));
      expect(z().letzterWecker, isNotNull);
    });
  });

  group('Abmelden', () {
    test('Abmelden löscht zuerst den Endpunkt beim Server (Sitzung gilt noch), dann die Sitzung, und meldet beim Verteiler ab', () async {
      await start();
      await c.read(authProvider.notifier).neuLaden();
      await push().einschalten();
      await ruhe();
      await c.read(authProvider.notifier).abmelden();
      final reihenfolge = env.server.log.map((r) => r.key).where((k) => k == 'DELETE /me/push' || k == 'POST /auth/logout').toList();
      expect(reihenfolge, ['DELETE /me/push', 'POST /auth/logout']);
      expect(fake.abgemeldet, greaterThanOrEqualTo(1));
      expect(z().gewuenscht, isFalse);
    });

    test('nur lokal abmelden: kein Aufruf beim Server, aber beim Verteiler abgemeldet', () async {
      await start();
      await c.read(authProvider.notifier).neuLaden();
      await push().einschalten();
      await ruhe();
      await c.read(authProvider.notifier).abmelden(nurLokal: true);
      expect(env.server.anfragen('DELETE /me/push'), isEmpty);
      expect(fake.abgemeldet, greaterThanOrEqualTo(1));
    });
  });

  group('Hintergrund-Start', () {
    test('Wecker: eigener Container gleicht ab, meldet neue Ereignisse und schließt danach', () async {
      await start();
      final bg = FakePush();
      final hint = _Ereignisse();
      var neu = 0;
      await pushHintergrundStarten(
        plattform: bg,
        containerFabrik: () {
          neu++;
          return ProviderContainer(overrides: env.overrides.where((o) => true).toList());
        },
        ereignisse: hint,
      );
      expect(bg.initialisiert, 1);
      // die Fake-Datenbank des Tests ist gemeinsam: der Server liefert Änderungen, sobald es welche gibt
      env.sync.rev = 4;
      bg.wecker();
      await ruhe(200);
      expect(neu, 1);
      expect(env.server.anfragen('POST /sync'), isNotEmpty);
      expect(hint.aufrufe.map((a) => a.$1), [4]);
    });

    test('neuer Endpunkt während die App geschlossen ist: wird dem Server gemeldet', () async {
      await start();
      final bg = FakePush();
      await pushHintergrundStarten(plattform: bg, containerFabrik: () => ProviderContainer(overrides: env.overrides));
      bg.rueckrufe!.beiEndpunkt(fixEndpunkt);
      await ruhe(100);
      expect(ps.endpunkte, [fixEndpunkt]);
    });

    test('Plattform ohne Push: nichts passiert', () async {
      await start();
      final bg = FakePush()..unterstuetzt = false;
      await pushHintergrundStarten(plattform: bg);
      expect(bg.initialisiert, 0);
    });

    test('Offline im Hintergrund: kein Absturz, nächster Start gleicht ab', () async {
      await start();
      env.sync.offline = true;
      final bg = FakePush();
      await pushHintergrundStarten(plattform: bg, containerFabrik: () => ProviderContainer(overrides: env.overrides), ereignisse: _Ereignisse());
      bg.wecker();
      await ruhe(100);
    });
  });

  group('Schnittstellen', () {
    test('PushStatusDto liest die Serverantwort tolerant', () {
      final s = PushStatusDto.fromJson({'available': true, 'registered': true, 'active': false, 'lastOkAt': '2026-10-19T08:00:00.000Z', 'extra': 1});
      expect(s.available && s.registered && !s.active, isTrue);
      expect(s.lastOkAt, isNotNull);
      final leer = PushStatusDto.fromJson(<String, dynamic>{});
      expect(leer.available, isFalse);
    });

    test('verteilerName zeigt die ntfy-App freundlich', () {
      expect(verteilerName('io.heckel.ntfy'), 'ntfy');
      expect(verteilerName('org.x.y'), 'org.x.y');
    });
  });
}
