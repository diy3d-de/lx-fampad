// Gut lesbare Darstellung eines 32-Byte-Geheimnisses für Wiederherstellungsschlüssel und Übertragungscode: Base32 (RFC 4648, A-Z und 2-7)
// in Vierergruppen, mit 3 Byte Prüfsumme (SHA-256 mit Verwendungszweck). 32 + 3 Byte = 56 Zeichen = 14 Gruppen. Beim Eintippen sind Groß-/Kleinschreibung,
// Leerzeichen und Bindestriche egal; 0, 1 und 8 werden als O, I und B gelesen. Die Prüfsumme erkennt Tippfehler und verwechselte Codes
// (Wiederherstellungsschlüssel und Übertragungscode haben verschiedene Zwecke und damit verschiedene Prüfsummen).
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'bytes.dart';
import 'crypto_fehler.dart';

const String _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const int kGeheimnisLaenge = 32;
const int _pruefLaenge = 3;
const int kCodeZeichen = 56;
const int kCodeGruppen = 14;

String _base32(Uint8List bytes) {
  final out = StringBuffer();
  var puffer = 0;
  var bits = 0;
  for (final b in bytes) {
    puffer = (puffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(puffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    puffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(puffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List? _ausBase32(String text) {
  final out = BytesBuilder();
  var puffer = 0;
  var bits = 0;
  for (final z in text.codeUnits) {
    final i = _alphabet.indexOf(String.fromCharCode(z));
    if (i < 0) return null;
    puffer = (puffer << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.addByte((puffer >> (bits - 8)) & 255);
      bits -= 8;
    }
    puffer &= (1 << bits) - 1;
  }
  // übrige Bits müssen null sein (kanonische Form)
  if (puffer != 0) return null;
  return out.takeBytes();
}

Uint8List _pruefsumme(String zweck, Uint8List geheimnis) =>
    Uint8List.fromList(c.sha256.convert([...utf8Bytes(zweck), 0, ...geheimnis]).bytes.sublist(0, _pruefLaenge));

/// Der Verwendungszweck (z. B. 'lx-fampad|wiederherstellung|v1') geht in die Prüfsumme ein, damit ein Code nur für seinen Zweck gilt.
class Code32 {
  /// Darstellung in Vierergruppen mit Bindestrichen (z. B. `ABCD-EFGH-...`, 14 Gruppen).
  static String kodieren(Uint8List geheimnis, String zweck, {bool gruppiert = true}) {
    if (geheimnis.length != kGeheimnisLaenge) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    final roh = _base32(verketten([geheimnis, _pruefsumme(zweck, geheimnis)]));
    if (!gruppiert) return roh;
    return gruppen(roh).join('-');
  }

  static List<String> gruppen(String roh) => [for (var i = 0; i < roh.length; i += 4) roh.substring(i, i + 4 > roh.length ? roh.length : i + 4)];

  /// Normalisiert eine Eingabe: Großbuchstaben, ohne Leerzeichen und Bindestriche, 0/1/8 als O/I/B.
  static String normalisieren(String eingabe) =>
      eingabe.toUpperCase().replaceAll(RegExp(r'[\s\-_]'), '').replaceAll('0', 'O').replaceAll('1', 'I').replaceAll('8', 'B');

  /// Liest die Eingabe; wirft [CryptoFehler] (format bei falscher Länge/Zeichen, pruefsumme bei Tippfehlern).
  static Uint8List dekodieren(String eingabe, String zweck) {
    final roh = normalisieren(eingabe);
    if (roh.length != kCodeZeichen) throw const CryptoFehler(CryptoFehlerArt.format, 'Der Code hat nicht die richtige Länge.');
    final bytes = _ausBase32(roh);
    if (bytes == null || bytes.length != kGeheimnisLaenge + _pruefLaenge) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Der Code enthält ungültige Zeichen.');
    }
    final geheimnis = Uint8List.sublistView(bytes, 0, kGeheimnisLaenge);
    if (!gleicheBytes(Uint8List.sublistView(bytes, kGeheimnisLaenge), _pruefsumme(zweck, geheimnis))) {
      throw const CryptoFehler(CryptoFehlerArt.pruefsumme, 'Die Prüfsumme stimmt nicht: Hast du dich vertippt?');
    }
    return Uint8List.fromList(geheimnis);
  }
}
