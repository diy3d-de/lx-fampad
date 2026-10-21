// Datenmodelle der Server-Schnittstelle (docs/API.md). Parsing ist streng bei Pflichtfeldern und tolerant bei
// zusätzlichen Feldern; Abweichungen werden zu ApiException.unerwarteteAntwort (keine Interna im UI).
import '../crypto/schluessel.dart';
import 'api_error.dart';

typedef Json = Map<String, dynamic>;

Never _fehler() => throw ApiException.unerwarteteAntwort;

Json asJson(Object? v) => v is Map<String, dynamic> ? v : _fehler();

List<Json> asJsonList(Object? v) {
  if (v is! List) _fehler();
  return [for (final e in v) asJson(e)];
}

/// Liest eine Liste Eintrag für Eintrag: Ein Eintrag, den die App nicht versteht (z. B. unbekannte Rolle oder unbekannter Status
/// einer neueren Server-Version), wird übersprungen, statt die ganze Liste zu verwerfen. Ist die Antwort keine Liste, bleibt es ein Fehler.
List<T> parseListe<T>(Object? v, T Function(Object? raw) eintrag) {
  if (v is! List) _fehler();
  final out = <T>[];
  for (final e in v) {
    try {
      out.add(eintrag(e));
    } on ApiException {
      // unbekannter oder fehlerhafter Eintrag: überspringen
    }
  }
  return out;
}

String _s(Json m, String k) {
  final v = m[k];
  return v is String ? v : _fehler();
}

String? _sn(Json m, String k) {
  final v = m[k];
  if (v == null) return null;
  return v is String ? v : _fehler();
}

int _i(Json m, String k) {
  final v = m[k];
  return v is int ? v : _fehler();
}

bool _b(Json m, String k) {
  final v = m[k];
  return v is bool ? v : _fehler();
}

DateTime _t(Json m, String k) => DateTime.tryParse(_s(m, k)) ?? _fehler();

DateTime? _tn(Json m, String k) {
  final v = _sn(m, k);
  return v == null ? null : (DateTime.tryParse(v) ?? _fehler());
}

enum Role {
  admin('admin', 'Admin', 3),
  parent('parent', 'Elternteil', 2),
  child('child', 'Kind', 1);

  final String wire;
  final String label;

  /// Rang wie auf dem Server (ROLE_RANK): höher = mehr Rechte.
  final int rang;
  const Role(this.wire, this.label, this.rang);

  /// Die frühere Rolle "guest" (Server vor Migration 0005) gilt als Kind: die geringsten Rechte. Andere unbekannte Werte lassen die
  /// Zeile einer Liste aus (siehe parseListe) und lösen sonst einen Antwortfehler aus, nie einen Absturz.
  static Role parse(String s) => s == 'guest' ? Role.child : Role.values.firstWhere((r) => r.wire == s, orElse: () => _fehler());

  /// Rollen, die diese Rolle einladen darf (Admin: alle, Eltern: nur Kinder).
  List<Role> get darfEinladen => switch (this) {
    Role.admin => Role.values,
    Role.parent => const [Role.child],
    _ => const [],
  };
}

/// Familienrolle: reine Anzeige (z. B. "Elternteil" neben "Admin"), ändert keine Rechte. Unbekannte Werte einer neueren Version werden
/// zu null (nicht angezeigt), nie zu einem Fehler.
enum FamilyRole {
  vater('vater', 'Vater'),
  mutter('mutter', 'Mutter'),
  elternteil('elternteil', 'Elternteil'),
  kind('kind', 'Kind'),
  grosseltern('grosseltern', 'Großeltern'),
  sonstige('sonstige', 'Sonstige');

  final String wire;
  final String label;
  const FamilyRole(this.wire, this.label);

  static FamilyRole? tolerant(Object? raw) {
    for (final r in FamilyRole.values) {
      if (r.wire == raw) return r;
    }
    return null;
  }
}

enum MemberStatus {
  active,
  pending;

  static MemberStatus parse(String s) => switch (s) {
    'active' => MemberStatus.active,
    'pending' => MemberStatus.pending,
    _ => _fehler(),
  };
}

/// Benutzerbild einer Person (Teil von /me und /members): Platzhalter ([vorlage] gesetzt) oder Foto. [version] zählt jede Änderung.
/// Alte Server liefern nichts (null); unbekannte Arten einer neueren Version werden zu null (Initialen), nie zu einem Fehler.
class AvatarDto {
  final bool istFoto;
  final String? vorlage;
  final int version;
  const AvatarDto.vorlage(String id, this.version) : istFoto = false, vorlage = id;
  const AvatarDto.foto(this.version) : istFoto = true, vorlage = null;

