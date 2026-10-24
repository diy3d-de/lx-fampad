// HTTP-Client für die Server-Schnittstelle (docs/API.md).
//
// Web: Die Sitzung trägt der HttpOnly-Cookie (gleiche Domain, der Browser sendet ihn selbst). Jede ändernde Anfrage
//   (POST, PUT, PATCH, DELETE) bekommt den Header X-CSRF-Token (aus der Sitzungsantwort bzw. GET /me). Nichts landet in localStorage.
// Android: Access-Token (15 min) als Bearer-Header, Refresh-Token in flutter_secure_storage. Das Access-Token wird kurz vor dem
//   Ablauf oder nach einem 401 erneuert.
//
// Refresh-Regeln (der Server erkennt Wiederverwendung strikt und widerruft die ganze Token-Familie):
//   - Erneuerungen laufen nie parallel: alle Aufrufer warten auf dieselbe Anfrage (ein Future).
//   - Bricht die Verbindung ab, ohne dass sicher ist, ob der Server die Anfrage bekam (Zeitüberschreitung der Antwort, Abbruch
//     mitten in der Übertragung), wird das Refresh-Token NICHT erneut gesendet (es könnte schon eingelöst sein). Die lokale
//     Sitzung wird verworfen und die Person meldet sich neu an. Nur Fehler beim Verbindungsaufbau (VerbindungsaufbauFehler:
//     kein Netz, Adresse nicht auflösbar, abgelehnt, Zeitlimit beim Aufbau) lassen die Token unangetastet; der nächste Aufruf
//     versucht es dann wieder. Die Einstufung hängt nur vom Typ der Ausnahme ab (api_error.dart), nie vom Text.
//   - 401 führt nur bei den Codes unauthenticated/invalid_token zu Erneuerung und Wiederholung (andere 401-Fachcodes wie
//     step_up_failed zählen serverseitig gegen die Sperre und werden nie wiederholt).
//   - Sitzungsgeneration: Melden sich Person oder Sitzung ab bzw. um, während eine Erneuerung oder Anfrage läuft, verfällt deren
//     Ergebnis (kein Zurückschreiben alter Token, keine Abmeldung der neuen Sitzung).
//   - Token erscheinen nie in Logs oder Fehlermeldungen.
import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../constants.dart';
import 'api_error.dart';
import 'models.dart';
import 'token_store.dart';

enum SessionLostReason {
  /// Sitzung ungültig oder abgelaufen (401).
  abgelaufen,

  /// Die Erneuerung brach mitten drin ab; ob der Server das Refresh-Token einlöste, ist unklar.
  unsicher,
}

/// Antwort von [ApiClient.getBytes]: `bytes` ist null, wenn der Server mit 304 antwortete (Zwischenspeicher gilt weiter).
class BytesAntwort {
  final Uint8List? bytes;
  final String? etag;
  const BytesAntwort(this.bytes, this.etag);
}

class ApiClient {
  final http.Client _client;
  final TokenStore _store;
  final bool _web;
  final String _base;
  final DateTime Function() _now;
  final Duration _timeout;

  /// false (Hintergrund-Abgleich nach einem Push-Wecker): nie das Refresh-Token einlösen und nie Token verwerfen. Ist das Access-Token
  /// abgelaufen oder wird es abgelehnt, endet die Anfrage mit einem Verbindungsfehler; der nächste Start der App gleicht ab. So kann
  /// ein zweiter Prozess oder eine zweite Engine nie ein Refresh-Token doppelt einlösen (der Server würde die ganze Familie widerrufen).
  final bool _refreshErlaubt;

  /// Nur mit `refreshErlaubt: false` (Hintergrund): ein abgelaufenes oder abgelehntes Zugangstoken wird genau EINMAL je Client über denselben serialisierten,
  /// prozessübergreifend gesperrten Weg erneuert wie sonst ([_erneuern]); danach nie wieder (kein Schleifen, ein Fehler bleibt der Fehler dieses Laufs).
  final bool _hintergrundErneuern;
  Future<void>? _hgLauf;

