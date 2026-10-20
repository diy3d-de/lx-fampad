// SyncSocket: Ticket, Anmeldung, Revisionshinweis, Ping/Pong, Neuaufbau mit Backoff und Jitter, Schließcode 4401, Stopp.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/sync/sync_socket.dart';

import 'support/fake_socket.dart';

/// Zufall mit festem Wert: nextDouble() liefert immer [wert] (0.5 -> Jitter-Faktor genau 1.0).
class _FesterZufall implements Random {
  final double wert;
  _FesterZufall(this.wert);
  @override
  double nextDouble() => wert;
  @override
  bool nextBool() => false;
  @override
  int nextInt(int max) => 0;
}

void main() {
  late FakeSocketFabrik fabrik;
  late List<int> revs;
  late List<bool> status;
  var tickets = 0;
  var mitgliederHinweise = 0;
  Object? ticketFehler;

  SyncSocket neu({double zufall = 0.5, Duration ping = const Duration(seconds: 25), Duration pong = const Duration(seconds: 10)}) {
    return SyncSocket(
      ticket: () async {
        tickets++;
        if (ticketFehler != null) throw ticketFehler!;
        return 'ticket-$tickets';
      },
      beiRev: revs.add,
      beiStatus: status.add,
      beiMitglieder: () => mitgliederHinweise++,
      oeffner: fabrik.oeffner,
      zufall: _FesterZufall(zufall),
      adresse: () => Uri.parse('wss://familie.test/ws'),
      pingAbstand: ping,
      pongFrist: pong,
    );
  }

  setUp(() {
    fabrik = FakeSocketFabrik();
    revs = [];
    status = [];
    tickets = 0;
    mitgliederHinweise = 0;
    ticketFehler = null;
  });

  test('Adresse: wss für https, ws für http, Port bleibt, Pfad /ws (nie ein Ticket in der Adresse)', () {
    expect(webSocketAdresse(api: 'https://familie.lx-labs.dev').toString(), 'wss://familie.lx-labs.dev/ws');
    expect(webSocketAdresse(api: 'http://localhost:4400').toString(), 'ws://localhost:4400/ws');
    expect(webSocketAdresse(api: '', seite: Uri.parse('https://familie.lx-labs.dev/#/x')).toString(), 'wss://familie.lx-labs.dev/ws');
    expect(webSocketAdresse(api: '', seite: Uri.parse('http://127.0.0.1:8091/')).toString(), 'ws://127.0.0.1:8091/ws');
  });

  testWidgets('verbindet mit Ticket als erster Nachricht, wird live und meldet Revisionen', (tester) async {
    final s = neu()..start();
    await tester.pump();
    expect(fabrik.sockets, hasLength(1));
    expect(fabrik.adressen.single.toString(), 'wss://familie.test/ws');
    expect(fabrik.letzter.gesendet.first, {'type': 'auth', 'ticket': 'ticket-1'});
    await tester.pump();
    expect(s.live, isTrue);
    expect(status, [true]);
    fabrik.letzter.vomServer({'type': 'rev', 'rev': 7});
    fabrik.letzter.vomServer({'type': 'rev', 'rev': 8});
    fabrik.letzter.vomServer({'type': 'unbekannt'});
    fabrik.letzter.vomServer({'type': 'members_changed'});
    fabrik.letzter.vomServer({'type': 'rev', 'rev': 'kaputt'});
    await tester.pump();
    expect(revs, [7, 8]);
    expect(mitgliederHinweise, 1);
    s.stop();
    expect(s.live, isFalse);
    expect(status, [true, false]);
  });

  testWidgets('Ping alle 25 s, Pong hält die Verbindung; bleibt das Pong aus, wird nach 10 s neu verbunden', (tester) async {
    final s = neu()..start();
    await tester.pump(const Duration(milliseconds: 10));
    final erster = fabrik.letzter;
    await tester.pump(const Duration(seconds: 25));
    expect(erster.gesendet.where((m) => m['type'] == 'ping'), hasLength(1));
    await tester.pump(const Duration(seconds: 15));
    expect(fabrik.sockets, hasLength(1), reason: 'Pong kam, Verbindung bleibt');
    expect(s.live, isTrue);

    erster.autoPong = false;
    await tester.pump(const Duration(seconds: 19)); // t = 59 s: der Ping bei 50 s blieb unbeantwortet, die Frist (10 s) läuft noch
    expect(s.live, isTrue, reason: 'Pong-Frist läuft noch');
    await tester.pump(const Duration(milliseconds: 1500)); // Frist abgelaufen, der Neuaufbau (Backoff 1 s) steht noch aus
    expect(s.live, isFalse);
    // Neuaufbau nach dem Backoff (1 s)
    await tester.pump(const Duration(seconds: 2));
    expect(fabrik.sockets, hasLength(2));
    s.stop();
  });

  testWidgets('Verbindung bricht ab: Neuaufbau mit wachsendem Abstand (1, 2, 4 ... s, höchstens 60 s) und Jitter', (tester) async {
    fabrik.scheitern = 5;
    final s = neu()..start();
    await tester.pump(const Duration(milliseconds: 10));
    expect(fabrik.sockets, hasLength(1));
    // Jitterfaktor 1.0: Versuche bei 1 s, 3 s, 7 s
    await tester.pump(const Duration(milliseconds: 900));
    expect(fabrik.sockets, hasLength(1), reason: 'noch nicht');
    await tester.pump(const Duration(milliseconds: 120));
    expect(fabrik.sockets, hasLength(2));
    await tester.pump(const Duration(milliseconds: 1900));
    expect(fabrik.sockets, hasLength(2));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fabrik.sockets, hasLength(3));
    await tester.pump(const Duration(milliseconds: 3900));
    expect(fabrik.sockets, hasLength(3));
    await tester.pump(const Duration(milliseconds: 120));
    expect(fabrik.sockets, hasLength(4));
    expect(s.versuche, 4);
    s.stop();
  });

  test('Abstand: verdoppelt sich, ist auf 60 s begrenzt und streut um ±50 %', () {
    final klein = neu(zufall: 0.0);
    final mitte = neu(zufall: 0.5);
    final gross = neu(zufall: 1.0);
    expect([for (var n = 0; n < 8; n++) mitte.abstand(n).inSeconds], [1, 2, 4, 8, 16, 32, 60, 60]);
    expect(klein.abstand(3).inMilliseconds, 4000);
    expect(gross.abstand(3).inMilliseconds, 12000);
    expect(mitte.abstand(40).inSeconds, 60);
  });

  testWidgets('Schließcode 4401: sofort ein neues Ticket und neu verbinden; wiederholt: wieder mit Backoff', (tester) async {
    final s = neu()..start();
    await tester.pump(const Duration(milliseconds: 10));
    fabrik.letzter.serverSchliesst(4401);
    await tester.pump(const Duration(milliseconds: 10));
    expect(tickets, 2, reason: 'neues Ticket prüft, ob die Sitzung noch gilt');
    expect(fabrik.sockets, hasLength(2));
    await tester.pump(const Duration(milliseconds: 10));
    expect(s.live, isTrue);
    s.stop();
  });

  testWidgets('Ticket-Anfrage scheitert mit 401: Sitzung beendet, kein Neuaufbau mehr', (tester) async {
    final s = neu()..start();
    await tester.pump(const Duration(milliseconds: 10));
    ticketFehler = const ApiException(kind: ApiErrorKind.nichtAngemeldet, status: 401, code: 'unauthenticated', message: 'x');
    fabrik.letzter.serverSchliesst(4401);
    await tester.pump(const Duration(seconds: 120));
    expect(s.aktiv, isFalse);
    expect(fabrik.sockets, hasLength(1));
  });

  testWidgets('Ticket-Anfrage scheitert wegen Netz: später erneut mit Backoff', (tester) async {
    ticketFehler = ApiException.keineVerbindung;
    final s = neu()..start();
    await tester.pump(const Duration(milliseconds: 10));
    expect(fabrik.sockets, isEmpty);
    ticketFehler = null;
    await tester.pump(const Duration(seconds: 2));
    expect(fabrik.sockets, hasLength(1));
    s.stop();
  });

  testWidgets('stop beendet Verbindung und Zeitgeber; start danach öffnet neu; doppeltes start ändert nichts', (tester) async {
    final s = neu();
    s.start();
    s.start();
    await tester.pump(const Duration(milliseconds: 10));
    expect(fabrik.sockets, hasLength(1));
    s.stop();
    await tester.pump(const Duration(minutes: 5));
    expect(fabrik.sockets, hasLength(1), reason: 'nach stop kein Neuaufbau');
    expect(fabrik.letzter.geschlossen, isTrue);
    s.start();
    await tester.pump(const Duration(milliseconds: 10));
    expect(fabrik.sockets, hasLength(2));
    s.stop();
  });

  testWidgets('ein spätes Ereignis einer alten Verbindung wird ignoriert', (tester) async {
    final s = neu()..start();
    await tester.pump(const Duration(milliseconds: 10));
    final alt = fabrik.letzter;
    s.stop();
    s.start();
    await tester.pump(const Duration(milliseconds: 10));
    alt.vomServer({'type': 'rev', 'rev': 99});
    await tester.pump();
    expect(revs, isEmpty);
    s.stop();
  });
}