  static AvatarDto? tolerant(Object? raw) {
    if (raw is! Map) return null;
    final art = raw['kind'];
    final v = raw['version'];
    final version = v is int ? v : 0;
    if (art == 'photo') return AvatarDto.foto(version);
    final id = raw['id'];
    if (art == 'preset' && id is String && id.isNotEmpty) return AvatarDto.vorlage(id, version);
    return null;
  }

  Json toJson() => istFoto ? {'kind': 'photo', 'version': version} : {'kind': 'preset', 'id': vorlage, 'version': version};

  @override
  bool operator ==(Object other) => other is AvatarDto && other.istFoto == istFoto && other.vorlage == vorlage && other.version == version;

  @override
  int get hashCode => Object.hash(istFoto, vorlage, version);
}

/// Person (Antwort von Anmeldung, /me und der Mitgliederliste; `email` fehlt in der Liste für Nicht-Admins).
class UserDto {
  final String id;
  final String? email;
  final String displayName;
  final int colorIndex;
  final Role role;
  final MemberStatus status;

  /// Benutzerbild (null = keines: Initialen).
  final AvatarDto? avatar;

  /// Öffentliche Verschlüsselungsschlüssel (null, solange die Person keine eingerichtet hat oder der Server keine liefert).
  final OeffentlicheSchluessel? schluessel;

  /// Familienrolle (reine Anzeige; null = nicht gesetzt, auch bei alten Servern).
  final FamilyRole? familyRole;
  const UserDto({
    required this.id,
    required this.email,
    required this.displayName,
    required this.colorIndex,
    required this.role,
    required this.status,
    this.avatar,
    this.schluessel,
    this.familyRole,
  });

  factory UserDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return UserDto(
      id: _s(m, 'id'),
      email: _sn(m, 'email'),
      displayName: _s(m, 'displayName'),
      colorIndex: _i(m, 'colorIndex'),
      role: Role.parse(_s(m, 'role')),
      status: MemberStatus.parse(_s(m, 'status')),
      avatar: AvatarDto.tolerant(m['avatar']),
      schluessel: _schluessel(m),
      familyRole: FamilyRole.tolerant(m['familyRole']),
    );
  }

  Json toJson() => {
    'id': id,
    'email': email,
    'displayName': displayName,
    'colorIndex': colorIndex,
    'role': role.wire,
    'status': status.name,
    if (avatar != null) 'avatar': avatar!.toJson(),
    if (familyRole != null) 'familyRole': familyRole!.wire,
  };
}

/// Sitzung aus den Antworten der Anmeldung (`session`): Web (Cookie + CSRF) oder App (Token).
class SessionDto {
  final bool istApp;
  final String? csrfToken;
  final String? accessToken;
  final DateTime? accessExpiresAt;
  final String? refreshToken;
  final DateTime? refreshExpiresAt;
  final DateTime? expiresAt;
  final String deviceId;
  const SessionDto({
    required this.istApp,
    this.csrfToken,
    this.accessToken,
    this.accessExpiresAt,
    this.refreshToken,
    this.refreshExpiresAt,
    this.expiresAt,
    required this.deviceId,
  });

  factory SessionDto.fromJson(Object? raw) {
    final m = asJson(raw);
    final kind = _s(m, 'kind');
    if (kind == 'web') {
      return SessionDto(istApp: false, csrfToken: _s(m, 'csrfToken'), expiresAt: _t(m, 'expiresAt'), deviceId: _s(m, 'deviceId'));
    }
    if (kind == 'app') {
      return SessionDto(
        istApp: true,
        accessToken: _s(m, 'accessToken'),
        accessExpiresAt: _t(m, 'accessExpiresAt'),
        refreshToken: _s(m, 'refreshToken'),
        refreshExpiresAt: _t(m, 'refreshExpiresAt'),
        deviceId: _s(m, 'deviceId'),
      );
    }
    _fehler();
  }
}

/// Antwort von Passkey-/Passwort-/Wiederherstellungs-Anmeldung.
class LoginResult {
  final UserDto user;
  final SessionDto session;

  /// Nur bei der Anmeldung per Wiederherstellungscode.
  final int? recoveryCodesRemaining;
  const LoginResult({required this.user, required this.session, this.recoveryCodesRemaining});

