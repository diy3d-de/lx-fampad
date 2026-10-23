// Medikamenten-Plan, Teil 2: Negativtests. Medikamente (und ihre verborgene Konversation `meds`) erscheinen NIE in der Chatliste, in Chat-Benachrichtigungen, im Wandtablet, in der Suche,
// im Widget "Heute", im Teilen-Weg, in der Standort- und der Betreiber-Ansicht. Die Ausschlüsse stehen im Code (Filter nach Art, keine Verbindung der Bereiche); hier werden sie festgehalten.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';

import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;

const _ich = fixIdAdmin;
const _ben = fixIdKind;
const _meds = 'mmmmmmmm-0000-4000-8000-000000000001';

class _Anzeige implements ChatAnzeigePort {
  final gezeigt = <({String titel, String text})>[];

  @override
  Future<bool> initialisieren() async => true;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async {
    gezeigt.add((titel: titel, text: text));
    return true;
  }

  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async => false;
  @override
  Future<void> entfernen(int id) async {}
}

Future<void> _medsDaten(AppDatabase db) async {
  await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: _meds, art: 'meds', createdAt: DateTime.utc(2026, 10, 19), teilnehmerJson: Value(jsonEncode([_ich, _ben])), subjektId: const Value(_ben), rev: const Value(1)));
  await db.into(db.medikamente).insert(MedikamenteCompanion.insert(id: 'm1', konversationId: _meds, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
  await db.into(db.einnahmen).insert(EinnahmenCompanion.insert(id: 'n1', konversationId: _meds, medikamentId: 'm1', inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('Chatliste: die verborgene Konversation fehlt, der Familienchat bleibt', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await _medsDaten(env.db);
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    final liste = await c.read(chatRepositoryProvider).uebersicht(_ich).first.timeout(const Duration(seconds: 10));
    expect(liste.map((e) => e.id), ['fam']);
    expect(liste.any((e) => e.art == ChatArt.meds), isFalse);
  });

  test('Chat-Benachrichtigung: selbst eine (künstliche) Nachricht in der Medikamenten-Konversation meldet nichts; die gewöhnlichen Chats melden ohne das Wort Medikament', () async {
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    await db.metaSchreiben('members', jsonEncode([{'id': _ich, 'displayName': 'Anna', 'colorIndex': 0, 'role': 'admin', 'status': 'active'}, {'id': _ben, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'}]));
    await _medsDaten(db);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    for (final (id, konv) in [('x1', _meds), ('x2', 'fam')]) {
      await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: id, konversationId: konv, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19, 9), autorId: const Value(_ben), rev: const Value(5)));
    }
    final a = _Anzeige();
    await ChatBenachrichtiger(db: db, anzeige: a, ich: () async => _ich, sperrbildschirmTitel: () async => false, istVordergrund: () => false).neueEreignisse(5, vorher: 4);
    expect(a.gezeigt.single.text, 'in Familie');
    expect(a.gezeigt.any((x) => '${x.titel}${x.text}'.toLowerCase().contains('medikament')), isFalse);
  });

  test('Wandtablet, Suche, Widget "Heute", Teilen, Standort und Betreiber-Ansicht sind nicht mit dem Medikamenten-Plan verbunden (kein Import, keine Typen)', () {
    final kopplung = RegExp(r"import\s+'[^']*medikament|\bMedDaten\b|\bMedEintrag\b|medDatenProvider|medAnsichtProvider|MedikamentRepository|medikamentRepositoryProvider|\bEinnahmeAnsicht\b");
    final bereiche = ['lib/data/wandtablet', 'lib/features/wandtablet', 'lib/data/suche', 'lib/features/suche', 'lib/data/heute_widget', 'lib/data/teilen', 'lib/features/teilen', 'lib/data/standort', 'lib/features/standort', 'lib/data/betrieb', 'lib/features/betrieb', 'lib/data/push'];
    final treffer = <String>[];
    var dateien = 0;
    for (final b in bereiche) {
      final dir = Directory(b);
      expect(dir.existsSync(), isTrue, reason: b);
      for (final f in dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        dateien++;
        if (kopplung.hasMatch(f.readAsStringSync())) treffer.add(f.path);
      }
    }
    expect(dateien, greaterThan(20));
    expect(treffer, isEmpty, reason: 'Diese Bereiche dürfen Medikamente nie anzeigen');
  });

  test('der Backup- und Betreiber-Weg liest keine Inhalte: auf dem Server nur e1-Hüllen (Serverseite, Abschnitt 6k) und in der App keine Verbindung (siehe oben)', () {
    // Die Sicht der Betreiber-Ansicht kennt nur Zähler; die App-Seite hat keinen Zugriff auf die Tabellen medikamente/einnahmen.
    final betrieb = Directory('lib/data/betrieb').listSync(recursive: true).whereType<File>().map((f) => f.readAsStringSync()).join('\n');
    expect(RegExp(r'db\.(medikamente|einnahmen)\b').hasMatch(betrieb), isFalse);
  });
}
