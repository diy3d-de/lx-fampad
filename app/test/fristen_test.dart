// Fristen-Tracker: reine Logik (Ampel, Sortierung, Vorwarnung, Wiederholung in Monaten über Monats-/Jahreswechsel und Schaltjahr), Repository
// (Felder, Folgefrist mit fester ID, Zurücknehmen), Erinnerung (Vorwarnzeit, Text, Zuständige) und Abgleich mit zwei Geräten.
import 'package:drift/drift.dart' show DatabaseConnection, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart' show KalenderDaten;
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/tasks/aufgabe_logik.dart';
import 'package:lx_fampad/data/tasks/aufgabe_repository.dart';
import 'package:lx_fampad/data/tasks/fristen_logik.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

DateTime tag(int y, int m, int d) => DateTime.utc(y, m, d);

Aufgabe frist({
  String id = 'f1',
  String titel = 'TÜV',
  String? faelligDate,
  int? erinnerungMin = 30 * 1440,
  int? fristMonate,
  DateTime? erledigtAt,
  bool istFrist = true,
}) => Aufgabe(
  id: id,
  frist: istFrist,
  fristMonate: fristMonate,
  titel: titel,
  beschreibung: '',
  faelligDate: faelligDate,
  prioritaet: 0,
  erledigtAt: erledigtAt,
  erinnerungMin: erinnerungMin,
  audience: 'family',
  createdAt: DateTime.utc(2026, 1, 1),
  rev: 1,
);

class Geraet {
  final AppDatabase db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  late final SyncStore store;
  late final AufgabeRepository repo;
  var _n = 0;
  DateTime jetzt;

  Geraet(String ich, {String praefix = '00000000-0000-4000-8000-', DateTime? jetzt}) : jetzt = jetzt ?? DateTime.utc(2026, 10, 19, 8) {
    store = SyncStore(db);
    repo = AufgabeRepository(db: db, store: store, ich: () => ich, beiAenderung: () {}, jetzt: () => this.jetzt, neueId: () => '$praefix${(++_n).toString().padLeft(12, '0')}');
  }

