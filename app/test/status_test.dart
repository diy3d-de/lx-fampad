// Familien-Status: feste ID (Known-Answer wie auf dem Server), reine Logik (Gültigkeit, Ablauf-Auswahl in Europe/Berlin, Texte), eigenen Status lokal schreiben (Ausgang),
// Schalter in `sync_meta`, Anzeige gegen die Uhr.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart' show authProvider;
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/status/status_logik.dart';
import 'package:lx_fampad/data/status/status_state.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  test('Feste ID: Known-Answer wie server/test/sync-status.test.ts', () {
    const u = '22222222-2222-4222-8222-222222222222';
    expect(statusId(u), 'c3d1a94a-9984-5393-8cfe-8b4475df5371');
    expect(statusId(u.toUpperCase()), statusId(u));
    expect(statusId('33333333-3333-4333-8333-333333333333'), isNot(statusId(u)));
  });

  group('Gültigkeit', () {
    final jetzt = DateTime.utc(2026, 10, 27, 12);
    test('ohne Ende gilt immer; mit Ende bis zum Ende, danach nicht mehr', () {
      expect(statusGilt(null, jetzt), isTrue);
      expect(statusGilt(jetzt.add(const Duration(minutes: 1)), jetzt), isTrue);
      expect(statusGilt(jetzt, jetzt), isFalse);
      expect(statusGilt(jetzt.subtract(const Duration(days: 3)), jetzt), isFalse);
    });

    test('geltendeStati: abgelaufene und leere fallen weg, jede Person nur einmal', () {
      final liste = geltendeStati([
        StatusEintrag(userId: 'a', text: 'Beim Sport', bis: jetzt.add(const Duration(hours: 1))),
        StatusEintrag(userId: 'b', text: 'Lernen', bis: jetzt.subtract(const Duration(minutes: 1))),
        const StatusEintrag(userId: 'c', text: 'Unterwegs'),
        const StatusEintrag(userId: 'd', text: '   '),
        const StatusEintrag(userId: 'a', text: 'doppelt'),
      ], jetzt);
      expect([for (final s in liste) s.userId], ['a', 'c']);
      expect(liste.first.text, 'Beim Sport');
    });
  });

  group('Text', () {
    test('trimmt, lehnt leer, zu lang und unzulässige Zeichen ab', () {
      expect(statusTextPruefen('  Beim Sport '), 'Beim Sport');
      expect(statusTextPruefen('x' * 60), 'x' * 60);
      expect(statusTextPruefen('x' * 61), isNull);
      expect(statusTextPruefen(''), isNull);
      expect(statusTextPruefen('   '), isNull);
      expect(statusTextPruefen('Zeile\nZwei'), isNull);
      expect(statusTextPruefen('Tab\tstopp'), isNull);
      expect(statusTextPruefen('Unsicht\u200Bbar'), isNull);
      expect(statusTextPruefen('Rück\u202Ewärts'), isNull);
      expect(statusTextPruefen('Mädchen-Abend 🎉'), 'Mädchen-Abend 🎉');
    });
  });

  group('Ablauf in der Familienzeitzone (Europe/Berlin)', () {
    // 27.10.2026: Winterzeit (MEZ, UTC+1) seit dem 25.10.
    test('1 und 3 Stunden', () {
      final jetzt = DateTime.utc(2026, 10, 27, 10);
      expect(StatusAblauf.einStunde.ende(jetzt), DateTime.utc(2026, 10, 27, 11));
      expect(StatusAblauf.dreiStunden.ende(jetzt), DateTime.utc(2026, 10, 27, 13));
      expect(StatusAblauf.ohneEnde.ende(jetzt), isNull);
    });

    test('Heute Abend = 22 Uhr Wanduhr (21 Uhr UTC im Winter), nur wenn noch mindestens eine Stunde bleibt', () {
      final nachmittag = DateTime.utc(2026, 10, 27, 14); // 15:00 Berlin
      expect(StatusAblauf.heuteAbend.ende(nachmittag), DateTime.utc(2026, 10, 27, 21));
      expect(statusAblaufOptionen(nachmittag), contains(StatusAblauf.heuteAbend));
      final spaet = DateTime.utc(2026, 10, 27, 20, 30); // 21:30 Berlin
      expect(statusAblaufOptionen(spaet), isNot(contains(StatusAblauf.heuteAbend)));
      expect(statusAblaufOptionen(spaet), contains(StatusAblauf.morgenFrueh));
    });

    test('Heute Abend im Sommer: 22 Uhr MESZ = 20 Uhr UTC', () {
      expect(StatusAblauf.heuteAbend.ende(DateTime.utc(2026, 7, 1, 12)), DateTime.utc(2026, 7, 1, 20));
    });

    test('Morgen früh = der nächste 7-Uhr-Zeitpunkt, der mindestens eine Stunde entfernt liegt', () {
      // 27.10. 20:00 Berlin -> 28.10. 07:00 Berlin = 06:00 UTC
      expect(StatusAblauf.morgenFrueh.ende(DateTime.utc(2026, 10, 27, 19)), DateTime.utc(2026, 10, 28, 6));
      // 28.10. 02:00 Berlin (nachts): heute 07:00 Berlin
      expect(StatusAblauf.morgenFrueh.ende(DateTime.utc(2026, 10, 28, 1)), DateTime.utc(2026, 10, 28, 6));
      // 28.10. 06:30 Berlin: weniger als eine Stunde bis 7 Uhr -> übermorgen früh... nein, der nächste Tag
      expect(StatusAblauf.morgenFrueh.ende(DateTime.utc(2026, 10, 28, 5, 30)), DateTime.utc(2026, 10, 29, 6));
    });

    test('alle Enden liegen höchstens 7 Tage voraus', () {
      final jetzt = DateTime.utc(2026, 10, 27, 12);
      for (final a in StatusAblauf.values) {
        final e = a.ende(jetzt);
        if (e != null) expect(e.difference(jetzt) <= const Duration(days: kStatusMaxTage), isTrue, reason: a.name);
      }
    });
  });

  group('Text des Endes', () {
    final jetzt = DateTime.utc(2026, 10, 27, 14); // Dienstag 15:00 Berlin
    test('heute, morgen, später, ohne Ende', () {
      expect(statusBisText(DateTime.utc(2026, 10, 27, 17), jetzt), 'bis 18:00');
      expect(statusBisText(DateTime.utc(2026, 10, 28, 6), jetzt), 'bis morgen 07:00');
      expect(statusBisText(DateTime.utc(2026, 10, 30, 16, 30), jetzt), 'bis Fr 17:30');
      expect(statusBisText(null, jetzt), 'ohne Ende');
    });
  });

  group('Eigenen Status schreiben', () {
    late TestUmgebung env;
    late AppDatabase db;
    final fest = DateTime.utc(2026, 10, 27, 14);
    late StatusRepository repo;

    setUp(() async {
      env = await angemeldeteUmgebung();
      db = env.db;
      repo = StatusRepository(db: db, store: SyncStore(db), ich: () => fixIdAdmin, beiAenderung: () {}, jetzt: () => fest);
    });

    test('setzen legt die Zeile mit fester ID an und stellt eine Op in den Ausgang', () async {
      expect(await repo.setzen('  Beim Sport ', fest.add(const Duration(hours: 3))), isTrue);
      final z = await db.select(db.familienStati).getSingle();
      expect(z.id, statusId(fixIdAdmin));
      expect(z.userId, fixIdAdmin);
      expect(z.statusText, 'Beim Sport');
      expect(z.bis!.isAtSameMomentAs(fest.add(const Duration(hours: 3))), isTrue);
      final op = (await db.select(db.outbox).get()).single;
      expect(op.entity, 'status');
      expect(op.entityId, statusId(fixIdAdmin));
      final felder = jsonDecode(op.fieldsJson) as Map<String, dynamic>;
      expect(felder, {'userId': fixIdAdmin, 'text': 'Beim Sport', 'bis': '2026-10-27T17:00:00.000Z'});
    });

    test('ohne Ende wird bis null gesendet; ändern verschmilzt mit der noch nicht gesendeten Op', () async {
      await repo.setzen('Unterwegs', null);
      await repo.setzen('Lernen', null);
      final ops = await db.select(db.outbox).get();
      expect(ops, hasLength(1));
      expect(jsonDecode(ops.single.fieldsJson), containsPair('bis', null));
      expect((await db.select(db.familienStati).getSingle()).statusText, 'Lernen');
    });

    test('ungültig: nichts wird geschrieben (leer, zu lang, Ende vorbei oder mehr als 7 Tage weg)', () async {
      expect(await repo.setzen('', null), isFalse);
      expect(await repo.setzen('x' * 61, null), isFalse);
      expect(await repo.setzen('Okay', fest), isFalse);
      expect(await repo.setzen('Okay', fest.subtract(const Duration(hours: 1))), isFalse);
      expect(await repo.setzen('Okay', fest.add(const Duration(days: 8))), isFalse);
      expect(await db.select(db.familienStati).get(), isEmpty);
      expect(await db.select(db.outbox).get(), isEmpty);
    });

    test('löschen: ein vom Server bestätigter Status bekommt eine Löschung im Ausgang, ein nie gesendeter verschwindet spurlos', () async {
      await repo.setzen('Unterwegs', null);
      await repo.loeschen();
      expect(await db.select(db.familienStati).get(), isEmpty);
      expect(await db.select(db.outbox).get(), isEmpty);

      await repo.setzen('Unterwegs', null);
      await (db.update(db.familienStati)).write(const FamilienStatiCompanion(rev: Value(3)));
      await db.delete(db.outbox).go();
      await repo.loeschen();
      expect(await db.select(db.familienStati).get(), isEmpty);
      final op = (await db.select(db.outbox).get()).single;
      expect(op.op, 'delete');
      expect(op.baseRev, 3);
    });
  });

  group('Anzeige und Schalter', () {
    Future<(TestUmgebung, ProviderContainer)> aufbau({Map<String, String> meta = const {}, DateTime? jetzt}) async {
      final env = await angemeldeteUmgebung();
      env.speicher = MemoryFeiertageSpeicher(null, meta);
      env.extraOverrides.add(statusJetztProvider.overrideWithValue(() => jetzt ?? DateTime.utc(2026, 10, 27, 14)));
      final c = env.container();
      addTearDown(c.dispose);
      return (env, c);
    }

    Future<void> zeile(AppDatabase db, String user, String text, DateTime? bis) =>
        db.into(db.familienStati).insert(FamilienStatiCompanion.insert(id: statusId(user), userId: user, statusText: text, bis: Value(bis), createdAt: DateTime.utc(2026, 10, 27, 13)));

    test('Standard: Schalter an; Status gelten gegen die Uhr, abgelaufene werden nirgends gezeigt', () async {
      final (env, c) = await aufbau();
      await c.read(authProvider.notifier).start();
      await c.read(statusAnzeigenProvider.notifier).bereit;
      expect(c.read(statusAnzeigenProvider), isTrue);
      await zeile(env.db, fixIdKind, 'Lernen', DateTime.utc(2026, 10, 27, 13)); // schon vorbei
      await zeile(env.db, fixIdAdmin, 'Beim Sport', DateTime.utc(2026, 10, 27, 17));
      c.listen(familienStatusProvider, (_, _) {});
      c.listen(statusZeilenProvider, (_, _) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await c.read(statusZeilenProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect([for (final s in c.read(familienStatusProvider)) s.userId], [fixIdAdmin]);
    });

    test('Schalter aus: keine Stati, auch nicht die eigenen; Wert landet in sync_meta und überlebt einen Neustart', () async {
      final speicher = MemoryFeiertageSpeicher();
      final env = await angemeldeteUmgebung();
      env.speicher = speicher;
      env.extraOverrides.add(statusJetztProvider.overrideWithValue(() => DateTime.utc(2026, 10, 27, 14)));
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      await zeile(env.db, fixIdAdmin, 'Beim Sport', null);
      c.listen(statusZeilenProvider, (_, _) {});
      await c.read(statusZeilenProvider.future);
      await c.read(statusAnzeigenProvider.notifier).setzen(false);
      expect(speicher.werte[kStatusAnzeigenSchluessel], 'nein');
      expect(c.read(familienStatusProvider), isEmpty);
      await c.read(statusAnzeigenProvider.notifier).setzen(true);
      expect(c.read(familienStatusProvider).map((s) => s.text), ['Beim Sport']);
      await c.read(statusAnzeigenProvider.notifier).setzen(false);
      final c2 = env.container();
      addTearDown(c2.dispose);
      await c2.read(statusAnzeigenProvider.notifier).bereit;
      expect(c2.read(statusAnzeigenProvider), isFalse);
      await c2.read(statusAnzeigenProvider.notifier).setzen(true);
      expect(speicher.werte[kStatusAnzeigenSchluessel], 'ja');
    });
  });
}
