// Eigener tus-Client (Abschnitt 6n, `docs/API.md` „Dateiablage“) auf dem ApiClient: tus 1.0.0 mit creation, expiration und termination (OPTIONS, POST, HEAD, PATCH, DELETE), Abschnitte von
// höchstens 4 MiB, Fortsetzen nach einem Abbruch über HEAD. Kein Fremdpaket: Anmeldung, Erneuerung des Zugangs (nur über den serialisierten Weg des ApiClient), CSRF und Zeitlimits laufen wie
// bei jeder Anfrage. Die Upload-ID ist zugleich die Blob-ID. Fehler des Servers werden in feste Kategorien mit verständlichen Meldungen übersetzt; nie Dateiinhalt, Dateiname oder URL loggen.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../api/api_client.dart';
import '../api/api_error.dart';
import 'datei_modelle.dart';
import 'upload_quelle.dart';

const String _tus = '1.0.0';
final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Wie geht es nach einem Fehler weiter?
enum TusFolge {
  /// Später (mit Wartezeit) erneut versuchen: Netz weg, Server überlastet, zu viele Anfragen, anderer Abschnitt läuft.
  spaeter,

  /// Den Upload NEU beginnen (der Server kennt ihn nicht mehr, z. B. nach 24 Stunden).
  neuBeginnen,

  /// Endgültig: die Person muss etwas ändern (zu groß, Speicher voll, ungültige Datei).
  aufgeben,
}

class TusFehler implements Exception {
  /// Fester Code (`quota_exceeded`, `file_too_large`, `network`, …); nie ein Text des Servers.
  final String code;
  final String meldung;
  final TusFolge folge;
  final int status;
  final Duration? warte;
  const TusFehler(this.code, this.meldung, this.folge, {this.status = 0, this.warte});

  @override
  String toString() => meldung;

  /// Übersetzt eine Antwort des Servers.
  factory TusFehler.vonAntwort(RohAntwort a) {
    final code = a.fehlerCode;
    final w = a.wartezeit;
    switch (a.status) {
      case 413:
        return code == 'quota_exceeded'
            ? TusFehler('quota_exceeded', 'Der Speicher der Familie ist voll.', TusFolge.aufgeben, status: 413)
            : TusFehler('file_too_large', 'Die Datei ist größer als erlaubt (höchstens 100 MB).', TusFolge.aufgeben, status: 413);
      case 507:
        return const TusFehler('insufficient_storage', 'Auf dem Server ist gerade kein Platz mehr. Bitte melde dich bei der Person, die den Server betreut.', TusFolge.aufgeben, status: 507);
      case 422:
        return const TusFehler('invalid_file', 'Der Server hat die Datei abgelehnt (der Dateityp passt nicht zum Inhalt).', TusFolge.aufgeben, status: 422);
      case 423:
        return TusFehler('locked', 'Der Upload wird gerade von einem anderen Vorgang bearbeitet.', TusFolge.spaeter, status: 423, warte: w ?? const Duration(seconds: 1));
      case 429:
        return TusFehler(code.isEmpty ? 'rate_limited' : code, 'Zu viele Uploads auf einmal. Es geht gleich weiter.', TusFolge.spaeter, status: 429, warte: w);
      case 503:
        if (code == 'maintenance') return TusFehler('maintenance', kWartungMeldung, TusFolge.spaeter, status: 503, warte: w);
        return TusFehler(code.isEmpty ? 'server_busy' : code, 'Der Server ist gerade ausgelastet. Es geht später weiter.', TusFolge.spaeter, status: 503, warte: w);
      case 404:
        return const TusFehler('not_found', 'Der Upload ist nicht mehr da und wird neu begonnen.', TusFolge.neuBeginnen, status: 404);
      case 401:
        return const TusFehler('unauthenticated', 'Du bist nicht angemeldet.', TusFolge.spaeter, status: 401);
      case 412:
      case 400:
        return TusFehler(code.isEmpty ? 'invalid_request' : code, 'Der Server hat die Anfrage abgelehnt. Vielleicht ist ein Update der App nötig.', TusFolge.aufgeben, status: a.status);
      case 409:
        return TusFehler(code.isEmpty ? 'conflict' : code, 'Der Upload ist durcheinandergekommen und wird neu angesetzt.', TusFolge.spaeter, status: 409);
      default:
        if (a.status >= 500) return TusFehler('server_error', 'Auf dem Server ist ein Fehler aufgetreten. Es geht später weiter.', TusFolge.spaeter, status: a.status, warte: w);
        return TusFehler(code.isEmpty ? 'unexpected' : code, 'Der Upload hat nicht geklappt.', TusFolge.aufgeben, status: a.status);
    }
  }

