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

  /// Zählt Anfragen je Pfad (zum Prüfen, dass nichts ohne Not gesendet wurde).
  int anfragen(String methodPath) => server.anfragen(methodPath).length;

  /// Person, als die das Standard-Token der Testumgebung (`access-1`) gilt.
  final String? standardId;

  FakeE2eeServer(this.server, {this.standardId}) {
    server
      ..on('GET /me/keys', (r) => _mit(r, (p) => jsonAntwort({'keys': _keys(p), 'hasBackup': p.backupBlob != null && p.backupVersion == p.version})))
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
  void person(String id, String name) {
    _personen[id] = _Person(id, name);
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

  /// Person aus der Familie nehmen (verschwindet aus /members).
  void entferne(String id) => _personen.remove(id);

  /// Schlüssel einer Person direkt setzen (andere Mitglieder, die der Test nicht als Gerät simuliert).
  void setzeSchluessel(String id, {required String enc, required String sign, required int version}) {
    final p = _personen[id]!;
    p.enc = enc;
    p.sign = sign;
    p.version = version;
  }

  /// Was der Server über eine Person gespeichert hat (für Prüfungen: nie Geheimnisse).
  String gespeichert(String id) {
    final p = _personen[id]!;
    return jsonEncode({'enc': p.enc, 'sign': p.sign, 'backup': p.backupBlob, 'transfers': _transfers.values.where((t) => t.hash.startsWith('$id:')).map((t) => t.blob).toList()});
  }

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
