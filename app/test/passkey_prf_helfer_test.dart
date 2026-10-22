// Hilfen der Passkey-Anmeldung mit PRF: Ausgabe aus den Client-Erweiterungen lesen (echte Formen, nie ein Fehler), die PRF-Ausgabe aus der Antwort an den Server entfernen,
// Kennungen mit und ohne Füllzeichen gleich behandeln.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/passkey_service.dart';

void main() {
  final ausgabe = Uint8List.fromList(List.generate(32, (i) => i + 1));

  group('prfAusgabeAus', () {
    test('echte Form: prf.results.first als Base64url (mit und ohne Füllzeichen)', () {
      final ohne = base64Url.encode(ausgabe).replaceAll('=', '');
      final mit = base64Url.encode(ausgabe);
      expect(prfAusgabeAus({'prf': {'enabled': true, 'results': {'first': ohne}}}), ausgabe);
      expect(prfAusgabeAus({'prf': {'results': {'first': mit}}}), ausgabe);
    });

    test('jede Abweichung ergibt null und nie einen Fehler', () {
      expect(prfAusgabeAus(null), isNull);
      expect(prfAusgabeAus(const {}), isNull);
      expect(prfAusgabeAus({'prf': {'enabled': true}}), isNull, reason: 'bei der Registrierung gibt es nur "enabled"');
      expect(prfAusgabeAus({'prf': 'x'}), isNull);
      expect(prfAusgabeAus({'prf': {'results': 'x'}}), isNull);
      expect(prfAusgabeAus({'prf': {'results': {'first': ''}}}), isNull);
      expect(prfAusgabeAus({'prf': {'results': {'first': 5}}}), isNull);
      expect(prfAusgabeAus({'prf': {'results': {'first': '***nicht base64***'}}}), isNull);
    });
  });

  group('antwortOhnePrf', () {
    test('entfernt die PRF-Ausgabe, lässt alles andere stehen', () {
      final antwort = {
        'id': 'abc',
        'rawId': 'abc',
        'type': 'public-key',
        'response': {'clientDataJSON': 'x'},
        'clientExtensionResults': {
          'prf': {'results': {'first': base64Url.encode(ausgabe)}},
          'credProps': {'rk': true},
        },
      };
      final r = antwortOhnePrf(antwort);
      expect(jsonEncode(r).contains(base64Url.encode(ausgabe)), isFalse);
      expect(r['clientExtensionResults'], {'credProps': {'rk': true}});
      expect(r['id'], 'abc');
      expect((r['response'] as Map)['clientDataJSON'], 'x');
      // die Eingabe bleibt unverändert
      expect((antwort['clientExtensionResults'] as Map).containsKey('prf'), isTrue);
    });

    test('nur PRF: ein leeres Ergebnis bleibt stehen; ohne Ergebnisse oder ohne prf bleibt die Antwort gleich', () {
      expect(antwortOhnePrf({'id': 'a', 'clientExtensionResults': {'prf': {'results': {'first': 'AAAA'}}}})['clientExtensionResults'], isEmpty);
      final ohne = {'id': 'a'};
      expect(identical(antwortOhnePrf(ohne), ohne), isTrue);
      final ohnePrf = {'id': 'a', 'clientExtensionResults': {'credProps': {}}};
      expect(identical(antwortOhnePrf(ohnePrf), ohnePrf), isTrue);
    });
  });

  test('passkeyKennung: Füllzeichen fallen weg, sonst unverändert', () {
    expect(passkeyKennung('abc_-DEF=='), 'abc_-DEF');
    expect(passkeyKennung('abc_-DEF'), 'abc_-DEF');
    expect(passkeyKennung(''), '');
  });
}