  factory LoginResult.fromJson(Object? raw) {
    final m = asJson(raw);
    final rest = m['recoveryCodesRemaining'];
    return LoginResult(
      user: UserDto.fromJson(m['user']),
      session: SessionDto.fromJson(m['session']),
      recoveryCodesRemaining: rest is int ? rest : null,
    );
  }
}

/// `GET /me`
class MeDto {
  final UserDto user;
  final String familyId;
  final String? sessionDeviceId;
  final DateTime? stepUpAt;
  final String? csrfToken;
  final int passkeys;
  final bool hasPassword;
  final bool hasTotp;
  final int recoveryCodesRemaining;

  /// Betreiber des Servers (Konto-Flag, nur Anzeige: zeigt den Bereich "Betrieb"; die Routen prüft der Server selbst). Ältere Server: false.
  final bool betreiber;
  const MeDto({
    required this.user,
    required this.familyId,
    required this.sessionDeviceId,
    required this.stepUpAt,
    required this.csrfToken,
    required this.passkeys,
    required this.hasPassword,
    required this.hasTotp,
    required this.recoveryCodesRemaining,
    this.betreiber = false,
  });

  factory MeDto.fromJson(Object? raw) {
    final m = asJson(raw);
    final session = asJson(m['session']);
    final creds = asJson(m['credentials']);
    final step = session['stepUpAt'];
    return MeDto(
      user: UserDto.fromJson(m['user']),
      familyId: _s(m, 'familyId'),
      sessionDeviceId: _sn(session, 'deviceId'),
      stepUpAt: step is String ? DateTime.tryParse(step) : null,
      csrfToken: _sn(m, 'csrfToken'),
      passkeys: _i(creds, 'passkeys'),
      hasPassword: _b(creds, 'password'),
      hasTotp: _b(creds, 'totp'),
      recoveryCodesRemaining: _i(m, 'recoveryCodesRemaining'),
      betreiber: m['operator'] == true,
    );
  }
}

class DeviceDto {
  final String id;
  final String name;
  final String platform;
  final String? appVersion;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final bool current;
  const DeviceDto({
    required this.id,
    required this.name,
    required this.platform,
    required this.appVersion,
    required this.createdAt,
    required this.lastSeenAt,
    required this.current,
  });

  factory DeviceDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return DeviceDto(
      id: _s(m, 'id'),
      name: _s(m, 'name'),
      platform: _s(m, 'platform'),
      appVersion: _sn(m, 'appVersion'),
      createdAt: _t(m, 'createdAt'),
      lastSeenAt: _tn(m, 'lastSeenAt'),
      current: _b(m, 'current'),
    );
  }
}

class CredentialDto {
  final String id;
  final String type;
  final String? label;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  const CredentialDto({required this.id, required this.type, required this.label, required this.createdAt, required this.lastUsedAt});

  bool get istPasskey => type == 'passkey';

  factory CredentialDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return CredentialDto(id: _s(m, 'id'), type: _s(m, 'type'), label: _sn(m, 'label'), createdAt: _t(m, 'createdAt'), lastUsedAt: _tn(m, 'lastUsedAt'));
  }
}

enum InviteStatus {
  open('offen'),
  used('benutzt'),
  revoked('widerrufen'),
  locked('gesperrt'),
  expired('abgelaufen');

  final String label;
  const InviteStatus(this.label);

  static InviteStatus parse(String s) => InviteStatus.values.firstWhere((e) => e.name == s, orElse: () => _fehler());
}

/// Eintrag der Einladungsliste (ohne Token und PIN).
class InviteDto {
  final String id;
  final Role role;
  final InviteStatus status;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool hasPin;
  final bool requireApproval;
  final bool reset;
  final String? createdBy;
  final String? usedBy;
  const InviteDto({
    required this.id,
    required this.role,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    required this.hasPin,
    required this.requireApproval,
    required this.reset,
    required this.createdBy,
    required this.usedBy,
  });

  factory InviteDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return InviteDto(
      id: _s(m, 'id'),
      role: Role.parse(_s(m, 'role')),
      status: InviteStatus.parse(_s(m, 'status')),
      createdAt: _t(m, 'createdAt'),
      expiresAt: _t(m, 'expiresAt'),
      hasPin: _b(m, 'hasPin'),
      requireApproval: _b(m, 'requireApproval'),
      reset: _b(m, 'reset'),
      createdBy: _sn(m, 'createdBy'),
      usedBy: _sn(m, 'usedBy'),
    );
  }
}

