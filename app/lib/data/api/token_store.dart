// Ablage der App-Anmeldung (Android): Access- und Refresh-Token in flutter_secure_storage (Android Keystore).
// Im Web wird NICHTS gespeichert: dort trägt der HttpOnly-Cookie die Sitzung.
import 'dart:convert';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/sicherer_speicher.dart';
import 'kleiner_speicher.dart';
import 'models.dart' show ServerFaehigkeiten;

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

/// Sperre "Erneuerung läuft" in der gemeinsamen Ablage: wer gerade das Refresh-Token einlöst ([besitzer], zufällig je Erneuerung), und bis wann
/// die Sperre höchstens gilt ([bis], danach darf jeder sie übernehmen). Kein Geheimnis.
class ErneuerungsSperre {
  final String besitzer;
  final DateTime bis;
  const ErneuerungsSperre(this.besitzer, this.bis);

  Map<String, dynamic> toJson() => {'o': besitzer, 'b': bis.toUtc().toIso8601String()};

  static ErneuerungsSperre? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final o = raw['o'], b = raw['b'];
    if (o is! String || b is! String) return null;
    final t = DateTime.tryParse(b);
    return t == null ? null : ErneuerungsSperre(o, t);
  }
}

abstract class TokenStore {
  Future<StoredTokens?> readTokens();
  Future<void> writeTokens(StoredTokens tokens);

  /// Löscht die Token (die Geräte-ID bleibt als Hinweis für die nächste Anmeldung erhalten).
  Future<void> clearTokens();

  /// Sperre gegen doppelte Erneuerung (Hintergrund-Engine und App teilen sich diese Ablage, aber keinen Arbeitsspeicher). Best-Effort ohne atomare
  /// Operation: der Aufrufer schreibt, wartet kurz und liest zurück (siehe `ApiClient._erneuernEinmal`). Lesefehler = keine Sperre.
  Future<ErneuerungsSperre?> readErneuerungsSperre();
  Future<void> writeErneuerungsSperre(ErneuerungsSperre sperre);

  /// Löscht die Sperre nur, wenn sie noch [besitzer] gehört (nie die einer anderen Erneuerung).
  Future<void> clearErneuerungsSperre(String besitzer);

  /// Geräte-ID der letzten Anmeldung (wird bei der nächsten mitgesendet, damit der Server das Gerät wiedererkennt).
  Future<String?> readDeviceId();

  /// Profil der letzten Sitzung für den Offline-Start (Name, E-Mail, Rolle, Farbe; liegt im Keystore, wird beim Abmelden gelöscht).
  Future<Map<String, dynamic>?> readProfile();
  Future<void> writeProfile(Map<String, dynamic> profile);

  /// Konten (E-Mail in Kleinschreibung), mit denen sich diese App schon einmal per authKey angemeldet hat. Für sie sendet die App nie mehr das
  /// Klartext-Passwort, auch wenn ein Server das provoziert (Schutz vor Herabstufung). Bleibt beim Abmelden erhalten (gehört zum Gerät, nicht zur Sitzung).
  Future<bool> istAuthKeyKonto(String email);
  Future<void> merkeAuthKeyKonto(String email);

  /// Zuletzt erfolgreich gelesene Fähigkeiten des Servers (kein Geheimnis): Fällt GET /version einmal aus, bleibt die App beim bekannten Weg, statt auf
  /// Klartext zu wechseln. null = noch nie gelesen.
  Future<ServerFaehigkeiten?> readFaehigkeiten();
  Future<void> writeFaehigkeiten(ServerFaehigkeiten f);
}

String _faehigkeitenJson(ServerFaehigkeiten f) => jsonEncode({'p': f.pwBackup, 'a': f.authKey, 'l': f.legacyPasswortLogin});

ServerFaehigkeiten? _faehigkeitenLesen(Object? v) =>
    v is Map ? ServerFaehigkeiten(pwBackup: v['p'] == true, authKey: v['a'] == true, legacyPasswortLogin: v['l'] != false) : null;

