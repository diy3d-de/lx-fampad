// Vertragsprüfung gegen den ECHTEN Server (gebauter Server aus server/, PostgreSQL 17): die App-Klassen (ApiClient, FampadApi, DTOs,
// Einladungslink-Parser, Passkey-Optionen) rufen die von der App genutzten Endpunkte einmal real auf. Seit Phase 1c gehört der Sync dazu
// (syncVertrag, offlineOnlineVertrag): zwei Geräte derselben Person, Idempotenz, Konflikte pro Feld, Löschen gewinnt, Validierung, Rechte von
// Kind (inklusive "hidden"-Tombstone), mehrseitiger Snapshot (> 500 Einträge, purged_rev > 0) und Geisterlisten, zwei lokale Datenbanken mit SyncStore und SyncEngine (offline/online), WebSocket "rev N" und
// das Bereinigen von Verweisen beim Entfernen eines Mitglieds, Kalender (kalenderVertrag) und Aufgaben (aufgabenVertrag: Folgeaufgabe mit fester ID, Rechte, Validierung). Der Server muss mit PUBLIC_URL=https://familie.lx-labs.dev laufen (RP-ID).
// Der Chat-Teil (e2eeChatVertrag) prüft die Ende-zu-Ende-Verschlüsselung mit drei Personen und zwei Geräten; er benutzt libsodium, wo vorhanden (Linux/Docker, SODIUM_ERFORDERLICH=1),
// sonst den Fake aus test/support/fake_crypto.dart (gleiche Protokolle, Drahtformat unabhängig vom Verfahren).
// Gehört NICHT zu 'flutter test' (echte Netzverbindung, ändert die Datenbank, dauert ca. 1 Minute wegen der TOTP-Zeitschritte).
// Ablauf: frische Datenbank migrieren, 'node dist/cli/bootstrap.js --family "Familie Vertrag"' (Token aus dem Link), Server starten, dann
//   SERVER=http://127.0.0.1:4460 INVITE_TOKEN=<Token> SERVER_DIR=<server/-Ordner mit node_modules> DATABASE_URL=postgres://… flutter test test/vertrag_test.dart
// Der Server braucht für den Lauf hohe Sync-Limits (SYNC_RATE_LIMIT_MAX, SYNC_REQ_*, SYNC_OPS_*), sonst antwortet der Sync mit 429.
// (die Datei dazu aus tool/ nach test/ kopieren; sie initialisiert kein Widget-Binding, damit HTTP echt läuft).
import 'dart:convert';
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
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/chat/chat_krypto_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/crypto/pw_ablauf.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/chat/nachrichten_inhalt.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/data/sync/sync_engine.dart';
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_socket.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/data/tasks/aufgabe_logik.dart';
import 'package:lx_fampad/data/tasks/aufgabe_repository.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/features/auth/invite_link.dart';
import 'package:passkeys/types.dart' show AuthenticateRequestType, RegisterRequestType;
import 'package:timezone/data/latest_all.dart' as tzdata;

import '../test/support/chat_welt.dart' show TestPerson;
import '../test/support/fake_crypto.dart' show kryptoVarianten;

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

/// Form-gültige e1-Hülle (Base64url, mindestens 153 Zeichen) für die Klartext-Schritte: der Server prüft nur die Form und wertet den Inhalt nie aus.
String e1Text(String s) => 'e1:${base64Url.encode(utf8.encode(s)).replaceAll('=', '')}${'A' * 160}';

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