  /// Prozessübergreifende Sperre der Erneuerung (Hintergrund-Engine und App teilen nur die Token-Ablage): Gültigkeit und Abstand zum Prüfen/Zurücklesen.
  final Duration _sperreDauer;
  final Duration _sperreAbstand;

  /// Wird aufgerufen, wenn die Sitzung nicht mehr gültig ist (Zustand wird "abgemeldet").
  void Function(SessionLostReason reason)? onSessionLost;

  StoredTokens? _tokens;
  bool _tokensGeladen = false;
  String? _csrf;
  Future<void>? _refresh;

  /// Zählt Sitzungswechsel (Anmelden, Verwerfen). Späte Ergebnisse alter Sitzungen werden damit erkannt und verworfen.
  int _gen = 0;

  ApiClient({
    required this._client,
    required this._store,
    bool? web,
    String? base,
    DateTime Function()? now,
    this._timeout = const Duration(seconds: 20),
    this._refreshErlaubt = true,
    this._hintergrundErneuern = false,
    this._sperreDauer = const Duration(seconds: 30),
    this._sperreAbstand = const Duration(milliseconds: 40),
  }) : _web = web ?? kIsWeb,
       _base = base ?? kApiBase,
       _now = now ?? DateTime.now;

  bool get istWeb => _web;

  /// Kurz vor Ablauf wird das Access-Token vorsorglich erneuert.
  static const _vorlauf = Duration(seconds: 30);

  Uri _uri(String path) {
    final u = '$_base/api/v1$path';
    return _base.isEmpty ? Uri.base.resolve(u) : Uri.parse(u);
  }

  // ---------------------------------------------------------------- Sitzung

  /// Übernimmt die Sitzung aus einer Anmeldeantwort (Web: CSRF-Token, App: Token in den sicheren Speicher).
  Future<void> sitzungUebernehmen(SessionDto s) async {
    _gen++; // neue Sitzung: laufende Erneuerungen und Anfragen der alten verfallen
    _refresh = null;
    await _sitzungSchreiben(s);
  }

  Future<void> _sitzungSchreiben(SessionDto s) async {
    if (!s.istApp) {
      _csrf = s.csrfToken;
      return;
    }
    final t = StoredTokens(
      accessToken: s.accessToken!,
      accessExpiresAt: s.accessExpiresAt!,
      refreshToken: s.refreshToken!,
      refreshExpiresAt: s.refreshExpiresAt!,
      deviceId: s.deviceId,
    );
    _tokens = t;
    _tokensGeladen = true;
    await _store.writeTokens(t);
  }

  void csrfSetzen(String? token) => _csrf = token;

  /// Verwirft alle lokalen Sitzungsdaten (kein Serveraufruf).
  Future<void> sitzungVerwerfen() async {
    _gen++; // eine gerade laufende Erneuerung darf nichts mehr zurückschreiben
    _refresh = null;
    _csrf = null;
    _tokens = null;
    _tokensGeladen = true;
    await _store.clearTokens();
  }

  /// Sind (nur App) gespeicherte Token vorhanden?
  Future<bool> hatGespeicherteToken() async => (await _tokenLaden()) != null;

  Future<StoredTokens?> _tokenLaden() async {
    if (!_tokensGeladen) {
      _tokens = await _store.readTokens();
      _tokensGeladen = true;
    }
    return _tokens;
  }

  /// Verwirft die Sitzung und meldet den Verlust. Gehört der Anlass zu einer älteren Sitzung ([gen] weicht ab), passiert nichts.
  Future<void> _verloren(SessionLostReason grund, int gen) async {
    if (gen != _gen) return;
    await sitzungVerwerfen();
    onSessionLost?.call(grund);
  }

  // ---------------------------------------------------------------- Anfragen

  Future<Json> get(String path, {bool auth = true}) => _anfrage('GET', path, null, auth);
  Future<Json> post(String path, [Object? body, bool auth = true]) => _anfrage('POST', path, body ?? const <String, dynamic>{}, auth);
  Future<Json> patch(String path, Object body) => _anfrage('PATCH', path, body, true);
  Future<Json> put(String path, Object body) => _anfrage('PUT', path, body, true);
  Future<Json> delete(String path) => _anfrage('DELETE', path, null, true);

