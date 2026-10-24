// Ein Gerät einer Person für die Tests der Dateiablage: eigene lokale Datenbank, Store, Repository, ApiClient (Bearer-Token `person-<Kennung>`, daran erkennt der Fake-Server die Person) und
// Sync-Engine gegen den gemeinsamen Fake-Server ([FakeDateien]). Mehrere Geräte teilen sich den Server und die Sync-Welt.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/dateien/datei_cache_dienst.dart';
import 'package:lx_fampad/data/dateien/datei_ort_io.dart';
import 'package:lx_fampad/data/dateien/datei_repository.dart';
import 'package:lx_fampad/data/dateien/transfer_dienst.dart';
import 'package:lx_fampad/data/dateien/transfer_modelle.dart';
import 'package:lx_fampad/data/dateien/tus_client.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

import 'datei_welt.dart';
import 'fake_server.dart';

int _geraeteZaehler = 0;

class DateiGeraet {
  final String person;
  final Role rolle;
  final FakeDateien welt;
  final AppDatabase db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  late final SyncStore store;
  late final DateiRepository repo;
  late final ApiClient api;
  late final FampadApi fampad;
  late final SyncEngine engine;
  late final TusClient tus;
  late final DateiOrtIo ort;
  late final DateiCacheDienst cache;
  late TransferDienst dienst;
  final FakeTransferHintergrund hintergrund = FakeTransferHintergrund();
  late final Directory tmp;
  ThumbErzeuger thumb = fakeThumb;
  Duration Function(int) backoff = (_) => Duration.zero;
  int maxParallel = 3;
  int maxVersuche = 8;
  final String geraeteId;
  int geaendert = 0;
  int _n = 0;
  DateTime jetzt = DateTime.utc(2026, 10, 24, 9);
  final String _praefix;

  DateiGeraet._(this.welt, this.person, this.rolle, this.geraeteId, this._praefix);

  /// [person] ist die Kennung (`mama`); das Token lautet `person-mama`. Die Rolle trägt der Fake-Server ein ([FakeDateien.rollen]).
  static Future<DateiGeraet> neu(FakeServer server, FakeDateien welt, {required String person, required Role rolle, String? geraet}) async {
    final nr = ++_geraeteZaehler;
    final id = geraet ?? 'geraet-$person-$nr';
    final g = DateiGeraet._(welt, 'person-$person', rolle, id, '${nr.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-');
    welt.rollen[g.person] = rolle;
    g.store = SyncStore(g.db, jetzt: () => g.jetzt);
    final tokens = MemoryTokenStore();
    await tokens.writeTokens(
      StoredTokens(accessToken: g.person, accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'refresh-$person', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: id),
    );
    g.api = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test');
    g.fampad = FampadApi(g.api, geraet: () async => null);
    g.engine = SyncEngine(store: g.store, api: g.fampad, geraeteId: () async => id, seite: 500, maxOps: 50);
    g.repo = DateiRepository(
      db: g.db,
      store: g.store,
      ich: () => g.person,
      rolle: () => rolle,
      beiAenderung: () => g.geaendert++,
      jetzt: () => g.jetzt,
      neueId: () => '${g._praefix}${(++g._n).toString().padLeft(12, '0')}',
    );
    g.tmp = Directory.systemTemp.createTempSync('datei_test_');
    g.ort = DateiOrtIo(() async => Directory('${g.tmp.path}/cache'));
    g.cache = DateiCacheDienst(db: g.db, ort: g.ort, jetzt: () => g.jetzt);
    g.tus = TusClient(g.api, schlaf: (_) async {});
    g.dienstNeu();
    addTearDown(() async {
      await g.dienst.beenden();
      await g.db.close();
      try {
        g.tmp.deleteSync(recursive: true);
      } on Object {
        // Aufräumen im Test
      }
    });
    return g;
  }

  /// Ein neuer Transfer-Dienst auf derselben Datenbank (wie nach einem Neustart der App).
  TransferDienst dienstNeu() => dienst = TransferDienst(
    db: db,
    repo: repo,
    tus: tus,
    api: fampad,
    cache: cache,
    hintergrund: hintergrund,
    thumb: (b) => thumb(b),
    jetzt: () => DateTime.now(),
    neueId: () => '$_praefix${(++_n).toString().padLeft(12, '0')}',
    backoff: (n) => backoff(n),
    maxParallel: maxParallel,
    maxVersuche: maxVersuche,
  );

  /// Schreibt eine Datei mit [bytes] in den Wegwerf-Ordner (Quelle per Pfad, wie auf Android) und liefert ihren Pfad.
  String datei(String name, Uint8List bytes) {
    final f = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  /// Ein Abgleich dieses Geräts gegen den Fake-Server; schlägt der Test fehl, wenn er nicht gelingt.
  Future<SyncErgebnis> abgleich() async {
    welt.sync.geraet = geraeteId;
    final r = await engine.abgleichen();
    expect(r.ok, isTrue, reason: 'Abgleich: ${r.ausgang} ${r.meldung}');
    return r;
  }

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();
  Future<List<OrdnerZeile>> ordner() => db.select(db.ordner).get();
  Future<List<DateiZeile>> dateien() => db.select(db.dateien).get();
  Future<List<DateiVersionZeile>> versionen() => db.select(db.dateiVersionen).get();
  Future<OrdnerZeile?> o(String id) => (db.select(db.ordner)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<DateiZeile?> d(String id) => (db.select(db.dateien)..where((t) => t.id.equals(id))).getSingleOrNull();
}

/// Vorschaubild im Test: ein paar feste Bytes (die echte Bildverarbeitung prüft ein eigener Test).
Future<Uint8List?> fakeThumb(Uint8List quelle) async => Uint8List.fromList(List.filled(100, 7));

/// Hintergrunddienst zum Beobachten.
class FakeTransferHintergrund implements TransferHintergrundPort {
  final List<String> ereignisse = [];
  int? letzteAnzahl;
  int? letztesProzent;
  bool aktiv = false;

  @override
  Future<void> starten({required int anzahl}) async {
    aktiv = true;
    ereignisse.add('start $anzahl');
  }

  @override
  Future<void> aktualisieren({required int anzahl, required int prozent}) async {
    letzteAnzahl = anzahl;
    letztesProzent = prozent;
  }

  @override
  Future<void> beenden() async {
    aktiv = false;
    ereignisse.add('ende');
  }
}
