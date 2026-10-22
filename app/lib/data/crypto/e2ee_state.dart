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
import '../auth/eigener_abruf.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'eltern_state.dart';
import 'pw_ablauf.dart';
import 'schluessel.dart';
import 'schluessel_speicher.dart';
import 'sicherheitscode.dart';
import 'sodium_crypto_provider.dart';
import 'uebertragung.dart';
import 'vertrauen.dart';
import 'wiederherstellung.dart';
import 'wiederherstellungstest.dart';

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

/// Ausgang der automatischen neuen Passwort-Sicherung nach einem Passwort-Reset.
enum PwNachReset {
  /// Es gab keine Sicherung, die der Reset veraltet hätte (oder der Server bietet sie nicht an): nichts zu tun.
  nichtNoetig,

  /// Die Sicherung wurde mit dem neuen Passwort neu angelegt, geprüft und bestätigt.
  erneuert,

  /// Auf diesem Gerät liegt der Personenschlüssel nicht: der Verlauf bleibt zunächst unlesbar, es wird NIE von selbst ein neuer Schlüssel angelegt.
  keinSchluesselAufGeraet,

  /// Das Anlegen ist gescheitert (Netz, Bestätigung abgelaufen o. Ä.): die Sicherung lässt sich unter Profil > Verschlüsselung neu anlegen.
  fehlgeschlagen,
}

/// Ausgang des automatischen Verbindens nach der Anmeldung mit Passwort ([E2eeController.automatischVerbinden]).
enum AutoVerbinden {
  /// Es gab nichts zu tun (Gerät hat schon einen Schlüssel, Person hat noch keinen, Passwort-Sicherung nicht angeboten).
  nichtNoetig,

  /// Das Gerät ist jetzt mit dem Personenschlüssel verbunden.
  verbunden,

  /// Es gibt keine bestätigte Passwort-Sicherung: Verbinden geht nur mit Wiederherstellungsschlüssel oder einem anderen Gerät.
  keineSicherung,

  /// Die Passwort-Sicherung ist veraltet (nach einem Passwort-Reset): sie gehört zum alten Passwort.
  veraltet,

  /// Das Anmelde-Passwort öffnet die Sicherung nicht (sie wurde mit einem anderen Passwort angelegt).
  passwortPasstNicht,

  /// Der Passkey öffnet die Passkey-Sicherung nicht (er wurde zum Beispiel neu angelegt).
  passkeyPasstNicht,

  /// Technischer Fehler (Netz, Speicher, Step-up): es wurde nichts verändert; manuell unter Profil > Verschlüsselung.
  fehlgeschlagen,
}

/// Lädt libsodium einmal (Tests ersetzen den Provider durch einen Fake).
/// Ohne automatische Wiederholung (Riverpod 3 würde Fehler sonst mit Wartezeiten wiederholen): Scheitert das Laden, zeigt die Seite sofort "nicht verfügbar".
final cryptoProviderProvider = FutureProvider<CryptoProvider>((ref) => SodiumCryptoProvider.laden(), retry: (_, _) => null);

final schluesselSpeicherProvider = Provider<SchluesselSpeicher>((ref) => schluesselSpeicherErzeugen());

/// Name des Personenschlüssels im Schlüsselspeicher; gehört zu einer Person, damit ein Gerät mit zwei Konten nichts vermischt.
String personenschluesselName(String userId) => 'e2ee.pk.$userId';

/// Für localDataWiperProvider (main.dart): Beim Abmelden bzw. Personenwechsel wird nur der Zustand im Arbeitsspeicher verworfen. **Der Personenschlüssel
/// im Schlüsselspeicher bleibt liegen** (je Person getrennt, `e2ee.pk.<uid>`): Abmelden beendet die Sitzung, es löscht keinen Schlüssel. Er wird bei der
/// nächsten Anmeldung derselben Person wiederverwendet; bei einer anderen Person am selben Gerät bleibt er unberührt (verschlüsselt) liegen und wird nie
/// für sie benutzt. Gelöscht wird er nur über [schluesselVomGeraetLoeschen] ("Gerät abgeben") oder beim ausdrücklichen Verwerfen eines Quarantäne-Eintrags.
Future<void> Function() e2eeSitzungWiper(Ref ref) => () async {
  // Zustand und der Schlüssel im Arbeitsspeicher gehören der bisherigen Person: verwerfen (der Neuaufbau überschreibt die Bytes)
  ref.invalidate(e2eeProvider);
};

