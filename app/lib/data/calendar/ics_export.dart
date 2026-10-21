// ICS-Export (iCalendar, RFC 5545): schreibt die lokalen Termine als .ics-Datei, das Gegenstück zu ics_parser.dart. Alles läuft auf dem Gerät
// aus der lokalen Datenbank; nichts geht an den Server. Exportiert werden nur Termine (VEVENT, VALARM aus `erinnerungMin`, VTIMEZONE);
// nie Chat, Standort, Schlüssel oder Teilnehmer. Ohne Geocoding: der Ort bleibt Text.
//
// Zeitmodell wie in der App: Zeittermine als Wanduhrzeit mit TZID (Serien rechnen so in der Zeitzone des Termins weiter, auch über die Zeitumstellung),
// ganztägige Termine als VALUE=DATE mit exklusivem Ende. Abgesagte Vorkommen sind EXDATE, geänderte ein eigenes VEVENT mit RECURRENCE-ID.
import 'dart:convert';
import 'dart:typed_data';

import 'package:timezone/timezone.dart' as tz;

import '../app_database.dart';
import 'expansion.dart';
import 'termin_repository.dart' show ZeitzonenFehlen;
import 'zeitzonen.dart';

const kIcsProdId = '-//lx-labs.dev//lx-fampad//DE';

/// Domain für die UID eines Termins ohne `icalUid` (stabil aus der Termin-ID).
const kIcsUidDomain = 'familie.lx-labs.dev';

/// Welche Termine in die Datei kommen.
enum IcsZeitraum { alles, abHeute, jahr }

/// Dateiname `lx-familyhub-kalender-JJJJ-MM-TT.ics` (Datum in der Familienzeitzone).
String icsExportDateiname(DateTime jetzt) => 'lx-familyhub-kalender-${tagText(wandUhr(jetzt.toUtc(), familienOrt))}.ics';

/// Die Termine, die zum Zeitraum gehören: mindestens ein (nicht abgesagtes) Vorkommen liegt im Zeitraum. Ein passender Termin kommt immer ganz
/// in die Datei (eine Serie nie gekürzt).
List<Termin> termineFuerExport({
  required Iterable<Termin> termine,
  required Map<String, List<TerminAusnahme>> ausnahmen,
  required IcsZeitraum zeitraum,
  int? jahr,
  DateTime? jetzt,
}) {
  final alle = termine.toList();
  if (zeitraum == IcsZeitraum.alles) return alle;
  final heute = wandUhr((jetzt ?? DateTime.now()).toUtc(), familienOrt);
  final DateTime von;
  final DateTime bis;
  if (zeitraum == IcsZeitraum.abHeute) {
    von = DateTime.utc(heute.year, heute.month, heute.day);
    bis = DateTime.utc(heute.year + kHorizontJahre + 1, 1, 1);
  } else {
    final j = jahr ?? heute.year;
    von = DateTime.utc(j, 1, 1);
    bis = DateTime.utc(j + 1, 1, 1);
  }
  final ids = {for (final v in vorkommenImFenster(termine: alle, ausnahmen: ausnahmen, vonWand: von, bisWand: bis, jetzt: jetzt)) v.termin.id};
  return [
    for (final t in alle)
      if (ids.contains(t.id)) t,
  ];
}

