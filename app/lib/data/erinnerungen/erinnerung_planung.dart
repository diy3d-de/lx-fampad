// Terminerinnerungen: REINE Planungslogik (kein Plugin, keine Oberfläche). Aus den lokalen Kalenderdaten wird berechnet, welche
// Erinnerungen als Nächstes auf dem Gerät geplant werden sollen ("rollierendes Fenster"): die nächsten [kErinnerungFenster]
// Erinnerungen ab jetzt. Android begrenzt die Zahl der Alarme je App (Samsung rund 500); bei jedem Start, jedem Abgleich und jeder
// Änderung wird das Fenster neu berechnet und das Gerät darauf angeglichen (siehe erinnerung_dienst.dart).
//
// Aufgaben (Abschnitt 6e) teilen sich dasselbe Fenster: offene Aufgaben mit Fälligkeit und `erinnerungMin`, die der Person zugewiesen sind
// (oder ohne Zuständige von ihr stammen); Bezugspunkt eines Fälligkeitstags ohne Uhrzeit ist wie bei ganztägigen Terminen 09:00 Uhr.
//
// Regeln (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6b, "Erinnerungen"):
//  - Quelle ist `Termin.erinnerungMin` (Minuten VOR dem Beginn, null und -1 = keine; nur Werte >= 0 werden geplant). Serien erinnern an jedem Vorkommen; abgesagte Vorkommen
//    nicht; verschobene Vorkommen (Ausnahme) zur neuen Zeit; einen geänderten Titel/Ort der Ausnahme zeigt die Erinnerung.
//  - Zeittermine: Beginn (echter Zeitpunkt) minus Vorlaufzeit. Ganze Tage der Vorlaufzeit (1440, 10080 ...) werden in der Wanduhr der
//    Familienzone gerechnet, wie bei ganztägigen Terminen: "1 Tag vorher" bei einem Termin um 10:00 ist am Vortag um 10:00, auch über die
//    Zeitumstellung. Der Rest (Minuten, Stunden) ist eine absolute Dauer.
//  - Ganztägige Termine haben keine Uhrzeit: Bezugspunkt ist 09:00 Uhr (Familienzone) am ersten Tag, davon wird die Vorlaufzeit
//    abgezogen. "Zur Startzeit" = 09:00 am Tag, "1 Tag vorher" = 09:00 am Vortag, "1 Woche vorher" = 09:00 sieben Tage davor.
//  - Nur Termine, die die angemeldete Person betreffen: sie ist Ersteller oder Teilnehmer. Ein Termin ohne Ersteller erinnert nur seine
//    Teilnehmer. Andere Familientermine erscheinen im Kalender, lösen aber keine Benachrichtigung aus.
//  - Vergangenes wird übersprungen (Zeitpunkt der Erinnerung muss in der Zukunft liegen).
//  - Gibt es mehr Erinnerungen als das Fenster fasst, steht als letzter Platz eine Hinweis-Benachrichtigung ("Erinnerungen laufen aus"),
//    die zum Öffnen der App auffordert; beim Öffnen wird das Fenster erneuert.
import 'package:timezone/timezone.dart' as tz;

import '../../constants.dart';
import '../app_database.dart' show Aufgabe;
import '../calendar/expansion.dart';
import '../calendar/geburtstag.dart' show vorkommenTitel;
import '../calendar/termin_repository.dart' show KalenderDaten;
import '../calendar/zeitzonen.dart';
import '../tasks/aufgabe_logik.dart' show faelligWand, istErledigt;

/// Wie viele Erinnerungen höchstens gleichzeitig beim Betriebssystem geplant sind (ohne Hinweis). Android begrenzt die Alarme je App
/// (Samsung rund 500); mit Reserve für andere Alarme der App bleibt es bei 300.
const kErinnerungFenster = 300;

/// Uhrzeit (Familienzone), auf die sich Erinnerungen ganztägiger Termine beziehen.
const kGanztaegigStunde = 9;

/// Wie weit voraus Termine betrachtet werden (Tage). Ein jährlicher Termin (Geburtstag) fällt damit noch hinein.
const kErinnerungHorizontTage = 366;

/// Größte Vorlaufzeit, die der Server erlaubt (4 Wochen); erweitert das Betrachtungsfenster.
const kMaxVorlaufMin = 40320;

/// Zeit des Hinweises "Erinnerungen laufen aus" nach der letzten geplanten Erinnerung.
const kAuslaufHinweisAbstand = Duration(minutes: 1);