  /// Sendet rohe Bytes (z. B. ein Bild) mit festem Content-Type; die Antwort ist wie sonst JSON.
  Future<Json> putBytes(String path, Uint8List bytes, String contentType) => _anfrage('PUT', path, null, true, rohdaten: bytes, contentType: contentType);

  /// Lädt rohe Bytes. Mit [etag] kann der Server mit 304 antworten (dann ist [BytesAntwort.bytes] null).
  Future<BytesAntwort> getBytes(String path, {String? etag}) async {
    final gen = _gen;
    final res = await _senden('GET', path, null, true, extraKopf: {'accept': 'image/*', 'if-none-match': ?etag});
    if (res.statusCode == 304) return BytesAntwort(null, etag);
    if (res.statusCode == 200) return BytesAntwort(res.bodyBytes, res.headers['etag']);
    await _auswerten(res, true, gen); // wirft den passenden Fehler
    throw ApiException.unerwarteteAntwort;
  }

  Future<Json> _anfrage(String method, String path, Object? body, bool auth, {Uint8List? rohdaten, String? contentType}) async {
    final gen = _gen;
    final res = await _senden(method, path, body, auth, rohdaten: rohdaten, contentType: contentType);
    return _auswerten(res, auth, gen);
  }

  /// Eine Anfrage inklusive einmaliger Erneuerung bei abgelehntem Access-Token; die Antwort wird nicht ausgewertet.
  Future<http.Response> _senden(
    String method,
    String path,
    Object? body,
    bool auth, {
    Uint8List? rohdaten,
    String? contentType,
    Map<String, String> extraKopf = const {},
  }) async {
    var gesendetesToken = await _vorbereiten(auth);
    var res = await _einmal(method, path, body, auth, gesendetesToken, rohdaten, contentType, extraKopf);
    if (auth && res.statusCode == 401 && !_web && gesendetesToken != null && _istSitzungsCode(_fehlercode(res))) {
      // ohne Refresh-Erlaubnis (Hintergrund): weder erneuern noch die Sitzung verwerfen, nur melden, dass es jetzt nicht geht
      if (!_refreshErlaubt) {
        if (!_hintergrundErneuern || _hgLauf != null) throw ApiException.zugangAbgelaufen;
        await _nachUnauthorized(gesendetesToken, hintergrund: true);
        gesendetesToken = (await _tokenLaden())?.accessToken;
        return _einmal(method, path, body, auth, gesendetesToken, rohdaten, contentType, extraKopf);
      }
      // Access-Token abgelehnt (z. B. abgelaufen/Uhr): einmal erneuern, aber nur, wenn nicht schon jemand anderes erneuert hat.
      // Andere 401-Fachcodes (step_up_failed ...) bleiben, wie sie sind: kein Erneuern, kein zweiter Versuch.
      await _nachUnauthorized(gesendetesToken);
      gesendetesToken = (await _tokenLaden())?.accessToken;
      res = await _einmal(method, path, body, auth, gesendetesToken, rohdaten, contentType, extraKopf);
    }
    return res;
  }

  /// 401-Codes, die "Sitzung bzw. Token ungültig" bedeuten (alle anderen 401 sind Fachfehler der Aktion).
  static bool _istSitzungsCode(String code) => code == 'unauthenticated' || code == 'invalid_token';

  /// Gibt das zu sendende Access-Token zurück (App) und erneuert es bei Bedarf.
  Future<String?> _vorbereiten(bool auth) async {
    if (!auth || _web) return null;
    var t = await _tokenLaden();
    if (t == null) {
      throw const ApiException(
        kind: ApiErrorKind.nichtAngemeldet,
        status: 401,
        code: 'unauthenticated',
        message: 'Du bist nicht angemeldet.',
      );
    }
    if (!_refreshErlaubt) {
      // nur mit einem noch gültigen Access-Token (mit Reserve für die Laufzeit der Anfrage), sonst ohne Tokenzugriff beenden
      if (!t.accessExpiresAt.subtract(const Duration(seconds: 5)).isAfter(_now())) {
        if (!_hintergrundErneuern) throw ApiException.zugangAbgelaufen;
        await _hintergrundErneuernEinmal();
        t = await _tokenLaden();
        if (t == null || !t.accessExpiresAt.subtract(const Duration(seconds: 5)).isAfter(_now())) throw ApiException.zugangAbgelaufen;
      }
      return t.accessToken;
    }
    if (!t.accessExpiresAt.subtract(_vorlauf).isAfter(_now())) {
      await _erneuern();
      t = await _tokenLaden();
      if (t == null) {
        throw const ApiException(
          kind: ApiErrorKind.nichtAngemeldet,
          status: 401,
          code: 'unauthenticated',
          message: 'Du bist nicht angemeldet.',
        );
      }
    }
    return t.accessToken;
  }

