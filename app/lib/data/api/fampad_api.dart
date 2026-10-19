// Endpunkte der Server-Schnittstelle (docs/API.md) als typisierte Methoden. Kein Zustand, keine UI.
import '../../constants.dart';
import 'api_client.dart';
import 'api_error.dart';
import '../sync/sync_models.dart';
import 'models.dart';

class FampadApi {
  final ApiClient client;

  /// Liefert die Gerätedaten für Anmeldung/Registrierung (nur App; im Web legt der Server den Namen aus dem User-Agent an).
  final Future<DeviceInfo?> Function() geraet;

  FampadApi(this.client, {required this.geraet});

  /// `client` und `device` für Anmelde- und Registrierungsaufrufe.
  Future<Json> _clientFelder() async {
    if (client.istWeb) return {'client': 'web'};
    final d = await geraet();
    return {'client': 'app', 'device': ?d?.toJson()};
  }

  // ----------------------------------------------------------- Einladung (ohne Anmeldung)

  /// Das Token geht nur im POST-Body an den Server (nie in der URL).
  Future<InviteLookup> einladungPruefen(String token) async =>
      InviteLookup.fromJson((await client.post('/auth/invites/lookup', {'token': token}, false))['invite']);

  Future<ChallengeDto> passkeyRegistrierungStart({required String token, String? pin, String? email, String? anzeigename}) async =>
      ChallengeDto.fromJson(
        await client.post('/auth/invites/passkey/options', {
          'token': token,
          if (pin != null && pin.isNotEmpty) 'pin': pin,
          'email': ?email,
          'displayName': ?anzeigename,
        }, false),
      );

  Future<RegistrationResult> passkeyRegistrierungFertig({required String challengeId, required Json antwort, String? bezeichnung}) async =>
      RegistrationResult.fromJson(
        await client.post('/auth/invites/passkey/complete', {
          'challengeId': challengeId,
          'response': antwort,
          ...await _clientFelder(),
          'label': ?bezeichnung,
        }, false),
      );

  Future<PasswordStart> passwortRegistrierungStart({
    required String token,
    required String passwort,
    String? pin,
    String? email,
    String? anzeigename,
  }) async => PasswordStart.fromJson(
    await client.post('/auth/invites/password/start', {
      'token': token,
      'password': passwort,
      if (pin != null && pin.isNotEmpty) 'pin': pin,
      'email': ?email,
      'displayName': ?anzeigename,
    }, false),
  );

  Future<RegistrationResult> passwortRegistrierungFertig({required String challengeId, required String code}) async =>
      RegistrationResult.fromJson(
        await client.post('/auth/invites/password/complete', {'challengeId': challengeId, 'code': code, ...await _clientFelder()}, false),
      );

  // ----------------------------------------------------------- Anmeldung

  Future<ChallengeDto> passkeyAnmeldeOptionen() async => ChallengeDto.fromJson(await client.post('/auth/login/passkey/options', const {}, false));

  Future<LoginResult> passkeyAnmelden({required String challengeId, required Json antwort}) async => LoginResult.fromJson(
    await client.post('/auth/login/passkey/verify', {'challengeId': challengeId, 'response': antwort, ...await _clientFelder()}, false),
  );

  /// Passwort nur mit zweitem Faktor: entweder [totp] oder [wiederherstellungscode].
  Future<LoginResult> passwortAnmelden({
    required String email,
    required String passwort,
    String? totp,
    String? wiederherstellungscode,
  }) async => LoginResult.fromJson(
    await client.post('/auth/login/password', {
      'email': email,
      'password': passwort,
      'totp': ?totp,
      'recoveryCode': ?wiederherstellungscode,
      ...await _clientFelder(),
    }, false),
  );

  Future<LoginResult> wiederherstellungAnmelden({required String email, required String code}) async => LoginResult.fromJson(
    await client.post('/auth/login/recovery', {'email': email, 'code': code, ...await _clientFelder()}, false),
  );

  Future<void> abmelden() async {
    await client.post('/auth/logout', const {}, true);
  }

  Future<void> ueberallAbmelden() async {
    await client.post('/auth/logout-all', const {});
  }

  // ----------------------------------------------------------- Step-up

  Future<ChallengeDto> stepUpPasskeyOptionen() async => ChallengeDto.fromJson(await client.post('/auth/step-up/passkey/options', const {}));

  Future<void> stepUpPasskey({required String challengeId, required Json antwort}) async {
    await client.post('/auth/step-up/passkey/verify', {'challengeId': challengeId, 'response': antwort});
  }

  Future<void> stepUpCode({String? totp, String? wiederherstellungscode}) async {
    await client.post('/auth/step-up/code', {'totp': ?totp, 'recoveryCode': ?wiederherstellungscode});
  }

