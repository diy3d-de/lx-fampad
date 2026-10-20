// Aufgaben-Erinnerungen: reine Planung (Bezugspunkte, Zuständige, Erledigte, Fenster gemeinsam mit Terminen, Payload), Repository
// (erinnerungMin nur mit Fälligkeit, Folgeaufgabe übernimmt) und Dienst (Neuplanung bei Änderung, Einstellung "Aufgaben" aus).
import 'package:drift/drift.dart' show DatabaseConnection, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/tasks/aufgabe_logik.dart';
import 'package:lx_fampad/data/tasks/aufgabe_repository.dart';
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/tasks/tasks_state.dart' show aufgabeOeffnenProvider;
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;
import 'support/test_app.dart';

const ich = 'u-ich';
const a1 = '3f2b8c1e-9d4a-4b6f-8a1c-2e7d5f0a9b13';

/// Montag 19.10.2026 12:00 Uhr Berlin (Sommerzeit).
final jetzt = DateTime.utc(2026, 10, 19, 10);

Aufgabe aufgabe({
  String id = a1,
  String titel = 'Müll raus',
  String? faelligDate,
  DateTime? faelligUtc,
  int? min = 0,
  String? zu,
  String? owner = ich,
  DateTime? erledigt,
}) => Aufgabe(
  id: id,
  titel: titel,
  beschreibung: '',
  faelligDate: faelligDate,
  faelligUtc: faelligUtc,
  tzid: faelligUtc == null ? null : 'Europe/Berlin',
  prioritaet: 0,
  assigneeId: zu,
  erledigtAt: erledigt,
  erledigtVon: null,
  wiederholung: null,
  erinnerungMin: min,
  audience: 'family',
  ownerId: owner,
  createdAt: DateTime.utc(2026, 10, 1),
  rev: 1,
);

String uuid(int i) => '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';

