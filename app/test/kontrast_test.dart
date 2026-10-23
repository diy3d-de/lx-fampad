// Kontrast der Design-Token (WCAG 2.x): Texte auf Hintergrund und Karte mindestens 4,5:1 (normaler Text), große Schrift und Bedienelemente 3:1. Die Werte sind gemessen und
// hier festgehalten; ein Token, das die Schwelle verfehlt, steht ausdrücklich in [bekannteSchwaechen] (dokumentiert, nicht geändert: neue Farben gehören in constants.dart und die
// Projektbeschreibung). Wer ein Token ändert, ändert die Tabelle mit.
import 'dart:math' show pow;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';

double _kanal(double v) => v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();

double leuchtdichte(Color c) => 0.2126 * _kanal(c.r) + 0.7152 * _kanal(c.g) + 0.0722 * _kanal(c.b);

double kontrast(Color a, Color b) {
  final la = leuchtdichte(a);
  final lb = leuchtdichte(b);
  final hell = la > lb ? la : lb;
  final dunkel = la > lb ? lb : la;
  return (hell + 0.05) / (dunkel + 0.05);
}

void main() {
  const gruende = {'kBg': kBg, 'kSurface': kSurface, 'kSurface2': kSurface2};
  const text = <String, Color>{
    'kTextStrong': kTextStrong,
    'kText': kText,
    'kTextMuted': kTextMuted,
    'kAccent': kAccent,
    'kAccentStrong': kAccentStrong,
    'kTerminal': kTerminal,
    'kWarn': kWarn,
    'kDanger': kDanger,
    'kFeiertag': kFeiertag,
    'kFerien': kFerien,
    'kMuellRest': kMuellRest,
    'kMuellBio': kMuellBio,
    'kMuellGelb': kMuellGelb,
    'kMuellPapier': kMuellPapier,
    'kMuellGruen': kMuellGruen,
    'kMuellSonder': kMuellSonder,
    'kMuellSperr': kMuellSperr,
    'kMuellBaum': kMuellBaum,
  };

  test('Messhilfe: Schwarz auf Weiß ist 21:1, gleiche Farbe 1:1', () {
    expect(kontrast(const Color(0xFF000000), const Color(0xFFFFFFFF)), closeTo(21, 0.01));
    expect(kontrast(kText, kText), closeTo(1, 0.0001));
  });

  test('Haupttexte erreichen auf Hintergrund, Karte und Fläche mindestens 4,5:1', () {
    for (final g in gruende.entries) {
      for (final t in ['kTextStrong', 'kText', 'kTextMuted', 'kAccent', 'kAccentStrong']) {
        expect(kontrast(text[t]!, g.value), greaterThanOrEqualTo(4.5), reason: '$t auf ${g.key}');
      }
    }
  });

  test('Status- und Kategoriefarben als Text erreichen mindestens 4,5:1 auf Hintergrund und Karte', () {
    for (final g in ['kBg', 'kSurface']) {
      for (final t in text.keys) {
        expect(kontrast(text[t]!, gruende[g]!), greaterThanOrEqualTo(4.5), reason: '$t auf $g');
      }
    }
  });

  test('Text auf Akzentfläche (Knöpfe): kOnAccent auf kAccent mindestens 4,5:1', () {
    expect(kontrast(kOnAccent, kAccent), greaterThanOrEqualTo(4.5));
  });

  /// Bekannte Schwäche (nur dokumentiert, nicht geändert): kTextFaint ist die Farbe der leisesten Metadaten (Zeitangaben in Chat-Blasen, "bearbeitet").
  /// Gemessen: siehe Test; unter 4,5:1, aber über 3:1 auf Hintergrund und Karte. Sie trägt nur Zusatzangaben, die auch im Semantics-Text der Zeile stehen.
  test('kTextFaint (dokumentiert): unter 4,5:1, aber mindestens 3:1', () {
    for (final g in ['kBg', 'kSurface']) {
      final k = kontrast(kTextFaint, gruende[g]!);
      expect(k, lessThan(4.5), reason: 'falls dieser Test bricht, ist die Schwäche behoben: Tabelle und CLAUDE.md anpassen ($g: $k)');
      expect(k, greaterThanOrEqualTo(3.0), reason: g);
    }
  });
}
