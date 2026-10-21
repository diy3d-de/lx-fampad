// Ablauf der Passwort-Sicherung des Personenschlüssels (vereinfachte Schlüsselverwaltung, PR 3; Projektbeschreibung 9a). Rein additiv: berührt weder
// den lokalen Schlüssel noch Epochen, Wraps oder den alten Weg (Wiederherstellungsschlüssel, QR). Die Sicherung gilt erst nach ZWEI Proben:
//   1. lokale Probe (vor dem Senden): der Blob lässt sich mit dem kek öffnen und ergibt genau die öffentlichen Schlüssel, die der Server führt;
//   2. Round-Trip (nach dem Ablegen): Blob frisch vom Server holen, Salt und Parameter prüfen, mit dem PASSWORT neu ableiten (unabhängiger Weg),
//      öffnen und den Schlüssel mit dem lokalen UND dem Schlüssel des Servers vergleichen.
// Erst danach meldet die App die Sicherung beim Server als verifiziert. Der Server sieht nie Passwort, authKey oder kek (hier wird nicht einmal
// der authKey benutzt: der Login folgt in einem späteren Paket). Nichts davon landet im Log oder in einer Fehlermeldung.
import '../api/fampad_api.dart';
import '../api/models.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'pw_sicherung.dart';
import 'schluessel.dart';

/// Ergebnis der Vorbereitung: Der Blob ist erzeugt und lokal geprüft, aber noch nicht gesendet. Enthält kein Geheimnis außer dem verschlüsselten Blob.
class PwEntwurf {
  final String blob;
  final int keyVersion;
  final KdfDto kdf;
  const PwEntwurf({required this.blob, required this.keyVersion, required this.kdf});
}

class PwSicherungAblauf {
  final CryptoProvider crypto;
  final FampadApi api;
  final String userId;

  /// E-Mail des Kontos (der Server leitet daraus den Salt ab).
  final String email;
  const PwSicherungAblauf({required this.crypto, required this.api, required this.userId, required this.email});

  static const _fehlerProbe = CryptoFehler(
    CryptoFehlerArt.schluessel,
    'Die Prüfung der Passwort-Sicherung ist fehlgeschlagen. Es wurde nichts übernommen, dein bisheriger Weg (Wiederherstellungsschlüssel, QR-Code) gilt unverändert. Bitte versuche es noch einmal.',
  );

  /// Prüft Verfahren und Parameter des Servers gegen das feste Profil (kein Herabsetzen der Kosten, auch nicht durch einen manipulierten Server).
  static PwKdfParams _parameter(KdfDto k) {
    if (k.id != kKdf1ServerId) throw const CryptoFehler(CryptoFehlerArt.version, 'Der Server nutzt ein unbekanntes Verfahren der Schlüsselableitung. Bitte aktualisiere die App.');
    if (k.memKiB != kKdf1MemKiB || k.ops != kKdf1Ops) throw const CryptoFehler(CryptoFehlerArt.format, 'Ungültige Parameter der Schlüsselableitung.');
    return PwKdfParams(kdfId: kKdf1, memKiB: k.memKiB, ops: k.ops, salt: base64urlDekodieren(k.salt));
  }

  /// Schritt 1: Parameter und Salt vom Server holen, Blob erzeugen, lokale Probe. Es wird nichts gespeichert und nichts an die Sicherung gesendet.
  /// [lokal] muss der Schlüssel dieses Geräts sein und zu [server] (frisch geholt) passen.
  Future<PwEntwurf> vorbereiten({required Personenschluessel lokal, required OeffentlicheSchluessel server, required String passwort}) async {
    if (!server.gleichWie(lokal.oeffentlich(server.version))) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüssel dieses Geräts passt nicht zu deinem Konto. Verbinde das Gerät zuerst neu.');
    }
    final kdf = await api.kdfParameter(email);
    final params = _parameter(kdf);
    final keys = await PwSchluessel.ausPasswort(crypto, passwort: passwort, params: params);
    try {
      final blob = PwSicherungBlob.erzeugen(crypto, schluessel: lokal, kek: keys.kek, params: params, userId: userId, keyVersion: server.version);
      if (!PwSicherungBlob.pruefen(crypto, blob: blob, kek: keys.kek, userId: userId, erwartet: server)) throw _fehlerProbe;
      return PwEntwurf(blob: blob, keyVersion: server.version, kdf: kdf);
    } finally {
      keys.loeschen();
    }
  }

  /// Schritt 2 und 3: Blob ablegen (Step-up, den die Oberfläche um den Aufruf legt), Round-Trip, dann als verifiziert melden. Gibt die Kennung der
  /// Sicherung zurück. Bei jedem Fehler wird nichts gemeldet: die Sicherung bleibt beim Server unverifiziert (und wird beim nächsten Anlegen ersetzt).
  Future<String> ablegenUndPruefen(PwEntwurf e, {required String passwort, required Personenschluessel lokal, required OeffentlicheSchluessel serverVorher}) async {
    final id = await api.pwSicherungAblegen(blob: e.blob, keyVersion: e.keyVersion, kdf: e.kdf);
    final abruf = await api.pwSicherungAbrufen();
    if (abruf.id != id || abruf.stale || abruf.keyVersion != e.keyVersion || abruf.blob != e.blob || abruf.kdf.id != e.kdf.id || abruf.kdf.salt != e.kdf.salt) {
      throw _fehlerProbe;
    }
    final Personenschluessel geoeffnet;
    try {
      geoeffnet = await PwSicherungBlob.oeffnenMitPasswort(crypto, blob: abruf.blob, passwort: passwort, userId: userId, keyVersion: abruf.keyVersion);
    } on CryptoFehler catch (f) {
      if (f.art == CryptoFehlerArt.bibliothek) rethrow;
      throw _fehlerProbe;
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
    await api.pwSicherungBestaetigen(id);
    return id;
  }

  /// Auf einem Gerät ohne Schlüssel: Passwort-Sicherung holen und den Personenschlüssel daraus öffnen. Der Aufrufer übernimmt ihn erst nach dem
  /// Vergleich mit dem frisch vom Server geholten öffentlichen Schlüssel. Eine veraltete (`stale`) Sicherung enthält einen früheren Schlüssel.
  Future<({Personenschluessel schluessel, int keyVersion})> abrufenUndOeffnen(String passwort) async {
    final abruf = await api.pwSicherungAbrufen();
    if (abruf.stale) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Die Passwort-Sicherung gehört zu einem früheren Schlüssel und passt nicht mehr zu deinem Konto.');
    }
    final PwKdfParams imBlob;
    try {
      imBlob = PwSicherungBlob.parameter(abruf.blob);
    } on CryptoFehler {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Die Passwort-Sicherung ist beschädigt oder stammt von einer anderen App-Version.');
    }
    if (abruf.kdf.id != kKdf1ServerId || abruf.kdf.salt != imBlob.saltBase64) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Die Passwort-Sicherung ist beschädigt.');
    }
    try {
      final s = await PwSicherungBlob.oeffnenMitPasswort(crypto, blob: abruf.blob, passwort: passwort, userId: userId, keyVersion: abruf.keyVersion);
      return (schluessel: s, keyVersion: abruf.keyVersion);
    } on CryptoFehler catch (f) {
      if (f.art == CryptoFehlerArt.entschluesselung) {
        throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Das Passwort passt nicht zu deiner Sicherung.');
      }
      rethrow;
    }
  }
}
