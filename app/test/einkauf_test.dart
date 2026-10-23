// Einkaufsliste: Logik (Kategorie-Vorschlag, Gruppierung, "Zuletzt gekauft"), Repository (Kategorie, Vorlage) und Abgleich mit zwei Geräten.
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/lists/einkauf_logik.dart';
import 'package:lx_fampad/data/lists/list_repository.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

Listeneintrag eintrag(String text, {String? kategorie, DateTime? erledigt, int n = 0, double position = 0}) => Listeneintrag(
  id: 'id-$text-$n',
  listId: 'l1',
  inhalt: text,
  assigneeId: null,
  doneAt: erledigt,
  category: kategorie,
  position: position,
  createdAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: n)),
  rev: 1,
);

class Geraet {
  final AppDatabase db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  late final SyncStore store;
  late final ListenRepository repo;
  var geaendert = 0;
  var _n = 0;

  Geraet(String ich, String praefix) {
    store = SyncStore(db);
    repo = ListenRepository(
      db: db,
      store: store,
      ich: () => ich,
      beiAenderung: () => geaendert++,
      jetzt: () => DateTime.utc(2026, 10, 19, 8),
      neueId: () => '$praefix-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}',
    );
  }

  Future<List<Listeneintrag>> eintraege(String listId) =>
      (db.select(db.listenEintraege)
            ..where((e) => e.listId.equals(listId))
            ..orderBy([(e) => OrderingTerm.asc(e.position)]))
          .get();
  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Kategorie-Vorschlag', () {
    test('Stichwort-Tabelle: gängige Artikel, Groß-/Kleinschreibung egal, Wortteile in Zusammensetzungen', () {
      expect(schlageKategorieVor('Äpfel'), EinkaufKategorie.obstGemuese);
      expect(schlageKategorieVor('rote PAPRIKA'), EinkaufKategorie.obstGemuese);
      expect(schlageKategorieVor('Vollkornbrot'), EinkaufKategorie.brotBackwaren);
      expect(schlageKategorieVor('Milch 1,5 %'), EinkaufKategorie.milchKuehlregal);
      expect(schlageKategorieVor('Eier'), EinkaufKategorie.milchKuehlregal);
      expect(schlageKategorieVor('Hähnchenbrust'), EinkaufKategorie.fleischFisch);
      expect(schlageKategorieVor('Eis'), EinkaufKategorie.tiefkuehl);
      expect(schlageKategorieVor('Reis'), EinkaufKategorie.vorratKonserven, reason: 'Wort "eis" passt nur ganz, "reis" ist ein eigenes Stichwort');
      expect(schlageKategorieVor('Mineralwasser'), EinkaufKategorie.getraenke);
      expect(schlageKategorieVor('Spülmittel'), EinkaufKategorie.haushaltDrogerie);
    });

    test('ohne Treffer: zuletzt gewählte Kategorie desselben Namens, sonst Sonstiges', () {
      final vorhanden = [
        eintrag('Hundeleckerli', kategorie: 'vorrat_konserven', n: 1),
        eintrag('hundeleckerli', kategorie: 'haushalt_drogerie', n: 2),
        eintrag('Geschenkpapier', n: 3),
      ];
      expect(schlageKategorieVor('HUNDELECKERLI', vorhandene: vorhanden), EinkaufKategorie.haushaltDrogerie);
      expect(schlageKategorieVor('Geschenkpapier', vorhandene: vorhanden), EinkaufKategorie.sonstiges);
      expect(schlageKategorieVor('   '), EinkaufKategorie.sonstiges);
    });

    test('unbekannte oder fehlende Kennung gilt als Sonstiges', () {
      expect(EinkaufKategorie.von(null), EinkaufKategorie.sonstiges);
      expect(EinkaufKategorie.von('neue_kategorie'), EinkaufKategorie.sonstiges);
      expect(EinkaufKategorie.von('getraenke'), EinkaufKategorie.getraenke);
    });

