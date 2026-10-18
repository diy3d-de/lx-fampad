import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../constants.dart';
import 'apk_downloader.dart';

/// Lädt [url] nach `<Cache>/updates/update.apk` (Ordner passt zu MainActivity.kt), prüft Größe und Prüfsumme und
/// gibt den Dateipfad zurück. Bei jedem Fehler (auch bei zu großem Download) wird die Datei gelöscht.
/// [groesse] stammt aus dem signierten Manifest und ist zugleich die Obergrenze.
Future<String> apkHerunterladen({
  required http.Client client,
  required Uri url,
  required String erwartetSha256,
  required int groesse,
  required FortschrittCallback onFortschritt,
}) async {
  if (groesse < 1 || groesse > kMaxApkBytes) throw Exception('Update-Größe ungültig');
  final dir = Directory('${(await getApplicationCacheDirectory()).path}/updates');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final file = File('${dir.path}/update.apk');

  final res = await client.send(http.Request('GET', url)).timeout(const Duration(seconds: 30));
  if (res.statusCode != 200) {
    await _verwerfen(res);
    throw Exception('Download fehlgeschlagen (HTTP ${res.statusCode})');
  }
  final angekuendigt = res.contentLength;
  if (angekuendigt != null && angekuendigt > groesse) {
    await _verwerfen(res);
    throw Exception('Download ist größer als im Manifest angegeben');
  }

  final hashSink = _DigestSink();
  final hasher = sha256.startChunkedConversion(hashSink);
  IOSink? sink;
  var geladen = 0;
  try {
    sink = file.openWrite();
    await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
      geladen += chunk.length;
      if (geladen > groesse) throw Exception('Download ist größer als im Manifest angegeben');
      sink.add(chunk);
      hasher.add(chunk);
      onFortschritt(geladen / groesse);
    }
    await sink.flush();
  } catch (_) {
    await _loescheLeise(sink, file);
    rethrow;
  } finally {
    await sink?.close().catchError((_) {});
  }
  hasher.close();
  if (geladen != groesse) {
    await _loescheLeise(null, file);
    throw Exception('Download unvollständig - verworfen');
  }
  if (hashSink.value.toString() != erwartetSha256) {
    await _loescheLeise(null, file);
    throw Exception('Prüfsumme stimmt nicht - Download verworfen');
  }
  return file.path;
}

/// Berechnet die SHA-256-Prüfsumme der Datei neu und vergleicht sie; bei Abweichung wird die Datei gelöscht.
/// Wird unmittelbar vor der Installation aufgerufen (der Cache-Ordner könnte seit dem Download verändert worden sein).
Future<bool> apkPruefsummeStimmt(String pfad, String erwartetSha256) async {
  final file = File(pfad);
  if (!await file.exists()) return false;
  final digest = await sha256.bind(file.openRead()).first;
  if (digest.toString() == erwartetSha256) return true;
  await _loescheLeise(null, file);
  return false;
}

/// Gibt eine nicht benötigte Antwort frei, ohne den Rumpf zu lesen.
Future<void> _verwerfen(http.StreamedResponse res) async {
  try {
    await res.stream.listen((_) {}).cancel();
  } catch (_) {
    // schon beendet
  }
}

Future<void> _loescheLeise(IOSink? sink, File file) async {
  try {
    await sink?.close();
  } catch (_) {
    // egal, die Datei wird gelöscht
  }
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // egal
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
