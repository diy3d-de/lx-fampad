// Standard-Erinnerung nachtragen: Kandidaten (nur Zukunft, Serien, Rechte, nie Geburtstage), einmaliger Lauf mit Marke, Stapel, nie
// überschreiben, was gesetzt ist; danach plant die Erinnerungs-Planung die neuen Erinnerungen (Fenster 300).
import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_nachtrag.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_planung.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

const ich = 'u-ich';
const andere = 'u-andere';
final jetzt = DateTime.utc(2026, 10, 27, 8);
final heute = DateTime.utc(2026, 10, 27);

Termin termin(
  String id, {
  int? erinnerung,
  DateTime? start,
  bool ganztaegig = false,
  String? startDate,
  String? rrule,
  String? owner = ich,
  String? uid,
}) => Termin(
  id: id,
  titel: 'T $id',
  ort: '',
  beschreibung: '',
  ganztaegig: ganztaegig,
  startUtc: ganztaegig ? null : (start ?? DateTime.utc(2026, 11, 3, 9)),
  endUtc: ganztaegig ? null : (start ?? DateTime.utc(2026, 11, 3, 9)).add(const Duration(hours: 1)),
  tzid: ganztaegig ? null : 'Europe/Berlin',
  startDate: startDate,
  endDate: startDate,
  rrule: rrule,
  erinnerungMin: erinnerung,
  icalUid: uid,
  farbe: null,
  audience: 'family',
  ownerId: owner,
  createdAt: DateTime.utc(2026, 1, 1),
  rev: 1,
);

Set<String> ids(List<Termin> l) => {for (final t in l) t.id};

