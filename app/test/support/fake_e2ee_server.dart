// In-Memory-Nachbau der E2EE-Endpunkte des Servers (docs/API.md): öffentliche Schlüssel, opake Sicherung, einmalige kurzlebige Übertragung
// (TTL 120 s, nur durch dieselbe Person, atomar), Step-up für Sicherung und Schlüsselwechsel. Mehrere Personen/Geräte teilen sich einen Server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/crypto/bytes.dart';

import 'fake_server.dart';

class _Historie {
  final String enc;
  final String sign;
  final int version;
  _Historie(this.enc, this.sign, this.version);
}

class _Person {
  final String id;
  final String name;
  String? enc;
  String? sign;
  int version = 0;
  final List<_Historie> historie = [];
  String? backupBlob;
  int backupVersion = 0;
  String? email;
  // Passwort-Sicherung (Schalter E2EE_PW_BACKUP)
  String? pwBlob;
  String? pwId;
  int pwVersion = 0;
  bool pwStale = false;
  bool pwVerifiziert = false;
  int pwAnzahl = 0;
  // noch unbestätigte Sicherung (pending): die aktuelle bleibt bis zur Bestätigung unberührt
  String? pwPBlob;
  String? pwPId;
  int pwPVersion = 0;
  // Geräte, die dem Server melden, den aktuellen Schlüssel zu haben (PUT /me/device-key)
  int geraete = 0;
  _Person(this.id, this.name);
}

class _Transfer {
  final String hash;
  final String blob;
  final int version;
  final DateTime bis;
  _Transfer(this.hash, this.blob, this.version, this.bis);
}

class FakeE2eeServer {
  final FakeServer server;
  final Map<String, _Person> _personen = {};
  final Map<String, _Transfer> _transfers = {};

  /// Steuerbare Uhr (Übertragung läuft nach 120 s ab).
  DateTime jetzt = DateTime.now().toUtc();

  /// Verlangt der Server gerade ein Step-up (403 step_up_required) für Sicherung/Wechsel?
  bool stepUpNoetig = false;
  int stepUps = 0;

  /// Schalter des Servers für die Passwort-Sicherung (GET /version: features.pwBackup; aus = die Routen gibt es nicht, 404).
  bool pwSchalter = false;

  /// Der Server nimmt den abgeleiteten authKey statt des Klartext-Passworts (GET /version: features.authKey) und, ob er den Klartext noch annimmt.
  bool authKeySchalter = false;
  bool legacyLogin = true;

  /// Meldet `GET /me/keys` die neuen Felder (pwBackupVerifiedAt, recoveryBackupAt, archiveCount)? Aus = ein älterer Server: die App darf dann nie "gesichert" annehmen.
  bool neueFelder = true;

  /// Wert von `archiveCount` in `GET /me/keys` (frühere, archivierte Sicherungen).
  int archiv = 0;

  /// Zuletzt per `POST /me/password/change` gesetzter authKey je Person (für Prüfungen).
  final Map<String, String> authKeys = {};

  /// Verändert den Blob in der Antwort von GET /me/key-backup-pw (simuliert eine fehlerhafte Ablage).
  String Function(String blob)? pwAbrufVerfaelschen;

  /// Zählt Anfragen je Pfad (zum Prüfen, dass nichts ohne Not gesendet wurde).
  int anfragen(String methodPath) => server.anfragen(methodPath).length;

  /// Person, als die das Standard-Token der Testumgebung (`access-1`) gilt.
  final String? standardId;

