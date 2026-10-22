// Startseite anpassen: reine Logik (Zusammenführen der gemerkten Reihenfolge, Teilmengen, Verschieben, Lesen/Schreiben der Texte).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/startseite/startseite_logik.dart';

void main() {
  const std = ['a', 'b', 'c', 'd'];

  group('vollstaendigeReihenfolge', () {
    test('nichts gemerkt: Standard', () => expect(vollstaendigeReihenfolge(std, null), std));
    test('gemerkte Reihenfolge gilt', () => expect(vollstaendigeReihenfolge(std, ['c', 'a', 'd', 'b']), ['c', 'a', 'd', 'b']));
    test('unbekannte Kennungen fallen weg, doppelte auch', () => expect(vollstaendigeReihenfolge(std, ['x', 'c', 'c', 'a', 'y', 'b', 'd']), ['c', 'a', 'b', 'd']));
    test('neue (fehlende) Kacheln kommen ans Ende, in Standardreihenfolge', () => expect(vollstaendigeReihenfolge(std, ['d', 'b']), ['d', 'b', 'a', 'c']));
    test('leere gemerkte Liste: Standard', () => expect(vollstaendigeReihenfolge(std, const []), std));
  });

  test('bekannteAusgeblendete: nur bekannte Kennungen', () => expect(bekannteAusgeblendete(std, ['b', 'zzz']), {'b'}));

  group('sichtbare und angebotene Kacheln', () {
    const verf = KachelVerfuegbarkeit(angeboten: {'a', 'c', 'd'}, leer: {'d'});

    test('nicht angebotene und leere fallen aus der Anzeige, ausgeblendete auch', () {
      expect(sichtbareKacheln(reihenfolge: ['d', 'c', 'b', 'a'], verfuegbar: verf, ausgeblendet: const {}), ['c', 'a']);
      expect(sichtbareKacheln(reihenfolge: ['d', 'c', 'b', 'a'], verfuegbar: verf, ausgeblendet: const {'c'}), ['a']);
    });

    test('die Anpassen-Seite führt angebotene Kacheln auf, auch leere und ausgeblendete', () {
      expect(angeboteneKacheln(reihenfolge: ['d', 'c', 'b', 'a'], verfuegbar: verf), ['d', 'c', 'a']);
    });
  });

  group('teilmengeNeuOrdnen: nicht angezeigte Kacheln behalten ihren Platz', () {
    test('Teilmenge vertauscht, der Rest bleibt', () {
      // b ist nicht sichtbar (z. B. Müll ohne Termine) und bleibt an Platz 2
      expect(teilmengeNeuOrdnen(['a', 'b', 'c', 'd'], ['d', 'c', 'a']), ['d', 'b', 'c', 'a']);
    });

    test('ganze Liste', () => expect(teilmengeNeuOrdnen(['a', 'b', 'c'], ['c', 'b', 'a']), ['c', 'b', 'a']));
    test('unbekannte Kennung wird ignoriert', () => expect(teilmengeNeuOrdnen(['a', 'b', 'c'], ['c', 'x', 'a']), ['c', 'b', 'a']));
    test('doppelte Kennung: unverändert', () => expect(teilmengeNeuOrdnen(['a', 'b', 'c'], ['c', 'c']), ['a', 'b', 'c']));
    test('leere Teilmenge: unverändert', () => expect(teilmengeNeuOrdnen(['a', 'b'], const []), ['a', 'b']));
  });

  group('verschiebeUm', () {
    test('eine Stelle nach oben und unten', () {
      expect(verschiebeUm(['a', 'b', 'c'], ['a', 'b', 'c'], 'b', -1), ['b', 'a', 'c']);
      expect(verschiebeUm(['a', 'b', 'c'], ['a', 'b', 'c'], 'b', 1), ['a', 'c', 'b']);
    });

    test('an den Rändern bleibt alles gleich', () {
      expect(verschiebeUm(['a', 'b', 'c'], ['a', 'b', 'c'], 'a', -1), ['a', 'b', 'c']);
      expect(verschiebeUm(['a', 'b', 'c'], ['a', 'b', 'c'], 'c', 1), ['a', 'b', 'c']);
    });

    test('über eine nicht angezeigte Kachel hinweg: sie behält ihren Platz', () {
      // sichtbar: a, c, d (b fehlt); c ein Platz nach oben tauscht mit a, b bleibt Platz 2
      expect(verschiebeUm(['a', 'b', 'c', 'd'], ['a', 'c', 'd'], 'c', -1), ['c', 'b', 'a', 'd']);
    });

    test('unbekannte Kennung: unverändert', () => expect(verschiebeUm(['a', 'b'], ['a', 'b'], 'x', 1), ['a', 'b']));
  });

  group('Text lesen und schreiben', () {
    test('Rundlauf', () => expect(kennungenAusText(kennungenAlsText(['b', 'a'])), ['b', 'a']));
    test('fehlend, leer, defekt, falsche Form: null', () {
      expect(kennungenAusText(null), isNull);
      expect(kennungenAusText(''), isNull);
      expect(kennungenAusText('{kaputt'), isNull);
      expect(kennungenAusText('{"a":1}'), isNull);
      expect(kennungenAusText('"text"'), isNull);
    });
    test('Nicht-Strings in der Liste werden verworfen', () => expect(kennungenAusText('["a", 3, null, "b"]'), ['a', 'b']));
  });

  group('StartAnordnung', () {
    test('Standard ist je Layout verschieden und ohne Ausgeblendete', () {
      final m = StartAnordnung.standard(StartLayout.mobil);
      final d = StartAnordnung.standard(StartLayout.desktop);
      expect(m.reihenfolge, StartLayout.mobil.standard);
      expect(d.reihenfolge, StartLayout.desktop.standard);
      expect(m.reihenfolge, isNot(d.reihenfolge));
      expect(m.ausgeblendet, isEmpty);
      expect(m.geladen, isFalse);
    });

    test('aus Texten: unbekannt verworfen, fehlendes angehängt, geladen', () {
      final a = StartAnordnung.aus(StartLayout.mobil, reihenfolgeText: '["standort","gibtsnicht","einkauf"]', ausgeblendetText: '["wetter","nix"]');
      expect(a.geladen, isTrue);
      expect(a.reihenfolge.take(2), ['standort', 'einkauf']);
      expect(a.reihenfolge.toSet(), StartLayout.mobil.standard.toSet());
      expect(a.reihenfolge.length, StartLayout.mobil.standard.length);
      expect(a.ausgeblendet, {'wetter'});
    });

    test('defekte Texte: Standardreihenfolge, trotzdem geladen', () {
      final a = StartAnordnung.aus(StartLayout.desktop, reihenfolgeText: '###', ausgeblendetText: null);
      expect(a.reihenfolge, StartLayout.desktop.standard);
      expect(a.ausgeblendet, isEmpty);
      expect(a.geladen, isTrue);
    });
  });

  test('Schlüssel je Layout getrennt', () {
    expect(StartLayout.mobil.reihenfolgeSchluessel, 'startseite_reihenfolge_mobil');
    expect(StartLayout.desktop.reihenfolgeSchluessel, 'startseite_reihenfolge_desktop');
    expect(StartLayout.mobil.ausgeblendetSchluessel, 'startseite_ausgeblendet_mobil');
    expect(StartLayout.desktop.ausgeblendetSchluessel, 'startseite_ausgeblendet_desktop');
  });

  test('Kennungen sind je Layout eindeutig', () {
    for (final l in StartLayout.values) {
      expect(l.standard.toSet().length, l.standard.length);
    }
  });
}
