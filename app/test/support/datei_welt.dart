// Fake-Server der Dateiablage für die Client-Tests (Abschnitt 6n): tus-Upload (OPTIONS, POST, HEAD, PATCH, DELETE), Blobs mit Range, Kontingent und die Regeln der Sync-Entitäten `ordner`, `datei`,
// `datei_version` (Claim des Uploads, Nummer je Datei eindeutig, Freigabe-Invariante, Tiefe, Zyklus, Löschen nur leer, Rechte nach Rolle). Der Fake VERHÄLT SICH wie der echte Server (docs/API.md),
// ist aber nur für Tests; das Zusammenspiel mit dem echten Server prüft `app/tool/vertrag_test.dart`. Die Person der Anfrage steht im Bearer-Token der Tests (`person-<Kennung>`).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/dateien/datei_logik.dart';
import 'package:lx_fampad/data/medikamente/medikament_subjekte.dart' show istErwachsen;

import 'fake_server.dart';
import 'fake_sync_server.dart';

class FakeBlob {
  final String id;
  final String modus; // server | e2ee
  final String kind; // datei | thumb | opak
  final String? mime;
  final int laenge;
  final String besitzer;
  final BytesBuilder daten = BytesBuilder(copy: false);
  String zustand = 'upload'; // upload | ready | claimed
  String? sha256;
  String? claimEntity;
  String? claimId;
  int patches = 0;
  FakeBlob(this.id, this.modus, this.kind, this.mime, this.laenge, this.besitzer);

  int get offset => daten.length;
  Uint8List get bytes => daten.toBytes();
}

class FakeDateien {
  final FakeServer server;
  final FakeSyncServer sync;
  FakeDateien(this.server, this.sync) {
    sync.registrieren(server);
    sync.ablehnung = _regeln;
    server.on('OPTIONS /uploads', (_) => _tus(204, {'tus-version': '1.0.0', 'tus-extension': 'creation,expiration,termination', 'tus-max-size': '$maxE2eeBytes'}));
    server.on('POST /uploads', _anlegen);
    server.onMuster('HEAD /uploads/:id', _head);
    server.onMuster('PATCH /uploads/:id', _patch);
    server.onMuster('DELETE /uploads/:id', _loeschenUpload);
    server.onMuster('GET /files/blobs/:id', _lesen);
    server.on('GET /files/usage', (_) => jsonAntwort({'usedBytes': belegt, 'reservedBytes': reserviert, 'quotaBytes': kontingent, 'maxFileBytes': maxDateiBytes, 'maxE2eeBytes': maxE2eeBytes, 'chunkBytes': 4194304}));
  }

  // ------------------------------------------------------------------ Einstellungen und Beobachtung

  int maxDateiBytes = 104857600;
  int maxE2eeBytes = 105906176;
  int kontingent = 10737418240;
  final Map<String, FakeBlob> blobs = {};
  final Map<String, Role> rollen = {};
  int _n = 0;

  /// Alle PATCH-Längen (zum Prüfen der Abschnittsgrenzen) in der Reihenfolge der Anfragen.
  final List<int> patchLaengen = [];

  /// Eingespritzte Antworten: der erste passende Eintrag mit Rest wird verbraucht (`mal` Mal).
  final List<_Einspritzung> _einspritzungen = [];

  /// Die nächsten [mal] Anfragen, auf die [passt] zutrifft, beantwortet [antwort] (oder wirft, z. B. ein Verbindungsabbruch) statt der echten Logik.
  void einspritzen(bool Function(Req) passt, FutureOr<http.Response> Function(Req) antwort, {int mal = 1}) => _einspritzungen.add(_Einspritzung(passt, antwort, mal));

  int get belegt => blobs.values.where((b) => b.zustand != 'upload').fold(0, (s, b) => s + b.laenge);
  int get reserviert => blobs.values.where((b) => b.zustand == 'upload').fold(0, (s, b) => s + b.laenge);

  String? _person(Req r) => r.headers['authorization']?.replaceFirst('Bearer ', '');
  Role _rolle(String? p) => rollen[p] ?? Role.child;

  // ------------------------------------------------------------------ HTTP (tus und Blobs)

  http.Response _tus(int status, Map<String, String> kopf, [String body = '']) => http.Response(body, status, headers: {'tus-resumable': '1.0.0', ...kopf});

