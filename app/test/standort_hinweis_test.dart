// Hinweis "Name teilt seinen Standort": lokale Benachrichtigung ohne Standort, nur einmal je Freigabe, Einstellung, Vordergrund, Kurzabruf nach einem Wecker.
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/standort/standort_abruf.dart';
import 'package:lx_fampad/data/standort/standort_hinweis.dart';
import 'package:lx_fampad/data/sync/sync_socket.dart';

import 'support/fake_server.dart';
import 'support/fake_socket.dart';

const _ich = 'aaaaaaaa-0000-4000-8000-000000000001';
const _ben = 'bbbbbbbb-0000-4000-8000-000000000002';
const _cora = 'cccccccc-0000-4000-8000-000000000003';

class _Anzeige implements StandortAnzeigePort {
  bool erlaubt = true;
  int initialisiert = 0;
  final gezeigt = <({int id, String titel, String text, bool sperre, Duration? verfall})>[];
  final entfernt = <int>[];
  int alleEntfernt = 0;

  @override
  Future<bool> initialisieren() async {
    initialisiert++;
    return erlaubt;
  }

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, Duration? verfall}) async {
    gezeigt.add((id: id, titel: titel, text: text, sperre: sperrbildschirmTitel, verfall: verfall));
    return true;
  }

  @override
  Future<void> entfernen(int id) async => entfernt.add(id);

  @override
  Future<void> alleEntfernen() async => alleEntfernt++;
}