/// Frisch erzeugte Einladung: Token (im Link) und PIN erscheinen nur hier.
class CreatedInvite {
  final String id;
  final String token;
  final String link;
  final String? pin;
  final DateTime expiresAt;
  final bool requireApproval;
  const CreatedInvite({
    required this.id,
    required this.token,
    required this.link,
    required this.pin,
    required this.expiresAt,
    required this.requireApproval,
  });

  factory CreatedInvite.fromJson(Object? raw) {
    final m = asJson(raw);
    return CreatedInvite(
      id: _s(m, 'id'),
      token: _s(m, 'token'),
      link: _s(m, 'link'),
      pin: _sn(m, 'pin'),
      expiresAt: _t(m, 'expiresAt'),
      requireApproval: _b(m, 'requireApproval'),
    );
  }
}

/// `POST /auth/invites/lookup`
class InviteLookup {
  final Role role;
  final bool pinRequired;
  final bool requireApproval;
  final String familyName;
  final bool reset;
  final String? displayName;

  /// Nur bei einer Reset-Einladung (und Server mit authKey): E-Mail des Kontos, nötig für den Salt der Passwort-Ableitung.
  final String? email;
  final DateTime expiresAt;
  const InviteLookup({
    required this.role,
    required this.pinRequired,
    required this.requireApproval,
    required this.familyName,
    required this.reset,
    required this.displayName,
    this.email,
    required this.expiresAt,
  });

  factory InviteLookup.fromJson(Object? raw) {
    final m = asJson(raw);
    return InviteLookup(
      role: Role.parse(_s(m, 'role')),
      pinRequired: _b(m, 'pinRequired'),
      requireApproval: _b(m, 'requireApproval'),
      familyName: _s(m, 'familyName'),
      reset: _b(m, 'reset'),
      displayName: _sn(m, 'displayName'),
      email: _sn(m, 'email'),
      expiresAt: _t(m, 'expiresAt'),
    );
  }
}

/// WebAuthn-Optionen mit Challenge-ID (Registrierung, Anmeldung, Step-up, neuer Passkey).
class ChallengeDto {
  final String challengeId;
  final Json options;
  const ChallengeDto({required this.challengeId, required this.options});

  factory ChallengeDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return ChallengeDto(challengeId: _s(m, 'challengeId'), options: asJson(m['options']));
  }
}

/// `POST /auth/invites/password/start`
class PasswordStart {
  final String challengeId;
  final String totpSecret;
  final String totpUri;
  const PasswordStart({required this.challengeId, required this.totpSecret, required this.totpUri});

  factory PasswordStart.fromJson(Object? raw) {
    final m = asJson(raw);
    return PasswordStart(challengeId: _s(m, 'challengeId'), totpSecret: _s(m, 'totpSecret'), totpUri: _s(m, 'totpUri'));
  }
}

/// Ergebnis der Registrierung (Passkey oder Passwort): Wiederherstellungscodes erscheinen nur hier.
class RegistrationResult {
  final UserDto member;
  final MemberStatus status;
  final List<String> recoveryCodes;
  final SessionDto? session;
  const RegistrationResult({required this.member, required this.status, required this.recoveryCodes, required this.session});

  factory RegistrationResult.fromJson(Object? raw) {
    final m = asJson(raw);
    final codes = m['recoveryCodes'];
    if (codes is! List) _fehler();
    final session = m['session'];
    return RegistrationResult(
      member: UserDto.fromJson(m['member']),
      status: MemberStatus.parse(_s(m, 'status')),
      recoveryCodes: [for (final c in codes) c is String ? c : _fehler()],
      session: session == null ? null : SessionDto.fromJson(session),
    );
  }
}

/// Gerätedaten, die bei Anmeldung und Registrierung mitgesendet werden.
class DeviceInfo {
  final String? id;
  final String name;
  final String platform;
  final String? appVersion;
  const DeviceInfo({this.id, required this.name, required this.platform, this.appVersion});

  Json toJson() => {if (id != null) 'id': id, 'name': name, 'platform': platform, if (appVersion != null && appVersion!.isNotEmpty) 'appVersion': appVersion};
}

