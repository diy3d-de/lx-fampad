// Ende-zu-Ende-verschlüsselte Blobs (Abschnitt 6n, Modus `e2ee`; erster Nutzer: Anhänge im Tresor): die Datei wird auf dem Gerät mit einem ZUFÄLLIGEN Schlüssel je Datei (32 Byte) verschlüsselt, der
// Server bekommt nur Chiffretext (kein Typ, kein Name, kein Schlüssel). Verschlüsselt wird mit libsodium secretstream (XChaCha20-Poly1305) über den vorhandenen CryptoProvider, KEINE eigenen Primitive.
//
// Format (versioniert): `version (1 Byte, 1) | secretstream-Kopfzeile (24 Byte) | Blöcke`, jeder Block höchstens 64 KiB Klartext + 17 Byte; der letzte Block trägt das Kennzeichen FINAL (ein gekürzter
// oder verlängerter Chiffretext, vertauschte Blöcke oder ein falscher Schlüssel schlagen fehl). Der Dateischlüssel steht NUR im verschlüsselten Inhalt des Datensatzes (e1-Hülle), die Prüfsumme dort
// ist die SHA-256 der übertragenen Bytes (so sieht die App, dass der Server dieselben Bytes liefert, die sie hochgeladen hat; der Server nennt sie beim Abschluss ebenfalls).
// Größe: Klartext + Overhead muss in `maxE2eeBytes` aus `GET /files/usage` passen ([e2eeKlartextMax]). Entschlüsselt wird nur im Arbeitsspeicher; Schlüssel und Klartext werden nach der Benutzung überschrieben.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';

/// Formatkennung des Blobs (erstes Byte).
const int kE2eeFormat = 1;

/// Klartext je Block (64 KiB), Kopfzeile des secretstream und Zusatz je Block (libsodium: `crypto_secretstream_xchacha20poly1305_ABYTES` = 17).
const int kE2eeBlockBytes = 65536;
const int kE2eeStromKopf = 24;
const int kE2eeBlockZusatz = 17;
const int kE2eeSchluesselBytes = 32;

int _bloecke(int klartextBytes) => klartextBytes <= 0 ? 1 : (klartextBytes + kE2eeBlockBytes - 1) ~/ kE2eeBlockBytes;

/// Größe des Chiffretexts zu einem Klartext von [klartextBytes] Byte (inklusive Format-Byte, Kopfzeile und Block-Zusatz).
int e2eeGroesse(int klartextBytes) => 1 + kE2eeStromKopf + klartextBytes + kE2eeBlockZusatz * _bloecke(klartextBytes);

/// Größter Klartext, dessen Chiffretext noch in [maxE2eeBytes] passt (0, wenn gar keiner).
int e2eeKlartextMax(int maxE2eeBytes) {
  var klein = 0;
  var gross = maxE2eeBytes;
  if (e2eeGroesse(0) > maxE2eeBytes) return 0;
  while (klein < gross) {
    final mitte = (klein + gross + 1) ~/ 2;
    if (e2eeGroesse(mitte) <= maxE2eeBytes) {
      klein = mitte;
    } else {
      gross = mitte - 1;
    }
  }
  return klein;
}

/// SHA-256 als Hex-Text (zum Vergleich mit `Upload-Sha256` des Servers und für die Prüfsumme im Inhalt).
String sha256Hex(Uint8List bytes) => c.sha256.convert(bytes).toString();

/// Ein verschlüsselter Blob: die Bytes für den Upload, der Dateischlüssel (nur für den verschlüsselten Inhalt des Datensatzes) und die SHA-256 der Bytes.
class E2eeBlob {
  final Uint8List chiffretext;
  final Uint8List schluessel;
  final String sha256;
  const E2eeBlob(this.chiffretext, this.schluessel, this.sha256);

  int get groesse => chiffretext.length;

  /// Überschreibt den Dateischlüssel (nach dem Verpacken in den Inhalt des Datensatzes).
  void schluesselVergessen() => schluessel.fillRange(0, schluessel.length, 0);
}

class E2eeBlobHelfer {
  final Future<CryptoProvider> Function() _crypto;

  /// Mit einem fertigen CryptoProvider (Tests) oder, über [E2eeBlobHelfer.spaet], einem, der erst geladen wird (libsodium lädt asynchron).
  E2eeBlobHelfer(CryptoProvider crypto) : _crypto = (() async => crypto);
  E2eeBlobHelfer.spaet(this._crypto);

  /// Verschlüsselt [klartext] mit einem frischen Zufallsschlüssel (oder [schluessel], nur für Tests). Wirft [CryptoFehler] bei einem Fehler der Bausteine.
  Future<E2eeBlob> verschluesseln(Uint8List klartext, {Uint8List? schluessel}) async {
    final crypto = await _crypto();
    final key = schluessel ?? crypto.zufall(kE2eeSchluesselBytes);
    if (key.length != kE2eeSchluesselBytes) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    final strom = await crypto.stromVerschluesseln(schluessel: key, klartext: klartext, blockBytes: kE2eeBlockBytes);
    final raus = Uint8List(1 + strom.length)
      ..[0] = kE2eeFormat
      ..setRange(1, 1 + strom.length, strom);
    return E2eeBlob(raus, key, sha256Hex(raus));
  }

  /// Entschlüsselt einen Blob. Wirft [CryptoFehler] (entschluesselung), wenn Schlüssel, Format oder Inhalt nicht passen (auch bei Manipulation, Kürzen oder Vertauschen). Ist [erwarteteSha256] angegeben,
  /// muss die Prüfsumme der Bytes passen (sonst derselbe Fehler, noch vor dem Entschlüsseln). Der Aufrufer überschreibt den Klartext nach der Benutzung.
  Future<Uint8List> entschluesseln({required Uint8List chiffretext, required Uint8List schluessel, String? erwarteteSha256}) async {
    const fehler = CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    if (chiffretext.length < 1 + kE2eeStromKopf + kE2eeBlockZusatz || chiffretext[0] != kE2eeFormat) throw fehler;
    if (erwarteteSha256 != null && erwarteteSha256.toLowerCase() != sha256Hex(chiffretext)) throw fehler;
    return (await _crypto()).stromEntschluesseln(schluessel: schluessel, chiffretext: Uint8List.sublistView(chiffretext, 1), blockBytes: kE2eeBlockBytes);
  }
}
