// Zustand und Abläufe der Ende-zu-Ende-Verschlüsselung (Phase 1: Schlüsselverwaltung, noch keine Nachrichten).
// Die UI (features/profile/verschluesselung_screen.dart) ruft die Abläufe auf; Netzwerkaufrufe, die der Server mit Step-up absichert
// (Sicherung ablegen/abrufen, Schlüsselwechsel), umhüllt die UI mit mitStepUp. Kein Schlüsselmaterial im Zustand, nie im Log.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../api/models.dart';
import '../auth/auth_state.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'pw_ablauf.dart';
import 'schluessel.dart';
import 'schluessel_speicher.dart';
import 'sicherheitscode.dart';
import 'sodium_crypto_provider.dart';
import 'uebertragung.dart';
import 'vertrauen.dart';
import 'wiederherstellung.dart';

/// Vorbereiteter Passwortwechsel: abgeleiteter authKey/kek des neuen Passworts und, falls möglich, die neue Passwort-Sicherung (lokal geprüft). Enthält Schlüsselmaterial:
/// nach Gebrauch [loeschen] aufrufen.
class PwWechselEntwurf {
  final PwAbleitung _ableitung;
  final PwEntwurf? sicherung;
  PwWechselEntwurf._(this._ableitung, this.sicherung);

  /// Der abgeleitete Anmelde-Schlüssel (Base64url), den der Server statt des Passworts bekommt.
  String get authKey => _ableitung.keys.authKeyBase64;

  void loeschen() => _ableitung.keys.loeschen();
}

class PwWechselErgebnis {
  /// Die Passwort-Sicherung wurde mit dem neuen Passwort neu angelegt und gilt jetzt.
  final bool sicherungAktualisiert;

  /// Es gibt eine Passwort-Sicherung, sie gehört aber noch zum ALTEN Passwort (auf diesem Gerät fehlt der Schlüssel): bitte neu anlegen.
  final bool sicherungVeraltet;
  const PwWechselErgebnis({required this.sicherungAktualisiert, required this.sicherungVeraltet});
}

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
  try {
    await ref.read(schluesselSpeicherProvider).loescheMitPraefix('e2ee.pk.');
    await ref.read(schluesselSpeicherProvider).loescheMitPraefix('e2ee.kv.');
  } finally {
    // Zustand und der Schlüssel im Arbeitsspeicher gehören der bisherigen Person: verwerfen (der Neuaufbau überschreibt die Bytes), auch wenn das Löschen scheiterte
    ref.invalidate(e2eeProvider);
  }
};

/// Führt alle [wiper] unabhängig voneinander aus (ein Fehler eines Wipers hindert die anderen nie, z. B. darf ein Datenbankfehler das Löschen des
/// Personenschlüssels nicht verhindern) und wirft danach den ersten Fehler.
Future<void> Function() wiperVerkettet(List<Future<void> Function()> wiper) => () async {
  Object? erster;
  StackTrace? stapel;
  for (final w in wiper) {
    try {
      await w();
    } on Object catch (e, st) {
      erster ??= e;
      stapel ??= st;
    }
  }
  if (erster != null) Error.throwWithStackTrace(erster, stapel!);
};

