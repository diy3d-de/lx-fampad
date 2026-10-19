// Ablage der App-Anmeldung (Android): Access- und Refresh-Token in flutter_secure_storage (Android Keystore).
// Im Web wird NICHTS gespeichert: dort trägt der HttpOnly-Cookie die Sitzung.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredTokens {
  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;
  final DateTime refreshExpiresAt;
  final String deviceId;
  const StoredTokens({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
    required this.deviceId,
  });

  Map<String, dynamic> toJson() => {
    'a': accessToken,
    'ae': accessExpiresAt.toUtc().toIso8601String(),
    'r': refreshToken,
    're': refreshExpiresAt.toUtc().toIso8601String(),
    'd': deviceId,
  };

  static StoredTokens? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final a = raw['a'], ae = raw['ae'], r = raw['r'], re = raw['re'], d = raw['d'];
    if (a is! String || r is! String || d is! String || ae is! String || re is! String) return null;
    final aeT = DateTime.tryParse(ae), reT = DateTime.tryParse(re);
    if (aeT == null || reT == null) return null;
    return StoredTokens(accessToken: a, accessExpiresAt: aeT, refreshToken: r, refreshExpiresAt: reT, deviceId: d);
  }
}

abstract class TokenStore {
  Future<StoredTokens?> readTokens();
  Future<void> writeTokens(StoredTokens tokens);

  /// Löscht die Token (die Geräte-ID bleibt als Hinweis für die nächste Anmeldung erhalten).
  Future<void> clearTokens();

  /// Geräte-ID der letzten Anmeldung (wird bei der nächsten mitgesendet, damit der Server das Gerät wiedererkennt).
  Future<String?> readDeviceId();

  /// Profil der letzten Sitzung für den Offline-Start (Name, E-Mail, Rolle, Farbe; liegt im Keystore, wird beim Abmelden gelöscht).
  Future<Map<String, dynamic>?> readProfile();
  Future<void> writeProfile(Map<String, dynamic> profile);
}

/// Für Tests und das Web (dort bleibt alles im Arbeitsspeicher des Tabs).
class MemoryTokenStore implements TokenStore {
  StoredTokens? _tokens;
  String? _deviceId;
  Map<String, dynamic>? _profile;

  @override
  Future<StoredTokens?> readTokens() async => _tokens;

  @override
  Future<void> writeTokens(StoredTokens tokens) async {
    _tokens = tokens;
    _deviceId = tokens.deviceId;
  }

  @override
  Future<void> clearTokens() async {
    _tokens = null;
    _profile = null;
  }

  @override
  Future<String?> readDeviceId() async => _deviceId;

  @override
  Future<Map<String, dynamic>?> readProfile() async => _profile;

  @override
  Future<void> writeProfile(Map<String, dynamic> profile) async => _profile = profile;
}

/// Android Keystore über flutter_secure_storage. Das Lesen fängt ALLE Fehler ab (PlatformException, BadPaddingException nach
/// Keystore-Verlust oder Backup-Wiederherstellung, kaputtes JSON ...): der unlesbare Eintrag wird gelöscht und die Person gilt als
/// nicht angemeldet (null), statt dass die App beim Start hängt oder abstürzt.
class SecureTokenStore implements TokenStore {
  static const _kTokens = 'lx_fampad_tokens';
  static const _kDevice = 'lx_fampad_device_id';
  static const _kProfile = 'lx_fampad_profile';

  final FlutterSecureStorage _s;
  SecureTokenStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  /// Liest und decodiert einen Eintrag; bei jedem Fehler wird er gelöscht und null geliefert.
  Future<T?> _lesen<T>(String key, T? Function(Object? json) lesen) async {
    try {
      final raw = await _s.read(key: key);
      if (raw == null) return null;
      final wert = lesen(jsonDecode(raw));
      if (wert != null) return wert;
    } catch (_) {
      // unlesbar (Keystore-Schlüssel weg, beschädigte Daten ...): wie nicht vorhanden behandeln
    }
    try {
      await _s.delete(key: key);
    } catch (_) {
      // auch Löschen kann scheitern; der nächste Start versucht es erneut
    }
    return null;
  }

  @override
  Future<StoredTokens?> readTokens() => _lesen(_kTokens, StoredTokens.fromJson);

  @override
  Future<void> writeTokens(StoredTokens tokens) async {
    await _s.write(key: _kTokens, value: jsonEncode(tokens.toJson()));
    await _s.write(key: _kDevice, value: tokens.deviceId);
  }

  @override
  Future<void> clearTokens() async {
    // beide Einträge versuchen, auch wenn der erste Fehler wirft; der erste Fehler geht danach weiter
    Object? erster;
    for (final key in [_kTokens, _kProfile]) {
      try {
        await _s.delete(key: key);
      } catch (e) {
        erster ??= e;
      }
    }
    if (erster != null) throw erster;
  }

  @override
  Future<String?> readDeviceId() async {
    try {
      return await _s.read(key: _kDevice);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> readProfile() => _lesen(_kProfile, (v) => v is Map<String, dynamic> ? v : null);

  @override
  Future<void> writeProfile(Map<String, dynamic> profile) => _s.write(key: _kProfile, value: jsonEncode(profile));
}
