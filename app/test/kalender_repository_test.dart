// Kalender-Daten: TerminRepository (lokal sofort + Ausgang), Serien ändern (nur dieses, dieses und folgende, alle), Rechte der Oberfläche
// und der Abgleich über den Sync-Kern gegen den Fake-Server (Kaskade, Konflikt, Ablehnungen, zwei Geräte).
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/data/calendar/zeitzonen.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_entities.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

DateTime tag(int y, int m, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, m, d, h, mi);

class Geraet {
  final AppDatabase db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  late final SyncStore store;
  late final TerminRepository repo;
  var geaendert = 0;
  var _n = 0;

  Geraet(String ich) {
    store = SyncStore(db);
    repo = TerminRepository(
      db: db,
      store: store,
      ich: () => ich,
      beiAenderung: () => geaendert++,
      jetzt: () => DateTime.utc(2026, 10, 19, 8),
      neueId: () => '00000000-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}',
    );
  }

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<Termin?> termin(String id) => (db.select(db.termine)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<List<Termin>> alleTermine() => db.select(db.termine).get();
  Future<List<TerminAusnahme>> ausnahmen() => db.select(db.terminAusnahmen).get();
  Future<List<TerminTeilnehmerZeile>> teilnehmer() => db.select(db.terminTeilnehmer).get();
}

TerminEingabe zeit({
  String titel = 'Training',
  DateTime? start,
  DateTime? ende,
  String? rrule,
  Set<String> teilnehmer = const {},
  TerminSicht sicht = TerminSicht.family,
}) => TerminEingabe(
  titel: titel,
  ganztaegig: false,
  startWand: start ?? tag(2026, 10, 20, 10),
  endeWand: ende ?? tag(2026, 10, 20, 11),
  rrule: rrule,
  teilnehmer: teilnehmer,
  sicht: sicht,
);

SyncResult antwort({int rev = 1, List<String> acked = const [], List<SyncRejected> rejected = const [], List<SyncConflict> conflicts = const [], List<SyncChange> changes = const []}) =>
    SyncResult(resyncNoetig: false, rev: rev, acked: acked, rejected: rejected, conflicts: conflicts, changes: changes, hasMore: false, next: 0, snapshotRev: null, serverTime: null);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true; // zwei Geräte = zwei Datenbanken
  tzdata.initializeTimeZones();
  late Geraet g;

  Future<KalenderDaten> laden() async {
    final a = <String, List<TerminAusnahme>>{};
    for (final x in await g.ausnahmen()) {
      a.putIfAbsent(x.terminId, () => []).add(x);
    }
    return KalenderDaten(termine: await g.alleTermine(), ausnahmen: a);
  }

  setUp(() => g = Geraet('u-ich'));
  tearDown(() => g.db.close());

