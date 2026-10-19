// Lasttest des ICS-Imports gegen den ECHTEN Server mit den STANDARD-Limits des Sync (SYNC_OPS_BURST=100, SYNC_OPS_PER_MINUTE=120, ...):
// 700 Termine (davon 50 Serien mit zusammen 25 Ausnahmen) als ein Import über den echten SyncController (Anfragelimit 429 mit Retry-After),
// danach muss alles auf dem Server stehen und ein zweiter Import darf nichts doppelt anlegen.
// Gehört NICHT zu 'flutter test' (echte Verbindung, dauert mehrere Minuten, ändert die Datenbank). Ablauf wie tool/vertrag_test.dart
// (frische Datenbank, Bootstrap, Server OHNE hohe SYNC_*-Limits starten), dann die Datei nach test/ kopieren:
//   SERVER=http://127.0.0.1:4461 INVITE_TOKEN=<Token> SERVER_DIR=<server/> DATABASE_URL=postgres://… flutter test test/ics_last_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/calendar/ics_import.dart';
import 'package:lx_fampad/data/calendar/ics_parser.dart';
import 'package:lx_fampad/data/calendar/termin_repository.dart';
import 'package:lx_fampad/data/database_provider.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

final server = Platform.environment['SERVER'] ?? 'http://127.0.0.1:4461';
final adminToken = Platform.environment['INVITE_TOKEN']!;
final serverDir = Platform.environment['SERVER_DIR'] ?? '../server';
final datenbank = Platform.environment['DATABASE_URL']!;

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

/// 700 Termine: 650 einzelne (Zeit und ganztägig), 50 wöchentliche Serien, bei 25 davon ein abgesagtes Vorkommen (EXDATE).
String erzeugeIcs() {
  final b = StringBuffer('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:Lasttest\r\n');
  String tag(int n) {
    final d = DateTime.utc(2026, 1, 1).add(Duration(days: n % 700));
    return '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  }

  for (var i = 0; i < 650; i++) {
    b.write('BEGIN:VEVENT\r\nUID:event/$i\r\nSUMMARY:Termin $i\r\nDESCRIPTION:Beschreibung $i\r\n');
    if (i % 3 == 0) {
      b.write('DTSTART;VALUE=DATE:${tag(i)}\r\nDTEND;VALUE=DATE:${tag(i + 1)}\r\n');
    } else {
      b.write('DTSTART;TZID=Europe/Berlin:${tag(i)}T100000\r\nDTEND;TZID=Europe/Berlin:${tag(i)}T110000\r\n');
    }
    b.write('END:VEVENT\r\n');
  }
  for (var i = 0; i < 50; i++) {
    // Beginn an einem Dienstag (2026-01-06 + 7 * k)
    final start = DateTime.utc(2026, 1, 6).add(Duration(days: 7 * (i % 20)));
    String d(DateTime x) => '${x.year}${x.month.toString().padLeft(2, '0')}${x.day.toString().padLeft(2, '0')}';
    b.write('BEGIN:VEVENT\r\nUID:serie/$i\r\nSUMMARY:Serie $i\r\nDTSTART;TZID=Europe/Berlin:${d(start)}T180000\r\nDTEND;TZID=Europe/Berlin:${d(start)}T190000\r\n');
    b.write('RRULE:FREQ=WEEKLY;COUNT=20;BYDAY=TU\r\n');
    if (i < 25) b.write('EXDATE;TZID=Europe/Berlin:${d(start.add(const Duration(days: 14)))}T180000\r\n');
    b.write('END:VEVENT\r\n');
  }
  b.write('END:VCALENDAR\r\n');
  return b.toString();
}

Future<int> zaehle(String sql) async {
  final r = await Process.run('node', [
    '-e',
    "const pg=require('pg');(async()=>{const c=new pg.Client({connectionString:process.env.DATABASE_URL});await c.connect();"
        'const r=await c.query(process.env.SQL);console.log(r.rows[0].n);await c.end()})()',
  ], workingDirectory: serverDir, environment: {'DATABASE_URL': datenbank, 'SQL': sql});
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return int.parse('${r.stdout}'.trim());
}

void main() {
  test('ICS-Import mit 700 Terminen gegen den Server mit Standard-Limits', timeout: const Timeout(Duration(minutes: 30)), () async {
    tzdata.initializeTimeZones();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final store = MemoryTokenStore();
    final client = ApiClient(client: IOClient(), store: store, web: false, base: server);
    final api = FampadApi(client, geraet: () async => DeviceInfo(id: await store.readDeviceId(), name: 'Lasttest', platform: 'android', appVersion: '0.1.0'));
    final start = await api.passwortRegistrierungStart(token: adminToken, passwort: 'Contract-Passwort-12', email: 'anna@beispiel.de', anzeigename: 'Anna');
    final reg = await api.passwortRegistrierungFertig(challengeId: start.challengeId, code: totp(start.totpSecret, DateTime.now().millisecondsSinceEpoch ~/ 30000));
    await client.sitzungUebernehmen(reg.session!);
    final adminId = reg.member.id;

    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tokenStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);
    // erst die Anmeldung laden (Geräte-ID), dann den Sync starten
    await container.read(authProvider.notifier).neuLaden();
    final sync = container.read(syncProvider.notifier);
    final importer = IcsImporter(db: db, store: container.read(syncStoreProvider), ich: () => adminId, beiAenderung: sync.lokaleAenderung);

    final datei = icsLesen(Uint8List.fromList(utf8.encode(erzeugeIcs())));
    expect(datei.termine, hasLength(700));
    final plan = icsPlanen(datei, bestehende: const [], ausnahmen: const {}, rechte: TerminRechte(Role.admin, adminId));
    expect(plan.neu, 700);

    sync.starten();
    final uhr = Stopwatch()..start();
    final bericht = await importer.importieren(plan, sicht: TerminSicht.family, rechte: TerminRechte(Role.admin, adminId));
    stdout.writeln('lokal geschrieben: ${bericht.neu} Termine in ${uhr.elapsed}');
    var letzterStatus = '';
    final ausgangStore = container.read(syncStoreProvider);
    while (await ausgangStore.offeneAnzahl() > 0) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final s = container.read(syncProvider);
      final z = '${s.status.name} offen=${s.offeneAenderungen} ${s.meldung ?? ''}';
      if (z != letzterStatus || uhr.elapsed.inSeconds % 30 < 5) stdout.writeln('[${uhr.elapsed.inSeconds} s] $z');
      letzterStatus = z;
      expect(uhr.elapsed, lessThan(const Duration(minutes: 25)), reason: 'Sync dauert zu lange');
    }
    stdout.writeln('Sync fertig nach ${uhr.elapsed}');

    expect(await zaehle('select count(*)::int as n from termine where deleted_at is null'), 700);
    expect(await zaehle('select count(*)::int as n from termin_ausnahmen where deleted_at is null'), 25);
    expect(await zaehle('select count(*)::int as n from termine where deleted_at is null and ical_uid is not null'), 700);

    // zweiter Import derselben Datei: nichts Neues
    final termine = await db.select(db.termine).get();
    final ausn = <String, List<TerminAusnahme>>{};
    for (final a in await db.select(db.terminAusnahmen).get()) {
      ausn.putIfAbsent(a.terminId, () => []).add(a);
    }
    final plan2 = icsPlanen(datei, bestehende: termine, ausnahmen: ausn, rechte: TerminRechte(Role.admin, adminId));
    expect(plan2.neu, 0);
    expect(plan2.vorhanden, 700);
    sync.stoppen();
  });
}
