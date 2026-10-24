// Tresor, Teil 2: Negativtests. Der Tresor (und seine verborgene Konversation `tresor`) erscheint NIE in der Chatliste, in Chat-Benachrichtigungen, im Wandtablet, in der Suche, im Widget
// "Heute", im Teilen-Weg, in der Standort- und der Betreiber-Ansicht, im Push, in Startseiten-Kacheln und in Erinnerungen. Kinder bekommen weder Daten noch Zugang. Die Ausschlüsse stehen
// im Code (Filter nach Art, keine Verbindung der Bereiche, kein Protokoll von Inhalten); hier werden sie festgehalten.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart' show tresorChatId;
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';
import 'package:lx_fampad/data/tresor/tresor_daten.dart';
import 'package:lx_fampad/data/tresor/tresor_modelle.dart';
import 'package:lx_fampad/data/tresor/tresor_sperre.dart';
import 'package:lx_fampad/data/tresor/tresor_state.dart';

import 'support/fake_server.dart';
import 'support/harness.dart' show angemeldeteUmgebung;

const _ich = fixIdAdmin;
const _ben = fixIdKind;
const _tresor = 'tttttttt-0000-4000-8000-000000000001';

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

Future<void> _tresorDaten(AppDatabase db) async {
  await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: _tresor, art: 'tresor', createdAt: DateTime.utc(2026, 10, 24), teilnehmerJson: Value(jsonEncode([_ich])), rev: const Value(1)));
  await db.into(db.tresorEintraege).insert(TresorEintraegeCompanion.insert(id: 't1', konversationId: _tresor, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 24), rev: const Value(1)));
}