/// Maskiert einen TEXT-Wert (RFC 5545, 3.3.11): `\`, `;`, `,` und Zeilenumbrüche; Steuerzeichen entfallen.
String icsMaskieren(String s) {
  final b = StringBuffer();
  final n = s.length;
  for (var i = 0; i < n; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x0D) {
      if (i + 1 < n && s.codeUnitAt(i + 1) == 0x0A) i++;
      b.write(r'\n');
    } else if (c == 0x0A) {
      b.write(r'\n');
    } else if (c == 0x5C) {
      b.write(r'\\');
    } else if (c == 0x3B) {
      b.write(r'\;');
    } else if (c == 0x2C) {
      b.write(r'\,');
    } else if (c == 0x09 || c >= 0x20 && c != 0x7F) {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

/// Faltet eine Inhaltszeile auf höchstens 75 Oktette je Zeile (RFC 5545, 3.1): Fortsetzungszeilen beginnen mit einem Leerzeichen; ein
/// UTF-8-Zeichen wird nie geteilt. Zeilen enden mit CRLF.
String icsFalten(String zeile) {
  final out = StringBuffer();
  var frei = 75; // Oktette in der aktuellen Zeile
  for (final r in zeile.runes) {
    final len = r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
    if (len > frei) {
      out.write('\r\n ');
      frei = 74;
    }
    out.writeCharCode(r);
    frei -= len;
  }
  out.write('\r\n');
  return out.toString();
}

String _z(int n, [int w = 2]) => n.toString().padLeft(w, '0');
String _tag(DateTime d) => '${_z(d.year, 4)}${_z(d.month)}${_z(d.day)}';
String _wand(DateTime d) => '${_tag(d)}T${_z(d.hour)}${_z(d.minute)}${_z(d.second)}';
String _utc(DateTime d) => '${_wand(d.toUtc())}Z';
String _versatz(Duration o) {
  final min = o.inMinutes;
  final a = min.abs();
  return '${min < 0 ? '-' : '+'}${_z(a ~/ 60)}${_z(a % 60)}';
}

DateTime? _tagLesen(String? s) => s == null ? null : DateTime.tryParse('${s}T00:00:00Z');

/// Wanduhrzeit (als UTC getarnt) des Zeitpunkts [utc] in der Zone [ort].
DateTime _wandIn(DateTime utc, tz.Location ort) =>
    DateTime.fromMillisecondsSinceEpoch(utc.millisecondsSinceEpoch + ort.timeZone(utc.millisecondsSinceEpoch).offset.inMilliseconds, isUtc: true);

class _Schreiber {
  final _b = StringBuffer();
  void zeile(String s) => _b.write(icsFalten(s));
  void text(String name, String wert) => zeile('$name:${icsMaskieren(wert)}');
  @override
  String toString() => _b.toString();
}

/// Das VTIMEZONE für Europe/Berlin mit den EU-Sommerzeitregeln (letzter Sonntag im März 02:00 und im Oktober 03:00).
void _berlin(_Schreiber s) {
  s.zeile('BEGIN:VTIMEZONE');
  s.zeile('TZID:$kFamilienZone');
  s.zeile('BEGIN:DAYLIGHT');
  s.zeile('TZOFFSETFROM:+0100');
  s.zeile('TZOFFSETTO:+0200');
  s.zeile('TZNAME:CEST');
  s.zeile('DTSTART:19700329T020000');
  s.zeile('RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU');
  s.zeile('END:DAYLIGHT');
  s.zeile('BEGIN:STANDARD');
  s.zeile('TZOFFSETFROM:+0200');
  s.zeile('TZOFFSETTO:+0100');
  s.zeile('TZNAME:CET');
  s.zeile('DTSTART:19701025T030000');
  s.zeile('RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU');
  s.zeile('END:STANDARD');
  s.zeile('END:VTIMEZONE');
}

/// VTIMEZONE einer anderen Zone aus ihren Übergängen (ab [vonJahr] bis zum Ende der Daten, höchstens 400 Übergänge): zuerst die Regel, die
/// am Anfang gilt, dann jeder Übergang einzeln.
void _andere(_Schreiber s, tz.Location ort, int vonJahr) {
  final start = DateTime.utc(vonJahr, 1, 1).millisecondsSinceEpoch;
  final at = ort.transitionAt;
  var i = 0;
  while (i < at.length && at[i] <= start) {
    i++;
  }
  final erste = ort.timeZone(start);
  s.zeile('BEGIN:VTIMEZONE');
  s.zeile('TZID:${ort.name}');
  void beob(tz.TimeZone z, Duration von, int ms) {
    final art = z.isDst ? 'DAYLIGHT' : 'STANDARD';
    s.zeile('BEGIN:$art');
    s.zeile('TZOFFSETFROM:${_versatz(von)}');
    s.zeile('TZOFFSETTO:${_versatz(z.offset)}');
    s.zeile('TZNAME:${z.abbreviation}');
    s.zeile('DTSTART:${_wand(DateTime.fromMillisecondsSinceEpoch(ms + von.inMilliseconds, isUtc: true))}');
    s.zeile('END:$art');
  }

  beob(erste, erste.offset, start);
  var vorher = erste;
  for (var n = 0; i < at.length && n < 400; i++, n++) {
    final z = ort.zones[ort.transitionZone[i]];
    beob(z, vorher.offset, at[i]);
    vorher = z;
  }
  s.zeile('END:VTIMEZONE');
}

/// Schreibt die Termine als iCalendar-Text. [jetzt] ist der Zeitstempel (DTSTAMP).
String icsErstellen({required Iterable<Termin> termine, required Map<String, List<TerminAusnahme>> ausnahmen, required DateTime jetzt}) {
  if (!zeitzonenBereit()) throw const ZeitzonenFehlen();
  final liste = termine.toList();
  final stempel = _utc(jetzt);

  // Zonen, die vorkommen (Zeittermine; die Familienzone immer, wenn es Zeittermine gibt)
  final zonen = <String, tz.Location>{};
  final ersteJahre = <String, int>{};
  for (final t in liste) {
    if (t.ganztaegig || t.startUtc == null) continue;
    final ort = ortFuer(t.tzid);
    zonen.putIfAbsent(ort.name, () => ort);
    final j = t.startUtc!.toUtc().year;
    final alt = ersteJahre[ort.name];
    if (alt == null || j < alt) ersteJahre[ort.name] = j;
  }

  final s = _Schreiber();
  s.zeile('BEGIN:VCALENDAR');
  s.zeile('VERSION:2.0');
  s.zeile('PRODID:$kIcsProdId');
  s.zeile('CALSCALE:GREGORIAN');
  s.zeile('METHOD:PUBLISH');
  s.text('X-WR-CALNAME', 'Familienkalender');
  for (final e in zonen.entries) {
    if (e.key == kFamilienZone) {
      _berlin(s);
    } else {
      _andere(s, e.value, ersteJahre[e.key]! - 1);
    }
  }
  for (final t in liste) {
    _termin(s, t, ausnahmen[t.id] ?? const [], stempel);
  }
  s.zeile('END:VCALENDAR');
  return s.toString();
}

/// Der Export als UTF-8-Bytes (ohne BOM).
Uint8List icsBytes(String text) => Uint8List.fromList(utf8.encode(text));

String _uid(Termin t) {
  final u = t.icalUid;
  return (u != null && u.trim().isNotEmpty) ? u : '${t.id}@$kIcsUidDomain';
}

void _alarm(_Schreiber s, Termin t) {
  final m = t.erinnerungMin;
  if (m == null || m < 0) return;
  s.zeile('BEGIN:VALARM');
  s.zeile('ACTION:DISPLAY');
  s.text('DESCRIPTION', t.titel.isEmpty ? 'Erinnerung' : t.titel);
  s.zeile('TRIGGER:${m == 0 ? 'PT0S' : '-PT${m}M'}');
  s.zeile('END:VALARM');
}

void _termin(_Schreiber s, Termin t, List<TerminAusnahme> ausnahmen, String stempel) {
  final ganz = t.ganztaegig;
  final tagStart = _tagLesen(t.startDate);
  if (ganz ? tagStart == null : t.startUtc == null) {
    return; // ohne Beginn nicht darstellbar
  }
  final ort = ortFuer(t.tzid);
  final uid = _uid(t);
  final serie = t.rrule != null && t.rrule!.trim().isNotEmpty;

  // Dauer des Termins (für geänderte Vorkommen ohne eigenes Ende)
  final Duration dauer;
  if (ganz) {
    final e = _tagLesen(t.endDate);
    dauer = (e != null && e.isAfter(tagStart!)) ? e.difference(tagStart) : const Duration(days: 1);
  } else {
    dauer = t.endUtc != null && t.endUtc!.isAfter(t.startUtc!) ? t.endUtc!.difference(t.startUtc!) : Duration.zero;
  }

  /// DTSTART/DTEND/RECURRENCE-ID/EXDATE-Zeile für den Wert [w] (Tag bei ganztägigen, Zeitpunkt sonst).
  String zeit(String name, DateTime w) => ganz ? '$name;VALUE=DATE:${_tag(w)}' : '$name;TZID=${ort.name}:${_wand(_wandIn(w, ort))}';

  void kopf() {
    s.zeile('BEGIN:VEVENT');
    s.zeile('UID:${uid.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')}');
    s.zeile('DTSTAMP:$stempel');
  }

  kopf();
  if (ganz) {
    s.zeile(zeit('DTSTART', tagStart!));
    s.zeile(zeit('DTEND', tagStart.add(dauer)));
  } else {
    s.zeile(zeit('DTSTART', t.startUtc!));
    if (dauer > Duration.zero) s.zeile(zeit('DTEND', t.endUtc!));
  }
  s.text('SUMMARY', t.titel);
  if (t.ort.isNotEmpty) s.text('LOCATION', t.ort);
  if (t.beschreibung.isNotEmpty) s.text('DESCRIPTION', t.beschreibung);
  if (serie) s.zeile('RRULE:${t.rrule!.trim()}');

  final sortiert = [...ausnahmen]..sort((a, b) => a.originalStart.compareTo(b.originalStart));
  DateTime? schluessel(TerminAusnahme a) => ganz ? _tagLesen(a.originalStart) : DateTime.tryParse(a.originalStart)?.toUtc();
  if (serie) {
    for (final a in sortiert) {
      final k = schluessel(a);
      if (a.abgesagt && k != null) s.zeile(zeit('EXDATE', k));
    }
  }
  _alarm(s, t);
  s.zeile('END:VEVENT');

  if (!serie) return;
  for (final a in sortiert) {
    final k = schluessel(a);
    if (a.abgesagt || k == null) continue;
    if (a.titel == null && a.ort == null && a.start == null && a.ende == null) continue;
    DateTime? neu(String? w) => ganz ? _tagLesen(w) : (w == null ? null : DateTime.tryParse(w)?.toUtc());
    final start = neu(a.start) ?? k;
    var ende = neu(a.ende) ?? start.add(dauer);
    if (ende.isBefore(start)) ende = start;
    kopf();
    s.zeile(zeit('RECURRENCE-ID', k));
    s.zeile(zeit('DTSTART', start));
    if (ganz || ende.isAfter(start)) s.zeile(zeit('DTEND', ende));
    s.text('SUMMARY', a.titel ?? t.titel);
    final o = a.ort ?? t.ort;
    if (o.isNotEmpty) s.text('LOCATION', o);
    if (t.beschreibung.isNotEmpty) s.text('DESCRIPTION', t.beschreibung);
    _alarm(s, t);
    s.zeile('END:VEVENT');
  }
}
