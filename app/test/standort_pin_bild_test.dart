// Nadel als Bild (Web: Symbol der Karte): gültiges PNG in der richtigen Größe, Initialen und Platzhalter, Treffer-Rechteck über der Spitze.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/standort/standort_pin.dart';
import 'package:lx_fampad/features/standort/standort_pin_bild.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Größenberechnung: logische Nadelgröße bleibt bei jeder Pixeldichte 48 x 62 (Karte rechnet Bildpixel / pixelRatio * icon-size)', () {
    for (final dpr in [1.0, 1.25, 1.5, 2.0, 2.625, 3.0, 4.0]) {
      final m = pinMassstab(dpr);
      final px = pinBildPixel(m);
      final logisch = ui.Size(px.width / dpr * pinIconSize(m, dpr), px.height / dpr * pinIconSize(m, dpr));
      expect(logisch.width, closeTo(kPinGroesse.width, 1e-9), reason: 'dpr $dpr');
      expect(logisch.height, closeTo(kPinGroesse.height, 0.7), reason: 'dpr $dpr'); // Höhe: Rundung auf ganze Bildpixel
    }
    expect(pinIconSize(pinMassstab(2), 2), 1); // Normalfall: Bild in Gerätepixeln, icon-size 1
    expect(pinMassstab(0), 1);
    expect(pinMassstab(double.nan), 1);
    expect(pinMassstab(9), 4);
  });

  test('pinPng: gültiges PNG in Nadelgröße mal Maßstab', () async {
    const kPinBildMassstab = 2.0;
    final png = await pinPng(const PinBildAngaben(farbIndex: 2, name: 'Anna Beispiel'));
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    final codec = await ui.instantiateImageCodec(png);
    final bild = (await codec.getNextFrame()).image;
    expect(bild.width, (kPinGroesse.width * kPinBildMassstab).round());
    expect(bild.height, (kPinGroesse.height * kPinBildMassstab).round());
  });

  test('pinPng: veraltet, gewählt und unlesbares Kopfbild ergeben trotzdem ein Bild', () async {
    final a = await pinPng(PinBildAngaben(farbIndex: 0, name: 'Ben', veraltet: true));
    final b = await pinPng(PinBildAngaben(farbIndex: 0, name: 'Ben', gewaehlt: true, kopfBild: Uint8List.fromList([1, 2, 3])));
    expect(a.length, greaterThan(100));
    expect(b.length, greaterThan(100));
    expect(a, isNot(b));
  });

  test('Schlüssel unterscheidet die Angaben', () {
    const x = PinBildAngaben(farbIndex: 1, name: 'A');
    expect(x.schluessel, const PinBildAngaben(farbIndex: 1, name: 'A').schluessel);
    expect(x.schluessel, isNot(const PinBildAngaben(farbIndex: 1, name: 'A', gewaehlt: true).schluessel));
  });

  test('pinGetroffen: Fläche der Nadel über der Spitze', () {
    const spitze = ui.Offset(200, 300);
    expect(pinGetroffen(const ui.Offset(200, 270), spitze), isTrue);
    expect(pinGetroffen(const ui.Offset(200, 301), spitze), isFalse);
    expect(pinGetroffen(const ui.Offset(200, 230), spitze), isFalse);
    expect(pinGetroffen(const ui.Offset(260, 280), spitze), isFalse);
  });

  group('PinBildCache', () {
    test('anfordern: neu ja, laufend/fertig nein; Ergebnis löst das Vorgängerbild ab', () {
      final c = PinBildCache();
      expect(c.anfordern('a', 'a1'), isTrue);
      expect(c.anfordern('a', 'a1'), isFalse); // läuft schon
      expect(c.fertig('a', 'a1', ok: true), isEmpty);
      expect(c.bereit['a'], 'a1');
      expect(c.anfordern('a', 'a1'), isFalse); // fertig
      expect(c.anfordern('a', 'a2'), isTrue);
      expect(c.fertig('a', 'a2', ok: true), ['a1']); // altes Bild wird entfernt
      expect(c.bereit['a'], 'a2');
    });

    test('Wählen, Abwählen, Wählen: nie zweimal dasselbe Bild im Stil, überholte Bilder werden entfernt', () {
      final c = PinBildCache();
      expect(c.anfordern('a', 'frei'), isTrue);
      c.fertig('a', 'frei', ok: true);
      expect(c.anfordern('a', 'gewaehlt'), isTrue); // läuft
      expect(c.anfordern('a', 'frei'), isFalse); // wieder abgewählt: das freie Bild liegt noch im Stil
      expect(c.fertig('a', 'gewaehlt', ok: true), ['gewaehlt']); // überholt: gleich wieder weg
      expect(c.bereit['a'], 'frei');
    });

    test('Fehler: dieselbe Kennung wird nicht endlos neu versucht', () {
      final c = PinBildCache();
      expect(c.anfordern('a', 'x'), isTrue);
      expect(c.fertig('a', 'x', ok: false), isEmpty);
      for (var i = 0; i < 5; i++) {
        expect(c.anfordern('a', 'x'), isFalse);
      }
      expect(c.bereit.containsKey('a'), isFalse);
      expect(c.anfordern('a', 'y'), isTrue); // anderer Zustand: neuer Versuch
    });

    test('Person weg: Bild wird frei, ein noch laufendes Bild wird danach verworfen', () {
      final c = PinBildCache();
      c.anfordern('a', 'a1');
      c.fertig('a', 'a1', ok: true);
      c.anfordern('b', 'b1');
      expect(c.aufraeumen({'a'}), isEmpty); // b hat noch kein fertiges Bild
      expect(c.fertig('b', 'b1', ok: true), ['b1']); // b ist weg: das fertige Bild gleich entfernen
      expect(c.aufraeumen({}), ['a1']);
      expect(c.bereit, isEmpty);
    });

    test('leeren: alles vergessen (neue Karten-Ansicht)', () {
      final c = PinBildCache();
      c.anfordern('a', 'a1');
      c.fertig('a', 'a1', ok: false);
      c.leeren();
      expect(c.anfordern('a', 'a1'), isTrue);
    });
  });
}