  // ----------------------------------------------------------- Konto

  Future<MeDto> ich() async {
    final me = MeDto.fromJson(await client.get('/me'));
    if (client.istWeb) client.csrfSetzen(me.csrfToken);
    return me;
  }

  Future<void> profilAendern({String? anzeigename, int? farbe}) async {
    await client.patch('/me', {'displayName': ?anzeigename, 'colorIndex': ?farbe});
  }

  Future<List<CredentialDto>> zugaenge() async =>
      parseListe((await client.get('/me/credentials'))['credentials'], CredentialDto.fromJson);

  Future<ChallengeDto> passkeyHinzufuegenOptionen() async => ChallengeDto.fromJson(await client.post('/me/passkeys/options', const {}));

  Future<String> passkeyHinzufuegen({required String challengeId, required Json antwort, String? bezeichnung}) async {
    final r = await client.post('/me/passkeys/verify', {'challengeId': challengeId, 'response': antwort, 'label': ?bezeichnung});
    final id = r['id'];
    return id is String ? id : '';
  }

  Future<void> passkeyEntfernen(String id) async {
    await client.delete('/me/passkeys/$id');
  }

  Future<List<String>> neueWiederherstellungscodes() async {
    final r = await client.post('/me/recovery-codes', const {});
    final codes = r['recoveryCodes'];
    if (codes is! List) throw ApiException.unerwarteteAntwort;
    return [for (final c in codes) c is String ? c : throw ApiException.unerwarteteAntwort];
  }

  Future<List<DeviceDto>> geraete() async => parseListe((await client.get('/devices'))['devices'], DeviceDto.fromJson);

  Future<void> geraetAbmelden(String id) async {
    await client.delete('/devices/$id');
  }

  // ----------------------------------------------------------- Sync

  /// Ops hochladen und Änderungen seit [sinceRev] abholen (docs/API.md, POST /sync). Antwort immer 200; Fehler sind [ApiException]
  /// (426: Update nötig, 409 device_mismatch, 429/503: später wieder). [snapshotRev]: Ziel-Revision eines laufenden mehrseitigen Snapshots.
  Future<SyncResult> sync({required String deviceId, required int sinceRev, required List<SyncOp> ops, int? limit, int? snapshotRev}) async => SyncResult.fromJson(
    await client.post('/sync', {
      'protocolVersion': kProtocolVersion,
      'deviceId': deviceId,
      'sinceRev': sinceRev,
      'limit': ?limit,
      'snapshotRev': ?snapshotRev,
      'ops': [for (final o in ops) o.toJson()],
    }),
  );

  /// Einmal-Ticket für den WebSocket.
  Future<String> wsTicket() async {
    final t = (await client.post('/ws-ticket', const {}))['ticket'];
    return t is String ? t : throw ApiException.unerwarteteAntwort;
  }

  // ----------------------------------------------------------- Mitglieder

  Future<List<UserDto>> mitglieder() async => parseListe((await client.get('/members'))['members'], UserDto.fromJson);

  Future<void> rolleAendern(String id, Role rolle) async {
    await client.patch('/members/$id/role', {'role': rolle.wire});
  }

  Future<void> freigeben(String id) async {
    await client.post('/members/$id/approve', const {});
  }

  Future<void> ablehnen(String id) async {
    await client.post('/members/$id/reject', const {});
  }

  Future<void> mitgliedEntfernen(String id) async {
    await client.delete('/members/$id');
  }

  Future<CreatedInvite> mitgliedZuruecksetzen(String id, {required int stunden, required bool pin}) async =>
      CreatedInvite.fromJson((await client.post('/members/$id/reset', {'hours': stunden, 'pin': pin}))['invite']);

  // ----------------------------------------------------------- Einladungen

  /// Der Server antwortet mit `{ invites: [...] }` (docs/API.md nennt nur die Liste).
  Future<List<InviteDto>> einladungen() async {
    final r = await client.get('/invites');
    return parseListe(r['invites'], InviteDto.fromJson);
  }

  Future<CreatedInvite> einladungErstellen({required Role rolle, required int stunden, required bool pin, bool? freigabe}) async =>
      CreatedInvite.fromJson(
        (await client.post('/invites', {'role': rolle.wire, 'hours': stunden, 'pin': pin, 'requireApproval': ?freigabe}))['invite'],
      );

  Future<void> einladungWiderrufen(String id) async {
    await client.post('/invites/$id/revoke', const {});
  }

  Future<DateTime> einladungVerlaengern(String id, int stunden) async {
    final r = await client.post('/invites/$id/extend', {'hours': stunden});
    final t = r['expiresAt'];
    return t is String ? (DateTime.tryParse(t) ?? DateTime.now()) : DateTime.now();
  }
}
