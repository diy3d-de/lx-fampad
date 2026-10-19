// HTTP-Client für Android (dart:io): trennt Verbindungsaufbau und Senden/Antwort.
//
// Scheitert schon das Öffnen der Verbindung (Adresse nicht auflösbar, Verbindung abgelehnt, Netz weg, TLS-Aushandlung, Zeitlimit
// beim Verbindungsaufbau), wurde noch kein Byte der Anfrage gesendet: das wirft [VerbindungsaufbauFehler]. Dann ist ein erneuter
// Versuch gefahrlos, auch beim Refresh-Token. Alles danach (Senden, Warten auf die Antwort) bleibt eine normale ClientException:
// ob der Server die Anfrage verarbeitet hat, ist dann unklar.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_error.dart';

/// Zeitlimit nur für den Verbindungsaufbau (kürzer als das Limit für die Antwort).
const kVerbindungsTimeout = Duration(seconds: 10);

http.Client neuerHttpClient() => PhasenClient(HttpClient()..connectionTimeout = kVerbindungsTimeout);

class PhasenClient extends http.BaseClient {
  HttpClient? _inner;
  PhasenClient(HttpClient inner) : _inner = inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final inner = _inner;
    if (inner == null) throw http.ClientException('Der HTTP-Client ist geschlossen.', request.url);
    final stream = request.finalize();

    // Phase 1: Verbindung öffnen. openUrl liefert erst, wenn die Verbindung (inkl. TLS) steht; gesendet ist dann noch nichts.
    final HttpClientRequest io;
    try {
      io = await inner.openUrl(request.method, request.url);
    } on SocketException catch (e) {
      throw VerbindungsaufbauFehler(e.message, request.url);
    } on HandshakeException catch (e) {
      throw VerbindungsaufbauFehler(e.message, request.url);
    } on TlsException catch (e) {
      throw VerbindungsaufbauFehler(e.message, request.url);
    } on TimeoutException {
      throw VerbindungsaufbauFehler('Zeitüberschreitung beim Verbindungsaufbau', request.url);
    }

    // Phase 2: senden und auf den Antwortkopf warten. Ab hier ist der Ausgang bei einem Fehler unklar.
    try {
      io
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..contentLength = request.contentLength ?? -1
        ..persistentConnection = request.persistentConnection;
      request.headers.forEach(io.headers.set);
      final antwort = await stream.pipe(io) as HttpClientResponse;
      final headers = <String, String>{};
      antwort.headers.forEach((name, werte) => headers[name] = werte.join(','));
      return http.StreamedResponse(
        antwort.handleError((Object e) => throw http.ClientException('$e', request.url), test: (e) => e is HttpException || e is SocketException),
        antwort.statusCode,
        contentLength: antwort.contentLength == -1 ? null : antwort.contentLength,
        request: request,
        headers: headers,
        isRedirect: antwort.isRedirect,
        persistentConnection: antwort.persistentConnection,
        reasonPhrase: antwort.reasonPhrase,
      );
    } on SocketException catch (e) {
      throw http.ClientException(e.message, request.url);
    } on HttpException catch (e) {
      throw http.ClientException(e.message, request.url);
    }
  }

  @override
  void close() {
    _inner?.close(force: true);
    _inner = null;
  }
}
