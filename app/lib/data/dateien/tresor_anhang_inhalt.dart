// Inhalt eines Tresor-Anhangs (Abschnitt 6n): Klartext `f1:` + JSON, im Datensatz nur als e1-Hülle der Art `f` (`inhalt`, vom Client verschlüsselt, höchstens 4096 Zeichen laut Server). Er enthält
// Name, Typ und Größe der Datei, den ZUFÄLLIGEN Dateischlüssel (32 Byte), die SHA-256 der übertragenen (verschlüsselten) Bytes und die Zuordnung zum Tresor-Eintrag. Der Server sieht davon nichts.
// Unbekannte Versionen und kaputte Daten ergeben null (nicht lesbar), nie einen Absturz und nie einen Teilinhalt.
import 'dart:convert';
import 'dart:typed_data';

import '../chat/chat_krypto.dart' show kMaxAnhangKlartextBytes;
import '../crypto/bytes.dart';
import '../crypto/crypto_fehler.dart';
import 'datei_logik.dart';
import 'datei_modelle.dart' show DateiFehler;
import 'e2ee_blob.dart';
export '../crypto/huellen_arten.dart' show kArtAnhang;

/// Typpräfix des Klartexts (nach dem Hüllenpräfix `l1:` bzw. nach dem Öffnen der Hülle).
const String kPraefixAnhang = 'f1:';

/// Art im AAD der Hülle (`HuellenKontext.art`): Tresor-Anhang `f`. Eine Hülle lässt sich nie als andere Art lesen.

/// Version des Klartext-Formats (Feld `v`).
const int kAnhangFormat = 1;

/// Mehr Anhänge nimmt der Server je Tresor nicht an.
const int kMaxTresorAnhaenge = 200;

class AnhangInhalt {
  final String name;
  final String? mime;

  /// Größe des Klartexts (der Datei) in Byte.
  final int groesse;

  /// Dateischlüssel (32 Byte); der Aufrufer überschreibt ihn nach der Benutzung ([vergessen]).
  final Uint8List schluessel;

  /// SHA-256 (Hex) der übertragenen Bytes (Chiffretext).
  final String sha256;

  /// Der Tresor-Eintrag, zu dem der Anhang gehört (ID aus `tresor_eintrag`); null: gehört zu keinem Eintrag.
  final String? eintragId;
  const AnhangInhalt({required this.name, required this.mime, required this.groesse, required this.schluessel, required this.sha256, required this.eintragId});

  void vergessen() => schluessel.fillRange(0, schluessel.length, 0);
}

/// Der Klartext für die Hülle; wirft [DateiFehler] bei einem ungültigen Namen und [CryptoFehler] (format), wenn er für die Hülle zu groß wäre.
String anhangKodieren(AnhangInhalt a) {
  final name = bereinigeName(a.name);
  if (name == null) throw DateiFehler.nameUngueltig;
  if (a.schluessel.length != kE2eeSchluesselBytes || a.groesse < 0 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(a.sha256)) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültiger Anhang.');
  final text = '$kPraefixAnhang${jsonEncode({
    'v': kAnhangFormat,
    'n': name,
    'm': a.mime,
    's': a.groesse,
    'k': base64urlKodieren(a.schluessel),
    'h': a.sha256,
    'e': a.eintragId,
  })}';
  if (utf8.encode(text).length > kMaxAnhangKlartextBytes) throw const CryptoFehler(CryptoFehlerArt.format, 'Der Anhang ist zu groß für die Hülle.');
  return text;
}

/// Liest den Klartext (mit `f1:`); null bei unbekannter Version, fehlenden oder falschen Feldern.
AnhangInhalt? anhangLesen(String text) {
  if (!text.startsWith(kPraefixAnhang)) return null;
  try {
    final j = jsonDecode(text.substring(kPraefixAnhang.length));
    if (j is! Map<String, dynamic> || j['v'] != kAnhangFormat) return null;
    final n = j['n'];
    final s = j['s'];
    final k = j['k'];
    final h = j['h'];
    final m = j['m'];
    final e = j['e'];
    if (n is! String || n.isEmpty || s is! int || s < 0 || k is! String || h is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) return null;
    if (m != null && m is! String) return null;
    if (e != null && e is! String) return null;
    final schluessel = base64urlDekodieren(k);
    if (schluessel.length != kE2eeSchluesselBytes) return null;
    return AnhangInhalt(name: n, mime: m as String?, groesse: s, schluessel: schluessel, sha256: h, eintragId: e as String?);
  } on Object {
    return null;
  }
}
