// Lädt einen Blob in den ARBEITSSPEICHER (Abschnitte von 4 MiB per Range, über den ApiClient mit Anmeldung und Erneuerung): für Vorschaubilder (höchstens 256 KiB) und für verschlüsselte Anhänge
// (Chiffretext, den die App im Speicher entschlüsselt; nie eine Datei im Cache, nie Klartext auf der Platte). Fehler des Servers erscheinen als [TusFehler] mit festen Meldungen (404 = keine Sicht oder
// nicht mehr da). Nie Namen oder Inhalte loggen.
import 'dart:math' as math;
import 'dart:typed_data';

import '../api/api_client.dart';
import '../api/api_error.dart';
import 'datei_modelle.dart';
import 'tus_client.dart';

class BlobLader {
  final ApiClient api;
  const BlobLader(this.api);

  Future<RohAntwort> _teil(String blobId, int von, int bis) async {
    try {
      return await api.roh('GET', '/files/blobs/$blobId', kopf: {'range': 'bytes=$von-$bis', 'accept': '*/*'}, zeitlimit: const Duration(minutes: 2));
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.nichtAngemeldet) rethrow;
      throw TusFehler.netz(e);
    }
  }

  /// Lädt einen kleinen Blob, dessen Größe die App nicht kennt (ein Vorschaubild, höchstens [maxBytes]), mit EINER Anfrage ohne Range.
  Future<Uint8List> ladenGanz(String blobId, int maxBytes) async {
    final RohAntwort a;
    try {
      a = await api.roh('GET', '/files/blobs/$blobId', kopf: const {'accept': '*/*'}, zeitlimit: const Duration(minutes: 1));
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.nichtAngemeldet) rethrow;
      throw TusFehler.netz(e);
    }
    if (a.status != 200) throw TusFehler.vonAntwort(a);
    if (a.bytes.isEmpty || a.bytes.length > maxBytes) throw const TusFehler('file_too_large', 'Die Datei ist größer als erlaubt.', TusFolge.aufgeben);
    return a.bytes;
  }

  /// Lädt den ganzen Blob der Größe [groesse] (aus dem Datensatz bekannt; mehr als [maxBytes] werden nie geladen). [fortschritt] bekommt die Zahl der geladenen Byte.
  Future<Uint8List> laden(String blobId, int groesse, {int maxBytes = kStandardMaxE2eeBytes, void Function(int)? fortschritt}) async {
    if (groesse <= 0 || groesse > maxBytes) throw const TusFehler('file_too_large', 'Die Datei ist größer als erlaubt.', TusFolge.aufgeben);
    final raus = BytesBuilder(copy: false);
    var offset = 0;
    var neu = 0;
    while (offset < groesse) {
      final ende = math.min(offset + kTusAbschnittBytes, groesse) - 1;
      final a = await _teil(blobId, offset, ende);
      if (a.status == 206) {
        final cr = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(a.kopfzeile('content-range') ?? '');
        if (cr == null || int.parse(cr.group(1)!) != offset || a.bytes.isEmpty) throw const TusFehler('protocol', 'Die Antwort des Servers war unerwartet.', TusFolge.spaeter);
        raus.add(a.bytes);
        offset += a.bytes.length;
      } else if (a.status == 200 && offset == 0 && a.bytes.length == groesse) {
        raus.add(a.bytes); // der Server hat Range ignoriert
        offset = a.bytes.length;
      } else if (a.status == 416 && ++neu <= 2) {
        raus.clear();
        offset = 0;
      } else {
        throw TusFehler.vonAntwort(a);
      }
      fortschritt?.call(offset);
    }
    final bytes = raus.takeBytes();
    if (bytes.length != groesse) throw const TusFehler('protocol', 'Die Antwort des Servers war unerwartet.', TusFolge.spaeter);
    return bytes;
  }
}
