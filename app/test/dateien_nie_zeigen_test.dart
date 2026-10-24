// Dateiablage, Oberfläche (Paket D4): Negativtests. Dateien (Namen, Ordner, Fassungen, Übertragungen) erscheinen NIE in Wandtablet, Suche, Widget "Heute", Teilen-Weg, Standort- und Betreiber-Ansicht,
// Push, Erinnerungen und den anderen Bereichen (Müll, Zähler, Medikamente). Die einzigen Stellen, die die Dateiablage kennen, sind der Bereich selbst, die Shell (Menüpunkt, Seitenleiste) und die
// Startseite (Kachel "Zuletzt geteilt", Schnellaktionen). Dateien lösen nie Benachrichtigungen aus (kein Dateiname im Push). Die Ausschlüsse stehen im Code (keine Verbindung der Bereiche);
// hier werden sie festgehalten.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> _dartDateien(String ordner) {
  final dir = Directory(ordner);
  expect(dir.existsSync(), isTrue, reason: ordner);
  return dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
}

void main() {
  final kopplung = RegExp(
    r"import\s+'[^']*(?:/dateien/|/files/)|\bDateiRepository\b|dateiRepositoryProvider|alleDateienProvider|dateienInProvider|ordnerInProvider|alleOrdnerProvider|dateiVersionenProvider|transferDienstProvider|transferListeProvider|\bDateiEintrag\b|dateienVerfuegbarProvider|db\.dateien\b|db\.ordner\b|db\.dateiVersionen|db\.transfers|db\.dateiCache|dateiCacheDienstProvider",
  );

  test('Wandtablet, Suche, Widget "Heute", Teilen, Standort, Betreiber, Push, Erinnerungen, Müll, Zähler und Medikamente kennen die Dateiablage nicht (kein Import, keine Typen)', () {
    final bereiche = [
      'lib/data/wandtablet', 'lib/features/wandtablet', 'lib/data/suche', 'lib/features/suche', 'lib/data/heute_widget', 'lib/data/teilen', 'lib/features/teilen',
      'lib/data/standort', 'lib/features/standort', 'lib/data/betrieb', 'lib/features/betrieb', 'lib/data/push',
      'lib/data/erinnerungen', 'lib/data/muell', 'lib/features/muell', 'lib/data/zaehler', 'lib/features/zaehler', 'lib/data/medikamente', 'lib/features/medikamente',
      'lib/data/chat', 'lib/features/chat', 'lib/data/calendar', 'lib/features/calendar', 'lib/data/tasks', 'lib/features/tasks', 'lib/data/lists', 'lib/features/lists',
    ];
    final treffer = <String>[];
    var dateien = 0;
    for (final b in bereiche) {
      for (final f in _dartDateien(b)) {
        dateien++;
        if (kopplung.hasMatch(f.readAsStringSync())) treffer.add(f.path);
      }
    }
    expect(dateien, greaterThan(100));
    expect(treffer, isEmpty, reason: 'Diese Bereiche dürfen Dateien nie anzeigen oder auslösen');
    // die Erinnerungs-Steuerung im Kalender und die Mehr-Hinweise (Zahlen) kennen sie ebenfalls nicht
    for (final f in ['lib/features/calendar/erinnerung_steuerung.dart', 'lib/data/shell/leiste_logik.dart', 'lib/data/shell/leiste_state.dart']) {
      expect(kopplung.hasMatch(File(f).readAsStringSync()), isFalse, reason: f);
    }
  });

  test('nur Bereich, Shell und Startseite binden die Dateiablage ein (Liste der Dateien außerhalb von features/files und data/dateien)', () {
    final erlaubt = {
      'lib/features/shell/desktop_shell.dart', 'lib/features/shell/home_shell.dart', 'lib/features/shell/mehr_menue.dart',
      'lib/features/home/desktop_home.dart', 'lib/features/home/home_screen.dart', 'lib/features/home/startseite_verfuegbar.dart',
      'lib/features/tresor/tresor_dokumente.dart', 'lib/features/tresor/tresor_eintrag_screen.dart', 'lib/features/tresor/tresor_anhang_screen.dart', 'lib/features/tresor/tresor_screen.dart', // Tresor-Anhänge (Dokumente an Einträgen)
      'lib/app.dart', 'lib/data/api/fampad_api.dart', // die Schnittstelle zum Server (Nutzung und Fähigkeiten), keine Anzeige
    };
    final treffer = <String>[];
    for (final f in _dartDateien('lib')) {
      final p = f.path.replaceAll(r'\', '/');
      if (p.startsWith('lib/features/files/') || p.startsWith('lib/data/dateien/')) continue;
      final inhalt = f.readAsStringSync();
      if (RegExp(r"import\s+'[^']*(?:/dateien/|/files/)").hasMatch(inhalt) || RegExp(r'dateienVerfuegbarProvider|dateiWaehlerProvider|transferSteuerungProvider|DateienScreen|dateienOeffnen').hasMatch(inhalt)) {
        treffer.add(p);
      }
    }
    final unerwartet = treffer.where((p) => !erlaubt.contains(p) && !_istDatenschicht(p)).toList();
    expect(unerwartet, isEmpty, reason: 'unerwartete Stellen binden Dateien ein');
    // die beabsichtigten Stellen sind wirklich verdrahtet
    for (final p in ['lib/features/shell/mehr_menue.dart', 'lib/features/shell/desktop_shell.dart', 'lib/features/home/desktop_home.dart']) {
      expect(treffer, contains(p), reason: p);
    }
  });

  test('Dateien lösen nie Push, Erinnerungen oder lokale Benachrichtigungen aus: die Oberfläche der Dateiablage kennt weder Benachrichtigungs- noch Push-Typen', () {
    final verboten = RegExp(r'push/|erinnerung|EreignisBenachrichtiger|ChatAnzeigePort|flutter_local_notifications|share_plus|open_filex|Share\.|launchUrl');
    final treffer = <String>[];
    for (final f in _dartDateien('lib/features/files')) {
      if (verboten.hasMatch(f.readAsStringSync())) treffer.add(f.path);
    }
    expect(treffer, isEmpty);
  });

  test('es gibt kein Teilen per Link nach außen: keine Link-, Teilen- oder Einladungstexte in der Oberfläche der Dateiablage', () {
    final verboten = RegExp(r'Link teilen|Link kopieren|Freigabelink|öffentlicher Link|Zwischenablage', caseSensitive: false);
    for (final f in _dartDateien('lib/features/files')) {
      final text = f.readAsStringSync();
      // der Hinweistext sagt ausdrücklich "nie per Link nach außen": nur Fügungen, die einen Link anbieten, sind verboten
      expect(verboten.hasMatch(text), isFalse, reason: f.path);
    }
  });
}

bool _istDatenschicht(String p) => p.startsWith('lib/data/dateien/') || p.startsWith('lib/features/files/');
