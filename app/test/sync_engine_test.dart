// SyncEngine gegen den Fake-Server (echter ApiClient/FampadApi, MockClient): Offline-Änderung -> späterer Abgleich, Idempotenz bei
// verlorener Antwort, Konflikt, Löschen gegen Ändern, Resync, Seiten, Fehlerfälle (401, 426, 429, Netz, Gerät).
import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/api_error.dart' show kWartungMeldung;
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

const _l1 = '11111111-1111-4111-8111-111111111111';
const _i1 = '22222222-2222-4222-8222-222222222222';

class Aufbau {
  final FakeServer server = FakeServer();
  final FakeSyncServer sync = FakeSyncServer();
  late final AppDatabase db;
  late final SyncStore store;
  late final SyncEngine engine;
  late final ApiClient client;
  String? geraet = fixDevice;
  var sitzungVerloren = 0;

  Future<void> init({int seite = 500, int maxOps = 50}) async {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    sync.registrieren(server);
    final tokens = MemoryTokenStore();
    await tokens.writeTokens(
      StoredTokens(accessToken: 'access-1', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'refresh-1', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: fixDevice),
    );
    client = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test')..onSessionLost = (_) => sitzungVerloren++;
    store = SyncStore(db);
    engine = SyncEngine(store: store, api: FampadApi(client, geraet: () async => null), geraeteId: () async => geraet, seite: seite, maxOps: maxOps);
  }

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<Liste?> liste(String id) => (db.select(db.listen)..where((l) => l.id.equals(id))).getSingleOrNull();
  Future<Listeneintrag?> eintrag(String id) => (db.select(db.listenEintraege)..where((l) => l.id.equals(id))).getSingleOrNull();

  Future<void> neueListe(String id, String name) => store.aendern('list', id, {'name': name, 'kind': 'shopping', 'audience': 'family'}, nurLokal: {'createdAt': DateTime.now().toUtc().toIso8601String()});
  Future<void> neuerEintrag(String id, String text, {String list = _l1}) =>
      store.aendern('list_item', id, {'listId': list, 'text': text, 'position': 0.0}, nurLokal: {'createdAt': DateTime.now().toUtc().toIso8601String()});
}

