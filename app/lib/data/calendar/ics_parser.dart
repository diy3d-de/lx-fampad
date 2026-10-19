// ICS-Import (iCalendar, RFC 5545): liest eine .ics-Datei in Termine für die App. Bewusst selbst gebaut und klein gehalten (keine ICS-Bibliothek):
// verstanden werden nur VEVENT (samt VALARM) und VTIMEZONE (nur zum Erkennen der Namen); alles andere (Aufgaben, Journale, Teilnehmer,
// Organisator, Anhänge, Links) wird ignoriert, es wird nie etwas aus dem Netz abgerufen.
//
// Sicherheit: Größe und Anzahl sind gedeckelt (5 MB, 5000 Termine), Zeilen werden von Hand zerlegt (kein verschachtelter regulärer Ausdruck,
// kein ReDoS), die Wiederholungsregel prüft ein Hand-Tokenizer mit denselben Grenzen wie der Server (server/src/sync/rrule.ts). Ein kaputter
// Termin bricht den Import nicht ab: Fehler werden je Termin abgefangen und im Bericht ausgewiesen.
//
// Zeitmodell wie im Rest der App: Zeittermine = Zeitpunkt (UTC) + IANA-Zeitzone, Wiederholungen in der Wanduhrzeit dieser Zeitzone;
// ganztägige Termine = Kalendertage, Ende exklusiv (wie in ICS).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:timezone/timezone.dart' as tz;

import 'expansion.dart' show tagText, zeitSchluessel;
import 'ics_zonen.dart';
import 'zeitzonen.dart';

/// Obergrenzen (Schutz vor überlangen oder bösartigen Dateien).
const kIcsMaxBytes = 5 * 1024 * 1024;
const kIcsMaxTermine = 5000;
const kIcsMaxZeilenLaenge = 100000;
const kIcsMaxAusnahmen = 500; // wie der Server je Termin

/// Erinnerungen, die die App anbietet (Minuten vor Beginn); der Server erlaubt 0 bis 40320.
const kIcsErinnerungen = <int>[0, 5, 15, 30, 60, 1440, 10080];

const _kMinJahr = 2000; // wie der Server (Zeitpunkte 2000 bis 2200)
const _kMaxJahr = 2199;

/// Die Datei ist nicht zu lesen (Größe, Format, fehlende Zeitzonen-Daten).
class IcsFehler implements Exception {
  final String meldung;
  const IcsFehler(this.meldung);

  @override
  String toString() => meldung;
}

/// Hinweis zum Import: [titel] null = allgemein; [uebersprungen] = der Termin wird nicht übernommen.
class IcsHinweis {
  final String? titel;
  final String text;
  final bool uebersprungen;
  const IcsHinweis(this.titel, this.text, {this.uebersprungen = false});

  @override
  String toString() => '${titel ?? '-'}: $text';
}

/// Eine Abweichung von einem Vorkommen einer Serie (abgesagt oder geändert); [schluessel] ist der ursprüngliche Beginn
/// (UTC `YYYY-MM-DDTHH:MM:SSZ` bzw. Tag `YYYY-MM-DD`, wie `originalStart` am Server).
class IcsAusnahme {
  final String schluessel;
  final bool abgesagt;
  final String? titel;
  final String? ort;
  final String? start;
  final String? ende;
  const IcsAusnahme({required this.schluessel, this.abgesagt = false, this.titel, this.ort, this.start, this.ende});
}

/// Ein Termin aus der Datei, bereits auf die Felder und Grenzen der App gebracht.
class IcsTermin {
  final String uid;
  final String titel;
  final String ort;
  final String beschreibung;
  final bool ganztaegig;
  final DateTime? startUtc;
  final DateTime? endUtc;
  final String? tzid;
  final String? startDate;
  final String? endDate;
  final String? rrule;
  final int? erinnerungMin;
  final List<IcsAusnahme> ausnahmen;
  const IcsTermin({
    required this.uid,
    required this.titel,
    this.ort = '',
    this.beschreibung = '',
    required this.ganztaegig,
    this.startUtc,
    this.endUtc,
    this.tzid,
    this.startDate,
    this.endDate,
    this.rrule,
    this.erinnerungMin,
    this.ausnahmen = const [],
  });

  bool get serie => rrule != null;
}

class IcsErgebnis {
  final List<IcsTermin> termine;
  final List<IcsHinweis> hinweise;

  /// Anzahl der gelesenen VEVENT-Blöcke.
  final int gelesen;

  /// Es gab mehr als [kIcsMaxTermine] Termine; der Rest wurde nicht gelesen.
  final bool abgeschnitten;
  const IcsErgebnis({required this.termine, required this.hinweise, required this.gelesen, required this.abgeschnitten});
}

// ------------------------------------------------------------------------------------------------ Zeilen

class _Zeile {
  final String name;
  final Map<String, String> params;
  final String wert;
  const _Zeile(this.name, this.params, this.wert);
}