  Future<Aufgabe?> a(String id) => (db.select(db.aufgaben)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<List<Aufgabe>> alle() => db.select(db.aufgaben).get();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  final jetzt = DateTime.utc(2026, 10, 19, 8); // Mo 19.10.2026, Berlin 10:00

  group('Ampel', () {
    test('überfällig ab dem Tag nach dem Ablauf, bald ab Vorwarnzeit (inklusive Ablauftag), sonst ruhig, erledigt zuletzt', () {
      expect(fristAmpel(frist(faelligDate: '2026-10-18'), jetzt), FristAmpel.ueberfaellig);
      expect(fristAmpel(frist(faelligDate: '2026-10-19'), jetzt), FristAmpel.bald, reason: 'der Ablauftag selbst ist noch nicht überfällig');
      expect(fristAmpel(frist(faelligDate: '2026-11-18'), jetzt), FristAmpel.bald, reason: 'genau 30 Tage');
      expect(fristAmpel(frist(faelligDate: '2026-11-19'), jetzt), FristAmpel.ruhig, reason: '31 Tage');
      expect(fristAmpel(frist(faelligDate: '2026-10-01', erledigtAt: jetzt), jetzt), FristAmpel.erledigt);
    });

    test('ohne Vorwarnzeit gilt der Standard; Vorwarnzeit 90 Tage wirkt', () {
      expect(fristAmpel(frist(faelligDate: '2026-11-10', erinnerungMin: null), jetzt), FristAmpel.bald);
      expect(fristAmpel(frist(faelligDate: '2027-01-17', erinnerungMin: 90 * 1440), jetzt), FristAmpel.bald);
      expect(fristAmpel(frist(faelligDate: '2027-01-18', erinnerungMin: 90 * 1440), jetzt), FristAmpel.ruhig);
      expect(fristVorwarnTage(7 * 1440), 7);
      expect(fristVorwarnTage(null), isNull);
    });

    test('Resttage und Texte', () {
      expect(fristRestTage(frist(faelligDate: '2026-10-19'), jetzt), 0);
      expect(fristRestTage(frist(faelligDate: '2026-10-16'), jetzt), -3);
      expect(fristRestText(-3), 'seit 3 Tagen überfällig');
      expect(fristRestText(-1), 'seit gestern überfällig');
      expect(fristRestText(0), 'läuft heute ab');
      expect(fristRestText(1), 'läuft morgen ab');
      expect(fristRestText(12), 'in 12 Tagen');
      expect(fristRestText(100), 'in 3 Monaten');
      expect(fristRestText(365), 'in 12 Monaten');
      expect(fristRestText(730), 'in 2 Jahren');
      expect(fristWiederholungText(null), 'Einmalig');
      expect(fristWiederholungText(6), 'Halbjährlich');
      expect(fristWiederholungText(12), 'Jährlich');
      expect(fristWiederholungText(24), 'Alle 2 Jahre');
      expect(fristWiederholungText(18), 'Alle 18 Monate');
      expect(fristVorwarnText(1), '1 Tag vorher');
      expect(fristVorwarnText(30), '30 Tage vorher');
    });
  });

  group('Sortierung und dringende Fristen', () {
    final alle = [
      frist(id: 'c', titel: 'Später', faelligDate: '2027-05-01'),
      frist(id: 'a', titel: 'Überfällig', faelligDate: '2026-09-01'),
      frist(id: 'z', titel: 'Ohne Datum'),
      frist(id: 'b', titel: 'Bald', faelligDate: '2026-11-01'),
      frist(id: 'e', titel: 'Erledigt', faelligDate: '2026-08-01', erledigtAt: DateTime.utc(2026, 8, 2)),
      frist(id: 'n', titel: 'Normale Aufgabe', faelligDate: '2026-01-01', istFrist: false),
    ];

    test('offene Fristen nach Ablauf, ohne Datum am Ende, keine Erledigten und keine normalen Aufgaben', () {
      expect([for (final a in offeneFristen(alle)) a.id], ['a', 'b', 'c', 'z']);
    });

    test('dringend: nur überfällig oder innerhalb der Vorwarnzeit', () {
      expect([for (final a in dringendeFristen(alle, jetzt)) a.id], ['a', 'b']);
      expect(dringendeFristen([alle.first, alle[2]], jetzt), isEmpty);
    });

    test('Filter "Fristen" zeigt nur offene Fristen', () {
      expect([for (final a in filtereAufgaben(alle, filter: AufgabeFilter.fristen)) a.id], ['c', 'a', 'z', 'b']);
      expect(filtereAufgaben(alle, filter: AufgabeFilter.offen).map((a) => a.id), contains('n'), reason: 'Fristen und Aufgaben stehen auch in "Offen"');
    });
  });

  group('Wiederholung in Monaten', () {
    DateTime? naechste(DateTime basis, int monate, {DateTime? heute, int? wunsch}) =>
        naechsteFristFaelligkeit(basis: basis, monate: monate, jetzt: heute ?? DateTime.utc(2026, 10, 19, 8), wunschTag: wunsch);

    test('jährlich: der nächste Ablauf ein Jahr später, auch über den Jahreswechsel', () {
      expect(naechste(tag(2026, 12, 15), 12, heute: DateTime.utc(2026, 12, 1)), tag(2027, 12, 15));
      expect(naechste(tag(2026, 11, 30), 6, heute: DateTime.utc(2026, 11, 1)), tag(2027, 5, 30));
      expect(naechste(tag(2026, 10, 1), 24, heute: DateTime.utc(2026, 10, 1)), tag(2028, 10, 1));
      expect(naechste(tag(2026, 1, 31), 1, heute: DateTime.utc(2026, 1, 31)), tag(2026, 2, 28));
    });

    test('Schaltjahr: 29.2. wird im Folgejahr der 28.2., nach vier Jahren wieder der 29.2.', () {
      expect(naechste(tag(2024, 2, 29), 12, heute: DateTime.utc(2024, 3, 1)), tag(2025, 2, 28));
      expect(naechste(tag(2024, 2, 29), 48, heute: DateTime.utc(2024, 3, 1)), tag(2028, 2, 29));
      // Kette: der Wunschtag 29 bleibt erhalten, auch wenn die Basis schon der 28. ist
      expect(naechste(tag(2027, 2, 28), 12, heute: DateTime.utc(2027, 3, 1), wunsch: 29), tag(2028, 2, 29));
      expect(naechste(tag(2027, 2, 28), 12, heute: DateTime.utc(2027, 3, 1)), tag(2028, 2, 28), reason: 'ohne Wunschtag zählt der Tag der Basis');
    });

    test('uralte Frist: der erste Schritt nach heute (gerechnet, nicht gezählt)', () {
      expect(naechste(tag(2005, 3, 15), 12, heute: DateTime.utc(2026, 10, 19)), tag(2027, 3, 15));
      expect(naechste(tag(2005, 12, 31), 120, heute: DateTime.utc(2026, 10, 19)), tag(2035, 12, 31));
      expect(naechste(tag(2026, 10, 19), 12, heute: DateTime.utc(2026, 10, 19, 22)), tag(2027, 10, 19));
    });

    test('heute = Ablauftag zählt als nicht danach; ungültige Monate ergeben nichts', () {
      expect(naechste(tag(2026, 10, 19), 12, heute: DateTime.utc(2026, 10, 19, 8)), tag(2027, 10, 19));
      expect(naechste(tag(2026, 10, 19), 0), isNull);
    });
  });

  group('Repository', () {
    late Geraet g;
    setUp(() => g = Geraet('u-ich'));
    tearDown(() => g.db.close());

    AufgabeEingabe eingabe(DateTime ablauf, {int? monate = 24, int vorwarn = 30, String? zu}) => AufgabeEingabe(
      titel: 'TÜV',
      faellig: ablauf,
      frist: true,
      fristMonate: monate,
      erinnerungMin: fristVorwarnMin(vorwarn),
      zustaendig: zu,
    );

    test('Anlegen: Frist-Felder, Tag ohne Uhrzeit, Wunschtag; ohne Wiederholung kein Monatswert', () async {
      final id = await g.repo.anlegen(eingabe(tag(2028, 3, 31)));
      final a = (await g.a(id))!;
      expect([a.frist, a.fristMonate, a.faelligDate, a.faelligUtc, a.erinnerungMin, a.wiederholung, a.wiederholungTag], [true, 24, '2028-03-31', null, 43200, null, 31]);
      final b = (await g.a(await g.repo.anlegen(eingabe(tag(2028, 3, 31), monate: null))))!;
      expect([b.frist, b.fristMonate, b.wiederholungTag], [true, null, null]);
      final c = (await g.a(await g.repo.anlegen(const AufgabeEingabe(titel: 'Normal'))))!;
      expect([c.frist, c.fristMonate], [false, null]);
    });

    test('Speichern ändert nur geänderte Felder (Monate, Vorwarnzeit) in den Ausgang', () async {
      final id = await g.repo.anlegen(eingabe(tag(2028, 3, 31)));
      await g.db.delete(g.db.outbox).go();
      await g.repo.speichern((await g.a(id))!, eingabe(tag(2028, 3, 31), monate: 12, vorwarn: 90), bisherigePunkte: const []);
      final ops = await g.db.select(g.db.outbox).get();
      expect(ops, hasLength(1));
      final a = (await g.a(id))!;
      expect([a.fristMonate, a.erinnerungMin], [12, 90 * 1440]);
    });

    test('Erledigen legt die Folgefrist an: feste ID, gleicher Titel, Vorwarnzeit, Monate, Wunschtag; Zurücknehmen löscht sie wieder', () async {
      final id = await g.repo.anlegen(eingabe(tag(2026, 10, 31), monate: 12, vorwarn: 60, zu: 'u-ben'));
      await g.repo.erledigt((await g.a(id))!, true);
      final folge = (await g.a(folgeAufgabeId(id)))!;
      expect([folge.titel, folge.frist, folge.fristMonate, folge.faelligDate, folge.erinnerungMin, folge.assigneeId, folge.wiederholungTag, folge.erledigtAt], ['TÜV', true, 12, '2027-10-31', 60 * 1440, 'u-ben', 31, null]);
      expect((await g.a(id))!.folgeId, folge.id);
      await g.repo.erledigt((await g.a(id))!, false);
      expect(await g.a(folge.id), isNull);
    });

    test('Kette über das Schaltjahr: 29.2.2028 + 12 Monate = 28.2.2029, danach wieder 29.2.2032 bei 48 Monaten', () async {
      g.jetzt = DateTime.utc(2028, 2, 29, 8);
      final id = await g.repo.anlegen(eingabe(tag(2028, 2, 29), monate: 12));
      await g.repo.erledigt((await g.a(id))!, true);
      final f1 = (await g.a(folgeAufgabeId(id)))!;
      expect([f1.faelligDate, f1.wiederholungTag], ['2029-02-28', 29]);
      g.jetzt = DateTime.utc(2029, 2, 28, 8);
      await g.repo.erledigt(f1, true);
      expect((await g.a(folgeAufgabeId(f1.id)))!.faelligDate, '2030-02-28', reason: 'der Wunschtag 29 gilt nur im Schaltjahr');
      final v = await g.repo.anlegen(eingabe(tag(2028, 2, 29), monate: 48));
      await g.repo.erledigt((await g.a(v))!, true);
      expect((await g.a(folgeAufgabeId(v)))!.faelligDate, '2032-02-29');
    });

    test('verspätet erledigt: die Folgefrist liegt nach heute, nicht in der Vergangenheit', () async {
      g.jetzt = DateTime.utc(2026, 10, 19, 8);
      final id = await g.repo.anlegen(eingabe(tag(2024, 3, 10), monate: 24));
      await g.repo.erledigt((await g.a(id))!, true);
      expect((await g.a(folgeAufgabeId(id)))!.faelligDate, '2028-03-10');
    });

    test('einmalige Frist: keine Folgefrist', () async {
      final id = await g.repo.anlegen(eingabe(tag(2026, 11, 1), monate: null));
      await g.repo.erledigt((await g.a(id))!, true);
      expect(await g.alle(), hasLength(1));
    });

    test('eine normale Aufgabe wiederholt sich weiter über ihre Wiederholung, eine Frist nie darüber', () async {
      final id = await g.repo.anlegen(AufgabeEingabe(titel: 'Tonne', faellig: tag(2026, 10, 19), wiederholung: AufgabeWdh.woechentlich));
      await g.repo.erledigt((await g.a(id))!, true);
      expect((await g.a(folgeAufgabeId(id)))!.faelligDate, '2026-10-26');
      final f = await g.repo.anlegen(AufgabeEingabe(titel: 'Frist', faellig: tag(2026, 10, 19), wiederholung: AufgabeWdh.taeglich, frist: true));
      expect((await g.a(f))!.wiederholung, isNull);
    });
  });

  group('Erinnerung', () {
    const leer = KalenderDaten();

    test('eine Frist erinnert um 09:00 Uhr am Tag Ablauf minus Vorwarnzeit, mit festem Text ohne Inhalt der Notiz', () {
      final a = frist(faelligDate: '2026-12-31', erinnerungMin: 30 * 1440).copyWith(assigneeId: const Value('u-ich'));
      final plan = planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: DateTime.utc(2026, 10, 19, 8), aufgaben: [a]);
      expect(plan, hasLength(1));
      expect(plan.single.zeit, DateTime.utc(2026, 12, 1, 8)); // 09:00 Berlin (Winterzeit)
      expect(plan.single.titel, 'TÜV');
      expect(plan.single.text, 'Läuft ab Do, 31. Dez 2026');
    });

    test('90 Tage Vorwarnzeit: die Erinnerung liegt früher; Vergangenes und Fristen anderer Personen entfallen', () {
      final a = frist(faelligDate: '2027-01-31', erinnerungMin: 90 * 1440).copyWith(assigneeId: const Value('u-ich'));
      final plan = planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: DateTime.utc(2026, 10, 19, 8), aufgaben: [a]);
      expect(plan.single.zeit, DateTime.utc(2026, 11, 2, 8), reason: '09:00 Berlin (Winterzeit) am 2.11.');
      // liegt der Erinnerungszeitpunkt schon hinter uns, entfällt sie
      expect(planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: DateTime.utc(2026, 11, 5, 8), aufgaben: [a]), isEmpty);
      expect(planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: DateTime.utc(2026, 10, 19, 8), aufgaben: [a.copyWith(assigneeId: const Value('u-ben'))]), isEmpty);
    });

    test('Eltern und Admins werden an jede sichtbare Frist erinnert; Kinder nur an eigene', () {
      final a = frist(faelligDate: '2027-01-31', erinnerungMin: 90 * 1440).copyWith(assigneeId: const Value('u-ben'));
      final jetzt = DateTime.utc(2026, 10, 19, 8);
      expect(planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: jetzt, aufgaben: [a], elternRolle: true), hasLength(1));
      expect(planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: jetzt, aufgaben: [a]), isEmpty, reason: 'ohne Elternrolle nur Zuständige');
      // gilt nur für Fristen, nicht für normale Aufgaben anderer Personen
      expect(planeErinnerungen(daten: leer, ich: 'u-ich', jetzt: jetzt, aufgaben: [a.copyWith(frist: false)], elternRolle: true), isEmpty);
    });

    test('Text: heute und morgen', () {
      expect(fristErinnerungInhalt(tag(2026, 10, 19), tag(2026, 10, 19)), 'Läuft heute ab');
      expect(fristErinnerungInhalt(tag(2026, 10, 20), tag(2026, 10, 19)), 'Läuft morgen ab');
    });
  });

  group('Abgleich mit zwei Geräten', () {
    late FakeServer server;
    late FakeSyncServer fake;

    Future<(Geraet, SyncEngine)> geraet(String ich, String geraetId, String praefix) async {
      final d = Geraet(ich, praefix: praefix);
      final tokens = MemoryTokenStore();
      await tokens.writeTokens(
        StoredTokens(accessToken: 'access-1', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'refresh-1', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: geraetId),
      );
      final client = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test');
      final engine = SyncEngine(store: d.store, api: FampadApi(client, geraet: () async => null), geraeteId: () async => geraetId, seite: 500, maxOps: 50);
      return (d, engine);
    }

    setUp(() {
      server = FakeServer();
      fake = FakeSyncServer();
      fake.registrieren(server);
    });

    test('Frist kommt mit Monaten und Vorwarnzeit auf dem zweiten Gerät an; zwei Geräte erledigen sie: genau eine Folgefrist', () async {
      final (a, ea) = await geraet('u-a', fixDevice, '00000000-0000-4000-8000-');
      final (b, eb) = await geraet('u-b', 'geraet-b', '11111111-0000-4000-8000-');
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      final id = await a.repo.anlegen(AufgabeEingabe(titel: 'Reisepass', faellig: tag(2026, 11, 20), frist: true, fristMonate: 120, erinnerungMin: 90 * 1440));
      expect((await ea.abgleichen()).ok, isTrue);
      expect((await eb.abgleichen()).ok, isTrue);
      final x = (await b.a(id))!;
      expect([x.frist, x.fristMonate, x.erinnerungMin, x.faelligDate], [true, 120, 90 * 1440, '2026-11-20']);
      await a.repo.erledigt((await a.a(id))!, true);
      await b.repo.erledigt((await b.a(id))!, true);
      await ea.abgleichen();
      expect((await eb.abgleichen()).ok, isTrue);
      await ea.abgleichen();
      expect(fake.zeilen.values.where((z) => z.entity == 'aufgabe'), hasLength(2));
      expect(await a.alle(), hasLength(2));
      final folge = (await a.a(folgeAufgabeId(id)))!;
      expect([folge.frist, folge.fristMonate, folge.faelligDate], [true, 120, '2036-11-20']);
    });
  });
}