/// Push-Status dieses Geräts laut Server (GET /me/push).
class PushStatusDto {
  /// Der Server hat Push eingerichtet (NTFY_URL/NTFY_TOKEN).
  final bool available;
  final bool registered;
  final bool active;
  final DateTime? lastOkAt;
  const PushStatusDto({required this.available, required this.registered, required this.active, required this.lastOkAt});

  factory PushStatusDto.fromJson(Object? raw) {
    final m = asJson(raw);
    final ok = m['lastOkAt'];
    return PushStatusDto(
      available: m['available'] == true,
      registered: m['registered'] == true,
      active: m['active'] == true,
      lastOkAt: ok is String ? DateTime.tryParse(ok) : null,
    );
  }
}

/// Öffentliche Schlüssel aus den Feldern publicEncKey/publicSignKey/keyVersion (alle drei oder keiner; ungültige Form zählt als "keine").
OeffentlicheSchluessel? _schluessel(Json m) {
  final enc = m['publicEncKey'], sign = m['publicSignKey'], v = m['keyVersion'];
  if (enc is! String || sign is! String || v is! int) return null;
  try {
    return OeffentlicheSchluessel.ausBase64(enc: enc, sign: sign, version: v);
  } on Object {
    return null;
  }
}

/// Antwort von GET /me/keys.
class EigeneSchluesselDto {
  final OeffentlicheSchluessel? schluessel;
  final bool hatSicherung;
  const EigeneSchluesselDto({required this.schluessel, required this.hatSicherung});

  factory EigeneSchluesselDto.fromJson(Object? raw) {
    final m = asJson(raw);
    final k = m['keys'];
    return EigeneSchluesselDto(schluessel: k == null ? null : _schluesselStreng(asJson(k)), hatSicherung: _b(m, 'hasBackup'));
  }
}

OeffentlicheSchluessel _schluesselStreng(Json m) => _schluessel(m) ?? _fehler();

/// Antwort auf das Anlegen oder Wechseln des Schlüssels.
OeffentlicheSchluessel schluesselAusAntwort(Json r) => _schluesselStreng(asJson(r['keys']));

/// Fähigkeiten des Servers (GET /version, `features`). Fehlt ein Eintrag (älterer Server), gilt er als nicht vorhanden; [legacyPasswortLogin] ist
/// ohne Angabe an (der alte Server nimmt das Klartext-Passwort ohnehin an).
class ServerFaehigkeiten {
  final bool pwBackup;

  /// Anmeldung und Passwortwechsel mit abgeleitetem authKey (das Passwort verlässt das Gerät nie).
  final bool authKey;

  /// Der Server nimmt noch das Klartext-Passwort an (AUTH_LEGACY_PASSWORD_LOGIN).
  final bool legacyPasswortLogin;
  const ServerFaehigkeiten({required this.pwBackup, required this.authKey, required this.legacyPasswortLogin});

  static const keine = ServerFaehigkeiten(pwBackup: false, authKey: false, legacyPasswortLogin: true);

  factory ServerFaehigkeiten.fromJson(Map<String, dynamic> f) =>
      ServerFaehigkeiten(pwBackup: f['pwBackup'] == true, authKey: f['authKey'] == true, legacyPasswortLogin: f['legacyPasswordLogin'] != false);
}

/// Zustand der Passwort-Anmeldung je Mitglied (GET /members/password-modes, nur Admins). Nie ein Prüfwert, nur der Zustand.
enum PasswortModus { legacy, authkey, keins }

class PasswortModi {
  /// Der Server nimmt noch das Klartext-Passwort an.
  final bool legacyPasswortLogin;
  final Map<String, PasswortModus> modi;
  const PasswortModi({required this.legacyPasswortLogin, required this.modi});

  factory PasswortModi.fromJson(Object? raw) {
    final m = asJson(raw);
    final liste = m['modes'];
    final modi = <String, PasswortModus>{};
    if (liste is List) {
      for (final e in liste) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['userId'], modus = e['mode'];
        if (id is! String) continue;
        modi[id] = switch (modus) {
          'authkey' => PasswortModus.authkey,
          'legacy' => PasswortModus.legacy,
          _ => PasswortModus.keins,
        };
      }
    }
    return PasswortModi(legacyPasswortLogin: m['legacyPasswordLogin'] != false, modi: modi);
  }
}

/// Parameter der Passwort-Ableitung laut Server (POST /auth/kdf-params und in der Passwort-Sicherung). Der Salt ist öffentlich und kommt vom Server.
class KdfDto {
  final String id;
  final int memKiB;
  final int ops;
  final String salt;
  const KdfDto({required this.id, required this.memKiB, required this.ops, required this.salt});

