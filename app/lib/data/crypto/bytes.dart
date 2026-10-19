// Kleine Byte-Hilfen der Verschlüsselungs-Bibliothek: Base64url (ohne Auffüllzeichen, streng), Verketten, Vergleich.
import 'dart:convert';
import 'dart:typed_data';

import 'crypto_fehler.dart';

final _b64url = RegExp(r'^[A-Za-z0-9_-]+$');

/// Base64url ohne Auffüllzeichen (wie der Server es erwartet).
String base64urlKodieren(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Streng: nur Base64url-Zeichen, kanonische Form (kein Rest in den letzten Bits), sonst [CryptoFehler].
Uint8List base64urlDekodieren(String text) {
  if (text.isEmpty || !_b64url.hasMatch(text)) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültige Kodierung.');
  try {
    final bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(text)));
    if (base64urlKodieren(bytes) != text) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültige Kodierung.');
    return bytes;
  } on FormatException {
    throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültige Kodierung.');
  }
}

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List verketten(List<List<int>> teile) {
  final out = BytesBuilder(copy: false);
  for (final t in teile) {
    out.add(t);
  }
  return out.takeBytes();
}

/// Vier Byte, höchstwertiges zuerst.
Uint8List u32Bytes(int wert) {
  if (wert < 0 || wert > 0xFFFFFFFF) throw const CryptoFehler(CryptoFehlerArt.format, 'Zahl außerhalb des Bereichs.');
  return Uint8List(4)..buffer.asByteData().setUint32(0, wert, Endian.big);
}

int u32Lesen(Uint8List bytes, int offset) => bytes.buffer.asByteData(bytes.offsetInBytes).getUint32(offset, Endian.big);

/// Vergleich in konstanter Zeit (für Prüfsummen und Schlüssel).
bool gleicheBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Überschreibt die Bytes mit Nullen (best effort: Dart kann Kopien im Speicher nicht ausschließen).
void loescheBytes(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);
