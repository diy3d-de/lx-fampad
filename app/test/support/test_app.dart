// Aufbau von Provider-Überschreibungen für Tests: Fake-Server, Speicher im Arbeitsspeicher, Fake-Passkeys.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/data/providers.dart';

import 'fake_server.dart';

class FakePasskeys implements PasskeyService {
  bool da = true;
  PasskeyException? fehler;
  int erstellt = 0;
  int bestaetigt = 0;
  Map<String, dynamic>? letzteOptionen;

  @override
  Future<bool> verfuegbar() async => da;

  @override
  Future<Map<String, dynamic>> erstellen(Map<String, dynamic> optionen) async {
    letzteOptionen = optionen;
    if (fehler != null) throw fehler!;
    erstellt++;
    return {
      'id': 'cred-1',
      'rawId': 'cred-1',
      'type': 'public-key',
      'response': {'clientDataJSON': 'e30', 'attestationObject': 'o2M'},
      'clientExtensionResults': <String, dynamic>{},
    };
  }

  @override
  Future<Map<String, dynamic>> bestaetigen(Map<String, dynamic> optionen) async {
    letzteOptionen = optionen;
    if (fehler != null) throw fehler!;
    bestaetigt++;
    return {
      'id': 'cred-1',
      'rawId': 'cred-1',
      'type': 'public-key',
      'response': {'clientDataJSON': 'e30', 'authenticatorData': 'AA', 'signature': 'c2ln'},
      'clientExtensionResults': <String, dynamic>{},
    };
  }
}

class TestUmgebung {
  final FakeServer server;
  final MemoryTokenStore store;
  final FakePasskeys passkeys;
  final bool web;
  int geloescht = 0;
  late final ApiClient client = ApiClient(client: server.client, store: store, web: web, base: 'https://familie.test');

  TestUmgebung(this.server, {this.web = false, MemoryTokenStore? store, FakePasskeys? passkeys})
    : store = store ?? MemoryTokenStore(),
      passkeys = passkeys ?? FakePasskeys();

  /// Legt gültige App-Token ab (angemeldetes Gerät).
  Future<void> angemeldet() => store.writeTokens(
    StoredTokens(
      accessToken: 'access-1',
      accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
      refreshToken: 'refresh-1',
      refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
      deviceId: fixDevice,
    ),
  );

  List<Override> get overrides => [
    httpClientProvider.overrideWithValue(server.client),
    tokenStoreProvider.overrideWithValue(store),
    apiClientProvider.overrideWithValue(client),
    passkeyServiceProvider.overrideWithValue(passkeys),
    localDataWiperProvider.overrideWithValue(() async => geloescht++),
  ];

  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides);
    return c;
  }
}