/// Mindestabstand zwischen "jetzt" und einer Erinnerung (sonst gilt sie als vergangen).
const kMindestAbstand = Duration(seconds: 5);

/// Eine geplante Erinnerung. [id] ist stabil für dasselbe Vorkommen eines Termins (gleiche ID überschreibt die alte Planung).
class GeplanteErinnerung {
  final int id;

  /// Wann die Benachrichtigung erscheinen soll (UTC-Zeitpunkt).
  final DateTime zeit;
  final String titel;
  final String text;

  /// Was beim Tippen geöffnet wird (siehe [erinnerungPayload]).
  final String payload;
  const GeplanteErinnerung({required this.id, required this.zeit, required this.titel, required this.text, required this.payload});

  /// Inhaltsgleich? (Der Dienst plant nur neu, wenn sich etwas geändert hat.)
  bool gleich(GeplanteErinnerung o) => id == o.id && zeit == o.zeit && titel == o.titel && text == o.text && payload == o.payload;
}

/// Alle IDs der Erinnerungen liegen in diesem Bereich; kleinere Werte sind für andere Zwecke reserviert (Testbenachrichtigung = 1,
/// Hinweis "Erinnerungen laufen aus" = 2).
const kErinnerungIdMin = 1000;
const _kIdMax = 0x7fffffff;

/// ID des Hinweises "Erinnerungen laufen aus" (gleicher Wert wie kAuslaufHinweisId in erinnerung_port.dart).
const kAuslaufHinweisPlanId = 2;

