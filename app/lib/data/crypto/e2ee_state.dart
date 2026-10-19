// Zustand und Abläufe der Ende-zu-Ende-Verschlüsselung (Phase 1: Schlüsselverwaltung, noch keine Nachrichten).
// Die UI (features/profile/verschluesselung_screen.dart) ruft die Abläufe auf; Netzwerkaufrufe, die der Server mit Step-up absichert
// (Sicherung ablegen/abrufen, Schlüsselwechsel), umhüllt die UI mit mitStepUp. Kein Schlüsselmaterial im Zustand, nie im Log.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../auth/auth_state.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'schluessel.dart';
import 'schluessel_speicher.dart';
import 'sicherheitscode.dart';
import 'sodium_crypto_provider.dart';
import 'uebertragung.dart';
import 'vertrauen.dart';
import 'wiederherstellung.dart';

/// Lädt libsodium einmal (Tests ersetzen den Provider durch einen Fake).
/// Ohne automatische Wiederholung (Riverpod 3 würde Fehler sonst mit Wartezeiten wiederholen): Scheitert das Laden, zeigt die Seite sofort "nicht verfügbar".
final cryptoProviderProvider = FutureProvider<CryptoProvider>((ref) => SodiumCryptoProvider.laden(), retry: (_, _) => null);

final schluesselSpeicherProvider = Provider<SchluesselSpeicher>((ref) => schluesselSpeicherErzeugen());

/// Name des Personenschlüssels im Schlüsselspeicher; gehört zu einer Person, damit ein Gerät mit zwei Konten nichts vermischt.
String personenschluesselName(String userId) => 'e2ee.pk.$userId';

/// Für localDataWiperProvider (main.dart): Beim Abmelden bzw. Personenwechsel wird der geheime Personenschlüssel vom Gerät entfernt
/// (ein neues Anmelden verlangt dann wieder "Gerät verbinden"). Die gemerkten öffentlichen Schlüssel (TOFU) bleiben, damit ein Abmelden
/// kein Weg ist, einen Schlüsselwechsel unbemerkt zu lassen.
Future<void> Function() e2eeDatenWiper(Ref ref) => () async {
  await ref.read(schluesselSpeicherProvider).loescheMitPraefix('e2ee.pk.');
  // Zustand und der Schlüssel im Arbeitsspeicher gehören der bisherigen Person: verwerfen (das Notifier-Ende überschreibt die Bytes)
  ref.invalidate(e2eeProvider);
};

enum E2eeStatus {
  /// Wird geprüft.
  laedt,

  /// libsodium lässt sich nicht laden (z. B. sodium.js fehlt) oder der Server ist nicht erreichbar.
  nichtVerfuegbar,

  /// Weder auf dem Server noch auf diesem Gerät gibt es einen Schlüssel: Einrichtung offen.
  keinSchluessel,

  /// Der Server kennt einen Schlüssel der Person, dieses Gerät hat ihn noch nicht: Gerät verbinden.
  geraetNichtVerbunden,

  /// Schlüssel auf diesem Gerät passt zum Server.
  bereit,

  /// Schlüssel auf diesem Gerät weicht vom Schlüssel auf dem Server ab (z. B. auf einem anderen Gerät gewechselt).
  abweichend,
}

class E2eeState {
  final E2eeStatus status;
  final String? meldung;

  /// Öffentliche Schlüssel dieser Person laut Server (null = keiner).
  final OeffentlicheSchluessel? serverSchluessel;
  final bool hatSicherung;
  final List<UserDto> mitglieder;
  final List<SchluesselWarnung> warnungen;

  /// Familien-Sicherheitscode (leer, solange niemand Schlüssel hat).
  final String sicherheitscode;

  const E2eeState({
    required this.status,
    this.meldung,
    this.serverSchluessel,
    this.hatSicherung = false,
    this.mitglieder = const [],
    this.warnungen = const [],
    this.sicherheitscode = '',
  });

  const E2eeState.laedt() : this(status: E2eeStatus.laedt);
}