  factory KdfDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return KdfDto(id: _s(m, 'id'), memKiB: _i(m, 'memKiB'), ops: _i(m, 'ops'), salt: _s(m, 'salt'));
  }
}

/// Antwort von GET /me/key-backup-pw. [stale]: der Personenschlüssel hat seither gewechselt (die Sicherung enthält den alten). [pending]: noch nicht bestätigt.
class PwSicherungDto {
  final String id;
  final String blob;
  final int keyVersion;
  final bool stale;
  final bool pending;
  final KdfDto kdf;
  const PwSicherungDto({required this.id, required this.blob, required this.keyVersion, required this.stale, this.pending = false, required this.kdf});

  factory PwSicherungDto.fromJson(Object? raw) {
    final m = asJson(raw);
    final state = _s(m, 'state');
    if (state != 'active' && state != 'stale' && state != 'pending') throw ApiException.unerwarteteAntwort;
    return PwSicherungDto(id: _s(m, 'id'), blob: _s(m, 'blob'), keyVersion: _i(m, 'keyVersion'), stale: state == 'stale', pending: state == 'pending', kdf: KdfDto.fromJson(m['kdf']));
  }
}

/// Blob samt Schlüsselversion (Sicherung abrufen, Übertragung einlösen).
class BlobDto {
  final String blob;
  final int keyVersion;
  const BlobDto({required this.blob, required this.keyVersion});
  factory BlobDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return BlobDto(blob: _s(m, 'blob'), keyVersion: _i(m, 'keyVersion'));
  }
}

/// Messwerte der Wetterstation (GET /weather, docs/API.md). Nur Ortsname und Zahlen, nie Straße, Koordinaten oder Station.
class WetterAktuell {
  final DateTime gemessen;

  /// Der Server hält die letzte Messung für veraltet (älter als eine Stunde).
  final bool veraltet;
  final double? temperatur;
  final double? feuchte;
  final double? druck;
  final double? regen1h;
  final double? regen24h;
  final double? windKmh;
  final double? boeKmh;
  final double? windRichtung;
  const WetterAktuell({
    required this.gemessen,
    required this.veraltet,
    this.temperatur,
    this.feuchte,
    this.druck,
    this.regen1h,
    this.regen24h,
    this.windKmh,
    this.boeKmh,
    this.windRichtung,
  });
}

class WetterPunkt {
  final DateTime zeit;
  final double temperatur;
  const WetterPunkt(this.zeit, this.temperatur);
}

class WetterDto {
  /// Der Server hat das Wetter eingeschaltet.
  final bool verfuegbar;
  final String ort;
  final WetterAktuell? aktuell;
  final double? min24h;
  final double? max24h;
  final List<WetterPunkt> verlauf;
  const WetterDto({required this.verfuegbar, this.ort = '', this.aktuell, this.min24h, this.max24h, this.verlauf = const []});

  static double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

  factory WetterDto.fromJson(Object? raw) {
    final m = asJson(raw);
    if (m['available'] != true) return const WetterDto(verfuegbar: false);
    final ort = _s(m, 'place');
    final c = m['current'];
    WetterAktuell? aktuell;
    if (c != null) {
      final cm = asJson(c);
      aktuell = WetterAktuell(
        gemessen: _t(cm, 'measuredAt'),
        veraltet: cm['stale'] == true,
        temperatur: _d(cm['temperature']),
        feuchte: _d(cm['humidity']),
        druck: _d(cm['pressure']),
        regen1h: _d(cm['rain1h']),
        regen24h: _d(cm['rain24h']),
        windKmh: _d(cm['windKmh']),
        boeKmh: _d(cm['gustKmh']),
        windRichtung: _d(cm['windAngle']),
      );
    }
    final reihe = m['series'];
    final verlauf = <WetterPunkt>[];
    if (reihe is List) {
      for (final p in reihe) {
        if (p is! Map<String, dynamic>) continue;
        final t = p['t'] is String ? DateTime.tryParse(p['t'] as String) : null;
        final v = _d(p['temperature']);
        if (t != null && v != null) verlauf.add(WetterPunkt(t, v));
      }
    }
    return WetterDto(verfuegbar: true, ort: ort, aktuell: aktuell, min24h: _d(m['min24h']), max24h: _d(m['max24h']), verlauf: verlauf);
  }
}
