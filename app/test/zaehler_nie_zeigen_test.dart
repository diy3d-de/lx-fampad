// Zähler, Teil 2: Negativtests. Zähler (und ihre verborgene Konversation `zaehler`) erscheinen NIE in der Chatliste, in Chat-Benachrichtigungen, im Wandtablet, in der Suche, im Widget "Heute",
// im Teilen-Weg, in der Standort- und der Betreiber-Ansicht und im Push. Kinder bekommen weder Daten noch Erinnerungen. Die Ausschlüsse stehen im Code (Filter nach Art, keine Verbindung der
// Bereiche); hier werden sie festgehalten.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart' show Role;
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart';

import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;

const _ich = fixIdAdmin;
const _ben = fixIdKind;
const _zaehler = 'zzzzzzzz-0000-4000-8000-000000000001';

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

Future<void> _zaehlerDaten(AppDatabase db) async {
  await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: _zaehler, art: 'zaehler', createdAt: DateTime.utc(2026, 10, 19), teilnehmerJson: Value(jsonEncode([_ich])), rev: const Value(1)));
  await db.into(db.zaehler).insert(ZaehlerCompanion.insert(id: 'z1', konversationId: _zaehler, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
  await db.into(db.zaehlerstaende).insert(ZaehlerstaendeCompanion.insert(id: 's1', konversationId: _zaehler, zaehlerId: 'z1', inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('Chatliste: die verborgene Zähler-Konversation fehlt, der Familienchat bleibt', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await _zaehlerDaten(env.db);
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    final liste = await c.read(chatRepositoryProvider).uebersicht(_ich).first.timeout(const Duration(seconds: 10));
    expect(liste.map((e) => e.id), ['fam']);
    expect(liste.any((e) => e.art == ChatArt.zaehler), isFalse);
  });

  test('Chat-Benachrichtigung: selbst eine (künstliche) Nachricht in der Zähler-Konversation meldet nichts', () async {
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    await db.metaSchreiben('members', jsonEncode([{'id': _ich, 'displayName': 'Anna', 'colorIndex': 0, 'role': 'admin', 'status': 'active'}, {'id': _ben, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'}]));
    await _zaehlerDaten(db);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 19), rev: const Value(1)));
    for (final (id, konv) in [('x1', _zaehler), ('x2', 'fam')]) {
      await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: id, konversationId: konv, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 19, 9), autorId: const Value(_ben), rev: const Value(5)));
    }
    final a = _Anzeige();
    await ChatBenachrichtiger(db: db, anzeige: a, ich: () async => _ich, sperrbildschirmTitel: () async => false, istVordergrund: () => false).neueEreignisse(5, vorher: 4);
    expect(a.gezeigt.single.text, 'in Familie');
    expect(a.gezeigt.any((x) => '${x.titel}${x.text}'.toLowerCase().contains('zähler')), isFalse);
  });

  test('Wandtablet, Suche, Widget "Heute", Teilen, Standort, Betreiber-Ansicht und Push sind nicht mit den Zählern verbunden (kein Import, keine Typen)', () {
    final kopplung = RegExp(
      r"import\s+'[^']*(zaehler|ingest)|\bIngestZustand\b|\bIngestNotifier\b|\bIngestDienst\b|ingestProvider|\bPostfachSchluessel\b|\bZaehlerDaten\b|\bZaehlerEintrag\b|\bZaehlerReihe\b|\bZaehlerKachel\b|zaehlerDatenProvider|zaehlerRepositoryProvider|\bZaehlerRepository\b|\bStandAnsicht\b|zaehlerFaelligProvider|zaehlerKachelProvider|db\.(zaehler|zaehlerstaende)\b",
    );
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
    expect(treffer, isEmpty, reason: 'Diese Bereiche dürfen Zähler nie anzeigen');
  });

  test('Home Assistant (Werte abholen): kein Push, kein Hintergrund-Isolate, keine Verbindung zu Chat, Wandtablet, Suche, Teilen, Standort und Betreiber-Ansicht, nichts wird protokolliert', () {
    final dateien = [for (final f in Directory('lib/data/ingest').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) f.readAsStringSync()].join('\n');
    expect(dateien.length, greaterThan(1000));
    // keine Wecker, kein Hintergrund (Isolate, Plugin, Push-Hintergrund), keine Benachrichtigung
    expect(RegExp(r'PushService|EreignisBenachrichtiger|ChatBenachrichtiger|ChatAnzeigePort|push_hintergrund|workmanager|Isolate\.|compute\(|unifiedpush|flutter_local_notifications').hasMatch(dateien), isFalse);
    // keine Verbindung zu den übrigen Bereichen
    expect(RegExp(r"import\s+'[^']*(chat/|wandtablet|suche|teilen|standort|betrieb|heute_widget)").hasMatch(dateien), isFalse);
    // Werte, Kanäle und Päckchen werden nie protokolliert
    expect(RegExp(r'\bprint\(|debugPrint\(|\blog\(|developer\.log').hasMatch(dateien), isFalse);
    // die Oberfläche der Anbindung zeigt nichts auf der Startseite und sendet nichts per Push
    final ui = [for (final n in ['ha_verbindung_screen', 'ha_koppeln_screen', 'ha_pruefen_screen', 'ha_zuordnen_screen', 'ha_weitergabe_screens']) File('lib/features/zaehler/$n.dart').readAsStringSync()].join('\n');
    expect(RegExp(r'PushService|EreignisBenachrichtiger|ChatAnzeigePort|home_screen|print\(|debugPrint\(').hasMatch(ui), isFalse);
  });

  test('Die Schreibwege der Zähler kennen keinen Push-Wecker (kein Wecker, keine Benachrichtigung vom Server) und senden nichts an Dritte', () {
    final dateien = [for (final f in Directory('lib/data/zaehler').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) f.readAsStringSync()].join('\n');
    expect(RegExp(r'PushService|EreignisBenachrichtiger|ChatBenachrichtiger|http\.(get|post|put)|HttpClient\b|apiClientProvider|fampadApiProvider').hasMatch(dateien), isFalse);
    // der Bericht entsteht nur lokal: kein Netz in der PDF-Erzeugung
    final pdf = File('lib/data/zaehler/zaehler_pdf.dart').readAsStringSync() + File('lib/data/zaehler/zaehler_bericht.dart').readAsStringSync();
    expect(RegExp(r'package:http|dart:io|dart:html|print\(|debugPrint\(|log\(').hasMatch(pdf), isFalse);
  });

  test('Backup- und Betreiber-Weg lesen keine Inhalte: in der App kein Zugriff auf die Tabellen zaehler und zaehlerstaende (siehe oben)', () {
    final betrieb = Directory('lib/data/betrieb').listSync(recursive: true).whereType<File>().map((f) => f.readAsStringSync()).join('\n');
    expect(RegExp(r'db\.(zaehler|zaehlerstaende)\b').hasMatch(betrieb), isFalse);
  });

  test('Kind: der Datenanbieter ist leer und liest die Tabellen nicht (Rolle entscheidet)', () async {
    final env = await angemeldeteUmgebung(role: 'child');
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await _zaehlerDaten(env.db); // selbst wenn Daten da wären
    expect(c.read(zaehlerDarfProvider), isFalse);
    final d = c.read(zaehlerDatenProvider);
    expect(d.darf, isFalse);
    expect(d.eintraege, isEmpty);
    expect(d.reihen, isEmpty);
    expect(d.kacheln, isEmpty);
  });

  test('Elternteil und Admin dürfen, Kind und ohne Anmeldung niemand (nur die Rolle zählt)', () {
    expect(darfRolleZaehler(Role.admin), isTrue);
    expect(darfRolleZaehler(Role.parent), isTrue);
    expect(darfRolleZaehler(Role.child), isFalse);
    expect(darfRolleZaehler(null), isFalse);
  });
}