  Future<http.Response> _einmal(
    String method,
    String path,
    Object? body,
    bool auth,
    String? accessToken, [
    Uint8List? rohdaten,
    String? contentType,
    Map<String, String> extraKopf = const {},
  ]) async {
    final headers = <String, String>{'accept': 'application/json', ...extraKopf};
    if (body != null) headers['content-type'] = 'application/json';
    if (rohdaten != null && contentType != null) headers['content-type'] = contentType;
    if (accessToken != null) headers['authorization'] = 'Bearer $accessToken';
    if (_web && auth && method != 'GET' && _csrf != null) headers['x-csrf-token'] = _csrf!;
    final request = http.Request(method, _uri(path))..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    if (rohdaten != null) request.bodyBytes = rohdaten;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on Exception catch (e) {
      // Zeitüberschreitung, ClientException, TLS-Fehler u. ä.: alles, was nicht vom Server kommt, ist ein Verbindungsproblem
      throw netzwerkFehler(e);
    }
  }

  Future<Json> _auswerten(http.Response res, bool auth, int gen) async {
    final status = res.statusCode;
    Object? daten;
    if (res.bodyBytes.isNotEmpty) {
      try {
        daten = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        daten = null;
      }
    }
    if (status >= 200 && status < 300) {
      if (daten == null) return <String, dynamic>{};
      if (daten is Map<String, dynamic>) return daten;
      throw ApiException.unerwarteteAntwort;
    }
    final code = daten is Map && daten['error'] is String ? daten['error'] as String : '';
    final retry = int.tryParse(res.headers['retry-after'] ?? '') ?? (daten is Map && daten['retryAfterSec'] is int ? daten['retryAfterSec'] as int : null);
    final fehler = ApiException.vonAntwort(status: status, code: code, retryAfterSekunden: retry);
    // 401 mit Sitzungscode an einer geschützten Stelle = Sitzung weg (Fachfehler wie step_up_failed oder invalid_credentials nicht)
    if (auth && status == 401 && _istSitzungsCode(code)) {
      await _verloren(SessionLostReason.abgelaufen, gen);
      throw ApiException(kind: ApiErrorKind.nichtAngemeldet, status: 401, code: code, message: fehler.message);
    }
    throw fehler;
  }

  // ---------------------------------------------------------------- Refresh

  /// Stellt sicher, dass das Access-Token noch gültig ist, und erneuert es dafür einmal über denselben serialisierten Weg wie jede Anfrage (gleichzeitige
  /// Aufrufer teilen sich eine Anfrage). Gilt ausdrücklich auch für einen Client mit `refreshErlaubt: false`: Der Aufrufer (heute nur der Standort-Abruf
  /// nach einem Wecker, höchstens einmal je 30 Sekunden) entscheidet bewusst, dass er hier erneuern darf. Nie in einer Schleife wiederholen: ein Fehler
  /// (Verbindung, abgelehnt) wird weitergereicht. Web: nichts zu tun (Cookie).
  Future<void> zugangErneuern() async {
    if (_web) return;
    final t = await _tokenLaden();
    if (t == null) {
      throw const ApiException(kind: ApiErrorKind.nichtAngemeldet, status: 401, code: 'unauthenticated', message: 'Du bist nicht angemeldet.');
    }
    if (t.accessExpiresAt.subtract(_vorlauf).isAfter(_now())) return;
    await _erneuern();
  }