List<File> _dartDateien(String ordner) {
  final dir = Directory(ordner);
  expect(dir.existsSync(), isTrue, reason: ordner);
  return dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('Chatliste: die verborgene Tresor-Konversation fehlt, der Familienchat bleibt', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await _tresorDaten(env.db);
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 24), rev: const Value(1)));
    final liste = await c.read(chatRepositoryProvider).uebersicht(_ich).first.timeout(const Duration(seconds: 10));
    expect(liste.map((e) => e.id), ['fam']);
    expect(liste.any((e) => e.art == ChatArt.tresor), isFalse);
  });

  test('Chat-Benachrichtigung: selbst eine (künstliche) Nachricht in der Tresor-Konversation meldet nichts', () async {
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    await db.metaSchreiben('members', jsonEncode([{'id': _ich, 'displayName': 'Anna', 'colorIndex': 0, 'role': 'admin', 'status': 'active'}, {'id': _ben, 'displayName': 'Ben', 'colorIndex': 1, 'role': 'child', 'status': 'active'}]));
    await _tresorDaten(db);
    await db.into(db.konversationen).insert(KonversationenCompanion.insert(id: 'fam', art: 'family', createdAt: DateTime.utc(2026, 10, 24), rev: const Value(1)));
    for (final (id, konv) in [('x1', _tresor), ('x2', 'fam')]) {
      await db.into(db.nachrichten).insert(NachrichtenCompanion.insert(id: id, konversationId: konv, inhalt: 'e1:AAAA', createdAt: DateTime.utc(2026, 10, 24, 9), autorId: const Value(_ben), rev: const Value(5)));
    }
    final a = _Anzeige();
    await ChatBenachrichtiger(db: db, anzeige: a, ich: () async => _ich, sperrbildschirmTitel: () async => false, istVordergrund: () => false).neueEreignisse(5, vorher: 4);
    expect(a.gezeigt.single.text, 'in Familie');
    expect(a.gezeigt.any((x) => '${x.titel}${x.text}'.toLowerCase().contains('tresor')), isFalse);
  });

  test('Wandtablet, Suche, Widget "Heute", Teilen, Standort, Betreiber-Ansicht, Push, Startseite und Erinnerungen sind nicht mit dem Tresor verbunden (kein Import, keine Typen)', () {
    final kopplung = RegExp(
      r"import\s+'[^']*tresor|\bTresorDaten\b|\bTresorInhalt\b|\bTresorAnsicht\b|\bTresorFeld\b|\bTresorRepository\b|tresorDatenProvider|tresorRepositoryProvider|tresorSperreProvider|tresorDarfProvider|db\.tresorEintraege|tresor_eintrag|tresorAnhang|TresorAnhang|AnhangAnsicht|tresorDokumenteAktiv|db\.tresorAnhaenge",
    );
    final bereiche = [
      'lib/data/wandtablet', 'lib/features/wandtablet', 'lib/data/suche', 'lib/features/suche', 'lib/data/heute_widget', 'lib/data/teilen', 'lib/features/teilen',
      'lib/data/standort', 'lib/features/standort', 'lib/data/betrieb', 'lib/features/betrieb', 'lib/data/push',
      'lib/data/startseite', 'lib/features/home', 'lib/data/erinnerungen', 'lib/data/muell', 'lib/data/zaehler', 'lib/data/medikamente',
    ];
    final treffer = <String>[];
    var dateien = 0;
    for (final b in bereiche) {
      for (final f in _dartDateien(b)) {
        dateien++;
        if (kopplung.hasMatch(f.readAsStringSync())) treffer.add(f.path);
      }
    }
    expect(dateien, greaterThan(40));
    expect(treffer, isEmpty, reason: 'Diese Bereiche dürfen den Tresor nie anzeigen');
    // die Erinnerungs-Steuerung im Kalender und die Mehr-Hinweise (Zahlen) kennen den Tresor ebenfalls nicht
    for (final f in ['lib/features/calendar/erinnerung_steuerung.dart', 'lib/data/shell/leiste_logik.dart', 'lib/data/shell/leiste_state.dart']) {
      expect(kopplung.hasMatch(File(f).readAsStringSync()), isFalse, reason: f);
    }
    // keine Startseiten-Kachel: die Kennungen kennen keinen Tresor
    expect(RegExp("'tresor'", caseSensitive: false).hasMatch(File('lib/data/startseite/startseite_logik.dart').readAsStringSync()), isFalse);
  });

  test('Der Tresor kennt keinen Push-Wecker, kein Netz und kein Protokoll (nie Inhalte in Log oder Ausgabe)', () {
    final dateien = [
      for (final o in ['lib/data/tresor', 'lib/features/tresor']) for (final f in _dartDateien(o)) f.readAsStringSync(),
    ].join('\n');
    expect(RegExp(r'PushService|EreignisBenachrichtiger|ChatBenachrichtiger|http\.(get|post|put)|HttpClient\b|apiClientProvider|fampadApiProvider').hasMatch(dateien), isFalse);
    expect(RegExp(r'\bprint\(|debugPrint\(|\blog\(|developer\.log|Logger\b').hasMatch(dateien), isFalse);
    // der Oberflächen-Teil nutzt weder Teilen noch Dateiausgabe
    final ui = [for (final f in _dartDateien('lib/features/tresor')) f.readAsStringSync()].join('\n');
    expect(RegExp(r'dart:io|file_picker|printing|ics_export|Share\.').hasMatch(ui), isFalse);
  });

  test('Anhänge im Tresor: nur der Tresor und die Datenschicht kennen sie (nie Dateien-Bereich, Suche, Wandtablet, Widget, Teilen, Push), nie eine Verbindung zum Vorschau-Zwischenspeicher', () {
    final anhang = RegExp(r'tresor_anhang|tresorAnhang|TresorAnhang|AnhangAnsicht|tresorDokumenteAktiv|db\.tresorAnhaenge|tresorAnhaenge');
    // erlaubt: die Datenschicht der Anhänge, die Sync-Anbindung, die Tresor-Oberfläche (und die Datenbank selbst)
    final erlaubt = RegExp(
      r'lib[/\\](data[/\\](app_database(\.g)?\.dart|chat[/\\]chat_krypto_state\.dart|dateien[/\\]tresor_anhang_[a-z]+\.dart|sync[/\\](sync_dateien|sync_entities|sync_store)\.dart)|features[/\\]tresor[/\\][a-z_]+\.dart)$',
    );
    final fremd = <String>[];
    var geprueft = 0;
    for (final f in _dartDateien('lib')) {
      geprueft++;
      if (anhang.hasMatch(f.readAsStringSync()) && !erlaubt.hasMatch(f.path)) fremd.add(f.path);
    }
    expect(geprueft, greaterThan(300));
    expect(fremd, isEmpty, reason: 'Anhänge des Tresors dürfen nur dort vorkommen, wo sie hingehören');
    // der Dateien-Bereich (Oberfläche und Datenschicht ohne die Tresor-Teile) kennt sie nicht
    final dateienBereich = [
      for (final o in ['lib/features/files', 'lib/data/dateien']) for (final f in _dartDateien(o)) if (!f.path.contains('tresor_anhang')) f,
    ];
    expect(dateienBereich, isNotEmpty);
    for (final f in dateienBereich) {
      expect(anhang.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    // der Tresor-Anhang-Code nutzt weder Vorschau-Zwischenspeicher, Offline-Cache noch den Download in den Cache der Dateien-Ablage (Klartext nur im Arbeitsspeicher)
    final cacheWeg = RegExp(r'datei_vorschau|VorschauCache|vorschauCacheProvider|vorschauBildProvider|datei_cache_dienst|DateiCacheDienst|dateiCacheDienstProvider|datei_ort|DateiOrt\b|dateiOrtProvider|\.herunterladen\(\s*blobId');
    final tresorAnhangCode = [
      for (final f in [..._dartDateien('lib/features/tresor'), ..._dartDateien('lib/data/dateien').where((f) => f.path.contains('tresor_anhang'))]) f,
    ];
    expect(tresorAnhangCode.length, greaterThanOrEqualTo(8));
    for (final f in tresorAnhangCode) {
      expect(cacheWeg.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
    // keine temporären Dateien, kein Teilen, kein Push, kein Log im Anhang-Code
    final dateiAusgabe = RegExp(r'dart:io|getTemporaryDirectory|Share\.|PushService|\bprint\(|debugPrint\(|developer\.log');
    for (final f in tresorAnhangCode) {
      expect(dateiAusgabe.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
    }
  });

  test('Backup- und Betreiber-Weg lesen keine Inhalte: in der App kein Zugriff auf die Tabelle tresor_eintraege', () {
    final betrieb = _dartDateien('lib/data/betrieb').map((f) => f.readAsStringSync()).join('\n');
    expect(RegExp(r'db\.tresorEintraege\b').hasMatch(betrieb), isFalse);
  });

  test('Kind: der Datenanbieter ist leer und liest die Tabelle nicht, entsperren geht nie (Rolle entscheidet)', () async {
    final env = await angemeldeteUmgebung(role: 'child');
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    await _tresorDaten(env.db); // selbst wenn Daten da wären
    expect(c.read(tresorDarfProvider), isFalse);
    c.read(tresorSperreProvider.notifier).entsperren();
    expect(c.read(tresorSperreProvider).entsperrt, isFalse);
    final halte = c.listen(tresorDatenProvider, (_, _) {}); // autoDispose: für die Dauer des Tests halten
    addTearDown(halte.close);
    final d = c.read(tresorDatenProvider);
    expect(d.offen, isFalse);
    expect(d.eintraege, isEmpty);
    final halte2 = c.listen(tresorEintraegeStromProvider, (_, _) {});
    addTearDown(halte2.close);
    expect(await c.read(tresorEintraegeStromProvider.future), isEmpty);
  });

  test('Echter Datenweg: gesperrt liefert der Anbieter nichts und liest nichts; entsperrt kommen die Einträge, mit der Sperre sind sie wieder weg', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    final konv = tresorChatId(c.read(authProvider).me!.familyId);
    await env.db.into(env.db.konversationen).insert(KonversationenCompanion.insert(id: konv, art: 'tresor', createdAt: DateTime.utc(2026, 10, 24), teilnehmerJson: Value(jsonEncode([_ich])), rev: const Value(1)));
    final klar = tresorKodieren(const TresorInhalt(kategorie: TresorKategorie.zugang, titel: 'Alarmanlage', felder: [TresorFeld(bezeichnung: 'Code', wert: '9911', geheim: true)]));
    await env.db.into(env.db.tresorEintraege).insert(
      TresorEintraegeCompanion.insert(id: 't1', konversationId: konv, inhalt: 'l1:$klar', createdAt: DateTime.utc(2026, 10, 24), bearbeiterId: const Value(_ich), rev: const Value(0)),
    );
    final halte = c.listen(tresorDatenProvider, (_, _) {});
    addTearDown(halte.close);
    expect(c.read(tresorDatenProvider).eintraege, isEmpty);
    expect(c.read(tresorDatenProvider).offen, isFalse);
    c.read(tresorSperreProvider.notifier).entsperren();
    for (var i = 0; i < 20 && c.read(tresorDatenProvider).eintraege.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final d = c.read(tresorDatenProvider);
    expect(d.offen, isTrue);
    expect(d.lesbare.single.inhalt!.titel, 'Alarmanlage');
    c.read(tresorSperreProvider.notifier).sperren();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(tresorDatenProvider).eintraege, isEmpty);
    expect(c.read(tresorDatenProvider).offen, isFalse);
  });

  test('Eltern: beim Start gesperrt, entsperren setzt "bis"; der Abmelde-Weg (Wiper) wirft den Zustand weg', () async {
    final env = await angemeldeteUmgebung();
    final c = env.container();
    addTearDown(c.dispose);
    await c.read(authProvider.notifier).start();
    expect(c.read(tresorDarfProvider), isTrue);
    expect(c.read(tresorSperreProvider).entsperrt, isFalse, reason: 'beim Start gesperrt');
    c.read(tresorSperreProvider.notifier).entsperren();
    expect(c.read(tresorSperreProvider).entsperrt, isTrue);
    expect(c.read(tresorSperreProvider).bis, isNotNull);
    c.invalidate(tresorSperreProvider);
    expect(c.read(tresorSperreProvider).entsperrt, isFalse);
  });
}