/// Entfernt ALLE Schlüssel dieser Person von diesem Gerät: Personenschlüssel, Zwischenstand, Vermerke und Quarantäne-Einträge. Nur für "Gerät abgeben"
/// (nach der Prüfung einer bestätigten Sicherung und der ausdrücklichen Bestätigung). Die gemerkten öffentlichen Schlüssel der Familie (TOFU) bleiben, damit
/// kein Weg entsteht, einen Schlüsselwechsel unbemerkt zu lassen; Schlüssel anderer Personen auf diesem Gerät bleiben unberührt. Alle Schritte laufen
/// unabhängig voneinander; der erste Fehler wird danach geworfen.
Future<void> schluesselVomGeraetLoeschen(SchluesselSpeicher speicher, String userId) async {
  Object? erster;
  StackTrace? stapel;
  Future<void> schritt(Future<void> Function() f) async {
    try {
      await f();
    } on Object catch (e, st) {
      erster ??= e;
      stapel ??= st;
    }
  }

  await schritt(() => speicher.loeschen(personenschluesselName(userId)));
  await schritt(() => speicher.loeschen(personenschluesselAltName(userId)));
  await schritt(() => speicher.loeschen('e2ee.kv.$userId'));
  await schritt(() => speicher.loeschen('e2ee.kv.pw.$userId'));
  // Vermerke der Wiederherstellungstests und der Eltern-Wiederherstellung (flüchtiges Paar des Kindes, festgehaltene Werte des Elternteils je Anfrage)
  await schritt(() => speicher.loeschen(testVermerkName(userId)));
  await schritt(() => speicher.loeschen(testAusName(userId)));
  await schritt(() => speicher.loeschen(elternAnfrageName(userId)));
  await schritt(() async {
    for (final n in await speicher.namenMitPraefix('e2ee.elternuebernahme.$userId.')) {
      await schritt(() => speicher.loeschen(n));
    }
  });
  await schritt(() async {
    for (final n in await speicher.namenMitPraefix(quarantaenePraefix(userId))) {
      await schritt(() => speicher.loeschen(n));
    }
  });
  final fehler = erster;
  if (fehler != null) Error.throwWithStackTrace(fehler, stapel!);
}

/// Löschauftrag: Vor "Gerät abgeben" wird dieser Marker abgelegt (Inhalt nur der Zeitpunkt in Millisekunden, nie ein Geheimnis). Scheitert das Löschen, bleibt er
/// liegen und wird beim nächsten Start der App abgearbeitet ([loeschauftraegeAbarbeiten]); nach erfolgreichem Löschen oder wenn das Abmelden scheitert (dann ist
/// nichts gelöscht), wird er entfernt. Er löscht NIE still: Meldet sich dieselbe Person wieder an, wird er verworfen ([loeschauftragVerwerfen]); er löscht nur,
/// wenn keine Sitzung dieser Person aktiv ist, und verfällt nach [kLoeschauftragFrist].
String loeschauftragName(String userId) => 'e2ee.loeschauftrag.$userId';

const String _loeschauftragPraefix = 'e2ee.loeschauftrag.';

/// Wie lange ein Löschauftrag gilt; danach wird er verworfen statt ausgeführt.
const Duration kLoeschauftragFrist = Duration(hours: 24);

Uint8List _loeschauftragInhalt(DateTime jetzt) => utf8Bytes('${jetzt.millisecondsSinceEpoch}');

/// Verwirft den Löschauftrag dieser Person (z. B. nach einer erneuten Anmeldung). Fehler werden verschluckt.
Future<void> loeschauftragVerwerfen(SchluesselSpeicher speicher, String userId) async {
  try {
    await speicher.loeschen(loeschauftragName(userId));
  } on Object {
    // bleibt; läuft spätestens nach der Frist ab
  }
}

/// Arbeitet liegengebliebene Löschaufträge ab (beim Start der App, vor der Anmeldung): löscht die Schlüssel der genannten Person und entfernt dann den Marker.
/// Verworfen statt ausgeführt wird er, wenn er abgelaufen oder unlesbar ist oder wenn [aktiveUserId] (die Person mit gespeicherter Sitzung auf diesem Gerät)
/// dieselbe Person nennt. Fehler beim Löschen werden verschluckt (der Marker bleibt, der nächste Start versucht es erneut, bis die Frist abläuft).
Future<void> loeschauftraegeAbarbeiten(
  SchluesselSpeicher speicher, {
  Future<String?> Function()? aktiveUserId,
  DateTime Function()? jetzt,
}) async {
  try {
    final namen = await speicher.namenMitPraefix(_loeschauftragPraefix);
    if (namen.isEmpty) return;
    String? aktiv;
    try {
      aktiv = await aktiveUserId?.call();
    } on Object {
      aktiv = null;
    }
    final heute = (jetzt ?? DateTime.now)();
    for (final name in namen) {
      final uid = name.substring(_loeschauftragPraefix.length);
      if (uid.isEmpty) continue;
      try {
        final roh = await speicher.lesen(name);
        final ms = roh == null ? null : int.tryParse(String.fromCharCodes(roh));
        final abgelaufen = ms == null || heute.difference(DateTime.fromMillisecondsSinceEpoch(ms)) > kLoeschauftragFrist || ms > heute.millisecondsSinceEpoch + 60000;
        if (abgelaufen || aktiv == uid) {
          await speicher.loeschen(name); // verwerfen, nicht ausführen
          continue;
        }
        await schluesselVomGeraetLoeschen(speicher, uid);
        await speicher.loeschen(name);
      } on Object {
        // bleibt für den nächsten Start
      }
    }
  } on Object {
    // Speicher nicht lesbar: nichts zu tun
  }
}

/// Ausgang von "Gerät abgeben": Was ist geschehen? Die Oberfläche sagt es ehrlich.
class GeraetAbgabeErgebnis {
  /// Der Server hat die Sitzung beendet (oder sie war dort schon beendet).
  final bool serverAbgemeldet;

  /// Alle Schlüssel dieser Person sind vom Gerät gelöscht. false: Das Löschen ist gescheitert; ein Löschauftrag bleibt und wird beim nächsten Start abgearbeitet.
  final bool schluesselGeloescht;

  /// Token und lokale Daten (Datenbank) wurden vollständig entfernt (Web: nur die Zeilen, nicht die Datei der Browser-Datenbank).
  final bool datenSauber;
  const GeraetAbgabeErgebnis({required this.serverAbgemeldet, required this.schluesselGeloescht, required this.datenSauber});
}

