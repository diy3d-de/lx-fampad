// Anmeldezustand der App (Riverpod): prüfe / abgemeldet / angemeldet / wartend auf Freigabe / Verbindungsfehler.
// Pflicht-Update liegt in updateProvider (features/update) und hat in app.dart Vorrang vor allen Zuständen.
// Start: GET /me prüft die Sitzung. Ausdrückliches Abmelden löscht Token und lokale Daten (Hook localDataWiperProvider für Phase 1c).
//
// Lokale Daten und Sitzungsverlust: Verliert die App die Sitzung (abgelaufen, widerrufen, Erneuerung gescheitert), bleibt die lokale
// Datenbank erhalten: sie kann noch ungesendete Änderungen enthalten, die nach erneuter Anmeldung derselben Person nicht verloren
// gehen sollen. Geleert wird sie (1) beim ausdrücklichen Abmelden und (2) sobald sich eine ANDERE Person anmeldet. Dafür merkt sich
// die Datenbank die Benutzer-ID ihres Besitzers (Hook localDataOwnerProvider).
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

  /// Betreiber des Servers (Konto-Flag, unabhängig von der Familienrolle): sieht den Bereich "Betrieb".
  bool get istBetreiber => me?.betreiber ?? false;
}

/// Hook für Phase 1c: leert beim Abmelden die lokale drift-Datenbank (Sync-Zustand, Outbox, Fachdaten).
/// main.dart ersetzt ihn durch die echte Löschung; hier der Standard ohne Wirkung (Tests, Phase 1b).
final localDataWiperProvider = Provider<Future<void> Function()>((ref) => () async {});

/// Merkt, wessen Daten in der lokalen Datenbank liegen (Benutzer-ID). Liegt in der Datenbank selbst und verschwindet mit ihr.
abstract class LocalDataOwner {
  Future<String?> lesen();
  Future<void> setzen(String userId);
}

/// Standard (Tests, Phase 1b ohne Datenbank): nur im Arbeitsspeicher.
class MemoryLocalDataOwner implements LocalDataOwner {
  String? _id;
  @override
  Future<String?> lesen() async => _id;
  @override
  Future<void> setzen(String userId) async => _id = userId;
}

/// Hook für Push (main.dart): beim Abmelden den Endpunkt beim Server löschen (`serverLoeschen`, solange die Sitzung noch gilt) und beim
/// Verteiler (ntfy-App) abmelden. Standard: nichts (Tests, Web).
final pushAbmeldenProvider = Provider<Future<void> Function({required bool serverLoeschen})>((ref) => ({required bool serverLoeschen}) async {});

final localDataOwnerProvider = Provider<LocalDataOwner>((ref) => MemoryLocalDataOwner());

/// Ergebnis des Abmeldens (die Person wird informiert, wenn etwas nicht vollständig geklappt hat).
class AbmeldeErgebnis {
  /// Der Server hat die Sitzung beendet (oder sie war dort schon beendet).
  final bool serverAbgemeldet;

