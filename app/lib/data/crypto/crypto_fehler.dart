// Fehler der Verschlüsselungs-Bibliothek. Die Meldungen sind deutsch und enthalten nie Schlüsselmaterial oder Klartext.

enum CryptoFehlerArt {
  /// Eingabe/Hülle hat nicht die erwartete Form (Länge, Zeichen, Kodierung).
  format,

  /// Unbekannte Version oder unbekanntes Verfahren.
  version,

  /// Prüfsumme eines eingetippten Codes stimmt nicht (Tippfehler).
  pruefsumme,

  /// Signatur des Absenders passt nicht.
  signatur,

  /// Entschlüsselung gescheitert (falscher Schlüssel, veränderte Daten oder falscher Kontext).
  entschluesselung,

  /// Schlüssel fehlt oder hat die falsche Länge.
  schluessel,

  /// Ein Nonce würde zum zweiten Mal mit demselben Schlüssel benutzt.
  nonce,

  /// Die Kryptobibliothek (libsodium) ist nicht verfügbar oder meldet einen internen Fehler.
  bibliothek,
}

class CryptoFehler implements Exception {
  final CryptoFehlerArt art;
  final String meldung;
  const CryptoFehler(this.art, this.meldung);

  @override
  String toString() => 'CryptoFehler(${art.name}): $meldung';
}