  /// Kein Netz oder Zeitüberschreitung (aus [ApiException]).
  factory TusFehler.netz(ApiException e) => TusFehler(e.code.isEmpty ? 'network' : e.code, e.message, TusFolge.spaeter);
}

/// Stand eines Uploads beim Server (HEAD).
class TusStatus {
  final int offset;
  final int laenge;
  const TusStatus(this.offset, this.laenge);
  bool get fertig => laenge > 0 && offset >= laenge;
}

/// Ergebnis eines fertigen Uploads: die Blob-ID (= Upload-ID) und die SHA-256 (Hex), die der Server beim Abschluss nannte (null, wenn nur ein HEAD abgeschlossen hat).
class TusErgebnis {
  final String blobId;
  final String? sha256;
  const TusErgebnis(this.blobId, this.sha256);
}

/// Abbruch eines laufenden Uploads (zwischen zwei Abschnitten wirksam).
class AbbruchToken {
  bool _abgebrochen = false;
  bool get abgebrochen => _abgebrochen;
  void abbrechen() => _abgebrochen = true;
}

/// Der Upload wurde abgebrochen (kein Fehler des Servers).
class TusAbgebrochen implements Exception {
  const TusAbgebrochen();
}

class TusClient {
  final ApiClient api;

  /// Abschnittsgröße (höchstens 4 MiB, sonst lehnt der Server mit 413 ab).
  final int abschnitt;
  final Duration zeitlimit;
  final Future<void> Function(Duration) _schlaf;

  TusClient(this.api, {int abschnitt = kTusAbschnittBytes, this.zeitlimit = const Duration(minutes: 2), Future<void> Function(Duration)? schlaf})
    : abschnitt = abschnitt > kTusAbschnittBytes ? kTusAbschnittBytes : (abschnitt < 1 ? 1 : abschnitt),
      _schlaf = schlaf ?? Future<void>.delayed;

  static const String _basis = '/uploads';
  static Map<String, String> get _kopf => const {'tus-resumable': _tus};

