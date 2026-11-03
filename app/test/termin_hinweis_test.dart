// Hinweise auf neue und geänderte Termine (Abschnitt 6r): reine Logik, der Ablauf im Abgleich gegen den Fake-Server (eigene Änderungen, erster
// Abgleich, Neusynchronisierung, Geburtstage, Zusammenfassen, Schalter, Wandtablet) und die Schalterzeile. Feste Uhr: nichts hängt von DateTime.now() ab.
import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart' show localDataWiperProvider;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher, feiertageSpeicherProvider;
import 'package:lx_fampad/data/calendar/termin_hinweis_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/browser_benachrichtigung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/calendar/termin_hinweis_logik.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_models.dart' show SyncChange;
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/features/calendar/termin_hinweis_ui.dart';

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';
import 'support/fake_sync_server.dart';

const _t1 = '33333333-3333-4333-8333-333333333333';
const _t2 = '44444444-4444-4444-8444-444444444444';
const _t3 = '55555555-5555-4555-8555-555555555555';

class _Anzeige implements TerminHinweisAnzeige {
  final List<({List<TerminTreffer> treffer, bool mitTitel})> gezeigt = [];
  int entfernt = 0;
  @override
  Future<bool> zeigen(List<TerminTreffer> treffer, {required bool mitTitel, required bool sperrbildschirmTitel}) async {
    gezeigt.add((treffer: treffer, mitTitel: mitTitel));
    return true;
  }

  @override
  Future<void> entfernen() async => entfernt++;
}

Map<String, dynamic> _termin(String titel, {int tag = 10, String? uid}) => {
  'titel': titel,
  'ganztaegig': true,
  'startDate': '2027-03-${tag.toString().padLeft(2, '0')}',
  'endDate': '2027-03-${(tag + 1).toString().padLeft(2, '0')}',
  'icalUid': ?uid,
  'audience': 'family',
};

Termin _zeile(String id, {String titel = 'X', String? owner = 'a', int rev = 5, String? uid}) => Termin(
  id: id,
  titel: titel,
  ort: '',
  beschreibung: '',
  ganztaegig: true,
  startDate: '2027-03-10',
  endDate: '2027-03-11',
  audience: 'family',
  ownerId: owner,
  icalUid: uid,
  createdAt: DateTime.utc(2027, 1, 1),
  rev: rev,
);