  Future<void> _nachUnauthorized(String gesendet, {bool hintergrund = false}) async {
    final aktuell = await _tokenLaden();
    if (aktuell == null) return; // inzwischen abgemeldet
    if (aktuell.accessToken != gesendet) return; // ein anderer Aufruf hat schon erneuert
    if (hintergrund) return _hintergrundErneuernEinmal();
    await _erneuern();
  }

  /// Hintergrund: höchstens eine Erneuerung je Client; jeder weitere Aufruf desselben Laufs wartet auf dasselbe Ergebnis (auch denselben Fehler), ohne erneut zu erneuern.
  Future<void> _hintergrundErneuernEinmal() => _hgLauf ??= _erneuern();

  /// Übernimmt Token, die eine andere Engine/ein anderer Prozess in die gemeinsame Ablage geschrieben hat (nie ältere): das Refresh-Token ist dann
  /// schon eingelöst, ein zweites Einlösen würde die Token-Familie widerrufen. Ergebnis true: die übernommenen Token gelten noch (nichts mehr zu tun).
  Future<bool> _frischeUebernehmen(int gen) async {
    final alt = _tokens;
    if (alt == null) return false;
    final StoredTokens? neu;
    try {
      neu = await _store.readTokens();
    } catch (_) {
      return false;
    }
    if (gen != _gen) throw _sitzungGeaendert;
    if (neu == null || neu.refreshToken == alt.refreshToken || !neu.accessExpiresAt.isAfter(alt.accessExpiresAt)) return false;
    _tokens = neu;
    return neu.accessExpiresAt.subtract(_vorlauf).isAfter(_now());
  }

  /// Erneuert die Token; gleichzeitige Aufrufer teilen sich genau eine Anfrage.
  Future<void> _erneuern() {
    final laufend = _refresh;
    if (laufend != null) return laufend;
    late final Future<void> f;
    f = _erneuernEinmal().whenComplete(() {
      if (identical(_refresh, f)) _refresh = null;
    });
    _refresh = f;
    return f;
  }

  /// Erneuert unter der Sperre der gemeinsamen Ablage: Hintergrund-Engine und App laufen in getrennten Isolates, teilen aber den Token-Speicher. Vor und
  /// nach dem Warten auf die Sperre werden die Token frisch gelesen; hat die andere Seite schon erneuert, werden ihre (neueren) Token übernommen,
  /// statt das verbrauchte Refresh-Token ein zweites Mal einzulösen (der Server würde die ganze Familie widerrufen). Die Sperre gilt höchstens
  /// [_sperreDauer] (Absturz mitten drin sperrt nie dauerhaft); wer nicht rechtzeitig an die Reihe kommt, bekommt einen Verbindungsfehler (Token unangetastet).
  Future<void> _erneuernEinmal() async {
    final gen = _gen;
    await _tokenLaden();
    if (await _frischeUebernehmen(gen)) return;
    final mein = '${_now().microsecondsSinceEpoch}-${Random.secure().nextInt(4294967296)}';
    final uhr = Stopwatch()..start();
    while (true) {
      final s = await _store.readErneuerungsSperre();
      if (s != null && s.besitzer != mein && s.bis.isAfter(_now())) {
        // jemand anderes erneuert gerade: warten, dann frisch lesen
        if (uhr.elapsed > _sperreDauer + _sperreAbstand * 2) throw ApiException.keineVerbindung;
        await Future<void>.delayed(_sperreAbstand);
        if (await _frischeUebernehmen(gen)) return;
        continue;
      }
      await _store.writeErneuerungsSperre(ErneuerungsSperre(mein, _now().add(_sperreDauer)));
      await Future<void>.delayed(_sperreAbstand); // wer gleichzeitig geschrieben hat, überschreibt uns: zurücklesen entscheidet
      final z = await _store.readErneuerungsSperre();
      if (z == null || z.besitzer == mein) break; // null: Ablage ohne Sperre, dann ohne
      if (uhr.elapsed > _sperreDauer + _sperreAbstand * 2) throw ApiException.keineVerbindung;
    }
    try {
      if (await _frischeUebernehmen(gen)) return;
      await _erneuernEinloesen(gen);
    } finally {
      await _store.clearErneuerungsSperre(mein);
    }
  }