void main() {
  var jetzt = DateTime.utc(2026, 10, 20, 12);
  late AppDatabase db;
  late _Anzeige anzeige;
  late MemoryErinnerungSpeicher speicher;
  var vordergrund = false;
  String? ich = _ich;

  StandortBenachrichtiger benachrichtiger() => StandortBenachrichtiger(db: db, anzeige: anzeige, speicher: speicher, ich: () async => ich, istVordergrund: () => vordergrund, jetzt: () => jetzt);
  DateTime ende([Duration d = const Duration(hours: 1)]) => jetzt.add(d);

  setUp(() async {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    anzeige = _Anzeige();
    speicher = MemoryErinnerungSpeicher();
    jetzt = DateTime.utc(2026, 10, 20, 12);
    vordergrund = false;
    ich = _ich;
    await db.metaSchreiben(
      'members',
      jsonEncode([
        {'id': _ich, 'displayName': 'Anna', 'colorIndex': 0, 'role': 'admin', 'status': 'active'},
        {'id': _ben, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'},
      ]),
    );
  });
  tearDown(() => db.close());

  group('StandortBenachrichtiger', () {
    test('Hintergrund: "Standort geteilt" mit dem Namen aus der lokalen Mitgliederliste, eigener Kanal, privat auf dem Sperrbildschirm, verschwindet zum Ende der Freigabe', () async {
      final erg = await benachrichtiger().freigabe(von: _ben, shareId: 's1', endsAt: ende());
      expect(erg, HinweisErgebnis.system);
      final n = anzeige.gezeigt.single;
      expect(n.titel, 'Standort geteilt');
      expect(n.text, 'Ben teilt seinen Standort.');
      expect(n.sperre, isFalse);
      expect(n.verfall, const Duration(hours: 1));
      expect(n.id, standortBenachrichtigungsId(_ben));
    });

    test('Datenschutz: Text und Titel enthalten nur den Namen, nie Kennungen oder Zahlen', () async {
      await benachrichtiger().freigabe(von: _ben, shareId: 'geheime-share-id', endsAt: ende());
      final alles = jsonEncode(anzeige.gezeigt.map((g) => [g.titel, g.text]).toList());
      expect(alles, isNot(contains('geheime')));
      expect(alles, isNot(contains(_ben)));
      expect(RegExp(r'\d').hasMatch(alles), isFalse);
    });

    test('Titel auf dem Sperrbildschirm nur mit der Einstellung der Erinnerungen', () async {
      speicher.daten[kSperrbildschirmSchluessel] = 'ja';
      await benachrichtiger().freigabe(von: _ben, shareId: 's1', endsAt: ende());
      expect(anzeige.gezeigt.single.sperre, isTrue);
    });

    test('unbekannte Person: "Jemand"', () async {
      await benachrichtiger().freigabe(von: _cora, shareId: 's1', endsAt: ende());
      expect(anzeige.gezeigt.single.text, 'Jemand teilt seinen Standort.');
    });

    test('je Freigabe nur einmal (Nachreichung beim Wiederverbinden), eine neue Freigabe derselben Person meldet wieder und ersetzt die Anzeige', () async {
      final b = benachrichtiger();
      expect(await b.freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.system);
      expect(await b.freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.nichts);
      expect(await benachrichtiger().freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.nichts); // auch aus einem anderen Prozess (Buch in der Datenbank)
      jetzt = jetzt.add(kHinweisAbstand);
      expect(await b.freigabe(von: _ben, shareId: 's2', endsAt: ende()), HinweisErgebnis.system);
      expect(anzeige.gezeigt, hasLength(2));
      expect(anzeige.gezeigt.map((g) => g.id).toSet(), hasLength(1)); // gleiche Kennung: ersetzt statt zu stapeln
    });

    test('Abstand: eine andere Freigabe derselben Person löst innerhalb von 10 Minuten keinen weiteren Hinweis aus, eine andere Person schon; danach wieder', () async {
      final b = benachrichtiger();
      expect(await b.freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.system);
      jetzt = jetzt.add(const Duration(minutes: 5));
      expect(await b.freigabe(von: _ben, shareId: 's2', endsAt: ende(const Duration(hours: 2))), HinweisErgebnis.nichts);
      expect(await b.freigabe(von: _cora, shareId: 'c1', endsAt: ende(const Duration(hours: 2))), HinweisErgebnis.system);
      jetzt = jetzt.add(const Duration(minutes: 5, seconds: 1));
      expect(await b.freigabe(von: _ben, shareId: 's2', endsAt: ende(const Duration(hours: 2))), HinweisErgebnis.system); // die Freigabe läuft noch: jetzt kommt sie
      expect(anzeige.gezeigt, hasLength(3));
    });

    test('Kurzabruf: höchstens einmal je 30 Sekunden und Gerät (auch über Prozesse), der Zeitpunkt wird beim Start gebucht', () async {
      expect(await benachrichtiger().abrufErlaubt(), isTrue);
      expect(await benachrichtiger().abrufErlaubt(), isFalse); // anderer Prozess, gleiche Datenbank
      jetzt = jetzt.add(const Duration(seconds: 29));
      expect(await benachrichtiger().abrufErlaubt(), isFalse);
      jetzt = jetzt.add(const Duration(seconds: 2));
      expect(await benachrichtiger().abrufErlaubt(), isTrue);
    });

    test('Kanal wird beim Start angelegt (initialisieren), auch ohne dass je eine Freigabe kam', () async {
      await benachrichtiger().kanalAnlegen();
      expect(anzeige.initialisiert, 1);
      expect(anzeige.gezeigt, isEmpty);
    });

    test('Diagnose: jede Entscheidung über einen Hinweis wird mit Zeitpunkt und Code gemerkt (nie Name oder Kennung)', () async {
      final b = benachrichtiger();
      Future<String?> code() async => StandortDiagnoseEintrag.lesen(await db.metaLesen(kDiagHinweis))?.code;
      await b.freigabe(von: _ben, shareId: 's1', endsAt: ende());
      expect(await code(), 'gezeigt');
      await b.freigabe(von: _ben, shareId: 's1', endsAt: ende());
      expect(await code(), 'schon_gemeldet');
      await b.freigabe(von: _ben, shareId: 's2', endsAt: ende());
      expect(await code(), 'abstand');
      await b.freigabe(von: _cora, shareId: 'c1', endsAt: jetzt.subtract(const Duration(seconds: 1)));
      expect(await code(), 'abgelaufen');
      anzeige.erlaubt = false;
      await b.freigabe(von: _cora, shareId: 'c2', endsAt: ende());
      expect(await code(), 'keine_erlaubnis');
      speicher.daten[kStandortHinweisSchluessel] = 'aus';
      await b.freigabe(von: _cora, shareId: 'c3', endsAt: ende());
      expect(await code(), 'aus');
      final roh = await db.metaLesen(kDiagHinweis);
      expect(roh, isNot(contains(_ben)));
      expect(roh, isNot(contains('Ben')));
      for (final c in ['ok', 'freigaben', 'aus', 'gedrosselt', 'keine_verbindung', 'gezeigt', 'abstand', 'keine_erlaubnis', 'gestartet']) {
        expect(standortDiagnoseText(c), isNot(c), reason: c);
      }
    });

    test('Einstellung aus: nichts, auch nicht im Vordergrund; Standard ist an', () async {
      expect(await benachrichtiger().aktiv(), isTrue);
      speicher.daten[kStandortHinweisSchluessel] = 'aus';
      expect(await benachrichtiger().aktiv(), isFalse);
      expect(await benachrichtiger().freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.nichts);
      vordergrund = true;
      expect(await benachrichtiger().freigabe(von: _ben, shareId: 's2', endsAt: ende()), HinweisErgebnis.nichts);
      expect(anzeige.gezeigt, isEmpty);
    });

    test('Vordergrund: keine System-Benachrichtigung, die Oberfläche zeigt einen Hinweis (einmal)', () async {
      vordergrund = true;
      final b = benachrichtiger();
      expect(await b.freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.vordergrund);
      expect(await b.freigabe(von: _ben, shareId: 's1', endsAt: ende()), HinweisErgebnis.nichts);
      expect(anzeige.gezeigt, isEmpty);
    });

    test('eigene Freigabe, abgelaufene Freigabe, keine angemeldete Person und fehlende Erlaubnis melden nichts (ohne Erlaubnis wird nichts gebucht)', () async {
      final b = benachrichtiger();
      expect(await b.freigabe(von: _ich, shareId: 's1', endsAt: ende()), HinweisErgebnis.nichts);
      expect(await b.freigabe(von: _ben, shareId: 's2', endsAt: jetzt.subtract(const Duration(seconds: 1))), HinweisErgebnis.nichts);
      anzeige.erlaubt = false;
      expect(await b.freigabe(von: _ben, shareId: 's3', endsAt: ende()), HinweisErgebnis.nichts);
      anzeige.erlaubt = true;
      expect(await b.freigabe(von: _ben, shareId: 's3', endsAt: ende()), HinweisErgebnis.system); // nach Erteilen der Erlaubnis kommt es
      ich = null;
      expect(await b.freigabe(von: _ben, shareId: 's4', endsAt: ende()), HinweisErgebnis.nichts);
    });

    test('Ende der Freigabe und Öffnen der Seite entfernen die Benachrichtigung; die Kennungen liegen außerhalb der Chat-Kennungen', () async {
      final b = benachrichtiger();
      await b.beendet(_ben);
      await b.alleEntfernen();
      expect(anzeige.entfernt, [standortBenachrichtigungsId(_ben)]);
      expect(anzeige.alleEntfernt, 1);
      for (final id in [_ben, _ich, _cora]) {
        final n = standortBenachrichtigungsId(id);
        expect(n, greaterThanOrEqualTo(kStandortIdBasis));
        expect(n, lessThan(kStandortIdBasis + kStandortIdBereich));
      }
    });
  });

  group('StandortAbruf (nach einem Wecker)', () {
    late FakeSocketFabrik sockets;

    StandortAbruf abruf() => StandortAbruf(
      benachrichtiger: benachrichtiger(),
      fabrik: ({required beiNachricht, required beiStatus}) => SyncSocket(
        ticket: () async => 't',
        beiRev: (_) {},
        beiStatus: beiStatus,
        beiNachricht: beiNachricht,
        oeffner: sockets.oeffner,
        adresse: () => Uri.parse('wss://familie.test/ws'),
      ),
    );

    setUp(() => sockets = FakeSocketFabrik());

    Future<void> mitServer(Future<void> Function(StandortAbruf) f, void Function(FakeSocket) server) async {
      final a = abruf();
      final lauf = f(a);
      for (var i = 0; i < 50 && sockets.sockets.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // warten, bis die Anmeldung durch ist (ready) und der Abruf sich als Standort-Kanal gemeldet hat
      final s = sockets.letzter;
      for (var i = 0; i < 100 && !s.gesendet.any((m) => m['type'] == 'loc_hello'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      server(s);
      await lauf;
    }

    test('verbindet kurz, meldet sich als Standort-Kanal, meldet die nachgereichte Freigabe lokal und schließt die Verbindung wieder', () async {
      await mitServer(
        (a) => a.abfragen(stille: const Duration(milliseconds: 150), hoechstens: const Duration(seconds: 3)),
        (s) => s.vomServer({'type': 'loc_start', 'from': _ben, 'shareId': 's1', 'endsAt': ende().millisecondsSinceEpoch, 'wrap': 'AAAA'}),
      );
      expect(sockets.letzter.gesendet.any((m) => m['type'] == 'loc_hello'), isTrue);
      expect(anzeige.gezeigt.single.text, 'Ben teilt seinen Standort.');
    });

    test('loc_stop entfernt die Benachrichtigung; ein bereits gemeldetes loc_start meldet nicht noch einmal', () async {
      await benachrichtiger().freigabe(von: _ben, shareId: 's1', endsAt: ende());
      anzeige.gezeigt.clear();
      await mitServer(
        (a) => a.abfragen(stille: const Duration(milliseconds: 150), hoechstens: const Duration(seconds: 3)),
        (s) {
          s.vomServer({'type': 'loc_start', 'from': _ben, 'shareId': 's1', 'endsAt': ende().millisecondsSinceEpoch, 'wrap': 'AAAA'});
          s.vomServer({'type': 'loc_stop', 'from': _ben, 'shareId': 's1', 'reason': 'stopped'});
        },
      );
      expect(anzeige.gezeigt, isEmpty);
      expect(anzeige.entfernt, [standortBenachrichtigungsId(_ben)]);
    });

    test('zweiter Abruf innerhalb einer Minute: keine Verbindung, kein Ticket', () async {
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 300), aufbauFrist: const Duration(milliseconds: 100));
      final n = sockets.sockets.length;
      expect(n, greaterThan(0));
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 300), aufbauFrist: const Duration(milliseconds: 100));
      expect(sockets.sockets.length, n);
    });

    test('Verbindung kommt nicht zustande (Ticket abgelehnt, Netz): nach der Aufbaufrist Schluss, keine endlosen Versuche', () async {
      sockets.scheitern = 100;
      final t = Stopwatch()..start();
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(seconds: 5), aufbauFrist: const Duration(milliseconds: 200));
      expect(t.elapsedMilliseconds, lessThan(2000));
      expect(sockets.sockets.length, lessThan(4));
    });

    test('Diagnose des Abrufs: Verbindung ok mit Freigabe, ohne Freigabe, gedrosselt, keine Verbindung', () async {
      Future<String?> code() async => StandortDiagnoseEintrag.lesen(await db.metaLesen(kDiagAbruf))?.code;
      await mitServer((a) => a.abfragen(stille: const Duration(milliseconds: 100), hoechstens: const Duration(seconds: 3)), (s) => s.vomServer({'type': 'loc_start', 'from': _ben, 'shareId': 's1', 'endsAt': ende().millisecondsSinceEpoch, 'wrap': 'AAAA'}));
      expect(await code(), 'freigaben');
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 300), aufbauFrist: const Duration(milliseconds: 100));
      expect(await code(), 'gedrosselt');
      jetzt = jetzt.add(const Duration(minutes: 1));
      sockets.scheitern = 100;
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 500), aufbauFrist: const Duration(milliseconds: 150));
      expect(await code(), 'keine_verbindung');
      jetzt = jetzt.add(const Duration(minutes: 1));
      sockets.scheitern = 0;
      await mitServer((a) => a.abfragen(stille: const Duration(milliseconds: 100), hoechstens: const Duration(seconds: 3)), (_) {});
      expect(await code(), 'ok');
    });

    group('abgelaufenes Zugangstoken im Hintergrund (Client ohne eigene Erneuerung)', () {
      Future<(StandortAbruf, FakeServer, MemoryTokenStore)> hintergrund(FakeServer server, {required bool abgelaufen}) async {
        final (_, store) = await angemeldeterClient(server, accessBis: abgelaufen ? DateTime.now().subtract(const Duration(minutes: 1)) : null);
        // wie der Hintergrund-Container: derselbe Client darf von selbst nie erneuern
        final bg = ApiClient(client: server.client, store: store, web: false, base: 'https://familie.test', refreshErlaubt: false);
        final api = FampadApi(bg, geraet: () async => null);
        return (
          StandortAbruf(
            benachrichtiger: benachrichtiger(),
            zugangSichern: bg.zugangErneuern,
            fabrik: ({required beiNachricht, required beiStatus}) => SyncSocket(
              ticket: api.wsTicket,
              beiRev: (_) {},
              beiStatus: beiStatus,
              beiNachricht: beiNachricht,
              oeffner: sockets.oeffner,
              adresse: () => Uri.parse('wss://familie.test/ws'),
            ),
          ),
          server,
          store,
        );
      }

      Future<String?> code() async => StandortDiagnoseEintrag.lesen(await db.metaLesen(kDiagAbruf))?.code;

      test('abgelaufen: genau eine Erneuerung, dann Ticket mit dem neuen Token, Verbindung steht', () async {
        final server = FakeServer()
          ..on('POST /auth/refresh', (_) => jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')}))
          ..json('POST /ws-ticket', {'ticket': 't-1'});
        final (a, _, store) = await hintergrund(server, abgelaufen: true);
        await a.abfragen(stille: const Duration(milliseconds: 100), hoechstens: const Duration(seconds: 3));
        expect(server.log.map((r) => r.key), ['POST /auth/refresh', 'POST /ws-ticket']);
        expect(server.anfragen('POST /ws-ticket').single.headers['authorization'], 'Bearer access-2');
        expect((await store.readTokens())!.refreshToken, 'refresh-2');
        expect(sockets.sockets, isNotEmpty);
        expect(await code(), 'ok');
      });

      test('gültiges Token: keine Erneuerung', () async {
        final server = FakeServer()..json('POST /ws-ticket', {'ticket': 't-1'});
        final (a, _, _) = await hintergrund(server, abgelaufen: false);
        await a.abfragen(stille: const Duration(milliseconds: 100), hoechstens: const Duration(seconds: 3));
        expect(server.anfragen('POST /auth/refresh'), isEmpty);
        expect(await code(), 'ok');
      });

      test('Erneuerung abgelehnt: ehrlicher Zustand "anmeldung_abgelaufen", kein Ticket, keine Wiederholung', () async {
        final server = FakeServer()..on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
        final (a, _, _) = await hintergrund(server, abgelaufen: true);
        await a.abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(seconds: 2));
        expect(server.log.map((r) => r.key), ['POST /auth/refresh']);
        expect(sockets.sockets, isEmpty);
        expect(await code(), 'anmeldung_abgelaufen');
        expect(standortDiagnoseText('anmeldung_abgelaufen'), contains('öffne die App'));
      });

      test('Netz weg bei der Erneuerung: "keine_verbindung", Token bleiben unangetastet', () async {
        final server = FakeServer()..on('POST /auth/refresh', (_) => fehler(503, 'unavailable'));
        final (a, _, store) = await hintergrund(server, abgelaufen: true);
        await a.abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(seconds: 2));
        expect(await code(), 'keine_verbindung');
        expect((await store.readTokens())!.refreshToken, 'refresh-1');
        expect(server.anfragen('POST /auth/refresh'), hasLength(1));
      });
    });

    test('Hinweise aus oder App im Vordergrund: keine Verbindung', () async {
      speicher.daten[kStandortHinweisSchluessel] = 'aus';
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 500));
      expect(sockets.sockets, isEmpty);
      speicher.daten.clear();
      vordergrund = true;
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 500));
      expect(sockets.sockets, isEmpty);
    });

    test('Server nicht erreichbar: endet nach der Höchstdauer ohne Fehler', () async {
      sockets.scheitern = 100;
      final t = Stopwatch()..start();
      await abruf().abfragen(stille: const Duration(milliseconds: 50), hoechstens: const Duration(milliseconds: 400));
      expect(t.elapsedMilliseconds, lessThan(3000));
      expect(anzeige.gezeigt, isEmpty);
    });
  });
}
