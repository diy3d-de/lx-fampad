// Anmeldezustand der App (Riverpod): prüfe / abgemeldet / angemeldet / wartend auf Freigabe / Verbindungsfehler.
// Pflicht-Update liegt in updateProvider (features/update) und hat in app.dart Vorrang vor allen Zuständen.
// Start: GET /me prüft die Sitzung. Abmelden löscht Token und lokale Daten (Hook localDataWiperProvider für Phase 1c).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../api/models.dart';
import '../api/token_store.dart';
import '../passkey_service.dart';
import '../providers.dart';
import '../system_channel.dart';

enum AuthStatus {
  /// Beim Start: Sitzung wird geprüft.
  pruefe,
  abgemeldet,
  angemeldet,

  /// Konto angelegt, wartet auf die Freigabe durch einen Admin.
  wartend,

  /// Start ohne Verbindung und ohne gespeicherte Sitzungsdaten (Web) bzw. unerwarteter Fehler.
  verbindungsfehler,
}

class AuthState {
  final AuthStatus status;
  final UserDto? user;
  final MeDto? me;

  /// Hinweis für die Anmeldeseite (z. B. "Sitzung abgelaufen") oder Fehlertext beim Start.
  final String? hinweis;

  /// Angemeldet mit gespeicherten Daten, aber ohne Verbindung zum Server.
  final bool offline;

  const AuthState({required this.status, this.user, this.me, this.hinweis, this.offline = false});

  const AuthState.pruefe() : this(status: AuthStatus.pruefe);

  bool get angemeldet => status == AuthStatus.angemeldet;
  Role? get rolle => user?.role;
  bool get istAdmin => rolle == Role.admin;
  bool get darfEinladen => rolle == Role.admin || rolle == Role.parent;
}

/// Hook für Phase 1c: leert beim Abmelden die lokale drift-Datenbank (Sync-Zustand, Outbox, Fachdaten).
/// main.dart ersetzt ihn durch die echte Löschung; hier der Standard ohne Wirkung (Tests, Phase 1b).
final localDataWiperProvider = Provider<Future<void> Function()>((ref) => () async {});

final tokenStoreProvider = Provider<TokenStore>((ref) => kIsWeb ? MemoryTokenStore() : SecureTokenStore());

final systemChannelProvider = Provider<SystemChannel>((ref) => SystemChannel());

final passkeyServiceProvider = Provider<PasskeyService>((ref) => CorbadoPasskeyService());

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(client: ref.watch(httpClientProvider), store: ref.watch(tokenStoreProvider)));

final apiProvider = Provider<FampadApi>((ref) {
  final store = ref.watch(tokenStoreProvider);
  final channel = ref.watch(systemChannelProvider);
  return FampadApi(
    ref.watch(apiClientProvider),
    geraet: () async {
      if (kIsWeb) return null;
      final name = (await channel.geraetename())?.trim() ?? '';
      return DeviceInfo(
        id: await store.readDeviceId(),
        name: name.isEmpty ? 'Android-Gerät' : name,
        platform: 'android',
        appVersion: await channel.appVersion(),
      );
    },
  );
});

class AuthController extends Notifier<AuthState> {
  FampadApi get _api => ref.read(apiProvider);
  ApiClient get _client => ref.read(apiClientProvider);

  @override
  AuthState build() {
    // Bei verlorener Sitzung (401, Erneuerung gescheitert) zurück zur Anmeldung
    final client = _client;
    client.onSessionLost = _sitzungVerloren;
    ref.onDispose(() => client.onSessionLost = null);
    return const AuthState.pruefe();
  }

  void _sitzungVerloren(SessionLostReason grund) {
    if (state.status == AuthStatus.abgemeldet) return;
    state = AuthState(
      status: AuthStatus.abgemeldet,
      hinweis: grund == SessionLostReason.unsicher
          ? 'Die Verbindung brach beim Erneuern deiner Anmeldung ab. Bitte melde dich noch einmal an.'
          : 'Deine Sitzung ist abgelaufen. Bitte melde dich neu an.',
    );
  }

  /// Beim Start der App: Sitzung prüfen.
  Future<void> start() async {
    state = const AuthState.pruefe();
    try {
      if (!_client.istWeb && !await _client.hatGespeicherteToken()) {
        state = const AuthState(status: AuthStatus.abgemeldet);
        return;
      }
      final me = await _api.ich();
      await _uebernehmen(me);
    } on ApiException catch (e) {
      await _startFehler(e);
    }
  }