/// Chat (Phase 1c-3a) gegen den echten Server: Familienchat (einer je Familie), Direktchats nur für ihre Teilnehmer (der Admin sieht den Chat
/// von Kind und Gast nicht), Gruppen mit hidden-Tombstone nur für die entfernte Person, undurchsichtiger Inhalt, Lesestand über zwei Geräte.
/// Liefert die ID des Direktchats Admin/Kind (für die Prüfung beim Entfernen des Kindes).
Future<String> chatVertrag({
  required Gegenstelle a,
  required Gegenstelle b,
  required Gegenstelle gast,
  required Gegenstelle kind,
  required String kindId,
  required String adminId,
}) async {
  // eine dritte Person (Elternteil): der Chat von Kind und Cora ist für den Admin unsichtbar (der Gast ist nie Teil von Chats)
  final coraInv = await a.api.einladungErstellen(rolle: Role.parent, stunden: 1, pin: false);
  final cora = Gegenstelle(name: 'Cora');
  final coraStart = await cora.api.passwortRegistrierungStart(token: coraInv.token, passwort: 'Cora-Passwort-1234', email: 'cora@beispiel.de', anzeigename: 'Cora');
  final coraReg = await cora.api.passwortRegistrierungFertig(challengeId: coraStart.challengeId, code: await frischerCode(coraStart.totpSecret));
  expect(coraReg.status, MemberStatus.active);
  await cora.client.sitzungUebernehmen(coraReg.session!);
  final coraId = coraReg.member.id;
  Iterable<SyncChange> chat(Iterable<SyncChange> l) => l.where((c) => const {'konversation', 'nachricht', 'lesestand'}.contains(c.entity));

  schritt('Chat: Familienchat anlegen, Kind sieht ihn, der Gast nicht, ein zweiter wird abgelehnt');
  final famId = familienchatId((await a.api.ich()).familyId);
  final famOp = neu('konversation', famId, {'art': 'family', 'encVersion': 'e1'});
  final fam = await syncen(a, [famOp]);
  expect(fam.rejected, isEmpty);
  expect(fam.acked, [famOp.opId]);
  expect((await alleSeiten(kind)).where((c) => c.id == famId), hasLength(1));
  expect(chat(await alleSeiten(gast)).where((c) => c.entity == 'konversation').map((c) => c.id), [famId], reason: 'die zweite Person (Oma) ist Mitglied und sieht den Familienchat');
  // ein zweiter (andere ID als die aus der Familie abgeleitete) ist ungültig: kein Hinweis darauf, ob es ihn schon gibt
  expect((await syncen(kind, [neu('konversation', neueUuid(), {'art': 'family'})])).rejected.single.code, 'invalid');
  final famRev = (await alleSeiten(a)).firstWhere((c) => c.id == famId).rev;
  expect((await syncen(a, [aender('konversation', famId, {'titel': 'p1:Neu'}, famRev)])).rejected.single.code, 'forbidden');
  expect((await syncen(a, [weg('konversation', famId, famRev)])).rejected.single.code, 'forbidden');

  schritt('Chat: Nachrichten sind undurchsichtig (Inhalt bleibt unverändert, Hülle e1:), Länge, Autor und Zeit setzt der Server');
  final m1 = neueUuid();
  final r1 = await syncen(kind, [neu('nachricht', m1, {'konversationId': famId, 'text': e1Text('<b>unverändert</b> 👋 e1:')})]);
  expect(r1.rejected, isEmpty);
  // die Hülle muss zur Konversation passen (Klartext p1: ist in einem verschlüsselten Chat ungültig, ebenso eine zu kurze e1-Hülle; der Server prüft nur die Form)
  expect((await syncen(kind, [neu('nachricht', neueUuid(), {'konversationId': famId, 'text': 'p1:Klartext'})])).rejected.single.code, 'invalid');
  expect((await syncen(kind, [neu('nachricht', neueUuid(), {'konversationId': famId, 'text': 'e1:QUJDREVGRw'})])).rejected.single.code, 'invalid');
  final gesehen = (await alleSeiten(a)).firstWhere((c) => c.id == m1);
  expect(gesehen.fields['text'], e1Text('<b>unverändert</b> 👋 e1:'));
  expect(gesehen.fields['autorId'], kindId);
  expect(gesehen.fields['createdAt'], isNotNull);
  expect((await syncen(kind, [neu('nachricht', neueUuid(), {'konversationId': famId, 'text': 'x' * 16385})])).rejected.single.code, 'invalid');
  expect((await syncen(kind, [neu('nachricht', neueUuid(), {'konversationId': famId, 'text': e1Text('x'), 'autorId': adminId})])).rejected.single.code, 'invalid');
  // nur der Autor bearbeitet; der Admin darf im Familienchat fremde Nachrichten löschen
  expect((await syncen(a, [aender('nachricht', m1, {'text': e1Text('gefälscht')}, gesehen.rev)])).rejected.single.code, 'forbidden');
  final m2 = neueUuid();
  await syncen(kind, [neu('nachricht', m2, {'konversationId': famId, 'text': e1Text('weg damit')})]);
  final rev2 = (await alleSeiten(a)).firstWhere((c) => c.id == m2).rev;
  expect((await syncen(a, [weg('nachricht', m2, rev2)])).acked, hasLength(1));

  schritt('Chat: Direktchat Kind/Admin (feste ID je Paar); Direktchat Kind/Cora ist für den Admin unsichtbar und unveränderbar (not_found)');
  final dm = direktChatId(kindId, adminId);
  final dmOp = neu('konversation', dm, {'art': 'direct', 'encVersion': 'e1', 'teilnehmer': [kindId, adminId]..sort()});
  expect((await syncen(kind, [dmOp])).acked, [dmOp.opId]);
  // dasselbe Paar mit anderer ID und aus der anderen Richtung: abgelehnt; dieselbe ID noch einmal: ohne Wirkung
  expect((await syncen(a, [neu('konversation', neueUuid(), {'art': 'direct', 'encVersion': 'e1', 'teilnehmer': [adminId, kindId]})])).rejected.single.code, 'invalid');
  // Squatting: die ID des Paares Admin/Cora kann das Kind nicht für einen eigenen Chat belegen
  expect((await syncen(kind, [neu('konversation', direktChatId(adminId, coraId), {'art': 'direct', 'encVersion': 'e1', 'teilnehmer': [kindId, coraId]})])).rejected.single.code, 'invalid');
  expect((await syncen(kind, [neu('konversation', direktChatId(adminId, coraId), {'art': 'direct', 'encVersion': 'e1', 'teilnehmer': [adminId, coraId]})])).rejected.single.code, 'forbidden');
  expect((await syncen(a, [neu('konversation', dm, {'art': 'direct', 'encVersion': 'e1', 'teilnehmer': [adminId, kindId]})])).rejected, isEmpty);
  final privatId = direktChatId(kindId, coraId);
  expect((await syncen(kind, [neu('konversation', privatId, {'art': 'direct', 'encVersion': 'e1', 'teilnehmer': [kindId, coraId]})])).rejected, isEmpty);
  final geheimMsg = neueUuid();
  expect((await syncen(kind, [neu('nachricht', geheimMsg, {'konversationId': privatId, 'text': e1Text('GEHEIM-TEXT')})])).rejected, isEmpty);
  for (final g in [a, b]) {
    final alle = await alleSeiten(g);
    expect(alle.where((c) => c.id == privatId || c.id == geheimMsg), isEmpty, reason: 'auch der Admin sieht fremde Privatchats nicht');
    expect(alle.where((c) => c.id == dm), hasLength(1));
  }
  final privRev = (await alleSeiten(kind)).firstWhere((c) => c.id == privatId).rev;
  final angriff = await syncen(a, [
    aender('konversation', privatId, {'titel': 'p1:x'}, privRev),
    weg('konversation', privatId, privRev),
    neu('nachricht', neueUuid(), {'konversationId': privatId, 'text': e1Text('Einschleusen')}),
    aender('nachricht', geheimMsg, {'text': e1Text('x')}, 1),
    weg('nachricht', geheimMsg, 1),
  ]);
  expect(angriff.rejected.map((x) => x.code), List.filled(5, 'not_found'));
  expect(angriff.changes.where((c) => c.id == privatId || c.id == geheimMsg), isEmpty);
  expect(chat(await alleSeiten(cora)).where((c) => c.entity == 'konversation').map((c) => c.id), unorderedEquals([famId, privatId]));
  expect(chat(await alleSeiten(gast)).where((c) => c.entity == 'konversation').map((c) => c.id), [famId], reason: 'Privatchats sieht Oma nicht');

  schritt('Chat: Gruppe, Teilnehmer entfernen -> hidden-Tombstone nur für die entfernte Person, Außenstehende erfahren nichts');
  final gruppe = neueUuid();
  expect((await syncen(kind, [neu('konversation', gruppe, {'art': 'group', 'encVersion': 'e1', 'titel': 'p1:Ausflug', 'teilnehmer': [kindId, adminId, coraId]..sort()})])).rejected, isEmpty);
  final vorA = (await syncen(a, [])).rev;
  final vorCora = (await syncen(cora, [])).rev;
  final gRev = (await alleSeiten(kind)).firstWhere((c) => c.id == gruppe).rev;
  expect((await syncen(kind, [aender('konversation', gruppe, {'teilnehmer': [kindId, coraId]..sort()}, gRev)])).rejected, isEmpty);
  final nachA = await syncen(a, [], since: vorA);
  expect(nachA.changes.where((c) => c.id == gruppe).map((c) => (c.tombstone, c.hidden)), [(true, true)]);
  final nachCora = await syncen(cora, [], since: vorCora);
  expect(nachCora.changes.where((c) => c.id == gruppe && c.tombstone), isEmpty, reason: 'wer drin bleibt, bekommt die Änderung, keinen Tombstone');
  expect(nachCora.changes.where((c) => c.id == gruppe && !c.tombstone), hasLength(1));
  // wer nie drin war (der Gast), erfährt nichts: kein Tombstone mit der ID
  expect((await alleSeiten(gast, since: vorCora)).where((c) => c.id == gruppe), isEmpty);
  expect((await syncen(a, [neu('nachricht', neueUuid(), {'konversationId': gruppe, 'text': e1Text('x')})])).rejected.single.code, 'not_found');

  await e2eeChatVertrag(a: a, b: b, kind: kind, cora: cora, adminId: adminId, kindId: kindId, coraId: coraId, altChatId: dm);
  return dm;
}

