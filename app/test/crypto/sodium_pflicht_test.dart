// CI-Absicherung: Ist libsodium erforderlich (SODIUM_ERFORDERLICH=1), darf ein Ladefehler die Kryptotests nie still überspringen lassen.
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';

import '../support/fake_crypto.dart';

void main() {
  Future<CryptoProvider> kaputt() async => throw const CryptoFehler(CryptoFehlerArt.bibliothek, 'nicht ladbar');

  test('erforderlich: Ladefehler schlägt fehl (statt zu überspringen)', () async {
    await expectLater(ladeEchtesSodium(kaputt, erforderlich: true), throwsA(isA<CryptoFehler>()));
  });

  test('nicht erforderlich: Ladefehler ergibt null (Tests werden übersprungen)', () async {
    expect(await ladeEchtesSodium(kaputt, erforderlich: false), isNull);
  });

  test('gelungenes Laden wird durchgereicht', () async {
    final fake = FakeCryptoProvider();
    expect(await ladeEchtesSodium(() async => fake, erforderlich: true), same(fake));
  });
}
