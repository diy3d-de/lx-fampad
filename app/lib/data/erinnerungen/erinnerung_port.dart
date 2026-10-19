// Schnittstelle zum Betriebssystem für Terminerinnerungen. Die App spricht nur diese Schnittstelle an; das Plugin
// (flutter_local_notifications) steckt dahinter und wird nur auf Android eingebunden (erinnerung_port_android.dart, bedingter Import).
// Im Web und in Tests gibt es eine Variante ohne Wirkung bzw. einen Fake.
import 'erinnerung_planung.dart';

/// ID der Testbenachrichtigung ("in 10 Sekunden"); gehört nicht zum Planungsfenster und wird beim Angleichen nicht gelöscht.
const kTestBenachrichtigungId = 1;

/// ID der Hinweis-Benachrichtigung "Erinnerungen laufen aus" (gehört zur Planung, siehe erinnerung_planung.dart).
const kAuslaufHinweisId = 2;

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

  /// Fragt die Berechtigung ab (Android 13+: Systemdialog). Liefert, ob sie jetzt erteilt ist.
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

  /// Öffnet die Systemeinstellungen der App für Benachrichtigungen.
  Future<void> systemEinstellungenOeffnen();
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
  Future<void> systemEinstellungenOeffnen() async {}
}
