// Vorsorge und Impfungen (Abschnitt 6p), Negativtests. Gesundheitsdaten erscheinen NIE in der Chatliste, in Chat-Benachrichtigungen, im Wandtablet, in der Suche, im Widget "Heute", im Teilen-Weg,
// in der Standort-, der Betreiber- und der Tagesbriefing-Ansicht und in keinem Push. Die Ausschlüsse stehen im Code (Filter nach Art, keine Verbindung der Bereiche); hier werden sie festgehalten.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/erinnerungen/web_erinnerung_logik.dart' show webNeutralerText;
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

Future<void> _daten(AppDatabase db) async {
  await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: _meds, art: 'meds', createdAt: DateTime.utc(2026, 10, 19), teilnehmerJson: Value(jsonEncode([_ich, _ben])), subjektId: const Value(_ben), rev: const Value(1)));
  await db.into(db.vorsorgeProfile).insert(VorsorgeProfileCompanion.insert(id: 'p1', konversationId: _meds, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
  await db.into(db.vorsorgeEintraege).insert(VorsorgeEintraegeCompanion.insert(id: 'v1', konversationId: _meds, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('Chatliste: die verborgene Konversation mit den Vorsorge-Daten fehlt, der Familienchat bleibt', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await _daten(env.db);
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    final liste = await c.read(chatRepositoryProvider).uebersicht(_ich).first.timeout(const Duration(seconds: 10));
    expect(liste.map((e) => e.id), ['fam']);
  });

  test('Chat-Benachrichtigung: die Konversation meldet nichts; gewöhnliche Chats melden ohne die Wörter Vorsorge oder Impfung', () async {
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    await db.metaSchreiben('members', jsonEncode([{'id': _ich, 'displayName': 'Anna', 'colorIndex': 0, 'role': 'admin', 'status': 'active'}, {'id': _ben, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'}]));
    await _daten(db);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    for (final (id, konv) in [('x1', _meds), ('x2', 'fam')]) {
      await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: id, konversationId: konv, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19, 9), autorId: const Value(_ben), rev: const Value(5)));
    }
    final a = _Anzeige();
    await ChatBenachrichtiger(db: db, anzeige: a, ich: () async => _ich, sperrbildschirmTitel: () async => false, istVordergrund: () => false).neueEreignisse(5, vorher: 4);
    expect(a.gezeigt.single.text, 'in Familie');
    final alles = a.gezeigt.map((x) => '${x.titel}${x.text}'.toLowerCase()).join();
    expect(alles.contains('vorsorge') || alles.contains('impf'), isFalse);
  });

  test('Wandtablet, Suche, Widget "Heute", Teilen, Standort, Betreiber-Ansicht, Push und Tagesbriefing sind nicht mit Vorsorge verbunden (kein Import, keine Typen)', () {
    final kopplung = RegExp(r"import\s+'[^']*vorsorge|\bVorsorgeDaten\b|\bVorsorgeAnsicht\b|vorsorgeDatenProvider|vorsorgeAnsichtProvider|VorsorgeRepository|vorsorgeRepositoryProvider|\bVorsorgeProfilAnsicht\b|vorsorgeFaelligkeit|kVorsorgeVorlagen");
    final bereiche = [
      'lib/data/wandtablet',
      'lib/features/wandtablet',
      'lib/data/suche',
      'lib/features/suche',
      'lib/data/heute_widget',
      'lib/data/teilen',
      'lib/features/teilen',
      'lib/data/standort',
      'lib/features/standort',
      'lib/data/betrieb',
      'lib/features/betrieb',
      'lib/data/push',
      'lib/data/tagesbriefing',
      'lib/features/tagesbriefing',
    ];
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
    expect(treffer, isEmpty, reason: 'Diese Bereiche dürfen Vorsorge-Daten nie anzeigen');
  });

  test('Web-Erinnerungs-Port: kennt nur die Nutzlast, nie Daten oder Repository; der Text ist neutral', () {
    final kopplung = RegExp(r'VorsorgeDaten|VorsorgeAnsicht|vorsorgeDatenProvider|VorsorgeRepository|vorsorgeRepositoryProvider|vorsorge_state|vorsorge_repository|vorsorge_modelle|vorsorge_vorlagen');
    var n = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.replaceAll('\\', '/').contains('/web_erinnerung'))) {
      n++;
      expect(kopplung.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    expect(n, greaterThan(2));
    expect(webNeutralerText('vorsorge'), 'Erinnerung: Etwas steht an');
    expect(webNeutralerText('vorsorge'), isNot(contains('Vorsorge')));
  });

  test('der Betreiber-Weg liest keine Inhalte (die Tabellen sind ihm unbekannt), und kein Server-Weg kennt Vorsorge-Inhalte', () {
    final betrieb = Directory('lib/data/betrieb').listSync(recursive: true).whereType<File>().map((f) => f.readAsStringSync()).join('\n');
    expect(RegExp(r'db\.(vorsorgeProfile|vorsorgeEintraege)\b').hasMatch(betrieb), isFalse);
    // die Erinnerung nennt nie etwas anderes als die neutralen Texte
    final erinnerung = File('lib/data/vorsorge/vorsorge_erinnerung.dart').readAsStringSync();
    expect(erinnerung, contains("kVorsorgeTitel = 'Eine Vorsorge ist fällig'"));
    expect(erinnerung, isNot(contains('displayName')));
    expect(erinnerung, isNot(contains('.name')));
  });
}
