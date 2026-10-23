// Abfuhrtermine: REINE Logik (keine Oberfläche, kein Netz): nächste Abholung, "morgen", kommende Tage, Texte und die
// Planung der Erinnerungen (Abend vor der Abholung, nur für Eltern/Admins, rollierendes Fenster der bestehenden Erinnerungen).
// Tage sind wie überall im Kalender `DateTime.utc`-Markierungen der Familienzone (Europe/Berlin).
import '../calendar/zeitzonen.dart';
import '../erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung, erinnerungId, kMindestAbstand;
import 'muell_modelle.dart';

/// Heute (Kalendertag in der Familienzone).
DateTime muellHeute(DateTime jetzt) {
  final w = wandUhr(jetzt.toUtc(), familienOrt);
  return DateTime.utc(w.year, w.month, w.day);
}

/// Die nächste Abholung ab [heute] (einschließlich heute); mit [art] nur dieser Art. null = keine bekannt.
MuellTag? naechsteAbholung(List<MuellTag> tage, DateTime heute, {MuellArt? art}) {
  for (final t in tage) {
    if (t.tag.isBefore(heute)) continue;
    if (art == null) return t;
    if (t.arten.contains(art)) return MuellTag(t.tag, [art]);
  }
  return null;
}

/// Tage bis zur Abholung (0 = heute, 1 = morgen).
int tageBis(DateTime tag, DateTime heute) => tag.difference(heute).inDays;

/// Die kommenden Abholungen ab [heute], optional nur einer [art] (dann je Tag nur diese Art), höchstens [max].
List<MuellTag> kommendeAbholungen(List<MuellTag> tage, DateTime heute, {MuellArt? art, int max = 60}) {
  final out = <MuellTag>[];
  for (final t in tage) {
    if (t.tag.isBefore(heute)) continue;
    if (art != null) {
      if (!t.arten.contains(art)) continue;
      out.add(MuellTag(t.tag, [art]));
    } else {
      out.add(t);
    }
    if (out.length >= max) break;
  }
  return out;
}

/// Arten, die in den Terminen vorkommen (für Filter und Einstellungen); "Sonstiges" nur, wenn es vorkommt.
List<MuellArt> vorkommendeArten(List<MuellTag> tage) {
  final s = {for (final t in tage) ...t.arten};
  return [for (final a in MuellArt.values) if (s.contains(a)) a];
}

const _wochentageKurz = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const _wochentageLang = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
const _monateKurz = ['JAN', 'FEB', 'MÄR', 'APR', 'MAI', 'JUN', 'JUL', 'AUG', 'SEP', 'OKT', 'NOV', 'DEZ'];

/// "Mi 28.10." (Kachel).
String muellKurzDatum(DateTime tag) => '${_wochentageKurz[tag.weekday - 1]} ${tag.day}.${tag.month}.';

/// "Mittwoch, 28.10." (Seite).
String muellLangDatum(DateTime tag) => '${_wochentageLang[tag.weekday - 1]}, ${tag.day}.${tag.month}.';

/// Tagesnummer "28" und "Mi · Okt" der Terminliste.
({String zahl, String unten}) muellTagKopf(DateTime tag) => (zahl: tag.day.toString().padLeft(2, '0'), unten: '${_wochentageKurz[tag.weekday - 1]} · ${_monateKurz[tag.month - 1]}');

/// "heute", "morgen", "in 6 Tagen".
String tageBisText(int tage) => tage <= 0 ? 'heute' : (tage == 1 ? 'morgen' : 'in $tage Tagen');

/// "Bioabfall, Gelber Sack".
String artenText(List<MuellArt> arten) => arten.map((a) => a.name).join(', ');

// ------------------------------------------------------------------------------------------------ Prüfung auf neue Dateien

/// Wanduhrzeit eines Zeitpunkts in der Familienzone (Europe/Berlin), nicht in der Zone des Geräts.
DateTime _berlin(DateTime t) => wandUhr(t.toUtc(), familienOrt);