  Future<RohAntwort> _senden(String methode, String pfad, {Uint8List? bytes, String? contentType, Map<String, String> kopf = const {}}) async {
    try {
      return await api.roh(methode, pfad, bytes: bytes, contentType: contentType, kopf: {..._kopf, ...kopf}, zeitlimit: zeitlimit);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.nichtAngemeldet) rethrow; // Sitzung weg: der Aufrufer behandelt es wie überall
      throw TusFehler.netz(e);
    }
  }

  /// `Upload-Metadata`: `schlüssel base64wert,…` (Schlüssel ohne Leerzeichen und Komma; der Wert Standard-Base64).
  static String metadatenKopf(Map<String, String> m) => [for (final e in m.entries) '${e.key} ${base64.encode(utf8.encode(e.value))}'].join(',');

  /// OPTIONS: `Tus-Max-Size` des Servers (null, wenn nicht genannt). Nur eine Auskunft, kein Pflicht-Schritt.
  Future<int?> maxGroesse() async {
    final a = await _senden('OPTIONS', _basis);
    if (a.status != 204 && a.status != 200) throw TusFehler.vonAntwort(a);
    return int.tryParse(a.kopfzeile('tus-max-size') ?? '');
  }

  /// POST: legt einen Upload an; liefert die Upload-ID (= Blob-ID). [metadaten]: `modus` (`server`/`e2ee`), `kind` (`datei`/`thumb`/`opak`), `mime`.
  Future<String> anlegen({required int laenge, Map<String, String> metadaten = const {}}) async {
    if (laenge <= 0) throw const TusFehler('empty', 'Die Datei ist leer.', TusFolge.aufgeben);
    final a = await _senden(
      'POST',
      _basis,
      kopf: {'upload-length': '$laenge', if (metadaten.isNotEmpty) 'upload-metadata': metadatenKopf(metadaten)},
    );
    if (a.status != 201) throw TusFehler.vonAntwort(a);
    final ort = a.kopfzeile('location') ?? '';
    final id = ort.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';
    if (!_uuid.hasMatch(id)) throw const TusFehler('protocol', 'Die Antwort des Servers war unerwartet. Vielleicht ist ein Update der App nötig.', TusFolge.aufgeben, status: 201);
    return id.toLowerCase();
  }

  /// HEAD: Stand beim Server (zum Fortsetzen). Ein beim Abschluss unterbrochener Upload wird dabei vom Server erneut abgeschlossen.
  Future<TusStatus> status(String id) async {
    final a = await _senden('HEAD', '$_basis/$id');
    if (a.status != 200 && a.status != 204) throw TusFehler.vonAntwort(a);
    final offset = int.tryParse(a.kopfzeile('upload-offset') ?? '');
    final laenge = int.tryParse(a.kopfzeile('upload-length') ?? '');
    if (offset == null || laenge == null || offset < 0 || laenge < 0) throw const TusFehler('protocol', 'Die Antwort des Servers war unerwartet. Vielleicht ist ein Update der App nötig.', TusFolge.aufgeben, status: 200);
    return TusStatus(offset, laenge);
  }

  /// DELETE: bricht den Upload beim Server ab (Staging weg). Fehler, die nichts mehr zu löschen heißen (404), zählen als erledigt; ein schon beanspruchter Blob (409) bleibt unberührt.
  Future<void> abbrechen(String id) async {
    final a = await _senden('DELETE', '$_basis/$id');
    if (a.status == 204 || a.status == 200 || a.status == 404) return;
    if (a.status == 409) return; // `upload_claimed`: wird schon verwendet, nichts zu tun
    throw TusFehler.vonAntwort(a);
  }

  /// Lädt [quelle] ab [ab] hoch (nach einem Neustart: [ab] aus [status]). [fortschritt] bekommt den bestätigten Stand. Liefert das Ergebnis beim letzten Byte. Bei `409` (anderer Versatz) richtet sich der
  /// Client nach dem Stand des Servers (höchstens 5 Mal hintereinander), bei `423` (anderer Abschnitt läuft) wartet er kurz, bei `503 finalize_failed` schließt er erneut ab (höchstens 5 Mal).
  Future<TusErgebnis> hochladen(String id, UploadQuelle quelle, {int ab = 0, void Function(int)? fortschritt, AbbruchToken? abbruch}) async {
    final laenge = quelle.laenge;
    var offset = ab;
    var versatz = 0;
    var gesperrt = 0;
    while (true) {
      if (abbruch?.abgebrochen ?? false) throw const TusAbgebrochen();
      if (offset >= laenge) return _abschliessen(id, laenge);
      final ende = offset + abschnitt > laenge ? laenge : offset + abschnitt;
      final bytes = await quelle.lies(offset, ende);
      final a = await _senden('PATCH', '$_basis/$id', bytes: bytes, contentType: 'application/offset+octet-stream', kopf: {'upload-offset': '$offset'});
      if (a.status == 204 || a.status == 200) {
        final neu = int.tryParse(a.kopfzeile('upload-offset') ?? '');
        if (neu == null || neu < offset || neu > laenge) throw const TusFehler('protocol', 'Die Antwort des Servers war unerwartet. Vielleicht ist ein Update der App nötig.', TusFolge.aufgeben, status: 204);
        versatz = 0;
        gesperrt = 0;
        offset = neu;
        fortschritt?.call(offset);
        if (offset >= laenge) {
          final blob = a.kopfzeile('upload-blob-id');
          if (blob != null && _uuid.hasMatch(blob)) return TusErgebnis(blob.toLowerCase(), a.kopfzeile('upload-sha256'));
          return _abschliessen(id, laenge);
        }
        continue;
      }
      if (a.status == 409) {
        if (a.fehlerCode == 'upload_done') return _abschliessen(id, laenge);
        final serverOffset = int.tryParse(a.kopfzeile('upload-offset') ?? '');
        if (serverOffset == null || serverOffset > laenge || ++versatz > 5) throw TusFehler.vonAntwort(a);
        offset = serverOffset;
        continue;
      }
      if (a.status == 423 && ++gesperrt <= 3) {
        await _schlaf(const Duration(seconds: 1));
        offset = (await status(id)).offset;
        continue;
      }
      if (a.status == 503 && a.fehlerCode == 'finalize_failed') return _abschliessen(id, laenge);
      throw TusFehler.vonAntwort(a);
    }
  }

  /// Schließt einen vollständig übertragenen Upload ab: leeres PATCH mit `Upload-Offset` = Länge (nach `503 finalize_failed` ist er abschließbar); bei `409 upload_done` ist er schon fertig.
  Future<TusErgebnis> _abschliessen(String id, int laenge) async {
    for (var versuch = 0; versuch < 5; versuch++) {
      final a = await _senden('PATCH', '$_basis/$id', bytes: Uint8List(0), contentType: 'application/offset+octet-stream', kopf: {'upload-offset': '$laenge'});
      if (a.status == 204 || a.status == 200) {
        final blob = a.kopfzeile('upload-blob-id');
        return TusErgebnis(blob != null && _uuid.hasMatch(blob) ? blob.toLowerCase() : id, a.kopfzeile('upload-sha256'));
      }
      if (a.status == 409 && a.fehlerCode == 'upload_done') return TusErgebnis(id, null);
      if (a.status == 503 && a.fehlerCode == 'finalize_failed') {
        await _schlaf(Duration(seconds: 1 << versuch));
        continue;
      }
      throw TusFehler.vonAntwort(a);
    }
    throw const TusFehler('finalize_failed', 'Der Server kann die Datei gerade nicht fertigstellen. Es geht später weiter.', TusFolge.spaeter, status: 503);
  }
}