/// Passwort-Sicherung (PR 3 der vereinfachten Schlüsselverwaltung) gegen den echten Server: nur mit Schalter E2EE_PW_BACKUP (sonst übersprungen und die Routen
/// müssen 404 sein). Salt vom Server, Blob ablegen, Round-Trip, "verifiziert", zweites Gerät öffnet mit dem Passwort, Server speichert nur den opaken Blob,
/// feste Parameter (409 kdf_mismatch), alter Weg (key_backups) bleibt unberührt.
Future<void> pwSicherungVertrag({required Gegenstelle a, required TestPerson anna, required CryptoProvider crypto, required String email}) async {
  schritt('Passwort-Sicherung: Schalter des Servers (GET /version features.pwBackup)');
  final an = await a.api.pwSicherungVerfuegbar();
  if (!an) {
    stdout.writeln('    Schalter E2EE_PW_BACKUP ist aus: Routen müssen 404 sein');
    await expectLater(a.api.kdfParameter(email), throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)));
    await expectLater(a.api.pwSicherungAbrufen(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)));
    return;
  }
  final server = (await a.api.eigeneSchluessel()).schluessel!;
  expect(server.gleichWie(anna.oeffentlich), isTrue);
  final userId = anna.id;
  const passwort = 'Zebra-Kamin-Orbit-Fluss-Lampe';
  final ablauf = PwSicherungAblauf(crypto: crypto, api: a.api, userId: userId, email: email);

  schritt('Passwort-Sicherung: Salt kommt vom Server und ist für dieselbe E-Mail stabil, für andere gleich geformt (kein Konto-Orakel)');
  final k1 = await a.api.kdfParameter(email);
  final k2 = await a.api.kdfParameter(email.toUpperCase());
  final fremd = await a.api.kdfParameter('niemand@beispiel.de');
  expect((k1.id, k1.memKiB, k1.ops), ('argon2id-v1', 65536, 3));
  expect(k2.salt, k1.salt);
  expect((fremd.id, fremd.memKiB, fremd.ops), ('argon2id-v1', 65536, 3));
  expect(fremd.salt, isNot(k1.salt));
  expect(base64urlDekodieren(fremd.salt), hasLength(16));
  await expectLater(a.api.pwSicherungAbrufen(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)), reason: 'noch keine Sicherung');

  schritt('Passwort-Sicherung: lokale Probe, Ablegen, Round-Trip, verifiziert; der Server sieht nur den opaken Blob');
  final entwurf = await ablauf.vorbereiten(lokal: anna.pk, server: server, passwort: passwort);
  final id = await ablauf.ablegenUndPruefen(entwurf, passwort: passwort, lokal: anna.pk, serverVorher: server);
  final zeilen = await dbAbfrage("select id, state, key_version, kdf_id, mem_kib, ops, blob, verified_at is not null as verifiziert from key_backups_pw where user_id = '$userId'");
  expect(zeilen, hasLength(1));
  expect(zeilen.single['id'], id);
  expect((zeilen.single['state'], zeilen.single['key_version'], zeilen.single['kdf_id'], zeilen.single['mem_kib'], zeilen.single['ops']), ('active', 1, 'argon2id-v1', 65536, 3));
  expect(zeilen.single['verifiziert'], isTrue);
  expect(zeilen.single['blob'], entwurf.blob);
  final seeds = anna.pk.exportieren();
  for (final teil in [seeds.sublist(0, 32), seeds.sublist(32)]) {
    expect((zeilen.single['blob'] as String).contains(base64urlKodieren(teil)), isFalse);
  }
  expect(await dbAbfrage("select 1 from audit_log where event like 'key_backup_pw_%' and detail::text like '%${entwurf.blob.substring(10, 30)}%'"), isEmpty, reason: 'nie der Blob im Audit');

  schritt('Passwort-Sicherung: zweites Gerät öffnet mit dem Passwort denselben Schlüssel, falsches Passwort scheitert');
  final nur = PwSicherungAblauf(crypto: crypto, api: a.api, userId: userId, email: email);
  final r = await nur.abrufenUndOeffnen(passwort);
  expect(gleicheBytes(r.schluessel.exportieren(), anna.pk.exportieren()), isTrue);
  expect(r.keyVersion, 1);
  await expectLater(nur.abrufenUndOeffnen('Falsches-Passwort-Tisch-Wolke-Baum'), throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', CryptoFehlerArt.entschluesselung)));

  schritt('Passwort-Sicherung: Abbruch nach dem Ablegen (nie bestätigt): die zuletzt verifizierte bleibt aktuell, das alte Passwort öffnet sie weiter');
  final abgebrochen = await a.api.pwSicherungAblegen(blob: (await ablauf.vorbereiten(lokal: anna.pk, server: server, passwort: 'Nie-Bestaetigt-Wolke-Tisch-Vogel')).blob, keyVersion: 1, kdf: k1);
  expect((await dbAbfrage("select state from key_backups_pw where user_id = '$userId' order by state")).map((z) => z['state']), ['active', 'pending']);
  expect((await a.api.pwSicherungAbrufen()).id, id);
  expect((await a.api.pwSicherungAbrufen(unbestaetigt: true)).id, abgebrochen);
  expect(gleicheBytes((await nur.abrufenUndOeffnen(passwort)).schluessel.exportieren(), anna.pk.exportieren()), isTrue);

  schritt('Passwort-Sicherung: erneutes Anlegen ersetzt erst nach der Bestätigung (alte Zeilen superseded, nie gelöscht); feste Parameter, Version geprüft');
  final id2 = await ablauf.ablegenUndPruefen(
    await ablauf.vorbereiten(lokal: anna.pk, server: server, passwort: 'Anderes-Passwort-Wolke-Tisch-Vogel'),
    passwort: 'Anderes-Passwort-Wolke-Tisch-Vogel',
    lokal: anna.pk,
    serverVorher: server,
  );
  expect(id2, isNot(id));
  expect((await dbAbfrage("select state from key_backups_pw where user_id = '$userId' order by created_at")).map((z) => z['state']), ['superseded', 'superseded', 'active']);
  await expectLater(
    a.api.pwSicherungAblegen(blob: entwurf.blob, keyVersion: 1, kdf: const KdfDto(id: 'argon2id-v1', memKiB: 1024, ops: 1, salt: '')),
    throwsA(isA<ApiException>().having((e) => e.code, 'code', 'kdf_mismatch')),
  );
  await expectLater(
    a.api.pwSicherungAblegen(blob: entwurf.blob, keyVersion: 7, kdf: k1),
    throwsA(isA<ApiException>().having((e) => e.code, 'code', 'key_version_mismatch')),
  );
  await expectLater(a.api.pwSicherungBestaetigen(id), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'backup_not_current')), reason: 'die ersetzte Sicherung lässt sich nicht mehr bestätigen');
}

