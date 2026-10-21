// Wiederherstellungsschlüssel: 32 Byte Zufall, angezeigt als 14 Vierergruppen (Base32 mit Prüfsumme, siehe code32.dart). Er verschlüsselt
// ein Backup des Personenschlüssels (XChaCha20-Poly1305); der Server speichert nur diesen undurchsichtigen Blob. Der Schlüssel ist
// 256 Bit stark, deshalb braucht es keine Passphrase-Ableitung (kein Argon2id). Ohne den Schlüssel (und ohne ein verbundenes Gerät)
// gibt es keinen Weg zurück: Es gibt bewusst keinen Nachschlüssel für Admins.
//
// Blob (Base64url): v (1 Byte) | key_version (4 Byte, BE) | nonce (24 Byte) | chiffretext (64 Byte Personenschlüssel + 16 Byte Tag)
// Schlüssel zum Verpacken = BLAKE2b-256(Zweck, Schlüssel = Wiederherstellungsschlüssel); AAD = "lx-fampad|key-backup|v1|user_id|key_version".
import 'dart:typed_data';

import 'bytes.dart';
import 'code32.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'schluessel.dart';

const String _zweckAnzeige = 'lx-fampad|wiederherstellung|v1';
const String _zweckSchluessel = 'lx-fampad|e2ee|backup-key|v1';
const int _blobVersion = 1;
const int _kopf = 1 + 4 + kNonceLaengeBackup;
const int kNonceLaengeBackup = 24;

class Sicherung {
  final Personenschluessel schluessel;
  final int keyVersion;
  const Sicherung(this.schluessel, this.keyVersion);
}

class Wiederherstellung {
  /// Neuer Wiederherstellungsschlüssel (32 Byte Zufall).
  static Uint8List neuerSchluessel(CryptoProvider crypto) => crypto.zufall(kGeheimnisLaenge);

  /// Anzeige in Vierergruppen (`ABCD-EFGH-...`).
  static String anzeigen(Uint8List schluessel) => Code32.kodieren(schluessel, _zweckAnzeige);

  /// Die 14 Gruppen der Anzeige (für die Abfrage "Gruppe 3 und 9").
  static List<String> gruppen(Uint8List schluessel) => anzeigen(schluessel).split('-');

  /// Liest einen eingetippten Schlüssel; wirft [CryptoFehler] (format/pruefsumme).
  static Uint8List lesen(String eingabe) => Code32.dekodieren(eingabe, _zweckAnzeige);

  /// Probe nach dem Aufschreiben: Stimmt der VOLLSTÄNDIG eingetippte Schlüssel (unabhängig von Schreibweise, Leerzeichen und Bindestrichen, 0/1/8 wie O/I/B)
  /// mit [schluessel] überein? Falsche Prüfsumme oder falsches Format ergeben false (nie eine Ausnahme).
  static bool stimmt(Uint8List schluessel, String eingabe) {
    final Uint8List gelesen;
    try {
      gelesen = lesen(eingabe);
    } on CryptoFehler {
      return false;
    }
    try {
      return gleicheBytes(gelesen, schluessel);
    } finally {
      loescheBytes(gelesen);
    }
  }

  static Uint8List _verpackSchluessel(CryptoProvider crypto, Uint8List wiederherstellungsschluessel) =>
      crypto.hash(utf8Bytes(_zweckSchluessel), schluessel: wiederherstellungsschluessel);

  static Uint8List _aad(String userId, int keyVersion) => utf8Bytes('lx-fampad|key-backup|v1|$userId|$keyVersion');

  /// Verschlüsselt den Personenschlüssel für den Server (Base64url-Blob).
  static String sicherungErstellen(
    CryptoProvider crypto, {
    required Personenschluessel schluessel,
    required Uint8List wiederherstellungsschluessel,
    required String userId,
    required int keyVersion,
  }) {
    final nonce = crypto.zufall(kNonceLaengeBackup);
    final ct = crypto.verschluesseln(
      schluessel: _verpackSchluessel(crypto, wiederherstellungsschluessel),
      nonce: nonce,
      klartext: schluessel.exportieren(),
      zusatzdaten: _aad(userId, keyVersion),
    );
    return base64urlKodieren(verketten([
      [_blobVersion],
      u32Bytes(keyVersion),
      nonce,
      ct,
    ]));
  }

  /// Öffnet die Sicherung; bei falschem Schlüssel, falscher Person oder veränderten Daten: [CryptoFehler] (entschluesselung).
  static Sicherung sicherungOeffnen(CryptoProvider crypto, {required String blob, required Uint8List wiederherstellungsschluessel, required String userId}) {
    final bytes = base64urlDekodieren(blob);
    if (bytes.length < _kopf + 2 * kSchluesselLaenge + 16) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Sicherung ist beschädigt.');
    if (bytes[0] != _blobVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Sicherung stammt von einer neueren App-Version.');
    final keyVersion = u32Lesen(bytes, 1);
    final klartext = crypto.entschluesseln(
      schluessel: _verpackSchluessel(crypto, wiederherstellungsschluessel),
      nonce: Uint8List.sublistView(bytes, 5, _kopf),
      chiffretext: Uint8List.sublistView(bytes, _kopf),
      zusatzdaten: _aad(userId, keyVersion),
    );
    try {
      return Sicherung(Personenschluessel.ausBytes(crypto, klartext), keyVersion);
    } finally {
      loescheBytes(klartext);
    }
  }
}
