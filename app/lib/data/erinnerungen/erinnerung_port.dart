// Schnittstelle zum Betriebssystem für Terminerinnerungen. Die App spricht nur diese Schnittstelle an; das Plugin
// (flutter_local_notifications) steckt dahinter und wird nur auf Android eingebunden (erinnerung_port_android.dart, bedingter Import).
// Im Web und in Tests gibt es eine Variante ohne Wirkung bzw. einen Fake.
import 'erinnerung_planung.dart';

/// ID der Testbenachrichtigung ("in 10 Sekunden"); gehört nicht zum Planungsfenster und wird beim Angleichen nicht gelöscht.
const kTestBenachrichtigungId = 1;

/// ID der Hinweis-Benachrichtigung "Erinnerungen laufen aus" (gehört zur Planung, siehe erinnerung_planung.dart).
const kAuslaufHinweisId = 2;

/// Zustand der Benachrichtigungs-Erlaubnis: [erlaubt]; [fragbar] = nicht erlaubt, aber Android zeigt den Dialog noch (nie gefragt oder einmal
/// abgelehnt); [gesperrt] = nicht erlaubt und kein Dialog mehr möglich (dauerhaft verweigert, Systemschalter aus): nur die Einstellungen helfen.
/// [unbekannt] = der Systemaufruf selbst ist gescheitert (kein Ergebnis, nicht als "verweigert" werten).
enum BenachrichtigungsStatus { erlaubt, fragbar, gesperrt, unbekannt }

/// Nur Zustände für die Diagnose-Zeile (keine Inhalte): Plugin bereit, Erlaubnis, Wichtigkeit des Kanals (0 = aus, -1 = unbekannt/nicht angelegt),
/// genaue Alarme, Anzahl geplanter Erinnerungen (-1 = unbekannt).
class ErinnerungDiagnose {
  final bool bereit;
  final bool erlaubt;
  final int kanal;
  final bool exakt;
  final int geplant;

  /// Art des letzten gescheiterten Systemaufrufs (Typ/Fehlercode), sonst null.
  final String? fehler;
  const ErinnerungDiagnose({this.bereit = false, this.erlaubt = false, this.kanal = -1, this.exakt = false, this.geplant = -1, this.fehler});
}

abstract class ErinnerungPort {
  /// Gibt es auf diesem Gerät Erinnerungen? Nur Android (nicht Web).
  bool get verfuegbar;

  /// Bereitet das Plugin vor (Kanal "Terminerinnerungen" anlegen). [beiTipp] bekommt den Inhalt ([erinnerungPayload]), wenn die Person
  /// bei laufender App auf eine Benachrichtigung tippt.
  /// Liefert false, wenn das Plugin nicht bereit ist (der Dienst versucht es später erneut).
  Future<bool> initialisieren({required void Function(String payload) beiTipp});

  /// Inhalt der Benachrichtigung, mit deren Tippen die App gestartet wurde (einmalig); sonst null.
  Future<String?> startPayload();

  /// Darf die App Benachrichtigungen anzeigen? (Android 13+: Berechtigung POST_NOTIFICATIONS; sonst Systemschalter)
  Future<bool> benachrichtigungenErlaubt();

  /// Wie [benachrichtigungenErlaubt], zusätzlich ob der Systemdialog noch möglich ist.
  Future<BenachrichtigungsStatus> benachrichtigungsStatus();

  /// Fragt die Berechtigung ab (Android 13+: Systemdialog; bei dauerhafter Verweigerung erscheint keiner). Liefert, ob sie jetzt erteilt ist.
  Future<bool> benachrichtigungenAnfragen();

  /// Dürfen Alarme zur genauen Zeit gesetzt werden? Ohne das fällt die Planung auf ungenaue Alarme zurück (Abweichung einige Minuten).
  Future<bool> exakteAlarmeMoeglich();

  /// Gleicht die geplanten Erinnerungen des Geräts an [liste] an: alles Geplante, das nicht (mehr) in der Liste steht, wird gelöscht, der
  /// Rest neu gesetzt (gleiche ID überschreibt). Die Testbenachrichtigung bleibt unberührt. [sperrbildschirmTitel]: Titel und Ort dürfen auf dem
  /// Sperrbildschirm erscheinen (sonst privat). Liefert true nur, wenn alles gesetzt werden konnte.
  Future<bool> planen(List<GeplanteErinnerung> liste, {required bool exakt, required bool sperrbildschirmTitel});

  /// Löscht alle geplanten Erinnerungen (Erinnerungen aus, Abmelden). true = gelungen.
  Future<bool> alleLoeschen();

  /// Testbenachrichtigung nach [wartezeit].
  Future<bool> testPlanen(Duration wartezeit, {required bool exakt, required bool sperrbildschirmTitel});

  /// Öffnet die Systemeinstellungen der App für Benachrichtigungen. false = ließ sich nicht öffnen (die Oberfläche zeigt dann einen Hinweis).
  Future<bool> systemEinstellungenOeffnen();

  /// Öffnet "Alarme & Erinnerungen" der App (genaue Alarme). false = ließ sich nicht öffnen.
  Future<bool> alarmEinstellungenOeffnen();

  /// Zustände für die Diagnose-Zeile.
  Future<ErinnerungDiagnose> diagnose();
}

/// Ohne Wirkung: Web und alle Plattformen ohne Erinnerungen.
class KeinErinnerungPort implements ErinnerungPort {
  const KeinErinnerungPort();

  @override
  bool get verfuegbar => false;
  @override
  Future<bool> initialisieren({required void Function(String payload) beiTipp}) async => false;
  @override
  Future<String?> startPayload() async => null;
  @override
  Future<bool> benachrichtigungenErlaubt() async => false;
  @override
  Future<BenachrichtigungsStatus> benachrichtigungsStatus() async => BenachrichtigungsStatus.gesperrt;
  @override
  Future<bool> benachrichtigungenAnfragen() async => false;
  @override
  Future<bool> exakteAlarmeMoeglich() async => false;
  @override
  Future<bool> planen(List<GeplanteErinnerung> liste, {required bool exakt, required bool sperrbildschirmTitel}) async => false;
  @override
  Future<bool> alleLoeschen() async => false;
  @override
  Future<bool> testPlanen(Duration wartezeit, {required bool exakt, required bool sperrbildschirmTitel}) async => false;
  @override
  Future<bool> systemEinstellungenOeffnen() async => false;
  @override
  Future<bool> alarmEinstellungenOeffnen() async => false;
  @override
  Future<ErinnerungDiagnose> diagnose() async => const ErinnerungDiagnose();
}