String _hhmm(DateTime t) {
  final l = _berlin(t);
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// "2027: gefunden, 118 Termine" / "2027: noch nicht verfügbar (geprüft um 07:05)" / "2027: Quelle nicht erreichbar (geprüft um 07:05)" /
/// "2027: noch nicht geprüft". Nur feste Texte zu festen Zuständen (nie ein Servertext, nie Fehlerdetails).
String muellJahrErgebnis(MuellDto dto, int jahr) {
  final j = dto.jahr(jahr);
  if (j == null) return '$jahr: noch nicht geprüft';
  final um = j.geprueft == null ? '' : ' (geprüft um ${_hhmm(j.geprueft!)})';
  return switch (j.status) {
    MuellJahrStatus.geladen => '$jahr: gefunden, ${j.anzahlTermine} ${j.anzahlTermine == 1 ? 'Termin' : 'Termine'}',
    MuellJahrStatus.nichtVerfuegbar => '$jahr: noch nicht verfügbar$um',
    MuellJahrStatus.fehler => '$jahr: Quelle nicht erreichbar$um',
  };
}

/// Datum und Uhrzeit für die Prüfzeiten in der Familienzone ("07.12., 06:00").
String muellZeitpunkt(DateTime t) {
  final l = _berlin(t);
  return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}., ${_hhmm(t)}';
}

// ------------------------------------------------------------------------------------------------ Erinnerung

/// Nutzlast der Erinnerung: `muell|<Tag der Abholung YYYY-MM-DD>`; ein Tipp öffnet die Müll-Seite.
String muellErinnerungPayload(DateTime tag) => 'muell|${_ymd(tag)}';

/// true, wenn [payload] zu einer Müll-Benachrichtigung gehört (Erinnerung oder Hinweis auf ein neues Jahr).
bool istMuellPayload(String? payload) => payload == kMuellPayload || (payload != null && RegExp(r'^muell\|\d{4}-\d{2}-\d{2}$').hasMatch(payload));

/// Nutzlast des Hinweises "Abfuhrtermine 20XX sind da".
const kMuellPayload = 'muell';

String _ymd(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Standardzeit der Erinnerung (18:00), in Minuten ab Mitternacht.
const kMuellStandardZeit = 18 * 60;

/// Wie weit voraus Müll-Erinnerungen geplant werden (Tage). Bewusst kurz: die App plant bei jedem Start, jeder Rückkehr und jedem Abgleich neu, und die
/// vielen Abholtermine eines Jahres würden sonst das Fenster von 300 Erinnerungen mit Terminen und Aufgaben teilen und deren spätere Einträge verdrängen.
const kMuellHorizontTage = 90;

/// Die Erinnerungen am Abend vor der Abholung: für jede Abholung mit mindestens einer eingeschalteten Art genau eine Benachrichtigung
/// ("Morgen ist Abholung", Text: die eingeschalteten Arten) um [minuten] Uhr am Vortag (Wanduhr der Familienzone). Vergangenes entfällt,
/// höchstens [horizontTage] Tage voraus. Reine Funktion der Daten und der Uhr; ob die Person Erinnerungen bekommen darf (Eltern/Admin,
/// Schalter an), prüft der Aufrufer.
List<GeplanteErinnerung> planeMuellErinnerungen({
  required List<MuellTag> tage,
  required Set<MuellArt> aktiv,
  required int minuten,
  required DateTime jetzt,
  int horizontTage = kMuellHorizontTage,
}) {
  if (aktiv.isEmpty) return const [];
  final ort = familienOrt;
  final jetztUtc = jetzt.toUtc();
  final grenze = jetztUtc.add(kMindestAbstand);
  final horizont = jetztUtc.add(Duration(days: horizontTage));
  final out = <GeplanteErinnerung>[];
  for (final t in tage) {
    final arten = [for (final a in t.arten) if (aktiv.contains(a)) a];
    if (arten.isEmpty) continue;
    final vortag = DateTime.utc(t.tag.year, t.tag.month, t.tag.day - 1);
    final zeit = instantAusWand(DateTime.utc(vortag.year, vortag.month, vortag.day, minuten ~/ 60, minuten % 60), ort);
    if (!zeit.isAfter(grenze) || zeit.isAfter(horizont)) continue;
    out.add(GeplanteErinnerung(id: erinnerungId('muell', _ymd(t.tag)), zeit: zeit, titel: 'Morgen ist Abholung', text: artenText(arten), payload: muellErinnerungPayload(t.tag)));
  }
  return out;
}

/// "18:00" aus Minuten ab Mitternacht.
String uhrzeitAusMinuten(int minuten) => '${(minuten ~/ 60).toString().padLeft(2, '0')}:${(minuten % 60).toString().padLeft(2, '0')}';
