// Passwort-abgeleitete Sicherung des Personenschlüssels (Entwurf "vereinfachte Schlüsselverwaltung", Projektbeschreibung 9a). NUR Bausteine, noch nicht
// im Ablauf verdrahtet.
//
// Ableitung: master = Argon2id(NFKC-UTF-8-Passwort, salt, Profil kdf1) -> zwei unabhängige Teilschlüssel per BLAKE2b-256 mit Schlüssel = master:
//   authKey = BLAKE2b-256(key = master, "lx-fampad|auth|v2")  -> geht an den Server (statt des Passworts)
//   kek     = BLAKE2b-256(key = master, "lx-fampad|kek|v2")   -> bleibt auf dem Gerät, verpackt den Personenschlüssel
// Aus dem authKey lässt sich der kek nicht berechnen (BLAKE2b ist eine PRF: verschiedene Kontexte, Schlüssel = master, Ausgaben unabhängig);
// der Server kann nur das Passwort raten (Argon2id, 64 MiB, 3 Durchläufe je Versuch).
//
// Blob (Base64url): v (1 Byte = 2) | kdfId (1) | keyVersion (4, BE) | memKiB (4, BE) | ops (4, BE) | salt (16) | nonce (24) | XChaCha20-Poly1305 (64 Byte Seeds + 16 Tag)
// AAD = "lx-fampad|pwbackup|v2|userId|keyVersion|kdfId|memKiB|ops|salt(base64url)": Person, Schlüsselversion und alle Parameter sind
// an den Chiffretext gebunden. Die Parameter im Blob gelten nur, wenn sie GENAU dem festen Profil entsprechen (kein Herabsetzen durch den Server).
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'domaenen.dart';
import 'nfkc.dart';
import 'schluessel.dart';

/// Kennung des Profils: Argon2id mit [kKdf1MemKiB]/[kKdf1Ops], Salt 16 Byte, Passwort-Normalisierung nach nfkc.dart (Tabellenstand 1).
const int kKdf1 = 1;

/// 64 MiB (libsodium: crypto_pwhash_argon2id_MEMLIMIT_INTERACTIVE = 67108864 Byte). Ops = 3 ist libsodiums OPSLIMIT_MODERATE (INTERACTIVE = 2,
/// SENSITIVE = 4); libsodium selbst koppelt Moderate sonst an 256 MiB, hier bleibt der Speicher bei 64 MiB (Benchmark und Begründung: 9a).
const int kKdf1MemKiB = 65536;
const int kKdf1Ops = 3;
const int kPwSaltLaenge = 16;
const int kPwBlobVersion = 2;
const int _nonceLaenge = 24;
const int _kopf = 1 + 1 + 4 + 4 + 4 + kPwSaltLaenge + _nonceLaenge;

/// Parameter der Passwort-Ableitung (stehen im Blob und beim Server neben dem authKey).
class PwKdfParams {
  final int kdfId;
  final int memKiB;
  final int ops;
  final Uint8List salt;

  PwKdfParams({required this.kdfId, required this.memKiB, required this.ops, required Uint8List salt}) : salt = Uint8List.fromList(salt) {
    if (kdfId != kKdf1) throw const CryptoFehler(CryptoFehlerArt.version, 'Unbekanntes Verfahren der Schlüsselableitung.');
    if (memKiB != kKdf1MemKiB || ops != kKdf1Ops || salt.length != kPwSaltLaenge) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültige Parameter der Schlüsselableitung.');
    }
  }

  /// Profil `kdf1` mit frischem zufälligem Salt.
  factory PwKdfParams.neu(CryptoProvider crypto) => PwKdfParams(kdfId: kKdf1, memKiB: kKdf1MemKiB, ops: kKdf1Ops, salt: crypto.zufall(kPwSaltLaenge));

  String get saltBase64 => base64urlKodieren(salt);

  @override
  bool operator ==(Object other) =>
      other is PwKdfParams && other.kdfId == kdfId && other.memKiB == memKiB && other.ops == ops && gleicheBytes(other.salt, salt);

  @override
  int get hashCode => Object.hash(kdfId, memKiB, ops, saltBase64);
}

/// Die beiden Teilschlüssel aus dem Master.
class PwSchluessel {
  /// Geht an den Server.
  final Uint8List authKey;

  /// Bleibt auf dem Gerät.
  final Uint8List kek;

  PwSchluessel._(this.authKey, this.kek);

  /// Aus einem 32-Byte-Master (Ausgabe von pwhash).
  factory PwSchluessel.ausMaster(CryptoProvider crypto, Uint8List master) {
    if (master.length != 32) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    return PwSchluessel._(crypto.kdf(master, kKontextPwAuth), crypto.kdf(master, kKontextPwKek));
  }