void main() {
  late Aufbau a;

  setUp(() async {
    a = Aufbau();
    await a.init();
  });
  tearDown(() => a.db.close());

  test('Änderungen entstehen lokal sofort, gehen aber erst beim Abgleich zum Server (offline -> später)', () async {
    a.sync.offline = true;
    await a.neueListe(_l1, 'Einkauf');
    await a.neuerEintrag(_i1, 'Milch');
    // lokal sofort da
    expect((await a.liste(_l1))?.name, 'Einkauf');
    expect((await a.eintrag(_i1))?.inhalt, 'Milch');
    var e = await a.engine.abgleichen();
    expect(e.ausgang, SyncAusgang.offline);
    expect(await a.ausgang(), hasLength(2), reason: 'Ausgang bleibt erhalten');
    expect(a.sync.zeilen, isEmpty);

    a.sync.offline = false;
    e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect(await a.ausgang(), isEmpty);
    expect(a.sync.zeilen.keys, containsAll(['list/$_l1', 'list_item/$_i1']));
    expect((await a.eintrag(_i1))?.rev, greaterThan(0), reason: 'Revision des Servers übernommen');
    expect(e.ops, 2);
  });

  test('Idempotenz: geht die Antwort verloren, wird dieselbe Op erneut gesendet und der Server wendet sie nicht noch einmal an', () async {
    await a.neueListe(_l1, 'Einkauf');
    a.sync.antwortVerlieren = true;
    final e1 = await a.engine.abgleichen();
    expect(e1.ausgang, SyncAusgang.offline);
    expect(a.sync.angewendet, 1);
    expect(await a.ausgang(), hasLength(1));
    final opId = (await a.ausgang()).single.opId;

    final e2 = await a.engine.abgleichen();
    expect(e2.ok, isTrue);
    expect(a.sync.angewendet, 1, reason: 'nicht noch einmal angewendet');
    expect(a.sync.rev, 1, reason: 'keine neue Revision');
    expect(a.sync.anfragen.where((r) => (r['ops'] as List).any((o) => o['opId'] == opId)), hasLength(2), reason: 'dieselbe op_id wurde zweimal gesendet');
    expect(await a.ausgang(), isEmpty);
  });

  test('zwei Geräte ändern verschiedene Felder: beides bleibt; dasselbe Feld: der Server gewinnt und der Konflikt wird übernommen', () async {
    await a.neueListe(_l1, 'Einkauf');
    await a.neuerEintrag(_i1, 'Milch');
    await a.engine.abgleichen();

    // anderes Gerät: Text; dieses Gerät: abhaken (verschiedene Felder)
    a.sync.andereAendert('list_item', _i1, {'text': 'Hafermilch'});
    await a.store.aendern('list_item', _i1, {'doneAt': '2026-10-19T10:00:00.000Z'});
    var e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    var z = await a.eintrag(_i1);
    expect(z?.inhalt, 'Hafermilch');
    expect(z?.doneAt, isNotNull);
    expect(a.sync.zeilen['list_item/$_i1']!.fields['doneAt'], '2026-10-19T10:00:00.000Z');

    // dasselbe Feld: anderes Gerät war schneller
    a.sync.andereAendert('list_item', _i1, {'text': 'Barista-Hafermilch'});
    await a.store.aendern('list_item', _i1, {'text': 'Milch 1,5%'});
    e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    z = await a.eintrag(_i1);
    expect(z?.inhalt, 'Barista-Hafermilch', reason: 'Serverstand gewinnt');
    expect(e.hinweise.single.text, contains('gleichzeitig'));
    expect(await a.ausgang(), isEmpty);
  });

  test('Löschen gewinnt: Änderung an einem anderswo gelöschten Eintrag wird abgelehnt, Eintrag verschwindet, Hinweis erscheint', () async {
    await a.neueListe(_l1, 'Einkauf');
    await a.neuerEintrag(_i1, 'Milch');
    await a.engine.abgleichen();
    a.sync.andereLoescht('list_item', _i1);
    await a.store.aendern('list_item', _i1, {'text': 'Hafermilch'});
    final e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect(await a.eintrag(_i1), isNull);
    expect(e.hinweise.single.text, contains('Hafermilch'));
    expect(e.hinweise.single.text, contains('gelöscht'));
    expect(await a.ausgang(), isEmpty);
  });

  test('lokal gelöscht: delete-Op geht raus, der Server hat danach einen Tombstone', () async {
    await a.neueListe(_l1, 'Einkauf');
    await a.neuerEintrag(_i1, 'Milch');
    await a.engine.abgleichen();
    await a.store.loeschen('list', _l1);
    expect(await a.liste(_l1), isNull);
    final e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect(a.sync.zeilen['list/$_l1']!.geloescht, isTrue);
    expect(await a.liste(_l1), isNull, reason: 'der Tombstone bringt nichts zurück');
  });

  test('anderes Gerät legt an: erscheint nach dem Abgleich lokal, mit Seiten (hasMore/next)', () async {
    a.sync.seitenMax = 2;
    a.sync.andereAendert('list', _l1, {'name': 'Von drüben', 'kind': 'packing'});
    for (var i = 0; i < 5; i++) {
      a.sync.andereAendert('list_item', '00000000-0000-4000-8000-00000000000$i', {'listId': _l1, 'text': 'E$i', 'position': i});
    }
    final e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect((await a.db.select(a.db.listenEintraege).get()), hasLength(5));
    expect((await a.liste(_l1))?.kind, 'packing');
    expect(await a.store.sinceRev(), a.sync.rev);
    expect(a.sync.anfragen.length, greaterThanOrEqualTo(3), reason: '6 Änderungen in Seiten zu 2');
    // ein weiterer Abgleich holt nichts mehr
    final vorher = a.sync.anfragen.length;
    await a.engine.abgleichen();
    expect(a.sync.anfragen.length, vorher + 1);
    expect(a.sync.anfragen.last['sinceRev'], a.sync.rev, reason: 'fragt ab dem bekannten Stand');
  });

  test('nach dem Update (Sync-Fortschritt zurückgesetzt): zuvor übersprungene Termine kommen per Snapshot, ausstehende Ops gehen raus', () async {
    const t1 = '33333333-3333-4333-8333-333333333333';
    a.sync.andereAendert('list', _l1, {'name': 'Alt', 'kind': 'shopping'});
    a.sync.andereAendert('termin', t1, {'titel': 'Zahnarzt'});
    await a.engine.abgleichen();
    // alte App: Termin ohne Definition übersprungen, Cursor trotzdem vorgerückt
    await a.db.delete(a.db.termine).go();
    expect(await a.db.select(a.db.termine).get(), isEmpty);
    await a.engine.abgleichen();
    expect(await a.db.select(a.db.termine).get(), isEmpty, reason: 'ohne Reset kommt er nie');
    await a.neuerEintrag(_i1, 'Milch');
    // Migration: sinceRev/snapshotRev gelöscht
    await a.db.metaLoeschen(SyncStore.kSinceRev);
    await a.db.metaLoeschen(SyncStore.kSnapshotRev);
    final e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect((await a.db.select(a.db.termine).get()).map((t) => t.id), [t1]);
    expect((await a.liste(_l1))?.name, 'Alt');
    expect(await a.eintrag(_i1), isNotNull);
    expect(a.sync.anfragen.where((r) => r['sinceRev'] == 0), isNotEmpty);
    expect(await a.ausgang(), isEmpty);
  });

  test('resync_required: lokale Tabellen werden neu geladen, offene Änderungen bleiben darüber erhalten', () async {
    await a.neueListe(_l1, 'Einkauf');
    await a.neuerEintrag(_i1, 'Milch');
    await a.engine.abgleichen();
    await a.store.aendern('list_item', _i1, {'text': 'Hafermilch'});
    a.sync.resyncNaechste = true;
    final e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect((await a.eintrag(_i1))?.inhalt, 'Hafermilch');
    expect(a.sync.zeilen['list_item/$_i1']!.fields['text'], 'Hafermilch');
    expect(a.sync.anfragen.where((r) => r['sinceRev'] == 0).length, greaterThanOrEqualTo(2), reason: 'danach beginnt der Abgleich bei 0');
  });

  test('der Server hat Tombstones bereinigt (sinceRev zu alt): Resync ohne Zutun', () async {
    await a.neueListe(_l1, 'Einkauf');
    await a.engine.abgleichen();
    a.sync.andereAendert('list', 'zweite', {'name': 'Zweite'});
    a.sync.andereLoescht('list', 'zweite');
    a.sync.bereinigen(a.sync.rev);
    a.sync.andereAendert('list', 'dritte', {'name': 'Dritte'});
    final e = await a.engine.abgleichen();
    expect(e.ok, isTrue);
    expect((await a.liste('dritte'))?.name, 'Dritte');
  });

  test('mehr Ops als eine Anfrage fasst gehen in mehreren Anfragen raus', () async {
    final b = Aufbau();
    await b.init(maxOps: 3);
    addTearDown(b.db.close);
    await b.neueListe(_l1, 'Einkauf');
    for (var i = 0; i < 7; i++) {
      await b.neuerEintrag('00000000-0000-4000-8000-00000000000$i', 'E$i');
    }
    final e = await b.engine.abgleichen();
    expect(e.ok, isTrue);
    expect(await b.ausgang(), isEmpty);
    expect(b.sync.zeilen.length, 8);
    expect(b.sync.anfragen.where((r) => (r['ops'] as List).isNotEmpty).length, 3);
  });

  test('abgebrochen (Abmelden während der Anfrage): die Antwort wird nicht mehr in die Datenbank geschrieben', () async {
    await a.neueListe(_l1, 'Einkauf');
    var abbruch = false;
    a.server.on('POST /sync', (req) {
      final antwort = a.sync.verarbeiten(req.json);
      abbruch = true; // der Dienst wird gestoppt, während die Antwort unterwegs ist
      return jsonAntwort(antwort);
    });
    await a.db.alleDatenLoeschen();
    final e = await a.engine.abgleichen(abgebrochen: () => abbruch);
    expect(e.ausgang, SyncAusgang.abgebrochen);
    expect(await a.liste(_l1), isNull);
    expect(await a.ausgang(), isEmpty);
    expect(await a.store.sinceRev(), 0);
  });

  group('Mehrseitiger Snapshot', () {
    String id(int i) => '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';

    test('bei purgedRev > 0 läuft ein Snapshot über mehrere Seiten durch (Folgeseiten senden snapshotRev und werden nie zu resync_required)', () async {
      a.sync.andereAendert('list', _l1, {'name': 'Von drüben'});
      for (var i = 0; i < 7; i++) {
        a.sync.andereAendert('list_item', id(i), {'listId': _l1, 'text': 'E$i', 'position': i});
      }
      a.sync.purgedRev = 4; // der Server hat Tombstones bis 4 bereinigt
      a.sync.seitenMax = 3;
      final e = await a.engine.abgleichen();
      expect(e.ok, isTrue);
      expect(await a.db.select(a.db.listenEintraege).get(), hasLength(7));
      expect(await a.store.sinceRev(), a.sync.rev);
      expect(await a.store.snapshotRev(), isNull);
      expect(a.sync.anfragen.first['sinceRev'], 0);
      expect(a.sync.anfragen.first.containsKey('snapshotRev'), isFalse);
      // alle Folgeseiten nennen die Ziel-Revision aus der ersten Antwort (8 Zeilen = Revision 8)
      final folge = a.sync.anfragen.skip(1).toList();
      expect(folge, isNotEmpty);
      expect(folge.first['snapshotRev'], 8);
      expect(folge.first['sinceRev'], 3);
    });

    test('Fehler nach der ersten Seite: Cursor und snapshotRev bleiben, die Fortsetzung beginnt nicht bei 0', () async {
      for (var i = 0; i < 6; i++) {
        a.sync.andereAendert('list', id(i), {'name': 'L$i'});
      }
      a.sync.purgedRev = 3;
      a.sync.seitenMax = 2;
      var n = 0;
      a.server.on('POST /sync', (req) {
        n++;
        if (n == 2) throw http.ClientException('Verbindung weg'); // zweite Seite scheitert
        return jsonAntwort(a.sync.verarbeiten(req.json));
      });
      final e1 = await a.engine.abgleichen();
      expect(e1.ausgang, SyncAusgang.offline);
      expect(await a.store.sinceRev(), 2);
      expect(await a.store.snapshotRev(), 6);
      expect(await a.db.select(a.db.listen).get(), hasLength(2));
      final e2 = await a.engine.abgleichen();
      expect(e2.ok, isTrue);
      expect(await a.db.select(a.db.listen).get(), hasLength(6));
      expect(a.sync.anfragen.where((r) => r['sinceRev'] == 0), hasLength(1), reason: 'nur der erste Start begann bei 0');
    });

    test('die Familie ändert sich während des Snapshots: danach folgt der normale Lauf und holt den Rest', () async {
      for (var i = 0; i < 4; i++) {
        a.sync.andereAendert('list', id(i), {'name': 'L$i'});
      }
      a.sync.seitenMax = 2;
      var n = 0;
      a.server.on('POST /sync', (req) {
        n++;
        final antwort = a.sync.verarbeiten(req.json);
        if (n == 1) a.sync.andereAendert('list', id(9), {'name': 'Neu während des Snapshots'});
        return jsonAntwort(antwort);
      });
      final e = await a.engine.abgleichen();
      expect(e.ok, isTrue);
      expect(await a.db.select(a.db.listen).get(), hasLength(5));
      expect(await a.store.sinceRev(), a.sync.rev);
    });

    test('resync_required mitten im Snapshot: der Cursor wird verworfen, es beginnt bei 0', () async {
      for (var i = 0; i < 4; i++) {
        a.sync.andereAendert('list', id(i), {'name': 'L$i'});
      }
      a.sync.seitenMax = 2;
      var n = 0;
      a.server.on('POST /sync', (req) {
        n++;
        if (n == 2) a.sync.resyncNaechste = true;
        return jsonAntwort(a.sync.verarbeiten(req.json));
      });
      final e = await a.engine.abgleichen();
      expect(e.ok, isTrue);
      expect(await a.db.select(a.db.listen).get(), hasLength(4));
      expect(a.sync.anfragen.where((r) => r['sinceRev'] == 0), hasLength(2));
    });

    test('der Client sendet höchstens 50 Ops je Anfrage', () async {
      final b = Aufbau();
      await b.init();
      addTearDown(b.db.close);
      await b.neueListe(_l1, 'Einkauf');
      for (var i = 0; i < 120; i++) {
        await b.neuerEintrag(id(i), 'E$i');
      }
      final e = await b.engine.abgleichen();
      expect(e.ok, isTrue);
      expect(b.sync.anfragen.where((r) => (r['ops'] as List).isNotEmpty), hasLength(3));
      for (final r in b.sync.anfragen) {
        expect((r['ops'] as List).length, lessThanOrEqualTo(50));
      }
    });
  });

  group('Fehlerfälle', () {
    test('429: später wieder, mit der Wartezeit des Servers; Ausgang bleibt', () async {
      await a.neueListe(_l1, 'Einkauf');
      a.sync.fehlerQueue.add((429, 'rate_limited'));
      final e = await a.engine.abgleichen();
      expect(e.ausgang, SyncAusgang.ueberlastet);
      expect(e.warten, const Duration(seconds: 7));
      expect(await a.ausgang(), hasLength(1));
    });

    test('503: ebenfalls "später wieder"', () async {
      a.sync.fehlerQueue.add((503, 'server_busy'));
      expect((await a.engine.abgleichen()).ausgang, SyncAusgang.ueberlastet);
    });

    test('500: Fehler mit fester Meldung (nie Servertext)', () async {
      a.sync.fehlerQueue.add((500, 'internal_error'));
      final e = await a.engine.abgleichen();
      expect(e.ausgang, SyncAusgang.fehler);
      expect(e.meldung, isNot(contains('Meldung des Servers')));
    });

    test('401: Sitzung verloren (ApiClient meldet sie), Ausgang bleibt für die nächste Anmeldung', () async {
      await a.neueListe(_l1, 'Einkauf');
      a.sync.fehlerQueue.add((401, 'unauthenticated'));
      // Access-Token abgelehnt -> Erneuerung -> auch das scheitert
      a.server.on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
      final e = await a.engine.abgleichen();
      expect(e.ausgang, SyncAusgang.sitzungVerloren);
      expect(a.sitzungVerloren, 1);
      expect(await a.ausgang(), hasLength(1));
    });

    test('426: Update nötig', () async {
      a.sync.fehlerQueue.add((426, 'update_required'));
      expect((await a.engine.abgleichen()).ausgang, SyncAusgang.updateNoetig);
    });

    test('503 maintenance: Wartung (kein Fehler), mit fester Meldung; der Ausgang bleibt', () async {
      await a.neueListe(_l1, 'Einkauf');
      a.sync.fehlerQueue.add((503, 'maintenance'));
      final e = await a.engine.abgleichen();
      expect(e.ausgang, SyncAusgang.wartung);
      expect(e.meldung, kWartungMeldung);
      expect(await a.ausgang(), hasLength(1));
      // andere 503 bleiben "ueberlastet"
      a.sync.fehlerQueue.add((503, 'server_busy'));
      expect((await a.engine.abgleichen()).ausgang, SyncAusgang.ueberlastet);
    });

    test('409 device_mismatch: Gerät neu zuordnen lassen', () async {
      a.sync.fehlerQueue.add((409, 'device_mismatch'));
      expect((await a.engine.abgleichen()).ausgang, SyncAusgang.geraetFalsch);
    });

    test('Geräte-ID unbekannt: geraetFalsch (nicht "Sitzung verloren")', () async {
      a.geraet = null;
      expect((await a.engine.abgleichen()).ausgang, SyncAusgang.geraetFalsch);
    });

    test('Wechsel der Geräte-ID (neue Anmeldung): Daten werden neu geladen, offene Änderungen bleiben', () async {
      await a.neueListe(_l1, 'Einkauf');
      await a.engine.abgleichen();
      await a.neuerEintrag(_i1, 'offen');
      a.geraet = '99999999-0000-4000-8000-000000000001';
      a.sync.offline = true;
      await a.engine.abgleichen();
      expect(await a.liste(_l1), isNull, reason: 'Fachtabellen für das neue Gerät geleert');
      expect(await a.ausgang(), hasLength(1));
      a.sync.offline = false;
      a.sync.geraet = a.geraet!;
      final e = await a.engine.abgleichen();
      expect(e.ok, isTrue);
      expect((await a.liste(_l1))?.name, 'Einkauf');
      expect((await a.eintrag(_i1))?.inhalt, 'offen');
    });

    test('unlesbare Antwort: Fehler, kein Absturz', () async {
      a.server.on('POST /sync', (_) => jsonAntwort({'unerwartet': true}));
      expect((await a.engine.abgleichen()).ausgang, SyncAusgang.fehler);
    });

    test('abgelehnte Op wird nicht in Endlosschleife wiederholt', () async {
      await a.neuerEintrag(_i1, 'ohne Liste'); // Liste fehlt -> not_found
      final e = await a.engine.abgleichen();
      expect(e.ok, isTrue);
      expect(await a.ausgang(), isEmpty);
      expect(await a.eintrag(_i1), isNull);
      expect(e.hinweise, isNotEmpty);
    });
  });
}