  Future<void> _erneuernEinloesen(int gen) async {
    final t = await _tokenLaden();
    if (t == null) {
      throw const ApiException(kind: ApiErrorKind.nichtAngemeldet, status: 401, code: 'unauthenticated', message: 'Du bist nicht angemeldet.');
    }
    if (!t.refreshExpiresAt.isAfter(_now())) {
      await _verloren(SessionLostReason.abgelaufen, gen);
      throw const ApiException(
        kind: ApiErrorKind.nichtAngemeldet,
        status: 401,
        code: 'invalid_token',
        message: 'Deine Anmeldung ist abgelaufen. Bitte melde dich neu an.',
      );
    }
    final http.Response res;
    try {
      final request = http.Request('POST', _uri('/auth/refresh'))
        ..headers.addAll({'accept': 'application/json', 'content-type': 'application/json'})
        ..body = jsonEncode({'refreshToken': t.refreshToken, 'deviceId': t.deviceId});
      final streamed = await _client.send(request).timeout(_timeout);
      res = await http.Response.fromStream(streamed).timeout(_timeout);
    } catch (e) {
      if (vorDemSenden(e)) throw ApiException.keineVerbindung; // Token unangetastet, später erneut versuchen
      // Unklar, ob der Server das Token eingelöst hat: nicht wiederholen, sondern neu anmelden
      await _verloren(SessionLostReason.unsicher, gen);
      throw const ApiException(
        kind: ApiErrorKind.nichtAngemeldet,
        status: 0,
        code: 'refresh_unsure',
        message: 'Die Verbindung brach beim Erneuern deiner Anmeldung ab. Bitte melde dich noch einmal an.',
      );
    }
    if (res.statusCode == 200) {
      // Wurde die Sitzung inzwischen beendet oder ersetzt (Abmelden, Personenwechsel), verfällt das Ergebnis: nichts zurückschreiben
      if (gen != _gen) throw _sitzungGeaendert;
      try {
        final daten = jsonDecode(utf8.decode(res.bodyBytes));
        final s = SessionDto.fromJson(asJson(daten)['session']);
        if (!s.istApp) throw ApiException.unerwarteteAntwort;
        await _sitzungSchreiben(s);
        return;
      } catch (_) {
        // Antwort unlesbar oder Speichern fehlgeschlagen: das alte Token ist verbraucht
        await _verloren(SessionLostReason.unsicher, gen);
        throw const ApiException(
          kind: ApiErrorKind.nichtAngemeldet,
          status: 0,
          code: 'refresh_unsure',
          message: 'Deine Anmeldung konnte nicht erneuert werden. Bitte melde dich noch einmal an.',
        );
      }
    }
    final code = _fehlercode(res);
    final retry = int.tryParse(res.headers['retry-after'] ?? '');
    final fehler = ApiException.vonAntwort(status: res.statusCode, code: code, retryAfterSekunden: retry);
    if (res.statusCode == 401 || res.statusCode == 400 || res.statusCode == 403 || res.statusCode == 404) {
      // Abgelehnt, weil eine andere Engine das Refresh-Token inzwischen eingelöst hat? Dann liegen neuere Token in der Ablage: übernehmen, nichts verwerfen.
      if (await _frischeUebernehmen(gen)) return;
      await _verloren(SessionLostReason.abgelaufen, gen);
      throw ApiException(kind: ApiErrorKind.nichtAngemeldet, status: res.statusCode, code: code, message: 'Deine Anmeldung ist abgelaufen. Bitte melde dich neu an.');
    }
    // 429/503/5xx: der Server hat das Token nicht eingelöst (Fehler vor der Verarbeitung bzw. Transaktion zurückgerollt)
    throw fehler;
  }

  static const _sitzungGeaendert = ApiException(
    kind: ApiErrorKind.nichtAngemeldet,
    status: 401,
    code: 'session_changed',
    message: 'Du bist nicht angemeldet.',
  );

  static String _fehlercode(http.Response res) {
    try {
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map && d['error'] is String) return d['error'] as String;
    } catch (_) {}
    return '';
  }
}