  FakeE2eeServer(this.server, {this.standardId}) {
    server
      ..on('GET /me/keys', (r) => _mit(r, (p) => jsonAntwort({'keys': _keys(p), 'hasBackup': p.backupBlob != null && p.backupVersion == p.version, if (p.pwStale && p.pwBlob != null) 'pwBackupStale': true, ..._neueFelder(p)})))
      ..on('GET /me/key-status', (r) => _mit(r, (p) {
        if (!keyStatusSchalter) return fehler(404, 'not_found');
        final hat = p.enc != null;
        final geraet = hat && p.geraete > 0;
        final pw = hat && pwSchalter && p.pwBlob != null && p.pwVerifiziert && !p.pwStale && p.pwVersion == p.version;
        final rec = hat && p.backupBlob != null && p.backupVersion == p.version;
        final n = [geraet, pw, rec].where((x) => x).length;
        // dieselbe Rechenvorschrift wie der Server (ampelOf)
        final ampel = !hat || n == 0 ? 'red' : (n >= 2 && geraet ? 'green' : (n == 1 ? (geraet ? 'yellow' : 'red') : 'yellow'));
        return jsonAntwort({
          'status': {
            'generatedAt': jetzt.toIso8601String(),
            'ampel': ampel,
            'hasKeys': hat,
            'keyVersion': hat ? p.version : null,
            'ways': {'device': geraet, 'pwBackup': pw, 'recoveryBackup': rec},
            'wayCount': n,
            'devicesTotal': p.geraete,
            'devicesWithKey': p.geraete,
            'devicesReported': p.geraete,
            'archiveCount': archiv,
          },
        });
      }))
      ..on('POST /me/keys', (r) => _mit(r, (p) {
        if (p.enc != null) return fehler(409, 'keys_exist');
        p.enc = r.json['publicEncKey'] as String;
        p.sign = r.json['publicSignKey'] as String;
        p.version = 1;
        return jsonAntwort({'keys': _keys(p)});
      }))
      ..on('PUT /me/keys', (r) => _mit(r, (p) {
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        if (p.enc == null) return fehler(404, 'not_found');
        if (r.json['expectedKeyVersion'] != p.version) return fehler(409, 'key_version_mismatch');
        p.historie.add(_Historie(p.enc!, p.sign!, p.version));
        p.enc = r.json['publicEncKey'] as String;
        p.sign = r.json['publicSignKey'] as String;
        p.version++;
        p.backupBlob = null;
        if (p.pwBlob != null) p.pwStale = true;
        p.pwPBlob = null;
        p.pwPId = null;
        _transfers.removeWhere((_, t) => t.hash.startsWith('${p.id}:'));
        return jsonAntwort({'keys': _keys(p)});
      }))
      ..on('PUT /me/key-backup', (r) => _mit(r, (p) {
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        if (p.enc == null) return fehler(409, 'no_keys');
        if (r.json['keyVersion'] != p.version) return fehler(409, 'key_version_mismatch');
        p.backupBlob = r.json['blob'] as String;
        p.backupVersion = p.version;
        return jsonAntwort({'ok': true});
      }))
      ..on('GET /me/key-backup', (r) => _mit(r, (p) {
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        if (p.backupBlob == null) return fehler(404, 'not_found');
        return jsonAntwort({'blob': p.backupBlob, 'keyVersion': p.backupVersion});
      }))
      ..on('GET /version', (_) => jsonAntwort({'service': 'lx-fampad', 'features': {'pwBackup': pwSchalter, 'authKey': authKeySchalter, 'legacyPasswordLogin': legacyLogin}}))
      ..on('POST /me/password/change', (r) => _mit(r, (p) {
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        final authKey = r.json['authKey'];
        if (authKey != null && !authKeySchalter) return fehler(400, 'invalid_request');
        if (authKey == null && !legacyLogin) return fehler(403, 'legacy_login_disabled');
        final id = r.json['pwBackupId'];
        if (id != null) {
          // wie der Server: Passwort und Sicherung gemeinsam, bei ungültiger Kennung passiert nichts
          if (id != p.pwPId || p.pwPBlob == null || p.pwPVersion != p.version) return fehler(404, 'not_found');
          p.pwBlob = p.pwPBlob;
          p.pwVersion = p.pwPVersion;
          p.pwId = p.pwPId;
          p.pwStale = false;
          p.pwVerifiziert = true;
          p.pwPBlob = null;
          p.pwPId = null;
        }
        if (authKey is String) authKeys[p.id] = authKey;
        return jsonAntwort({'ok': true});
      }))
      ..on('POST /auth/kdf-params', (r) {
        if (!pwSchalter) return fehler(404, 'not_found');
        return jsonAntwort({'kdf': _kdf(r.json['email'] as String)});
      })
      ..on('PUT /me/key-backup-pw', (r) => _mit(r, (p) {
        if (!pwSchalter) return fehler(404, 'not_found');
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        if (p.enc == null) return fehler(409, 'no_keys');
        final kdf = r.json['kdf'] as Map<String, dynamic>;
        if (kdf['id'] != 'argon2id-v1' || kdf['memKiB'] != 65536 || kdf['ops'] != 3) return fehler(409, 'kdf_mismatch');
        if (r.json['keyVersion'] != p.version) return fehler(409, 'key_version_mismatch');
        p.pwPBlob = r.json['blob'] as String;
        p.pwPVersion = p.version;
        p.pwPId = '00000000-0000-4000-8000-${(++p.pwAnzahl).toString().padLeft(12, '0')}';
        return jsonAntwort({'ok': true, 'id': p.pwPId});
      }))
      ..on('GET /me/key-backup-pw', (r) => _mit(r, (p) {
        if (!pwSchalter) return fehler(404, 'not_found');
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        if (r.query['pending'] == '1') {
          if (p.pwPBlob == null) return fehler(404, 'not_found');
          final blob = pwAbrufVerfaelschen?.call(p.pwPBlob!) ?? p.pwPBlob!;
          return jsonAntwort({'id': p.pwPId, 'blob': blob, 'keyVersion': p.pwPVersion, 'state': 'pending', 'kdf': _kdf(p.email ?? '')});
        }
        if (p.pwBlob == null) return fehler(404, 'not_found');
        final blob = pwAbrufVerfaelschen?.call(p.pwBlob!) ?? p.pwBlob!;
        return jsonAntwort({'id': p.pwId, 'blob': blob, 'keyVersion': p.pwVersion, 'state': p.pwStale ? 'stale' : 'active', 'kdf': _kdf(p.email ?? '')});
      }))
      ..on('POST /me/key-backup-pw/verified', (r) => _mit(r, (p) {
        if (!pwSchalter) return fehler(404, 'not_found');
        if (stepUpNoetig) return fehler(403, 'step_up_required');
        if (r.json['id'] == p.pwId && p.pwVerifiziert && !p.pwStale) return jsonAntwort({'ok': true});
        if (r.json['id'] != p.pwPId || p.pwPBlob == null) return fehler(r.json['id'] == p.pwId ? 409 : 404, r.json['id'] == p.pwId ? 'backup_not_current' : 'not_found');
        if (p.pwPVersion != p.version) return fehler(409, 'backup_not_current');
        // atomar: pending wird aktuell, die bisherige ist ersetzt
        p.pwBlob = p.pwPBlob;
        p.pwVersion = p.pwPVersion;
        p.pwId = p.pwPId;
        p.pwStale = false;
        p.pwVerifiziert = true;
        p.pwPBlob = null;
        p.pwPId = null;
        return jsonAntwort({'ok': true});
      }))
      ..on('POST /me/key-transfer', (r) => _mit(r, (p) {
        if (p.enc == null) return fehler(409, 'no_keys');
        if (r.json['keyVersion'] != p.version) return fehler(409, 'key_version_mismatch');
        _transfers.removeWhere((_, t) => t.hash.startsWith('${p.id}:'));
        final hash = '${p.id}:${_sha(r.json['lookup'] as String)}';
        final bis = jetzt.add(const Duration(seconds: 120));
        _transfers[hash] = _Transfer(hash, r.json['blob'] as String, p.version, bis);
        return jsonAntwort({'expiresAt': bis.toIso8601String(), 'ttlSec': 120});
      }))
      ..on('POST /me/key-transfer/claim', (r) => _mit(r, (p) {
        // einmalig und atomar: entfernen und liefern; nur dieselbe Person (Schlüssel enthält die Person), nur vor Ablauf
        final t = _transfers.remove('${p.id}:${_sha(r.json['lookup'] as String)}');
        if (t == null || !t.bis.isAfter(jetzt)) return fehler(404, 'not_found');
        return jsonAntwort({'blob': t.blob, 'keyVersion': t.version});
      }))
      ..on('GET /members', (r) => _mit(r, (_) => jsonAntwort({'members': [for (final p in _personen.values) _mitglied(p)]})))
      ..on('POST /auth/step-up/code', (r) {
        stepUps++;
        stepUpNoetig = false;
        return jsonAntwort({'ok': true});
      });
  }