/// Quarantäne: Ein lokaler Schlüssel, der nicht (mehr) gelten soll (weicht vom Server ab, Speicher defekt, alter Schlüssel nach einem Wechsel), wird
/// nie gelöscht, sondern unter diesem Namen aufbewahrt: `e2ee.quarantaene.<uid>.<Millisekunden>`.
String quarantaenePraefix(String userId) => 'e2ee.quarantaene.$userId.';

/// Ein aufbewahrter alter Schlüssel dieses Geräts (nur zur Anzeige; er wird nie automatisch benutzt oder gelöscht).
class QuarantaeneEintrag {
  final String name;

  /// Wann er in die Quarantäne kam (aus dem Namen; null, wenn nicht lesbar).
  final DateTime? seit;
  const QuarantaeneEintrag(this.name, this.seit);
}

/// Wie sicher "Gerät abgeben" gerade ist.
enum GeraetAbgabeLage {
  /// Eine bestätigte Sicherung liegt beim Server: Schlüssel und lokale Daten dürfen nach ausdrücklicher Bestätigung gelöscht werden.
  moeglich,

  /// Der Stand beim Server ließ sich nicht klären (offline, Fehler, noch nicht geladen): gesperrt, nie "gesichert".
  standUnbekannt,

  /// Der Server kennt keine bestätigte Sicherung (oder meldet es nicht): gesperrt.
  keineBestaetigteSicherung,

  /// Auf diesem Gerät liegt kein Schlüssel und nichts in Quarantäne: es gibt nichts zu löschen.
  nichtsZuLoeschen,
}