/// Abfrage der Datenbank (nur lesen, JSON-Zeilen), um zu prüfen, was der Server wirklich speichert.
Future<List<dynamic>> dbAbfrage(String sql) async {
  final r = await Process.run('node', [
    '-e',
    'const pg=require(\x27pg\x27);(async()=>{const c=new pg.Client({connectionString:process.env.DATABASE_URL});await c.connect();'
        'const r=await c.query(process.env.ABFRAGE);console.log(JSON.stringify(r.rows));await c.end()})()',
  ], workingDirectory: serverDir, environment: {'DATABASE_URL': datenbank, 'ABFRAGE': sql});
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return jsonDecode((r.stdout as String).trim()) as List<dynamic>;
}

/// Ein Gerät mit eigener lokaler Datenbank, SyncStore, SyncEngine (mit dem echten Ausgang-Vorbereiter), ChatKrypto und ChatRepository gegen den echten Server.
class E2eeGeraet {
  final Gegenstelle g;
  final TestPerson person;
  final AppDatabase db;
  final SyncStore store;
  late final SyncEngine engine;
  late final ChatKrypto krypto;
  late final ChatRepository repo;
  final Map<String, OeffentlicheSchluessel> tofu = {};
  Map<String, OeffentlicheSchluessel?>? karte;

  E2eeGeraet._(this.g, this.person, this.db, this.store);

