// Termin-Farben: reine Logik (Index -> Name/Farbe, Rückfall auf die Person, Filter, Zählung, Speicherform) und die Konstanten.
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/calendar/termin_farben.dart';

void main() {
  test('elf Farben mit festen Namen in fester Reihenfolge; die ersten zehn sind die Personenfarben, die elfte ist Rufdienst', () {
    expect([for (final f in kTerminFarben) f.name], ['Familie', 'Schule', 'Arbeit', 'Arzt', 'Sport', 'Freizeit', 'Haushalt', 'Urlaub', 'Besuch', 'Sonstiges', 'Rufdienst']);
    for (var i = 0; i < 10; i++) {
      expect(kTerminFarben[i].farbe, personPalette[i], reason: kTerminFarben[i].name);
    }
    expect(kTerminFarben[10].farbe, const Color(0xFFE5322D));
    expect(kTerminFarbeRufdienst, const Color(0xFFE5322D));
    expect(kTerminFarbenAnzahl, 11);
  });

  test('Rufdienst ist deutlich anders als die rosé Personenfarbe, kDanger und die übrigen Farben', () {
    for (final f in [...personPalette, kDanger, kGeburtstag, kMuellSonder]) {
      expect(f == kTerminFarbeRufdienst, isFalse);
    }
    double abstand(Color a, Color b) => (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
    expect(abstand(kTerminFarbeRufdienst, personPalette[3]), greaterThan(0.5));
    expect(abstand(kTerminFarbeRufdienst, kDanger), greaterThan(0.25));
  });

  test('Gültigkeit, Name und Wert', () {
    expect(terminFarbeGueltig(null), isFalse);
    expect(terminFarbeGueltig(-1), isFalse);
    expect(terminFarbeGueltig(0), isTrue);
    expect(terminFarbeGueltig(10), isTrue);
    expect(terminFarbeGueltig(11), isFalse);
    expect(terminFarbeName(3), 'Arzt');
    expect(terminFarbeName(10), 'Rufdienst');
    expect(terminFarbeName(11), isNull);
    expect(terminFarbeName(null), isNull);
    expect(terminFarbeWert(0), personPalette[0]);
    expect(terminFarbeWert(99), isNull);
    expect(terminFarbeNummer(5), 5);
    expect(terminFarbeNummer(12), isNull);
  });

  test('Rückfall auf die Personenfarbe ohne (gültige) Farbe', () {
    const person = Color(0xFF123456);
    expect(terminFarbeOderRueckfall(null, person), person);
    expect(terminFarbeOderRueckfall(42, person), person);
    expect(terminFarbeOderRueckfall(2, person), personPalette[2]);
  });

  test('Filter: ausgeblendete Farben verschwinden, Termine ohne Farbe nie', () {
    expect(passtZumFarbFilter(null, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}), isTrue);
    expect(passtZumFarbFilter(7, {}), isTrue);
    expect(passtZumFarbFilter(7, {7}), isFalse);
    expect(passtZumFarbFilter(7, {1, 2}), isTrue);
    expect(passtZumFarbFilter(99, {99}), isTrue, reason: 'unbekannte Nummer gilt als keine Farbe');
  });

  test('Zählung je Farbe', () {
    expect(zaehleFarben([0, 0, 3, null, 12, 10]), {0: 2, 3: 1, 10: 1});
    expect(zaehleFarben(const []), isEmpty);
  });

  test('Speicherform des Filters: sortiert, ungültiges wird verworfen, leer = alle an', () {
    expect(farbFilterAlsText({5, 1, 10}), '1,5,10');
    expect(farbFilterAlsText({}), '');
    expect(farbFilterAlsText({3, 77}), '3');
    expect(farbFilterAusText('1,5,10'), {1, 5, 10});
    expect(farbFilterAusText(''), isEmpty);
    expect(farbFilterAusText(null), isEmpty);
    expect(farbFilterAusText('a,3, 4,99,-1'), {3, 4});
  });
}