  http.Response _fehler(int status, String code, {Map<String, String> kopf = const {}}) => http.Response(jsonEncode({'error': code, 'message': 'Text des Servers'}), status, headers: {'content-type': 'application/json', 'tus-resumable': '1.0.0', ...kopf});

  Future<http.Response?> _eingespritzt(Req r) async {
    for (final e in _einspritzungen) {
      if (e.rest > 0 && e.passt(r)) {
        e.rest--;
        return await e.antwort(r);
      }
    }
    return null;
  }

  Map<String, String> _metadaten(String? roh) {
    final out = <String, String>{};
    if (roh == null || roh.isEmpty) return out;
    for (final teil in roh.split(',')) {
      final i = teil.trim().indexOf(' ');
      if (i <= 0) continue;
      out[teil.trim().substring(0, i)] = utf8.decode(base64.decode(teil.trim().substring(i + 1)));
    }
    return out;
  }

  Future<http.Response> _anlegen(Req r) async {
    final e = await _eingespritzt(r);
    if (e != null) return e;
    final laenge = int.tryParse(r.headers['upload-length'] ?? '');
    if (laenge == null || laenge <= 0) return _fehler(400, 'invalid_request');
    final m = _metadaten(r.headers['upload-metadata']);
    final modus = m['modus'] ?? 'server';
    final kind = m['kind'] ?? (modus == 'e2ee' ? 'opak' : 'datei');
    if (modus == 'e2ee' ? laenge > maxE2eeBytes : laenge > (kind == 'thumb' ? 262144 : maxDateiBytes)) return _fehler(413, 'file_too_large');
    if (belegt + reserviert + laenge > kontingent) return _fehler(413, 'quota_exceeded');
    final id = '${(++_n).toString().padLeft(8, '0')}-0000-4000-8000-000000000000';
    blobs[id] = FakeBlob(id, modus, kind, m['mime'], laenge, _person(r) ?? '');
    return _tus(201, {'location': '/api/v1/uploads/$id', 'upload-offset': '0', 'upload-expires': 'Fri, 01 Jan 2027 00:00:00 GMT'});
  }

  FakeBlob? _meinBlob(Req r) {
    final id = r.path.split('/').last;
    final b = blobs[id];
    return b != null && b.besitzer == _person(r) ? b : null;
  }

  Future<http.Response> _head(Req r) async {
    final e = await _eingespritzt(r);
    if (e != null) return e;
    final b = _meinBlob(r);
    if (b == null) return _fehler(404, 'not_found');
    return _tus(200, {'upload-offset': '${b.zustand == 'upload' ? b.offset : b.laenge}', 'upload-length': '${b.laenge}', 'cache-control': 'no-store'});
  }

  Future<http.Response> _patch(Req r) async {
    final e = await _eingespritzt(r);
    if (e != null) return e;
    final b = _meinBlob(r);
    if (b == null) return _fehler(404, 'not_found');
    final bytes = r.body is Uint8List ? r.body as Uint8List : Uint8List(0);
    patchLaengen.add(bytes.length);
    if (bytes.length > 4194304) return _fehler(413, 'chunk_too_large');
    if (b.zustand != 'upload') return _fehler(409, 'upload_done');
    final versatz = int.tryParse(r.headers['upload-offset'] ?? '');
    if (versatz != b.offset) return _fehler(409, 'offset_mismatch', kopf: {'upload-offset': '${b.offset}'});
    b.daten.add(bytes);
    b.patches++;
    if (b.offset < b.laenge) return _tus(204, {'upload-offset': '${b.offset}'});
    final alle = b.bytes;
    if (b.modus == 'server' && b.kind != 'thumb') {
      final erkannt = mimeAusKopf(alle.length > 16 ? Uint8List.sublistView(alle, 0, 16) : alle);
      final d = b.mime;
      if (d != null && (d.startsWith('image/') || d == 'application/pdf') && erkannt != d) {
        blobs.remove(b.id);
        return _fehler(422, 'mime_mismatch');
      }
    }
    b.sha256 = c.sha256.convert(alle).toString();
    b.zustand = 'ready';
    return _tus(204, {'upload-offset': '${b.offset}', 'upload-blob-id': b.id, 'upload-sha256': b.sha256!});
  }

  Future<http.Response> _loeschenUpload(Req r) async {
    final e = await _eingespritzt(r);
    if (e != null) return e;
    final b = _meinBlob(r);
    if (b == null) return _fehler(404, 'not_found');
    if (b.zustand == 'claimed') return _fehler(409, 'upload_claimed');
    blobs.remove(b.id);
    return _tus(204, {});
  }