  static Future<E2eeGeraet> neu(Gegenstelle g, TestPerson person, CryptoProvider crypto) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final e = E2eeGeraet._(g, person, db, SyncStore(db));
    e.krypto = ChatKrypto(
      crypto: crypto,
      db: db,
      store: e.store,
      ichId: person.id,
      meinSchluessel: person.pk,
      meineKeyVersion: person.version,
      gemerkt: (u, {version}) async => e.tofu[u],
      serverSchluessel: () => e.karte,
      absenderSchluessel: (u, v) async => e.tofu[u]?.version == v ? e.tofu[u]! : throw const CryptoFehler(CryptoFehlerArt.signatur, 'Absender nicht bestätigt'),
    );
    e.engine = SyncEngine(
      store: e.store,
      api: g.api,
      geraeteId: () async => geraetId(g),
      vorbereiter: ChatOpVorbereiter(db: db, krypto: () async => e.krypto),
    );
    e.repo = ChatRepository(
      db: db,
      store: e.store,
      inhalt: const KlartextHuelle(),
      krypto: () async => e.krypto,
      ich: () => person.id,
      familie: () => null,
      beiAenderung: () {},
    );
    return e;
  }

  /// Mitglieder und ihre öffentlichen Schlüssel vom Server (Vertrauen beim ersten Sehen: neue Personen werden gemerkt).
  Future<void> mitgliederLernen() async {
    final mitglieder = await g.api.mitglieder();
    karte = {
      for (final m in mitglieder)
        if (m.status == MemberStatus.active) m.id: m.schluessel,
    };
    for (final m in mitglieder) {
      if (m.id != person.id && m.schluessel != null) tofu.putIfAbsent(m.id, () => m.schluessel!);
    }
    krypto.vertrauenGeaendert();
  }

  /// Abgleich wie die App: senden, übernehmen, Schlüsselbund auffrischen, bis nichts mehr zu tun ist.
  Future<void> abgleichen() async {
    for (var i = 0; i < 4; i++) {
      final r = await engine.abgleichen();
      expect(r.ok, isTrue, reason: 'Abgleich: ${r.ausgang} ${r.meldung}');
      await krypto.aktualisieren();
    }
  }

  Future<String> lesen(String konversationId, String nachrichtId) async {
    final n = await (db.select(db.nachrichten)..where((x) => x.id.equals(nachrichtId))).getSingle();
    final d = await krypto.nachrichtOeffnen(konversationId: konversationId, nachrichtId: n.id, autorId: n.autorId, wire: n.inhalt, antwortAuf: n.antwortAuf);
    return d.lesbar ? d.text : '<${d.hinweis}>';
  }
}

