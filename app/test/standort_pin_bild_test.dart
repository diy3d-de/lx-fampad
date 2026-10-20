// Nadel als Bild (Web: Symbol der Karte): gültiges PNG in der richtigen Größe, Initialen und Platzhalter, Treffer-Rechteck über der Spitze.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/standort/standort_pin.dart';
import 'package:lx_fampad/features/standort/standort_pin_bild.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pinPng: gültiges PNG in Nadelgröße mal Maßstab', () async {
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
}