/// Zerlegt eine entfaltete Zeile `NAME;PARAM=WERT;PARAM="WERT;MIT:ZEICHEN":Wert` von Hand (Anführungszeichen schützen `;` `:` `,`).
_Zeile? _zeileLesen(String s) {
  final n = s.length;
  var i = 0;
  while (i < n && s.codeUnitAt(i) != 0x3B && s.codeUnitAt(i) != 0x3A) {
    i++;
  }
  if (i == 0 || i >= n) return null;
  var name = s.substring(0, i).trim().toUpperCase();
  final punkt = name.lastIndexOf('.'); // Gruppenpräfix "item1.X-..."
  if (punkt >= 0) name = name.substring(punkt + 1);
  final params = <String, String>{};
  while (i < n && s.codeUnitAt(i) == 0x3B) {
    i++;
    final von = i;
    while (i < n && s.codeUnitAt(i) != 0x3D && s.codeUnitAt(i) != 0x3B && s.codeUnitAt(i) != 0x3A) {
      i++;
    }
    final pname = s.substring(von, i).trim().toUpperCase();
    final wert = StringBuffer();
    if (i < n && s.codeUnitAt(i) == 0x3D) {
      i++;
      var inAnf = false;
      while (i < n) {
        final c = s.codeUnitAt(i);
        if (c == 0x22) {
          inAnf = !inAnf;
          i++;
          continue;
        }
        if (!inAnf && (c == 0x3B || c == 0x3A)) break;
        wert.writeCharCode(c);
        i++;
      }
    }
    if (pname.isNotEmpty && !params.containsKey(pname)) params[pname] = wert.toString();
  }
  if (i >= n || s.codeUnitAt(i) != 0x3A) return null;
  return _Zeile(name, params, s.substring(i + 1));
}

/// Zeilen entfalten (Fortsetzungszeilen beginnen mit Leerzeichen oder Tab); LF, CRLF und CR als Zeilenende.
List<String> _entfalten(String text) {
  final ergebnis = <String>[];
  StringBuffer? aktuell;
  var zu = false; // aktuelle Zeile ist schon zu lang: Rest verwerfen
  void abschliessen() {
    final a = aktuell;
    if (a != null && a.isNotEmpty) ergebnis.add(a.toString());
    aktuell = null;
    zu = false;
  }

  for (final roh in const LineSplitter().convert(text)) {
    if (roh.isEmpty) continue;
    final c = roh.codeUnitAt(0);
    if ((c == 0x20 || c == 0x09) && aktuell != null) {
      if (!zu) {
        aktuell!.write(roh.substring(1));
        if (aktuell!.length > kIcsMaxZeilenLaenge) zu = true;
      }
    } else {
      abschliessen();
      aktuell = StringBuffer(roh.length > kIcsMaxZeilenLaenge ? roh.substring(0, kIcsMaxZeilenLaenge) : roh);
      zu = roh.length >= kIcsMaxZeilenLaenge;
    }
  }
  abschliessen();
  return ergebnis;
}

// ------------------------------------------------------------------------------------------------ Text