  /// Rechenintensiv (Argon2id): auf Android läuft die Rechnung im Isolate des Providers, im Web im Hauptthread (UI vorher einen Frame zeichnen lassen).
  static Future<PwSchluessel> ausPasswort(CryptoProvider crypto, {required String passwort, required PwKdfParams params}) async {
    final pw = passwortBytes(passwort);
    if (pw.isEmpty) throw const CryptoFehler(CryptoFehlerArt.format, 'Das Passwort ist leer.');
    try {
      final master = await crypto.pwhash(passwort: pw, salt: params.salt, memKiB: params.memKiB, ops: params.ops);
      try {
        return PwSchluessel.ausMaster(crypto, master);
      } finally {
        loescheBytes(master);
      }
    } finally {
      loescheBytes(pw);
    }
  }

  String get authKeyBase64 => base64urlKodieren(authKey);

  /// Überschreibt die Bytes (best effort).
  void loeschen() {
    loescheBytes(authKey);
    loescheBytes(kek);
  }
}

/// Blob der Passwort-Sicherung (Format oben).
class PwSicherungBlob {
  PwSicherungBlob._();

  static Uint8List _aad(String userId, int keyVersion, PwKdfParams p) =>
      utf8Bytes('$kDomaenePwSicherung|$userId|$keyVersion|${p.kdfId}|${p.memKiB}|${p.ops}|${p.saltBase64}');

  /// Verpackt die 64 Byte Seeds des Personenschlüssels mit dem [kek] (Base64url-Blob für den Server).
  static String erzeugen(
    CryptoProvider crypto, {
    required Personenschluessel schluessel,
    required Uint8List kek,
    required PwKdfParams params,
    required String userId,
    required int keyVersion,
  }) {
    final nonce = crypto.zufall(_nonceLaenge);
    final klartext = schluessel.exportieren();
    try {
      final ct = crypto.verschluesseln(schluessel: kek, nonce: nonce, klartext: klartext, zusatzdaten: _aad(userId, keyVersion, params));
      return base64urlKodieren(
        verketten([
          [kPwBlobVersion, params.kdfId],
          u32Bytes(keyVersion),
          u32Bytes(params.memKiB),
          u32Bytes(params.ops),
          params.salt,
          nonce,
          ct,
        ]),
      );
    } finally {
      loescheBytes(klartext);
    }
  }

  /// Liest nur die Parameter (um das Passwort mit dem richtigen Salt abzuleiten). Wirft [CryptoFehler] (format/version).
  static PwKdfParams parameter(String blob) => _lesen(blob).params;

  static ({PwKdfParams params, int keyVersion, Uint8List nonce, Uint8List chiffretext}) _lesen(String blob) {
    final b = base64urlDekodieren(blob);
    if (b.length != _kopf + 2 * kSchluesselLaenge + 16) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Sicherung ist beschädigt.');
    if (b[0] != kPwBlobVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Sicherung stammt von einer anderen App-Version.');
    final params = PwKdfParams(kdfId: b[1], memKiB: u32Lesen(b, 6), ops: u32Lesen(b, 10), salt: Uint8List.sublistView(b, 14, 14 + kPwSaltLaenge));
    return (
      params: params,
      keyVersion: u32Lesen(b, 2),
      nonce: Uint8List.sublistView(b, 14 + kPwSaltLaenge, _kopf),
      chiffretext: Uint8List.sublistView(b, _kopf),
    );
  }

  /// Öffnet den Blob mit dem [kek]. [keyVersion] kommt vom Server-Datensatz und muss mit dem Blob übereinstimmen. Falsches Passwort (falscher kek),
  /// andere Person, andere Version oder veränderte Daten: [CryptoFehler] (entschluesselung).
  static Personenschluessel oeffnen(CryptoProvider crypto, {required String blob, required Uint8List kek, required String userId, required int keyVersion}) {
    final d = _lesen(blob);
    if (d.keyVersion != keyVersion) throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    final klartext = crypto.entschluesseln(schluessel: kek, nonce: d.nonce, chiffretext: d.chiffretext, zusatzdaten: _aad(userId, keyVersion, d.params));
    try {
      return Personenschluessel.ausBytes(crypto, klartext);
    } finally {
      loescheBytes(klartext);
    }
  }

  /// Wie [oeffnen], aber aus dem Passwort (liest Salt und Parameter aus dem Blob).
  static Future<Personenschluessel> oeffnenMitPasswort(
    CryptoProvider crypto, {
    required String blob,
    required String passwort,
    required String userId,
    required int keyVersion,
  }) async {
    final keys = await PwSchluessel.ausPasswort(crypto, passwort: passwort, params: parameter(blob));
    try {
      return oeffnen(crypto, blob: blob, kek: keys.kek, userId: userId, keyVersion: keyVersion);
    } finally {
      keys.loeschen();
    }
  }

  /// Probe: Der Blob lässt sich öffnen UND die daraus berechneten öffentlichen Schlüssel sind genau die [erwartet]en (die der Server für diese
  /// Version führt). false bei jedem Fehler beim Öffnen oder bei abweichenden Schlüsseln; Fehler der Bibliothek (bibliothek) werden weitergereicht.
  static bool pruefen(CryptoProvider crypto, {required String blob, required Uint8List kek, required String userId, required OeffentlicheSchluessel erwartet}) {
    try {
      final s = oeffnen(crypto, blob: blob, kek: kek, userId: userId, keyVersion: erwartet.version);
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