List<GeplanteErinnerung> plane(List<Aufgabe> a, {String? person = ich, int max = kErinnerungFenster, KalenderDaten? daten}) =>
    planeErinnerungen(daten: daten ?? const KalenderDaten(), ich: person, jetzt: jetzt, maxAnzahl: max, aufgaben: a);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  group('Planung', () {
    test('Tag ohne Uhrzeit: Bezugspunkt 09:00 Uhr (Sommerzeit = 07:00 UTC), Vorlaufzeiten in Minuten und Tagen', () {
      final e = plane([
        aufgabe(id: uuid(1), faelligDate: '2026-10-21', min: 0),
        aufgabe(id: uuid(2), faelligDate: '2026-10-21', min: 60),
        aufgabe(id: uuid(3), faelligDate: '2026-10-21', min: 1440),
      ]);
      expect(e.map((x) => x.zeit), [DateTime.utc(2026, 10, 20, 7), DateTime.utc(2026, 10, 21, 6), DateTime.utc(2026, 10, 21, 7)]);
      expect(e.first.text, 'Fällig morgen');
      expect(e.last.text, 'Fällig heute');
    });

    test('Zeitpunkt mit Uhrzeit: Fälligkeit minus Vorlaufzeit, Text mit Uhrzeit', () {
      final e = plane([aufgabe(faelligUtc: DateTime.utc(2026, 10, 20, 12, 30), min: 15)]);
      expect(e.single.zeit, DateTime.utc(2026, 10, 20, 12, 15));
      expect(e.single.titel, 'Müll raus');
      expect(e.single.text, 'Fällig heute, 14:30');
      expect(e.single.payload, 'aufgabe|$a1');
      expect(aufgabeErinnerungPayloadLesen(e.single.payload), a1);
    });

    test('ein Tag vorher rechnet in der Wanduhr (über die Zeitumstellung am 25.10.)', () {
      final e = plane([aufgabe(faelligUtc: DateTime.utc(2026, 10, 26, 9), min: 1440)]); // 10:00 Winterzeit
      expect(e.single.zeit, DateTime.utc(2026, 10, 25, 9)); // 10:00 am Vortag (Winterzeit)
    });

    test('Ausgenommen: ohne Erinnerung, ohne Fälligkeit, erledigt, vergangen', () {
      expect(plane([aufgabe(faelligDate: '2026-10-21', min: null)]), isEmpty);
      expect(plane([aufgabe(min: 15)]), isEmpty);
      expect(plane([aufgabe(faelligDate: '2026-10-21', erledigt: jetzt)]), isEmpty);
      expect(plane([aufgabe(faelligDate: '2026-10-19', min: 0)]), isEmpty, reason: '09:00 heute ist vorbei');
      expect(plane([aufgabe(faelligUtc: DateTime.utc(2026, 10, 19, 10, 0, 3), min: 0)]), isEmpty, reason: 'innerhalb des Mindestabstands');
    });

    test('Betroffene Person: Zuständige; ohne Zuständige der Ersteller; fremde Zuweisung erinnert nur die Zuständige', () {
      const tag = '2026-10-21';
      expect(plane([aufgabe(faelligDate: tag, zu: ich, owner: 'x')]), hasLength(1));
      expect(plane([aufgabe(faelligDate: tag, zu: null, owner: ich)]), hasLength(1));
      expect(plane([aufgabe(faelligDate: tag, zu: null, owner: 'x')]), isEmpty);
      expect(plane([aufgabe(faelligDate: tag, zu: 'u-kind', owner: ich)]), isEmpty);
      expect(plane([aufgabe(faelligDate: tag, zu: ich)], person: null), isEmpty);
      expect(aufgabeBetrifftPerson(null, null, ich), isFalse);
    });

    test('Horizont wie bei Terminen: Erinnerungen jenseits von 366 Tagen werden noch nicht geplant', () {
      expect(plane([aufgabe(faelligDate: '2027-10-10', min: 0)]), hasLength(1));
      expect(plane([aufgabe(faelligDate: '2027-11-20', min: 0)]), isEmpty);
    });

    test('Payload: nur UUIDs, nie eine Ausnahme', () {
      expect(aufgabeErinnerungPayloadLesen(null), isNull);
      expect(aufgabeErinnerungPayloadLesen('aufgabe|kein-uuid'), isNull);
      expect(aufgabeErinnerungPayloadLesen('termin|$a1|2026-10-20'), isNull);
      expect(erinnerungPayloadLesen('aufgabe|$a1'), isNull);
    });

    test('Fenster gemeinsam mit Terminen: nach Zeit gemischt, Deckel gilt für beide, danach der Hinweis', () {
      final termin = Termin(
        id: 't1',
        titel: 'Zahnarzt',
        ort: '',
        beschreibung: '',
        ganztaegig: false,
        startUtc: DateTime.utc(2026, 10, 20, 12),
        endUtc: DateTime.utc(2026, 10, 20, 13),
        tzid: 'Europe/Berlin',
        startDate: null,
        endDate: null,
        rrule: null,
        erinnerungMin: 15,
        icalUid: null,
        audience: 'family',
        ownerId: ich,
        createdAt: DateTime.utc(2026, 10, 1),
        rev: 1,
      );
      final daten = KalenderDaten(termine: [termin], ausnahmen: const {}, teilnehmer: const {});
      final auf = aufgabe(faelligUtc: DateTime.utc(2026, 10, 20, 11, 30), min: 0);
      expect(plane([auf], daten: daten).map((x) => x.titel), ['Müll raus', 'Zahnarzt']);
      final knapp = plane([auf], daten: daten, max: 1);
      expect(knapp, hasLength(2));
      expect(knapp.first.titel, 'Müll raus');
      expect(knapp.last.titel, 'Erinnerungen laufen aus');
    });

    test('Hinweis bei vielen Aufgaben: genau das Fenster plus Hinweis, IDs eindeutig', () {
      final viele = [
        for (var i = 0; i < kErinnerungFenster + 5; i++) aufgabe(id: uuid(i), faelligUtc: DateTime.utc(2026, 11, 1).add(Duration(minutes: i)), min: 0),
      ];
      final e = plane(viele);
      expect(e, hasLength(kErinnerungFenster + 1));
      expect(e.last.id, kAuslaufHinweisPlanId);
      expect(e.map((x) => x.id).toSet(), hasLength(e.length));
    });

    test('Text der Vorlaufzeiten', () {
      expect([for (final m in kAufgabeErinnerungen) aufgabeErinnerungText(m)], ['Keine', 'Zur Fälligkeit', '15 Minuten vorher', '1 Stunde vorher', '1 Tag vorher']);
      expect(aufgabeErinnerungText(10080), '7 Tage vorher');
      expect(aufgabeErinnerungText(90), '90 Minuten vorher');
    });
  });

  group('Repository', () {
    late AppDatabase db;
    late AufgabeRepository repo;
    var n = 0;

    setUp(() {
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      repo = AufgabeRepository(
        db: db,
        store: SyncStore(db),
        ich: () => ich,
        beiAenderung: () {},
        jetzt: () => DateTime.utc(2026, 10, 19, 8),
        neueId: () => uuid(++n),
      );
    });
    tearDown(() => db.close());

    Future<Aufgabe> holen(String id) => (db.select(db.aufgaben)..where((t) => t.id.equals(id))).getSingle();

    test('erinnerungMin wird mit Fälligkeit gespeichert, ohne Fälligkeit entfällt es; Änderungen werden übernommen', () async {
      final mit = await repo.anlegen(AufgabeEingabe(titel: 'a', faellig: DateTime.utc(2026, 10, 25), erinnerungMin: 60));
      final ohne = await repo.anlegen(const AufgabeEingabe(titel: 'b', erinnerungMin: 60));
      expect((await holen(mit)).erinnerungMin, 60);
      expect((await holen(ohne)).erinnerungMin, isNull);
      await repo.speichern(await holen(mit), AufgabeEingabe(titel: 'a', faellig: DateTime.utc(2026, 10, 25), erinnerungMin: 1440), bisherigePunkte: const []);
      expect((await holen(mit)).erinnerungMin, 1440);
      // Fälligkeit entfernt: die Erinnerung geht mit
      await repo.speichern(await holen(mit), const AufgabeEingabe(titel: 'a', erinnerungMin: 1440), bisherigePunkte: const []);
      expect((await holen(mit)).erinnerungMin, isNull);
    });

    test('Folgeaufgabe einer wiederkehrenden Aufgabe übernimmt die Erinnerung', () async {
      final id = await repo.anlegen(AufgabeEingabe(titel: 'Tonne', faellig: DateTime.utc(2026, 10, 19), wiederholung: AufgabeWdh.woechentlich, erinnerungMin: 15));
      await repo.erledigt(await holen(id), true);
      expect((await holen(folgeAufgabeId(id))).erinnerungMin, 15);
    });
  });

  group('Dienst', () {
    late TestUmgebung env;
    late FakeErinnerungPort port;
    late MemoryErinnerungSpeicher speicher;
    late ProviderContainer c;

    Future<void> bis(bool Function() bedingung, {String grund = 'Bedingung'}) async {
      for (var i = 0; i < 100; i++) {
        if (bedingung()) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('Zeitüberschreitung: $grund');
    }

    Future<void> ruhe() async {
      var k = -1;
      for (var i = 0; i < 20 && k != port.planungen.length + port.geloescht; i++) {
        k = port.planungen.length + port.geloescht;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }

    AufgabenCompanion zeile(String id, {int? min = 15, String? zu, String? owner = fixIdAdmin, String tag = '2026-10-21'}) => AufgabenCompanion.insert(
      id: id,
      titel: 'Aufgabe $id',
      faelligDate: Value(tag),
      erinnerungMin: Value(min),
      assigneeId: Value(zu),
      ownerId: Value(owner),
      createdAt: DateTime.utc(2026, 10, 1),
    );

    setUp(() async {
      env = await angemeldeteUmgebung();
      port = FakeErinnerungPort();
      speicher = MemoryErinnerungSpeicher();
      env.extraOverrides.addAll([
        erinnerungPortProvider.overrideWithValue(port),
        erinnerungSpeicherProvider.overrideWithValue(speicher),
        erinnerungUhrProvider.overrideWithValue(() => jetzt),
        erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
        erinnerungWiederholenProvider.overrideWithValue(const Duration(milliseconds: 150)),
      ]);
      c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      c.listen(erinnerungSteuerungProvider, (_, _) {});
      await bis(() => port.planungen.isNotEmpty, grund: 'erste Planung');
      await ruhe();
    });

    test('neue Aufgabe wird geplant, Ändern ersetzt, Erledigen und Löschen räumen auf', () async {
      final n0 = port.planungen.length;
      await env.db.into(env.db.aufgaben).insert(zeile(a1));
      await bis(() => port.planungen.length > n0, grund: 'Planung nach Anlegen');
      expect(port.letzte!.single.zeit, DateTime.utc(2026, 10, 21, 6, 45));
      expect(port.letzte!.single.payload, 'aufgabe|$a1');

      final n1 = port.planungen.length;
      await (env.db.update(env.db.aufgaben)..where((t) => t.id.equals(a1))).write(const AufgabenCompanion(faelligDate: Value('2026-10-22')));
      await bis(() => port.planungen.length > n1, grund: 'Planung nach Änderung');
      expect(port.letzte!.single.zeit, DateTime.utc(2026, 10, 22, 6, 45));

      final n2 = port.planungen.length;
      await (env.db.update(env.db.aufgaben)..where((t) => t.id.equals(a1))).write(AufgabenCompanion(erledigtAt: Value(jetzt)));
      await bis(() => port.planungen.length > n2, grund: 'Planung nach Erledigen');
      expect(port.letzte, isEmpty);

      final n3 = port.planungen.length;
      await (env.db.update(env.db.aufgaben)..where((t) => t.id.equals(a1))).write(const AufgabenCompanion(erledigtAt: Value(null)));
      await bis(() => port.planungen.length > n3);
      expect(port.letzte, hasLength(1));
      final n4 = port.planungen.length;
      await (env.db.delete(env.db.aufgaben)..where((t) => t.id.equals(a1))).go();
      await bis(() => port.planungen.length > n4, grund: 'Planung nach Löschen');
      expect(port.letzte, isEmpty);
    });

    test('fremde Aufgaben und solche ohne Erinnerung lösen keinen neuen Aufruf aus', () async {
      await env.db.into(env.db.aufgaben).insert(zeile(a1));
      await bis(() => port.letzte?.length == 1);
      await ruhe();
      final k = port.planungen.length;
      await env.db.into(env.db.aufgaben).insert(zeile(uuid(2), zu: 'jemand-anderes'));
      await env.db.into(env.db.aufgaben).insert(zeile(uuid(3), min: null));
      await ruhe();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(port.planungen.length, k);
    });

    test('Einstellung "Aufgaben-Erinnerungen" aus: Aufgaben fallen heraus; wieder an: zurück; lokal gespeichert', () async {
      await env.db.into(env.db.aufgaben).insert(zeile(a1));
      await bis(() => port.letzte?.length == 1);
      await ruhe();
      final k = port.planungen.length;
      await c.read(erinnerungEinstellungenProvider.notifier).aufgabenAnSetzen(false);
      await bis(() => port.planungen.length > k, grund: 'Planung nach "aus"');
      expect(port.letzte, isEmpty);
      expect(speicher.daten['erinnerung_aufgaben'], 'nein');
      final k2 = port.planungen.length;
      await c.read(erinnerungEinstellungenProvider.notifier).aufgabenAnSetzen(true);
      await bis(() => port.planungen.length > k2, grund: 'Planung nach "an"');
      expect(port.letzte, hasLength(1));
      expect(speicher.daten['erinnerung_aufgaben'], 'ja');
    });

    test('Standard ist an; ein gespeichertes "nein" wird gelesen', () async {
      expect(const ErinnerungEinstellungen().aufgabenAn, isTrue);
      speicher.daten['erinnerung_aufgaben'] = 'nein';
      final c2 = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(speicher)]);
      addTearDown(c2.dispose);
      c2.read(erinnerungEinstellungenProvider);
      await c2.read(erinnerungEinstellungenProvider.notifier).bereit;
      expect(c2.read(erinnerungEinstellungenProvider).aufgabenAn, isFalse);
    });

    test('Aufgaben-Erinnerungen aus: Dienst plant auch ohne geladene Aufgaben', () async {
      await c.read(erinnerungEinstellungenProvider.notifier).aufgabenAnSetzen(false);
      await ruhe();
      expect(port.letzte, isNotNull);
    });

    test('Tippen auf die Erinnerung öffnet den Aufgaben-Tab und merkt die Aufgabe zum Öffnen', () async {
      await env.db.into(env.db.aufgaben).insert(zeile(a1));
      await bis(() => port.letzte?.length == 1);
      port.tippe('aufgabe|$a1');
      expect(c.read(shellTabProvider), kAufgabenTab);
      expect(c.read(aufgabeOeffnenProvider), a1);
    });
  });
}
