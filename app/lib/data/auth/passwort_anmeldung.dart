// Anmeldung mit Passwort ohne das Klartext-Passwort zu senden (vereinfachte Schlüsselverwaltung, PR 4; Projektbeschreibung 9a).
//
// Die App leitet aus E-Mail und Passwort per Argon2id (Salt vom Server) den authKey ab und sendet nur ihn. Was der Server kann, sagt GET /version
// (`features.authKey`, `features.legacyPasswordLogin`); ein älterer Server ohne die Angabe bekommt das Klartext-Passwort wie bisher.
//
// Umstellung (legacy -> authkey) ohne Zutun: Ein Konto, das der Server noch nicht kennt, lehnt den authKey wie ein falsches Passwort ab (der Server verrät nie,
// ob ein Konto existiert oder in welchem Zustand es ist). Nur dann, und nur solange der Server das Klartext-Passwort noch annimmt UND diese App dieses
// Konto noch nie per authKey angemeldet hat, wiederholt die App die Anmeldung einmal mit dem alten Weg und gibt den authKey mit (`upgradeAuthKey`);
// der Server legt ihn nach erfolgreicher Prüfung von Passwort und zweitem Faktor an. Danach geht es nur noch mit authKey.
//
// Herabstufungsschutz: Hat sich diese App mit dem Konto schon einmal per authKey angemeldet (`TokenStore.istAuthKeyKonto`), sendet sie nie wieder das Klartext-
// Passwort, auch nicht nach einer Fehlermeldung des Servers. Bei einem Gerät, das das Konto noch nicht kennt, kann ein Server die Wiederholung mit Klartext
// herbeiführen (er braucht dazu nur "falsch" zu antworten): dagegen hilft nur der Stichtag (AUTH_LEGACY_PASSWORD_LOGIN=false), ab dem es den Weg nicht mehr gibt.
// Weder authKey noch Passwort landen im Log oder in einer Meldung.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../api/models.dart' show ServerFaehigkeiten;
import '../api/token_store.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/e2ee_state.dart' show cryptoProviderProvider;
import '../crypto/pw_ablauf.dart';
import '../crypto/pw_sicherung.dart';
import 'auth_state.dart';

/// Schickt eine Passwort-Anmeldung ab (Server-Aufruf samt Übernahme der Sitzung): entweder mit [authKey] oder mit [passwort] (und dann optional [upgradeAuthKey]).
typedef AnmeldeSender = Future<void> Function({String? passwort, String? authKey, String? upgradeAuthKey});

/// Ein neues Passwort für den Server: genau eins von beiden gesetzt.
class NeuesPasswort {
  final String? klartext;
  final String? authKey;
  const NeuesPasswort({this.klartext, this.authKey});
}

class PasswortAnmeldung {
  final FampadApi api;
  final TokenStore store;
  final Future<CryptoProvider> Function() krypto;
  const PasswortAnmeldung({required this.api, required this.store, required this.krypto});

  static const _fehlerGeraet = CryptoFehler(
    CryptoFehlerArt.bibliothek,
    'Die Anmeldung ist auf diesem Gerät gerade nicht möglich (Verschlüsselung nicht verfügbar). Bitte versuche es mit einem Passkey.',
  );

  /// Leitet den authKey ab; null, wenn das auf diesem Gerät nicht geht (Bibliothek fehlt, unbekanntes Verfahren des Servers). Netzfehler gehen nach oben.
  Future<PwSchluessel?> _ableiten(String email, String passwort) async {
    // erst einen Frame zeichnen lassen: Argon2id blockiert im Web den Hauptthread
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final kdf = await api.kdfParameter(email);
    try {
      final params = PwSicherungAblauf.parameterPruefen(kdf);
      return await PwSchluessel.ausPasswort(await krypto(), passwort: passwort, params: params);
    } on Object {
      // CryptoFehler (unbekanntes Verfahren, Bibliothek) oder ein Ladefehler der Bibliothek: nie das Passwort in eine Meldung nehmen
      return null;
    }
  }

  static const _fehlerServerAlt = CryptoFehler(
    CryptoFehlerArt.version,
    'Der Server bietet die sichere Anmeldung gerade nicht an. Aus Sicherheitsgründen sendet die App dein Passwort dann nicht. Bitte versuche es später noch einmal.',
  );

