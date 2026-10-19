// Terminserien auflösen: aus Terminen (Master mit RRULE) und Ausnahmen werden einzelne Vorkommen in einem Zeitfenster.
//
// Zeitmodell (siehe docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6a):
//  - Zeittermine: Zeitpunkte (UTC) + Zeitzone (`tzid`). Die Wiederholung gilt in der Wanduhrzeit der `tzid`: "jeden Dienstag 10 Uhr" bleibt
//    auch über die Zeitumstellung 10 Uhr. Das Paket `rrule` kennt keine Zeitzonen; deshalb wird die Wanduhrzeit als `DateTime.utc`
//    getarnt expandiert und danach mit `timezone` in echte Zeitpunkte umgerechnet (siehe zeitzonen.dart).
//  - Ganztägige Termine: Kalendertage, Ende exklusiv, ohne Zeitzone.
//  - Anzeige und Tagesgrenzen immer in der Familienzeitzone (Europe/Berlin). Alle `*Wand`-Werte sind Wanduhrzeiten der Familienzone
//    als `DateTime.utc`-Markierung, nie echte UTC-Zeitpunkte.
// Deckel (Schutz vor Rechenlast durch Regeln aus dem Netz): höchstens [kMaxVorkommen] Vorkommen je Termin und Abfrage, Horizont
// [kHorizontJahre] Jahre ab heute. Eine Ausnahme, die ein Vorkommen aus dem Fenster heraus oder in das Fenster hinein verschiebt,
// wirkt nur, wenn das ursprüngliche Vorkommen im Fenster liegt.
import 'package:rrule/rrule.dart';
import 'package:timezone/timezone.dart' as tz;

import '../app_database.dart';
import 'zeitzonen.dart';

const kMaxVorkommen = 1000;
const kHorizontJahre = 5;

/// Ein einzelnes Vorkommen eines Termins (bei Serien nach Anwendung der Ausnahme).
class Vorkommen implements Comparable<Vorkommen> {
  final Termin termin;

  /// Schlüssel des ursprünglichen Vorkommens (`originalStart` einer Ausnahme): UTC-Zeitpunkt `YYYY-MM-DDTHH:MM:SSZ` bzw. Tag `YYYY-MM-DD`.
  final String schluessel;
  final bool ganztaegig;
  final DateTime startWand;

  /// Ende (bei ganztägigen Terminen exklusiv).
  final DateTime endeWand;

  /// Echter Zeitpunkt des Beginns (bei ganztägigen Terminen: Mitternacht der Familienzone).
  final DateTime startUtc;
  final String titel;
  final String ort;

  /// Zu diesem Vorkommen gibt es eine Ausnahme, die etwas ändert.
  final bool geaendert;
  final bool serie;

  /// Beginn und Ende des URSPRÜNGLICHEN Vorkommens (vor einer Verschiebung durch eine Ausnahme), Wanduhr der Familienzone bzw. Zeitpunkt.
  /// Serien teilen, kürzen und Ausnahmen vergleichen immer gegen diese Werte, nie gegen die (womöglich verschobene) Anzeige.
  final DateTime originalStartWand;
  final DateTime originalEndeWand;
  final DateTime originalStartUtc;
  const Vorkommen({
    required this.termin,
    required this.schluessel,
    required this.ganztaegig,
    required this.startWand,
    required this.endeWand,
    required this.startUtc,
    required this.titel,
    required this.ort,
    required this.geaendert,
    required this.serie,
    required this.originalStartWand,
    required this.originalEndeWand,
    required this.originalStartUtc,
  });

  /// Erster Kalendertag, an dem das Vorkommen stattfindet.
  DateTime get ersterTag => DateTime.utc(startWand.year, startWand.month, startWand.day);

  /// Letzter Kalendertag (ganztägig: Ende exklusiv; Zeittermin: ein Ende um 0 Uhr zählt nicht mehr zum Folgetag).
  DateTime get letzterTag {
    final e = endeWand.isAfter(startWand) ? endeWand.subtract(const Duration(seconds: 1)) : endeWand;
    return DateTime.utc(e.year, e.month, e.day);
  }

  bool faelltAuf(DateTime tag) => !tag.isBefore(ersterTag) && !tag.isAfter(letzterTag);

