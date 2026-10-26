// Tagesbriefing am Morgen: Planung der lokalen Benachrichtigung als reine Logik (kein Plugin, keine Oberfläche). Das Ergebnis geht über `planeErinnerungen(zusatz:)` in das
// gemeinsame Fenster des Erinnerungsdienstes (erinnerung_planung.dart), wie die Müll- und Medikamenten-Erinnerungen.
//
//  - Lokal, nie Push, nichts verlässt das Gerät. Eigener Schalter (Standard aus), unabhängig vom Schalter der Termin-Erinnerungen.
//  - Die Benachrichtigung wird vorab geplant und kennt darum nur den Stand beim letzten Planen: der Text ist NEUTRAL und enthält nur Zahlen ("Heute: 3 Termine, 2 Aufgaben",
//    nie Titel oder Namen, auch nicht auf dem Sperrbildschirm). Der Dienst plant bei jeder Änderung der Termine und Aufgaben, bei App-Start und Rückkehr neu.
//  - Vorausgeplant wird [kBriefingHorizontTage] Tage (heute eingeschlossen); ein Tag ohne Inhalt bekommt keine Benachrichtigung. Für spätere Tage zählen Termine dieses Tages und
//    alles Offene, das bis dahin fällig oder überfällig ist.
//  - Nutzlast `briefing`: der Tipp öffnet die Startseite.
import '../app_database.dart' show Aufgabe;
import '../calendar/termin_repository.dart' show KalenderDaten;
import '../calendar/zeitzonen.dart';
import '../erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung, erinnerungId, kMindestAbstand;
import '../tasks/aufgabe_logik.dart' show tagVon;
import 'briefing_logik.dart';

/// Wie viele Tage (heute eingeschlossen) vorausgeplant wird.
const kBriefingHorizontTage = 7;

const kBriefingPayload = 'briefing';
const kBriefingTitel = 'Heute im Überblick';

bool istBriefingPayload(String? payload) => payload == kBriefingPayload;

String _ymd(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Die Benachrichtigungen der nächsten Tage ab [jetzt], jeweils um [minuten] Uhr (Wanduhr der Familienzone). Vergangenes entfällt, leere Tage auch.
List<GeplanteErinnerung> planeBriefingErinnerungen({
  required KalenderDaten daten,
  required List<Aufgabe> aufgaben,
  required String? ich,
  required bool elternRolle,
  required int minuten,
  required DateTime jetzt,
  int tage = kBriefingHorizontTage,
}) {
  if (ich == null || minuten < 0 || minuten >= 1440) return const [];
  final ort = familienOrt;
  final grenze = jetzt.toUtc().add(kMindestAbstand);
  final heute = tagVon(jetzt);
  final out = <GeplanteErinnerung>[];
  for (var i = 0; i < tage; i++) {
    final tag = DateTime.utc(heute.year, heute.month, heute.day + i);
    final zeit = instantAusWand(DateTime.utc(tag.year, tag.month, tag.day, minuten ~/ 60, minuten % 60), ort);
    if (!zeit.isAfter(grenze)) continue;
    final text = baueTagesbriefing(kalender: daten, aufgaben: aufgaben, ich: ich, elternRolle: elternRolle, jetzt: zeit).neutralerText;
    if (text == null) continue;
    out.add(GeplanteErinnerung(id: erinnerungId('briefing', _ymd(tag)), zeit: zeit, titel: kBriefingTitel, text: text, payload: kBriefingPayload));
  }
  return out;
}