  /// Token und lokale Daten wurden vollständig entfernt.
  final bool lokalSauber;
  const AbmeldeErgebnis({required this.serverAbgemeldet, required this.lokalSauber});
}

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

  /// Zählt Anmelde-Ereignisse (Start, Anmelden, Abmelden, Personenwechsel). Späte Antworten von /me aus einer früheren
  /// Generation überschreiben den Zustand nicht (z. B. eine Antwort, die erst nach dem Abmelden oder einem Personenwechsel eintrifft).
  int _gen = 0;
  bool _aktuell(int gen) => ref.mounted && gen == _gen;

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

  /// Beim Start der App: Sitzung prüfen. Endet immer in einem Zustand ohne Ladeanzeige (angemeldet, abgemeldet, wartend, Verbindungsfehler).
  Future<void> start() async {
    final gen = ++_gen;
    state = const AuthState.pruefe();
    try {
      if (!_client.istWeb && !await _client.hatGespeicherteToken()) {
        if (_aktuell(gen)) state = const AuthState(status: AuthStatus.abgemeldet);
        return;
      }
      final me = await _api.ich();
      await _uebernehmen(me, gen);
    } on ApiException catch (e) {
      if (!_aktuell(gen)) return;
      try {
        await _startFehler(e, gen);
      } catch (_) {
        if (_aktuell(gen)) state = const AuthState(status: AuthStatus.verbindungsfehler, hinweis: _startFehlerText);
      }
    } catch (_) {
      // z. B. defekter Sicherer Speicher oder unerwartete Antwort: kein Endlos-Spinner, sondern Fehlerseite mit "Erneut versuchen"
      if (_aktuell(gen)) state = const AuthState(status: AuthStatus.verbindungsfehler, hinweis: _startFehlerText);
    }
  }

  static const _startFehlerText = 'Beim Start ist ein Fehler aufgetreten. Bitte versuche es noch einmal.';

  Future<void> _startFehler(ApiException e, int gen) async {
    // Serverseitige Störungen (503 server_busy, 429, 5xx, auch eine Fehlerseite von Caddy bei 502) sind für den Start wie fehlendes
    // Netz: Der Server ist gerade nicht zu erreichen, die Sitzung ist damit nicht widerlegt.
    final serverNichtErreichbar =
        e.kind == ApiErrorKind.netzwerk || e.kind == ApiErrorKind.serverBusy || e.kind == ApiErrorKind.zuVieleAnfragen || e.status >= 500;
    if (e.kind == ApiErrorKind.nichtAngemeldet) {
      // Web: Beim Start ist ein 401 der Normalfall (Erstbesuch, kein Cookie) und kein "Sitzung abgelaufen": kein Hinweis.
      // Android: _sitzungVerloren hat den Zustand samt Hinweis schon gesetzt; sonst (kein Callback) hier.
      if (_client.istWeb || state.status != AuthStatus.abgemeldet) state = const AuthState(status: AuthStatus.abgemeldet);
    } else if (e.kind == ApiErrorKind.kontoWartet) {
      state = const AuthState(status: AuthStatus.wartend);
    } else if (serverNichtErreichbar) {
      // Offline-first: mit gespeichertem Profil trotzdem in die App (nur Android; im Web gibt es keine lokale Sitzungsablage)
      final profil = _client.istWeb ? null : await ref.read(tokenStoreProvider).readProfile();
      if (!_aktuell(gen)) return;
      if (profil != null) {
        try {
          state = AuthState(status: AuthStatus.angemeldet, user: UserDto.fromJson(profil), offline: true);
          return;
        } on ApiException {
          // Profil unbrauchbar
        }
      }
      state = AuthState(status: AuthStatus.verbindungsfehler, hinweis: e.message);
    } else {
      state = AuthState(status: AuthStatus.verbindungsfehler, hinweis: e.message);
    }
  }

  /// Übernimmt eine /me-Antwort. [gen]: Generation, in der die Anfrage begann; [erwarteteUserId]: nur anwenden, wenn weiterhin diese
  /// Person angemeldet ist (null beim Start).
  Future<void> _uebernehmen(MeDto me, int gen, {String? erwarteteUserId}) async {
    bool passt() => _aktuell(gen) && (erwarteteUserId == null || (state.status == AuthStatus.angemeldet && state.user?.id == erwarteteUserId && me.user.id == erwarteteUserId));
    if (!passt()) return;
    if (me.user.status == MemberStatus.pending) {
      state = AuthState(status: AuthStatus.wartend, user: me.user);
      return;
    }
    if (erwarteteUserId == null) await _datenZuordnen(me.user.id);
    if (!passt()) return;
    state = AuthState(status: AuthStatus.angemeldet, user: me.user, me: me);
    if (!_client.istWeb) await ref.read(tokenStoreProvider).writeProfile(me.user.toJson());
  }

  /// Lädt /me neu (Profil, Zugänge, Rolle); Fehler lassen den Zustand unverändert. Eine späte Antwort nach Abmelden oder
  /// Personenwechsel wird verworfen.
  Future<void> neuLaden() async {
    if (state.status != AuthStatus.angemeldet) return;
    final gen = _gen;
    final userId = state.user?.id;
    try {
      final me = await _api.ich();
      await _uebernehmen(me, gen, erwarteteUserId: userId);
    } on ApiException {
      // Zustand bleibt, Aufrufer zeigen ihre eigenen Fehler
    }
  }

  /// Ordnet die lokale Datenbank der angemeldeten Person zu: Gehörten die Daten einer ANDEREN Person, werden sie vorher gelöscht
  /// (nicht aber bei einer erneuten Anmeldung derselben Person nach Sitzungsverlust: ungesendete Änderungen bleiben erhalten).
  /// Ist die Datenbank nicht lesbar, bleibt es bei dem, was da ist (kein Abbruch der Anmeldung).
  Future<void> _datenZuordnen(String userId) async {
    final LocalDataOwner besitzer = ref.read(localDataOwnerProvider);
    String? bisher;
    try {
      bisher = await besitzer.lesen();
    } catch (_) {
      return;
    }
    if (bisher != null && bisher != userId) await ref.read(localDataWiperProvider)();
    if (bisher != userId) {
      try {
        await besitzer.setzen(userId);
      } catch (_) {
        // wird bei der nächsten Anmeldung erneut versucht
      }
    }
  }

  // ------------------------------------------------------------ Anmeldung

  Future<void> mitPasskeyAnmelden() async {
    final ch = await _api.passkeyAnmeldeOptionen();
    final antwort = await ref.read(passkeyServiceProvider).bestaetigen(ch.options);
    await _anmelden(() => _api.passkeyAnmelden(challengeId: ch.challengeId, antwort: antwort));
  }

  /// Ein einzelner Anmeldeversuch mit Passwort: entweder [authKey] (abgeleitet) oder [passwort] (Klartext, alter Weg; mit [upgradeAuthKey] zur Umstellung).
  /// Die Wahl des Weges trifft `PasswortAnmeldung` (passwort_anmeldung.dart).
  Future<void> mitPasswortAnmelden({
    required String email,
    String? passwort,
    String? authKey,
    String? upgradeAuthKey,
    String? totp,
    String? wiederherstellungscode,
  }) => _anmelden(
    () => _api.passwortAnmelden(
      email: email,
      passwort: passwort,
      authKey: authKey,
      upgradeAuthKey: upgradeAuthKey,
      totp: totp,
      wiederherstellungscode: wiederherstellungscode,
    ),
  );

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
    await _angemeldet(r.user);
  }

  /// Schließt die Anmeldung ab: Daten der Person zuordnen (bei Personenwechsel vorher leeren), Zustand setzen, /me nachladen.
  Future<void> _angemeldet(UserDto user) async {
    final gen = ++_gen; // frühere Anfragen (Start, Neuladen) dürfen den neuen Zustand nicht mehr überschreiben
    try {
      await _datenZuordnen(user.id);
    } catch (_) {
      // Die Daten der vorherigen Person ließen sich nicht entfernen: nicht in ihren Daten anmelden
      await _lokalAbmelden(serverAbgemeldet: false);
      throw StateError('Lokale Daten konnten nicht entfernt werden');
    }
    if (!_aktuell(gen)) return;
    state = AuthState(status: AuthStatus.angemeldet, user: user);
    if (!_client.istWeb) await ref.read(tokenStoreProvider).writeProfile(user.toJson());
    unawaited(neuLaden());
  }

  /// Nach erfolgreicher Registrierung (und bestätigten Wiederherstellungscodes): Sitzung übernehmen bzw. auf Freigabe warten.
  Future<void> registrierungAbschliessen(RegistrationResult r) async {
    if (r.status == MemberStatus.pending || r.session == null) {
      state = AuthState(status: AuthStatus.wartend, user: r.member);
      return;
    }
    await _client.sitzungUebernehmen(r.session!);
    await _angemeldet(r.member);
  }

  /// Zurück zur Anmeldung (z. B. vom Warte-Bildschirm).
  void zurAnmeldung() {
    _gen++;
    state = const AuthState(status: AuthStatus.abgemeldet);
  }

  // ------------------------------------------------------------ Abmelden

  /// Meldet dieses Gerät (oder alle Geräte) ab, löscht Token und lokale Daten.
  ///
  /// Android: Ist der Server nicht erreichbar (offline, Störung), wird trotzdem lokal abgemeldet; der Aufrufer informiert die Person
  /// (`serverAbgemeldet == false`: die Sitzung bleibt auf dem Server bis zum Ablauf gültig).
  /// Web: Bei einem Serverfehler wird NICHT abgemeldet, sondern der Fehler geworfen (die Sitzung gilt weiter; ein Cookie lässt sich
  /// nur über den Server löschen). Die Oberfläche bietet dann "Erneut versuchen" und "Trotzdem lokal abmelden" ([nurLokal]).
  /// Der Zustand geht in jedem Fall, in dem nicht geworfen wird, auf abgemeldet, auch wenn das Löschen der Daten scheitert.
  Future<AbmeldeErgebnis> abmelden({bool ueberall = false, bool nurLokal = false}) async {
    var serverOk = false;
    if (!nurLokal) {
      // Push zuerst abmelden, solange die Sitzung noch gilt (danach würde der Server das DELETE ablehnen); Fehler sind hier egal,
      // der Server löscht den Endpunkt beim Abmelden ohnehin
      try {
        await ref.read(pushAbmeldenProvider)(serverLoeschen: true);
      } catch (_) {}
      try {
        if (ueberall) {
          await _api.ueberallAbmelden();
        } else {
          await _api.abmelden();
        }
        serverOk = true;
      } on ApiException catch (e) {
        if (e.kind == ApiErrorKind.nichtAngemeldet) {
          serverOk = true; // die Sitzung war auf dem Server schon beendet
        } else if (_client.istWeb) {
          rethrow;
        }
        // Android: offline oder Serverstörung wird toleriert
      }
    }
    return _lokalAbmelden(serverAbgemeldet: serverOk);
  }

  /// Wird nach dem Entfernen des eigenen Geräts in der Geräteliste aufgerufen (der Server hat die Sitzung bereits beendet).
  Future<AbmeldeErgebnis> dieseSitzungBeendet() => _lokalAbmelden(serverAbgemeldet: true);

  Future<AbmeldeErgebnis> _lokalAbmelden({required bool serverAbgemeldet}) async {
    _gen++;
    var sauber = true;
    try {
      try {
        await ref.read(pushAbmeldenProvider)(serverLoeschen: false);
      } catch (_) {}
      try {
        await _client.sitzungVerwerfen();
      } catch (_) {
        sauber = false;
      }
      try {
        await ref.read(localDataWiperProvider)();
      } catch (_) {
        sauber = false;
      }
    } finally {
      if (ref.mounted) state = const AuthState(status: AuthStatus.abgemeldet);
    }
    return AbmeldeErgebnis(serverAbgemeldet: serverAbgemeldet, lokalSauber: sauber);
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);
