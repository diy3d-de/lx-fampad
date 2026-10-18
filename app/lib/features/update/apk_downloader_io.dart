import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'apk_downloader.dart';

/// Lädt [url] nach `<Cache>/updates/update.apk` (Ordner passt zu update_paths.xml und MainActivity.kt),
/// prüft die Prüfsumme und gibt den Dateipfad zurück. Bei falscher Prüfsumme wird die Datei gelöscht.
Future<String> apkHerunterladen({
  required http.Client client,
  required Uri url,
  required String erwartetSha256,
  required int groesse,
  required FortschrittCallback onFortschritt,
}) async {
  final dir = Directory('${(await getApplicationCacheDirectory()).path}/updates');
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final file = File('${dir.path}/update.apk');

  final res = await client.send(http.Request('GET', url));
  if (res.statusCode != 200) throw Exception('Download fehlgeschlagen (HTTP ${res.statusCode})');
  final gesamt = res.contentLength ?? groesse;
  final sink = file.openWrite();
  final hashSink = _DigestSink();
  final hasher = sha256.startChunkedConversion(hashSink);
  var geladen = 0;
  await for (final chunk in res.stream) {
    sink.add(chunk);
    hasher.add(chunk);
    geladen += chunk.length;
    if (gesamt > 0) onFortschritt(geladen / gesamt);
  }
  await sink.close();
  hasher.close();
  if (hashSink.value.toString() != erwartetSha256) {
    await file.delete();
    throw Exception('Prüfsumme stimmt nicht - Download verworfen');
  }
  return file.path;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
