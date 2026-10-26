// Tagesbriefing: Negativtests. Das Briefing (Kachel und Benachrichtigung) nutzt nur Termine, Aufgaben und Fristen, Abfuhrtermine und das Wetter. Es ist mit Chat, Standort, Schlüsseln,
// Zählern, Tresor, Medikamenten und Dateien nicht verbunden (kein Import, keine Provider) und zeigt davon nie etwas, auch wenn solche Daten in der Datenbank liegen.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/features/tagesbriefing/briefing_karte.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;

const _ich = fixIdAdmin;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  test('kein Import und kein Provider von Chat, Standort, Schlüsseln, Zählern, Tresor, Medikamenten, Dateien, Push, Betrieb', () {
    final kopplung = RegExp(
      r"import\s+'[^']*(chat|standort|crypto|e2ee|schluessel|zaehler|tresor|medikament|dateien|files|ingest|push|betrieb|suche|teilen|wandtablet|heute_widget)[^']*'"
      r'|\bMedDaten\b|\bMedEintrag\b|medDatenProvider|zaehlerDatenProvider|ZaehlerDaten|tresorDatenProvider|chatRepositoryProvider|ChatRepository|standortProvider|E2eeController|dateienVerfuegbarProvider',
    );
    final treffer = <String>[];
    var dateien = 0;
    for (final b in ['lib/data/tagesbriefing', 'lib/features/tagesbriefing']) {
      final dir = Directory(b);
      expect(dir.existsSync(), isTrue, reason: b);
      for (final f in dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        dateien++;
        // nur Code prüfen, nicht die Kopfkommentare, die die Ausschlüsse beschreiben
        final code = f.readAsLinesSync().where((z) => !z.trimLeft().startsWith('//')).join('\n');
        if (kopplung.hasMatch(code)) treffer.add(f.path);
      }
    }
    expect(dateien, greaterThanOrEqualTo(5));
    expect(treffer, isEmpty, reason: 'Das Briefing darf diese Bereiche nie anzeigen');
  });

  test('Chat-Nachrichten, Zähler und Medikamente in der Datenbank ergeben kein Briefing', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    final heute = DateTime.now().toUtc();
    for (final (id, art) in [('k-fam', 'family'), ('k-zaehler', 'zaehler'), ('k-meds', 'meds'), ('k-tresor', 'tresor')]) {
      await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: id, art: art, createdAt: heute, teilnehmerJson: Value(jsonEncode([_ich])), rev: const Value(1)));
    }
    await env.db.into(env.db.zaehler).insert(ZaehlerCompanion.insert(id: 'z1', konversationId: 'k-zaehler', inhalt: 'e1:AAAA', createdAt: heute, rev: const Value(1)));
    final b = c.read(tagesbriefingProvider);
    expect(b.zeilen, isEmpty);
    expect(b.hatInhalt, isFalse);
    expect(b.neutralerText, isNull);
  });
}