  /// Fähigkeiten des Servers. Fällt GET /version aus (Netz, Zeitüberschreitung, 5xx), wird NIE auf Klartext geschlossen: Ist vom letzten Mal bekannt, dass der Server
  /// authKey kann, gilt das, sonst geht der Fehler nach oben ("keine Verbindung").
  Future<ServerFaehigkeiten> _faehigkeiten() async {
    try {
      final f = await api.serverFaehigkeiten();
      try {
        await store.writeFaehigkeiten(f);
      } catch (_) {}
      return f;
    } on ApiException {
      ServerFaehigkeiten? bekannt;
      try {
        bekannt = await store.readFaehigkeiten();
      } catch (_) {}
      if (bekannt != null && bekannt.authKey) return bekannt;
      rethrow;
    }
  }

  Future<void> anmelden({required String email, required String passwort, required AnmeldeSender senden}) async {
    final f = await _faehigkeiten();
    final festgelegt = await _festgelegt(email);
    if (!f.authKey) {
      // ein Konto, das diese App schon per authKey angemeldet hat, bekommt nie Klartext (auch nicht von einem Server, der den authKey "nicht kennt")
      if (festgelegt) throw _fehlerServerAlt;
      return senden(passwort: passwort);
    }
    final keys = await _ableiten(email, passwort);
    if (keys == null) {
      if (f.legacyPasswortLogin && !festgelegt) return senden(passwort: passwort);
      throw _fehlerGeraet;
    }
    try {
      try {
        await senden(authKey: keys.authKeyBase64);
        await merkeKonto(email);
        return;
      } on ApiException catch (e) {
        // nur die allgemeine Ablehnung führt zum alten Weg; Sperre (429), Wartestatus, Netzfehler u. a. gehen unverändert nach oben
        if (e.code != 'invalid_credentials' || !f.legacyPasswortLogin || festgelegt) rethrow;
      }
      await senden(passwort: passwort, upgradeAuthKey: keys.authKeyBase64);
      // die Umstellung hat geklappt: ab jetzt nie wieder Klartext von diesem Gerät (der nächste authKey-Login bestätigt es)
      await merkeKonto(email);
    } finally {
      keys.loeschen();
    }
  }

  /// Wie wird ein NEUES Passwort an den Server gegeben (Passwort einrichten, ändern, Registrierung)? Mit authKey, wenn der Server das kann (das Passwort verlässt
  /// das Gerät nie); sonst (älterer Server, oder die Ableitung geht auf diesem Gerät nicht, solange der Server das Klartext-Passwort noch annimmt) im Klartext
  /// wie bisher. Ohne den Klartext-Weg und ohne Ableitung: [CryptoFehler].
  ///
  /// [pruefenMitAuthKey] läuft nur, wenn der Server den authKey nimmt (er kann das Passwort dann nicht mehr selbst prüfen): die Regeln für Stärke und Kontodaten
  /// gelten dann auf dem Gerät.
  Future<NeuesPasswort> neuesPasswort(String email, String passwort, {void Function()? pruefenMitAuthKey}) async {
    final f = await _faehigkeiten();
    if (!f.authKey) {
      if (await _festgelegt(email)) throw _fehlerServerAlt;
      return NeuesPasswort(klartext: passwort);
    }
    pruefenMitAuthKey?.call();
    final keys = await _ableiten(email, passwort);
    if (keys == null) {
      if (f.legacyPasswortLogin && !await _festgelegt(email)) return NeuesPasswort(klartext: passwort);
      throw _fehlerGeraet;
    }
    try {
      return NeuesPasswort(authKey: keys.authKeyBase64);
    } finally {
      keys.loeschen();
    }
  }

  Future<bool> _festgelegt(String email) async {
    try {
      return await store.istAuthKeyKonto(email);
    } catch (_) {
      return false;
    }
  }

  /// Merkt, dass diese App das Konto per authKey kennt (Schutz vor Herabstufung). Fehler des Speichers werden verschluckt.
  Future<void> merkeKonto(String email) async {
    try {
      await store.merkeAuthKeyKonto(email);
    } catch (_) {
      // ohne Vermerk bleibt nur der Schutz vor Herabstufung auf diesem Gerät aus; die Anmeldung selbst ist gelungen
    }
  }
}

final passwortAnmeldungProvider = Provider<PasswortAnmeldung>(
  (ref) => PasswortAnmeldung(api: ref.watch(apiProvider), store: ref.watch(tokenStoreProvider), krypto: () => ref.read(cryptoProviderProvider.future)),
);