  Future<void> _startFehler(ApiException e) async {
    switch (e.kind) {
      case ApiErrorKind.nichtAngemeldet:
        // _sitzungVerloren hat den Zustand schon gesetzt; sonst (kein Callback) hier
        if (state.status != AuthStatus.abgemeldet) state = const AuthState(status: AuthStatus.abgemeldet);
      case ApiErrorKind.kontoWartet:
        state = const AuthState(status: AuthStatus.wartend);
      case ApiErrorKind.netzwerk:
        // Offline-first: mit gespeichertem Profil trotzdem in die App (nur Android; im Web gibt es keine lokale Sitzungsablage)
        final profil = await ref.read(tokenStoreProvider).readProfile();
        if (!_client.istWeb && profil != null) {
          try {
            state = AuthState(status: AuthStatus.angemeldet, user: UserDto.fromJson(profil), offline: true);
            return;
          } on ApiException {
            // Profil unbrauchbar
          }
        }
        state = AuthState(status: AuthStatus.verbindungsfehler, hinweis: e.message);
      default:
        state = AuthState(status: AuthStatus.verbindungsfehler, hinweis: e.message);
    }
  }

  Future<void> _uebernehmen(MeDto me) async {
    if (me.user.status == MemberStatus.pending) {
      state = AuthState(status: AuthStatus.wartend, user: me.user);
      return;
    }
    state = AuthState(status: AuthStatus.angemeldet, user: me.user, me: me);
    if (!_client.istWeb) await ref.read(tokenStoreProvider).writeProfile(me.user.toJson());
  }

  /// Lädt /me neu (Profil, Zugänge, Rolle); Fehler lassen den Zustand unverändert.
  Future<void> neuLaden() async {
    try {
      final me = await _api.ich();
      if (ref.mounted) await _uebernehmen(me);
    } on ApiException {
      // Zustand bleibt, Aufrufer zeigen ihre eigenen Fehler
    }
  }

  // ------------------------------------------------------------ Anmeldung

  Future<void> mitPasskeyAnmelden() async {
    final ch = await _api.passkeyAnmeldeOptionen();
    final antwort = await ref.read(passkeyServiceProvider).bestaetigen(ch.options);
    await _anmelden(() => _api.passkeyAnmelden(challengeId: ch.challengeId, antwort: antwort));
  }

  Future<void> mitPasswortAnmelden({required String email, required String passwort, String? totp, String? wiederherstellungscode}) =>
      _anmelden(() => _api.passwortAnmelden(email: email, passwort: passwort, totp: totp, wiederherstellungscode: wiederherstellungscode));

  Future<void> mitWiederherstellungscodeAnmelden({required String email, required String code}) =>
      _anmelden(() => _api.wiederherstellungAnmelden(email: email, code: code));

  Future<void> _anmelden(Future<LoginResult> Function() schritt) async {
    final LoginResult r;
    try {
      r = await schritt();
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.kontoWartet) state = const AuthState(status: AuthStatus.wartend);
      rethrow;
    }
    await _client.sitzungUebernehmen(r.session);
    state = AuthState(status: AuthStatus.angemeldet, user: r.user);
    if (!_client.istWeb) await ref.read(tokenStoreProvider).writeProfile(r.user.toJson());
    unawaited(neuLaden());
  }

  /// Nach erfolgreicher Registrierung (und bestätigten Wiederherstellungscodes): Sitzung übernehmen bzw. auf Freigabe warten.
  Future<void> registrierungAbschliessen(RegistrationResult r) async {
    if (r.status == MemberStatus.pending || r.session == null) {
      state = AuthState(status: AuthStatus.wartend, user: r.member);
      return;
    }
    await _client.sitzungUebernehmen(r.session!);
    state = AuthState(status: AuthStatus.angemeldet, user: r.member);
    if (!_client.istWeb) await ref.read(tokenStoreProvider).writeProfile(r.member.toJson());
    unawaited(neuLaden());
  }

  /// Zurück zur Anmeldung (z. B. vom Warte-Bildschirm).
  void zurAnmeldung() => state = const AuthState(status: AuthStatus.abgemeldet);

  // ------------------------------------------------------------ Abmelden

  /// Meldet dieses Gerät (oder alle Geräte) ab, löscht Token und lokale Daten. Serverfehler (z. B. offline) verhindern es nicht.
  Future<void> abmelden({bool ueberall = false}) async {
    try {
      if (ueberall) {
        await _api.ueberallAbmelden();
      } else {
        await _api.abmelden();
      }
    } on ApiException {
      // Sitzung ist lokal trotzdem beendet; der Server verwirft sie spätestens nach Ablauf bzw. über die Geräteliste
    }
    await _client.sitzungVerwerfen();
    await ref.read(localDataWiperProvider)();
    state = const AuthState(status: AuthStatus.abgemeldet);
  }

  /// Wird nach dem Entfernen des eigenen Geräts in der Geräteliste aufgerufen.
  Future<void> dieseSitzungBeendet() async {
    await _client.sitzungVerwerfen();
    await ref.read(localDataWiperProvider)();
    state = const AuthState(status: AuthStatus.abgemeldet);
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);