  @override
  int compareTo(Vorkommen o) {
    final t = startWand.compareTo(o.startWand);
    if (t != 0) return t;
    if (ganztaegig != o.ganztaegig) return ganztaegig ? -1 : 1;
    final e = endeWand.compareTo(o.endeWand);
    return e != 0 ? e : termin.id.compareTo(o.termin.id);
  }
}

/// `YYYY-MM-DD` -> Tag (Markierung UTC); null bei einem anderen Format.
DateTime? tagAusText(String? s) {
  if (s == null || s.length != 10) return null;
  return DateTime.tryParse('${s}T00:00:00Z');
}

String tagText(DateTime tag) =>
    '${tag.year.toString().padLeft(4, '0')}-${tag.month.toString().padLeft(2, '0')}-${tag.day.toString().padLeft(2, '0')}';

/// Schlüssel eines Zeitpunkts wie auf dem Server (`YYYY-MM-DDTHH:MM:SSZ`).
String zeitSchluessel(DateTime instant) => instant.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

final _untilTeil = RegExp(r'(^|;)UNTIL=([0-9TZ]+)');

/// Zerlegt eine Regel in die Regel ohne UNTIL und das UNTIL (`YYYYMMDD` oder `YYYYMMDDTHHMMSSZ`).
({String regel, String? until}) regelOhneUntil(String rrule) {
  final m = _untilTeil.firstMatch(rrule);
  if (m == null) return (regel: rrule, until: null);
  final rest = rrule.replaceFirst(_untilTeil, '').replaceAll(RegExp(r'^;|;$'), '');
  return (regel: rest, until: m.group(2));
}

DateTime? _untilAlsInstant(String s) {
  if (s.length == 8) return DateTime.tryParse('${s}T000000Z');
  if (s.length == 16) return DateTime.tryParse(s);
  return null;
}

/// Die Regel zum Rechnen: UNTIL (in UTC bzw. als Tag) wird in die Wanduhrzeit von [ort] umgerechnet, weil die Wiederholung dort gerechnet
/// wird. Null bei einer Regel, die nicht lesbar ist.
RecurrenceRule? regelFuer(String rrule, {required bool ganztaegig, required tz.Location ort}) {
  try {
    final teile = regelOhneUntil(rrule);
    var regel = RecurrenceRule.fromString('RRULE:${teile.regel}');
    // Sekunden-/Minuten-/Stundenserien und absurde Anzahlen lehnt auch der Server ab; ein Termin mit so einer Regel gilt als einmalig
    if (![Frequency.daily, Frequency.weekly, Frequency.monthly, Frequency.yearly].contains(regel.frequency) ||
        regel.bySeconds.isNotEmpty ||
        regel.byMinutes.isNotEmpty ||
        regel.byHours.isNotEmpty ||
        (regel.count ?? 0) > kMaxVorkommen) {
      return null;
    }
    final u = teile.until == null ? null : _untilAlsInstant(teile.until!);
    if (teile.until != null && u == null) return null;
    if (u != null) {
      final nurTag = ganztaegig || teile.until!.length == 8;
      final bis = nurTag ? DateTime.utc(u.year, u.month, u.day, 23, 59, 59) : wandUhr(u, ort);
      regel = regel.copyWith(until: bis);
    }
    return regel;
  } catch (_) {
    return null;
  }
}

/// Anzahl der Vorkommen einer Regel vor [vorWand] (Wanduhr der Zeitzone [ort]); für das Aufteilen einer Serie mit COUNT.
int vorkommenVor(String rrule, {required DateTime startWand, required DateTime vorWand, required bool ganztaegig, required tz.Location ort}) {
  final regel = regelFuer(rrule, ganztaegig: ganztaegig, ort: ort);
  if (regel == null) return 0;
  return regel.getInstances(start: startWand, before: vorWand).take(kMaxVorkommen).length;
}

/// Zeitbudget je Regel und Abfrage (Schutz vor Rechenlast durch Regeln aus dem Netz).
const _kBudgetMs = 150;
final _cache = <String, List<DateTime>>{};
const _kCacheMax = 256;