  /// Person anlegen (Anmeldung dieser Person wird über das Header-Token `access-<id>` erkannt).
  void person(String id, String name, {String? email}) {
    _personen[id] = _Person(id, name)..email = email;
    // Schlüssel eines Mitglieds in einer Version (aktuell oder Historie), nur Familienmitglieder (hier: alle bekannten Personen)
    server.on('GET /members/$id/keys', (r) => _mit(r, (_) {
      final p = _personen[id]!;
      final alle = [
        for (final h in p.historie) {'publicEncKey': h.enc, 'publicSignKey': h.sign, 'keyVersion': h.version},
        if (p.enc != null) {'publicEncKey': p.enc, 'publicSignKey': p.sign, 'keyVersion': p.version},
      ];
      final v = int.tryParse(r.query['version'] ?? '');
      final keys = v == null ? alle : alle.where((k) => k['keyVersion'] == v).toList();
      return keys.isEmpty ? fehler(404, 'not_found') : jsonAntwort({'userId': id, 'keys': keys});
    }));
  }

  /// Routen (z. B. `PUT /me/keys`), deren Antwort verloren geht: Der Server führt die Anfrage aus, der Client sieht aber einen Netzfehler.
  final Set<String> verliereAntwort = {};

  /// Personen, die (noch) auf die Freigabe warten (Status pending in /members).
  final Set<String> ausstehend = {};

  /// Kennt der Server `GET /me/key-status` (sonst 404 wie ein älterer Server)?
  bool keyStatusSchalter = true;

  /// So viele Geräte der Person melden dem Server, den aktuellen Schlüssel zu haben.
  void geraeteMelden(String id, int n) => _personen[id]!.geraete = n;

  /// Aktuelle Schlüsselversion einer Person (für Vermerke in Tests).
  int schluesselVersion(String id) => _personen[id]!.version;