/// Ergebnis der Einrichtung: der Wiederherstellungsschlüssel (nur im Arbeitsspeicher) und die Schlüsselversion, zu der die Sicherung gehört.
class Einrichtung {
  final Uint8List wiederherstellungsschluessel;
  final int keyVersion;
  const Einrichtung(this.wiederherstellungsschluessel, this.keyVersion);
}

/// Angebot für ein neues Gerät: QR-Text und Code zum Abtippen enthalten das Einmalgeheimnis, [gueltigBis] ist die Frist des Servers.
class UebertragungsAnzeige {
  final String qrText;
  final String codeText;
  final DateTime gueltigBis;
  const UebertragungsAnzeige({required this.qrText, required this.codeText, required this.gueltigBis});
}

class E2eeController extends Notifier<E2eeState> {
  Personenschluessel? _lokal;

  @override
  E2eeState build() {
    ref.onDispose(() => _lokal?.loeschen());
    return const E2eeState.laedt();
  }

  String get _userId {
    final id = ref.read(authProvider).user?.id;
    if (id == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du bist nicht angemeldet.');
    return id;
  }

  SchluesselSpeicher get _speicher => ref.read(schluesselSpeicherProvider);

  Future<CryptoProvider> _krypto() async {
    try {
      return await ref.read(cryptoProviderProvider.future);
    } on CryptoFehler {
      rethrow;
    } on Object {
      throw const CryptoFehler(CryptoFehlerArt.bibliothek, 'Die Verschlüsselung ist auf diesem Gerät nicht verfügbar.');
    }
  }

  Future<Personenschluessel?> _lokalLaden(CryptoProvider crypto) async {
    final bytes = await _speicher.lesen(personenschluesselName(_userId));
    if (bytes == null) return null;
    try {
      return Personenschluessel.ausBytes(crypto, bytes);
    } on CryptoFehler {
      // unbrauchbarer Eintrag: wie nicht vorhanden behandeln und entfernen
      await _speicher.loeschen(personenschluesselName(_userId));
      return null;
    } finally {
      loescheBytes(bytes);
    }
  }

  /// Öffentliche Schlüssel dieses Geräts (null, wenn keiner da ist); für die Phase 2 (Signieren, Entschlüsseln).
  Personenschluessel? get lokalerSchluessel => _lokal;

  /// Lädt Schlüsselstand, Mitglieder und Warnungen neu.
  Future<void> laden() async {
    final uid = ref.read(authProvider).user?.id;
    if (uid == null) return;
    try {
      final crypto = await _krypto();
      final api = ref.read(apiProvider);
      final eigene = await api.eigeneSchluessel();
      final mitglieder = await api.mitglieder();
      if (!ref.mounted) return;
      _lokal = await _lokalLaden(crypto);
      final server = eigene.schluessel;
      final pruefer = VertrauensPruefer(_speicher, eigeneUserId: uid);
      final warnungen = await pruefer.pruefen({for (final m in mitglieder) m.id: m.schluessel});
      final status = switch ((server, _lokal)) {
        (null, _) => E2eeStatus.keinSchluessel,
        (_, null) => E2eeStatus.geraetNichtVerbunden,
        (final s?, final l?) => _passt(l, s) ? E2eeStatus.bereit : E2eeStatus.abweichend,
      };
      if (!ref.mounted) return;
      state = E2eeState(
        status: status,
        serverSchluessel: server,
        hatSicherung: eigene.hatSicherung,
        mitglieder: mitglieder,
        warnungen: warnungen,
        sicherheitscode: familienSicherheitscode([for (final m in mitglieder) if (m.schluessel != null) MitgliedSchluessel(m.id, m.schluessel!)]),
      );
    } on CryptoFehler catch (e) {
      if (ref.mounted) state = E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: e.meldung);
    } on ApiException catch (e) {
      if (ref.mounted) state = E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: e.message);
    }
  }

  static bool _passt(Personenschluessel lokal, OeffentlicheSchluessel server) => server.gleichWie(lokal.oeffentlich(server.version));

  /// Erstmalige Einrichtung: Schlüssel erzeugen (oder einen vorhandenen lokalen veröffentlichen), auf dem Gerät ablegen und beim Server
  /// eintragen. Liefert den Wiederherstellungsschlüssel zum einmaligen Anzeigen; die Sicherung legt [sicherungAblegen] danach an.
  Future<Einrichtung> einrichten() async {
    final crypto = await _krypto();
    final name = personenschluesselName(_userId);
    final vorhanden = _lokal ?? await _lokalLaden(crypto);
    final schluessel = vorhanden ?? Personenschluessel.erzeugen(crypto);
    if (vorhanden == null) await _speicher.schreiben(name, schluessel.exportieren());
    final OeffentlicheSchluessel ver;
    try {
      ver = await ref.read(apiProvider).schluesselAnlegen(enc: schluessel.oeffentlich(1).encBase64, sign: schluessel.oeffentlich(1).signBase64);
    } on Object {
      if (vorhanden == null) await _speicher.loeschen(name);
      rethrow;
    }
    _lokal = schluessel;
    await laden();
    return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), ver.version);
  }

  /// Neuer Schlüssel nach Totalverlust (kein Gerät, kein Wiederherstellungsschlüssel) oder bei Verdacht auf Kompromittierung. Mit Step-up
  /// (UI). Frühere verschlüsselte Inhalte lassen sich damit NICHT lesen. Die anderen Mitglieder werden gewarnt.
  Future<Einrichtung> schluesselWechseln() async {
    final crypto = await _krypto();
    final name = personenschluesselName(_userId);
    final alt = await _speicher.lesen(name);
    final neu = Personenschluessel.erzeugen(crypto);
    await _speicher.schreiben(name, neu.exportieren());
    final OeffentlicheSchluessel ver;
    try {
      ver = await ref.read(apiProvider).schluesselWechseln(enc: neu.oeffentlich(1).encBase64, sign: neu.oeffentlich(1).signBase64);
    } on Object {
      if (alt == null) {
        await _speicher.loeschen(name);
      } else {
        await _speicher.schreiben(name, alt);
      }
      rethrow;
    }
    _lokal = neu;
    await laden();
    return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), ver.version);
  }

  /// Legt die Sicherung (Personenschlüssel, mit dem Wiederherstellungsschlüssel verschlüsselt) beim Server ab. Mit Step-up (UI).
  Future<void> sicherungAblegen(Einrichtung e) async {
    final crypto = await _krypto();
    final schluessel = _lokal ?? await _lokalLaden(crypto);
    if (schluessel == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel.');
    final blob = Wiederherstellung.sicherungErstellen(
      crypto,
      schluessel: schluessel,
      wiederherstellungsschluessel: e.wiederherstellungsschluessel,
      userId: _userId,
      keyVersion: e.keyVersion,
    );
    await ref.read(apiProvider).sicherungAblegen(blob: blob, keyVersion: e.keyVersion);
    await laden();
  }

  /// Neuen Wiederherstellungsschlüssel für den vorhandenen Personenschlüssel erzeugen (ersetzt die alte Sicherung nach [sicherungAblegen]).
  Future<Einrichtung> neuerWiederherstellungsschluessel() async {
    final crypto = await _krypto();
    final s = state.serverSchluessel;
    if (_lokal == null || s == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel.');
    return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), s.version);
  }

  Future<void> _lokalUebernehmen(Personenschluessel schluessel, int keyVersion) async {
    final server = state.serverSchluessel ?? (await ref.read(apiProvider).eigeneSchluessel()).schluessel;
    if (server == null || server.version != keyVersion || !server.gleichWie(schluessel.oeffentlich(server.version))) {
      schluessel.loeschen();
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüssel passt nicht mehr zu deinem Konto (er wurde inzwischen gewechselt).');
    }
    await _speicher.schreiben(personenschluesselName(_userId), schluessel.exportieren());
    _lokal = schluessel;
    await laden();
  }

  /// Gerät mit dem Wiederherstellungsschlüssel verbinden (Step-up für den Abruf der Sicherung; UI).
  Future<void> mitWiederherstellungVerbinden(String eingabe) async {
    final crypto = await _krypto();
    final wk = Wiederherstellung.lesen(eingabe);
    final blob = await ref.read(apiProvider).sicherungAbrufen();
    final Sicherung sicherung;
    try {
      sicherung = Wiederherstellung.sicherungOeffnen(crypto, blob: blob.blob, wiederherstellungsschluessel: wk, userId: _userId);
    } on CryptoFehler catch (e) {
      if (e.art == CryptoFehlerArt.entschluesselung) {
        throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Der Wiederherstellungsschlüssel passt nicht zu deiner Sicherung.');
      }
      rethrow;
    } finally {
      loescheBytes(wk);
    }
    await _lokalUebernehmen(sicherung.schluessel, sicherung.keyVersion);
  }

  /// Auf dem vorhandenen Gerät: Übertragung für ein neues Gerät anlegen (2 Minuten gültig, einmal einlösbar).
  Future<UebertragungsAnzeige> uebertragungAnbieten() async {
    final crypto = await _krypto();
    final schluessel = _lokal;
    final server = state.serverSchluessel;
    if (schluessel == null || server == null || !_passt(schluessel, server)) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Dieses Gerät hat keinen passenden Schlüssel zum Übertragen.');
    }
    final angebot = Uebertragung.anbieten(crypto, schluessel: schluessel, userId: _userId, keyVersion: server.version);
    final bis = await ref.read(apiProvider).uebertragungAnlegen(suchkennung: angebot.suchkennung, blob: angebot.blob);
    final anzeige = UebertragungsAnzeige(qrText: Uebertragung.qrText(angebot.geheimnis), codeText: Uebertragung.codeText(angebot.geheimnis), gueltigBis: bis);
    loescheBytes(angebot.geheimnis);
    return anzeige;
  }

  /// Auf dem neuen Gerät: QR-Text oder Code einlesen, Übertragung beim Server einlösen und den Schlüssel übernehmen.
  Future<void> uebertragungAnnehmen(String eingabe) async {
    final crypto = await _krypto();
    final geheimnis = Uebertragung.geheimnisLesen(eingabe);
    final BlobDto blob;
    try {
      blob = await ref.read(apiProvider).uebertragungEinloesen(Uebertragung.suchkennung(crypto, geheimnis));
    } on ApiException catch (e) {
      loescheBytes(geheimnis);
      if (e.status == 404) {
        throw const CryptoFehler(CryptoFehlerArt.format, 'Der Code ist abgelaufen oder schon benutzt. Zeige auf dem anderen Gerät einen neuen an.');
      }
      rethrow;
    }
    final Personenschluessel schluessel;
    try {
      schluessel = Uebertragung.oeffnen(crypto, blob: blob.blob, geheimnis: geheimnis, userId: _userId, keyVersion: blob.keyVersion);
    } finally {
      loescheBytes(geheimnis);
    }
    await _lokalUebernehmen(schluessel, blob.keyVersion);
  }

  /// Entfernt den Schlüssel von diesem Gerät (z. B. bei abweichendem Schlüssel), danach kann das Gerät neu verbunden werden.
  Future<void> lokalenSchluesselVerwerfen() async {
    await _speicher.loeschen(personenschluesselName(_userId));
    _lokal?.loeschen();
    _lokal = null;
    await laden();
  }

  /// Neuen Schlüssel einer Person nach ausdrücklicher Bestätigung akzeptieren.
  Future<void> warnungAkzeptieren(String userId) async {
    final w = state.warnungen.where((x) => x.userId == userId).firstOrNull;
    if (w == null) return;
    await VertrauensPruefer(_speicher, eigeneUserId: _userId).akzeptieren(userId, w.aktuell);
    await laden();
  }
}

final e2eeProvider = NotifierProvider<E2eeController, E2eeState>(E2eeController.new);