KalenderDaten daten(List<Termin> t) => KalenderDaten(termine: t);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  group('Kandidaten', () {
    test('nur Zukunft ohne Erinnerung; Vergangenes, Gesetztes und Geburtstage bleiben unberührt', () {
      final d = daten([
        termin('zukunft'),
        termin('vergangen', start: DateTime.utc(2026, 10, 1, 9)),
        termin('gesetzt', erinnerung: 15),
        termin('keine-bewusst-0', erinnerung: 0),
        termin('bewusst-keine', erinnerung: -1),
        termin('ganz-heute', ganztaegig: true, startDate: '2026-10-27'),
        termin('ganz-gestern', ganztaegig: true, startDate: '2026-10-26'),
        termin('geburtstag', ganztaegig: true, startDate: '2027-01-05', rrule: 'FREQ=YEARLY', uid: 'lxfampad-geb-2000-00000000-0000-4000-8000-000000000001'),
      ]);
      expect(ids(nachtragKandidaten(daten: d, ich: ich, rolle: Role.parent, jetzt: jetzt, heute: heute)), {'zukunft', 'ganz-heute'});
    });

    test('Serien: laufend ja, mit UNTIL in der Vergangenheit nein', () {
      final d = daten([
        termin('offen', start: DateTime.utc(2025, 1, 1, 9), rrule: 'FREQ=WEEKLY'),
        termin('bis-spaeter', start: DateTime.utc(2025, 1, 1, 9), rrule: 'FREQ=WEEKLY;UNTIL=20261231T000000Z'),
        termin('bis-vorbei', start: DateTime.utc(2025, 1, 1, 9), rrule: 'FREQ=WEEKLY;UNTIL=20260601T000000Z'),
      ]);
      expect(ids(nachtragKandidaten(daten: d, ich: ich, rolle: Role.parent, jetzt: jetzt, heute: heute)), {'offen', 'bis-spaeter'});
    });

    test('Rechte und Betroffene: Kinder nur Eigenes, fremde Termine ohne Teilnahme nie', () {
      final d = daten([termin('meiner'), termin('fremd', owner: andere)]);
      expect(ids(nachtragKandidaten(daten: d, ich: ich, rolle: Role.child, jetzt: jetzt, heute: heute)), {'meiner'});
      expect(ids(nachtragKandidaten(daten: d, ich: ich, rolle: Role.parent, jetzt: jetzt, heute: heute)), {'meiner'}, reason: 'fremder Termin ohne Teilnahme: nicht meiner');
      final mitTeilnahme = KalenderDaten(
        termine: d.termine,
        teilnehmer: {
          'fremd': [TerminTeilnehmerZeile(id: 'x', terminId: 'fremd', userId: ich, rev: 1)],
        },
      );
      expect(ids(nachtragKandidaten(daten: mitTeilnahme, ich: ich, rolle: Role.parent, jetzt: jetzt, heute: heute)), {'meiner', 'fremd'});
      expect(ids(nachtragKandidaten(daten: mitTeilnahme, ich: ich, rolle: Role.child, jetzt: jetzt, heute: heute)), {'meiner'}, reason: 'Kind darf fremden Termin nicht ändern');
      expect(nachtragKandidaten(daten: d, ich: null, rolle: Role.parent, jetzt: jetzt, heute: heute), isEmpty);
    });
  });

  group('Lauf', () {
    late AppDatabase db;
    late SyncStore store;
    var geaendert = 0;

    setUp(() async {
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      store = SyncStore(db);
      geaendert = 0;
    });
    tearDown(() => db.close());

    Future<void> anlegen(String id, {int? erinnerung}) => store.aendern('termin', id, {
      'titel': 'T $id',
      'ort': '',
      'beschreibung': '',
      'ganztaegig': false,
      'startUtc': '2026-11-03T09:00:00.000Z',
      'endUtc': '2026-11-03T10:00:00.000Z',
      'tzid': 'Europe/Berlin',
      'audience': 'family',
      'erinnerungMin': erinnerung,
    }, nurLokal: {'createdAt': '2026-01-01T00:00:00.000Z', 'ownerId': ich});

    Future<KalenderDaten> lesen() async => KalenderDaten(termine: await db.select(db.termine).get());

    Future<int> lauf({int? standard = 60}) async => nachtragAusfuehren(
      db: db,
      store: store,
      daten: await lesen(),
      ich: ich,
      rolle: Role.parent,
      standardVorlauf: standard,
      jetzt: jetzt,
      beiAenderung: () => geaendert++,
    );

    test('trägt 60 nach, lässt Gesetztes unberührt, ist idempotent und setzt die Marke', () async {
      await anlegen('a');
      await anlegen('b', erinnerung: 15);
      await anlegen('c', erinnerung: -1); // bewusst keine: auch von einem zweiten Gerät nie überschrieben
      expect(await lauf(), 1);
      final t = {for (final x in (await lesen()).termine) x.id: x.erinnerungMin};
      expect(t, {'a': 60, 'b': 15, 'c': -1});
      expect(geaendert, 1);
      expect(await db.metaLesen(nachtragMarke(ich)), '1');
      // nur die geänderte Zeile im Ausgang (a), Feld erinnerungMin
      final ausgang = await db.select(db.outbox).get();
      expect(ausgang.where((o) => o.entityId == 'a'), isNotEmpty);
      expect(ausgang.where((o) => o.entityId == 'b').where((o) => o.fieldsJson.contains('erinnerungMin')).where((o) => o.fieldsJson.contains('60')), isEmpty);
      // ein bewusstes "Keine" danach wird nie wieder überschrieben
      await store.aendern('termin', 'a', {'erinnerungMin': -1});
      expect(await lauf(), 0);
      expect((await lesen()).termine.firstWhere((x) => x.id == 'a').erinnerungMin, -1);
      // ohne Marke (zweites Gerät): -1 bleibt trotzdem unberührt
      await db.customStatement("delete from sync_meta where key = '${nachtragMarke(ich)}'");
      expect(await lauf(), 0);
      expect((await lesen()).termine.firstWhere((x) => x.id == 'a').erinnerungMin, -1);
    });

    test('Standard "Keine": nichts nachtragen, Marke trotzdem gesetzt', () async {
      await anlegen('a');
      expect(await lauf(standard: null), 0);
      expect((await lesen()).termine.single.erinnerungMin, isNull);
      expect(await db.metaLesen(nachtragMarke(ich)), '1');
      expect(await lauf(), 0, reason: 'auch eine spätere Änderung des Standards trägt nicht mehr nach');
    });

    test('mehrere hundert Termine in Stapeln zu 50', () async {
      for (var i = 0; i < 420; i++) {
        await anlegen('t$i');
      }
      expect(await lauf(), 420);
      final termine = (await lesen()).termine;
      expect(termine.every((t) => t.erinnerungMin == 60), isTrue);
      expect(await lauf(), 0);
    });

    test('danach plant die Planung die neuen Erinnerungen (Fenster 300)', () async {
      for (var i = 0; i < 350; i++) {
        await store.aendern('termin', 'p$i', {
          'titel': 'P$i',
          'ort': '',
          'beschreibung': '',
          'ganztaegig': false,
          'startUtc': DateTime.utc(2026, 11, 1).add(Duration(hours: i + 2)).toIso8601String(),
          'endUtc': DateTime.utc(2026, 11, 1).add(Duration(hours: i + 3)).toIso8601String(),
          'tzid': 'Europe/Berlin',
          'audience': 'family',
          'erinnerungMin': null,
        }, nurLokal: {'createdAt': '2026-01-01T00:00:00.000Z', 'ownerId': ich});
      }
      final vorher = planeErinnerungen(daten: await lesen(), ich: ich, jetzt: jetzt);
      expect(vorher, isEmpty);
      await lauf();
      final nachher = planeErinnerungen(daten: await lesen(), ich: ich, jetzt: jetzt);
      expect(nachher.where((e) => e.id != kAuslaufHinweisPlanId), hasLength(kErinnerungFenster), reason: 'volles Fenster (300), nicht mehr');
      // eine Stunde vor dem Beginn
      expect(nachher.first.zeit, DateTime.utc(2026, 11, 1, 1));
    });
  });

  group('Einstellung', () {
    test('Standard 60, "Keine" ist ein eigener Wert, unlesbar = Standard', () async {
      Future<int?> lesenMit(Map<String, String> werte) async {
        final s = MemoryErinnerungSpeicher()..daten.addAll(werte);
        final c = ProviderContainer(overrides: [erinnerungSpeicherProvider.overrideWithValue(s)]);
        addTearDown(c.dispose);
        c.read(erinnerungEinstellungenProvider);
        await c.read(erinnerungEinstellungenProvider.notifier).bereit;
        return c.read(erinnerungEinstellungenProvider).standardVorlauf;
      }

      expect(await lesenMit({}), 60);
      expect(await lesenMit({'erinnerung_vorlauf': ''}), isNull);
      expect(await lesenMit({'erinnerung_vorlauf': '5'}), 5);
      expect(await lesenMit({'erinnerung_vorlauf': '7'}), 60);
    });
  });
}