  Future<http.Response> _lesen(Req r) async {
    final e = await _eingespritzt(r);
    if (e != null) return e;
    final id = r.path.split('/').last;
    final b = blobs[id];
    final person = _person(r);
    var sichtbar = b != null && (b.zustand == 'claimed' || (b.zustand == 'ready' && b.besitzer == person));
    // Tresor-Anhänge liest nur, wer den Tresor sehen darf (Eltern und Admins), nie ein Kind
    if (sichtbar && b.claimEntity == 'tresor_anhang' && !istErwachsen(_rolle(person))) sichtbar = false;
    if (!sichtbar) return http.Response(jsonEncode({'error': 'not_found'}), 404, headers: {'content-type': 'application/json'});
    final alle = b!.bytes;
    final kopf = {'etag': '"${b.id}"', 'accept-ranges': 'bytes', 'content-type': b.kind == 'thumb' ? (b.mime ?? 'image/png') : 'application/octet-stream'};
    final range = r.headers['range'];
    if (range == null) return http.Response.bytes(alle, 200, headers: {...kopf, 'content-length': '${alle.length}'});
    final mt = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
    if (mt == null) return http.Response('', 416, headers: {'content-range': 'bytes */${alle.length}'});
    int von;
    int bis;
    if (mt.group(1)!.isEmpty) {
      final n = int.tryParse(mt.group(2)!) ?? 0;
      von = alle.length - n < 0 ? 0 : alle.length - n;
      bis = alle.length - 1;
    } else {
      von = int.parse(mt.group(1)!);
      bis = mt.group(2)!.isEmpty ? alle.length - 1 : int.parse(mt.group(2)!);
      if (bis >= alle.length) bis = alle.length - 1;
    }
    if (von >= alle.length || von > bis) return http.Response('', 416, headers: {'content-range': 'bytes */${alle.length}'});
    return http.Response.bytes(Uint8List.sublistView(alle, von, bis + 1), 206, headers: {...kopf, 'content-range': 'bytes $von-$bis/${alle.length}'});
  }

  // ------------------------------------------------------------------ Sync-Regeln (nach server/src/sync/entities/dateien.ts)

  /// Zeilen der Entität, die leben.
  Iterable<FakeZeile> _lebende(String entity) => sync.zeilen.values.where((z) => z.entity == entity && !z.geloescht);

  FakeZeile? _z(String entity, Object? id) => id == null ? null : sync.zeilen['$entity/$id'];

  /// Die Ordner von [id] nach oben (der Ordner selbst zuerst); null bei fehlendem Glied, Zyklus oder mehr als 6 Ebenen.
  List<FakeZeile>? _kette(String id) {
    final out = <FakeZeile>[];
    String? aktuell = id;
    while (aktuell != null) {
      if (out.length >= 6) return null;
      final z = _z('ordner', aktuell);
      if (z == null || z.geloescht) return null;
      out.add(z);
      aktuell = z.fields['parentId'] as String?;
    }
    return out;
  }

  int _hoeheUnter(String id) {
    var ebene = {id};
    for (var h = 0; h <= 6; h++) {
      final kinder = {for (final z in _lebende('ordner')) if (ebene.contains(z.fields['parentId'])) z.id};
      if (kinder.isEmpty) return h;
      ebene = kinder;
    }
    return 7;
  }

  bool _hatKinder(String id, {required bool nurFamilie}) {
    bool zaehlt(FakeZeile z) => !nurFamilie || z.fields['audience'] == 'family';
    return _lebende('ordner').any((z) => z.fields['parentId'] == id && zaehlt(z)) || _lebende('datei').any((z) => z.fields['ordnerId'] == id && zaehlt(z));
  }

  bool _sieht(Role r, String audience) => istErwachsen(r) || audience == 'family';

  bool _zielGueltig(Role rolle, Object? ordnerId, String audience) {
    if (ordnerId == null) return true;
    final k = _z('ordner', ordnerId);
    if (k == null || k.geloescht) return false;
    final a = k.fields['audience'] as String;
    if (!_sieht(rolle, a)) return false;
    return audience != 'family' || a == 'family';
  }

