// Vertragsprüfung gegen den ECHTEN Server (gebauter Server aus server/, PostgreSQL 17): die App-Klassen (ApiClient, FampadApi, DTOs,
// Einladungslink-Parser, Passkey-Optionen) rufen die von der App genutzten Endpunkte einmal real auf. Seit Phase 1c gehört der Sync dazu
// (syncVertrag, offlineOnlineVertrag): zwei Geräte derselben Person, Idempotenz, Konflikte pro Feld, Löschen gewinnt, Validierung, Rechte von
// Kind (inklusive "hidden"-Tombstone), mehrseitiger Snapshot (> 500 Einträge, purged_rev > 0) und Geisterlisten, zwei lokale Datenbanken mit SyncStore und SyncEngine (offline/online), WebSocket "rev N" und
// das Bereinigen von Verweisen beim Entfernen eines Mitglieds. Der Server muss mit PUBLIC_URL=https://familie.lx-labs.dev laufen (RP-ID).
// Gehört NICHT zu 'flutter test' (echte Netzverbindung, ändert die Datenbank, dauert ca. 1 Minute wegen der TOTP-Zeitschritte).
// Ablauf: frische Datenbank migrieren, 'node dist/cli/bootstrap.js --family "Familie Vertrag"' (Token aus dem Link), Server starten, dann
//   SERVER=http://127.0.0.1:4460 INVITE_TOKEN=<Token> SERVER_DIR=<server/-Ordner mit node_modules> DATABASE_URL=postgres://… flutter test test/vertrag_test.dart
// Der Server braucht für den Lauf hohe Sync-Limits (SYNC_RATE_LIMIT_MAX, SYNC_REQ_*, SYNC_OPS_*), sonst antwortet der Sync mit 429.
// (die Datei dazu aus tool/ nach test/ kopieren; sie initialisiert kein Widget-Binding, damit HTTP echt läuft).
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_socket.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/features/auth/invite_link.dart';
import 'package:passkeys/types.dart' show AuthenticateRequestType, RegisterRequestType;
import 'package:timezone/data/latest_all.dart' as tzdata;

final server = Platform.environment['SERVER'] ?? 'http://127.0.0.1:4460';
final adminToken = Platform.environment['INVITE_TOKEN']!;
final serverDir = Platform.environment['SERVER_DIR'] ?? '../server';
final datenbank = Platform.environment['DATABASE_URL']!;

