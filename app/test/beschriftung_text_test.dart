import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/ui/widgets.dart';

void main() {
  group('beschriftungText', () {
    test('leer und nur Präfix', () {
      expect(beschriftungText(''), '');
      expect(beschriftungText('// '), '');
      expect(beschriftungText('   '), '');
    });
    test('führendes "// " und Zeilenumbruch', () {
      expect(beschriftungText('// zuletzt'), 'Zuletzt');
      expect(beschriftungText('\nabc'), 'Abc');
    });
    test('Ziffer bleibt', () => expect(beschriftungText('7 Tage'), '7 Tage'));
    test('Umlaut wird groß', () => expect(beschriftungText('ärzte'), 'Ärzte'));
    test('kWh und iPhone bleiben', () {
      expect(beschriftungText('kWh pro Jahr'), 'kWh pro Jahr');
      expect(beschriftungText('iPhone'), 'iPhone');
    });
    test('ß am Anfang bleibt', () => expect(beschriftungText('ßtraße'), 'ßtraße'));
    test('Emoji bleibt', () => expect(beschriftungText('😀 gut'), '😀 gut'));
    test('schon richtig', () {
      expect(beschriftungText('Absicherung'), 'Absicherung');
      expect(beschriftungText('a'), 'A');
    });
  });
}
