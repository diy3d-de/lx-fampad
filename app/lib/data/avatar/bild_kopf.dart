// Maße einer Bilddatei aus dem Dateikopf (PNG, JPEG, WebP), ohne zu dekodieren. Die App prüft damit VOR dem Dekodieren, ob ein Bild
// zu groß ist (Speicherbombe: kleine Datei, behauptete 30000 x 30000 Pixel). Gegenstück zu server/src/avatar/image.ts.
import 'dart:typed_data';

class BildMasse {
  final String mime;
  final int breite;
  final int hoehe;
  const BildMasse(this.mime, this.breite, this.hoehe);
}

/// Liest Typ und Maße; null bei unbekanntem Typ oder kaputtem Kopf. Animierte PNG/WebP werden nicht erkannt (null).
BildMasse? bildMasse(Uint8List b) {
  final d = ByteData.sublistView(b);
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47 && b[4] == 0x0d && b[5] == 0x0a && b[6] == 0x1a && b[7] == 0x0a) {
    if (d.getUint32(8) != 13 || _text(b, 12, 4) != 'IHDR') return null;
    return BildMasse('image/png', d.getUint32(16), d.getUint32(20));
  }
  if (b.length >= 4 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return _jpeg(b, d);
  if (b.length >= 30 && _text(b, 0, 4) == 'RIFF' && _text(b, 8, 4) == 'WEBP') return _webp(b, d);
  return null;
}

String _text(Uint8List b, int von, int n) => String.fromCharCodes(b.sublist(von, von + n));

BildMasse? _jpeg(Uint8List b, ByteData d) {
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xff) return null;
    final marker = b[i + 1];
    if (marker == 0xff) {
      i += 1;
      continue;
    }
    if (marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    if (marker == 0xd9 || marker == 0xda) return null;
    final len = d.getUint16(i + 2);
    if (len < 2) return null;
    final sof = marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
    if (sof) {
      if (i + 9 > b.length) return null;
      return BildMasse('image/jpeg', d.getUint16(i + 7), d.getUint16(i + 5));
    }
    i += 2 + len;
  }
  return null;
}

BildMasse? _webp(Uint8List b, ByteData d) {
  final chunk = _text(b, 12, 4);
  if (chunk == 'VP8 ') {
    if (b[23] != 0x9d || b[24] != 0x01 || b[25] != 0x2a) return null;
    return BildMasse('image/webp', d.getUint16(26, Endian.little) & 0x3fff, d.getUint16(28, Endian.little) & 0x3fff);
  }
  if (chunk == 'VP8L') {
    if (b[20] != 0x2f) return null;
    final bits = d.getUint32(21, Endian.little);
    return BildMasse('image/webp', (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
  }
  if (chunk == 'VP8X') {
    if (b[20] & 0x02 != 0) return null; // animiert
    int u24(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);
    return BildMasse('image/webp', u24(24) + 1, u24(27) + 1);
  }
  return null;
}
