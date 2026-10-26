// Zähler (Abschnitt 6l): Planung der Ablese-Erinnerungen als reine Logik (kein Plugin, keine Oberfläche). Das Ergebnis geht über `planeErinnerungen(zusatz:)` in das gemeinsame
// Fenster des Erinnerungsdienstes, wie die Müll- und Medikamenten-Erinnerungen.
//
// Regeln:
//  - Lokal und nur für Eltern und Admins (der Dienst übergibt für alle anderen gar keine Daten); nie Push, nie ein Wecker vom Server.
//  - Der Text ist IMMER neutral und für alle Zähler gleich: "Zeit, die Zähler abzulesen", nie Art, Name, Stand oder Verbrauch; auch auf dem Sperrbildschirm. Die Nutzlast ist nur
//    `zaehler` (keine ID, kein Inhalt).
//  - Am Ablesetag um 09:00 Uhr (Familienzone). Ein Alarm je Tag, auch wenn mehrere Zähler am selben Tag dran sind.
//  - Wurde der Zähler seit dem Solltermin schon abgelesen (Stand am Tag oder danach), entfällt der Alarm dieses Tages. Archivierte Zähler, Zähler ohne Rhythmus und Zähler mit automatischer Quelle erinnern nie.
//  - Monatlich: 75 Tage voraus; jährlich (Jahresablesung): 400 Tage voraus; vergangene Zeitpunkte entfallen.
import '../calendar/zeitzonen.dart';
import '../erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung, erinnerungId, kMindestAbstand;
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';
import 'zaehler_monate.dart';
import 'zaehler_state.dart';
import 'zaehler_uebersicht.dart';

/// Neutraler Titel und Text (nie ein Inhalt).
const String kZaehlerTitel = 'Zeit, die Zähler abzulesen';
const String kZaehlerErinnerungText = 'Tippe, um die Stände einzutragen.';

/// Uhrzeit der Erinnerung (Minuten ab Mitternacht): 09:00.
const int kZaehlerErinnerungMinute = 9 * 60;

/// Horizont in Tagen.
const int kZaehlerHorizontMonatlich = 75;
const int kZaehlerHorizontJaehrlich = 400;

/// Nutzlast der Benachrichtigung (nur eine Kennung).
const String kZaehlerPayload = 'zaehler';

/// Ist es die Nutzlast einer Zähler-Erinnerung? Nie eine Ausnahme.
bool istZaehlerPayload(String? payload) => payload == kZaehlerPayload;

/// Die Solltermine einer Ablesung im Zeitraum [von, bis] (Tage, einschließlich).
List<DateTime> ablesetermine(Ablesung a, DateTime von, DateTime bis) {
  final out = <DateTime>[];
  if (a.art == AblesungArt.monatlich) {
    for (var m = 0; m < 30; m++) {
      final t = tagImMonat(von.year, von.month + m, a.tag);
      if (t.isAfter(bis)) break;
      if (!t.isBefore(von)) out.add(t);
    }
  } else {
    for (var j = von.year; j <= bis.year; j++) {
      final t = tagImMonat(j, a.monat, a.tag);
      if (!t.isBefore(von) && !t.isAfter(bis)) out.add(t);
    }
  }
  return out;
}

/// Die Erinnerungen ab [jetzt]. Ohne Daten (nicht geladen, nicht erlaubt, keine Zähler) nichts.
List<GeplanteErinnerung> planeZaehlerErinnerungen({required ZaehlerDaten daten, required DateTime jetzt}) {
  if (!daten.darf || !daten.geladen || daten.reihen.isEmpty) return const [];
  final ort = familienOrt;
  final jetztUtc = jetzt.toUtc();
  final grenze = jetztUtc.add(kMindestAbstand);
  final wand = wandUhr(jetztUtc, ort);
  final heute = DateTime.utc(wand.year, wand.month, wand.day);
  final tage = <int, DateTime>{};
  for (final r in daten.reihen) {
    if (r.archiviert) continue;
    if (r.monatlich) {
      // Eingabeart Monatswerte: am Monatsersten um 09:00, solange der Wert des Vormonats fehlt (dieselbe neutrale Erinnerung wie sonst)
      for (final t in monatswertErinnerungstage(r.monatswerte, heute, heute.add(const Duration(days: kZaehlerHorizontMonatlich)))) {
        tage[tagNummer(t)] = t;
      }
      continue;
    }
    if (r.inhalt.automatisch) continue; // automatische Quelle (Home Assistant): kein Ablese-Rhythmus, keine Erinnerung
    final a = r.inhalt.ablesung;
    if (a == null) continue;
    final bis = heute.add(Duration(days: a.art == AblesungArt.monatlich ? kZaehlerHorizontMonatlich : kZaehlerHorizontJaehrlich));
    final letzter = r.letzter?.tag;
    for (final t in ablesetermine(a, heute, bis)) {
      if (letzter != null && !letzter.isBefore(t)) continue; // seit dem Termin schon abgelesen
      tage[tagNummer(t)] = t;
    }
  }
  final out = <GeplanteErinnerung>[];
  for (final t in tage.values) {
    final zeit = instantAusWand(DateTime.utc(t.year, t.month, t.day, kZaehlerErinnerungMinute ~/ 60, kZaehlerErinnerungMinute % 60), ort);
    if (!zeit.isAfter(grenze)) continue;
    out.add(GeplanteErinnerung(id: erinnerungId('zaehler', tagIso(t)), zeit: zeit, titel: kZaehlerTitel, text: kZaehlerErinnerungText, payload: kZaehlerPayload));
  }
  return out;
}
