// "Folgen" auf der Standortkarte: Wahl des Ziels als reine Funktion.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/standort/standort_folgen.dart';

void main() {
  test('Ziel: die gewählte Person, sonst die einzige, bei mehreren ohne Auswahl niemand', () {
    expect(folgeZiel(gewaehlt: 'a', ids: ['a', 'b']), 'a');
    expect(folgeZiel(gewaehlt: null, ids: ['a']), 'a');
    expect(folgeZiel(gewaehlt: null, ids: ['a', 'b']), isNull);
    expect(folgeZiel(gewaehlt: null, ids: const []), isNull);
  });

  test('eine gewählte Person, die nicht (mehr) auf der Karte ist, zählt nicht: dann die einzige, sonst niemand', () {
    expect(folgeZiel(gewaehlt: 'x', ids: ['a']), 'a');
    expect(folgeZiel(gewaehlt: 'x', ids: ['a', 'b']), isNull);
  });
}