/// Instanzen der Regel ab [nach] (nie vor dem Beginn; `after` des Pakets muss mindestens `start` sein), bis [vor] (ausschließlich), höchstens
/// [kMaxVorkommen] und innerhalb des Zeitbudgets. Tägliche und wöchentliche Regeln ohne COUNT starten nahe am Fenster (um ganze Perioden
/// verschoben, Wochentag und Wochenraster bleiben gleich), statt jede Instanz seit dem Beginn zu rechnen. Ergebnisse werden zwischengespeichert.
List<DateTime> _instanzen(String text, RecurrenceRule regel, DateTime start, DateTime nach, DateTime vor) {
  if (vor.isBefore(start)) return const []; // Serie beginnt erst nach dem Fenster (das Paket verlangt before >= start)
  final key = '$text|$start|$nach|$vor';
  final bekannt = _cache[key];
  if (bekannt != null) return bekannt;
  var s = start;
  final tageProPeriode = regel.frequency == Frequency.daily ? 1 : (regel.frequency == Frequency.weekly ? 7 : 0);
  if (tageProPeriode > 0 && regel.count == null && nach.isAfter(start)) {
    final periode = tageProPeriode * regel.actualInterval;
    final k = nach.difference(start).inDays ~/ periode - 1;
    if (k > 0) s = start.add(Duration(days: k * periode));
  }
  final out = <DateTime>[];
  final uhr = Stopwatch()..start();
  for (final m in regel.getInstances(start: s, after: nach.isAfter(s) ? nach : s, includeAfter: true, before: vor)) {
    out.add(m);
    if (out.length >= kMaxVorkommen || uhr.elapsedMilliseconds > _kBudgetMs) break;
  }
  if (_cache.length >= _kCacheMax) _cache.remove(_cache.keys.first);
  _cache[key] = out;
  return out;
}

/// Alle Vorkommen der Termine im Fenster [vonWand, bisWand) (Wanduhr der Familienzone), sortiert.
List<Vorkommen> vorkommenImFenster({
  required Iterable<Termin> termine,
  required Map<String, List<TerminAusnahme>> ausnahmen,
  required DateTime vonWand,
  required DateTime bisWand,
  DateTime? jetzt,
}) {
  final heute = wandUhr(jetzt ?? DateTime.now().toUtc(), familienOrt);
  final horizont = DateTime.utc(heute.year + kHorizontJahre, heute.month, heute.day);
  final ende = bisWand.isAfter(horizont) ? horizont : bisWand;
  final out = <Vorkommen>[];
  if (!ende.isAfter(vonWand)) return out;
  for (final t in termine) {
    out.addAll(_vorkommenVon(t, ausnahmen[t.id] ?? const [], vonWand, ende));
  }
  out.sort();
  return out;
}