/// Die Regel für "Gerät abgeben": nur mit bestätigter Sicherung beim Server (Passwort-Sicherung bestätigt und gültig ODER Sicherung mit dem
/// Wiederherstellungsschlüssel zur aktuellen Version). Unbekannt zählt nie als gesichert.
GeraetAbgabeLage geraetAbgabeLage(E2eeState s) {
  switch (s.status) {
    case E2eeStatus.laedt:
    case E2eeStatus.nichtVerfuegbar:
      return GeraetAbgabeLage.standUnbekannt;
    case E2eeStatus.keinSchluessel:
    case E2eeStatus.geraetNichtVerbunden:
      // auch ein lokaler Schlüssel, den der Server nicht kennt (z. B. nach einem Zurücksetzen durch einen Admin), ist etwas zu Löschendes
      if (s.quarantaene.isEmpty && !s.lokalVorhanden) return GeraetAbgabeLage.nichtsZuLoeschen;
    case E2eeStatus.bereit:
    case E2eeStatus.abweichend:
  }
  return s.sicherungBestaetigt ? GeraetAbgabeLage.moeglich : GeraetAbgabeLage.keineBestaetigteSicherung;
}

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

  /// Der Server meldet die aktuelle Passwort-Sicherung als veraltet (nach einem Passwort-Reset): auf einem Gerät mit Schlüssel "Sicherung erneuern".
  final bool pwSicherungVeraltet;

  /// Passkey-Sicherung (Schalter E2EE_PRF_BACKUP des Servers): angeboten, seit wann bestätigt (null: nicht bestätigt oder nicht gemeldet), welche Passkeys (öffentliche
  /// Kennungen) bestätigt gesichert sind und ob eine veraltet ist (nach einem Schlüsselwechsel).
  final bool prfSicherungVerfuegbar;
  final DateTime? prfBestaetigtAm;
  final List<String> prfCredentialIds;
  final bool prfSicherungVeraltet;

  /// Ein Passkey mit bestätigter Sicherung ist synchronisiert (auf anderen Geräten verfügbar). Nur dann zählt die Passkey-Sicherung als Weg und nie als "bestätigte Sicherung"
  /// für "Gerät abgeben" (ein gerätegebundener Passkey wäre mit dem Gerät unlesbar).
  final bool prfSynchronisiert;

  /// Der Server bietet die Eltern-Wiederherstellung für Kinder an (Schalter E2EE_PARENT_RECOVERY; sonst bleibt die Funktion unsichtbar).
  final bool elternWiederherstellungVerfuegbar;

  /// Familien-Sicherheitscode (leer, solange niemand Schlüssel hat).
  final String sicherheitscode;

  /// Seit wann die aktuelle Passwort-Sicherung beim Server bestätigt ist (null: nicht bestätigt oder vom Server nicht gemeldet).
  final DateTime? pwBestaetigtAm;

  /// Seit wann die Sicherung mit dem Wiederherstellungsschlüssel zur aktuellen Schlüsselversion beim Server liegt (null: keine oder nicht gemeldet).
  final DateTime? wiederherstellungAm;

  /// Anzahl der beim Server archivierten früheren Sicherungen (null: nicht gemeldet).
  final int? archivAnzahl;

  /// Aufbewahrte alte Schlüssel dieser Person auf diesem Gerät.
  final List<QuarantaeneEintrag> quarantaene;

  /// Darf der Browser die Schlüssel-Daten löschen (nur Web; sonst [SpeicherDauer.nichtZutreffend])?
  final SpeicherDauer speicherDauer;

  /// Liegt auf diesem Gerät ein (lesbarer) Personenschlüssel, unabhängig davon, was der Server kennt?
  final bool lokalVorhanden;

  /// Wie viele frühere Schlüssel nur auf diesem Gerät liegen und beim "Gerät abgeben" mitgelöscht würden: die Quarantäne und, bei abweichendem Zustand, der
  /// lokale Schlüssel selbst (er passt nicht mehr zum Konto, wäre aber vielleicht noch für älteren Verlauf nötig).
  int get fruehereSchluessel => quarantaene.length + (status == E2eeStatus.abweichend ? 1 : 0);

  /// Liegt beim Server eine BESTÄTIGTE Sicherung (Passwort-Sicherung bestätigt und nicht veraltet, oder Wiederherstellungsschlüssel-Sicherung zur
  /// aktuellen Version)? Fehlt die Angabe des Servers, gilt sie als nicht bestätigt: "unbekannt" ist nie "gesichert".
  /// Die Passkey-Sicherung zählt hier bewusst NICHT: sie ist nur so verfügbar wie der Passkey (ein gerätegebundener ginge mit dem Gerät verloren); "Gerät abgeben" bleibt ohne
  /// Passwort-Sicherung oder Wiederherstellungsschlüssel gesperrt.
  bool get sicherungBestaetigt => (pwBestaetigtAm != null && !pwSicherungVeraltet) || (hatSicherung && wiederherstellungAm != null);

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
    this.pwSicherungVeraltet = false,
    this.prfSicherungVerfuegbar = false,
    this.prfBestaetigtAm,
    this.prfCredentialIds = const [],
    this.prfSicherungVeraltet = false,
    this.prfSynchronisiert = false,
    this.elternWiederherstellungVerfuegbar = false,
    this.sicherheitscode = '',
    this.pwBestaetigtAm,
    this.wiederherstellungAm,
    this.archivAnzahl,
    this.quarantaene = const [],
    this.speicherDauer = SpeicherDauer.nichtZutreffend,
    this.lokalVorhanden = false,
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

  /// Zähler der Ladeläufe ([laden]): nur der jüngste Lauf darf Zustand und lokalen Schlüssel setzen.
  int _ladeLauf = 0;

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

  /// Liest den lokalen Schlüssel. Fehlt er, null. Ein eindeutig dauerhaft unbrauchbarer Eintrag wird NIE gelöscht, sondern unverändert in die
  /// Quarantäne verschoben (null; lässt er sich nicht verschieben, bleibt er unter seinem Namen liegen); ein vorübergehender Fehler des Speichers geht
  /// weiter, der Eintrag bleibt (ein späterer Versuch kann klappen).
  Future<Personenschluessel?> _lokalLaden(CryptoProvider crypto) async {
    final name = personenschluesselName(_userId);
    final Uint8List? bytes;
    try {
      bytes = await _speicher.lesen(name);
    } on SchluesselSpeicherFehler catch (e) {
      if (!e.dauerhaft) rethrow;
      await _inQuarantaene(name);
      return null;
    }
    if (bytes == null) return null;
    try {
      return Personenschluessel.ausBytes(crypto, bytes);
    } on CryptoFehler catch (e) {
      // ein interner Fehler der Bibliothek sagt nichts über den Eintrag: er bleibt liegen (nur Länge/Format eines Schlüssels sind ein echter Defekt)
      if (e.art == CryptoFehlerArt.bibliothek) rethrow;
      await _inQuarantaene(name);
      return null;
    } finally {
      loescheBytes(bytes);
    }
  }

  static int _letzterQuarantaeneStempel = 0;

  /// Verschiebt den Eintrag [name] unverändert in die Quarantäne (nie löschen). true, wenn er danach dort liegt; false, wenn es ihn nicht gibt oder er
  /// sich nicht verschieben ließ (er bleibt dann, wo er war).
  Future<bool> _inQuarantaene(String name) async {
    final uid = _userId;
    var stempel = DateTime.now().millisecondsSinceEpoch;
    if (stempel <= _letzterQuarantaeneStempel) stempel = _letzterQuarantaeneStempel + 1;
    _letzterQuarantaeneStempel = stempel;
    try {
      return await _speicher.verschiebe(name, '${quarantaenePraefix(uid)}$stempel');
    } on Object {
      return false;
    }
  }

  Future<List<QuarantaeneEintrag>> _quarantaeneLesen(String uid) async {
    try {
      final praefix = quarantaenePraefix(uid);
      final namen = await _speicher.namenMitPraefix(praefix);
      DateTime? seit(String n) {
        final ms = int.tryParse(n.substring(praefix.length));
        return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      }

      return [for (final n in namen) QuarantaeneEintrag(n, seit(n))]
        ..sort((a, b) => (b.seit?.millisecondsSinceEpoch ?? 0).compareTo(a.seit?.millisecondsSinceEpoch ?? 0));
    } on Object {
      return const [];
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
  Future<void> laden() {
    final uid = ref.read(authProvider).user?.id;
    if (uid == null) return Future<void>.value();
    // Generationszähler: überlappende Läufe (Seite, Chat-Schlüsselbund, automatisches Verbinden) dürfen sich nicht überschreiben. Ein älterer Lauf, der nach einem
    // neueren (oder nach dem Übernehmen eines Schlüssels) fertig wird, verwirft sein Ergebnis und fasst weder den Zustand noch den lokalen Schlüssel an.
    final lauf = ++_ladeLauf;
    final f = _ladenLauf(uid, lauf);
    _juengsterLauf = f;
    return f;
  }

  Future<void>? _juengsterLauf;

  /// Ein abgelöster Lauf wartet auf den jüngsten: Wer `await laden()` aufruft, sieht danach den neuesten Stand (nicht den vor dem Lauf).
  Future<void> _abwarten(int lauf) async {
    final j = _juengsterLauf;
    if (ref.mounted && lauf != _ladeLauf && j != null) await j;
  }

  Future<void> _ladenLauf(String uid, int lauf) async {
    bool veraltet() => lauf != _ladeLauf || !ref.mounted;
    try {
      final crypto = await _krypto();
      // der lokale Schlüssel gehört zum Gerät: er steht auch ohne Verbindung zum Server zur Verfügung (Chat lesen und schreiben offline)
      try {
        if (_lokal == null) {
          final gelesen = await _lokalLaden(crypto);
          if (veraltet()) return await _abwarten(lauf);
          _lokal ??= gelesen; // erst nach dem Lesen prüfen: ein inzwischen übernommener Schlüssel wird nie überschrieben
        }
      } on SchluesselSpeicherFehler {
        // der Schlüsselspeicher ist gerade nicht lesbar: unten wird es erneut versucht und gemeldet
      }
      final eigene = await _api.eigeneSchluessel();
      final mitglieder = await _api.mitglieder();
      if (veraltet()) return await _abwarten(lauf);
      final gelesen = await _lokalLaden(crypto);
      if (veraltet()) return await _abwarten(lauf);
      _lokal = gelesen;
      await _zwischenstandAufloesen(crypto, eigene.schluessel);
      final server = eigene.schluessel;
      if (server != null) await _versionMerken(uid, server.version);
      final pruefer = VertrauensPruefer(_speicher, eigeneUserId: uid);
      var warnungen = <SchluesselWarnung>[];
      var ablageDefekt = false;
      try {
        warnungen = await pruefer.pruefen({for (final m in mitglieder) m.id: m.schluessel});
        await pruefer.standPruefen(); // ein beschädigter Stand der Chat-Mitglieder wird wie eine beschädigte Merkliste gemeldet
      } on VertrauensAblageDefekt {
        // Ohne eigenen Schlüssel auf dem Gerät (Schlüsselspeicher dauerhaft unlesbar, der Schlüssel liegt in der Quarantäne) darf das nicht in eine Sackgasse führen:
        // "Gerät nicht verbunden" bleibt, mit dem Weg zum Verbinden und dem bewussten Zurücksetzen des Vertrauens. Mit Schlüssel (oder ohne Server-Schlüssel) bleibt es beim Fehlerbild unten.
        if (_lokal != null || server == null) rethrow;
        ablageDefekt = true;
      }
      final status = switch ((server, _lokal)) {
        (null, _) => E2eeStatus.keinSchluessel,
        (_, null) => E2eeStatus.geraetNichtVerbunden,
        (final s?, final l?) => _passt(l, s) ? E2eeStatus.bereit : E2eeStatus.abweichend,
      };
      // Passwort-Sicherung: nur sichtbar, wenn der Server sie anbietet (Fehler = aus); der Vermerk "verifiziert" liegt auf diesem Gerät
      final faehig = server == null ? ServerFaehigkeiten.keine : await _api.faehigkeitenOderKeine();
      final pwVerfuegbar = faehig.pwBackup;
      final prfVerfuegbar = faehig.prfBackup;
      final elternVerfuegbar = faehig.elternWiederherstellung;
      final pwVersion = pwVerfuegbar ? await _pwVermerkLesen(uid) : null;
      final quarantaene = await _quarantaeneLesen(uid);
      // der Browser darf die Daten löschen, wenn er die dauerhafte Ablage verweigert: die Anfrage kann beim Nutzer nachfragen, darum mit Zeitlimit
      final dauer = await _speicher.dauerhaftigkeit().timeout(const Duration(seconds: 2), onTimeout: () => SpeicherDauer.unbekannt).catchError((Object _) => SpeicherDauer.unbekannt);
      if (veraltet()) return await _abwarten(lauf);
      state = E2eeState(
        status: status,
        vertrauenDefekt: ablageDefekt,
        meldung: ablageDefekt
            ? 'Der Schlüsselspeicher dieses Geräts ist nicht mehr lesbar (Daten gelöscht oder Schlüssel verloren). '
                  '${quarantaene.isNotEmpty ? 'Ein alter Schlüssel hier wurde aufbewahrt, nicht gelöscht. ' : 'Der Schlüssel auf diesem Gerät ist nicht mehr lesbar. '}'
                  'Verbinde dieses Gerät neu. Die gemerkten Schlüssel der Familie sind verloren; mit „Vertrauen zurücksetzen“ werden sie beim ersten Sehen neu gemerkt: '
                  'Vergleiche danach die Sicherheitscodes mit den Personen.'
            : null,
        serverSchluessel: server,
        hatSicherung: eigene.hatSicherung,
        pwSicherungVerfuegbar: pwVerfuegbar,
        pwSicherungVersion: pwVersion,
        pwSicherungVeraltet: pwVerfuegbar && eigene.pwSicherungVeraltet,
        prfSicherungVerfuegbar: prfVerfuegbar,
        prfBestaetigtAm: prfVerfuegbar ? eigene.prfSicherungBestaetigtAm : null,
        prfCredentialIds: prfVerfuegbar ? eigene.prfCredentialIds : const [],
        prfSicherungVeraltet: prfVerfuegbar && eigene.prfSicherungVeraltet,
        prfSynchronisiert: prfVerfuegbar && eigene.prfSynchronisiert,
        elternWiederherstellungVerfuegbar: elternVerfuegbar,
        pwBestaetigtAm: eigene.pwSicherungBestaetigtAm,
        wiederherstellungAm: eigene.wiederherstellungsSicherungAm,
        archivAnzahl: eigene.archivAnzahl,
        quarantaene: quarantaene,
        speicherDauer: dauer,
        lokalVorhanden: _lokal != null,
        mitglieder: mitglieder,
        warnungen: warnungen,
        // nur aktive Mitglieder: wartende gehören noch nicht zur Familie
        sicherheitscode: familienSicherheitscode([
          for (final m in mitglieder)
            if (m.schluessel != null && m.status == MemberStatus.active) MitgliedSchluessel(m.id, m.schluessel!),
        ]),
      );
    } on VertrauensAblageDefekt {
      if (!veraltet()) {
        state = const E2eeState(
          status: E2eeStatus.nichtVerfuegbar,
          vertrauenDefekt: true,
          meldung: 'Die gemerkten Schlüssel der Familie sind auf diesem Gerät beschädigt. Aus Sicherheitsgründen werden sie nicht stillschweigend ersetzt. Du kannst das Vertrauen zurücksetzen und die Schlüssel danach neu prüfen.',
        );
      }
    } on CryptoFehler catch (e) {
      if (!veraltet()) state = E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: e.meldung);
    } on SchluesselSpeicherFehler {
      if (!veraltet()) state = const E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: 'Der Schlüsselspeicher dieses Geräts ist gerade nicht lesbar. Bitte versuche es gleich noch einmal.');
    } on ApiException catch (e) {
      if (!veraltet()) state = E2eeState(status: E2eeStatus.nichtVerfuegbar, meldung: e.message);
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
    } on CryptoFehler catch (e) {
      if (e.art == CryptoFehlerArt.bibliothek) return; // interner Fehler der Bibliothek: der Zwischenstand bleibt liegen, das nächste Laden versucht es noch einmal
      await _inQuarantaene(altName); // unbrauchbarer Zwischenstand: aufbewahren, nicht löschen
      return;
    } finally {
      loescheBytes(roh);
    }
    final neuPasst = server != null && _lokal != null && _passt(_lokal!, server);
    final altPasst = server != null && _passt(alt, server);
    if (neuPasst) {
      // der Wechsel ist angekommen: der bisherige Schlüssel wird aufbewahrt (Quarantäne), nicht gelöscht
      alt.loeschen();
      await _inQuarantaene(altName);
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
    unawaited(_speicher.dauerhaftAnfordern()); // Aktion der Person: der Browser darf hier nach dauerhaftem Speicher fragen (nur Web)
    await laden();
    return Einrichtung(Wiederherstellung.neuerSchluessel(crypto), ver.version);
  }

  /// Eigener Knopf in Profil > Verschlüsselung (nur Web, wenn der Browser die dauerhafte Ablage nicht zugesagt hat): fragt einmal je Sitzung nach.
  Future<void> dauerhaftenSpeicherAnfordern() async {
    await _speicher.dauerhaftAnfordern().timeout(const Duration(seconds: 30), onTimeout: () => SpeicherDauer.unbekannt);
    await laden();
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
      await _inQuarantaene(altName); // der bisherige Schlüssel wird aufbewahrt, nicht gelöscht
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
    // ein anderer, schon vorhandener Schlüssel dieses Geräts wird nicht überschrieben, sondern aufbewahrt (Quarantäne)
    final vorhanden = _lokal;
    if (vorhanden != null && !vorhanden.oeffentlich(1).gleichWie(schluessel.oeffentlich(1))) {
      if (!await _inQuarantaene(personenschluesselName(_userId))) {
        schluessel.loeschen();
        throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der bisherige Schlüssel dieses Geräts ließ sich nicht sicher beiseitelegen. Es wurde nichts verändert.');
      }
    }
    await _speicher.schreiben(personenschluesselName(_userId), schluessel.exportieren());
    _lokal?.loeschen();
    _lokal = schluessel;
    unawaited(_speicher.dauerhaftAnfordern()); // Aktion der Person (Verbinden): der Browser darf nach dauerhaftem Speicher fragen (nur Web)
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

  /// Für die Abläufe der Passkey-Sicherung und der Eltern-Wiederherstellung (prf_state.dart, eltern_state.dart): lokaler Schlüssel und Provider, ohne etwas zu verändern.
  Future<CryptoProvider> kryptoFuerAblauf() => _krypto();
  Future<Personenschluessel?> lokalenSchluesselFuerAblauf() async => _lokal ?? await _lokalLaden(await _krypto());

  /// Übernimmt einen aus einer Sicherung (Passkey, Eltern) geöffneten Schlüssel wie beim Verbinden mit Passwort: Vergleich mit dem frisch geholten öffentlichen Schlüssel des
  /// Servers, erst dann schreiben ([_lokalUebernehmen]).
  Future<void> schluesselUebernehmen(Personenschluessel schluessel, int keyVersion) => _lokalUebernehmen(schluessel, keyVersion);

  /// Marke "eigener Abruf der Passwort-Sicherung" (siehe eigener_abruf.dart), VOR dem Abruf setzen. Wirft nie.
  Future<void> _eigenerAbruf() => ref.read(eigenerPwAbrufMarkeProvider)();

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
    await _eigenerAbruf();
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

  /// Nach einem Passwort-Reset (neues Passwort = neuer authKey UND neuer kek): Der Server hat die bisherige Passwort-Sicherung als veraltet (`stale`) markiert,
  /// nichts gelöscht; der Wiederherstellungsschlüssel und die QR-Übertragung gelten unverändert. Hat DIESES Gerät den Personenschlüssel, legt die App mit dem
  /// neuen Passwort selbst eine neue Sicherung an (derselbe Ablauf wie sonst: lokale Probe, Ablegen, Round-Trip, Bestätigen). Ohne Schlüssel auf dem Gerät
  /// passiert nichts am Schlüssel (kein neuer Personenschlüssel von selbst; der Verlauf wird später über Chat-Partner freigegeben). Wirft nie.
  Future<PwNachReset> sicherungNachResetErneuern(String passwort) async {
    try {
      final uid = _userId;
      if (!await _api.pwSicherungVerfuegbar()) return PwNachReset.nichtNoetig;
      PwSicherungDto? aktuell;
      await _eigenerAbruf();
      try {
        aktuell = await _api.pwSicherungAbrufen();
      } on ApiException catch (e) {
        if (e.code != 'not_found') rethrow;
      }
      if (aktuell == null || !aktuell.stale) return PwNachReset.nichtNoetig;
      // Der Vermerk "auf diesem Gerät verifiziert" gilt für die veraltete Sicherung nicht mehr
      try {
        await _speicher.loeschen(_pwVermerkName(uid));
      } on Object {
        // nur eine Anzeige
      }
      final crypto = await _krypto();
      final lokal = _lokal ?? await _lokalLaden(crypto);
      if (lokal == null) {
        try {
          await laden();
        } on Object {
          // nur die Anzeige
        }
        return PwNachReset.keinSchluesselAufGeraet;
      }
      final entwurf = await pwSicherungVorbereiten(passwort);
      await pwSicherungAblegen(entwurf, passwort);
      return PwNachReset.erneuert;
    } on Object {
      try {
        await laden();
      } on Object {
        // nur die Anzeige
      }
      return PwNachReset.fehlgeschlagen;
    }
  }

  /// Gerät ohne Schlüssel mit der Passwort-Sicherung verbinden (Step-up für den Abruf; UI). Der Schlüssel wird erst übernommen, wenn er zum
  /// frisch vom Server geholten öffentlichen Schlüssel passt ('_lokalUebernehmen').
  /// Gibt `true` zurück, wenn die Sicherung veraltet war (Passwort-Reset): Das Gerät ist verbunden, die Sicherung sollte jetzt erneuert werden.
  Future<bool> mitPasswortVerbinden(String passwort) async {
    final crypto = await _krypto();
    await _eigenerAbruf();
    final r = await _pwAblauf(crypto).abrufenUndOeffnen(passwort);
    await _lokalUebernehmen(r.schluessel, r.keyVersion);
    return r.veraltet;
  }

  /// Nach der Anmeldung mit Passwort (ein Passwort für Anmeldung und Sicherung): Hat dieses Gerät noch keinen Schlüssel, der Server aber eine bestätigte, nicht
  /// veraltete Passwort-Sicherung, öffnet die App sie mit dem Passwort, das die Person gerade eingegeben hat, und verbindet das Gerät (kein zweites Passwort).
  /// Nie ein neuer Personenschlüssel, nie ein vorhandener lokaler Schlüssel wird angefasst oder ersetzt (liegt einer da, passiert nichts, auch bei "abweichend": das
  /// entscheidet die Person unter Profil > Verschlüsselung). Übernommen wird der Schlüssel erst nach dem Vergleich mit dem frisch geholten öffentlichen Schlüssel
  /// des Servers ([_lokalUebernehmen]). Wirft nie; der Ausgang sagt, was geschehen ist.
  Future<AutoVerbinden> automatischVerbinden(String passwort) async {
    try {
      if (!await _api.pwSicherungVerfuegbar()) return AutoVerbinden.nichtNoetig;
      final crypto = await _krypto();
      final Personenschluessel? lokal;
      try {
        lokal = _lokal ?? await _lokalLaden(crypto);
      } on SchluesselSpeicherFehler {
        return AutoVerbinden.fehlgeschlagen; // Speicher gerade nicht lesbar: nichts anfassen
      }
      if (lokal != null) return AutoVerbinden.nichtNoetig;
      final eigene = await _api.eigeneSchluessel();
      if (eigene.schluessel == null) return AutoVerbinden.nichtNoetig; // noch kein Schlüssel eingerichtet: nie automatisch einen anlegen
      // Zustand des Servers zuerst (ohne die protokollierte Sicherung abzurufen): nur eine bestätigte, aktuelle Sicherung ist ein Ziel
      if (eigene.pwSicherungVeraltet) return AutoVerbinden.veraltet;
      if (eigene.pwSicherungBestaetigtAm == null) return AutoVerbinden.keineSicherung;
      final ({Personenschluessel schluessel, int keyVersion, bool veraltet}) r;
      await _eigenerAbruf();
      try {
        r = await _pwAblauf(crypto).abrufenUndOeffnen(passwort);
      } on CryptoFehler catch (e) {
        return e.art == CryptoFehlerArt.entschluesselung ? AutoVerbinden.passwortPasstNicht : AutoVerbinden.fehlgeschlagen;
      } on ApiException catch (e) {
        return e.code == 'not_found' ? AutoVerbinden.keineSicherung : AutoVerbinden.fehlgeschlagen;
      }
      // _lokalUebernehmen prüft gegen den frisch geholten Schlüssel des Servers und schreibt erst dann
      await _lokalUebernehmen(r.schluessel, r.keyVersion);
      return AutoVerbinden.verbunden;
    } on Object {
      try {
        if (ref.mounted) await laden();
      } on Object {
        // nur die Anzeige
      }
      return AutoVerbinden.fehlgeschlagen;
    }
  }

  /// Nimmt den Schlüssel aus dem Betrieb dieses Geräts (z. B. bei abweichendem Schlüssel), danach kann das Gerät neu verbunden werden. Der Schlüssel wird
  /// **nicht gelöscht**, sondern in die Quarantäne verschoben (Profil > Verschlüsselung: "Alter Schlüssel auf diesem Gerät"). Lässt er sich nicht
  /// verschieben, bleibt alles, wie es ist, und es gibt einen Fehler.
  Future<void> lokalenSchluesselVerwerfen() async {
    final namen = [personenschluesselName(_userId), personenschluesselAltName(_userId)];
    for (final n in namen) {
      if (await _inQuarantaene(n)) continue;
      // nicht verschoben: gibt es ihn nicht, ist alles gut; sonst (auch bei einem Lesefehler) bleibt er liegen und das Verbinden bricht ab
      var da = false;
      try {
        final bytes = await _speicher.lesen(n);
        da = bytes != null;
        if (bytes != null) loescheBytes(bytes);
      } on SchluesselSpeicherFehler {
        da = true;
      }
      if (da) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüssel dieses Geräts ließ sich nicht sicher beiseitelegen. Es wurde nichts gelöscht.');
    }
    _lokal?.loeschen();
    _lokal = null;
    await laden();
  }

  /// Verwirft einen aufbewahrten alten Schlüssel endgültig (die Oberfläche verlangt vorher eine ausdrückliche, getippte Bestätigung).
  Future<void> quarantaeneVerwerfen(String name) async {
    if (!name.startsWith(quarantaenePraefix(_userId))) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Dieser Eintrag gehört nicht zu deinem Konto.');
    await _speicher.loeschen(name);
    await laden();
  }

  /// "Gerät abgeben": meldet ab (Sitzung, lokale Daten) und löscht danach ALLE Schlüssel dieser Person von diesem Gerät. Nur mit bestätigter Sicherung beim
  /// Server ([geraetAbgabeLage]): der Stand wird dafür frisch geladen; ist er unbekannt oder unbestätigt, wirft das einen Fehler und nichts wird gelöscht.
  /// Scheitert das Abmelden (Web mit Serverfehler), wird ebenfalls nichts gelöscht (der Löschauftrag wird zurückgenommen). Scheitert das Löschen, bleibt ein
  /// Löschauftrag für den nächsten Start ([loeschauftraegeAbarbeiten]) und das Ergebnis sagt es. Die Oberfläche verlangt vorher Haken und getipptes Wort.
  Future<GeraetAbgabeErgebnis> geraetAbgeben() async {
    final uid = _userId;
    final speicher = _speicher;
    final auth = ref.read(authProvider.notifier);
    await laden();
    switch (geraetAbgabeLage(state)) {
      case GeraetAbgabeLage.moeglich:
        break;
      case GeraetAbgabeLage.standUnbekannt:
        throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Stand deiner Sicherung ließ sich gerade nicht prüfen. Es wurde nichts gelöscht.');
      case GeraetAbgabeLage.keineBestaetigteSicherung:
        throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Es gibt keine bestätigte Sicherung deines Schlüssels. Es wurde nichts gelöscht.');
      case GeraetAbgabeLage.nichtsZuLoeschen:
        throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät liegt kein Schlüssel.');
    }
    // Löschauftrag ablegen, bevor etwas passiert: gelingt das nicht, ist der Schlüsselspeicher nicht verlässlich, und es wird nichts begonnen
    final marker = loeschauftragName(uid);
    try {
      await speicher.schreiben(marker, _loeschauftragInhalt(DateTime.now()));
    } on Object {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüsselspeicher dieses Geräts ließ sich nicht beschreiben. Es wurde nichts gelöscht.');
    }
    // Danach ist dieser Controller verworfen (der Abmelde-Wiper leert den Zustand): nur noch lokale Werte benutzen, kein ref
    final AbmeldeErgebnis ergebnis;
    try {
      ergebnis = await auth.abmelden();
    } on Object {
      try {
        await speicher.loeschen(marker); // nichts wurde gelöscht: der Auftrag entfällt
      } on Object {
        // bleibt; würde beim nächsten Start nur die Schlüssel entfernen, die zu diesem Zeitpunkt noch gesichert waren
      }
      rethrow;
    }
    // Die Sitzung ist beendet: Der Auftrag wird mit frischem Zeitpunkt noch einmal abgelegt (eine während des Abmeldens eingetroffene Antwort könnte ihn als
    // "bestätigte Sitzung" verworfen haben). Gelingt das nicht, wird trotzdem sofort gelöscht.
    try {
      await speicher.schreiben(marker, _loeschauftragInhalt(DateTime.now()));
    } on Object {
      // nur der Wiederholungsweg fehlt
    }
    var geloescht = true;
    try {
      await schluesselVomGeraetLoeschen(speicher, uid);
    } on Object {
      geloescht = false;
    }
    if (geloescht) {
      try {
        await speicher.loeschen(marker);
      } on Object {
        // ein übrig gebliebener Marker löscht beim nächsten Start nichts mehr
      }
    }
    return GeraetAbgabeErgebnis(serverAbgemeldet: ergebnis.serverAbgemeldet, schluesselGeloescht: geloescht, datenSauber: ergebnis.lokalSauber);
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