/// Name des Zwischenstands beim Schlüsselwechsel: der bisherige Schlüssel bleibt bis zur Gewissheit über den Ausgang auf dem Gerät.
String personenschluesselAltName(String userId) => 'e2ee.pk.$userId.alt';

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

  /// Die Ablage der gemerkten Schlüssel ist beschädigt: Die Oberfläche bietet "Vertrauen zurücksetzen" an.
  final bool vertrauenDefekt;

  /// Der Server bietet die Passwort-Sicherung an (Schalter E2EE_PW_BACKUP; sonst bleibt die Funktion unsichtbar).
  final bool pwSicherungVerfuegbar;

  /// Schlüsselversion, für die auf DIESEM Gerät eine vollständig verifizierte Passwort-Sicherung vermerkt ist (null: keine).
  final int? pwSicherungVersion;

  /// Familien-Sicherheitscode (leer, solange niemand Schlüssel hat).
  final String sicherheitscode;

  const E2eeState({
    required this.status,
    this.meldung,
    this.serverSchluessel,
    this.hatSicherung = false,
    this.mitglieder = const [],
    this.warnungen = const [],
    this.vertrauenDefekt = false,
    this.pwSicherungVerfuegbar = false,
    this.pwSicherungVersion,
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
    // Dieselbe Notifier-Instanz wird nach invalidate neu gebaut: den Schlüssel der bisherigen Person nie behalten
    _lokal?.loeschen();
    _lokal = null;
    ref.onDispose(() => _lokal?.loeschen());
    return const E2eeState.laedt();
  }

  String get _userId {
    final id = ref.read(authProvider).user?.id;
    if (id == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du bist nicht angemeldet.');
    return id;
  }

  SchluesselSpeicher get _speicher => ref.read(schluesselSpeicherProvider);
  FampadApi get _api => ref.read(apiProvider);

  Future<CryptoProvider> _krypto() async {
    try {
      return await ref.read(cryptoProviderProvider.future);
    } on CryptoFehler {
      rethrow;
    } on Object {
      throw const CryptoFehler(CryptoFehlerArt.bibliothek, 'Die Verschlüsselung ist auf diesem Gerät nicht verfügbar.');
    }
  }

  /// Liest den lokalen Schlüssel. Fehlt er, null. Ein eindeutig dauerhaft unbrauchbarer Eintrag wird entfernt (null); ein vorübergehender
  /// Fehler des Speichers geht weiter, der Eintrag bleibt (ein späterer Versuch kann klappen).
  Future<Personenschluessel?> _lokalLaden(CryptoProvider crypto) async {
    final name = personenschluesselName(_userId);
    final Uint8List? bytes;
    try {
      bytes = await _speicher.lesen(name);
    } on SchluesselSpeicherFehler catch (e) {
      if (!e.dauerhaft) rethrow;
      await _speicher.loeschen(name);
      return null;
    }
    if (bytes == null) return null;
    try {
      return Personenschluessel.ausBytes(crypto, bytes);
    } on CryptoFehler {
      await _speicher.loeschen(name);
      return null;
    } finally {
      loescheBytes(bytes);
    }
  }

  static String _versionName(String userId) => 'e2ee.kv.$userId';

  /// Merkt die Schlüsselversion der eigenen Person (öffentlich, kein Geheimnis): so kann der Chat auch ohne Verbindung zum Server lesen und schreiben.
  Future<void> _versionMerken(String userId, int version) async {
    try {
      await _speicher.schreiben(_versionName(userId), utf8Bytes('$version'));
    } on Object {
      // nur eine Erleichterung für den Offline-Betrieb
    }
  }

  /// Vermerk (öffentlich, kein Geheimnis): Für diese Schlüsselversion hat DIESES Gerät die Passwort-Sicherung vollständig verifiziert (lokale Probe,
  /// Round-Trip, Bestätigung beim Server). Liegt unter dem Präfix 'e2ee.kv.', wird also beim Abmelden mit entfernt.
  static String _pwVermerkName(String userId) => 'e2ee.kv.pw.$userId';

  Future<int?> _pwVermerkLesen(String userId) async {
    try {
      final b = await _speicher.lesen(_pwVermerkName(userId));
      if (b == null) return null;
      return int.tryParse(String.fromCharCodes(b));
    } on Object {
      return null;
    }
  }

  /// Zuletzt vom Server erfahrene Schlüsselversion dieser Person (null: nie erfahren).
  Future<int?> letzteBekannteVersion() async {
    final id = ref.read(authProvider).user?.id;
    if (id == null) return null;
    try {
      final b = await _speicher.lesen(_versionName(id));
      if (b == null) return null;
      return int.tryParse(String.fromCharCodes(b));
    } on Object {
      return null;
    }
  }

  /// Öffentliche Schlüssel dieses Geräts (null, wenn keiner da ist); für die Phase 2 (Signieren, Entschlüsseln).
  Personenschluessel? get lokalerSchluessel => _lokal;

  /// Frischer Stand des eigenen Schlüssels beim Server (nie aus dem Zustand).
  Future<OeffentlicheSchluessel?> _serverSchluessel() async => (await _api.eigeneSchluessel()).schluessel;

  /// Lädt Schlüsselstand, Mitglieder und Warnungen neu.
  Future<void> laden() async {
    final uid = ref.read(authProvider).user?.id;
    if (uid == null) return;
    try {
      final crypto = await _krypto();
      // der lokale Schlüssel gehört zum Gerät: er steht auch ohne Verbindung zum Server zur Verfügung (Chat lesen und schreiben offline)
      try {
        _lokal ??= await _lokalLaden(crypto);
      } on SchluesselSpeicherFehler {
        // der Schlüsselspeicher ist gerade nicht lesbar: unten wird es erneut versucht und gemeldet
      }
      final eigene = await _api.eigeneSchluessel();
      final mitglieder = await _api.mitglieder();
      if (!ref.mounted) return;
      _lokal = await _lokalLaden(crypto);
      await _zwischenstandAufloesen(crypto, eigene.schluessel);
      final server = eigene.schluessel;
      if (server != null) await _versionMerken(uid, server.version);
      final pruefer = VertrauensPruefer(_speicher, eigeneUserId: uid);
      final warnungen = await pruefer.pruefen({for (final m in mitglieder) m.id: m.schluessel});
      await pruefer.standPruefen(); // ein beschädigter Stand der Chat-Mitglieder wird wie eine beschädigte Merkliste gemeldet
      final status = switch ((server, _lokal)) {
        (null, _) => E2eeStatus.keinSchluessel,
        (_, null) => E2eeStatus.geraetNichtVerbunden,
        (final s?, final l?) => _passt(l, s) ? E2eeStatus.bereit : E2eeStatus.abweichend,
      };
      // Passwort-Sicherung: nur sichtbar, wenn der Server sie anbietet (Fehler = aus); der Vermerk "verifiziert" liegt auf diesem Gerät
      final pwVerfuegbar = server != null && await _api.pwSicherungVerfuegbar();
      final pwVersion = pwVerfuegbar ? await _pwVermerkLesen(uid) : null;
      if (!ref.mounted) return;
      state = E2eeState(
        status: status,
        serverSchluessel: server,
        hatSicherung: eigene.hatSicherung,
        pwSicherungVerfuegbar: pwVerfuegbar,
        pwSicherungVersion: pwVersion,
        mitglieder: mitglieder,
        warnungen: warnungen,
        // nur aktive Mitglieder: wartende gehören noch nicht zur Familie
        sicherheitscode: familienSicherheitscode([
          for (final m in mitglieder)
            if (m.schluessel != null && m.status == MemberStatus.active) MitgliedSchluessel(m.id, m.schluessel!),
        ]),
      );
    } on VertrauensAblageDefekt {
      if (ref.mounted) {
        state = const E2eeState(
          status: E2eeStatus.nichtVerfuegbar,
          vertrauenDefekt: true,
          meldung: 'Die gemerkten Schlüssel der Familie sind auf diesem Gerät beschädigt. Aus Sicherheitsgründen werden sie nicht stillschweigend ersetzt. Du kannst das Vertrauen zurücksetzen und die Schlüssel danach neu prüfen.',
        );
      }
    } on CryptoFehler catch (e) {
      if (ref.mounted) state = E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: e.meldung);
    } on SchluesselSpeicherFehler {
      if (ref.mounted) state = const E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: 'Der Schlüsselspeicher dieses Geräts ist gerade nicht lesbar. Bitte versuche es gleich noch einmal.');
    } on ApiException catch (e) {
      if (ref.mounted) state = E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: e.message);
    }
  }

  static bool _passt(Personenschluessel lokal, OeffentlicheSchluessel server) => server.gleichWie(lokal.oeffentlich(server.version));

  /// Räumt einen liegengebliebenen Zwischenstand eines Schlüsselwechsels auf (Verbindung brach nach dem Absenden ab, App wurde beendet):
  /// passt der Schlüssel des Servers zum neuen lokalen, kann der alte weg; passt er zum alten, ist der Wechsel nicht angekommen und der alte gilt wieder.
  Future<void> _zwischenstandAufloesen(CryptoProvider crypto, OeffentlicheSchluessel? server) async {
    final altName = personenschluesselAltName(_userId);
    final Uint8List? roh;
    try {
      roh = await _speicher.lesen(altName);
    } on SchluesselSpeicherFehler {
      return;
    }
    if (roh == null) return;
    Personenschluessel? alt;
    try {
      alt = Personenschluessel.ausBytes(crypto, roh);
    } on CryptoFehler {
      await _speicher.loeschen(altName);
      return;
    } finally {
      loescheBytes(roh);
    }
    final neuPasst = server != null && _lokal != null && _passt(_lokal!, server);
    final altPasst = server != null && _passt(alt, server);
    if (neuPasst) {
      alt.loeschen();
      await _speicher.loeschen(altName);
    } else if (altPasst) {
      await _speicher.schreiben(personenschluesselName(_userId), alt.exportieren());
      _lokal?.loeschen();
      _lokal = alt;
      await _speicher.loeschen(altName);
    } else {
      alt.loeschen();
    }
  }

  /// Unklarer Ausgang (Netzfehler nach dem Absenden): fragt den Server frisch und entscheidet daran, ob der Schlüssel [eigener] dort angekommen ist.
  /// Gelingt auch diese Abfrage nicht, bleibt der Zustand unklar: nichts wird zurückgerollt (der Schlüssel geht nie verloren) und der Aufrufer
  /// meldet das; das nächste Laden entscheidet.
  Future<bool> _angekommen(Personenschluessel eigener) async {
    try {
      final s = await _serverSchluessel();
      return s != null && _passt(eigener, s);
    } on ApiException {
      throw const CryptoFehler(
        CryptoFehlerArt.schluessel,
        'Die Verbindung brach ab, ob der Schlüssel gespeichert wurde, ist unklar. Öffne die Seite in einem Moment neu: Sie klärt das.',
      );
    }
  }

  /// Erstmalige Einrichtung: Schlüssel erzeugen (oder einen vorhandenen lokalen veröffentlichen), auf dem Gerät ablegen und beim Server
  /// eintragen. Liefert den Wiederherstellungsschlüssel zum einmaligen Anzeigen; die Sicherung legt [sicherungAblegen] danach an.
  Future<Einrichtung> einrichten() async {
    final crypto = await _krypto();
    final name = personenschluesselName(_userId);
    final vorhanden = _lokal ?? await _lokalLaden(crypto);
    final schluessel = vorhanden ?? Personenschluessel.erzeugen(crypto);
    if (vorhanden == null) await _speicher.schreiben(name, schluessel.exportieren());
    Future<void> zurueck() async {
      if (vorhanden == null) {
        await _speicher.loeschen(name);
        schluessel.loeschen();
      }
    }

    OeffentlicheSchluessel ver;
    try {
      ver = await _api.schluesselAnlegen(enc: schluessel.oeffentlich(1).encBase64, sign: schluessel.oeffentlich(1).signBase64);
    } on ApiException catch (e) {
      if (!e.istNetzwerk) {
        await zurueck();
        rethrow;
      }
      // Netzfehler: vielleicht hat der Server den Schlüssel schon gespeichert
      if (!await _angekommen(schluessel)) {
        await zurueck();
        rethrow;
      }
      ver = (await _serverSchluessel())!;
    } on Object {
      await zurueck();
      rethrow;
    }
    _lokal = schluessel;
    await laden();
    return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), ver.version);
  }

  /// Neuer Schlüssel nach Totalverlust (kein Gerät, kein Wiederherstellungsschlüssel) oder bei Verdacht auf Kompromittierung. Mit Step-up
  /// (UI). Frühere verschlüsselte Inhalte lassen sich damit NICHT lesen. Die anderen Mitglieder werden gewarnt. Der Server prüft die Version, die
  /// dieses Gerät frisch von ihm erfahren hat (409, wenn ein anderes Gerät schneller war).
  Future<Einrichtung> schluesselWechseln() async {
    final crypto = await _krypto();
    final name = personenschluesselName(_userId);
    final altName = personenschluesselAltName(_userId);
    final aktuell = await _serverSchluessel();
    if (aktuell == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du hast die Verschlüsselung noch nicht eingerichtet.');
    final alt = await _speicher.lesen(name);
    final neu = Personenschluessel.erzeugen(crypto);
    try {
      // der bisherige Schlüssel bleibt als Zwischenstand liegen, bis der Ausgang feststeht
      if (alt != null) await _speicher.schreiben(altName, alt);
      await _speicher.schreiben(name, neu.exportieren());
      Future<void> zurueck() async {
        if (alt == null) {
          await _speicher.loeschen(name);
        } else {
          await _speicher.schreiben(name, alt);
        }
        await _speicher.loeschen(altName);
        neu.loeschen();
      }

      OeffentlicheSchluessel ver;
      try {
        ver = await _api.schluesselWechseln(enc: neu.oeffentlich(1).encBase64, sign: neu.oeffentlich(1).signBase64, erwarteteVersion: aktuell.version);
      } on ApiException catch (e) {
        if (!e.istNetzwerk) {
          await zurueck();
          rethrow;
        }
        if (!await _angekommen(neu)) {
          await zurueck();
          rethrow;
        }
        ver = (await _serverSchluessel())!;
      } on Object {
        await zurueck();
        rethrow;
      }
      await _speicher.loeschen(altName);
      // der bisherige öffentliche Schlüssel bleibt auf diesem Gerät gemerkt: eigene ältere Nachrichten und Wraps lassen sich weiter prüfen (die Historie des Servers zählt nie)
      try {
        final pruefer = VertrauensPruefer(_speicher, eigeneUserId: _userId);
        await pruefer.akzeptieren(_userId, aktuell);
        await pruefer.akzeptieren(_userId, ver);
      } on Object {
        // nur eine Erleichterung für alte Signaturen
      }
      _lokal?.loeschen();
      _lokal = neu;
      await laden();
      return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), ver.version);
    } finally {
      if (alt != null) loescheBytes(alt);
    }
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
    await _api.sicherungAblegen(blob: blob, keyVersion: e.keyVersion);
    await laden();
  }

  /// Neuen Wiederherstellungsschlüssel für den vorhandenen Personenschlüssel erzeugen (ersetzt die alte Sicherung nach [sicherungAblegen]).
  Future<Einrichtung> neuerWiederherstellungsschluessel() async {
    final crypto = await _krypto();
    final s = await _serverSchluessel();
    if (_lokal == null || s == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel.');
    return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), s.version);
  }

  /// Übernimmt einen empfangenen Schlüssel erst, wenn er zum FRISCH vom Server geholten öffentlichen Schlüssel passt.
  Future<void> _lokalUebernehmen(Personenschluessel schluessel, int keyVersion) async {
    final server = await _serverSchluessel();
    if (server == null || server.version != keyVersion || !server.gleichWie(schluessel.oeffentlich(server.version))) {
      schluessel.loeschen();
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüssel passt nicht mehr zu deinem Konto (er wurde inzwischen gewechselt).');
    }
    await _speicher.schreiben(personenschluesselName(_userId), schluessel.exportieren());
    _lokal?.loeschen();
    _lokal = schluessel;
    await laden();
  }

  /// Gerät mit dem Wiederherstellungsschlüssel verbinden (Step-up für den Abruf der Sicherung; UI).
  Future<void> mitWiederherstellungVerbinden(String eingabe) async {
    final crypto = await _krypto();
    final wk = Wiederherstellung.lesen(eingabe);
    try {
      final blob = await _api.sicherungAbrufen();
      final Sicherung sicherung;
      try {
        sicherung = Wiederherstellung.sicherungOeffnen(crypto, blob: blob.blob, wiederherstellungsschluessel: wk, userId: _userId);
      } on CryptoFehler catch (e) {
        if (e.art == CryptoFehlerArt.entschluesselung) {
          throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Der Wiederherstellungsschlüssel passt nicht zu deiner Sicherung.');
        }
        rethrow;
      }
      await _lokalUebernehmen(sicherung.schluessel, sicherung.keyVersion);
    } finally {
      loescheBytes(wk);
    }
  }

  /// Auf dem vorhandenen Gerät: Übertragung für ein neues Gerät anlegen (2 Minuten gültig, einmal einlösbar). Die Schlüsselversion kommt frisch
  /// vom Server und geht mit; der Server weist sie bei Abweichung zurück.
  Future<UebertragungsAnzeige> uebertragungAnbieten() async {
    final crypto = await _krypto();
    final schluessel = _lokal;
    final server = await _serverSchluessel();
    if (schluessel == null || server == null || !_passt(schluessel, server)) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Dieses Gerät hat keinen passenden Schlüssel zum Übertragen.');
    }
    final angebot = Uebertragung.anbieten(crypto, schluessel: schluessel, userId: _userId, keyVersion: server.version);
    try {
      final bis = await _api.uebertragungAnlegen(suchkennung: angebot.suchkennung, blob: angebot.blob, keyVersion: server.version);
      return UebertragungsAnzeige(qrText: Uebertragung.qrText(angebot.geheimnis), codeText: Uebertragung.codeText(angebot.geheimnis), gueltigBis: bis);
    } finally {
      loescheBytes(angebot.geheimnis);
    }
  }

  /// Auf dem neuen Gerät: QR-Text oder Code einlesen, Übertragung beim Server einlösen und den Schlüssel übernehmen.
  Future<void> uebertragungAnnehmen(String eingabe) async {
    final crypto = await _krypto();
    final geheimnis = Uebertragung.geheimnisLesen(eingabe);
    try {
      final BlobDto blob;
      try {
        blob = await _api.uebertragungEinloesen(Uebertragung.suchkennung(crypto, geheimnis));
      } on ApiException catch (e) {
        if (e.status == 404) {
          throw const CryptoFehler(CryptoFehlerArt.format, 'Der Code ist abgelaufen oder schon benutzt. Zeige auf dem anderen Gerät einen neuen an.');
        }
        rethrow;
      }
      final schluessel = Uebertragung.oeffnen(crypto, blob: blob.blob, geheimnis: geheimnis, userId: _userId, keyVersion: blob.keyVersion);
      await _lokalUebernehmen(schluessel, blob.keyVersion);
    } finally {
      loescheBytes(geheimnis);
    }
  }

  PwSicherungAblauf _pwAblauf(CryptoProvider crypto) {
    final email = ref.read(authProvider).user?.email;
    if (email == null || email.trim().isEmpty) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Zu deinem Konto gehört keine E-Mail-Adresse.');
    return PwSicherungAblauf(crypto: crypto, api: _api, userId: _userId, email: email);
  }

  /// Passwort-Sicherung, Schritt 1 (rechenintensiv, ohne Step-up): Salt vom Server, Blob erzeugen, lokale Probe. Sendet nichts an die Sicherung und
  /// verändert nichts (weder Schlüssel noch Vermerk). Der alte Weg (Wiederherstellungsschlüssel, QR) bleibt unberührt.
  Future<PwEntwurf> pwSicherungVorbereiten(String passwort) async {
    final crypto = await _krypto();
    final lokal = _lokal ?? await _lokalLaden(crypto);
    if (lokal == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel.');
    final server = await _serverSchluessel();
    if (server == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du hast die Verschlüsselung noch nicht eingerichtet.');
    return _pwAblauf(crypto).vorbereiten(lokal: lokal, server: server, passwort: passwort);
  }

  /// Schritt 2 und 3 (Step-up legt die UI um den Aufruf): ablegen, Round-Trip, beim Server als verifiziert melden und erst dann auf diesem Gerät
  /// vermerken. Scheitert etwas, bleibt der bisherige Vermerk unverändert: der Server hält die bisherige Sicherung bis zur Bestätigung der neuen
  /// gültig (das bisherige Passwort öffnet sie weiter); ein verlangtes Step-up ist kein Fehler (die UI wiederholt den Aufruf).
  Future<bool> pwSicherungAblegen(PwEntwurf entwurf, String passwort) async {
    final crypto = await _krypto();
    final lokal = _lokal ?? await _lokalLaden(crypto);
    final server = await _serverSchluessel();
    if (lokal == null || server == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel.');
    await _pwAblauf(crypto).ablegenUndPruefen(entwurf, passwort: passwort, lokal: lokal, serverVorher: server);
    try {
      await _speicher.schreiben(_pwVermerkName(_userId), utf8Bytes('${entwurf.keyVersion}'));
    } on Object {
      // ohne Vermerk zeigt die Seite "nicht bestätigt"; die Sicherung selbst ist verifiziert
    }
    await laden();
    return true;
  }

  /// Passwortwechsel, Schritt 1 (rechenintensiv, ohne Step-up): aus dem NEUEN Passwort authKey und kek ableiten und, wenn dieses Gerät den Personenschlüssel
  /// hat, die neue Passwort-Sicherung vorbereiten und lokal prüfen. Sendet nichts und verändert nichts. Schlüsselprobleme verhindern den Wechsel nicht
  /// (dann gibt es keine neue Sicherung und das Ergebnis meldet es). Der Aufrufer ruft danach [PwWechselEntwurf.loeschen].
  Future<PwWechselEntwurf> passwortWechselVorbereiten(String neuesPasswort) async {
    final crypto = await _krypto();
    final ablauf = _pwAblauf(crypto);
    final a = await ablauf.ableiten(neuesPasswort);
    PwEntwurf? sicherung;
    try {
      final lokal = _lokal ?? await _lokalLaden(crypto);
      final server = lokal == null ? null : await _serverSchluessel();
      if (lokal != null && server != null) sicherung = ablauf.entwurfMit(lokal: lokal, server: server, abgeleitet: a);
    } on CryptoFehler {
      sicherung = null; // Schlüssel passt nicht zum Konto o. Ä.: der Passwortwechsel läuft ohne neue Sicherung weiter
    } on ApiException {
      a.keys.loeschen();
      rethrow;
    }
    return PwWechselEntwurf._(a, sicherung);
  }

  /// Passwortwechsel, Schritt 2 (Step-up legt die UI um den Aufruf; er darf wiederholt werden): Hat die Person eine Passwort-Sicherung und dieses Gerät den
  /// Schlüssel, wird die neue Sicherung abgelegt und per Round-Trip geprüft, ohne sie zu bestätigen; dann ändert der Server Passwort und Sicherung in EINER
  /// Transaktion (die alte Sicherung gilt bis dahin unverändert weiter). Scheitert die Prüfung, bleibt alles beim Alten (bisheriges Passwort, bisherige
  /// Sicherung). Ohne Sicherung oder ohne Schlüssel auf dem Gerät wird nur das Passwort geändert; die Antwort sagt, ob die Sicherung dann veraltet ist.
  Future<PwWechselErgebnis> passwortWechselAusfuehren(PwWechselEntwurf w, String neuesPasswort) async {
    var hatSicherung = false;
    try {
      await _api.pwSicherungAbrufen();
      hatSicherung = true;
    } on ApiException catch (e) {
      if (e.code != 'not_found') rethrow;
    }
    String? id;
    if (hatSicherung && w.sicherung != null) {
      final crypto = await _krypto();
      final lokal = _lokal ?? await _lokalLaden(crypto);
      final server = await _serverSchluessel();
      if (lokal != null && server != null) {
        id = await _pwAblauf(crypto).ablegenUndPruefen(w.sicherung!, passwort: neuesPasswort, lokal: lokal, serverVorher: server, bestaetigen: false);
      }
    }
    await _api.passwortAendern(authKey: w.authKey, pwBackupId: id);
    if (id != null) {
      try {
        await _speicher.schreiben(_pwVermerkName(_userId), utf8Bytes('${w.sicherung!.keyVersion}'));
      } on Object {
        // ohne Vermerk zeigt die Seite "nicht bestätigt"; die Sicherung selbst ist verifiziert
      }
      try {
        await laden();
      } on Object {
        // nur die Anzeige
      }
    }
    return PwWechselErgebnis(sicherungAktualisiert: id != null, sicherungVeraltet: hatSicherung && id == null);
  }

  /// Gerät ohne Schlüssel mit der Passwort-Sicherung verbinden (Step-up für den Abruf; UI). Der Schlüssel wird erst übernommen, wenn er zum
  /// frisch vom Server geholten öffentlichen Schlüssel passt ('_lokalUebernehmen').
  Future<void> mitPasswortVerbinden(String passwort) async {
    final crypto = await _krypto();
    final r = await _pwAblauf(crypto).abrufenUndOeffnen(passwort);
    await _lokalUebernehmen(r.schluessel, r.keyVersion);
  }

  /// Entfernt den Schlüssel von diesem Gerät (z. B. bei abweichendem Schlüssel), danach kann das Gerät neu verbunden werden.
  Future<void> lokalenSchluesselVerwerfen() async {
    await _speicher.loeschen(personenschluesselName(_userId));
    await _speicher.loeschen(personenschluesselAltName(_userId));
    _lokal?.loeschen();
    _lokal = null;
    await laden();
  }

  /// Bewusstes Zurücksetzen der gemerkten Schlüssel nach einer beschädigten Ablage (die Oberfläche warnt vorher).
  Future<void> vertrauenZuruecksetzen() async {
    await VertrauensPruefer(_speicher, eigeneUserId: _userId).zuruecksetzen();
    await laden();
  }

  /// Neuen Schlüssel einer Person nach ausdrücklicher Bestätigung akzeptieren.
  Future<void> warnungAkzeptieren(String userId) async {
    final w = state.warnungen.where((x) => x.userId == userId).firstOrNull;
    if (w == null) return;
    if (w.rueckfall) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ein Rückfall auf eine ältere Schlüsselversion lässt sich nicht bestätigen.');
    await VertrauensPruefer(_speicher, eigeneUserId: _userId).akzeptieren(userId, w.aktuell);
    await laden();
  }

  /// Signatur-Schlüssel eines Absenders in der Version, mit der er eine Nachricht signiert hat (Phase 2, Hülle `sender_key_version`):
  /// Die gemerkte (TOFU) Version zählt, nie ein Schlüssel vom Server; eine NEUERE Version als die gemerkte gilt erst nach Bestätigung der Warnung;
  /// ältere Versionen gelten nur, wenn dieses Gerät sie selbst früher bestätigt hat (nach einem akzeptierten Wechsel); die Historie des Servers zählt NIE (kein
  /// ungeprüftes Nachladen: sonst könnte ein Server einen Schlüssel erfinden). Sonst "Absender nicht bestätigt".
  Future<OeffentlicheSchluessel> absenderSchluessel(String userId, int version) async {
    final pruefer = VertrauensPruefer(_speicher, eigeneUserId: _userId);
    final gemerkt = await pruefer.gemerkterSchluessel(userId);
    if (gemerkt != null && gemerkt.version == version) return gemerkt;
    // ein früher bestätigter Schlüssel dieser Person (vor einem bestätigten Wechsel) ist auch vom Gerät selbst gemerkt, nicht vom Server
    final frueher = await pruefer.gemerkterSchluessel(userId, version: version);
    if (frueher != null) return frueher;
    if (gemerkt != null && version > gemerkt.version) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Absender hat einen neuen Schlüssel, den du noch nicht akzeptiert hast.');
    }
    throw const CryptoFehler(CryptoFehlerArt.signatur, 'Der Schlüssel des Absenders in dieser Version ist auf diesem Gerät nie bestätigt worden.');
  }
}

final e2eeProvider = NotifierProvider<E2eeController, E2eeState>(E2eeController.new);