String _kontoSchluessel(String email) => email.trim().toLowerCase();

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

  ErneuerungsSperre? _sperre;

  @override
  Future<ErneuerungsSperre?> readErneuerungsSperre() async => _sperre;

  @override
  Future<void> writeErneuerungsSperre(ErneuerungsSperre sperre) async => _sperre = sperre;

  @override
  Future<void> clearErneuerungsSperre(String besitzer) async {
    if (_sperre?.besitzer == besitzer) _sperre = null;
  }

  @override
  Future<String?> readDeviceId() async => _deviceId;

  @override
  Future<Map<String, dynamic>?> readProfile() async => _profile;

  @override
  Future<void> writeProfile(Map<String, dynamic> profile) async => _profile = profile;

  // Im Web bleiben die Vermerke zusätzlich im localStorage (kein Geheimnis: nur E-Mail in Kleinschreibung und die Fähigkeiten des Servers), damit der Schutz vor
  // Herabstufung einen Neustart des Tabs übersteht; in Tests und außerhalb des Browsers gilt nur der Arbeitsspeicher.
  static const _kKonten = 'lx_fampad_authkey_konten';
  static const _kCaps = 'lx_fampad_server_caps';
  final Set<String> _authKeyKonten = {};
  ServerFaehigkeiten? _caps;

  Set<String> _gespeicherteKonten() {
    final roh = kleinerSpeicherLesen(_kKonten);
    if (roh == null) return {};
    try {
      final v = jsonDecode(roh);
      return v is List ? {for (final e in v) if (e is String) e} : {};
    } catch (_) {
      return {};
    }
  }

  @override
  Future<bool> istAuthKeyKonto(String email) async {
    final k = _kontoSchluessel(email);
    return _authKeyKonten.contains(k) || _gespeicherteKonten().contains(k);
  }

  @override
  Future<void> merkeAuthKeyKonto(String email) async {
    final k = _kontoSchluessel(email);
    _authKeyKonten.add(k);
    final alle = {..._gespeicherteKonten(), k}.toList();
    kleinerSpeicherSchreiben(_kKonten, jsonEncode(alle.length > 20 ? alle.sublist(alle.length - 20) : alle));
  }

  @override
  Future<ServerFaehigkeiten?> readFaehigkeiten() async {
    if (_caps != null) return _caps;
    final roh = kleinerSpeicherLesen(_kCaps);
    if (roh == null) return null;
    try {
      return _faehigkeitenLesen(jsonDecode(roh));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeFaehigkeiten(ServerFaehigkeiten f) async {
    _caps = f;
    kleinerSpeicherSchreiben(_kCaps, _faehigkeitenJson(f));
  }
}

/// Android Keystore über flutter_secure_storage. Das Lesen fängt ALLE Fehler ab (PlatformException, BadPaddingException nach
/// Keystore-Verlust oder Backup-Wiederherstellung, kaputtes JSON ...) und liefert null (nicht angemeldet), statt dass die App beim Start hängt oder abstürzt.
/// Gelöscht wird der Eintrag nur bei dauerhaftem Defekt (nicht entschlüsselbar, beschädigt), nie nach einem vorübergehenden Lesefehler.
class SecureTokenStore implements TokenStore {
  static const _kTokens = 'lx_fampad_tokens';
  static const _kDevice = 'lx_fampad_device_id';
  static const _kProfile = 'lx_fampad_profile';
  static const _kAuthKeyKonten = 'lx_fampad_authkey_konten';
  static const _kCaps = 'lx_fampad_server_caps';
  static const _kSperre = 'lx_fampad_refresh_lock';

  final FlutterSecureStorage _s;
  SecureTokenStore([FlutterSecureStorage? storage]) : _s = storage ?? kSicherSpeicher;

  /// Liest und decodiert einen Eintrag. Ein unbrauchbarer Eintrag (dauerhaft nicht entschlüsselbar oder beschädigt) wird gelöscht, null geliefert. Ein VORÜBERGEHENDER
  /// Lesefehler (Keystore gesperrt, E/A) liefert nur null und löscht nichts: der nächste Start liest wieder.
  Future<T?> _lesen<T>(String key, T? Function(Object? json) lesen) async {
    final String? raw;
    try {
      raw = await _s.read(key: key);
    } catch (e) {
      if (!speicherFehlerDauerhaft(e)) return null;
      return _loeschenSicher(key); // dauerhaft unlesbar: wie nicht vorhanden behandeln
    }
    if (raw == null) return null;
    try {
      final wert = lesen(jsonDecode(raw));
      if (wert != null) return wert;
    } catch (_) {
      // beschädigte Daten
    }
    return _loeschenSicher(key);
  }

  Future<T?> _loeschenSicher<T>(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {
      // auch Löschen kann scheitern; der nächste Start versucht es erneut
    }
    return null;
  }

  @override
  Future<StoredTokens?> readTokens() => _lesen(_kTokens, StoredTokens.fromJson);

  /// Schreibt einen Eintrag. Scheitert das mit einem Plattformfehler (Keystore-Schlüssel verloren, der Speicher heilt sich mit resetOnError: false nicht selbst),
  /// meldet das [GeraeteSpeicherDefekt]: die Oberfläche bietet dann die bewusste Reparatur an.
  Future<void> _schreiben(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } on PlatformException catch (e) {
      // "Gerätespeicher defekt" nur bei einem Fehler, der nach einem dauerhaften Defekt aussieht (auch beim zweiten Versuch); alles andere (E/A, voller Speicher,
      // Aussetzer) bleibt ein normaler Fehler mit der allgemeinen Meldung
      if (speicherFehlerDauerhaft(e)) throw const GeraeteSpeicherDefekt();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        await _s.write(key: key, value: value);
      } on PlatformException catch (e2) {
        if (speicherFehlerDauerhaft(e2)) throw const GeraeteSpeicherDefekt();
        rethrow;
      }
    }
  }

  @override
  Future<void> writeTokens(StoredTokens tokens) async {
    await _schreiben(_kTokens, jsonEncode(tokens.toJson()));
    await _schreiben(_kDevice, tokens.deviceId);
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
  Future<ErneuerungsSperre?> readErneuerungsSperre() async {
    try {
      final raw = await _s.read(key: _kSperre);
      return raw == null ? null : ErneuerungsSperre.fromJson(jsonDecode(raw));
    } catch (_) {
      return null; // unlesbar = keine Sperre (sie verfällt ohnehin)
    }
  }

  @override
  Future<void> writeErneuerungsSperre(ErneuerungsSperre sperre) async {
    try {
      await _s.write(key: _kSperre, value: jsonEncode(sperre.toJson()));
    } catch (_) {
      // ohne Sperre erneuern ist schlechter als mit, aber nie ein Grund, die Anmeldung zu verlieren
    }
  }

  @override
  Future<void> clearErneuerungsSperre(String besitzer) async {
    try {
      if ((await readErneuerungsSperre())?.besitzer != besitzer) return;
      await _s.delete(key: _kSperre);
    } catch (_) {}
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
  Future<void> writeProfile(Map<String, dynamic> profile) => _schreiben(_kProfile, jsonEncode(profile));

  Future<List<String>> _konten() async =>
      (await _lesen<List<String>>(_kAuthKeyKonten, (v) => v is List ? [for (final e in v) if (e is String) e] : null)) ?? const [];

  @override
  Future<bool> istAuthKeyKonto(String email) async => (await _konten()).contains(_kontoSchluessel(email));

  @override
  Future<ServerFaehigkeiten?> readFaehigkeiten() => _lesen(_kCaps, _faehigkeitenLesen);

  @override
  Future<void> writeFaehigkeiten(ServerFaehigkeiten f) => _schreiben(_kCaps, _faehigkeitenJson(f));

  @override
  Future<void> merkeAuthKeyKonto(String email) async {
    final k = _kontoSchluessel(email);
    final liste = await _konten();
    if (liste.contains(k)) return;
    // wenige Konten pro Gerät: ältere Einträge fallen heraus
    final neu = [...liste, k];
    await _schreiben(_kAuthKeyKonten, jsonEncode(neu.length > 20 ? neu.sublist(neu.length - 20) : neu));
  }
}