void main() {
  group('Logik', () {
    ({Termin termin, String abdruck}) j(Termin t, [List<TerminAusnahme> a = const []]) => (termin: t, abdruck: terminAbdruck(t, a));

    test('neu, geändert, unverändert, eigene, Geburtstage, gelöscht', () {
      final alt1 = _zeile('1', titel: 'Alt');
      final alt2 = _zeile('2', titel: 'Gleich');
      final t = terminTreffer(
        vorher: {'1': terminAbdruck(alt1, const []), '2': terminAbdruck(alt2, const []), '3': null, '4': null, '5': null, '6': null, '7': 'x'},
        jetzt: {
          '1': j(_zeile('1', titel: 'Neu benannt')), // geändert
          '2': j(_zeile('2', titel: 'Gleich', rev: 9)), // nur Revision: nichts Sichtbares
          '3': j(_zeile('3', titel: 'Frisch')), // neu
          '4': j(_zeile('4', titel: 'Selbst geändert')), // eigene Änderung (Ausgang)
          '5': j(_zeile('5', titel: 'Opa', uid: 'lxfampad-geb-1950-12345678-aaaa')), // Geburtstag
          // '7' fehlt: gelöscht
        },
        eigene: {'4'},
      );
      expect([for (final x in t) '${x.id}:${x.neu}'], ['1:false', '3:true']);
    });

    test('Termine des Besitzers gelten nicht mehr als eigene: erst der Ausgang entscheidet', () {
      final t = terminTreffer(vorher: {'1': null}, jetzt: {'1': j(_zeile('1', owner: 'ich'))}, eigene: {});
      expect(t, hasLength(1));
    });

    test('Ausnahmen einer Serie gehören zum Abdruck', () {
      final serie = _zeile('1').copyWith(rrule: const Value('FREQ=WEEKLY'));
      const ausnahme = TerminAusnahme(id: 'a1', terminId: '1', originalStart: '2027-03-17', abgesagt: true, rev: 3);
      final t = terminTreffer(vorher: {'1': terminAbdruck(serie, const [])}, jetzt: {'1': j(serie, [ausnahme])}, eigene: {});
      expect(t.single.neu, isFalse, reason: '"Nur dieses Vorkommen" abgesagt ist eine Änderung');
    });

    test('alte Serie gekürzt + neue Serie ergibt einen Treffer', () {
      final alt = _zeile('1', titel: 'Training').copyWith(rrule: const Value('FREQ=WEEKLY'));
      final gekuerzt = alt.copyWith(rrule: const Value('FREQ=WEEKLY;UNTIL=20270301T000000Z'));
      final neu = _zeile('2', titel: 'Training').copyWith(rrule: const Value('FREQ=WEEKLY'));
      final t = terminTreffer(vorher: {'1': terminAbdruck(alt, const []), '2': null}, jetzt: {'1': j(gekuerzt), '2': j(neu)}, eigene: {});
      expect(t, hasLength(1));
      expect(t.single.neu, isFalse);
    });

    test('Titel anderer: Steuer- und Richtungszeichen weg, höchstens 80 Zeichen', () {
      final bidi = String.fromCharCode(0x202E);
      final nullbreite = String.fromCharCode(0x200B);
      final klingel = String.fromCharCode(7);
      expect(terminHinweisTitel('A${bidi}evil$nullbreite$klingel B\n\tC'), 'Aevil B C');
      final lang = terminHinweisTitel('x' * 200);
      expect(lang.runes.length, 80);
      expect(lang, endsWith('…'));
      expect(terminHinweisText([TerminTreffer('1', 'Zahn${bidi}arzt', neu: true)], mitTitel: true).text, 'Zahnarzt');
    });

    test('Texte: einzeln, Zusammenfassung, Titel nur mit Erlaubnis, Web nie mit Titel', () {
      const n = TerminTreffer('1', 'Zahnarzt', neu: true);
      const g = TerminTreffer('2', 'Schwimmen', neu: false);
      expect(terminHinweisText([n], mitTitel: false), (titel: 'Ein neuer Termin', text: 'Im Kalender ansehen'));
      expect(terminHinweisText([n], mitTitel: true), (titel: 'Ein neuer Termin', text: 'Zahnarzt'));
      expect(terminHinweisText([g], mitTitel: false).titel, 'Ein Termin wurde geändert');
      expect(terminHinweisText([g, g, g], mitTitel: true), (titel: '3 Termine geändert', text: 'Im Kalender ansehen'));
      expect(terminHinweisText([n, n], mitTitel: true).titel, '2 neue Termine');
      expect(terminHinweisText([n, g], mitTitel: true).titel, '2 Termine neu oder geändert');
      for (final liste in [
        [n],
        [g],
        [n, g],
      ]) {
        expect(terminHinweisWebText(liste), isNot(contains('Zahnarzt')));
        expect(terminHinweisWebText(liste), isNot(contains('Schwimmen')));
        expect(terminHinweisWebText(liste), startsWith('Kalender: '));
      }
    });
  });

  group('im Abgleich', () {
    late FakeServer server;
    late FakeSyncServer sync;
    late AppDatabase db;
    late SyncStore store;
    late SyncEngine engine;
    late TerminHinweisDienst dienst;
    late _Anzeige anzeige;
    var an = true;
    var wand = false;
    var titelErlaubt = false;

    setUp(() async {
      an = true;
      wand = false;
      titelErlaubt = false;
      server = FakeServer();
      sync = FakeSyncServer()..registrieren(server);
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      await db.besitzerSetzen(fixIdAdmin);
      final tokens = MemoryTokenStore();
      await tokens.writeTokens(
        StoredTokens(accessToken: 'a', accessExpiresAt: DateTime.utc(2099), refreshToken: 'r', refreshExpiresAt: DateTime.utc(2099), deviceId: fixDevice),
      );
      final client = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test');
      store = SyncStore(db);
      anzeige = _Anzeige();
      dienst = TerminHinweisDienst(db: db, anzeige: anzeige, an: () async => an, sperrbildschirmTitel: () async => titelErlaubt, wandtablet: () => wand);
      engine = SyncEngine(store: store, api: FampadApi(client, geraet: () async => null), geraeteId: () async => fixDevice, beobachter: dienst);
    });
    tearDown(() => db.close());

    Future<void> lauf() async => expect((await engine.abgleichen()).ok, isTrue);

    test('der erste Abgleich meldet nichts, danach neu und geändert (Titel nur mit Erlaubnis)', () async {
      sync.andereAendert('termin', _t1, _termin('Schon da'));
      await lauf();
      expect(anzeige.gezeigt, isEmpty, reason: 'erster Abgleich: der ganze Bestand ist nichts Neues');
      sync.andereAendert('termin', _t2, _termin('Zahnarzt'));
      titelErlaubt = true;
      await lauf();
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.last.treffer.single.neu, isTrue);
      expect(anzeige.gezeigt.last.mitTitel, isTrue);
      sync.andereAendert('termin', _t2, {'titel': 'Zahnarzt neu'});
      await lauf();
      expect(anzeige.gezeigt, hasLength(2));
      expect(anzeige.gezeigt.last.treffer.single.neu, isFalse);
      await lauf();
      expect(anzeige.gezeigt, hasLength(2), reason: 'ohne Änderung nichts');
    });

    test('mehrere Änderungen in einem Lauf ergeben genau eine Meldung', () async {
      sync.andereAendert('termin', _t1, _termin('A'));
      await lauf();
      sync.andereAendert('termin', _t1, {'titel': 'A2'});
      sync.andereAendert('termin', _t2, _termin('B'));
      sync.andereAendert('termin', _t3, _termin('C'));
      await lauf();
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.treffer, hasLength(3));
    });

    test('eigene Änderungen und die an Terminen anderer lösen nichts aus', () async {
      sync.andereAendert('termin', _t1, _termin('Von Ben'));
      await lauf();
      // eigener neuer Termin (Besitzer ich) und eigene Änderung an einem fremden Termin, beides läuft über den Ausgang
      await store.aendern('termin', _t2, _termin('Mein Termin'), nurLokal: {'createdAt': '2027-01-01T00:00:00.000Z', 'ownerId': fixIdAdmin});
      await store.aendern('termin', _t1, {'titel': 'Von Ben, von mir geändert'});
      await lauf();
      expect(anzeige.gezeigt, isEmpty);
      // eine Änderung des Servers, die nur Farbe betrifft, meldet nichts
      sync.andereAendert('termin', _t1, {'farbe': 3});
      await lauf();
      expect(anzeige.gezeigt, isEmpty, reason: 'nur Farbe');
    });

    test('Termin der eigenen Person, den jemand anderes ändert, wird gemeldet (z. B. Elternteil verschiebt den Termin des Kindes)', () async {
      sync.andereAendert('termin', _t1, {..._termin('Kinderarzt'), 'ownerId': fixIdAdmin});
      await lauf();
      sync.andereAendert('termin', _t1, {'startDate': '2027-03-12', 'endDate': '2027-03-13'});
      await lauf();
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.treffer.single.neu, isFalse);
    });

    test('ein abgebrochener Lauf verliert die Meldung nicht: der Stand bleibt bis zum nächsten vollständigen Lauf', () async {
      sync.andereAendert('termin', _t1, _termin('Alt'));
      await lauf();
      // Antwort mit einer Änderung ist da, der Lauf bricht danach ab (kein nach())
      await dienst.vorUebernahme([SyncChange(rev: 9, entity: 'termin', id: _t2, tombstone: false, hidden: false, fields: const {})], const []);
      await db.into(db.termine).insert(TermineCompanion.insert(id: _t2, titel: 'Neu vom Abbruch', createdAt: DateTime.utc(2027), ownerId: const Value('x'), rev: const Value(9)));
      await lauf(); // vollständiger Lauf ohne neue Änderungen
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.treffer.single.titel, 'Neu vom Abbruch');
    });

    test('derselbe Termin von einem zweiten eigenen Gerät (Urheber = diese Person) meldet nichts, eine fremde Änderung danach schon', () async {
      sync.andereAendert('termin', _t1, _termin('Alt'));
      await lauf();
      sync.andereAendert('termin', _t1, {'titel': 'Vom Tablet'}, urheber: fixIdAdmin);
      sync.andereAendert('termin', _t2, _termin('Neu vom Tablet'), urheber: fixIdAdmin);
      await lauf();
      expect(anzeige.gezeigt, isEmpty, reason: 'eigene Person auf anderem Gerät');
      sync.andereAendert('termin', _t1, {'titel': 'Von Ben'}, urheber: fixIdKind);
      await lauf();
      expect(anzeige.gezeigt, hasLength(1));
      sync.andereAendert('termin', _t3, _termin('Ohne Urheber (älterer Server)'));
      await lauf();
      expect(anzeige.gezeigt, hasLength(2));
    });

    test('ein abgebrochener Hintergrund-Start: der nächste Dienst übernimmt den Stand (nur Prüfwerte auf der Platte, nie Titel oder Ort)', () async {
      sync.andereAendert('termin', _t1, _termin('Geheimer Titel'));
      await lauf();
      // Abbruch: die Antwort wird festgehalten und eingearbeitet, aber der Lauf endet vor nach(); der Dienst (Container) geht verloren
      final alt = TerminHinweisDienst(db: db, anzeige: anzeige, an: () async => true, sperrbildschirmTitel: () async => false, wandtablet: () => false);
      await alt.vorUebernahme([SyncChange(rev: 9, entity: 'termin', id: _t1, tombstone: false, hidden: false, fields: const {})], const []);
      final roh = await db.metaLesen(TerminHinweisDienst.kStandSchluessel);
      expect(roh, isNotNull);
      expect(roh, isNot(contains('Geheimer')));
      await (db.update(db.termine)..where((x) => x.id.equals(_t1))).write(const TermineCompanion(titel: Value('Geheimer Titel, neu')));
      final neu = TerminHinweisDienst(db: db, anzeige: anzeige, an: () async => true, sperrbildschirmTitel: () async => false, wandtablet: () => false);
      await neu.nach();
      expect(anzeige.gezeigt, hasLength(1));
      expect(anzeige.gezeigt.single.treffer.single.neu, isFalse);
      expect(await db.metaLesen(TerminHinweisDienst.kStandSchluessel), isNull, reason: 'nach dem vollständigen Lauf aufgeräumt');
    });

    test('Abmelden (Wiper-Weg): Zustand weg und gezeigte Meldung zurückgenommen', () async {
      await dienst.vorUebernahme([SyncChange(rev: 9, entity: 'termin', id: _t2, tombstone: false, hidden: false, fields: const {})], const []);
      await dienst.abmelden();
      expect(anzeige.entfernt, 1);
      await db.into(db.termine).insert(TermineCompanion.insert(id: _t2, titel: 'X', createdAt: DateTime.utc(2027), rev: const Value(9)));
      await dienst.nach();
      expect(anzeige.gezeigt, isEmpty, reason: 'der Stand der Vorperson ist verworfen');
    });

    test('Geburtstage, Löschen und Neusynchronisierung melden nichts', () async {
      sync.andereAendert('termin', _t1, _termin('X'));
      await lauf();
      sync.andereAendert('termin', _t2, _termin('Opa', uid: 'lxfampad-geb-1950-12345678-aaaa'));
      await lauf();
      expect(anzeige.gezeigt, isEmpty, reason: 'Geburtstag');
      sync.andereLoescht('termin', _t1);
      await lauf();
      expect(anzeige.gezeigt, isEmpty, reason: 'gelöscht');
      sync.andereAendert('termin', _t3, _termin('Neu beim Resync'));
      sync.resyncNaechste = true;
      await lauf();
      expect(anzeige.gezeigt, isEmpty, reason: 'Neusynchronisierung bringt den ganzen Bestand');
    });

    test('Schalter aus und Wandtablet: keine Meldung', () async {
      sync.andereAendert('termin', _t1, _termin('A'));
      await lauf();
      an = false;
      sync.andereAendert('termin', _t2, _termin('B'));
      await lauf();
      expect(anzeige.gezeigt, isEmpty);
      an = true;
      wand = true;
      sync.andereAendert('termin', _t3, _termin('C'));
      await lauf();
      expect(anzeige.gezeigt, isEmpty);
    });
  });

  group('Wiper', () {
    testWidgets('lokaleDatenWiper nimmt die gezeigte Meldung zurück (Abmelden, Personenwechsel, Gerät abgeben)', (tester) async {
      final anzeige = _Anzeige();
      final env = TestUmgebung(standardServer())..wiperEcht = true;
      env.extraOverrides.add(terminHinweisAnzeigeProvider.overrideWithValue(anzeige));
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      env.besitzerInDb = true;
      await env.angemeldet();
      final c = await starteApp(tester, env);
      await tester.runAsync(() => c.read(localDataWiperProvider)());
      expect(anzeige.entfernt, 1);
    });
  });

  group('Web', () {
    test('nur mit Schalter und Erlaubnis, immer neutral, Klick öffnet den Kalender', () async {
      final browser = FakeBrowserBenachrichtigung(stand: BrowserErlaubnis.erlaubt);
      var webAn = false;
      var geklickt = 0;
      final a = WebTerminHinweisAnzeige(browser: browser, webAn: () async => webAn, beiKlick: () => geklickt++);
      const t = [TerminTreffer('1', 'Zahnarzt bei Dr. Müller', neu: true)];
      expect(await a.zeigen(t, mitTitel: true, sperrbildschirmTitel: true), isFalse, reason: 'Schalter "Erinnerungen im Browser" aus');
      webAn = true;
      browser.stand = BrowserErlaubnis.blockiert;
      expect(await a.zeigen(t, mitTitel: true, sperrbildschirmTitel: true), isFalse, reason: 'ohne Erlaubnis');
      browser.stand = BrowserErlaubnis.erlaubt;
      expect(await a.zeigen(t, mitTitel: true, sperrbildschirmTitel: true), isTrue);
      expect(browser.gezeigt.single.text, 'Kalender: Ein neuer Termin');
      expect('${browser.gezeigt.single.titel} ${browser.gezeigt.single.text}', isNot(contains('Zahnarzt')));
      browser.gezeigt.single.beiKlick();
      expect(geklickt, 1);
    });
  });

  group('Schalterzeile', () {
    testWidgets('Standard an, bedienbar, 360 px und Textskala 1.5, Zustand wird gespeichert', (tester) async {
      final speicher = MemoryFeiertageSpeicher();
      final handle = tester.ensureSemantics();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [feiertageSpeicherProvider.overrideWithValue(speicher)]);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.5)),
              child: const Scaffold(body: SingleChildScrollView(child: TerminHinweiseSchalterZeile())),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'kein Überlauf');
      final schalter = find.byType(SwitchListTile);
      expect(tester.widget<SwitchListTile>(schalter).value, isTrue, reason: 'Standard an');
      expect(tester.getSize(schalter).height, greaterThanOrEqualTo(44));
      expect(find.text('Neue und geänderte Termine melden'), findsOneWidget);
      final sem = tester.getSemantics(schalter);
      expect(sem.label, contains('Neue und geänderte Termine melden'));
      await tester.tap(schalter);
      await tester.pump();
      expect(c.read(terminHinweiseAnProvider), isFalse);
      expect(speicher.werte[kTerminHinweiseSchluessel], 'nein');
      handle.dispose();
    });
  });
}
