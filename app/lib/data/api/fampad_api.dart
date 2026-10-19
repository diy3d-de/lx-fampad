// Endpunkte der Server-Schnittstelle (docs/API.md) als typisierte Methoden. Kein Zustand, keine UI.
import 'dart:typed_data';

import '../../constants.dart';
import 'api_client.dart';
import 'api_error.dart';
import '../sync/sync_models.dart';
import '../crypto/schluessel.dart';
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

  /// Passwort + TOTP nachträglich einrichten: Schritt 1 (Passwort prüfen, Schlüssel erzeugen), Schritt 2 (Code bestätigen). Beide mit Step-up.
  Future<PasswordStart> passwortEinrichtenStart(String passwort) async =>
      PasswordStart.fromJson(await client.post('/me/password/start', {'password': passwort}));

  Future<void> passwortEinrichtenFertig({required String challengeId, required String code}) async {
    await client.post('/me/password/complete', {'challengeId': challengeId, 'code': code});
  }

  Future<void> passwortAendern(String passwort) async {
    await client.post('/me/password/change', {'password': passwort});
  }

  Future<void> passwortEntfernen() async {
    await client.delete('/me/password');
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

  // ----------------------------------------------------------- Push (nur Android)

  Future<PushStatusDto> pushStatus() async => PushStatusDto.fromJson(await client.get('/me/push'));

  /// Meldet den UnifiedPush-Endpunkt dieses Geräts an (ersetzt einen früheren). Der Server prüft Host und Pfad streng.
  Future<void> pushAnmelden(String endpunkt) async {
    await client.put('/me/push', {'endpoint': endpunkt});
  }

  Future<void> pushLoeschen() async {
    await client.delete('/me/push');
  }

  /// Der Server schickt einen Wecker (ohne Inhalt) an dieses Gerät.
  Future<void> pushTest() async {
    await client.post('/me/push/test');
  }

  // ----------------------------------------------------------- E2EE-Schlüssel (docs/API.md, Abschnitt E2EE)

  Future<EigeneSchluesselDto> eigeneSchluessel() async => EigeneSchluesselDto.fromJson(await client.get('/me/keys'));

  Future<OeffentlicheSchluessel> schluesselAnlegen({required String enc, required String sign}) async =>
      schluesselAusAntwort(await client.post('/me/keys', {'publicEncKey': enc, 'publicSignKey': sign}));

  /// Schlüsselwechsel (Step-up): ersetzt das öffentliche Paar, die Schlüsselversion steigt, Sicherung und Übertragung entfallen.
  /// [erwarteteVersion] ist die dem Client bekannte Version (409, wenn ein anderes Gerät schneller war).
  Future<OeffentlicheSchluessel> schluesselWechseln({required String enc, required String sign, required int erwarteteVersion}) async =>
      schluesselAusAntwort(await client.put('/me/keys', {'publicEncKey': enc, 'publicSignKey': sign, 'expectedKeyVersion': erwarteteVersion}));

  /// Öffentlicher Schlüssel eines Familienmitglieds in einer bestimmten Version (Historie des Servers; für alte Signaturen).
  Future<OeffentlicheSchluessel> mitgliedSchluessel(String userId, int version) async {
    final r = await client.get('/members/$userId/keys?version=$version');
    final keys = r['keys'];
    if (keys is! List || keys.length != 1) throw ApiException.unerwarteteAntwort;
    return schluesselAusAntwort({'keys': keys.first});
  }

  Future<void> sicherungAblegen({required String blob, required int keyVersion}) async {
    await client.put('/me/key-backup', {'blob': blob, 'keyVersion': keyVersion});
  }

  Future<BlobDto> sicherungAbrufen() async => BlobDto.fromJson(await client.get('/me/key-backup'));

  /// Gibt die Ablaufzeit zurück (2 Minuten).
  Future<DateTime> uebertragungAnlegen({required String suchkennung, required String blob, required int keyVersion}) async {
    final r = await client.post('/me/key-transfer', {'lookup': suchkennung, 'blob': blob, 'keyVersion': keyVersion});
    final t = r['expiresAt'];
    return t is String ? (DateTime.tryParse(t) ?? DateTime.now()) : DateTime.now();
  }

  Future<BlobDto> uebertragungEinloesen(String suchkennung) async => BlobDto.fromJson(await client.post('/me/key-transfer/claim', {'lookup': suchkennung}));

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

  // ----------------------------------------------------------- Benutzerbild

  /// Wählt einen Platzhalter (Kennung wie 'V01'); Antwort: das neue Bild.
  Future<AvatarDto?> avatarVorlageSetzen(String id) async =>
      AvatarDto.tolerant((await client.put('/me/avatar', {'preset': id}))['avatar']);

  /// Lädt das (schon verkleinerte) Foto hoch; [mime] ist image/png, image/jpeg oder image/webp.
  Future<AvatarDto?> avatarFotoHochladen(Uint8List bytes, String mime) async =>
      AvatarDto.tolerant((await client.putBytes('/me/avatar', bytes, mime))['avatar']);

  Future<void> avatarEntfernen() async {
    await client.delete('/me/avatar');
  }

  /// Admin: setzt das Bild eines Mitglieds zurück.
  Future<void> avatarMitgliedZuruecksetzen(String id) async {
    await client.delete('/members/$id/avatar');
  }

  /// Foto eines Mitglieds (Bytes); 404, wenn es keines gibt.
  Future<Uint8List> avatarFoto(String id) async {
    final r = await client.getBytes('/members/$id/avatar');
    return r.bytes ?? (throw ApiException.unerwarteteAntwort);
  }

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