/// ICS-Text: `\n` `\N` -> Zeilenumbruch, `\,` `\;` `\\` -> das Zeichen.
String _entmaskieren(String s) {
  if (!s.contains('\\')) return s;
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final d = s[i + 1];
      i++;
      b.write((d == 'n' || d == 'N') ? '\n' : d);
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

/// Steuerzeichen, Richtungszeichen und einzelne Surrogate entfernen, auf [max] Zeichen (UTF-16) kürzen. [mehrzeilig]: Zeilenumbrüche bleiben,
/// sonst werden sie zu Leerzeichen.
String _bereinigen(String s, {required int max, bool mehrzeilig = false}) {
  final b = StringBuffer();
  var laenge = 0;
  var letztesLeer = true;
  for (final r in s.runes) {
    int? ausgabe = r;
    if (r == 0x0A || r == 0x2028 || r == 0x2029 || r == 0x85) {
      ausgabe = mehrzeilig ? 0x0A : 0x20;
    } else if (r == 0x09 || r == 0x0D) {
      ausgabe = 0x20;
    } else if (r < 0x20 || (r >= 0x7F && r <= 0x9F)) {
      ausgabe = null;
    } else if (r >= 0xD800 && r <= 0xDFFF) {
      ausgabe = null;
    } else if (r == 0xFFFE || r == 0xFFFF || (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) || r == 0x200E || r == 0x200F || r == 0xFEFF) {
      ausgabe = null;
    }
    if (ausgabe == null) continue;
    if (ausgabe == 0x20) {
      if (letztesLeer) continue; // Leerzeichen am Anfang und doppelte weglassen
      letztesLeer = true;
    } else {
      letztesLeer = ausgabe == 0x0A;
    }
    final n = ausgabe > 0xFFFF ? 2 : 1;
    if (laenge + n > max) break;
    b.writeCharCode(ausgabe);
    laenge += n;
  }
  return b.toString().trim();
}

// ------------------------------------------------------------------------------------------------ Zeit

class _DatumZeit {
  final bool datum;
  final DateTime wand; // Wanduhrzeit als DateTime.utc-Markierung (bei Z: echtes UTC)
  final bool utc;
  const _DatumZeit(this.datum, this.wand, this.utc);
}

bool _ziffern(String s, int von, int bis) {
  if (bis > s.length) return false;
  for (var i = von; i < bis; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  return true;
}

DateTime? _datum(String s) {
  if (s.length != 8 || !_ziffern(s, 0, 8)) return null;
  final y = int.parse(s.substring(0, 4)), m = int.parse(s.substring(4, 6)), d = int.parse(s.substring(6, 8));
  final t = DateTime.utc(y, m, d);
  return (t.year == y && t.month == m && t.day == d) ? t : null;
}

_DatumZeit? _datumZeit(String roh) {
  final s = roh.trim();
  if (s.length == 8) {
    final d = _datum(s);
    return d == null ? null : _DatumZeit(true, d, false);
  }
  if (s.length != 15 && s.length != 16) return null;
  if (s.codeUnitAt(8) != 0x54 /* T */ || !_ziffern(s, 9, 15)) return null;
  final utc = s.length == 16;
  if (utc && s.codeUnitAt(15) != 0x5A) return null;
  final d = _datum(s.substring(0, 8));
  if (d == null) return null;
  final h = int.parse(s.substring(9, 11)), mi = int.parse(s.substring(11, 13)), se = int.parse(s.substring(13, 15));
  if (h > 23 || mi > 59 || se > 60) return null;
  return _DatumZeit(false, DateTime.utc(d.year, d.month, d.day, h, mi, se > 59 ? 59 : se), utc);
}

/// ISO-8601-Dauer wie `PT15M`, `-P1D`, `P1W`, `P1DT2H`. Ohne reguläre Ausdrücke.
Duration? _dauer(String roh) {
  var s = roh.trim().toUpperCase();
  if (s.isEmpty || s.length > 40) return null;
  var neg = false;
  if (s.startsWith('-')) {
    neg = true;
    s = s.substring(1);
  } else if (s.startsWith('+')) {
    s = s.substring(1);
  }
  if (!s.startsWith('P') || s.length < 2) return null;
  var imZeitTeil = false;
  var zahl = '';
  var summe = 0; // Sekunden
  for (var i = 1; i < s.length; i++) {
    final c = s[i];
    if (c == 'T') {
      if (imZeitTeil || zahl.isNotEmpty) return null;
      imZeitTeil = true;
    } else if (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
      zahl += c;
      if (zahl.length > 9) return null;
    } else {
      if (zahl.isEmpty) return null;
      final n = int.parse(zahl);
      zahl = '';
      switch (c) {
        case 'W' when !imZeitTeil:
          summe += n * 604800;
        case 'D' when !imZeitTeil:
          summe += n * 86400;
        case 'H' when imZeitTeil:
          summe += n * 3600;
        case 'M' when imZeitTeil:
          summe += n * 60;
        case 'S' when imZeitTeil:
          summe += n;
        default:
          return null;
      }
    }
  }
  if (zahl.isNotEmpty) return null;
  return Duration(seconds: neg ? -summe : summe);
}

// ------------------------------------------------------------------------------------------------ Wiederholungsregel

enum _RegelArt { ok, einzeln, ueberspringen }

class _Regel {
  final _RegelArt art;
  final String? text;
  final String? hinweis;
  const _Regel(this.art, {this.text, this.hinweis});
}

const _kTage = {'MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'};
const _kMonatsTage = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

bool _zahlImBereich(String s, int min, int max, {required bool nullErlaubt}) {
  final neg = s.startsWith('-');
  final koerper = (neg || s.startsWith('+')) ? s.substring(1) : s;
  if (koerper.isEmpty || koerper.length > 4 || !_ziffern(koerper, 0, koerper.length)) return false;
  final n = (neg ? -1 : 1) * int.parse(koerper);
  if (n == 0 && !nullErlaubt) return false;
  return n >= min && n <= max;
}

bool _tagListe(String wert, {required bool mitZahl}) {
  final teile = wert.split(',');
  if (teile.length > 31) return false;
  for (final t in teile) {
    if (t.length < 2) return false;
    if (!_kTage.contains(t.substring(t.length - 2))) return false;
    final vor = t.substring(0, t.length - 2);
    if (vor.isEmpty) continue;
    if (!mitZahl || !_zahlImBereich(vor, -5, 5, nullErlaubt: false)) return false;
  }
  return true;
}

bool _zahlListe(String wert, int min, int max) {
  final teile = wert.split(',');
  return teile.length <= 31 && teile.every((t) => _zahlImBereich(t, min, max, nullErlaubt: false));
}

/// Spiegel von `isValidRrule` des Servers (Form der Regel); `false` = der Server würde sie ablehnen.
bool _regelServerGueltig(String text) {
  if (text.isEmpty || text.length > 300) return false;
  final teile = text.split(';');
  if (teile.length > 10) return false;
  final gesehen = <String>{};
  final werte = <String, String>{};
  for (final teil in teile) {
    final eq = teil.indexOf('=');
    if (eq <= 0) return false;
    final k = teil.substring(0, eq), v = teil.substring(eq + 1);
    if (gesehen.contains(k) || v.isEmpty) return false;
    gesehen.add(k);
    werte[k] = v;
  }
  final freq = werte['FREQ'];
  if (freq == null || !const {'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'}.contains(freq)) return false;
  final mitZahl = freq == 'MONTHLY' || freq == 'YEARLY';
  for (final e in werte.entries) {
    final v = e.value;
    switch (e.key) {
      case 'FREQ':
        break;
      case 'INTERVAL':
        if (!_ziffern(v, 0, v.length) || v.length > 3 || int.parse(v) < 1) return false;
      case 'COUNT':
        if (!_ziffern(v, 0, v.length) || v.length > 4 || int.parse(v) < 1 || int.parse(v) > 1000) return false;
      case 'UNTIL':
        if (!_untilGueltig(v)) return false;
      case 'BYDAY':
        if (!_tagListe(v, mitZahl: mitZahl)) return false;
      case 'BYMONTHDAY':
        if (!_zahlListe(v, -31, 31)) return false;
      case 'BYMONTH':
        if (!_zahlListe(v, 1, 12)) return false;
      case 'BYSETPOS':
        if (!_zahlListe(v, -5, 5)) return false;
      case 'WKST':
        if (!_kTage.contains(v)) return false;
      default:
        return false;
    }
  }
  if (werte.containsKey('COUNT') && werte.containsKey('UNTIL')) return false;
  if (!mitZahl && (werte.containsKey('BYSETPOS') || werte.containsKey('BYMONTHDAY'))) return false;
  final tage = werte['BYMONTHDAY']?.split(',');
  if (tage != null) {
    final monate = werte['BYMONTH']?.split(',').map(int.parse) ?? List.generate(12, (i) => i + 1);
    if (!monate.any((m) => tage.any((d) => int.parse(d).abs() <= _kMonatsTage[m - 1]))) return false;
  }
  return true;
}

bool _untilGueltig(String v) {
  final nurTag = v.length == 8;
  if (!(nurTag || (v.length == 16 && v[8] == 'T' && v[15] == 'Z'))) return false;
  final dz = _datumZeit(v);
  if (dz == null) return false;
  return dz.wand.year >= _kMinJahr && dz.wand.year <= _kMaxJahr;
}

String _untilText(DateTime utc) {
  String z(int n, int l) => n.toString().padLeft(l, '0');
  return '${z(utc.year, 4)}${z(utc.month, 2)}${z(utc.day, 2)}T${z(utc.hour, 2)}${z(utc.minute, 2)}${z(utc.second, 2)}Z';
}

/// Bringt eine Regel aus der Datei in die vom Server erlaubte Form. [ganztaegig]: UNTIL als Datum; sonst als UTC-Zeitpunkt
/// (ein Datum/eine Wanduhrzeit wird in [ort] gelesen).
_Regel _regelNormalisieren(String roh, {required bool ganztaegig, required tz.Location ort}) {
  var s = roh.trim();
  if (s.length > 2000) return const _Regel(_RegelArt.einzeln, hinweis: 'Wiederholungsregel zu lang, nur der erste Termin wird übernommen');
  if (s.toUpperCase().startsWith('RRULE:')) s = s.substring(6);
  final teile = s.split(';');
  if (teile.length > 30) return const _Regel(_RegelArt.einzeln, hinweis: 'Wiederholungsregel zu lang, nur der erste Termin wird übernommen');
  final ausgabe = <String>[];
  String? hinweis;
  for (final teil in teile) {
    if (teil.trim().isEmpty) continue;
    final eq = teil.indexOf('=');
    if (eq <= 0) return const _Regel(_RegelArt.einzeln, hinweis: 'Wiederholungsregel nicht lesbar, nur der erste Termin wird übernommen');
    final k = teil.substring(0, eq).trim().toUpperCase();
    final v = teil.substring(eq + 1).trim().toUpperCase();
    switch (k) {
      case 'FREQ':
        if (v == 'SECONDLY' || v == 'MINUTELY' || v == 'HOURLY') {
          return const _Regel(_RegelArt.ueberspringen, hinweis: 'Wiederholung im Stunden-, Minuten- oder Sekundentakt wird nicht unterstützt');
        }
        ausgabe.add('FREQ=$v');
      case 'INTERVAL':
        if (!_ziffern(v, 0, v.length) || v.isEmpty || v.length > 3 || int.parse(v) < 1) {
          return const _Regel(_RegelArt.einzeln, hinweis: 'Intervall der Wiederholung nicht unterstützt, nur der erste Termin wird übernommen');
        }
        ausgabe.add('INTERVAL=${int.parse(v)}');
      case 'COUNT':
        if (!_ziffern(v, 0, v.length) || v.isEmpty || v.length > 9 || int.parse(v) < 1) {
          return const _Regel(_RegelArt.einzeln, hinweis: 'Anzahl der Wiederholungen nicht lesbar, nur der erste Termin wird übernommen');
        }
        if (int.parse(v) > 1000) {
          hinweis = 'Serie auf 1000 Wiederholungen gekürzt';
          ausgabe.add('COUNT=1000');
        } else {
          ausgabe.add('COUNT=${int.parse(v)}');
        }
      case 'UNTIL':
        final dz = _datumZeit(v);
        if (dz == null) return const _Regel(_RegelArt.einzeln, hinweis: 'Ende der Serie nicht lesbar, nur der erste Termin wird übernommen');
        if (ganztaegig) {
          final t = DateTime.utc(dz.wand.year, dz.wand.month, dz.wand.day);
          if (t.year < _kMinJahr) return const _Regel(_RegelArt.ueberspringen, hinweis: 'Serie endet vor dem Jahr 2000');
          if (t.year > _kMaxJahr) {
            hinweis = 'Ende der Serie liegt nach 2199, die Serie läuft unbegrenzt';
          } else {
            ausgabe.add('UNTIL=${tagText(t).replaceAll('-', '')}');
          }
        } else {
          final DateTime utc;
          if (dz.utc) {
            utc = dz.wand;
          } else if (dz.datum) {
            utc = instantAusWand(DateTime.utc(dz.wand.year, dz.wand.month, dz.wand.day, 23, 59, 59), ort);
          } else {
            utc = instantAusWand(dz.wand, ort);
          }
          if (utc.year < _kMinJahr) return const _Regel(_RegelArt.ueberspringen, hinweis: 'Serie endet vor dem Jahr 2000');
          if (utc.year > _kMaxJahr) {
            hinweis = 'Ende der Serie liegt nach 2199, die Serie läuft unbegrenzt';
          } else {
            ausgabe.add('UNTIL=${_untilText(utc)}');
          }
        }
      case 'BYDAY' || 'BYMONTHDAY' || 'BYMONTH' || 'BYSETPOS' || 'WKST':
        ausgabe.add('$k=$v');
      default:
        return _Regel(_RegelArt.einzeln, hinweis: 'Wiederholungsregel enthält $k (nicht unterstützt), nur der erste Termin wird übernommen');
    }
  }
  final regel = ausgabe.join(';');
  if (!_regelServerGueltig(regel)) {
    return const _Regel(_RegelArt.einzeln, hinweis: 'Wiederholungsregel wird nicht unterstützt, nur der erste Termin wird übernommen');
  }
  return _Regel(_RegelArt.ok, text: regel, hinweis: hinweis);
}

// ------------------------------------------------------------------------------------------------ Termine

class _Ereignis {
  final Map<String, List<_Zeile>> eigenschaften = {};
  final List<_Zeile> alarme = []; // TRIGGER-Zeilen der VALARM-Blöcke
  _Zeile? erste(String name) {
    final l = eigenschaften[name];
    return (l == null || l.isEmpty) ? null : l.first;
  }

  List<_Zeile> alle(String name) => eigenschaften[name] ?? const [];
}

class _Zonen {
  final Map<String, int> unbekannt = {};
  final Set<String> ausDatei;
  _Zonen(this.ausDatei);

  /// IANA-Name der Zeitzone zu [tzid] (null/leer = schwebend: Familienzone); unbekannte Namen fallen auf die Familienzone zurück.
  String aufloesen(String? tzid) {
    if (tzid == null || tzid.trim().isEmpty) return kFamilienZone;
    final k = iana(tzid);
    if (k != null) return k;
    final name = _bereinigen(tzid, max: 60);
    unbekannt[name] = (unbekannt[name] ?? 0) + 1;
    return kFamilienZone;
  }
}

class _Anfang {
  final _DatumZeit wert;
  final String zone; // IANA, bei Z: 'UTC'
  const _Anfang(this.wert, this.zone);
  DateTime get instant => wert.datum ? wert.wand : (wert.utc ? wert.wand : instantAusWand(wert.wand, ortFuer(zone)));
}

_Anfang? _zeitLesen(_Zeile? z, _Zonen zonen) {
  if (z == null) return null;
  var dz = _datumZeit(z.wert);
  if (dz == null) return null;
  if (z.params['VALUE']?.toUpperCase() == 'DATE' && !dz.datum) dz = _DatumZeit(true, DateTime.utc(dz.wand.year, dz.wand.month, dz.wand.day), false);
  return _Anfang(dz, dz.utc ? 'UTC' : zonen.aufloesen(z.params['TZID']));
}

bool _jahrOk(int y) => y >= _kMinJahr && y <= _kMaxJahr;

int? _erinnerung(List<_Zeile> trigger) {
  for (final t in trigger) {
    if (t.params['VALUE']?.toUpperCase() == 'DATE-TIME') continue;
    if (t.params['RELATED']?.toUpperCase() == 'END') continue;
    final d = _dauer(t.wert);
    if (d == null) continue;
    final min = (-d.inSeconds / 60).round();
    if (min < 0 || min > 40320) continue; // nach Beginn oder zu weit vorher
    var bester = kIcsErinnerungen.first;
    for (final m in kIcsErinnerungen) {
      if ((m - min).abs() < (bester - min).abs()) bester = m;
    }
    return bester;
  }
  return null;
}

/// Eindeutige Kennung eines Termins ohne UID (aus Titel und Beginn, damit ein erneuter Import dieselbe findet).
String _ersatzUid(String basis) => 'fampad-ics-${sha1.convert(utf8.encode(basis)).toString().substring(0, 24)}';

class _Gruppe {
  final String uid;
  _Ereignis? master;
  int masterFolge = -1;
  final List<_Ereignis> ueberschreibungen = [];
  _Gruppe(this.uid);
}

/// Liest [bytes] als ICS-Datei. Wirft [IcsFehler] bei zu großer, leerer oder unbrauchbarer Datei; einzelne kaputte Termine
/// landen als Hinweis im Ergebnis.
IcsErgebnis icsLesen(Uint8List bytes) {
  if (bytes.length > kIcsMaxBytes) throw const IcsFehler('Die Datei ist größer als 5 MB.');
  if (!zeitzonenBereit()) throw const IcsFehler('Die Zeitzonen-Daten sind nicht geladen. Bitte versuche es gleich noch einmal.');
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  final zeilen = _entfalten(text);

  final hinweise = <IcsHinweis>[];
  final dateiZonen = <String>{};
  final ereignisse = <_Ereignis>[];
  final stapel = <String>[];
  var kalenderGesehen = false;
  var abgeschnitten = false;
  var gelesen = 0;
  _Ereignis? aktuell;
  var ignoriere = false;

  for (final roh in zeilen) {
    final z = _zeileLesen(roh);
    if (z == null) continue;
    if (z.name == 'BEGIN') {
      final art = z.wert.trim().toUpperCase();
      if (stapel.length >= 8) throw const IcsFehler('Die Datei ist zu tief verschachtelt.');
      stapel.add(art);
      if (art == 'VCALENDAR') kalenderGesehen = true;
      if (art == 'VEVENT' && stapel.length >= 2 && stapel[stapel.length - 2] == 'VCALENDAR') {
        gelesen++;
        if (gelesen > kIcsMaxTermine) {
          abgeschnitten = true;
          ignoriere = true;
          aktuell = null;
        } else {
          aktuell = _Ereignis();
          ereignisse.add(aktuell);
        }
      }
      continue;
    }
    if (z.name == 'END') {
      final art = z.wert.trim().toUpperCase();
      final i = stapel.lastIndexOf(art);
      if (i >= 0) {
        stapel.removeRange(i, stapel.length);
        if (art == 'VEVENT') {
          aktuell = null;
          ignoriere = false;
        }
      }
      continue;
    }
    if (stapel.isEmpty || ignoriere) continue;
    final oben = stapel.last;
    if (oben == 'VEVENT' && aktuell != null) {
      final liste = aktuell.eigenschaften.putIfAbsent(z.name, () => []);
      if (liste.length < 200) liste.add(z);
    } else if (oben == 'VALARM' && aktuell != null && stapel.length >= 2 && stapel[stapel.length - 2] == 'VEVENT') {
      if (z.name == 'TRIGGER' && aktuell.alarme.length < 20) aktuell.alarme.add(z);
    } else if (oben == 'VTIMEZONE' && z.name == 'TZID') {
      if (dateiZonen.length < 500) dateiZonen.add(z.wert.trim());
    }
  }
  if (!kalenderGesehen) throw const IcsFehler('Das ist keine ICS-Kalenderdatei (BEGIN:VCALENDAR fehlt).');
  if (abgeschnitten) hinweise.add(const IcsHinweis(null, 'Die Datei enthält mehr als $kIcsMaxTermine Termine; nur die ersten $kIcsMaxTermine wurden gelesen.'));

  final zonen = _Zonen(dateiZonen);
  // nach UID gruppieren (Reihenfolge der Datei bleibt erhalten)
  final gruppen = <String, _Gruppe>{};
  var folge = 0;
  for (final e in ereignisse) {
    folge++;
    try {
      final summe = _bereinigen(_entmaskieren(e.erste('SUMMARY')?.wert ?? ''), max: 200);
      var uid = _bereinigen(e.erste('UID')?.wert ?? '', max: 400);
      if (uid.isEmpty) {
        uid = _ersatzUid('$summe|${e.erste('DTSTART')?.wert}|${e.erste('RRULE')?.wert}|${e.erste('RECURRENCE-ID')?.wert}');
      } else if (uid.length > 255) {
        uid = _ersatzUid(uid);
      }
      final g = gruppen.putIfAbsent(uid, () => _Gruppe(uid));
      if (e.erste('RECURRENCE-ID') != null) {
        g.ueberschreibungen.add(e);
      } else {
        final seq = int.tryParse(e.erste('SEQUENCE')?.wert.trim() ?? '') ?? 0;
        final alt = g.master;
        if (alt == null) {
          g.master = e;
          g.masterFolge = seq;
        } else {
          if (seq >= g.masterFolge) {
            g.master = e;
            g.masterFolge = seq;
          }
          hinweise.add(IcsHinweis(summe.isEmpty ? null : summe, 'Dieselbe UID kommt mehrfach vor, es wird die neueste Fassung übernommen'));
        }
      }
    } catch (_) {
      hinweise.add(IcsHinweis(null, 'Ein Termin (Nr. $folge) war nicht lesbar und wurde übersprungen', uebersprungen: true));
    }
  }

  final termine = <IcsTermin>[];
  for (final g in gruppen.values) {
    try {
      if (g.master == null) {
        // nur abweichende Vorkommen ohne Serie (z. B. eingeladene Einzeltermine): jedes für sich übernehmen
        for (final o in g.ueberschreibungen) {
          final rid = o.erste('RECURRENCE-ID')!.wert.trim();
          final t = _einzelnerTermin(o, '${g.uid}#$rid'.length > 255 ? _ersatzUid('${g.uid}#$rid') : '${g.uid}#$rid', zonen, hinweise, ohneRegel: true);
          if (t != null) termine.add(t);
        }
        continue;
      }
      final t = _einzelnerTermin(g.master!, g.uid, zonen, hinweise, ueberschreibungen: g.ueberschreibungen);
      if (t != null) termine.add(t);
    } catch (_) {
      hinweise.add(IcsHinweis(null, 'Ein Termin war nicht lesbar und wurde übersprungen', uebersprungen: true));
    }
  }
  zonen.unbekannt.forEach((name, n) {
    final bekannt = zonen.ausDatei.contains(name);
    hinweise.add(IcsHinweis(null, 'Zeitzone „$name“ ist ${bekannt ? 'nicht umsetzbar' : 'unbekannt'}: $n Termin${n == 1 ? '' : 'e'} als Europe/Berlin gelesen'));
  });
  return IcsErgebnis(termine: termine, hinweise: hinweise, gelesen: gelesen > kIcsMaxTermine ? kIcsMaxTermine : gelesen, abgeschnitten: abgeschnitten);
}

IcsTermin? _einzelnerTermin(
  _Ereignis e,
  String uid,
  _Zonen zonen,
  List<IcsHinweis> hinweise, {
  List<_Ereignis> ueberschreibungen = const [],
  bool ohneRegel = false,
}) {
  final titel0 = _bereinigen(_entmaskieren(e.erste('SUMMARY')?.wert ?? ''), max: 200);
  final titel = titel0.isEmpty ? '(Ohne Titel)' : titel0;
  void weg(String grund) => hinweise.add(IcsHinweis(titel, grund, uebersprungen: true));
  void hin(String text) => hinweise.add(IcsHinweis(titel, text));

  if ((e.erste('STATUS')?.wert.trim().toUpperCase()) == 'CANCELLED') {
    weg('Der Termin ist in der Datei abgesagt');
    return null;
  }
  final start = _zeitLesen(e.erste('DTSTART'), zonen);
  if (start == null) {
    weg(e.erste('DTSTART') == null ? 'Beginn (DTSTART) fehlt' : 'Beginn nicht lesbar');
    return null;
  }
  final ganzt = start.wert.datum;
  var startWand = start.wert.wand;
  var zone = start.zone;

  // Wiederholungsregel
  String? regel;
  final rruleZeile = ohneRegel ? null : e.erste('RRULE');
  if (e.alle('RDATE').isNotEmpty && !ohneRegel) hin('RDATE (zusätzliche Einzeltermine einer Serie) wird nicht unterstützt');
  if (rruleZeile != null) {
    final ort = ortFuer(zone);
    final r = _regelNormalisieren(rruleZeile.wert, ganztaegig: ganzt, ort: ort);
    if (r.art == _RegelArt.ueberspringen) {
      weg(r.hinweis!);
      return null;
    }
    if (r.art == _RegelArt.einzeln) {
      hin(r.hinweis!);
    } else {
      regel = r.text;
      if (r.hinweis != null) hin(r.hinweis!);
    }
  }

  // Beginn vor 2000 (z. B. Geburtstage ab 1985): jährliche Serien werden auf das Jahr 2000 verschoben, alles andere übersprungen
  var verschoben = false;
  if (!_jahrOk(startWand.year)) {
    final jaehrlich = regel != null && regel.startsWith('FREQ=YEARLY') && !regel.contains('COUNT=') && !regel.contains('INTERVAL=') && !regel.contains('BYDAY=') && !regel.contains('BYSETPOS=');
    if (jaehrlich && startWand.year < _kMinJahr && startWand.year > 1000) {
      final n = _kMinJahr - startWand.year;
      startWand = DateTime.utc(startWand.year + n, startWand.month, startWand.day, startWand.hour, startWand.minute, startWand.second);
      verschoben = true;
    } else {
      weg('Beginn liegt außerhalb der Jahre $_kMinJahr bis $_kMaxJahr');
      return null;
    }
  }
  final istSerie = regel != null;
  if (verschoben) hin('Beginn vor dem Jahr 2000, die jährliche Serie beginnt im Jahr 2000');

  // Ende
  final dtend = _zeitLesen(e.erste('DTEND'), zonen);
  final dauer = e.erste('DURATION') == null ? null : _dauer(e.erste('DURATION')!.wert);
  final verschiebung = verschoben ? startWand.difference(start.wert.wand) : Duration.zero;

  String? startDate, endDate, tzid;
  DateTime? startUtc, endUtc;
  if (ganzt) {
    final s = DateTime.utc(startWand.year, startWand.month, startWand.day);
    var ende = DateTime.utc(s.year, s.month, s.day + 1);
    if (dtend != null) {
      final d = DateTime.utc(dtend.wert.wand.year, dtend.wert.wand.month, dtend.wert.wand.day).add(verschiebung);
      if (d.isAfter(s)) ende = d;
    } else if (dauer != null && dauer > Duration.zero) {
      final tage = (dauer.inHours / 24).ceil();
      ende = DateTime.utc(s.year, s.month, s.day + (tage < 1 ? 1 : tage));
    }
    if (!_jahrOk(ende.year) && ende.year != _kMaxJahr + 1) {
      weg('Ende liegt außerhalb der Jahre $_kMinJahr bis $_kMaxJahr');
      return null;
    }
    startDate = tagText(s);
    endDate = tagText(ende);
  } else {
    // Z-Zeiten: einmalige Termine in der Familienzone, Serien in UTC (die Regel rechnet in dieser Zone)
    zone = start.wert.utc ? (istSerie ? 'UTC' : kFamilienZone) : zone;
    final ort = ortFuer(zone);
    final s = start.wert.utc ? startWand : instantAusWand(startWand, ort);
    DateTime en = s;
    if (dtend != null && !dtend.wert.datum) {
      en = dtend.instant.add(verschiebung);
    } else if (dauer != null) {
      en = s.add(dauer);
    }
    if (en.isBefore(s)) {
      hin('Das Ende lag vor dem Beginn und wurde auf den Beginn gesetzt');
      en = s;
    }
    if (!_jahrOk(s.year) || !_jahrOk(en.year)) {
      weg('Beginn oder Ende liegt außerhalb der Jahre $_kMinJahr bis $_kMaxJahr');
      return null;
    }
    startUtc = s;
    endUtc = en;
    tzid = zone;
  }
  if (ganzt && !_jahrOk(int.parse(startDate!.substring(0, 4)))) {
    weg('Beginn liegt außerhalb der Jahre $_kMinJahr bis $_kMaxJahr');
    return null;
  }

  // Ausnahmen: EXDATE (abgesagt) und abweichende Vorkommen
  final ausnahmen = <String, IcsAusnahme>{};
  if (istSerie) {
    final ort = ortFuer(tzid ?? kFamilienZone);
    String? schluessel(_Anfang? a) {
      if (a == null) return null;
      if (ganzt) return tagText(DateTime.utc(a.wert.wand.year, a.wert.wand.month, a.wert.wand.day));
      if (a.wert.datum) {
        // nur ein Datum bei einem Zeittermin: gemeint ist das Vorkommen dieses Tages zur Beginnzeit
        final w = wandUhr(startUtc!, ort);
        return zeitSchluessel(instantAusWand(DateTime.utc(a.wert.wand.year, a.wert.wand.month, a.wert.wand.day, w.hour, w.minute, w.second), ort));
      }
      return zeitSchluessel(a.wert.utc ? a.wert.wand : instantAusWand(a.wert.wand, ortFuer(a.zone)));
    }

    for (final z in e.alle('EXDATE')) {
      for (final teil in z.wert.split(',')) {
        if (ausnahmen.length >= kIcsMaxAusnahmen) break;
        final a = _zeitLesen(_Zeile('EXDATE', z.params, teil.trim()), zonen);
        final k = schluessel(a);
        if (k != null) ausnahmen[k] = IcsAusnahme(schluessel: k, abgesagt: true);
      }
    }
    for (final o in ueberschreibungen) {
      try {
        final k = schluessel(_zeitLesen(o.erste('RECURRENCE-ID'), zonen));
        if (k == null) continue;
        if (o.erste('RECURRENCE-ID')!.params['RANGE']?.toUpperCase() == 'THISANDFUTURE') {
          hin('„Dieses und alle folgenden“ einer Serie wird nicht unterstützt, nur das genannte Vorkommen wurde geändert');
        }
        if (ausnahmen.length >= kIcsMaxAusnahmen && !ausnahmen.containsKey(k)) {
          hin('Mehr als $kIcsMaxAusnahmen Ausnahmen, der Rest wurde nicht übernommen');
          break;
        }
        if ((o.erste('STATUS')?.wert.trim().toUpperCase()) == 'CANCELLED') {
          ausnahmen[k] = IcsAusnahme(schluessel: k, abgesagt: true);
          continue;
        }
        final t = _bereinigen(_entmaskieren(o.erste('SUMMARY')?.wert ?? ''), max: 200);
        final ortText = o.erste('LOCATION') == null ? null : _bereinigen(_entmaskieren(o.erste('LOCATION')!.wert), max: 200);
        final os = _zeitLesen(o.erste('DTSTART'), zonen);
        String? neuStart, neuEnde;
        if (os != null && os.wert.datum == ganzt) {
          final oe = _zeitLesen(o.erste('DTEND'), zonen);
          final od = o.erste('DURATION') == null ? null : _dauer(o.erste('DURATION')!.wert);
          final String urspruenglichEnde;
          final String sk;
          final String ek;
          if (ganzt) {
            final tage = DateTime.parse('${endDate!}T00:00:00Z').difference(DateTime.parse('${startDate!}T00:00:00Z')).inDays;
            final k0 = DateTime.parse('${k}T00:00:00Z');
            urspruenglichEnde = tagText(DateTime.utc(k0.year, k0.month, k0.day + tage));
            final sd = os.wert.wand;
            var ed = DateTime.utc(sd.year, sd.month, sd.day + 1);
            if (oe != null && oe.wert.datum && oe.wert.wand.isAfter(sd)) ed = oe.wert.wand;
            sk = tagText(sd);
            ek = tagText(ed);
          } else {
            final si = os.instant;
            var ei = si.add(endUtc!.difference(startUtc!)); // ohne eigene Angabe bleibt die Dauer
            if (oe != null && !oe.wert.datum) {
              ei = oe.instant;
            } else if (od != null) {
              ei = si.add(od);
            }
            if (ei.isBefore(si)) ei = si;
            urspruenglichEnde = zeitSchluessel(DateTime.parse(k).add(endUtc.difference(startUtc)));
            sk = zeitSchluessel(si);
            ek = zeitSchluessel(ei);
          }
          // nur eine echte Verschiebung (anderer Beginn oder andere Dauer) wird als Ausnahme gespeichert
          if (sk != k || ek != urspruenglichEnde) {
            neuStart = sk;
            neuEnde = ek;
          }
        }
        final titelNeu = (t.isNotEmpty && t != titel0) ? t : null;
        final ortNeu = (ortText != null && ortText != _bereinigen(_entmaskieren(e.erste('LOCATION')?.wert ?? ''), max: 200)) ? ortText : null;
        if (titelNeu != null || ortNeu != null || neuStart != null) {
          ausnahmen[k] = IcsAusnahme(schluessel: k, titel: titelNeu, ort: ortNeu, start: neuStart, ende: neuEnde);
        }
      } catch (_) {
        hin('Ein geändertes Vorkommen der Serie war nicht lesbar und wurde ausgelassen');
      }
    }
  } else if (e.alle('EXDATE').isNotEmpty) {
    // EXDATE ohne Wiederholung: nichts zu tun
  }

  final beschr = _entmaskieren(e.erste('DESCRIPTION')?.wert ?? '');
  if (_bereinigen(beschr, max: 1000000, mehrzeilig: true).length > 4000) hin('Die Beschreibung wurde auf 4000 Zeichen gekürzt');
  final ortRoh = _entmaskieren(e.erste('LOCATION')?.wert ?? '');
  if (_bereinigen(ortRoh, max: 1000000).length > 200) hin('Der Ort wurde auf 200 Zeichen gekürzt');
  if (_bereinigen(_entmaskieren(e.erste('SUMMARY')?.wert ?? ''), max: 1000000).length > 200) hin('Der Titel wurde auf 200 Zeichen gekürzt');
  return IcsTermin(
    uid: uid,
    titel: titel,
    ort: _bereinigen(ortRoh, max: 200),
    beschreibung: _bereinigen(beschr, max: 4000, mehrzeilig: true),
    ganztaegig: ganzt,
    startUtc: startUtc,
    endUtc: endUtc,
    tzid: tzid,
    startDate: startDate,
    endDate: endDate,
    rrule: regel,
    erinnerungMin: _erinnerung(e.alarme),
    ausnahmen: ausnahmen.values.toList(),
  );
}