List<Vorkommen> _vorkommenVon(Termin t, List<TerminAusnahme> ausnahmen, DateTime vonWand, DateTime bisWand) {
  final berlin = familienOrt;
  final nachSchluessel = {for (final a in ausnahmen) a.originalStart: a};
  final out = <Vorkommen>[];

  /// Nimmt ein Vorkommen auf: [dauer] ist die echte Dauer (ganztägig: ganze Tage), [startWand]/[startUtc] der ursprüngliche Beginn.
  void aufnehmen({required String schluessel, required DateTime startWand, required DateTime startUtc, required Duration dauer, required bool serie}) {
    final a = nachSchluessel[schluessel];
    if (a != null && a.abgesagt) return;
    var su = startUtc;
    var s = startWand;
    final originalEnde = t.ganztaegig ? startWand.add(dauer) : wandUhr(startUtc.add(dauer), berlin);
    var e = originalEnde;
    var titel = t.titel;
    var ort = t.ort;
    var geaendert = false;
    if (a != null) {
      if (a.titel != null && a.titel!.isNotEmpty) {
        titel = a.titel!;
        geaendert = true;
      }
      if (a.ort != null) {
        ort = a.ort!;
        geaendert = true;
      }
      if (t.ganztaegig) {
        final ns = tagAusText(a.start);
        final ne = tagAusText(a.ende);
        if (ns != null) {
          s = ns;
          e = ne ?? ns.add(dauer);
          su = instantAusWand(s, berlin);
          geaendert = true;
        } else if (ne != null) {
          e = ne;
          geaendert = true;
        }
      } else {
        final ns = a.start == null ? null : DateTime.tryParse(a.start!);
        final ne = a.ende == null ? null : DateTime.tryParse(a.ende!);
        if (ns != null) {
          su = ns.toUtc();
          s = wandUhr(su, berlin);
          e = wandUhr(ne?.toUtc() ?? su.add(dauer), berlin);
          geaendert = true;
        } else if (ne != null) {
          e = wandUhr(ne.toUtc(), berlin);
          geaendert = true;
        }
      }
    }
    // Überschneidung mit dem Fenster (ein Zeitpunkt ohne Dauer zählt, wenn er im Fenster liegt)
    final ueberlappt = e.isAfter(s) ? s.isBefore(bisWand) && e.isAfter(vonWand) : !s.isBefore(vonWand) && s.isBefore(bisWand);
    if (!ueberlappt) return;
    out.add(
      Vorkommen(
        termin: t,
        schluessel: schluessel,
        ganztaegig: t.ganztaegig,
        startWand: s,
        endeWand: e,
        startUtc: su,
        titel: titel,
        ort: ort,
        geaendert: geaendert,
        serie: serie,
        originalStartWand: startWand,
        originalEndeWand: originalEnde,
        originalStartUtc: startUtc,
      ),
    );
  }

  if (t.ganztaegig) {
    final start = tagAusText(t.startDate);
    final end = tagAusText(t.endDate);
    if (start == null || end == null || !end.isAfter(start)) return out;
    final tage = end.difference(start);
    final regel = t.rrule == null ? null : regelFuer(t.rrule!, ganztaegig: true, ort: berlin);
    if (regel == null) {
      aufnehmen(schluessel: tagText(start), startWand: start, startUtc: instantAusWand(start, berlin), dauer: tage, serie: false);
      return out;
    }
    final von = vonWand.subtract(tage + const Duration(days: 1));
    for (final m in _instanzen(t.rrule!, regel, start, von, bisWand)) {
      aufnehmen(schluessel: tagText(m), startWand: m, startUtc: instantAusWand(m, berlin), dauer: tage, serie: true);
    }
    return out;
  }

  final su = t.startUtc?.toUtc();
  final eu = t.endUtc?.toUtc();
  if (su == null || eu == null) return out;
  final ort = ortFuer(t.tzid);
  final dauer = eu.difference(su);
  final regel = t.rrule == null ? null : regelFuer(t.rrule!, ganztaegig: false, ort: ort);
  if (regel == null) {
    aufnehmen(schluessel: zeitSchluessel(su), startWand: wandUhr(su, berlin), startUtc: su, dauer: dauer, serie: false);
    return out;
  }
  // Fenster in die Wanduhr des Termins übersetzen (mit Spielraum für Zeitzonen-Unterschiede und die Dauer)
  final von = vonWand.subtract(dauer + const Duration(days: 2));
  final bis = bisWand.add(const Duration(days: 2));
  for (final m in _instanzen('${t.rrule}|${t.tzid}', regel, wandUhr(su, ort), von, bis)) {
    final inst = instantAusWand(m, ort);
    aufnehmen(schluessel: zeitSchluessel(inst), startWand: wandUhr(inst, berlin), startUtc: inst, dauer: dauer, serie: true);
  }
  return out;
}

/// Vorkommen, gruppiert nach Kalendertag (Mehrtägige erscheinen an jedem Tag), jeder Tag sortiert.
Map<DateTime, List<Vorkommen>> nachTagen(Iterable<Vorkommen> vorkommen, DateTime vonTag, DateTime bisTagInklusive) {
  final out = <DateTime, List<Vorkommen>>{};
  for (final v in vorkommen) {
    var tag = v.ersterTag.isBefore(vonTag) ? vonTag : v.ersterTag;
    final letzter = v.letzterTag.isAfter(bisTagInklusive) ? bisTagInklusive : v.letzterTag;
    while (!tag.isAfter(letzter)) {
      out.putIfAbsent(tag, () => []).add(v);
      tag = DateTime.utc(tag.year, tag.month, tag.day + 1);
    }
  }
  for (final l in out.values) {
    l.sort();
  }
  return out;
}