  group('Anlegen und Ändern (lokal zuerst)', () {
    test('Zeittermin: lokal sofort da, Ausgang mit UTC-Zeit und Zeitzone, Ersteller nur lokal', () async {
      final id = await g.repo.anlegen(zeit(teilnehmer: {'u-ich', 'u-kind'}));
      final t = (await g.termin(id))!;
      expect(t.titel, 'Training');
      expect(t.startUtc!.toUtc(), DateTime.utc(2026, 10, 20, 8)); // 10 Uhr Berlin (Sommerzeit)
      expect(t.tzid, 'Europe/Berlin');
      expect(t.ownerId, 'u-ich');
      expect(t.rev, 0);
      final ops = await g.ausgang();
      expect(ops.map((o) => o.entity), ['termin', 'termin_teilnehmer', 'termin_teilnehmer']);
      final felder = jsonDecode(ops.first.fieldsJson) as Map<String, dynamic>;
      expect(felder['startUtc'], '2026-10-20T08:00:00.000Z');
      expect(felder['tzid'], 'Europe/Berlin');
      expect(felder['startDate'], isNull);
      expect(felder.containsKey('ownerId'), isFalse);
      expect(felder.containsKey('createdAt'), isFalse);
      expect(g.geaendert, 1);
    });

    test('Ganztägig: Tage als Text, Ende exklusiv, keine Zeitzone', () async {
      final id = await g.repo.anlegen(TerminEingabe(titel: 'Ferien', ganztaegig: true, startWand: tag(2026, 12, 24), endeWand: tag(2026, 12, 27)));
      final t = (await g.termin(id))!;
      expect([t.ganztaegig, t.startDate, t.endDate, t.startUtc, t.tzid], [true, '2026-12-24', '2026-12-27', null, null]);
    });

    test('Ändern sendet nur geänderte Felder; Teilnehmer werden abgeglichen', () async {
      final id = await g.repo.anlegen(zeit(teilnehmer: {'u-ich', 'u-kind'}));
      // Server hat alles bestätigt
      await g.db.delete(g.db.outbox).go();
      await g.store.sinceRevSetzen(5);
      await g.db.customStatement('UPDATE termine SET rev = 3');
      await g.db.customStatement('UPDATE termin_teilnehmer SET rev = 4');
      await g.repo.alleAendern(id, zeit(titel: 'Kinderturnen', teilnehmer: {'u-ich', 'u-oma'}));
      final ops = await g.ausgang();
      final termin = ops.firstWhere((o) => o.entity == 'termin');
      expect(jsonDecode(termin.fieldsJson), {'titel': 'Kinderturnen'});
      expect(termin.baseRev, 3);
      expect(ops.where((o) => o.entity == 'termin_teilnehmer' && o.op == 'upsert'), hasLength(1));
      expect(ops.where((o) => o.entity == 'termin_teilnehmer' && o.op == 'delete'), hasLength(1));
      expect((await g.teilnehmer()).map((z) => z.userId).toSet(), {'u-ich', 'u-oma'});
    });

    test('Umschalten auf ganztägig sendet alle Zeitfelder gemeinsam', () async {
      final id = await g.repo.anlegen(zeit());
      await g.db.delete(g.db.outbox).go();
      await g.db.customStatement('UPDATE termine SET rev = 3');
      await g.repo.alleAendern(id, TerminEingabe(titel: 'Training', ganztaegig: true, startWand: tag(2026, 10, 20), endeWand: tag(2026, 10, 21)));
      final f = jsonDecode((await g.ausgang()).single.fieldsJson) as Map<String, dynamic>;
      expect(f.keys.toSet(), {'ganztaegig', 'startUtc', 'endUtc', 'tzid', 'startDate', 'endDate'});
      expect(f['ganztaegig'], true);
      expect(f['startDate'], '2026-10-20');
      expect(f['startUtc'], isNull);
    });

    test('Löschen entfernt Termin, Teilnehmer und Ausnahmen lokal; ein nie gesendeter Termin verschwindet spurlos', () async {
      final id = await g.repo.anlegen(zeit(rrule: 'FREQ=WEEKLY', teilnehmer: {'u-ich'}));
      final v = vorkommenImFenster(termine: await g.alleTermine(), ausnahmen: const {}, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 10, 28), jetzt: tag(2026, 10, 19)).first;
      await g.repo.vorkommenAbsagen(v);
      expect(await g.ausnahmen(), hasLength(1));
      await g.repo.alleLoeschen(id);
      expect(await g.alleTermine(), isEmpty);
      expect(await g.teilnehmer(), isEmpty);
      expect(await g.ausnahmen(), isEmpty);
      expect(await g.ausgang(), isEmpty);
    });
  });

  group('Serien', () {
    Future<(String, Vorkommen, KalenderDaten)> serie({String rrule = 'FREQ=WEEKLY;BYDAY=TU', int nr = 1}) async {
      final id = await g.repo.anlegen(zeit(rrule: rrule, teilnehmer: {'u-ich'}));
      await g.db.delete(g.db.outbox).go();
      await g.db.customStatement('UPDATE termine SET rev = 3');
      final daten = await laden();
      final v = vorkommenImFenster(termine: daten.termine, ausnahmen: daten.ausnahmen, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 12, 1), jetzt: tag(2026, 10, 19));
      return (id, v[nr], daten);
    }

    test('nur dieses absagen: eine Ausnahme mit fester ID; zweimal ändern bleibt eine Zeile', () async {
      final (id, v, _) = await serie();
      expect(v.schluessel, '2026-10-27T09:00:00Z');
      await g.repo.vorkommenAbsagen(v);
      await g.repo.vorkommenAendern(v, zeit(titel: 'Spezial', start: v.startWand, ende: v.endeWand));
      final a = await g.ausnahmen();
      expect(a, hasLength(1));
      expect(a.single.id, ausnahmeId(id, v.schluessel));
      expect(a.single.abgesagt, isFalse);
      expect(a.single.titel, 'Spezial');
      expect(a.single.start, isNull);
      // beide Änderungen vor dem Senden verschmolzen: eine Op mit baseRev 0
      final ops = await g.ausgang();
      expect(ops, hasLength(1));
      expect(ops.single.entityId, a.single.id);
      expect(ausnahmeId(id, v.schluessel), ausnahmeId(id, v.schluessel));
      expect(ausnahmeId(id, v.schluessel), isNot(ausnahmeId(id, '2026-11-03T09:00:00Z')));
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(a.single.id), isTrue);
    });

    test('nur dieses verschieben: Beginn und Ende werden als Zeitpunkte überschrieben', () async {
      final (_, v, _) = await serie();
      await g.repo.vorkommenAendern(v, zeit(start: tag(2026, 10, 28, 15), ende: tag(2026, 10, 28, 16)));
      final a = (await g.ausnahmen()).single;
      expect(a.start, '2026-10-28T14:00:00Z');
      expect(a.ende, '2026-10-28T15:00:00Z');
      expect(a.titel, isNull);
      await g.repo.vorkommenZuruecksetzen(v);
      final z = (await g.ausnahmen()).single;
      expect([z.abgesagt, z.titel, z.start, z.ende, z.ort], [false, null, null, null, null]);
    });

    test('dieses und folgende ändern: alte Serie endet davor, neue beginnt, Ausnahmen ziehen mit um', () async {
      final (id, v, daten) = await serie();
      final spaeter = vorkommenImFenster(termine: daten.termine, ausnahmen: daten.ausnahmen, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 12, 1), jetzt: tag(2026, 10, 19))[3];
      await g.repo.vorkommenAbsagen(spaeter); // 10.11.
      final neu = await g.repo.folgendeAendern(v, zeit(titel: 'Neu ab 27.10.', start: v.startWand, ende: v.endeWand, rrule: 'FREQ=WEEKLY;BYDAY=TU', teilnehmer: {'u-kind'}));
      expect(neu, isNotNull);
      final alt = (await g.termin(id))!;
      expect(alt.rrule, 'FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T085959Z');
      final neuT = (await g.termin(neu!))!;
      expect(neuT.titel, 'Neu ab 27.10.');
      expect(neuT.startUtc!.toUtc(), DateTime.utc(2026, 10, 27, 9)); // 10 Uhr Berlin nach der Umstellung
      expect(neuT.ownerId, 'u-ich');
      final a = (await g.ausnahmen()).where((x) => x.terminId == neu).toList();
      expect(a, hasLength(1));
      expect(a.single.originalStart, spaeter.schluessel);
      expect(a.single.abgesagt, isTrue);
      // die Ausnahme der alten Serie bleibt als leere Zeile stehen (nicht gelöscht: ihre feste ID wäre sonst am Server verbraucht)
      final altA = (await g.ausnahmen()).where((x) => x.terminId == id).single;
      expect([altA.abgesagt, altA.titel, altA.start, altA.ende, altA.ort], [false, null, null, null, null]);
      expect((await g.teilnehmer()).where((z) => z.terminId == neu).map((z) => z.userId), ['u-kind']);
      final nach = await laden();
      final tage = vorkommenImFenster(termine: nach.termine, ausnahmen: nach.ausnahmen, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 11, 20), jetzt: tag(2026, 10, 19));
      expect(tage.map((x) => '${x.titel}@${x.startWand.day}').toList(), ['Training@20', 'Neu ab 27.10.@27', 'Neu ab 27.10.@3', 'Neu ab 27.10.@17']);
    });

    test('dieses und folgende bei COUNT: Rest der Anzahl geht auf die neue Serie über', () async {
      final (id, v, _) = await serie(rrule: 'FREQ=WEEKLY;BYDAY=TU;COUNT=6');
      final neu = await g.repo.folgendeAendern(v, zeit(titel: 'Neu', start: v.startWand, ende: v.endeWand, rrule: 'FREQ=WEEKLY;BYDAY=TU;COUNT=6'));
      expect((await g.termin(id))!.rrule, 'FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T085959Z');
      expect((await g.termin(neu!))!.rrule, 'FREQ=WEEKLY;BYDAY=TU;COUNT=5');
    });

    test('dieses und folgende beim ersten Vorkommen ändert die ganze Serie; Löschen löscht sie', () async {
      final (id, v, _) = await serie(nr: 0);
      expect(g.repo.istErstes(v), isTrue);
      expect(await g.repo.folgendeAendern(v, zeit(titel: 'Anders', rrule: 'FREQ=WEEKLY;BYDAY=TU')), isNull);
      expect((await g.termin(id))!.titel, 'Anders');
      expect(await g.alleTermine(), hasLength(1));
      await g.repo.folgendeLoeschen(v);
      expect(await g.alleTermine(), isEmpty);
    });

    test('dieses und folgende löschen: die Serie endet davor, Ausnahmen danach werden zurückgesetzt (nicht gelöscht) und bleiben wiederverwendbar', () async {
      final (id, v, daten) = await serie();
      final spaeter = vorkommenImFenster(termine: daten.termine, ausnahmen: daten.ausnahmen, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 12, 1), jetzt: tag(2026, 10, 19))[3];
      await g.repo.vorkommenAbsagen(spaeter);
      await g.repo.folgendeLoeschen(v);
      expect((await g.termin(id))!.rrule, 'FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T085959Z');
      final nachher = await g.ausnahmen();
      expect(nachher, hasLength(1));
      expect([nachher.single.abgesagt, nachher.single.titel], [false, null]);
      // dasselbe Vorkommen noch einmal ändern: dieselbe Zeile (dieselbe ID), keine zweite
      await g.repo.vorkommenAbsagen(spaeter);
      final wieder = await g.ausnahmen();
      expect(wieder, hasLength(1));
      expect(wieder.single.id, nachher.single.id);
      expect(wieder.single.abgesagt, isTrue);
    });

    Vorkommen vorkommenMit(KalenderDaten d, String schluessel) =>
        vorkommenImFenster(termine: d.termine, ausnahmen: d.ausnahmen, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 12, 1), jetzt: tag(2026, 10, 19)).firstWhere((x) => x.schluessel == schluessel);

    test('verschobenes Vorkommen: nur den Titel ändern lässt die Verschiebung bestehen; zurück auf die ursprüngliche Zeit hebt sie auf', () async {
      final (_, v, _) = await serie();
      await g.repo.vorkommenAendern(v, zeit(start: tag(2026, 10, 28, 15), ende: tag(2026, 10, 28, 16)));
      final v2 = vorkommenMit(await laden(), v.schluessel);
      expect(v2.startWand, tag(2026, 10, 28, 15));
      expect(v2.originalStartWand, tag(2026, 10, 27, 10));
      expect(v2.originalEndeWand, tag(2026, 10, 27, 11));
      // der Editor zeigt die verschobene Zeit: nur der Titel ändert sich
      await g.repo.vorkommenAendern(v2, zeit(titel: 'Sondertraining', start: v2.startWand, ende: v2.endeWand));
      var a = (await g.ausnahmen()).single;
      expect([a.titel, a.start, a.ende], ['Sondertraining', '2026-10-28T14:00:00Z', '2026-10-28T15:00:00Z']);
      // zurück auf die ursprüngliche Zeit und den Serientitel: keine Überschreibung mehr
      await g.repo.vorkommenAendern(v2, zeit(titel: 'Training', start: v2.originalStartWand, ende: v2.originalEndeWand));
      a = (await g.ausnahmen()).single;
      expect([a.titel, a.start, a.ende, a.abgesagt], [null, null, null, false]);
    });

    test('dieses und folgende bei einem verschobenen Vorkommen: Serie endet vor dem URSPRÜNGLICHEN Beginn, COUNT zählt bis dahin', () async {
      final (id, v, _) = await serie(rrule: 'FREQ=WEEKLY;BYDAY=TU;COUNT=6');
      await g.repo.vorkommenAendern(v, zeit(start: tag(2026, 10, 30, 8), ende: tag(2026, 10, 30, 9)));
      final v2 = vorkommenMit(await laden(), v.schluessel);
      expect(v2.startWand.day, 30);
      final neu = await g.repo.folgendeAendern(v2, zeit(titel: 'Neu', start: v2.startWand, ende: v2.endeWand, rrule: 'FREQ=WEEKLY;BYDAY=TU;COUNT=6'));
      expect((await g.termin(id))!.rrule, 'FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T085959Z', reason: 'UNTIL vor dem ursprünglichen 27.10., nicht vor dem verschobenen 30.10.');
      expect((await g.termin(neu!))!.rrule, 'FREQ=WEEKLY;BYDAY=TU;COUNT=5');
      // die verschobene Ausnahme gehört zur alten Serie und wird zurückgesetzt (der neue Beginn ist ein anderer)
      expect((await g.ausnahmen()).every((x) => x.terminId == id && x.titel == null && x.start == null), isTrue);
    });

    test('dieses und folgende löschen bei einem verschobenen Vorkommen: UNTIL vor dem ursprünglichen Beginn', () async {
      final (id, v, _) = await serie();
      await g.repo.vorkommenAendern(v, zeit(start: tag(2026, 10, 30, 8), ende: tag(2026, 10, 30, 9)));
      final v2 = vorkommenMit(await laden(), v.schluessel);
      await g.repo.folgendeLoeschen(v2);
      expect((await g.termin(id))!.rrule, 'FREQ=WEEKLY;BYDAY=TU;UNTIL=20261027T085959Z');
    });

    test('alle ändern: nur die Uhrzeit: die Absage zieht mit; Regel geändert: Ausnahmen werden zurückgesetzt und gemeldet', () async {
      final (id, v, _) = await serie();
      await g.repo.vorkommenAbsagen(v); // 27.10.
      final verw = await g.repo.alleAendern(id, zeit(start: tag(2026, 10, 20, 11), ende: tag(2026, 10, 20, 12), rrule: 'FREQ=WEEKLY;BYDAY=TU'));
      expect(verw, 0);
      final nach = await laden();
      final tage = vorkommenImFenster(termine: nach.termine, ausnahmen: nach.ausnahmen, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 11, 11), jetzt: tag(2026, 10, 19));
      expect(tage.map((x) => '${x.startWand.day}@${x.startWand.hour}').toList(), ['20@11', '3@11', '10@11'], reason: 'der 27. bleibt abgesagt, jetzt um 11 Uhr');
      expect((await g.ausnahmen()).where((a) => a.abgesagt).single.originalStart, '2026-10-27T10:00:00Z');
      // Regel geändert: bestehende Absage gilt nicht mehr, der Aufrufer erfährt es
      final verw2 = await g.repo.alleAendern(id, zeit(start: tag(2026, 10, 20, 11), ende: tag(2026, 10, 20, 12), rrule: 'FREQ=DAILY'));
      expect(verw2, 1);
      expect((await g.ausnahmen()).every((a) => !a.abgesagt && a.titel == null), isTrue);
      // anderer Starttag: ebenfalls zurückgesetzt
      await g.repo.vorkommenAbsagen(vorkommenMit(await laden(), '2026-10-27T10:00:00Z'));
      final verw3 = await g.repo.alleAendern(id, zeit(start: tag(2026, 10, 21, 11), ende: tag(2026, 10, 21, 12), rrule: 'FREQ=DAILY'));
      expect(verw3, 1);
    });

    test('Zeitzonen-Daten fehlen: Anlegen, Ändern und Serien teilen werden gesperrt, Absagen (nur Schlüssel) nicht', () async {
      final (id, v, _) = await serie();
      zeitzonenBereitUeberschreibung = false;
      addTearDown(() => zeitzonenBereitUeberschreibung = null);
      expect(g.repo.anlegen(zeit()), throwsA(isA<ZeitzonenFehlen>()));
      expect(g.repo.alleAendern(id, zeit(titel: 'x', rrule: 'FREQ=WEEKLY;BYDAY=TU')), throwsA(isA<ZeitzonenFehlen>()));
      expect(g.repo.vorkommenAendern(v, zeit(titel: 'x')), throwsA(isA<ZeitzonenFehlen>()));
      expect(g.repo.folgendeAendern(v, zeit(titel: 'x', rrule: 'FREQ=WEEKLY;BYDAY=TU')), throwsA(isA<ZeitzonenFehlen>()));
      expect((await g.alleTermine()).single.titel, 'Training');
      zeitzonenBereitUeberschreibung = null;
      await g.repo.anlegen(zeit(titel: 'Wieder da'));
      expect(await g.alleTermine(), hasLength(2));
    });

    test('Serie teilen: der neue Teil gehört der Person, die ihn anlegt (nicht dem alten Ersteller)', () async {
      final (id, v, _) = await serie();
      await g.db.customStatement("UPDATE termine SET owner_id = 'u-kind'");
      final neu = await g.repo.folgendeAendern(vorkommenMit(await laden(), v.schluessel), zeit(titel: 'Neu', start: v.startWand, ende: v.endeWand, rrule: 'FREQ=WEEKLY;BYDAY=TU'));
      expect((await g.termin(id))!.ownerId, 'u-kind');
      expect((await g.termin(neu!))!.ownerId, 'u-ich');
    });
  });

  group('Rechte der Oberfläche', () {
    Termin termin(String? owner) => Termin(
      id: 't',
      titel: 'x',
      ort: '',
      beschreibung: '',
      ganztaegig: true,
      startUtc: null,
      endUtc: null,
      tzid: null,
      startDate: '2026-10-20',
      endDate: '2026-10-21',
      rrule: null,
      erinnerungMin: null,
      icalUid: null,
      audience: 'family',
      ownerId: owner,
      createdAt: DateTime.utc(2026),
      rev: 1,
    );

    test('Eltern alles, Kinder nur eigene und nur Familie', () {
      for (final r in [Role.admin, Role.parent]) {
        final rechte = TerminRechte(r, 'u1');
        expect(rechte.darfAnlegen && rechte.darfAendern(termin('u2')) && rechte.darfFreigabeAendern, isTrue);
        expect(rechte.freigaben, TerminSicht.values);
      }
      const kind = TerminRechte(Role.child, 'u1');
      expect(kind.darfAnlegen, isTrue);
      expect(kind.darfAendern(termin('u1')), isTrue);
      expect(kind.darfAendern(termin('u2')), isFalse);
      expect(kind.darfAendern(termin(null)), isFalse);
      expect(kind.darfFreigabeAendern, isFalse);
      expect(kind.freigaben, [TerminSicht.family]);
    });
  });

  group('Abgleich (SyncStore)', () {
    SyncChange termin(String id, int rev, {String titel = 'Zahnarzt'}) => SyncChange(
      rev: rev,
      entity: 'termin',
      id: id,
      tombstone: false,
      hidden: false,
      fields: {
        'titel': titel,
        'ort': '',
        'beschreibung': '',
        'ganztaegig': false,
        'startUtc': '2026-10-20T08:00:00.000Z',
        'endUtc': '2026-10-20T09:00:00.000Z',
        'tzid': 'Europe/Berlin',
        'startDate': null,
        'endDate': null,
        'rrule': null,
        'erinnerungMin': 30,
        'icalUid': null,
        'audience': 'family',
        'ownerId': 'u-mama',
        'createdAt': '2026-10-19T08:00:00.000Z',
      },
    );

    test('Änderungsstrom legt Termin, Teilnehmer und Ausnahme an; hidden/Tombstone des Termins entfernt die untergeordneten mit', () async {
      await g.store.uebernehmen(
        antwort(
          rev: 4,
          changes: [
            termin('t-1', 1),
            const SyncChange(rev: 2, entity: 'termin_teilnehmer', id: 'tn-1', tombstone: false, hidden: false, fields: {'terminId': 't-1', 'userId': 'u-kind', 'createdAt': '2026-10-19T08:00:00.000Z'}),
            const SyncChange(
              rev: 3,
              entity: 'termin_ausnahmen',
              id: 'a-1',
              tombstone: false,
              hidden: false,
              fields: {'terminId': 't-1', 'originalStart': '2026-10-27T09:00:00Z', 'abgesagt': true, 'titel': null, 'start': null, 'ende': null, 'ort': null, 'createdAt': '2026-10-19T08:00:00.000Z'},
            ),
          ],
        ),
        const [],
      );
      final t = (await g.termin('t-1'))!;
      expect([t.erinnerungMin, t.ownerId, t.rev], [30, 'u-mama', 1]);
      expect(await g.teilnehmer(), hasLength(1));
      expect((await g.ausnahmen()).single.abgesagt, isTrue);
      await g.store.uebernehmen(antwort(rev: 5, changes: const [SyncChange(rev: 5, entity: 'termin', id: 't-1', tombstone: true, hidden: true, fields: {})]), const []);
      expect(await g.alleTermine(), isEmpty);
      expect(await g.teilnehmer(), isEmpty);
      expect(await g.ausnahmen(), isEmpty);
    });

    test('abgelehntes Anlegen eines Teilnehmers mit not_found (gibt es schon): kein Hinweis "gelöscht", die lokale Kopie weicht', () async {
      final id = await g.repo.anlegen(zeit(teilnehmer: {'u-kind'}));
      final gesendet = await g.store.naechsteOps(50);
      final tn = gesendet.firstWhere((o) => o.entity == 'termin_teilnehmer');
      final bericht = await g.store.uebernehmen(antwort(rev: 2, acked: [gesendet.first.opId], rejected: [SyncRejected(tn.opId, 'not_found')]), gesendet);
      expect(bericht.hinweise, isEmpty);
      expect(await g.teilnehmer(), isEmpty);
      expect(await g.termin(id), isNotNull);
    });

    test('Konflikt im Titel: Stand des Servers gilt, Hinweis nennt den Termin; abgelehnte Ausnahme an gelöschtem Termin: Hinweis', () async {
      await g.store.uebernehmen(antwort(rev: 1, changes: [termin('t-1', 1)]), const []);
      await g.repo.alleAendern('t-1', zeit(titel: 'Eigener Titel', start: tag(2026, 10, 20, 10), ende: tag(2026, 10, 20, 11)));
      final gesendet = await g.store.naechsteOps(50);
      final op = gesendet.firstWhere((o) => o.entity == 'termin');
      final bericht = await g.store.uebernehmen(
        antwort(rev: 3, acked: [op.opId], conflicts: [SyncConflict(opId: op.opId, entity: 'termin', id: 't-1', fields: const {'titel': 'Vom Server'}, serverRev: 2)]),
        gesendet,
      );
      expect((await g.termin('t-1'))!.titel, 'Vom Server');
      expect(bericht.hinweise.single.text, contains('Termin „Vom Server“'));

      await g.repo.vorkommenAbsagen(Vorkommen(
        termin: (await g.termin('t-1'))!,
        schluessel: '2026-10-27T09:00:00Z',
        ganztaegig: false,
        startWand: tag(2026, 10, 27, 10),
        endeWand: tag(2026, 10, 27, 11),
        startUtc: DateTime.utc(2026, 10, 27, 9),
        titel: 'x',
        ort: '',
        geaendert: false,
        serie: true,
        originalStartWand: tag(2026, 10, 27, 10),
        originalEndeWand: tag(2026, 10, 27, 11),
        originalStartUtc: DateTime.utc(2026, 10, 27, 9),
      ));
      final neu = await g.store.naechsteOps(50);
      final a = neu.firstWhere((o) => o.entity == 'termin_ausnahmen');
      final b2 = await g.store.uebernehmen(antwort(rev: 4, rejected: [SyncRejected(a.opId, 'parent_deleted')]), neu);
      expect(b2.hinweise.single.text, contains('Der Termin wurde gelöscht'));
      expect(await g.ausnahmen(), isEmpty);
    });
  });

  group('Zwei Geräte gegen den Fake-Server', () {
    late FakeServer server;
    late FakeSyncServer fake;

    Future<(Geraet, SyncEngine)> geraet(String ich, String geraetId) async {
      final d = Geraet(ich);
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

    test('Termin mit Teilnehmer und Absage kommt auf dem zweiten Gerät an; Löschen räumt dort alles ab', () async {
      final (a, ea) = await geraet('u-a', fixDevice);
      final (b, eb) = await geraet('u-b', 'geraet-b');
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      final id = await a.repo.anlegen(zeit(rrule: 'FREQ=WEEKLY;BYDAY=TU', teilnehmer: {'u-b'}));
      final t = (await a.termin(id))!;
      final v = vorkommenImFenster(termine: [t], ausnahmen: const {}, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 11, 1), jetzt: tag(2026, 10, 19))[1];
      await a.repo.vorkommenAbsagen(v);
      expect((await ea.abgleichen()).ok, isTrue);
      expect((await eb.abgleichen()).ok, isTrue);
      expect((await b.termin(id))?.rrule, 'FREQ=WEEKLY;BYDAY=TU');
      expect((await b.teilnehmer()).single.userId, 'u-b');
      expect((await b.ausnahmen()).single.originalStart, v.schluessel);
      expect((await a.termin(id))!.rev, greaterThan(0));
      // b ändert den Titel, a gleichzeitig den Ort: beide Felder bleiben
      await b.repo.alleAendern(id, zeit(titel: 'Neu', start: tag(2026, 10, 20, 10), ende: tag(2026, 10, 20, 11), rrule: 'FREQ=WEEKLY;BYDAY=TU', teilnehmer: {'u-b'}));
      await a.store.aendern('termin', id, {'ort': 'Halle'});
      await eb.abgleichen();
      await ea.abgleichen();
      await eb.abgleichen();
      expect([(await a.termin(id))!.titel, (await a.termin(id))!.ort], ['Neu', 'Halle']);
      expect([(await b.termin(id))!.titel, (await b.termin(id))!.ort], ['Neu', 'Halle']);
      // Löschen
      await a.repo.alleLoeschen(id);
      await ea.abgleichen();
      await eb.abgleichen();
      expect(await b.alleTermine(), isEmpty);
      expect(await b.teilnehmer(), isEmpty);
      expect(await b.ausnahmen(), isEmpty);
    });

    test('dieselbe Ausnahme von zwei Geräten: eine Zeile, der erste Stand gilt, kein Fehler', () async {
      final (a, ea) = await geraet('u-a', fixDevice);
      final (b, eb) = await geraet('u-b', 'geraet-b');
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      final id = await a.repo.anlegen(zeit(rrule: 'FREQ=WEEKLY;BYDAY=TU'));
      await ea.abgleichen();
      await eb.abgleichen();
      final v = vorkommenImFenster(termine: await b.alleTermine(), ausnahmen: const {}, vonWand: tag(2026, 10, 20), bisWand: tag(2026, 11, 1), jetzt: tag(2026, 10, 19))[1];
      await a.repo.vorkommenAbsagen(v);
      await b.repo.vorkommenAendern(v, zeit(titel: 'Anders', start: v.startWand, ende: v.endeWand));
      await ea.abgleichen();
      final r = await eb.abgleichen();
      expect(r.ok, isTrue);
      await ea.abgleichen();
      expect(await a.ausnahmen(), hasLength(1));
      expect(await b.ausnahmen(), hasLength(1));
      expect((await a.ausnahmen()).single.abgesagt, (await b.ausnahmen()).single.abgesagt);
      expect((await a.ausnahmen()).single.id, ausnahmeId(id, v.schluessel));
      expect(fake.zeilen.values.where((z) => z.entity == 'termin_ausnahmen'), hasLength(1));
    });
  });

  test('Familienzone ist fest Europe/Berlin', () {
    expect(kFamilienZone, 'Europe/Berlin');
    expect(syncEntities.keys, containsAll(['termin', 'termin_teilnehmer', 'termin_ausnahmen']));
  });
}