/// Chat Ende-zu-Ende (E2EE Phase 2) gegen den echten Server: drei Personen mit Schlüsseln, Gruppe, zwei Geräte, Admin liest Privatchat nicht, Server sieht nur Chiffretext
/// und Wraps, Entfernen rotiert, gleichzeitige Rotation (erster gewinnt), p1 in e1 wird abgelehnt, nur der Empfänger bekommt seinen Wrap.
Future<void> e2eeChatVertrag({
  required Gegenstelle a,
  required Gegenstelle b,
  required Gegenstelle kind,
  required Gegenstelle cora,
  required String adminId,
  required String kindId,
  required String coraId,
  required String altChatId,
}) async {
  final (cname, crypto) = (await kryptoVarianten()).last;
  stdout.writeln('    Krypto: $cname');
  final annaP = TestPerson(adminId, 'Anna', crypto);
  final benP = TestPerson(kindId, 'Ben', crypto);
  final coraP = TestPerson(coraId, 'Cora', crypto);

  schritt('Chat Ende-zu-Ende: Schlüssel einrichten (öffentliche Schlüssel beim Server), Mitglieder und Schlüssel kommen mit /members');
  for (final (g, p) in [(a, annaP), (kind, benP), (cora, coraP)]) {
    final k = await g.api.schluesselAnlegen(enc: p.oeffentlich.encBase64, sign: p.oeffentlich.signBase64);
    expect(k.version, 1);
  }
  final annaA = await E2eeGeraet.neu(a, annaP, crypto);
  final annaB = await E2eeGeraet.neu(b, annaP, crypto); // zweites Gerät derselben Person: derselbe Personenschlüssel
  final ben = await E2eeGeraet.neu(kind, benP, crypto);
  final coraG = await E2eeGeraet.neu(cora, coraP, crypto);
  final alle = [annaA, annaB, ben, coraG];
  for (final g in alle) {
    addTearDown(g.db.close);
    await g.mitgliederLernen();
    expect(g.karte!.length, greaterThanOrEqualTo(3));
  }
  Future<void> abgleich(Iterable<E2eeGeraet> gs) async {
    for (var runde = 0; runde < 2; runde++) {
      for (final g in gs) {
        await g.abgleichen();
      }
    }
  }

  await pwSicherungVertrag(a: a, anna: annaP, crypto: crypto, email: 'anna@beispiel.de');

  schritt('Chat Ende-zu-Ende: Gruppe aus drei Personen (Epoche 1, ein Wrap je Person), A sendet, alle lesen, zwei Geräte von Anna lesen dasselbe');
  final gruppe = await annaA.repo.gruppeAnlegen([kindId, coraId], name: 'Vertrag-Gruppe');
  await abgleich(alle);
  final m1 = (await annaA.repo.senden(gruppe, 'GEHEIMER-TEXT-123 👋'))!;
  await abgleich(alle);
  for (final g in alle) {
    expect(await g.lesen(gruppe, m1), 'GEHEIMER-TEXT-123 👋', reason: g.person.name);
  }
  expect(gleicheBytes(annaA.krypto.schluessel(gruppe, 1)!, annaB.krypto.schluessel(gruppe, 1)!), isTrue, reason: 'zwei Geräte, gleiche Epochenschlüssel');

  schritt('Chat Ende-zu-Ende: der Server speichert nur Chiffretext, Mitgliederliste und Wraps (kein Klartext, kein Schlüssel)');
  final texte = await dbAbfrage("select text from nachrichten where konversation_id = '$gruppe'");
  expect(texte, hasLength(1));
  expect(texte.single['text'], startsWith('e1:'));
  expect(texte.single['text'], isNot(contains('GEHEIM')));
  expect(await dbAbfrage("select 1 from konversation_epochen where konversation_id = '$gruppe'"), hasLength(1));
  expect(await dbAbfrage("select 1 from epoche_wraps where konversation_id = '$gruppe'"), hasLength(3));
  expect(await dbAbfrage("select 1 from change_log where changes::text like '%GEHEIMER%'"), isEmpty, reason: 'nie Klartext im Änderungsprotokoll');
  expect(await dbAbfrage("select 1 from nachrichten where text like 'l1:%' or text like 'p1:%' and konversation_id = '$gruppe'"), isEmpty);

  schritt('Chat Ende-zu-Ende: nur der Empfänger bekommt seinen Wrap; Epochen sehen nur Teilnehmer');
  for (final g in [annaA, ben, coraG]) {
    final alleChanges = await alleSeiten(g.g);
    final wraps = alleChanges.where((c) => c.entity == 'epoche_wrap' && c.fields['konversationId'] == gruppe);
    expect(wraps.map((c) => c.fields['empfaengerId']).toSet(), {g.person.id}, reason: g.person.name);
  }

  schritt('Chat Ende-zu-Ende: Admin liest einen Privatchat von Kind und Cora nicht (kein Wrap, keine Epoche, keine Nachricht)');
  // (das Paar Kind/Cora hat aus den Klartext-Schritten oben schon einen p1-Direktchat: hier eine verschlüsselte Zweiergruppe)
  final privat = await ben.repo.gruppeAnlegen([coraId], name: 'Privat');
  await abgleich([ben, coraG]);
  final pm = (await ben.repo.senden(privat, 'NUR-FUER-CORA'))!;
  await abgleich([ben, coraG]);
  expect(await coraG.lesen(privat, pm), 'NUR-FUER-CORA');
  for (final g in [annaA, annaB]) {
    await abgleich([g]);
    final seiten = await alleSeiten(g.g);
    expect(seiten.where((c) => c.id == privat || c.fields['konversationId'] == privat), isEmpty, reason: 'weder Chat noch Epoche, Wrap oder Nachricht');
    expect(g.krypto.schluessel(privat, 1), isNull);
  }
  // auch ein Angriff auf die Epochen eines fremden Chats scheitert unauffindbar
  final angriff = await syncen(a, [
    neu('epoche', epocheId(privat, 2), {'konversationId': privat, 'epoche': 2, 'mitglieder': 'A' * 200}),
    neu('epoche_wrap', wrapId(privat, 1, adminId), {'konversationId': privat, 'epoche': 1, 'empfaengerId': adminId, 'wrap': 'B' * 100}),
  ]);
  expect(angriff.rejected.map((x) => x.code), ['not_found', 'not_found']);

  schritt('Chat Ende-zu-Ende: p1 (Klartext) in einem verschlüsselten Chat wird abgelehnt, die Hülle wird nur in Form geprüft');
  expect((await syncen(a, [neu('nachricht', neueUuid(), {'konversationId': gruppe, 'text': 'p1:Klartext'})])).rejected.single.code, 'invalid');
  expect((await syncen(a, [neu('nachricht', neueUuid(), {'konversationId': gruppe, 'text': 'e1:kurz'})])).rejected.single.code, 'invalid');
  expect((await syncen(a, [neu('nachricht', neueUuid(), {'konversationId': gruppe, 'text': 'l1:Lokal'})])).rejected.single.code, 'invalid');
  final rev = (await alleSeiten(a)).firstWhere((c) => c.id == gruppe).rev;
  expect((await syncen(a, [aender('konversation', gruppe, {'encVersion': 'p1'}, rev)])).rejected.single.code, 'invalid', reason: 'kein Zurückstufen');

  schritt('Chat Ende-zu-Ende: Cora wird entfernt: neue Epoche nur für Anna und Ben, Cora liest Neues nicht');
  await annaA.repo.teilnehmerAendern(gruppe, weg: {coraId});
  await abgleich([annaA, ben, coraG]);
  expect(await dbAbfrage("select 1 from konversation_epochen where konversation_id = '$gruppe'"), hasLength(2));
  final wraps2 = await dbAbfrage("select empfaenger_id from epoche_wraps where konversation_id = '$gruppe' and epoche = 2");
  expect({for (final w in wraps2) w['empfaenger_id']}, {adminId, kindId});
  final m2 = (await annaA.repo.senden(gruppe, 'NACH-DEM-ENTFERNEN'))!;
  await abgleich([annaA, ben, coraG]);
  expect(await ben.lesen(gruppe, m2), 'NACH-DEM-ENTFERNEN');
  expect(coraG.krypto.epochenMitSchluessel(gruppe), isEmpty, reason: 'Cora bekommt den hidden-Tombstone, die Konversation samt Schlüsseln verschwindet bei ihr');
  expect((await alleSeiten(cora)).where((c) => c.id == gruppe || c.fields['konversationId'] == gruppe), isEmpty);

  schritt('Chat Ende-zu-Ende: gleichzeitige Rotation zweier Geräte: der erste gewinnt, der zweite übernimmt dessen Epoche und sendet damit');
  for (final g in [annaA, ben]) {
    await g.store.aendernMehrere(await g.krypto.epocheErstellen(konversationId: gruppe, mitglieder: {adminId, kindId}));
  }
  final m3 = (await ben.repo.senden(gruppe, 'NACH-DER-ROTATION'))!;
  await annaA.abgleichen(); // Anna gewinnt Epoche 3
  await abgleich([ben, annaA]);
  expect(await dbAbfrage("select 1 from konversation_epochen where konversation_id = '$gruppe' and epoche = 3"), hasLength(1));
  expect(await dbAbfrage("select 1 from epoche_wraps where konversation_id = '$gruppe' and epoche = 3"), hasLength(2));
  expect(await annaA.lesen(gruppe, m3), 'NACH-DER-ROTATION');
  expect(await ben.lesen(gruppe, m3), 'NACH-DER-ROTATION');
  expect(gleicheBytes(ben.krypto.schluessel(gruppe, 3)!, annaA.krypto.schluessel(gruppe, 3)!), isTrue);

  schritt('Chat Ende-zu-Ende: Lesestand des zweiten Geräts gilt auch auf dem ersten');
  await abgleich([annaB]); // erst den Stand holen (die Nachricht von Ben), dann lesen
  expect((await annaB.repo.uebersicht(adminId).first).firstWhere((e) => e.id == gruppe).ungelesen, greaterThan(0));
  await annaB.repo.gelesenSetzen(gruppe);
  await abgleich([annaB, annaA]);
  expect((await annaA.repo.uebersicht(adminId).first).firstWhere((e) => e.id == gruppe).ungelesen, 0);
  expect(altChatId, isNotEmpty);
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

/// Aufgaben gegen den echten Server (Phase 1c-4a): Aufgabe mit Unteraufgaben und Wiederholung auf zwei lokalen Datenbanken, Folgeaufgabe mit fester ID
/// (beide Geräte erledigen dieselbe Aufgabe: genau eine Folgeaufgabe), Validierung, Rechte des Kindes, Löschen räumt Unteraufgaben auf.
Future<void> aufgabenVertrag({
  required Gegenstelle a,
  required Gegenstelle b,
  required Gegenstelle kind,
  required String kindId,
  required String adminId,
}) async {
  schritt('Aufgaben: Aufgabe mit Unteraufgaben und Wiederholung auf zwei lokalen Datenbanken (A legt an, B sieht dasselbe)');
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();
  AppDatabase neueDb() => AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  final dbA = neueDb(), dbB = neueDb();
  addTearDown(dbA.close);
  addTearDown(dbB.close);
  final storeA = SyncStore(dbA), storeB = SyncStore(dbB);
  final engineA = SyncEngine(store: storeA, api: a.api, geraeteId: () async => geraetId(a));
  final engineB = SyncEngine(store: storeB, api: b.api, geraeteId: () async => geraetId(b));
  final heute = DateTime.now();
  final repoA = AufgabeRepository(db: dbA, store: storeA, ich: () => adminId, beiAenderung: () {}, jetzt: () => heute);
  final repoB = AufgabeRepository(db: dbB, store: storeB, ich: () => adminId, beiAenderung: () {}, jetzt: () => heute);
  // die lokalen Datenbanken holen zuerst, was schon da ist (Listen, Termine ...): Aufgaben gibt es noch keine
  expect((await engineA.abgleichen()).ok, isTrue);
  expect((await engineB.abgleichen()).ok, isTrue);

  final tagWand = DateTime.utc(heute.year, heute.month, heute.day);
  final id = await repoA.anlegen(AufgabeEingabe(
    titel: 'Altglas wegbringen',
    beschreibung: 'Container an der Ecke',
    faellig: tagWand,
    prioritaet: AufgabePrio.hoch,
    zustaendig: kindId,
    wiederholung: AufgabeWdh.woechentlich,
    punkte: const [PunktEingabe(id: '00000000-0000-4000-8000-0000000000a1', text: 'Flaschen sammeln'), PunktEingabe(id: '00000000-0000-4000-8000-0000000000a2', text: 'Deckel ab', erledigt: true)],
  ));
  expect((await engineA.abgleichen()).ok, isTrue);
  expect((await engineB.abgleichen()).ok, isTrue);
  final beiB = (await dbB.select(dbB.aufgaben).get()).singleWhere((t) => t.id == id);
  expect([beiB.titel, beiB.prioritaet, beiB.assigneeId, beiB.wiederholung, beiB.ownerId], ['Altglas wegbringen', 3, kindId, 'weekly', adminId]);
  expect(beiB.faelligDate, tagText(tagWand));
  expect((await dbB.select(dbB.aufgabePunkte).get()).map((p) => p.inhalt).toSet(), {'Flaschen sammeln', 'Deckel ab'});

  schritt('Aufgaben: beide Geräte erledigen dieselbe wiederkehrende Aufgabe (eine Folgeaufgabe, kein Fehler)');
  await repoA.erledigt((await dbA.select(dbA.aufgaben).get()).singleWhere((t) => t.id == id), true);
  await repoB.erledigt(beiB, true);
  expect((await engineA.abgleichen()).ok, isTrue);
  final rb = await engineB.abgleichen();
  expect(rb.ok, isTrue);
  expect((await engineA.abgleichen()).ok, isTrue);
  final folgeId = folgeAufgabeId(id);
  for (final db in [dbA, dbB]) {
    final alle = await db.select(db.aufgaben).get();
    expect(alle, hasLength(2));
    final folge = alle.singleWhere((t) => t.id == folgeId);
    expect([folge.titel, folge.erledigtAt, folge.assigneeId, folge.wiederholung], ['Altglas wegbringen', null, kindId, 'weekly']);
    expect(alle.singleWhere((t) => t.id == id).erledigtAt, isNotNull);
    expect((await db.select(db.aufgabePunkte).get()).where((p) => p.aufgabeId == folgeId && p.doneAt == null), hasLength(2));
  }
  expect(await storeA.offeneAnzahl(), 0);
  expect(await storeB.offeneAnzahl(), 0);

  schritt('Aufgaben: der Server lehnt ungültige Aufgaben ab (Fälligkeit, Zeitzone, Priorität, Wiederholung, Längen, Person), nichts landet im Datenbestand');
  final vorher = (await alleSeiten(a)).where((c) => c.entity == 'aufgabe').length;
  for (final schlecht in <Map<String, dynamic>>[
    {'titel': 'T', 'faelligDate': '2027-02-30'},
    {'titel': 'T', 'faelligDate': '2027-03-01', 'faelligUtc': '2027-03-01T08:00:00Z', 'tzid': 'Europe/Berlin'},
    {'titel': 'T', 'faelligUtc': '2027-03-01T08:00:00Z'},
    {'titel': 'T', 'faelligUtc': '2027-03-01T08:00:00Z', 'tzid': 'Mars/Olympus'},
    {'titel': 'T', 'prioritaet': 7},
    {'titel': 'T', 'wiederholung': 'yearly'},
    {'titel': 'x' * 201},
    {'titel': 'T', 'erinnerungMin': -5},
  ]) {
    final r = await syncen(a, [neu('aufgabe', neueUuid(), schlecht)]);
    expect(r.rejected.single.code, 'invalid', reason: '$schlecht');
  }
  final fremdePerson = await syncen(a, [neu('aufgabe', neueUuid(), {'titel': 'T', 'assigneeId': neueUuid()})]);
  expect(fremdePerson.rejected.single.code, 'invalid_reference');
  expect((await alleSeiten(a)).where((c) => c.entity == 'aufgabe').length, vorher);

  schritt('Aufgaben: Rechte des Kindes gegen den echten Server');
  final privat = neueUuid(), eltern = neueUuid();
  expect((await syncen(a, [neu('aufgabe', privat, {'titel': 'Nur Eltern', 'audience': 'parents'}), neu('aufgabe', eltern, {'titel': 'Für alle', 'audience': 'all'})])).rejected, isEmpty);
  final eigene = neueUuid();
  final eigeneOp = neu('aufgabe', eigene, {'titel': 'Kinder-Aufgabe', 'assigneeId': kindId});
  expect((await syncen(kind, [eigeneOp])).acked, [eigeneOp.opId]);
  expect((await syncen(kind, [aender('aufgabe', eigene, {'erledigtAt': DateTime.now().toUtc().toIso8601String()}, 900000000)])).rejected, isEmpty);
  // erledigtVon setzt der Server: ein Client-Wert ist ungültig, das Erledigen setzt den Akteur
  expect((await syncen(kind, [aender('aufgabe', eigene, {'erledigtVon': adminId}, 2)])).rejected.single.code, 'invalid');
  final vonKind = (await alleSeiten(kind)).firstWhere((c) => c.id == eigene);
  expect(vonKind.fields['erledigtVon'], kindId);
  expect((await syncen(kind, [aender('aufgabe', eltern, {'titel': 'Hack'}, 1)])).rejected.single.code, 'forbidden');
  expect((await syncen(kind, [aender('aufgabe', privat, {'titel': 'Hack'}, 1)])).rejected.single.code, 'not_found');
  expect((await syncen(kind, [neu('aufgabe', neueUuid(), {'titel': 'Geheim', 'audience': 'parents'})])).rejected.single.code, 'forbidden');
  expect((await syncen(kind, [neu('aufgabe_punkt', neueUuid(), {'aufgabeId': eltern, 'text': 'x'})])).rejected.single.code, 'forbidden');
  final kindSicht = (await alleSeiten(kind)).where((c) => c.entity == 'aufgabe').map((c) => c.id);
  expect(kindSicht, isNot(contains(privat)));
  expect(kindSicht, containsAll([eltern, eigene]));

  schritt('Aufgaben: zugewiesenes Kind setzt nur Status und Häkchen; alles andere, Anlegen/Löschen von Unteraufgaben und Löschen verboten');
  final zugew = neueUuid(), zugewPunkt = neueUuid();
  expect((await syncen(a, [neu('aufgabe', zugew, {'titel': 'Zugewiesen', 'assigneeId': kindId}), neu('aufgabe_punkt', zugewPunkt, {'aufgabeId': zugew, 'text': 'Schritt'})])).rejected, isEmpty);
  final jetzt = DateTime.now().toUtc().toIso8601String();
  final okOp = aender('aufgabe', zugew, {'erledigtAt': jetzt}, 900000000);
  expect((await syncen(kind, [okOp])).acked, [okOp.opId]);
  expect((await syncen(kind, [aender('aufgabe_punkt', zugewPunkt, {'doneAt': jetzt}, 900000000)])).rejected, isEmpty);
  expect((await alleSeiten(kind)).firstWhere((c) => c.id == zugew).fields['erledigtVon'], kindId);
  for (final f in <Map<String, dynamic>>[{'titel': 'x'}, {'assigneeId': kindId}, {'audience': 'parents'}]) {
    expect((await syncen(kind, [aender('aufgabe', zugew, f, 2)])).rejected.single.code, 'forbidden', reason: '$f');
  }
  expect((await syncen(kind, [weg('aufgabe', zugew, 2)])).rejected.single.code, 'forbidden');
  expect((await syncen(kind, [aender('aufgabe_punkt', zugewPunkt, {'text': 'neu'}, 2)])).rejected.single.code, 'forbidden');
  expect((await syncen(kind, [neu('aufgabe_punkt', neueUuid(), {'aufgabeId': zugew, 'text': 'mehr'})])).rejected.single.code, 'forbidden');
  await syncen(a, [weg('aufgabe', zugew, 1)]);

  schritt('Aufgaben: Löschen räumt die Unteraufgaben auf beiden Geräten ab');
  await syncen(a, [weg('aufgabe', privat, 1), weg('aufgabe', eltern, 1), weg('aufgabe', eigene, 1)]);
  await repoA.loeschen(id);
  await repoA.loeschen(folgeId);
  expect((await engineA.abgleichen()).ok, isTrue);
  expect((await engineB.abgleichen()).ok, isTrue);
  for (final db in [dbA, dbB]) {
    expect(await db.select(db.aufgaben).get(), isEmpty);
    expect(await db.select(db.aufgabePunkte).get(), isEmpty);
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
    await aufgabenVertrag(a: admin, b: adminB, kind: kind3, kindId: kindId, adminId: adminId);
    await snapshotVertrag(a: admin, b: adminB, gast: web);
    final chatDm = await chatVertrag(a: admin, b: adminB, gast: web, kind: kind3, kindId: kindId, adminId: adminId);

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
    // Chat: der Direktchat mit dem entfernten Kind ist für den Admin als gelöscht markiert (Tombstone, nicht hidden)
    expect(bereinigt.changes.where((c) => c.id == chatDm).map((c) => (c.tombstone, c.hidden)), [(true, false)]);
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