  /// Legt eine Sicherung des Wiederherstellungsschlüssels für die aktuelle Schlüsselversion ab.
  void sicherungEinspielen(String id) {
    final p = _personen[id]!;
    p.backupBlob = 'x';
    p.backupVersion = p.version;
  }

  /// Person aus der Familie nehmen (verschwindet aus /members).
  void entferne(String id) => _personen.remove(id);

  /// Schlüssel einer Person direkt setzen (andere Mitglieder, die der Test nicht als Gerät simuliert).
  void setzeSchluessel(String id, {required String enc, required String sign, required int version}) {
    final p = _personen[id]!;
    p.enc = enc;
    p.sign = sign;
    p.version = version;
  }

  /// Salt wie beim echten Server: nur aus E-Mail bestimmt (öffentlich, deterministisch), 16 Byte.
  Map<String, dynamic> _kdf(String email) => {
    'id': 'argon2id-v1',
    'memKiB': 65536,
    'ops': 3,
    'salt': base64urlKodieren(saltFuer(email)),
  };

  /// Der Salt, den dieser Fake-Server für eine E-Mail nennt (16 Byte).
  static Uint8List saltFuer(String email) => Uint8List.fromList(c.sha256.convert(utf8.encode('salt|${email.trim().toLowerCase()}')).bytes.sublist(0, 16));

  /// Legt eine fertige, schon verifizierte Passwort-Sicherung einer Person ab (so, wie ein anderes Gerät sie hinterlassen hätte).
  void pwEinspielen(String id, String blob, {required int version}) {
    final p = _personen[id]!;
    p.pwBlob = blob;
    p.pwVersion = version;
    p.pwStale = false;
    p.pwVerifiziert = true;
    p.pwPBlob = null;
    p.pwId = '00000000-0000-4000-8000-${(++p.pwAnzahl).toString().padLeft(12, '0')}';
  }

  /// Wie der Server nach einem Passwort-Reset: die aktuelle Passwort-Sicherung wird `stale` (nie gelöscht), eine unbestätigte verfällt.
  void passwortZurueckgesetzt(String id) {
    final p = _personen[id]!;
    if (p.pwBlob != null) p.pwStale = true;
    p.pwPBlob = null;
    p.pwPId = null;
  }

  /// Zustand der Passwort-Sicherung einer Person (für Prüfungen).
  ({String? blob, String? pendingBlob, bool verifiziert, bool stale, int version, int anzahl}) pwStand(String id) {
    final p = _personen[id]!;
    return (blob: p.pwBlob, pendingBlob: p.pwPBlob, verifiziert: p.pwVerifiziert, stale: p.pwStale, version: p.pwVersion, anzahl: p.pwAnzahl);
  }

  /// Was der Server über eine Person gespeichert hat (für Prüfungen: nie Geheimnisse).
  String gespeichert(String id) {
    final p = _personen[id]!;
    return jsonEncode({'enc': p.enc, 'sign': p.sign, 'backup': p.backupBlob, 'pwBackup': p.pwBlob, 'transfers': _transfers.values.where((t) => t.hash.startsWith('$id:')).map((t) => t.blob).toList()});
  }

  Map<String, dynamic> _neueFelder(_Person p) => !neueFelder
      ? const {}
      : {
          if (p.pwBlob != null && p.pwVerifiziert && !p.pwStale) 'pwBackupVerifiedAt': jetzt.toIso8601String(),
          if (p.backupBlob != null && p.backupVersion == p.version) 'recoveryBackupAt': jetzt.toIso8601String(),
          'archiveCount': archiv,
        };

  Map<String, dynamic>? _keys(_Person p) => p.enc == null ? null : {'publicEncKey': p.enc, 'publicSignKey': p.sign, 'keyVersion': p.version};

  Map<String, dynamic> _mitglied(_Person p) => {...userJson(id: p.id, name: p.name, role: 'parent', email: null, status: ausstehend.contains(p.id) ? 'pending' : 'active'), if (p.enc != null) ...?_keys(p)};

  String _sha(String s) => base64urlKodieren(Uint8List.fromList(c.sha256.convert(utf8.encode(s)).bytes));

  /// Wer fragt? Aus dem Bearer-Token `access-<id>`; ohne gültiges Token 401.
  Future<http.Response> _mit(Req r, http.Response Function(_Person p) aktion) async {
    final auth = r.headers['authorization'] ?? '';
    final id = auth.startsWith('Bearer access-') ? auth.substring('Bearer access-'.length) : '';
    final p = _personen[id == '1' ? standardId : id];
    if (p == null) return fehler(401, 'unauthenticated');
    final antwort = aktion(p);
    if (verliereAntwort.contains(r.key)) throw http.ClientException('Verbindung abgebrochen');
    return antwort;
  }
}
