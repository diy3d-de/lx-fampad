// Abläufe der Passkey-Sicherung (WebAuthn-PRF) für die Oberfläche: Sicherung anlegen, Gerät mit dem Passkey verbinden und das automatische Verbinden nach der Anmeldung mit
// Passkey. Die Kryptografie steht in prf_sicherung.dart und prf_ablauf.dart; hier nur die Verdrahtung mit Passkey-Dienst, Server und Zustand der Verschlüsselung.
// Die PRF-Ausgabe bleibt in dieser Datei im Arbeitsspeicher, wird nach Gebrauch überschrieben und erscheint nie in Zustand, Log oder Meldungen.
// Nie ein neuer Personenschlüssel, nie ein vorhandener lokaler Schlüssel wird ersetzt; jeder Fehler lässt Schlüssel und bisherige Sicherungen unverändert.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../auth/eigener_abruf.dart';
import '../passkey_service.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'e2ee_state.dart';
import 'prf_ablauf.dart';
import 'prf_sicherung.dart';
import 'schluessel.dart';
import 'schluessel_speicher.dart';

/// Ausgang von [PrfSteuerung.sicherungAnlegen].
enum PrfAnlegen {
  /// Die Sicherung wurde angelegt, zweifach geprüft und bestätigt.
  angelegt,

  /// Der Passkey-Speicher liefert keine PRF-Ausgabe (nicht unterstützt): nichts wurde gesendet oder verändert.
  nichtUnterstuetzt,
}

/// Ausgang von [PrfSteuerung.mitPasskeyVerbinden].
enum PrfVerbinden {
  verbunden,

  /// Der Passkey-Speicher liefert keine PRF-Ausgabe.
  nichtUnterstuetzt,

  /// Zu diesem Passkey gibt es keine bestätigte Sicherung.
  keineSicherung,

  /// Dieser Passkey öffnet die Sicherung nicht (zum Beispiel neu angelegt).
  passtNicht,
}

class PrfSteuerung {
  final Ref ref;
  PrfSteuerung(this.ref);

  E2eeController get _e2ee => ref.read(e2eeProvider.notifier);

  /// Eine Passkey-Geste: bestätigt zugleich den Step-up beim Server und liefert die PRF-Ausgabe. null, wenn der Passkey-Speicher PRF nicht unterstützt.
  /// Mit [nur] bietet das Gerät nur diesen Passkey an.
  Future<PrfAuswertung?> _auswerten({String? nur}) async {
    final api = ref.read(apiProvider);
    final crypto = await _e2ee.kryptoFuerAblauf();
    final ch = await api.stepUpPasskeyOptionen();
    final r = await ref.read(passkeyServiceProvider).bestaetigenMitPrf(ch.options, salt: prfSalt(crypto), nurCredentialId: nur);
    await api.stepUpPasskey(challengeId: ch.challengeId, antwort: r.antwort);
    final ausgabe = prfAusgabePruefen(r.prf);
    return ausgabe == null ? null : PrfAuswertung(r.credentialId, ausgabe);
  }