    test('Reihenfolge der Kategorien ist der Gang, Kennungen sind eindeutig', () {
      expect(EinkaufKategorie.values.first, EinkaufKategorie.obstGemuese);
      expect(EinkaufKategorie.values.last, EinkaufKategorie.sonstiges);
      expect(EinkaufKategorie.values.map((k) => k.wire).toSet().length, EinkaufKategorie.values.length);
    });
  });

  group('Gruppierung', () {
    test('offene Einträge nach Gang, leere Kategorien entfallen, unbekannte unter Sonstiges, Reihenfolge der Liste innerhalb', () {
      final alle = [
        eintrag('Wasser', kategorie: 'getraenke', position: 0),
        eintrag('Zeitung', position: 1),
        eintrag('Äpfel', kategorie: 'obst_gemuese', position: 2),
        eintrag('Birnen', kategorie: 'obst_gemuese', position: 1),
        eintrag('Neues', kategorie: 'gibt_es_noch_nicht', position: 3),
        eintrag('Erledigt', kategorie: 'obst_gemuese', erledigt: DateTime.utc(2026, 10, 2)),
      ];
      final g = gruppiereOffene(alle);
      expect(g.map((x) => x.kategorie), [EinkaufKategorie.obstGemuese, EinkaufKategorie.getraenke, EinkaufKategorie.sonstiges]);
      expect(g[0].eintraege.map((e) => e.inhalt), ['Birnen', 'Äpfel']);
      expect(g[2].eintraege.map((e) => e.inhalt), ['Zeitung', 'Neues']);
      expect(erledigteEintraege(alle).map((e) => e.inhalt), ['Erledigt']);
    });
  });

  group('Zuletzt gekauft', () {
    final t = DateTime.utc(2026, 10, 10);
    test('nur abgehakte, gefiltert, Duplikate ohne Groß-/Kleinschreibung zusammen, häufigste zuerst, dann zuletzt', () {
      final alle = [
        eintrag('Milch', kategorie: 'milch_kuehlregal', erledigt: t, n: 1),
        eintrag('milch', kategorie: 'milch_kuehlregal', erledigt: t.add(const Duration(days: 1)), n: 2),
        eintrag('Milchreis', erledigt: t.add(const Duration(days: 9)), n: 3),
        eintrag('Mandeln', erledigt: t.add(const Duration(days: 5)), n: 4),
        eintrag('Mehl', n: 5), // nicht abgehakt
      ];
      final v = zuletztGekauft(alle, 'M');
      expect(v.map((x) => x.name), ['milch', 'Milchreis', 'Mandeln']);
      expect(v.first.anzahl, 2);
      expect(v.first.kategorie, EinkaufKategorie.milchKuehlregal);
      expect(zuletztGekauft(alle, 'milch').map((x) => x.name), ['milch', 'Milchreis']);
      expect(zuletztGekauft(alle, ''), isEmpty);
      expect(zuletztGekauft(alle, 'xyz'), isEmpty);
    });

    test('was schon offen auf der Liste steht, wird nicht noch einmal vorgeschlagen; höchstens 8', () {
      final alle = [for (var i = 0; i < 12; i++) eintrag('Artikel $i', erledigt: t.add(Duration(hours: i)), n: i)];
      expect(zuletztGekauft(alle, 'artikel'), hasLength(8));
      expect(zuletztGekauft(alle, 'artikel').first.name, 'Artikel 11', reason: 'bei gleicher Häufigkeit der zuletzt abgehakte');
      expect(zuletztGekauft(alle, 'artikel', offeneNamen: {'ARTIKEL 11'}).map((x) => x.name), isNot(contains('Artikel 11')));
    });
  });

  group('Repository', () {
    late Geraet g;
    setUp(() => g = Geraet('u-ich', '00000000'));
    tearDown(() => g.db.close());

    test('Eintrag mit Kategorie anlegen, Kategorie ändern und zurücksetzen', () async {
      final l = await g.repo.listeAnlegen(name: 'Einkauf');
      final id = await g.repo.eintragAnlegen(l, 'Äpfel', kategorie: 'obst_gemuese');
      expect((await g.eintraege(l)).single.category, 'obst_gemuese');
      await g.repo.eintragKategorie(id, 'getraenke');
      expect((await g.eintraege(l)).single.category, 'getraenke');
      await g.repo.eintragKategorie(id, null);
      expect((await g.eintraege(l)).single.category, isNull);
      expect(await g.ausgang(), isNotEmpty);
    });

    test('ohne Kategorie schickt der neue Eintrag kein Feld (ältere Server)', () async {
      final l = await g.repo.listeAnlegen(name: 'Einkauf');
      await g.repo.eintragAnlegen(l, 'Zeitung');
      final op = (await g.ausgang()).lastWhere((o) => o.entity == 'list_item');
      expect((jsonDecode(op.fieldsJson) as Map<String, dynamic>).containsKey('category'), isFalse);
    });

    test('Als Vorlage speichern: neue Liste der Art Vorlage mit Texten und Kategorien, ohne Erledigt-Stand und Zuständige', () async {
      final l = await g.repo.listeAnlegen(name: 'Wocheneinkauf', sicht: ListenSicht.parents);
      final a = await g.repo.eintragAnlegen(l, 'Milch', kategorie: 'milch_kuehlregal', zugewiesen: 'u-x');
      await g.repo.eintragAnlegen(l, 'Brot');
      await g.repo.eintragErledigt(a, true);
      final liste = (await g.db.select(g.db.listen).get()).firstWhere((x) => x.id == l);
      final v = await g.repo.alsVorlageSpeichern(liste, name: 'Standard-Einkauf');
      expect(v, isNotNull);
      final vorlage = (await g.db.select(g.db.listen).get()).firstWhere((x) => x.id == v);
      expect([vorlage.name, vorlage.kind, vorlage.audience], ['Standard-Einkauf', 'template', 'parents']);
      final e = await g.eintraege(v!);
      expect(e.map((x) => x.inhalt).toSet(), {'Milch', 'Brot'});
      expect(e.every((x) => x.doneAt == null && x.assigneeId == null), isTrue);
      expect(e.firstWhere((x) => x.inhalt == 'Milch').category, 'milch_kuehlregal');
    });

    test('Leere Liste ergibt keine Vorlage', () async {
      final l = await g.repo.listeAnlegen(name: 'Leer');
      final liste = (await g.db.select(g.db.listen).get()).single;
      expect(await g.repo.alsVorlageSpeichern(liste), isNull);
      expect((await g.db.select(g.db.listen).get()).map((x) => x.id), [l]);
    });

    test('Aus Vorlage übernehmen: schon offene Namen werden übersprungen, neue Einträge oben, erledigte zählen nicht', () async {
      final vorlage = await g.repo.listeAnlegen(name: 'Vorlage', art: ListenArt.template);
      await g.repo.eintragAnlegen(vorlage, 'Milch', kategorie: 'milch_kuehlregal');
      await g.repo.eintragAnlegen(vorlage, 'Brot', kategorie: 'brot_backwaren');
      await g.repo.eintragAnlegen(vorlage, 'Butter', kategorie: 'milch_kuehlregal');
      final ziel = await g.repo.listeAnlegen(name: 'Einkauf');
      final alt = await g.repo.eintragAnlegen(ziel, 'Eier', kategorie: 'milch_kuehlregal');
      await g.repo.eintragAnlegen(ziel, 'milch');
      expect(await g.repo.ausVorlageUebernehmen(ziel, vorlage), 2);
      final e = await g.eintraege(ziel);
      expect(e.map((x) => x.inhalt).toSet(), {'Eier', 'milch', 'Brot', 'Butter'});
      expect(e.firstWhere((x) => x.inhalt == 'Brot').position, lessThan(e.firstWhere((x) => x.id == alt).position), reason: 'neue Einträge oben');
      expect(e.firstWhere((x) => x.inhalt == 'Brot').category, 'brot_backwaren');
      expect(await g.repo.ausVorlageUebernehmen(ziel, vorlage), 0, reason: 'zweites Mal: alles schon da');
      await g.repo.eintragErledigt(alt, true);
      final v2 = await g.repo.listeAnlegen(name: 'V2', art: ListenArt.template);
      await g.repo.eintragAnlegen(v2, 'Eier');
      expect(await g.repo.ausVorlageUebernehmen(ziel, v2), 1);
    });
  });

  group('Abgleich mit zwei Geräten', () {
    late FakeServer server;
    late FakeSyncServer fake;

    Future<(Geraet, SyncEngine)> geraet(String ich, String praefix, String geraetId) async {
      final d = Geraet(ich, praefix);
      final tokens = MemoryTokenStore();
      await tokens.writeTokens(
        StoredTokens(
          accessToken: 'access-1',
          accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
          refreshToken: 'refresh-1',
          refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
          deviceId: geraetId,
        ),
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

    test('Kategorie und Vorlage kommen auf dem zweiten Gerät an; Text und Kategorie gleichzeitig geändert bleiben beide', () async {
      final (a, ea) = await geraet('u-a', '0000000a', fixDevice);
      final (b, eb) = await geraet('u-b', '0000000b', 'geraet-b');
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      final l = await a.repo.listeAnlegen(name: 'Einkauf');
      final i = await a.repo.eintragAnlegen(l, 'Brot', kategorie: 'brot_backwaren');
      final liste = (await a.db.select(a.db.listen).get()).single;
      final v = await a.repo.alsVorlageSpeichern(liste, name: 'Standard');
      expect((await ea.abgleichen()).ok, isTrue);
      expect((await eb.abgleichen()).ok, isTrue);
      expect((await b.eintraege(l)).single.category, 'brot_backwaren');
      expect((await b.db.select(b.db.listen).get()).firstWhere((x) => x.id == v).kind, 'template');
      expect((await b.eintraege(v!)).single.category, 'brot_backwaren');
      // gleichzeitig: a ändert die Kategorie, b den Text
      await a.repo.eintragKategorie(i, 'tiefkuehl');
      await b.repo.eintragText(i, 'Brot (Vollkorn)');
      await ea.abgleichen();
      await eb.abgleichen();
      await ea.abgleichen();
      for (final d in [a, b]) {
        final e = (await d.eintraege(l)).single;
        expect([e.inhalt, e.category], ['Brot (Vollkorn)', 'tiefkuehl']);
      }
      // b übernimmt die Vorlage in eine neue Liste, a sieht die Einträge
      final ziel = await b.repo.listeAnlegen(name: 'Nächste Woche');
      expect(await b.repo.ausVorlageUebernehmen(ziel, v), 1);
      await eb.abgleichen();
      await ea.abgleichen();
      expect((await a.eintraege(ziel)).single.category, 'brot_backwaren');
    });
  });
}
