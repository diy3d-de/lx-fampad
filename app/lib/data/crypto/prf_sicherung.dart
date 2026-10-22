// Passkey-Sicherung des Personenschlüssels (WebAuthn-PRF, Projektbeschreibung 9a). Bausteine; der Ablauf steht in prf_ablauf.dart.
//
// Die PRF-Erweiterung (CTAP `hmac-secret`) liefert aus einem Passkey bei gleichem Salt jedes Mal dieselben 32 Byte, die den Authenticator nie verlassen.
// Sie werden NIE direkt als Schlüssel benutzt, sondern über BLAKE2b mit Schlüssel (CryptoProvider.kdf, eigener Kontext) zum `kek` abgeleitet:
//   kek = BLAKE2b-256(key = PRF-Ausgabe, "lx-fampad|prf-kek|v1")
//
// Blob (Base64url): v (1 Byte = 3) | keyVersion (4, BE) | nonce (24) | XChaCha20-Poly1305 (64 Byte Seeds + 16 Tag)
// AAD = "lx-fampad|prfbackup|v3|userId|keyVersion|credentialId": Person, Schlüsselversion und Passkey sind an den Chiffretext gebunden (ein Blob eines anderen Passkeys
// oder einer anderen Person lässt sich nicht unterschieben, auch nicht durch den Server).
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'domaenen.dart';
import 'schluessel.dart';

const int kPrfBlobVersion = 3;
const int kPrfAusgabeLaenge = 32;
const int _nonceLaenge = 24;
const int _kopf = 1 + 4 + _nonceLaenge;

/// Der feste Salt der PRF-Auswertung (32 Byte).
Uint8List prfSalt(CryptoProvider crypto) => crypto.hash(utf8Bytes(kPrfSaltText));

/// Prüft die Ausgabe der PRF-Erweiterung: genau 32 Byte, nicht nur Nullen (ein Authenticator, der "nichts" liefert, darf nie einen Schlüssel ergeben).
/// Gibt null zurück, wenn sie nicht brauchbar ist.
Uint8List? prfAusgabePruefen(Uint8List? roh) {
  if (roh == null || roh.length != kPrfAusgabeLaenge) return null;
  var summe = 0;
  for (final b in roh) {
    summe |= b;
  }
  return summe == 0 ? null : roh;
}

/// Der Schlüssel zum Verpacken, abgeleitet aus der PRF-Ausgabe eines Passkeys.
class PrfSchluessel {
  final Uint8List kek;
  PrfSchluessel._(this.kek);

  factory PrfSchluessel.ausAusgabe(CryptoProvider crypto, Uint8List prfAusgabe) {
    if (prfAusgabe.length != kPrfAusgabeLaenge) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Länge der Passkey-Ausgabe.');
    return PrfSchluessel._(crypto.kdf(prfAusgabe, kKontextPrfKek));
  }

  void loeschen() => loescheBytes(kek);
}

/// Blob der Passkey-Sicherung (Format oben).
class PrfSicherungBlob {
  PrfSicherungBlob._();

  static Uint8List _aad(String userId, int keyVersion, String credentialId) => utf8Bytes('$kDomaenePrfSicherung|$userId|$keyVersion|$credentialId');

  /// Verpackt die 64 Byte Seeds des Personenschlüssels mit dem [kek] (Base64url-Blob für den Server).
  static String erzeugen(
    CryptoProvider crypto, {
    required Personenschluessel schluessel,
    required Uint8List kek,
    required String userId,
    required int keyVersion,
    required String credentialId,
  }) {
    final nonce = crypto.zufall(_nonceLaenge);
    final klartext = schluessel.exportieren();
    try {
      final ct = crypto.verschluesseln(schluessel: kek, nonce: nonce, klartext: klartext, zusatzdaten: _aad(userId, keyVersion, credentialId));
      return base64urlKodieren(verketten([[kPrfBlobVersion], u32Bytes(keyVersion), nonce, ct]));
    } finally {
      loescheBytes(klartext);
    }
  }

  /// Öffnet den Blob mit dem [kek]. [keyVersion] kommt vom Server-Datensatz und muss mit dem Blob übereinstimmen. Falscher Passkey (falscher kek oder andere Kennung),
  /// andere Person, andere Version oder veränderte Daten: [CryptoFehler] (entschluesselung).
  static Personenschluessel oeffnen(
    CryptoProvider crypto, {
    required String blob,
    required Uint8List kek,
    required String userId,
    required int keyVersion,
    required String credentialId,
  }) {
    final b = base64urlDekodieren(blob);
    if (b.length != _kopf + 2 * kSchluesselLaenge + 16) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Sicherung ist beschädigt.');
    if (b[0] != kPrfBlobVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Sicherung stammt von einer anderen App-Version.');
    if (u32Lesen(b, 1) != keyVersion) throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    final klartext = crypto.entschluesseln(
      schluessel: kek,
      nonce: Uint8List.sublistView(b, 5, _kopf),
      chiffretext: Uint8List.sublistView(b, _kopf),
      zusatzdaten: _aad(userId, keyVersion, credentialId),
    );
    try {
      return Personenschluessel.ausBytes(crypto, klartext);
    } finally {
      loescheBytes(klartext);
    }
  }

  /// Probe: Der Blob lässt sich öffnen UND die daraus berechneten öffentlichen Schlüssel sind genau die [erwartet]en. false bei jedem Fehler beim Öffnen oder bei
  /// abweichenden Schlüsseln; Fehler der Bibliothek (bibliothek) werden weitergereicht.
  static bool pruefen(
    CryptoProvider crypto, {
    required String blob,
    required Uint8List kek,
    required String userId,
    required String credentialId,
    required OeffentlicheSchluessel erwartet,
  }) {
    try {
      final s = oeffnen(crypto, blob: blob, kek: kek, userId: userId, keyVersion: erwartet.version, credentialId: credentialId);
      try {
        return s.oeffentlich(erwartet.version).gleichWie(erwartet);
      } finally {
        s.loeschen();
      }
    } on CryptoFehler catch (e) {
      if (e.art == CryptoFehlerArt.bibliothek) rethrow;
      return false;
    }
  }
}
