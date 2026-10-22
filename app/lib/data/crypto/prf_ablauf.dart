// Ablauf der Passkey-Sicherung des Personenschlüssels (WebAuthn-PRF, Projektbeschreibung 9a). Rein additiv: berührt weder den lokalen Schlüssel noch Epochen, Wraps oder
// den alten Weg (Wiederherstellungsschlüssel, QR, Passwort-Sicherung). Wie die Passwort-Sicherung gilt sie erst nach ZWEI Proben:
//   1. lokale Probe (vor dem Senden): der Blob lässt sich mit dem kek öffnen und ergibt genau die öffentlichen Schlüssel, die der Server führt;
//   2. Round-Trip (nach dem Ablegen): die abgelegte, noch unbestätigte Sicherung frisch vom Server holen, mit einer ZWEITEN, unabhängigen PRF-Auswertung desselben Passkeys neu
//      ableiten, öffnen und den Schlüssel mit dem lokalen UND dem Schlüssel des Servers vergleichen.
// Der Server legt sie zuerst nur als "pending" ab: die bisherige Sicherung bleibt gültig, bis die neue bestätigt ist. Der Server sieht nie die PRF-Ausgabe oder den kek;
// beides erscheint nie in Zustand, Log oder Fehlermeldung.
import 'dart:typed_data';

import '../api/fampad_api.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'prf_sicherung.dart';
import 'schluessel.dart';

/// Ergebnis der Vorbereitung: Der Blob ist erzeugt und lokal geprüft, aber noch nicht gesendet.
class PrfEntwurf {
  final String blob;
  final int keyVersion;
  final String credentialId;
  const PrfEntwurf({required this.blob, required this.keyVersion, required this.credentialId});
}

/// Eine Auswertung der PRF-Erweiterung: die Kennung des benutzten Passkeys und seine (geprüfte, 32 Byte lange) Ausgabe.
class PrfAuswertung {
  final String credentialId;
  final Uint8List ausgabe;
  const PrfAuswertung(this.credentialId, this.ausgabe);

  void loeschen() => loescheBytes(ausgabe);
}

class PrfSicherungAblauf {
  final CryptoProvider crypto;
  final FampadApi api;
  final String userId;
  const PrfSicherungAblauf({required this.crypto, required this.api, required this.userId});

  static const _fehlerProbe = CryptoFehler(
    CryptoFehlerArt.schluessel,
    'Die Prüfung der Passkey-Sicherung ist fehlgeschlagen. Es wurde nichts übernommen, dein bisheriger Weg (Wiederherstellungsschlüssel, QR-Code, Passwort) gilt unverändert. Bitte versuche es noch einmal.',
  );