/// Zählt Anfragen je Pfad und merkt sich Cookies (Web-Modus).
class Spion extends http.BaseClient {
  final http.Client _inner = IOClient();
  final List<String> pfade = [];
  final Map<String, String> cookies = {};
  final bool cookiesNutzen;
  Spion({this.cookiesNutzen = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    pfade.add('${request.method} ${request.url.path}');
    if (cookiesNutzen && cookies.isNotEmpty) request.headers['cookie'] = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final res = await _inner.send(request);
    final sc = res.headersSplitValues['set-cookie'];
    if (cookiesNutzen && sc != null) {
      for (final c in sc) {
        final kv = c.split(';').first;
        final i = kv.indexOf('=');
        final name = kv.substring(0, i), value = kv.substring(i + 1);
        if (value.isEmpty || c.toLowerCase().contains('max-age=0') || c.contains('1970')) {
          cookies.remove(name);
        } else {
          cookies[name] = value;
        }
      }
    }
    return res;
  }

  int zaehle(String p) => pfade.where((x) => x == p).length;
}

class Gegenstelle {
  final Spion spion;
  final MemoryTokenStore store = MemoryTokenStore();
  late final ApiClient client;
  late final FampadApi api;
  Gegenstelle({bool web = false, DateTime Function()? now, String name = 'Contract-Test'})
    : spion = Spion(cookiesNutzen: web) {
    client = ApiClient(client: spion, store: store, web: web, base: server, now: now);
    api = FampadApi(client, geraet: () async => DeviceInfo(id: await store.readDeviceId(), name: name, platform: 'android', appVersion: '0.1.0'));
  }
}

// ---------------------------------------------------------------------------------------------------- TOTP (RFC 6238)

List<int> base32(String s) {
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = 0, wert = 0;
  final out = <int>[];
  for (final ch in s.toUpperCase().replaceAll('=', '').split('')) {
    wert = (wert << 5) | abc.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.add((wert >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return out;
}

String totp(String secret, int schritt) {
  final msg = List<int>.filled(8, 0);
  var s = schritt;
  for (var i = 7; i >= 0; i--) {
    msg[i] = s & 0xff;
    s >>= 8;
  }
  final h = Hmac(sha1, base32(secret)).convert(msg).bytes;
  final o = h.last & 0xf;
  final bin = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return (bin % 1000000).toString().padLeft(6, '0');
}

final Map<String, int> _letzterSchritt = {};

/// Code für einen Zeitschritt, der noch nie benutzt wurde (der Server lässt jeden Schritt nur einmal zu): wartet notfalls.
Future<String> frischerCode(String secret) async {
  while (true) {
    final schritt = DateTime.now().millisecondsSinceEpoch ~/ 30000;
    if (schritt > (_letzterSchritt[secret] ?? 0)) {
      _letzterSchritt[secret] = schritt;
      return totp(secret, schritt);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

/// Setzt die letzte Bestätigung (Step-up) aller Sitzungen in der Datenbank zurück, um 403 step_up_required real auszulösen.
Future<void> stepUpAltern() async {
  final r = await Process.run('node', [
    '-e',
    "const pg=require('pg');(async()=>{const c=new pg.Client({connectionString:process.env.DATABASE_URL});await c.connect();"
        "await c.query(\"update sessions set step_up_at = now() - interval '10 minutes'\");await c.end()})()",
  ], workingDirectory: serverDir, environment: {'DATABASE_URL': datenbank});
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

void schritt(String s) => stdout.writeln('--- $s');

/// Wiederholt einen Aufruf, solange das Konto nach den Fehlversuchen verzögert gesperrt ist (wartet laut Retry-After).
Future<T> mitWarten<T>(Future<T> Function() aufruf) async {
  for (var versuch = 0;; versuch++) {
    try {
      return await aufruf();
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.zuVieleAnfragen || versuch >= 3) rethrow;
      stdout.writeln('    warte ${e.retryAfter!.inSeconds + 1} s (Retry-After)');
      await Future<void>.delayed(e.retryAfter! + const Duration(seconds: 1));
    }
  }
}

// ---------------------------------------------------------------------------------------------------- Sync (Phase 1c)

Future<String> geraetId(Gegenstelle g) async {
  final fest = await g.store.readDeviceId();
  if (fest != null && fest.isNotEmpty) return fest;
  return (await g.api.ich()).sessionDeviceId!;
}

Future<SyncResult> syncen(Gegenstelle g, List<SyncOp> ops, {int since = 0, int? limit}) async =>
    g.api.sync(deviceId: await geraetId(g), sinceRev: since, ops: ops, limit: limit);

SyncOp neu(String entity, String id, Map<String, dynamic> fields) => SyncOp(opId: neueUuid(), op: 'upsert', entity: entity, id: id, fields: fields);
SyncOp aender(String entity, String id, Map<String, dynamic> fields, int baseRev) =>
    SyncOp(opId: neueUuid(), op: 'upsert', entity: entity, id: id, fields: fields, baseRev: baseRev);
SyncOp weg(String entity, String id, int baseRev) => SyncOp(opId: neueUuid(), op: 'delete', entity: entity, id: id, baseRev: baseRev);

/// Das Sync-Protokoll gegen den echten Server: zwei Geräte, Konflikte, Löschen, Rechte, Validierung, WebSocket.
Future<void> syncVertrag({
  required Gegenstelle a,
  required Gegenstelle b,
  required Gegenstelle gast,
  required Gegenstelle kind,
  required String kindId,
  required String adminId,
}) async {
  schritt('Sync: Liste + Eintrag anlegen (Gerät A), Antwort im Format von docs/API.md');
  final lid = neueUuid(), iid = neueUuid();
  final opListe = neu('list', lid, {'name': 'Einkauf', 'kind': 'shopping'});
  final opItem = neu('list_item', iid, {'listId': lid, 'text': 'Milch', 'position': 1.5});
  final r1 = await syncen(a, [opListe, opItem]);
  expect(r1.resyncNoetig, isFalse);
  expect(r1.acked, [opListe.opId, opItem.opId]);
  expect(r1.rejected, isEmpty);
  expect(r1.conflicts, isEmpty);
  expect(r1.changes.map((c) => c.entity), ['list', 'list_item']);
  expect(r1.changes.last.fields, containsPair('text', 'Milch'));
  expect(r1.changes.last.fields['position'], 1.5);
  final startRev = r1.rev;
  expect(r1.hasMore, isFalse);

  schritt('Sync: Idempotenz (dieselben Ops noch einmal) -> dieselbe Bestätigung, keine neue Revision');
  final r1b = await syncen(a, [opListe, opItem]);
  expect(r1b.acked, r1.acked);
  expect(r1b.rev, startRev);

  schritt('Sync: Gerät B (zweite Sitzung derselben Person) holt den Snapshot und danach nichts mehr');
  final snap = await syncen(b, []);
  expect(snap.changes.map((c) => c.id).toSet(), {lid, iid});
  final liste = snap.changes.firstWhere((c) => c.id == lid);
  expect(liste.fields['audience'], 'family');
  expect(liste.fields['ownerId'], adminId);
  expect((await syncen(b, [], since: snap.rev)).changes, isEmpty);
  final itemRev = snap.changes.firstWhere((c) => c.id == iid).rev;

  schritt('Sync: verschiedene Felder gleichzeitig (Text auf A, Abhaken auf B) bleiben beide; dasselbe Feld: später eintreffende Änderung verliert');
  final doneAt = DateTime.utc(2026, 10, 19, 10).toIso8601String();
  await syncen(a, [aender('list_item', iid, {'text': 'Hafermilch'}, itemRev)]);
  final rB = await syncen(b, [aender('list_item', iid, {'doneAt': doneAt}, itemRev)]);
  expect(rB.conflicts, isEmpty);
  final merged = rB.changes.firstWhere((c) => c.id == iid);
  expect(merged.fields['text'], 'Hafermilch');
  expect(merged.fields['doneAt'], isNotNull);
  final konflikt = await syncen(b, [aender('list_item', iid, {'text': 'Barista-Hafermilch'}, itemRev)]);
  expect(konflikt.acked, hasLength(1));
  expect(konflikt.conflicts.single.fields, {'text': 'Hafermilch'});
  expect(konflikt.conflicts.single.serverRev, greaterThan(itemRev));

  schritt('Sync: Löschen gewinnt gegen eine gleichzeitige Änderung (rejected deleted), Tombstone kommt bei B an');
  await syncen(a, [weg('list_item', iid, itemRev)]);
  final spaet = aender('list_item', iid, {'text': 'zu spät'}, itemRev);
  final rDel = await syncen(b, [spaet], since: rB.rev);
  expect(rDel.rejected.single.code, 'deleted');
  expect(rDel.acked, isEmpty);
  expect(rDel.changes.any((c) => c.id == iid && c.tombstone), isTrue);

  schritt('Sync: Validierung (NUL, zu lang, unbekanntes Feld) lehnt nur die Op ab; Umschlag-Fehler 400, falsches Gerät 409');
  final schlecht = [
    neu('list', neueUuid(), {'name': 'a\u0000b'}),
    neu('list', neueUuid(), {'name': 'x' * 101}),
    neu('list', neueUuid(), {'name': 'ok', 'farbe': 'rot'}),
  ];
  final rBad = await syncen(a, schlecht);
  expect(rBad.rejected.map((r) => r.code), ['invalid', 'invalid', 'invalid']);
  await expectLater(
    a.client.post('/sync', {'protocolVersion': 1, 'deviceId': await geraetId(a), 'sinceRev': -1, 'ops': []}),
    throwsA(isA<ApiException>().having((e) => e.status, 'status', 400)),
  );
  await expectLater(
    a.client.post('/sync', {'protocolVersion': 1, 'deviceId': neueUuid(), 'sinceRev': 0, 'ops': []}),
    throwsA(isA<ApiException>().having((e) => e.status, 'status', 409).having((e) => e.code, 'code', 'device_mismatch')),
  );

  schritt('Sync: Rechte (Kind begrenzt, nicht sichtbare Datensätze unauffindbar, alte Eingabe "all" = family)');
  final lid2 = neueUuid(), iid2 = neueUuid();
  await syncen(a, [neu('list', lid2, {'name': 'Grillfest', 'audience': 'parents'}), neu('list_item', iid2, {'listId': lid2, 'text': 'Würstchen'})]);
  expect((await syncen(gast, [])).changes.where((c) => c.id == lid2), isEmpty);
  expect((await syncen(kind, [])).changes.where((c) => c.id == lid2), isEmpty);
  final gastAendern = aender('list', lid2, {'name': 'Gehackt'}, 1);
  expect((await syncen(gast, [gastAendern])).rejected.single.code, 'not_found');
  final kindEltern = neu('list', neueUuid(), {'name': 'Kind-Liste', 'audience': 'parents'});
  expect((await syncen(kind, [kindEltern])).rejected.single.code, 'forbidden');
  // alte Apps senden "all": der Server speichert und liefert "family"
  final kindAlt = neu('list', neueUuid(), {'name': 'Alte App', 'audience': 'all'});
  expect((await syncen(kind, [kindAlt])).acked, [kindAlt.opId]);
  expect((await alleSeiten(kind)).firstWhere((c) => c.id == kindAlt.id).fields['audience'], 'family');
  final kindFamilie = neu('list', neueUuid(), {'name': 'Kinderliste'});
  expect((await syncen(kind, [kindFamilie])).acked, [kindFamilie.opId]);
  // Freigabe für die Familie: die zweite Person (Kind) sieht Liste und Eintrag
  final freigabe = await syncen(a, [aender('list', lid2, {'audience': 'family'}, 1)]);
  expect(freigabe.rejected, isEmpty);
  final gastSicht = await syncen(gast, []);
  expect(gastSicht.changes.map((c) => c.id), containsAll([lid2, iid2]));
  final itemSicht = gastSicht.changes.firstWhere((c) => c.id == iid2);
  expect((await syncen(gast, [aender('list_item', iid2, {'doneAt': doneAt}, itemSicht.rev)], since: gastSicht.rev)).acked, hasLength(1));
  // Freigabe zurückgenommen: die Person bekommt einen "hidden"-Tombstone ohne Inhalt
  final stand = (await syncen(gast, [], since: gastSicht.rev)).rev;
  await syncen(a, [aender('list', lid2, {'audience': 'parents'}, freigabe.rev)]);
  final versteckt = await syncen(gast, [], since: stand);
  final tomb = versteckt.changes.singleWhere((c) => c.entity == 'list');
  expect(tomb.tombstone, isTrue);
  expect(tomb.hidden, isTrue);
  expect(tomb.fields, isEmpty);

  schritt('Sync: Zuständigkeit setzen (wird beim Entfernen des Mitglieds bereinigt), WebSocket meldet "rev N"');
  final iid3 = neueUuid();
  await syncen(a, [neu('list_item', iid3, {'listId': lid, 'text': 'Kaffee', 'assigneeId': kindId})]);
  final wsRevs = <int>[];
  final socket = SyncSocket(
    ticket: () => b.api.wsTicket(),
    beiRev: wsRevs.add,
    beiStatus: (_) {},
    adresse: () => Uri.parse(server.replaceFirst('http', 'ws')).replace(path: '/ws'),
  );
  socket.start();
  for (var i = 0; i < 50 && !socket.live; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(socket.live, isTrue, reason: 'WebSocket mit Ticket verbunden');
  final nachSync = await syncen(a, [aender('list', lid, {'name': 'Wocheneinkauf'}, 1)]);
  for (var i = 0; i < 30 && !wsRevs.contains(nachSync.rev); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(wsRevs, contains(nachSync.rev), reason: 'der Hub meldet die neue Revision nach dem Commit');
  socket.stop();
}

/// Setzt families.purged_rev in der Datenbank (simuliert, dass der Server Tombstones bereinigt hat). Liefert den bisherigen Wert.
Future<int> purgedRevSetzen(int? rev) async {
  final r = await Process.run('node', [
    '-e',
    "const pg=require('pg');(async()=>{const c=new pg.Client({connectionString:process.env.DATABASE_URL});await c.connect();"
        "const alt=(await c.query('select purged_rev from families')).rows[0].purged_rev;"
        "if(process.env.NEU_PURGED!==undefined)await c.query('update families set purged_rev = \$1',[Number(process.env.NEU_PURGED)]);"
        'console.log(alt);await c.end()})()',
  ], workingDirectory: serverDir, environment: {'DATABASE_URL': datenbank, 'NEU_PURGED': ?(rev?.toString())});
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return int.parse((r.stdout as String).trim());
}

/// Alle Änderungen ab Revision [since] über alle Seiten (bei 0 als Snapshot mit snapshotRev).
Future<List<SyncChange>> alleSeiten(Gegenstelle g, {int since = 0}) async {
  final dev = await geraetId(g);
  final alle = <SyncChange>[];
  var seite = await g.api.sync(deviceId: dev, sinceRev: since, ops: const []);
  alle.addAll(seite.changes);
  for (var i = 0; seite.hasMore && i < 50; i++) {
    seite = await g.api.sync(deviceId: dev, sinceRev: seite.next, ops: const [], snapshotRev: seite.snapshotRev);
    expect(seite.resyncNoetig, isFalse);
    alle.addAll(seite.changes);
  }
  return alle;
}

/// Mehrseitiger Snapshot (mehr als 500 Einträge) bei purged_rev > 0 und Geisterlisten gegen den echten Server.
Future<void> snapshotVertrag({required Gegenstelle a, required Gegenstelle b, required Gegenstelle gast}) async {
  schritt('Sync: Snapshot über mehrere Seiten (> 500 Einträge) bei purged_rev > 0: Folgeseiten nie resync_required, snapshotRev, Delta danach');
  final lid = neueUuid();
  await syncen(a, [neu('list', lid, {'name': 'Großliste'})]);
  final ids = <String>[];
  for (var block = 0; block < 11; block++) {
    final ops = [
      for (var i = 0; i < 50; i++) () {
        final id = neueUuid();
        ids.add(id);
        return neu('list_item', id, {'listId': lid, 'text': 'Eintrag ${block * 50 + i}', 'position': (block * 50 + i).toDouble()});
      }(),
    ];
    final r = await syncen(a, ops);
    expect(r.acked, hasLength(50));
  }
  final stand = (await syncen(a, [])).rev;
  final altPurged = await purgedRevSetzen(stand - 1); // jeder Cursor der Folgeseiten liegt darunter: der alte Server hätte resync_required geantwortet
  try {
    final dev = await geraetId(b);
    final erste = await b.api.sync(deviceId: dev, sinceRev: 0, ops: const [], limit: 200);
    expect(erste.resyncNoetig, isFalse);
    expect(erste.hasMore, isTrue);
    expect(erste.snapshotRev, stand);
    expect(erste.changes.length, inInclusiveRange(1, 200), reason: 'Seiten zählen Protokolleinträge, ersetzte Stände fehlen');
    final gesehen = <String>{for (final c in erste.changes) c.id};
    // zwischen den Seiten ändert die Familie etwas: Umbenennen und eine neue Liste (kommen im Delta nach dem Snapshot)
    final neueListe = neueUuid();
    await syncen(a, [aender('list', lid, {'name': 'Großliste (umbenannt)'}, 1), neu('list', neueListe, {'name': 'Neu während des Snapshots'})]);
    var seite = erste;
    var seiten = 1;
    while (seite.hasMore) {
      final folge = seite.snapshotRev != null;
      seite = await b.api.sync(deviceId: dev, sinceRev: seite.next, ops: const [], limit: 200, snapshotRev: seite.snapshotRev);
      expect(seite.resyncNoetig, isFalse, reason: 'Folgeseite $seiten: nie resync_required');
      if (folge) expect(seite.changes.where((c) => c.tombstone), isEmpty);
      gesehen.addAll(seite.changes.map((c) => c.id));
      seiten++;
      expect(seiten, lessThan(20));
    }
    expect(seiten, greaterThanOrEqualTo(4));
    expect(gesehen, containsAll(ids));
    expect(gesehen, contains(neueListe), reason: 'der Delta-Lauf nach dem Snapshot holt die Änderung während des Snapshots');
    expect(seite.rev, greaterThan(stand));

    // dasselbe mit den echten App-Klassen (SyncEngine + SyncStore, Seitengröße 200)
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    final store = SyncStore(db);
    final engine = SyncEngine(store: store, api: b.api, geraeteId: () async => dev, seite: 200);
    final e = await engine.abgleichen();
    expect(e.ok, isTrue);
    expect((await db.select(db.listenEintraege).get()).where((x) => x.listId == lid), hasLength(ids.length));
    expect((await db.select(db.listen).get()).where((l) => l.id == lid).single.name, 'Großliste (umbenannt)');
    expect(await store.snapshotRev(), isNull);
    expect(await store.sinceRev(), seite.rev);
  } finally {
    await purgedRevSetzen(altPurged);
  }

  schritt('Sync: Geisterliste (Freigabe entzogen, danach gelöscht): die zweite Person bekommt einen hidden-Tombstone, auch für Einträge');
  final geist = neueUuid(), geistItem = neueUuid();
  final vorGeist = (await syncen(a, [])).rev;
  await syncen(a, [neu('list', geist, {'name': 'Oma-Liste', 'audience': 'family'}), neu('list_item', geistItem, {'listId': geist, 'text': 'Strickzeug'})]);
  final gVorher = await syncen(gast, [], since: vorGeist);
  expect(gVorher.changes.map((c) => c.id), containsAll([geist, geistItem]));
  final listeRev = gVorher.changes.firstWhere((c) => c.id == geist).rev;
  final entzogen = await syncen(a, [aender('list', geist, {'audience': 'parents'}, listeRev)], since: gVorher.rev);
  final nachEntzug = entzogen.changes.firstWhere((c) => c.id == geist).rev;
  await syncen(a, [weg('list', geist, nachEntzug)], since: entzogen.rev);
  final gNachher = await syncen(gast, [], since: gVorher.rev);
  final versteckt = gNachher.changes.where((c) => c.id == geist || c.id == geistItem).toList();
  expect(versteckt, hasLength(2));
  expect(versteckt.every((c) => c.tombstone && c.hidden && c.fields.isEmpty), isTrue);
  // ein Neustart (Snapshot) kennt die Liste nicht mehr, auch nicht als Tombstone
  expect((await alleSeiten(gast)).where((c) => c.id == geist || c.id == geistItem), isEmpty);
}

/// Offline/online mit echter lokaler Datenbank: zwei Geräte (SyncStore + SyncEngine) ändern gleichzeitig, eines war offline.
Future<void> offlineOnlineVertrag({required Gegenstelle a, required Gegenstelle b}) async {
  schritt('Sync offline/online: zwei lokale Datenbanken (SyncStore + SyncEngine), gleichzeitige Änderungen, Löschen');
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  AppDatabase neueDb() => AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  final dbA = neueDb(), dbB = neueDb();
  addTearDown(dbA.close);
  addTearDown(dbB.close);
  final storeA = SyncStore(dbA), storeB = SyncStore(dbB);
  final engineA = SyncEngine(store: storeA, api: a.api, geraeteId: () async => geraetId(a));
  final engineB = SyncEngine(store: storeB, api: b.api, geraeteId: () async => geraetId(b));

  final lid = neueUuid(), iid = neueUuid();
  final jetzt = DateTime.now().toUtc().toIso8601String();
  // A arbeitet "offline": nur lokale Änderungen
  await storeA.aendern('list', lid, {'name': 'Packliste', 'kind': 'packing', 'audience': 'family'}, nurLokal: {'createdAt': jetzt});
  await storeA.aendern('list_item', iid, {'listId': lid, 'text': 'Reisepässe', 'position': 0.0}, nurLokal: {'createdAt': jetzt});
  expect(await dbA.select(dbA.listenEintraege).get(), hasLength(1));
  expect(await storeA.offeneAnzahl(), 2);
  // B sieht noch nichts von dieser Liste
  expect((await engineB.abgleichen()).ok, isTrue);
  expect((await dbB.select(dbB.listen).get()).where((l) => l.id == lid), isEmpty);
  // A kommt online
  final ea = await engineA.abgleichen();
  expect(ea.ok, isTrue);
  expect(await storeA.offeneAnzahl(), 0);
  expect((await engineB.abgleichen()).ok, isTrue);
  expect((await dbB.select(dbB.listenEintraege).get()).singleWhere((e) => e.id == iid).inhalt, 'Reisepässe');

  // beide ändern, B ist offline: A Text, B Abhaken; danach Konflikt auf demselben Feld
  await storeA.aendern('list_item', iid, {'text': 'Reisepässe (alle)'});
  await storeB.aendern('list_item', iid, {'doneAt': DateTime.now().toUtc().toIso8601String()});
  await storeB.aendern('list_item', iid, {'text': 'Pässe'});
  expect((await engineA.abgleichen()).ok, isTrue);
  final eb = await engineB.abgleichen();
  expect(eb.ok, isTrue);
  final beiB = (await dbB.select(dbB.listenEintraege).get()).singleWhere((e) => e.id == iid);
  expect(beiB.doneAt, isNotNull, reason: 'Abhaken von B bleibt');
  expect(beiB.inhalt, 'Reisepässe (alle)', reason: 'dasselbe Feld: Serverstand (A war zuerst) gilt');
  expect(eb.hinweise, isNotEmpty);
  expect((await engineA.abgleichen()).ok, isTrue);
  final beiA = (await dbA.select(dbA.listenEintraege).get()).singleWhere((e) => e.id == iid);
  expect(beiA.doneAt, isNotNull);
  expect(beiA.inhalt, 'Reisepässe (alle)');

  // A löscht die Liste, B ändert gleichzeitig einen Eintrag -> B bekommt den Hinweis, alles verschwindet
  await storeA.loeschen('list', lid);
  await storeB.aendern('list_item', iid, {'text': 'noch eine Änderung'});
  expect((await engineA.abgleichen()).ok, isTrue);
  final eb2 = await engineB.abgleichen();
  expect(eb2.ok, isTrue);
  expect((await dbB.select(dbB.listen).get()).where((l) => l.id == lid), isEmpty);
  expect((await dbB.select(dbB.listenEintraege).get()).where((e) => e.id == iid), isEmpty);
  expect(eb2.hinweise.any((h) => h.text.contains('gelöscht')), isTrue);
  expect(await storeB.offeneAnzahl(), 0);
}

/// Kalender gegen den echten Server (Phase 1c-2a): Termin mit Serie, Teilnehmern und Ausnahme auf zwei lokalen Datenbanken, Validierung
/// (RRULE, Zeitzone, Zeiten), Rechte des Kindes, Serie löschen räumt Kinder auf.
Future<void> kalenderVertrag({
  required Gegenstelle a,
  required Gegenstelle b,
  required Gegenstelle gast,
  required Gegenstelle kind,
  required String kindId,
  required String adminId,
}) async {
  schritt('Kalender: Serie mit Teilnehmer und abgesagtem Vorkommen auf zwei lokalen Datenbanken (A legt an, B sieht dasselbe)');
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();
  AppDatabase neueDb() => AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  final dbA = neueDb(), dbB = neueDb();
  addTearDown(dbA.close);
  addTearDown(dbB.close);
  final storeA = SyncStore(dbA), storeB = SyncStore(dbB);
  final engineA = SyncEngine(store: storeA, api: a.api, geraeteId: () async => geraetId(a));
  final engineB = SyncEngine(store: storeB, api: b.api, geraeteId: () async => geraetId(b));
  final repoA = TerminRepository(db: dbA, store: storeA, ich: () => adminId, beiAenderung: () {});
  final repoB = TerminRepository(db: dbB, store: storeB, ich: () => adminId, beiAenderung: () {});

  DateTime tag(int y, int m, int d, [int h = 0]) => DateTime.utc(y, m, d, h);
  // Dienstag 10 Uhr Berlin, über die Zeitumstellung hinweg (25.10.2026)
  final id = await repoA.anlegen(
    TerminEingabe(titel: 'Chorprobe', ort: 'Aula', ganztaegig: false, startWand: tag(2027, 3, 23, 10), endeWand: tag(2027, 3, 23, 11), rrule: 'FREQ=WEEKLY;BYDAY=TU', erinnerungMin: 30, teilnehmer: {kindId, adminId}),
  );
  List<Vorkommen> vorkommen(AppDatabase db, List<Termin> t, List<TerminAusnahme> au) => vorkommenImFenster(
    termine: t,
    ausnahmen: {for (final x in au) x.terminId: au.where((y) => y.terminId == x.terminId).toList()},
    vonWand: tag(2027, 3, 20),
    bisWand: tag(2027, 4, 20),
    jetzt: tag(2027, 3, 1),
  );
  final erste = vorkommen(dbA, await dbA.select(dbA.termine).get(), const []);
  expect(erste.map((v) => v.startWand.day).toList(), [23, 30, 6, 13]);
  expect(erste.map((v) => v.startUtc.hour).toList(), [9, 8, 8, 8], reason: 'Sommerzeit ab 28.3.2027: 10 Uhr bleibt 10 Uhr');
  await repoA.vorkommenAbsagen(erste[1]);
  expect((await engineA.abgleichen()).ok, isTrue);
  expect((await engineB.abgleichen()).ok, isTrue);
  final beiB = (await dbB.select(dbB.termine).get()).singleWhere((t) => t.id == id);
  expect([beiB.titel, beiB.ort, beiB.tzid, beiB.erinnerungMin, beiB.ownerId, beiB.audience], ['Chorprobe', 'Aula', 'Europe/Berlin', 30, adminId, 'family']);
  expect(beiB.rrule, 'FREQ=WEEKLY;BYDAY=TU');
  expect((await dbB.select(dbB.terminTeilnehmer).get()).map((z) => z.userId).toSet(), {kindId, adminId});
  final auB = await dbB.select(dbB.terminAusnahmen).get();
  expect(auB.single.id, ausnahmeId(id, erste[1].schluessel));
  expect(vorkommen(dbB, [beiB], auB).map((v) => v.startWand.day).toList(), [23, 6, 13], reason: 'B rechnet dasselbe: das zweite Vorkommen ist abgesagt');

  schritt('Kalender: B ändert nur dieses Vorkommen und dieses und folgende (Serie wird geteilt), A sieht beides');
  final vorkB = vorkommen(dbB, [beiB], auB);
  await repoB.vorkommenAendern(vorkB[1], TerminEingabe(titel: 'Chorprobe (Sonder)', ort: 'Aula', ganztaegig: false, startWand: tag(2027, 4, 6, 18), endeWand: tag(2027, 4, 6, 19)));
  final neuId = await repoB.folgendeAendern(
    vorkB[2],
    TerminEingabe(titel: 'Chorprobe neu', ort: 'Halle', ganztaegig: false, startWand: vorkB[2].startWand, endeWand: vorkB[2].endeWand, rrule: 'FREQ=WEEKLY;BYDAY=TU', teilnehmer: {adminId}),
  );
  expect((await engineB.abgleichen()).ok, isTrue);
  expect((await engineA.abgleichen()).ok, isTrue);
  final termineA = await dbA.select(dbA.termine).get();
  expect(termineA, hasLength(2));
  expect(termineA.singleWhere((t) => t.id == id).rrule, contains('UNTIL='));
  expect(termineA.singleWhere((t) => t.id == neuId).titel, 'Chorprobe neu');
  final tageA = vorkommen(dbA, termineA, await dbA.select(dbA.terminAusnahmen).get());
  expect(tageA.map((v) => '${v.titel}@${v.startWand.day}').toList(), ['Chorprobe@23', 'Chorprobe (Sonder)@6', 'Chorprobe neu@13']);

  schritt('Kalender: der Server lehnt ungültige Termine ab (RRULE, Zeitzone, Zeiten, Längen), nichts landet im Datenbestand');
  final zeit = {'titel': 'T', 'ganztaegig': false, 'startUtc': '2027-04-01T08:00:00.000Z', 'endUtc': '2027-04-01T09:00:00.000Z', 'tzid': 'Europe/Berlin'};
  for (final schlecht in <Map<String, dynamic>>[
    {...zeit, 'rrule': 'FREQ=SECONDLY'},
    {...zeit, 'rrule': 'FREQ=DAILY;COUNT=99999'},
    {...zeit, 'tzid': 'Mars/Olympus'},
    {...zeit, 'endUtc': '2027-04-01T07:00:00.000Z'},
    {...zeit, 'titel': 'x' * 201},
    {'titel': 'Tag', 'ganztaegig': true, 'startDate': '2027-04-01', 'endDate': '2027-04-01'},
  ]) {
    final op = neu('termin', neueUuid(), schlecht);
    final r = await syncen(a, [op]);
    expect(r.rejected.single.code, 'invalid', reason: '$schlecht');
  }

  schritt('Kalender: Rechte des Kindes gegen den echten Server (alte Eingabe "all" = family)');
  final privat = neueUuid(), frei = neueUuid(), eltern = neueUuid();
  expect((await syncen(a, [neu('termin', privat, {...zeit, 'audience': 'parents'}), neu('termin', frei, {...zeit, 'titel': 'Für alle', 'audience': 'all'}), neu('termin', eltern, zeit)])).rejected, isEmpty);
  final kindTerminId = neueUuid();
  final kindOp = neu('termin', kindTerminId, {...zeit, 'titel': 'Kinder-Termin'});
  expect((await syncen(kind, [kindOp])).acked, [kindOp.opId]);
  final fremd = await syncen(kind, [aender('termin', eltern, {'titel': 'Hack'}, 1)]);
  expect(fremd.rejected.single.code, 'forbidden');
  final geheim = await syncen(kind, [aender('termin', privat, {'titel': 'Hack'}, 1)]);
  expect(geheim.rejected.single.code, 'not_found');
  final tn = await syncen(kind, [neu('termin_teilnehmer', neueUuid(), {'terminId': eltern, 'userId': kindId})]);
  expect(tn.rejected.single.code, 'forbidden');
  final kindSicht = (await alleSeiten(kind)).where((c) => c.entity == 'termin').map((c) => c.id);
  expect(kindSicht, isNot(contains(privat)));
  expect(kindSicht, contains(eltern));
  expect((await syncen(a, [neu('termin_teilnehmer', neueUuid(), {'terminId': frei, 'userId': kindId})])).rejected, isEmpty);
  final zweitSicht = (await alleSeiten(gast)).where((c) => c.entity == 'termin').toList();
  expect(zweitSicht.map((c) => c.id), containsAll([frei, eltern]));
  expect(zweitSicht.map((c) => c.id), isNot(contains(privat)));
  expect(zweitSicht.firstWhere((c) => c.id == frei).fields['audience'], 'family', reason: 'alte Eingabe "all" wird family');

  schritt('Kalender: Serie löschen räumt Teilnehmer und Ausnahmen auf beiden Geräten ab');
  // die Probetermine der Rechteprüfung zuerst entfernen (die lokalen Datenbanken bekommen sie sonst auch)
  await syncen(a, [weg('termin', privat, 1), weg('termin', frei, 1), weg('termin', eltern, 1), weg('termin', kindTerminId, 1)]);
  await repoA.alleLoeschen(neuId!);
  await repoA.alleLoeschen(id);
  expect((await engineA.abgleichen()).ok, isTrue);
  expect((await engineB.abgleichen()).ok, isTrue);
  for (final db in [dbA, dbB]) {
    expect(await db.select(db.termine).get(), isEmpty);
    expect(await db.select(db.terminTeilnehmer).get(), isEmpty);
    expect(await db.select(db.terminAusnahmen).get(), isEmpty);
  }
}

void main() {
  test('Vertrag App <-> echter Server', timeout: const Timeout(Duration(minutes: 8)), () async {
    // ---------------------------------------------------------------- Anmeldeoptionen ohne Anmeldung
    schritt('Passkey-Anmeldeoptionen werden vom Paket verstanden');
    final anon = Gegenstelle();
    final loginOpt = await anon.api.passkeyAnmeldeOptionen();
    final authReq = AuthenticateRequestType.fromJson(normalisiereOptionen(loginOpt.options));
    expect(authReq.relyingPartyId, 'familie.lx-labs.dev');
    expect(authReq.userVerification, 'required');
    expect(authReq.challenge, isNotEmpty);

    // ---------------------------------------------------------------- Erster Admin (Passwort + TOTP)
    schritt('Einladung prüfen, parser, Passkey-Registrierungsoptionen');
    final admin = Gegenstelle(name: 'Pixel 9');
    final info = await admin.api.einladungPruefen(adminToken);
    expect(info.role, Role.admin);
    expect(info.familyName, 'Familie Vertrag');
    expect(info.pinRequired, isFalse);
    expect(parseInviteToken('https://familie.lx-labs.dev/#/einladung/$adminToken'), adminToken);

    final pkOpt = await admin.api.passkeyRegistrierungStart(token: adminToken, email: 'anna@beispiel.de', anzeigename: 'Anna');
    final regReq = RegisterRequestType.fromJson(normalisiereOptionen(pkOpt.options));
    expect(regReq.relyingParty.id, 'familie.lx-labs.dev');
    expect(regReq.user.name, 'anna@beispiel.de');
    expect(regReq.authSelectionType!.userVerification, 'required');
    expect(regReq.pubKeyCredParams, isNotEmpty);

    schritt('Passwort-Registrierung: Start (Secret, otpauth) und Bestätigung mit TOTP');
    final start = await admin.api.passwortRegistrierungStart(
      token: adminToken,
      passwort: 'Contract-Passwort-12',
      email: 'anna@beispiel.de',
      anzeigename: 'Anna',
    );
    expect(start.totpUri, startsWith('otpauth://totp/'));
    expect(start.totpUri, contains(start.totpSecret));
    final secretAdmin = start.totpSecret;
    final reg = await admin.api.passwortRegistrierungFertig(challengeId: start.challengeId, code: await frischerCode(secretAdmin));
    expect(reg.status, MemberStatus.active);
    expect(reg.recoveryCodes, hasLength(10));
    expect(RegExp(r'^[A-Z0-9]{4}(-[A-Z0-9]{4}){3}$').hasMatch(reg.recoveryCodes.first), isTrue);
    expect(reg.session!.istApp, isTrue);
    await admin.client.sitzungUebernehmen(reg.session!);
    final adminId = reg.member.id;

    schritt('Einladung ist verbraucht (eine Antwort für alle Fälle)');
    await expectLater(anon.api.einladungPruefen(adminToken), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid')));

    schritt('/me, Zugänge, Geräte, Mitglieder, Einladungen');
    var me = await admin.api.ich();
    expect(me.user.role, Role.admin);
    expect(me.user.email, 'anna@beispiel.de');
    expect(me.hasPassword && me.hasTotp, isTrue);
    expect(me.passkeys, 0);
    expect(me.recoveryCodesRemaining, 10);
    final zugaenge = await admin.api.zugaenge();
    expect(zugaenge.map((c) => c.type).toSet(), {'password', 'totp'});
    final geraete = await admin.api.geraete();
    expect(geraete.single.current, isTrue);
    expect(geraete.single.name, 'Pixel 9');
    expect(geraete.single.platform, 'android');
    expect(geraete.single.appVersion, '0.1.0');
    expect((await admin.api.mitglieder()).single.id, adminId);
    expect((await admin.api.einladungen()).where((i) => i.status == InviteStatus.open), isEmpty);
    await admin.api.profilAendern(anzeigename: 'Anna A.', farbe: 4);
    me = await admin.api.ich();
    expect((me.user.displayName, me.user.colorIndex), ('Anna A.', 4));

    // ---------------------------------------------------------------- Einladungen
    schritt('Kind-Einladung mit PIN: erstellen, Liste, Parser auf den Link');
    final kindInv = await admin.api.einladungErstellen(rolle: Role.child, stunden: 24, pin: true);
    expect(kindInv.pin, matches(RegExp(r'^\d{6}$')));
    expect(parseInviteToken(kindInv.link), kindInv.token);
    expect(kindInv.requireApproval, isFalse);
    final liste = (await admin.api.einladungen()).firstWhere((i) => i.id == kindInv.id);
    expect(liste.status, InviteStatus.open);
    expect(liste.hasPin, isTrue);
    expect(liste.role, Role.child);

    schritt('Registrierung des Kindes: falsche PIN -> invite_invalid, richtige PIN -> Konto');
    final kind = Gegenstelle(name: 'Kinder-Handy');
    final kindInfo = await kind.api.einladungPruefen(kindInv.token);
    expect(kindInfo.pinRequired, isTrue);
    await expectLater(
      kind.api.passwortRegistrierungStart(token: kindInv.token, passwort: 'Kind-Passwort-123', pin: '000000', email: 'ben@beispiel.de', anzeigename: 'Ben'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid').having((e) => e.message, 'message', contains('PIN'))),
    );
    final kStart = await kind.api.passwortRegistrierungStart(
      token: kindInv.token,
      passwort: 'Kind-Passwort-123',
      pin: kindInv.pin,
      email: 'ben@beispiel.de',
      anzeigename: 'Ben',
    );
    final kReg = await kind.api.passwortRegistrierungFertig(challengeId: kStart.challengeId, code: await frischerCode(kStart.totpSecret));
    await kind.client.sitzungUebernehmen(kReg.session!);
    final kindId = kReg.member.id;
    expect((await kind.api.ich()).user.role, Role.child);
    // Kinder verwalten keine Einladungen
    await expectLater(kind.api.einladungen(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));

    schritt('Einladung mit Freigabe auf Wunsch: pending, Anmeldung 403 account_pending, Freigabe, dann Anmeldung; die Rolle guest gibt es nicht');
    final gastInv = await admin.api.einladungErstellen(rolle: Role.child, stunden: 6, pin: false, freigabe: true);
    expect(gastInv.requireApproval, isTrue);
    await expectLater(admin.client.post('/invites', {'role': 'guest', 'hours': 1, 'pin': false}), throwsA(isA<ApiException>().having((e) => e.status, 'status', 400)));
    final gast = Gegenstelle(name: 'Omas Tablet');
    final gStart = await gast.api.passwortRegistrierungStart(token: gastInv.token, passwort: 'Gast-Passwort-1234', email: 'oma@beispiel.de', anzeigename: 'Oma');
    final gReg = await gast.api.passwortRegistrierungFertig(challengeId: gStart.challengeId, code: await frischerCode(gStart.totpSecret));
    expect(gReg.status, MemberStatus.pending);
    expect(gReg.session, isNull);
    expect(gReg.recoveryCodes, hasLength(10));
    await expectLater(
      gast.api.passwortAnmelden(email: 'oma@beispiel.de', passwort: 'Gast-Passwort-1234', wiederherstellungscode: gReg.recoveryCodes.first),
      throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.kontoWartet)),
    );
    var mitglieder = await admin.api.mitglieder();
    final oma = mitglieder.firstWhere((m) => m.displayName == 'Oma');
    expect(oma.status, MemberStatus.pending);
    expect(oma.email, 'oma@beispiel.de'); // Admin sieht E-Mail
    await admin.api.freigeben(oma.id);
    // Beobachtung: der Server verbraucht den Code schon bei der abgelehnten Anmeldung (pending) -> der zweite Code wird gebraucht
    final omaLogin = await gast.api.passwortAnmelden(email: 'oma@beispiel.de', passwort: 'Gast-Passwort-1234', wiederherstellungscode: gReg.recoveryCodes[1]);
    expect(omaLogin.user.role, Role.child);
    expect(omaLogin.session.istApp, isTrue);
    await gast.client.sitzungUebernehmen(omaLogin.session);
    // Nicht-Admins sehen E-Mails anderer nicht
    final sichtKind = await kind.api.mitglieder();
    expect(sichtKind.where((m) => m.id != kindId).every((m) => m.email == null), isTrue);
    expect(sichtKind.firstWhere((m) => m.id == kindId).email, 'ben@beispiel.de');

    schritt('Verlängern (verkürzt nie), Widerrufen');
    final extra = await admin.api.einladungErstellen(rolle: Role.child, stunden: 24, pin: false);
    final vorher = (await admin.api.einladungen()).firstWhere((i) => i.id == extra.id).expiresAt;
    final neu = await admin.api.einladungVerlaengern(extra.id, 1);
    expect(neu.isBefore(vorher.subtract(const Duration(seconds: 1))), isFalse, reason: 'verkürzt nie');
    await admin.api.einladungWiderrufen(extra.id);
    expect((await admin.api.einladungen()).firstWhere((i) => i.id == extra.id).status, InviteStatus.revoked);
    await expectLater(admin.api.einladungWiderrufen(extra.id), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_not_open')));
    await expectLater(anon.api.einladungPruefen(extra.token), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid')));

    // ---------------------------------------------------------------- Step-up
    schritt('Step-up: Admin-Einladung nach 10 Minuten verlangt Bestätigung (403 step_up_required), TOTP bestätigt, Wiederholung klappt');
    await stepUpAltern();
    await expectLater(
      admin.api.einladungErstellen(rolle: Role.admin, stunden: 1, pin: false),
      throwsA(isA<ApiException>().having((e) => e.istStepUp, 'step-up', isTrue).having((e) => e.message, 'message', contains('bestätige'))),
    );
    await expectLater(admin.api.stepUpCode(totp: '000000'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'step_up_failed')));
    // Fehlversuch zählt; der Code gilt nur für einen neuen Zeitschritt
    await admin.api.stepUpCode(totp: await frischerCode(secretAdmin));
    final adminInv = await admin.api.einladungErstellen(rolle: Role.admin, stunden: 1, pin: false);
    expect(adminInv.token, isNotEmpty);
    await admin.api.einladungWiderrufen(adminInv.id);

    schritt('Step-up per Passkey: Optionen kommen an (Konto ohne Passkey: nur Fehler, kein Absturz)');
    await expectLater(
      admin.api.stepUpPasskeyOptionen(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_passkey').having((e) => e.message, 'message', contains('Passkey'))),
    );

    schritt('Rolle ändern widerruft Sitzungen der Person: Kind wird zu Elternteil, seine App merkt es und meldet ab');
    await admin.api.rolleAendern(kindId, Role.parent);
    var kindVerloren = false;
    kind.client.onSessionLost = (_) => kindVerloren = true;
    await expectLater(kind.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
    expect(kindVerloren, isTrue);
    expect(await kind.store.readTokens(), isNull);

    schritt('Wiederherstellungscode-Anmeldung (Kind, neue Sitzung)');
    final kind2 = Gegenstelle(name: 'Kinder-Handy 2');
    final rec = await kind2.api.wiederherstellungAnmelden(email: 'ben@beispiel.de', code: kReg.recoveryCodes.first);
    expect(rec.user.role, Role.parent);
    expect(rec.recoveryCodesRemaining, 9);
    await kind2.client.sitzungUebernehmen(rec.session);
    // gleicher Code ist verbraucht -> eine Meldung für alle Fälle
    await expectLater(
      Gegenstelle().api.wiederherstellungAnmelden(email: 'ben@beispiel.de', code: kReg.recoveryCodes.first),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_credentials').having((e) => e.message, 'message', isNot(contains('Code ist'))) ),
    );
    // Eltern: Kind-Einladungen ja (ohne Freigabe, wenn nicht verlangt), Elternteil nein
    final nachRolle = await kind2.api.einladungErstellen(rolle: Role.child, stunden: 1, pin: false);
    expect(nachRolle.requireApproval, isFalse);
    await expectLater(kind2.api.einladungErstellen(rolle: Role.parent, stunden: 1, pin: false), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
    await expectLater(kind2.api.rolleAendern(adminId, Role.child), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));

    schritt('Neue Wiederherstellungscodes (Step-up), alte entfallen');
    final neueCodes = await admin.api.neueWiederherstellungscodes();
    expect(neueCodes, hasLength(10));
    expect((await admin.api.ich()).recoveryCodesRemaining, 10);

    schritt('Passwort nachträglich: Pfade, Step-up und Fehlercodes (Admin hat schon Passwort und nur diesen Zugang)');
    await expectLater(admin.api.passwortEinrichtenStart('Noch-ein-Passwort-123'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'password_exists')));
    await expectLater(admin.api.passwortAendern('kurz'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'weak_password')));
    await expectLater(admin.api.passwortEntfernen(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'last_credential')));

    // ---------------------------------------------------------------- Refresh (echte Rotation)
    schritt('Refresh: abgelaufenes Access-Token, fünf gleichzeitige Aufrufe -> genau EIN POST /auth/refresh, Rotation gespeichert');
    // eigenes Gerät (eigene Token-Familie), damit der Admin-Zugang des Tests unberührt bleibt
    final basis = Gegenstelle(name: 'Zeitreise-Basis');
    final basisLogin = await basis.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'Contract-Passwort-12', wiederherstellungscode: neueCodes[3]);
    await basis.client.sitzungUebernehmen(basisLogin.session);
    final alt = (await basis.store.readTokens())!;
    final spaeter = Gegenstelle(now: () => DateTime.now().add(const Duration(minutes: 20)), name: 'Zeitreise');
    await spaeter.store.writeTokens(alt);
    await Future.wait([for (var i = 0; i < 5; i++) spaeter.api.ich()]);
    expect(spaeter.spion.zaehle('POST /api/v1/auth/refresh'), 1);
    final rotiert = (await spaeter.store.readTokens())!;
    expect(rotiert.refreshToken, isNot(alt.refreshToken));
    expect(rotiert.accessToken, isNot(alt.accessToken));
    expect(rotiert.deviceId, alt.deviceId);
    // die alte Sitzung des Admin lebt weiter? Rotation betrifft dieselbe Familie: das alte Paar ist ersetzt
    // zweite Erneuerung mit dem NEUEN Paar funktioniert (kein Mehrfach-Einlösen)
    final spaeter2 = Gegenstelle(now: () => DateTime.now().add(const Duration(minutes: 40)), name: 'Zeitreise');
    await spaeter2.store.writeTokens(rotiert);
    await spaeter2.api.ich();
    expect(spaeter2.spion.zaehle('POST /api/v1/auth/refresh'), 1);

    schritt('Wiederverwendung eines alten Refresh-Tokens widerruft die Familie (genau deshalb wird serialisiert)');
    Object? erneut;
    try {
      await spaeter2.client.post('/auth/refresh', {'refreshToken': alt.refreshToken, 'deviceId': alt.deviceId}, false);
    } catch (e) {
      erneut = e;
    }
    expect(erneut, isA<ApiException>().having((e) => e.status, 'status', 401));
    final nachher = Gegenstelle();
    await nachher.store.writeTokens((await spaeter2.store.readTokens())!);
    await expectLater(nachher.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));

    schritt('Toleranzfenster: dieselbe Geräte-ID legt das gerade rotierte Token noch einmal vor (Antwort ging verloren) -> neues Paar, Familie bleibt');
    final tol = Gegenstelle(name: 'Toleranz');
    final tolLogin = await tol.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'Contract-Passwort-12', wiederherstellungscode: neueCodes[4]);
    await tol.client.sitzungUebernehmen(tolLogin.session);
    final t0 = (await tol.store.readTokens())!;
    Future<SessionDto> rotiere() async => SessionDto.fromJson(
      (await tol.client.post('/auth/refresh', {'refreshToken': t0.refreshToken, 'deviceId': t0.deviceId}, false))['session'],
    );
    final erste = await rotiere();
    final zweite = await rotiere(); // gleich noch einmal, innerhalb von 30 Sekunden
    expect(zweite.refreshToken, isNot(erste.refreshToken));
    StoredTokens aus(SessionDto s) => StoredTokens(
      accessToken: s.accessToken!,
      accessExpiresAt: s.accessExpiresAt!,
      refreshToken: s.refreshToken!,
      refreshExpiresAt: s.refreshExpiresAt!,
      deviceId: s.deviceId,
    );
    final lebt = Gegenstelle(name: 'Toleranz-neu');
    await lebt.store.writeTokens(aus(zweite));
    expect((await lebt.api.ich()).user.email, 'anna@beispiel.de');
    final tot = Gegenstelle(name: 'Toleranz-alt');
    await tot.store.writeTokens(aus(erste));
    await expectLater(tot.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));

    // ---------------------------------------------------------------- Sperre / Fehlermeldungen
    schritt('Falsche Anmeldung: invalid_credentials, nach mehreren Fehlversuchen too_many_attempts mit Retry-After');
    final falsch = Gegenstelle();
    ApiException? sperre;
    for (var i = 0; i < 8 && sperre == null; i++) {
      try {
        await falsch.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'falsch', totp: '000000');
      } on ApiException catch (e) {
        if (e.kind == ApiErrorKind.zuVieleAnfragen) {
          sperre = e;
        } else {
          expect(e.code, 'invalid_credentials');
          expect(e.message, contains('Anmeldung hat nicht geklappt'));
        }
      }
    }
    expect(sperre, isNotNull, reason: 'verzögerte Sperre nach Fehlversuchen');
    expect(sperre!.retryAfter, isNotNull);
    expect(sperre.retryAfter!.inSeconds, inInclusiveRange(1, 90));
    expect(sperre.message, contains('Bitte warte'));

    // ---------------------------------------------------------------- Web-Modus (Cookie + CSRF)
    schritt('Web-Modus: Anmeldung per Passkey-losem Weg nicht möglich, daher Passwort + TOTP mit client=web, Cookie, CSRF-Header');
    final web = Gegenstelle(web: true);
    // die IP-Sperre der falschen Versuche gilt nur für Konto+IP (30-90 s): hier läuft ein anderes Konto (Oma)
    final secretOma = gStart.totpSecret;
    final w = await web.api.passwortAnmelden(email: 'oma@beispiel.de', passwort: 'Gast-Passwort-1234', totp: await frischerCode(secretOma));
    expect(w.session.istApp, isFalse);
    expect(w.session.csrfToken, isNotEmpty);
    await web.client.sitzungUebernehmen(w.session);
    expect(web.spion.cookies.keys, contains('__Host-lxsid'));
    final webMe = await web.api.ich();
    expect(webMe.csrfToken, w.session.csrfToken);
    expect(webMe.user.displayName, 'Oma');
    // ändernde Anfrage mit CSRF-Header klappt (Profil ändern)
    await web.api.profilAendern(anzeigename: 'Oma Erna');
    // ohne CSRF-Header: 403 csrf_invalid
    web.client.csrfSetzen(null);
    await expectLater(web.api.profilAendern(anzeigename: 'Oma X'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'csrf_invalid')));
    web.client.csrfSetzen(webMe.csrfToken);
    expect((await web.api.geraete()).any((d) => d.current && d.platform == 'web'), isTrue);

    // ---------------------------------------------------------------- Sync (Phase 1c)
    schritt('Sync: zweites Gerät des Admin, Kind wieder als Kind (Rolle ändern widerruft die Sitzungen), zweite Person (Oma, Kind-Rolle) per Cookie');
    final adminB = Gegenstelle(name: 'Zweitgerät B');
    final adminBLogin = await mitWarten(() => adminB.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'Contract-Passwort-12', wiederherstellungscode: neueCodes[5]));
    await adminB.client.sitzungUebernehmen(adminBLogin.session);
    try {
      await admin.api.rolleAendern(kindId, Role.child);
    } on ApiException catch (e) {
      if (!e.istStepUp) rethrow;
      await admin.api.stepUpCode(totp: await frischerCode(secretAdmin));
      await admin.api.rolleAendern(kindId, Role.child);
    }
    final kind3 = Gegenstelle(name: 'Kinder-Handy 3');
    final k3 = await kind3.api.wiederherstellungAnmelden(email: 'ben@beispiel.de', code: kReg.recoveryCodes[2]);
    expect(k3.user.role, Role.child);
    await kind3.client.sitzungUebernehmen(k3.session);
    await syncVertrag(a: admin, b: adminB, gast: web, kind: kind3, kindId: kindId, adminId: adminId);
    await offlineOnlineVertrag(a: admin, b: adminB);
    await kalenderVertrag(a: admin, b: adminB, gast: web, kind: kind3, kindId: kindId, adminId: adminId);
    await snapshotVertrag(a: admin, b: adminB, gast: web);

    // ---------------------------------------------------------------- Zurücksetzen, Entfernen, Geräte, Abmelden
    schritt('Zurücksetzen: neue Einladung für dasselbe Konto (lookup zeigt reset + Name)');
    final resetInv = await admin.api.mitgliedZuruecksetzen(kindId, stunden: 2, pin: false);
    final rl = await anon.api.einladungPruefen(resetInv.token);
    expect(rl.reset, isTrue);
    expect(rl.displayName, 'Ben');
    expect(parseInviteToken(resetInv.link), resetInv.token);
    final rpk = await anon.api.passkeyRegistrierungStart(token: resetInv.token);
    expect(RegisterRequestType.fromJson(normalisiereOptionen(rpk.options)).user.displayName, 'Ben');

    schritt('Mitglied ablehnen / entfernen');
    final g2 = await admin.api.einladungErstellen(rolle: Role.child, stunden: 1, pin: false, freigabe: true);
    final g2c = Gegenstelle();
    final g2s = await g2c.api.passwortRegistrierungStart(token: g2.token, passwort: 'Gast2-Passwort-123', email: 'opa@beispiel.de', anzeigename: 'Opa');
    await g2c.api.passwortRegistrierungFertig(challengeId: g2s.challengeId, code: await frischerCode(g2s.totpSecret));
    final opa = (await admin.api.mitglieder()).firstWhere((m) => m.displayName == 'Opa');
    await admin.api.ablehnen(opa.id);
    expect((await admin.api.mitglieder()).any((m) => m.displayName == 'Opa'), isFalse);
    final vorEntfernenRev = (await syncen(adminB, [])).rev;
    await admin.api.mitgliedEntfernen(kindId);
    expect((await admin.api.mitglieder()).any((m) => m.id == kindId), isFalse);
    schritt('Sync: Verweise auf das entfernte Mitglied sind mit Änderungseintrag bereinigt');
    final bereinigt = await syncen(adminB, [], since: vorEntfernenRev);
    expect(bereinigt.rev, greaterThan(vorEntfernenRev));
    final kaffee = (await alleSeiten(adminB)).firstWhere((c) => c.entity == 'list_item' && c.fields['text'] == 'Kaffee');
    expect(kaffee.fields['assigneeId'], isNull);
    expect(bereinigt.changes.any((c) => c.entity == 'list_item' && c.fields['text'] == 'Kaffee'), isTrue, reason: 'die Änderung kommt über den Strom');
    await expectLater(admin.api.mitgliedEntfernen(adminId), throwsA(isA<ApiException>()));

    schritt('Geräte: weiteres Gerät des Admin anlegen, einzeln abmelden, dann überall abmelden');
    final adminZwei = Gegenstelle(name: 'Zweitgerät');
    // das Konto ist nach den Fehlversuchen oben noch verzögert gesperrt: so wartet die App laut Retry-After
    LoginResult? al;
    for (var versuch = 0; versuch < 3 && al == null; versuch++) {
      try {
        al = await adminZwei.api.passwortAnmelden(email: 'anna@beispiel.de', passwort: 'Contract-Passwort-12', wiederherstellungscode: neueCodes.first);
      } on ApiException catch (e) {
        if (e.kind != ApiErrorKind.zuVieleAnfragen) rethrow;
        stdout.writeln('    warte ${e.retryAfter!.inSeconds + 1} s (Retry-After)');
        await Future<void>.delayed(e.retryAfter! + const Duration(seconds: 1));
      }
    }
    expect(al, isNotNull);
    await adminZwei.client.sitzungUebernehmen(al!.session);
    final dev = await admin.api.geraete();
    expect(dev.length, greaterThanOrEqualTo(2));
    final anderes = dev.firstWhere((d) => !d.current && d.name == 'Zweitgerät');
    await admin.api.geraetAbmelden(anderes.id);
    await expectLater(adminZwei.api.ich(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.nichtAngemeldet)));
    await admin.api.abmelden();
    await expectLater(admin.api.ich(), throwsA(isA<ApiException>()));
    stdout.writeln('--- Vertrag erfüllt');
  });
}