  String? _regeln(Map<String, dynamic> o) {
    final entity = o['entity'] as String;
    if (!const {'ordner', 'datei', 'datei_version'}.contains(entity)) return null;
    final person = sync.person;
    final rolle = _rolle(person);
    final id = o['id'] as String;
    final vorhanden = _z(entity, id);
    final erwachsen = istErwachsen(rolle);
    if (o['op'] == 'delete') {
      if (vorhanden == null) return null; // wie die Fake-Engine: not_found
      final besitzer = entity == 'datei_version' ? _z('datei', vorhanden.fields['dateiId'])?.fields['ownerId'] : vorhanden.fields['ownerId'];
      if (!erwachsen && besitzer != person) return 'forbidden';
      if (entity == 'ordner' && _hatKinder(id, nurFamilie: false)) return 'forbidden';
      return null;
    }
    final f = Map<String, dynamic>.from(o['fields'] as Map);
    if (entity == 'datei_version') {
      if (vorhanden != null) return 'forbidden'; // unveränderlich
      final datei = _z('datei', f['dateiId']);
      if (datei == null || datei.geloescht) return null; // die Fake-Engine meldet not_found / parent_deleted
      if (!erwachsen && datei.fields['ownerId'] != person) return 'forbidden';
      if (_lebende('datei_version').any((v) => v.fields['dateiId'] == f['dateiId'] && v.fields['nr'] == f['nr'])) return 'not_found';
      if (_lebende('datei_version').where((v) => v.fields['dateiId'] == f['dateiId']).length >= 100) return 'limit_reached';
      // Claim: nur der eigene, fertige, noch freie Upload des richtigen Modus und der richtigen Art
      final blob = blobs[f['blobId']];
      if (blob == null || blob.zustand != 'ready' || blob.besitzer != person || blob.modus != 'server' || blob.kind != 'datei') return 'invalid_reference';
      FakeBlob? thumb;
      if (f['thumbBlobId'] != null) {
        thumb = blobs[f['thumbBlobId']];
        if (thumb == null || thumb.zustand != 'ready' || thumb.besitzer != person || thumb.modus != 'server' || thumb.kind != 'thumb') return 'invalid_reference';
      }
      blob
        ..zustand = 'claimed'
        ..claimEntity = 'datei_version'
        ..claimId = id;
      thumb
        ?..zustand = 'claimed'
        ..claimEntity = 'datei_version'
        ..claimId = id;
      final felder = o['fields'] as Map<String, dynamic>;
      felder['size'] = blob.laenge;
      felder['mime'] = blob.mime ?? mimeAusKopf(blob.bytes.length > 16 ? Uint8List.sublistView(blob.bytes, 0, 16) : blob.bytes) ?? 'application/octet-stream';
      felder['sha256'] = blob.sha256;
      return null;
    }
    // ordner und datei
    final felder = o['fields'] as Map<String, dynamic>;
    final audience = (f['audience'] ?? vorhanden?.fields['audience'] ?? 'family') as String;
    if (vorhanden == null) {
      if (!erwachsen && audience != 'family') return 'forbidden';
      felder['ownerId'] = person;
    } else {
      final besitzer = vorhanden.fields['ownerId'];
      if (!erwachsen && besitzer != person) return 'forbidden';
      if (!erwachsen && f.containsKey('audience')) return 'forbidden';
    }
    if (entity == 'datei') {
      final ordnerId = f.containsKey('ordnerId') ? f['ordnerId'] : vorhanden?.fields['ordnerId'];
      if ((vorhanden == null || f.containsKey('ordnerId') || f.containsKey('audience')) && !_zielGueltig(rolle, ordnerId, audience)) return 'invalid';
      return null;
    }
    final parentId = (f.containsKey('parentId') ? f['parentId'] : vorhanden?.fields['parentId']) as String?;
    var tiefe = 1;
    if (parentId != null) {
      if (parentId == id) return 'invalid';
      final oben = _kette(parentId);
      if (oben == null || oben.any((k) => k.id == id)) return 'invalid';
      if (!_sieht(rolle, oben.first.fields['audience'] as String)) return 'invalid';
      if (audience == 'family' && oben.first.fields['audience'] != 'family') return 'invalid';
      tiefe = oben.length + 1;
    }
    if (tiefe + _hoeheUnter(id) > 6) return 'invalid';
    if (audience == 'parents' && _hatKinder(id, nurFamilie: true)) return 'invalid';
    return null;
  }
}

class _Einspritzung {
  final bool Function(Req) passt;
  final FutureOr<http.Response> Function(Req) antwort;
  int rest;
  _Einspritzung(this.passt, this.antwort, this.rest);
}