  /// Schritt 1: Blob aus der PRF-Ausgabe erzeugen und lokal prüfen. Es wird nichts gesendet und nichts gespeichert.
  /// [lokal] muss der Schlüssel dieses Geräts sein und zu [server] (frisch geholt) passen.
  PrfEntwurf vorbereiten({required Personenschluessel lokal, required OeffentlicheSchluessel server, required PrfAuswertung auswertung}) {
    if (!server.gleichWie(lokal.oeffentlich(server.version))) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüssel dieses Geräts passt nicht zu deinem Konto. Verbinde das Gerät zuerst neu.');
    }
    final k = PrfSchluessel.ausAusgabe(crypto, auswertung.ausgabe);
    try {
      final blob = PrfSicherungBlob.erzeugen(crypto, schluessel: lokal, kek: k.kek, userId: userId, keyVersion: server.version, credentialId: auswertung.credentialId);
      if (!PrfSicherungBlob.pruefen(crypto, blob: blob, kek: k.kek, userId: userId, credentialId: auswertung.credentialId, erwartet: server)) throw _fehlerProbe;
      return PrfEntwurf(blob: blob, keyVersion: server.version, credentialId: auswertung.credentialId);
    } finally {
      k.loeschen();
    }
  }

  /// Schritt 2 und 3 (Step-up ist vorher erledigt): Blob ablegen, Round-Trip mit einer zweiten Auswertung ([zweite]), dann als verifiziert melden. Gibt die Kennung
  /// der Sicherung zurück. Bei jedem Fehler wird nichts gemeldet: die abgelegte Sicherung bleibt beim Server unbestätigt (verfällt bzw. wird beim nächsten Anlegen ersetzt),
  /// die bisherige gilt unverändert weiter.
  Future<String> ablegenUndPruefen(
    PrfEntwurf e, {
    required Personenschluessel lokal,
    required OeffentlicheSchluessel serverVorher,
    required Future<PrfAuswertung> Function() zweite,
  }) async {
    final id = await api.prfSicherungAblegen(credentialId: e.credentialId, blob: e.blob, keyVersion: e.keyVersion);
    final abruf = await api.prfSicherungAbrufen(credentialId: e.credentialId, unbestaetigt: true);
    if (abruf.id != id || abruf.stale || !abruf.pending || abruf.keyVersion != e.keyVersion || abruf.blob != e.blob || abruf.credentialId != e.credentialId) throw _fehlerProbe;
    // unabhängiger Weg: eine frische Auswertung des Passkeys (eine zweite Geste), nicht die Ausgabe von vorhin
    final z = await zweite();
    final Personenschluessel geoeffnet;
    try {
      if (z.credentialId != e.credentialId) {
        throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Für die Prüfung wurde ein anderer Passkey benutzt. Bitte nimm denselben Passkey wie beim Anlegen.');
      }
      final k = PrfSchluessel.ausAusgabe(crypto, z.ausgabe);
      try {
        geoeffnet = PrfSicherungBlob.oeffnen(crypto, blob: abruf.blob, kek: k.kek, userId: userId, keyVersion: abruf.keyVersion, credentialId: abruf.credentialId);
      } on CryptoFehler catch (f) {
        if (f.art == CryptoFehlerArt.bibliothek) rethrow;
        throw _fehlerProbe;
      } finally {
        k.loeschen();
      }
    } finally {
      z.loeschen();
    }
    try {
      // gegen den Schlüssel des Servers (frisch, nach dem Ablegen) und den lokalen Schlüssel dieses Geräts
      final jetzt = (await api.eigeneSchluessel()).schluessel;
      final lokalBytes = lokal.exportieren();
      final geoeffnetBytes = geoeffnet.exportieren();
      try {
        final gleich = jetzt != null &&
            jetzt.version == e.keyVersion &&
            jetzt.gleichWie(geoeffnet.oeffentlich(jetzt.version)) &&
            serverVorher.version == jetzt.version &&
            gleicheBytes(lokalBytes, geoeffnetBytes);
        if (!gleich) throw _fehlerProbe;
      } finally {
        loescheBytes(lokalBytes);
        loescheBytes(geoeffnetBytes);
      }
    } finally {
      geoeffnet.loeschen();
    }
    await api.prfSicherungBestaetigen(id);
    return id;
  }

  /// Auf einem Gerät ohne Schlüssel: Passkey-Sicherung dieses Passkeys holen und den Personenschlüssel daraus öffnen. Der Aufrufer übernimmt ihn erst nach dem Vergleich mit
  /// dem frisch vom Server geholten öffentlichen Schlüssel. Eine veraltete (`stale`) Sicherung gehört zu einem früheren Schlüssel: sie wird nicht geöffnet, wenn ihre Version
  /// nicht zum aktuellen Schlüssel des Servers passt.
  Future<({Personenschluessel schluessel, int keyVersion})> abrufenUndOeffnen(PrfAuswertung auswertung) async {
    final abruf = await api.prfSicherungAbrufen(credentialId: auswertung.credentialId);
    if (abruf.pending || abruf.credentialId != auswertung.credentialId) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Passkey-Sicherung ist beschädigt.');
    final aktuell = (await api.eigeneSchluessel()).schluessel;
    if (aktuell == null || aktuell.version != abruf.keyVersion) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Die Passkey-Sicherung gehört zu einem früheren Schlüssel und passt nicht mehr zu deinem Konto.');
    }
    final k = PrfSchluessel.ausAusgabe(crypto, auswertung.ausgabe);
    try {
      final s = PrfSicherungBlob.oeffnen(crypto, blob: abruf.blob, kek: k.kek, userId: userId, keyVersion: abruf.keyVersion, credentialId: abruf.credentialId);
      return (schluessel: s, keyVersion: abruf.keyVersion);
    } on CryptoFehler catch (f) {
      if (f.art == CryptoFehlerArt.entschluesselung) {
        throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Dieser Passkey öffnet die Sicherung nicht (er wurde vermutlich neu angelegt). Nimm den Wiederherstellungsschlüssel oder ein anderes Gerät.');
      }
      rethrow;
    } finally {
      k.loeschen();
    }
  }
}
