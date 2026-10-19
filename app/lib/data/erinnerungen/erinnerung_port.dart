// Schnittstelle zum Betriebssystem für Terminerinnerungen. Die App spricht nur diese Schnittstelle an; das Plugin
// (flutter_local_notifications) steckt dahinter und wird nur auf Android eingebunden (erinnerung_port_android.dart, bedingter Import).
// Im Web und in Tests gibt es eine Variante ohne Wirkung bzw. einen Fake.
import 'erinnerung_planung.dart';

/// ID der Testbenachrichtigung ("in 10 Sekunden"); gehört nicht zum Planungsfenster und wird beim Angleichen nicht gelöscht.
const kTestBenachrichtigungId = 1;

abstract class ErinnerungPort {
  /// Gibt es auf diesem Gerät Erinnerungen? Nur Android (nicht Web).
  bool get verfuegbar;

  /// Bereitet das Plugin vor (Kanal "Terminerinnerungen" anlegen). [beiTipp] bekommt den Inhalt ([erinnerungPayload]), wenn die Person
  /// bei laufender App auf eine Benachrichtigung tippt.
  Future<void> initialisieren({required void Function(String payload) beiTipp});

  /// Inhalt der Benachrichtigung, mit deren Tippen die App gestartet wurde (einmalig); sonst null.
  Future<String?> startPayload();

  /// Darf die App Benachrichtigungen anzeigen? (Android 13+: Berechtigung POST_NOTIFICATIONS; sonst Systemschalter)
  Future<bool> benachrichtigungenErlaubt();

  /// Fragt die Berechtigung ab (Android 13+: Systemdialog). Liefert, ob sie jetzt erteilt ist.
  Future<bool> benachrichtigungenAnfragen();

  /// Dürfen Alarme zur genauen Zeit gesetzt werden? Ohne das fällt die Planung auf ungenaue Alarme zurück (Abweichung einige Minuten).
  Future<bool> exakteAlarmeMoeglich();

  /// Gleicht die geplanten Erinnerungen des Geräts an [liste] an: alles Geplante, das nicht (mehr) in der Liste steht, wird gelöscht, der
  /// Rest neu gesetzt (gleiche ID überschreibt). Die Testbenachrichtigung bleibt unberührt.
  Future<void> planen(List<GeplanteErinnerung> liste, {required bool exakt});

  /// Löscht alle geplanten Erinnerungen (Erinnerungen aus, Abmelden).
  Future<void> alleLoeschen();

  /// Testbenachrichtigung nach [wartezeit].
  Future<void> testPlanen(Duration wartezeit, {required bool exakt});

  /// Öffnet die Systemeinstellungen der App für Benachrichtigungen.
  Future<void> systemEinstellungenOeffnen();
}

/// Ohne Wirkung: Web und alle Plattformen ohne Erinnerungen.
class KeinErinnerungPort implements ErinnerungPort {
  const KeinErinnerungPort();

  @override
  bool get verfuegbar => false;
  @override
  Future<void> initialisieren({required void Function(String payload) beiTipp}) async {}
  @override
  Future<String?> startPayload() async => null;
  @override
  Future<bool> benachrichtigungenErlaubt() async => false;
  @override
  Future<bool> benachrichtigungenAnfragen() async => false;
  @override
  Future<bool> exakteAlarmeMoeglich() async => false;
  @override
  Future<void> planen(List<GeplanteErinnerung> liste, {required bool exakt}) async {}
  @override
  Future<void> alleLoeschen() async {}
  @override
  Future<void> testPlanen(Duration wartezeit, {required bool exakt}) async {}
  @override
  Future<void> systemEinstellungenOeffnen() async {}
}