/// Stabile ID aus Termin und Schlüssel des Vorkommens (FNV-1a, 32 Bit).
int erinnerungId(String terminId, String schluessel) {
  var h = 0x811c9dc5;
  for (final c in '$terminId|$schluessel'.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return kErinnerungIdMin + h % (_kIdMax - kErinnerungIdMin);
}

/// Inhalt für das Tippen auf die Benachrichtigung: `termin|<Termin-ID>|<Tag YYYY-MM-DD>`.
String erinnerungPayload(String terminId, DateTime tag) => 'termin|$terminId|${tagText(tag)}';

/// Inhalt für das Tippen auf die Erinnerung einer Aufgabe: `aufgabe|<Aufgaben-ID>`.
String aufgabeErinnerungPayload(String aufgabeId) => 'aufgabe|$aufgabeId';

/// Liest das Ergebnis von [aufgabeErinnerungPayload]; null bei einem unbekannten Format (die ID muss eine UUID sein). Nie eine Ausnahme.
String? aufgabeErinnerungPayloadLesen(String? payload) {
  if (payload == null) return null;
  final teile = payload.split('|');
  if (teile.length != 2 || teile[0] != 'aufgabe' || !_uuid.hasMatch(teile[1])) return null;
  return teile[1];
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Liest das Ergebnis von [erinnerungPayload]; null bei einem unbekannten Format (die Termin-ID muss eine UUID sein). Nie eine Ausnahme.
({String terminId, DateTime tag})? erinnerungPayloadLesen(String? payload) {
  if (payload == null) return null;
  final teile = payload.split('|');
  if (teile.length != 3 || teile[0] != 'termin' || !_uuid.hasMatch(teile[1])) return null;
  final tag = tagAusText(teile[2]);
  if (tag == null) return null;
  return (terminId: teile[1], tag: tag);
}

const _wochentage = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const _monate = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];

String _hhmm(DateTime w) => '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

/// Text der Benachrichtigung: "Heute, 14:30 · Praxis", "Morgen, ganztägig", "Mi, 21. Okt, 10:00". [erinnerungTag] ist der Kalendertag
/// (Familienzone), an dem die Erinnerung erscheint.
String erinnerungInhalt(Vorkommen v, DateTime erinnerungTag) {
  final start = v.ersterTag;
  final diff = start.difference(DateTime.utc(erinnerungTag.year, erinnerungTag.month, erinnerungTag.day)).inDays;
  final tag = switch (diff) {
    0 => 'Heute',
    1 => 'Morgen',
    _ => '${_wochentage[start.weekday - 1]}, ${start.day}. ${_monate[start.month - 1]}',
  };
  final zeit = v.ganztaegig ? 'ganztägig' : _hhmm(v.startWand);
  final ort = v.ort.trim();
  return ort.isEmpty ? '$tag, $zeit' : '$tag, $zeit · $ort';
}

/// Text der Erinnerung einer Aufgabe: "Fällig heute, 14:30", "Fällig morgen", "Fällig Mi, 21. Okt". [faellig] ist die Fälligkeit (Wanduhr der
/// Familienzone; ohne Uhrzeit 0 Uhr), [erinnerungTag] der Kalendertag, an dem die Erinnerung erscheint.
String aufgabeErinnerungInhalt(DateTime faellig, bool mitUhrzeit, DateTime erinnerungTag) {
  final tag = DateTime.utc(faellig.year, faellig.month, faellig.day);
  final diff = tag.difference(DateTime.utc(erinnerungTag.year, erinnerungTag.month, erinnerungTag.day)).inDays;
  final text = switch (diff) {
    0 => 'heute',
    1 => 'morgen',
    _ => '${_wochentage[tag.weekday - 1]}, ${tag.day}. ${_monate[tag.month - 1]}',
  };
  return mitUhrzeit ? 'Fällig $text, ${_hhmm(faellig)}' : 'Fällig $text';
}

/// Text der Erinnerung einer Frist (Fristen-Tracker): "Läuft heute ab", "Läuft morgen ab", "Läuft ab Mi, 21. Okt". [ablauf] ist das Ablaufdatum,
/// [erinnerungTag] der Kalendertag, an dem die Erinnerung erscheint. Die Vorwarnzeit steht nie im Text (sie ist beim Zeitpunkt, nicht im Inhalt).
String fristErinnerungInhalt(DateTime ablauf, DateTime erinnerungTag) {
  final tag = DateTime.utc(ablauf.year, ablauf.month, ablauf.day);
  final diff = tag.difference(DateTime.utc(erinnerungTag.year, erinnerungTag.month, erinnerungTag.day)).inDays;
  return switch (diff) {
    0 => 'Läuft heute ab',
    1 => 'Läuft morgen ab',
    _ => 'Läuft ab ${_wochentage[tag.weekday - 1]}, ${tag.day}. ${_monate[tag.month - 1]} ${tag.year}',
  };
}

/// Betrifft die Aufgabe die Person [ich]? Ihr zugewiesen; ohne Zuständige nur, wenn sie die Aufgabe selbst angelegt hat. Eine Aufgabe, die
/// jemand anderem zugewiesen ist, erinnert nur diese Person.
bool aufgabeBetrifftPerson(String? zustaendig, String? ownerId, String? ich) {
  if (ich == null) return false;
  return zustaendig == null ? ownerId == ich : zustaendig == ich;
}

/// Betrifft der Termin die Person [ich]? Ersteller oder Teilnehmer; ein Termin ohne Ersteller erinnert nur seine Teilnehmer.
bool betrifftPerson(String? ownerId, Set<String> teilnehmer, String? ich) {
  if (ich == null) return false;
  return ownerId == ich || teilnehmer.contains(ich);
}

/// Zeitpunkt der Erinnerung: ganze Tage in der Wanduhr der Familienzone, der Rest als absolute Dauer. [beginn] ist bei ganztägigen
/// Terminen 09:00 Uhr am ersten Tag.
DateTime _erinnerungsZeit(DateTime beginn, int min, tz.Location ort) {
  final tage = min ~/ 1440;
  final rest = min % 1440;
  var zeit = beginn;
  if (tage > 0) {
    final w = wandUhr(beginn, ort);
    zeit = instantAusWand(DateTime.utc(w.year, w.month, w.day - tage, w.hour, w.minute, w.second), ort);
  }
  return zeit.subtract(Duration(minutes: rest));
}

/// Die nächsten Erinnerungen ab [jetzt], zeitlich sortiert, höchstens [maxAnzahl] (danach, falls es mehr gäbe, der Hinweis "Erinnerungen
/// laufen aus"). Reine Funktion der Daten und der Uhr. [zusatz]: weitere, schon berechnete Erinnerungen (Abfuhrtermine), die sich das Fenster teilen.
List<GeplanteErinnerung> planeErinnerungen({
  required KalenderDaten daten,
  required String? ich,
  required DateTime jetzt,
  int maxAnzahl = kErinnerungFenster,
  List<Aufgabe> aufgaben = const [],
  List<GeplanteErinnerung> zusatz = const [],
  bool elternRolle = false,
}) {
  if (ich == null || maxAnzahl <= 0) return const [];
  final jetztUtc = jetzt.toUtc();
  final mitErinnerung = daten.termine.where((t) {
    final m = t.erinnerungMin;
    return m != null && m >= 0 && betrifftPerson(t.ownerId, daten.teilnehmerIds(t.id), ich);
  }).toList();
  final berlin = familienOrt;
  final vonWand = wandUhr(jetztUtc, berlin);
  // Beginn bis Horizont plus größte Vorlaufzeit; ab "jetzt" (auch laufende Termine kommen vor, ihre Erinnerung liegt aber in der Vergangenheit)
  final bisWand = vonWand.add(const Duration(days: kErinnerungHorizontTage + kMaxVorlaufMin ~/ 1440 + 1));
  final vorkommen = mitErinnerung.isEmpty
      ? const <Vorkommen>[]
      : vorkommenImFenster(termine: mitErinnerung, ausnahmen: daten.ausnahmen, vonWand: vonWand, bisWand: bisWand, jetzt: jetztUtc);
  final grenze = jetztUtc.add(kMindestAbstand);
  final out = <GeplanteErinnerung>[];
  final ids = <int>{};
  for (final v in vorkommen) {
    final min = v.termin.erinnerungMin!;
    final DateTime beginn;
    if (v.ganztaegig) {
      final t = v.ersterTag;
      beginn = instantAusWand(DateTime.utc(t.year, t.month, t.day, kGanztaegigStunde), berlin);
    } else {
      beginn = v.startUtc;
    }
    final zeit = _erinnerungsZeit(beginn, min, berlin);
    if (!zeit.isAfter(grenze)) continue;
    final id = erinnerungId(v.termin.id, v.schluessel);
    if (!ids.add(id)) continue; // ID-Kollision (praktisch ausgeschlossen): die frühere Erinnerung bleibt
    final w = wandUhr(zeit, berlin);
    out.add(
      GeplanteErinnerung(
        id: id,
        zeit: zeit,
        titel: v.titel.trim().isEmpty ? 'Termin' : vorkommenTitel(v),
        text: erinnerungInhalt(v, DateTime.utc(w.year, w.month, w.day)),
        payload: erinnerungPayload(v.termin.id, v.ersterTag),
      ),
    );
  }
  final horizont = jetztUtc.add(const Duration(days: kErinnerungHorizontTage));
  for (final a in aufgaben) {
    final min = a.erinnerungMin;
    if (min == null || min < 0 || istErledigt(a) || !(aufgabeBetrifftPerson(a.assigneeId, a.ownerId, ich) || (a.frist && elternRolle))) continue; // Fristen erinnern zusätzlich alle Eltern und Admins
    final wand = faelligWand(a);
    if (wand == null) continue;
    final mitUhr = a.faelligUtc != null;
    final beginn = mitUhr ? a.faelligUtc!.toUtc() : instantAusWand(DateTime.utc(wand.year, wand.month, wand.day, kGanztaegigStunde), berlin);
    final zeit = _erinnerungsZeit(beginn, min, berlin);
    if (!zeit.isAfter(grenze) || zeit.isAfter(horizont)) continue; // gleicher Horizont wie bei Terminen
    final id = erinnerungId(a.id, 'aufgabe');
    if (!ids.add(id)) continue;
    final w = wandUhr(zeit, berlin);
    out.add(
      GeplanteErinnerung(
        id: id,
        zeit: zeit,
        titel: a.titel.trim().isEmpty ? 'Aufgabe' : a.titel,
        text: a.frist ? fristErinnerungInhalt(wand, DateTime.utc(w.year, w.month, w.day)) : aufgabeErinnerungInhalt(wand, mitUhr, DateTime.utc(w.year, w.month, w.day)),
        payload: aufgabeErinnerungPayload(a.id),
      ),
    );
  }
  // Zusätzliche, schon berechnete Erinnerungen (Müll: Abend vor der Abholung) teilen sich das Fenster
  for (final z in zusatz) {
    if (ids.add(z.id)) out.add(z);
  }
  if (out.isEmpty) return const [];
  out.sort((a, b) {
    final c = a.zeit.compareTo(b.zeit);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  if (out.length <= maxAnzahl) return out;
  final fenster = out.sublist(0, maxAnzahl);
  fenster.add(
    GeplanteErinnerung(
      id: kAuslaufHinweisPlanId,
      zeit: fenster.last.zeit.add(kAuslaufHinweisAbstand),
      titel: 'Erinnerungen laufen aus',
      text: 'Öffne $kAppName, damit neue Erinnerungen geplant werden.',
      payload: '',
    ),
  );
  return fenster;
}