  PrfSicherungAblauf _ablauf(CryptoProvider crypto) {
    final id = ref.read(authProvider).user?.id;
    if (id == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du bist nicht angemeldet.');
    return PrfSicherungAblauf(crypto: crypto, api: ref.read(apiProvider), userId: id);
  }

  /// Legt die Passkey-Sicherung an (Gerät mit Schlüssel nötig). Zwei Passkey-Gesten: die erste verpackt den Schlüssel, die zweite prüft die Sicherung unabhängig. Scheitert
  /// etwas (Abbruch, Netz, Prüfung), bleibt die bisherige Sicherung gültig; ein Passkey-Dialog-Abbruch kommt als [PasskeyException] (abgebrochen) heraus.
  Future<PrfAnlegen> sicherungAnlegen() async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final lokal = await _e2ee.lokalenSchluesselFuerAblauf();
    if (lokal == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel.');
    final server = (await ref.read(apiProvider).eigeneSchluessel()).schluessel;
    if (server == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du hast den Nachrichten-Schutz noch nicht eingerichtet.');
    final erste = await _auswerten();
    if (erste == null) return PrfAnlegen.nichtUnterstuetzt;
    try {
      final ablauf = _ablauf(crypto);
      final entwurf = ablauf.vorbereiten(lokal: lokal, server: server, auswertung: erste);
      await ablauf.ablegenUndPruefen(
        entwurf,
        lokal: lokal,
        serverVorher: server,
        zweite: () async {
          final z = await _auswerten(nur: erste.credentialId);
          if (z == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Passkey lieferte bei der Prüfung keine Ausgabe. Es wurde nichts übernommen.');
          return z;
        },
      );
    } finally {
      erste.loeschen();
    }
    await _e2ee.laden();
    return PrfAnlegen.angelegt;
  }

  /// Gerät ohne Schlüssel mit der Passkey-Sicherung verbinden (eine Passkey-Geste). Der Schlüssel wird erst übernommen, wenn er zum frisch geholten öffentlichen Schlüssel
  /// des Servers passt.
  Future<PrfVerbinden> mitPasskeyVerbinden() async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final a = await _auswerten();
    if (a == null) return PrfVerbinden.nichtUnterstuetzt;
    try {
      await ref.read(eigenerPwAbrufMarkeProvider)();
      final ({Personenschluessel schluessel, int keyVersion}) r;
      try {
        final g = await _ablauf(crypto).abrufenUndOeffnen(a);
        r = (schluessel: g.schluessel, keyVersion: g.keyVersion);
      } on ApiException catch (e) {
        if (e.code == 'not_found') return PrfVerbinden.keineSicherung;
        rethrow;
      } on CryptoFehler catch (e) {
        if (e.art == CryptoFehlerArt.entschluesselung) return PrfVerbinden.passtNicht;
        rethrow;
      }
      await _e2ee.schluesselUebernehmen(r.schluessel, r.keyVersion);
      return PrfVerbinden.verbunden;
    } finally {
      a.loeschen();
    }
  }

  /// Wiederherstellungstest (wiederherstellungstest.dart): Passkey-Geste, Sicherung dieses Passkeys holen und öffnen, [vergleichen] gegen den Schlüssel des Servers (übernimmt
  /// nie etwas, überschreibt den geöffneten Schlüssel danach). false, wenn der Passkey-Speicher PRF nicht unterstützt (nichts geschehen).
  Future<bool> sicherungTesten(Future<void> Function(Personenschluessel schluessel, int keyVersion) vergleichen) async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final a = await _auswerten();
    if (a == null) return false;
    try {
      await ref.read(eigenerPwAbrufMarkeProvider)();
      final ({Personenschluessel schluessel, int keyVersion}) r;
      try {
        final g = await _ablauf(crypto).abrufenUndOeffnen(a);
        r = (schluessel: g.schluessel, keyVersion: g.keyVersion);
      } on ApiException catch (e) {
        if (e.code == 'not_found') throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Zu diesem Passkey gibt es keine Passkey-Sicherung.');
        rethrow;
      }
      await vergleichen(r.schluessel, r.keyVersion);
      return true;
    } finally {
      a.loeschen();
    }
  }

  /// Nach der Anmeldung mit Passkey und Zustimmung ("Das ist mein eigenes Gerät"): Hat dieses Gerät keinen Schlüssel, der Server aber eine bestätigte Sicherung zu GENAU
  /// diesem Passkey, öffnet die App sie mit der PRF-Ausgabe der Anmeldung (keine zweite Geste). Nie ein neuer Schlüssel, nie ein vorhandener lokaler Schlüssel wird
  /// angefasst. Wirft nie; der Ausgang sagt, was geschehen ist.
  Future<AutoVerbinden> automatischVerbinden({required String credentialId, required Uint8List prfAusgabe}) async {
    final ausgabe = prfAusgabePruefen(prfAusgabe);
    if (ausgabe == null) return AutoVerbinden.nichtNoetig;
    final a = PrfAuswertung(credentialId, ausgabe);
    try {
      final api = ref.read(apiProvider);
      if (!(await api.faehigkeitenOderKeine()).prfBackup) return AutoVerbinden.nichtNoetig;
      final crypto = await _e2ee.kryptoFuerAblauf();
      final Object? lokal;
      try {
        lokal = await _e2ee.lokalenSchluesselFuerAblauf();
      } on SchluesselSpeicherFehler {
        return AutoVerbinden.fehlgeschlagen; // Speicher gerade nicht lesbar: nichts anfassen
      }
      if (lokal != null) return AutoVerbinden.nichtNoetig;
      final eigene = await api.eigeneSchluessel();
      if (eigene.schluessel == null) return AutoVerbinden.nichtNoetig; // noch kein Schlüssel eingerichtet: nie automatisch einen anlegen
      // Zustand des Servers zuerst (ohne die protokollierte Sicherung abzurufen): nur eine bestätigte, aktuelle Sicherung dieses Passkeys ist ein Ziel
      if (!eigene.prfCredentialIds.contains(credentialId)) return AutoVerbinden.keineSicherung;
      await ref.read(eigenerPwAbrufMarkeProvider)();
      final ({Personenschluessel schluessel, int keyVersion}) r;
      try {
        final g = await _ablauf(crypto).abrufenUndOeffnen(a);
        r = (schluessel: g.schluessel, keyVersion: g.keyVersion);
      } on CryptoFehler catch (e) {
        return e.art == CryptoFehlerArt.entschluesselung ? AutoVerbinden.passkeyPasstNicht : AutoVerbinden.fehlgeschlagen;
      } on ApiException catch (e) {
        return e.code == 'not_found' ? AutoVerbinden.keineSicherung : AutoVerbinden.fehlgeschlagen;
      }
      await _e2ee.schluesselUebernehmen(r.schluessel, r.keyVersion);
      return AutoVerbinden.verbunden;
    } on Object {
      try {
        if (ref.mounted) await _e2ee.laden();
      } on Object {
        // nur die Anzeige
      }
      return AutoVerbinden.fehlgeschlagen;
    } finally {
      a.loeschen();
    }
  }
}

final prfSteuerungProvider = Provider<PrfSteuerung>((ref) => PrfSteuerung(ref));
