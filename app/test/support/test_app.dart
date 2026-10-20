// Aufbau von Provider-Überschreibungen für Tests: Fake-Server, Speicher im Arbeitsspeicher, Fake-Passkeys.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/data/database_provider.dart';
import 'package:lx_fampad/data/providers.dart';
import 'package:lx_fampad/data/standort/standort_dienst.dart' show standortPortProvider;
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart' show MemoryErinnerungSpeicher;
import 'package:lx_fampad/data/standort/standort_hinweis.dart';
import 'package:lx_fampad/data/standort/standort_port.dart' show KeinStandortPort, StandortPort;
import 'package:lx_fampad/features/standort/standort_karte.dart' show StandortKartenBuilder, standortKartenBuilderProvider;
import 'package:lx_fampad/data/sync_state.dart';

import 'fake_server.dart';
import 'fake_socket.dart';
import 'fake_sync_server.dart';

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

  /// Lokale Datenbank (im Arbeitsspeicher), Sync-Fake und WebSocket-Fake dieser Umgebung.
  // Abfrage-Streams sofort schließen: sonst bleiben nach dem Abbau des Widget-Baums Timer von drift stehen (Flutter-Test bricht dann ab)
  final AppDatabase db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  final FakeSyncServer sync = FakeSyncServer();
  final FakeSocketFabrik sockets = FakeSocketFabrik();
  SyncZeiten zeiten = const SyncZeiten();

  /// Wirft der Wiper (lokale Daten löschen)? Zählt trotzdem als Aufruf.
  bool wiperFehler = false;
  bool wiperEcht = false;
  bool besitzerInDb = false;
  final owner = MemoryLocalDataOwner();
  /// false: der Client löst nie das Refresh-Token ein (Hintergrund-Abgleich); vor dem ersten Zugriff auf [client] setzen.
  bool refreshErlaubt = true;
  late final ApiClient client = ApiClient(client: server.client, store: store, web: web, base: 'https://familie.test', refreshErlaubt: refreshErlaubt);

  TestUmgebung(this.server, {this.web = false, MemoryTokenStore? store, FakePasskeys? passkeys})
    : store = store ?? MemoryTokenStore(),
      passkeys = passkeys ?? FakePasskeys() {
    if (!server.routes.containsKey('POST /sync')) sync.registrieren(server);
  }

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

  /// Zusätzliche Überschreibungen einzelner Tests (z. B. ein Stream, der einen Lesefehler meldet).
  final List<Override> extraOverrides = [];

  /// Gerätedienst fürs Standort teilen (Standard: keiner, wie im Browser).
  StandortPort standortPort = const KeinStandortPort();

  /// Karte der Standort-Seite (Standard: keine, nur die Liste; die echte Karte läuft im Test nicht).
  StandortKartenBuilder? standortKarte;

  List<Override> get overrides => [
    httpClientProvider.overrideWithValue(server.client),
    tokenStoreProvider.overrideWithValue(store),
    apiClientProvider.overrideWithValue(client),
    passkeyServiceProvider.overrideWithValue(passkeys),
    // wiperEcht: der echte Wiper der App (Sync anhalten, Datenbank leeren) statt des zählenden Fakes
    if (wiperEcht)
      localDataWiperProvider.overrideWith(lokaleDatenWiper)
    else
      localDataWiperProvider.overrideWithValue(() async {
        geloescht++;
        if (wiperFehler) throw StateError('Löschen fehlgeschlagen');
      }),
    // besitzerInDb: wie in der App der Besitzer in sync_meta der echten (hier: In-Memory-)Datenbank
    localDataOwnerProvider.overrideWithValue(besitzerInDb ? DatenbankBesitzer(db) : owner),
    appDatabaseProvider.overrideWithValue(db),
    syncSocketOeffnerProvider.overrideWithValue(sockets.oeffner),
    syncZeitenProvider.overrideWithValue(zeiten),
    // Standort teilen: kein Gerätedienst im Test (der Kanal zur Android-Seite fehlt dort)
    standortPortProvider.overrideWithValue(standortPort),
    standortKartenBuilderProvider.overrideWithValue(standortKarte),
    // Standort-Hinweise: im Test gilt die App als im Vordergrund (kein Kurzabruf des Standort-Kanals nach einem Wecker, keine System-Benachrichtigung)
    standortBenachrichtigerProvider.overrideWithValue(
      StandortBenachrichtiger(db: db, anzeige: const KeineStandortAnzeige(), speicher: MemoryErinnerungSpeicher(), ich: () async => null, istVordergrund: () => true),
    ),
    ...extraOverrides,
  ];

  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides);
    return c;
  }
}
