// Wiederholung eines Termins in der Oberfläche: Auswahl (täglich, wöchentlich, monatlich, jährlich, Intervall, Ende) <-> RRULE-Text.
// Der Server prüft die Form (server/src/sync/rrule.ts); hier entstehen nur Regeln dieser Teilmenge. Eine fremde Regel, die sich nicht
// abbilden lässt (z. B. aus einem späteren Import), bleibt unverändert erhalten ([eigeneRegel]).
import 'package:timezone/timezone.dart' as tz;

import 'expansion.dart';
import 'zeitzonen.dart';

enum WdhArt {
  keine('keine', 'Einmalig'),
  taeglich('DAILY', 'Täglich'),
  woechentlich('WEEKLY', 'Wöchentlich'),
  monatlich('MONTHLY', 'Monatlich'),
  jaehrlich('YEARLY', 'Jährlich');

  final String freq;
  final String label;
  const WdhArt(this.freq, this.label);
}

enum WdhEnde { nie, bis, anzahl }

/// Monatlich: am selben Tag des Monats (z. B. der 15.) oder am selben Wochentag (z. B. der zweite Montag).
enum MonatsModus { tagImMonat, wochentag }

const _wochentagKuerzel = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
const wochentagKurz = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const kMaxAnzahl = 1000;

String _zweistellig(int n) => n.toString().padLeft(2, '0');

class Wiederholung {
  final WdhArt art;
  final int intervall;

  /// Wochentage (1 = Montag … 7 = Sonntag) bei wöchentlicher Wiederholung; leer = der Wochentag des Beginns.
  final Set<int> wochentage;
  final MonatsModus modus;
  final WdhEnde ende;

  /// Letzter Tag (einschließlich) bei [WdhEnde.bis].
  final DateTime? bis;
  final int anzahl;

  /// Regel, die sich nicht abbilden lässt: wird unverändert gespeichert, solange die Person nichts daran ändert.
  final String? eigeneRegel;

  const Wiederholung({
    this.art = WdhArt.keine,
    this.intervall = 1,
    this.wochentage = const {},
    this.modus = MonatsModus.tagImMonat,
    this.ende = WdhEnde.nie,
    this.bis,
    this.anzahl = 10,
    this.eigeneRegel,
  });

  static const keine = Wiederholung();

  bool get wiederholt => art != WdhArt.keine || eigeneRegel != null;

  Wiederholung kopie({
    WdhArt? art,
    int? intervall,
    Set<int>? wochentage,
    MonatsModus? modus,
    WdhEnde? ende,
    DateTime? bis,
    int? anzahl,
  }) => Wiederholung(
    art: art ?? this.art,
    intervall: intervall ?? this.intervall,
    wochentage: wochentage ?? this.wochentage,
    modus: modus ?? this.modus,
    ende: ende ?? this.ende,
    bis: bis ?? this.bis,
    anzahl: anzahl ?? this.anzahl,
  );

  /// RRULE-Text (ohne Präfix) für einen Termin, der am Tag [startTag] (Wanduhr) beginnt; null = keine Wiederholung.
  /// [ort] ist die Zeitzone des Termins (UNTIL eines Zeittermins steht in UTC), [ganztaegig]: UNTIL als Datum.
  String? zuRrule({required DateTime startTag, required bool ganztaegig, required tz.Location ort}) {
    if (eigeneRegel != null) return eigeneRegel;
    if (art == WdhArt.keine) return null;
    final teile = <String>['FREQ=${art.freq}'];
    final n = intervall.clamp(1, 99);
    if (n > 1) teile.add('INTERVAL=$n');
    switch (art) {
      case WdhArt.woechentlich:
        final tage = wochentage.isEmpty ? {startTag.weekday} : wochentage;
        final sortiert = tage.toList()..sort();
        teile.add('BYDAY=${[for (final t in sortiert) _wochentagKuerzel[t - 1]].join(',')}');
      case WdhArt.monatlich:
        if (modus == MonatsModus.tagImMonat) {
          teile.add('BYMONTHDAY=${startTag.day}');
        } else {
          final nr = (startTag.day - 1) ~/ 7 + 1;
          // fünfter Wochentag = der letzte des Monats
          teile.add('BYDAY=${nr >= 5 ? -1 : nr}${_wochentagKuerzel[startTag.weekday - 1]}');
        }
      case WdhArt.taeglich || WdhArt.jaehrlich || WdhArt.keine:
        break;
    }
    switch (ende) {
      case WdhEnde.nie:
        break;
      case WdhEnde.anzahl:
        teile.add('COUNT=${anzahl.clamp(1, kMaxAnzahl)}');
      case WdhEnde.bis:
        final tag = bis ?? startTag;
        if (ganztaegig) {
          teile.add('UNTIL=${tag.year.toString().padLeft(4, '0')}${_zweistellig(tag.month)}${_zweistellig(tag.day)}');
        } else {
          teile.add('UNTIL=${untilText(DateTime.utc(tag.year, tag.month, tag.day, 23, 59, 59), ort)}');
        }
    }
    return teile.join(';');
  }

  /// Liest eine Regel. Was sich nicht abbilden lässt, ergibt [eigeneRegel].
  static Wiederholung ausRrule(String? rrule, {required bool ganztaegig, required tz.Location ort}) {
    if (rrule == null || rrule.isEmpty) return keine;
    final eigene = Wiederholung(art: WdhArt.woechentlich, eigeneRegel: rrule);
    final teile = <String, String>{};
    for (final t in rrule.split(';')) {
      final i = t.indexOf('=');
      if (i <= 0) return eigene;
      teile[t.substring(0, i)] = t.substring(i + 1);
    }
    final art = WdhArt.values.where((a) => a != WdhArt.keine && a.freq == teile['FREQ']).firstOrNull;
    if (art == null) return eigene;
    const erlaubt = {'FREQ', 'INTERVAL', 'BYDAY', 'BYMONTHDAY', 'COUNT', 'UNTIL'};
    if (teile.keys.any((k) => !erlaubt.contains(k))) return eigene;
    final intervall = teile.containsKey('INTERVAL') ? int.tryParse(teile['INTERVAL']!) : 1;
    if (intervall == null || intervall < 1 || intervall > 99) return eigene;
    var wochentage = <int>{};
    var modus = MonatsModus.tagImMonat;
    final byday = teile['BYDAY'];
    if (byday != null) {
      if (art == WdhArt.woechentlich) {
        for (final t in byday.split(',')) {
          final i = _wochentagKuerzel.indexOf(t);
          if (i < 0) return eigene;
          wochentage.add(i + 1);
        }
      } else if (art == WdhArt.monatlich && RegExp(r'^(-1|[1-4])(MO|TU|WE|TH|FR|SA|SU)$').hasMatch(byday)) {
        modus = MonatsModus.wochentag;
      } else {
        return eigene;
      }
    }
    if (teile.containsKey('BYMONTHDAY') && (art != WdhArt.monatlich || byday != null || int.tryParse(teile['BYMONTHDAY']!) == null)) return eigene;
    var ende = WdhEnde.nie;
    DateTime? bis;
    var anzahl = 10;
    if (teile.containsKey('COUNT')) {
      if (teile.containsKey('UNTIL')) return eigene;
      final n = int.tryParse(teile['COUNT']!);
      if (n == null || n < 1 || n > kMaxAnzahl) return eigene;
      ende = WdhEnde.anzahl;
      anzahl = n;
    } else if (teile.containsKey('UNTIL')) {
      final u = teile['UNTIL']!;
      final instant = u.length == 8 ? DateTime.tryParse('${u}T000000Z') : (u.length == 16 ? DateTime.tryParse(u) : null);
      if (instant == null) return eigene;
      ende = WdhEnde.bis;
      final tag = (ganztaegig || u.length == 8) ? instant : wandUhr(instant, ort);
      bis = DateTime.utc(tag.year, tag.month, tag.day);
    }
    return Wiederholung(art: art, intervall: intervall, wochentage: wochentage, modus: modus, ende: ende, bis: bis, anzahl: anzahl);
  }

  /// Kurzbeschreibung für die Oberfläche ("Jeden 2. Tag", "Wöchentlich: Mo, Mi").
  String beschreibung() {
    if (eigeneRegel != null) return 'Eigene Wiederholung';
    if (art == WdhArt.keine) return 'Einmalig';
    final n = intervall;
    var text = switch (art) {
      WdhArt.taeglich => n == 1 ? 'Täglich' : 'Alle $n Tage',
      WdhArt.woechentlich => n == 1 ? 'Wöchentlich' : 'Alle $n Wochen',
      WdhArt.monatlich => n == 1 ? 'Monatlich' : 'Alle $n Monate',
      WdhArt.jaehrlich => n == 1 ? 'Jährlich' : 'Alle $n Jahre',
      WdhArt.keine => 'Einmalig',
    };
    if (art == WdhArt.woechentlich && wochentage.isNotEmpty) {
      final tage = wochentage.toList()..sort();
      text += ' (${[for (final t in tage) wochentagKurz[t - 1]].join(', ')})';
    }
    return switch (ende) {
      WdhEnde.nie => text,
      WdhEnde.anzahl => '$text, $anzahl-mal',
      WdhEnde.bis => bis == null ? text : '$text, bis ${_zweistellig(bis!.day)}.${_zweistellig(bis!.month)}.${bis!.year}',
    };
  }
}

/// UNTIL-Text eines Zeitpunkts (`YYYYMMDDTHHMMSSZ`): [wand] ist die Wanduhrzeit in [ort].
String untilText(DateTime wand, tz.Location ort) {
  final u = instantAusWand(wand, ort);
  return '${u.year.toString().padLeft(4, '0')}${_zweistellig(u.month)}${_zweistellig(u.day)}T${_zweistellig(u.hour)}${_zweistellig(u.minute)}${_zweistellig(u.second)}Z';
}

/// Regel mit neuem Ende "bis einschließlich vor [vorkommen]": entfernt COUNT und UNTIL, setzt UNTIL eine Sekunde vor dem Vorkommen
/// ([startUtc] bei Zeitterminen, [tag] bei ganztägigen: UNTIL ist dann der Vortag).
String regelBis(String rrule, {required bool ganztaegig, required DateTime startUtc, required DateTime tag}) {
  final teile = regelOhneUntil(rrule).regel.split(';').where((t) => !t.startsWith('COUNT=')).toList();
  if (ganztaegig) {
    final vortag = tag.subtract(const Duration(days: 1));
    teile.add('UNTIL=${vortag.year.toString().padLeft(4, '0')}${_zweistellig(vortag.month)}${_zweistellig(vortag.day)}');
  } else {
    final u = startUtc.toUtc().subtract(const Duration(seconds: 1));
    teile.add('UNTIL=${u.year.toString().padLeft(4, '0')}${_zweistellig(u.month)}${_zweistellig(u.day)}T${_zweistellig(u.hour)}${_zweistellig(u.minute)}${_zweistellig(u.second)}Z');
  }
  return teile.join(';');
}

/// Wert von COUNT einer Regel (null: keiner).
int? regelAnzahl(String rrule) {
  for (final t in rrule.split(';')) {
    if (t.startsWith('COUNT=')) return int.tryParse(t.substring(6));
  }
  return null;
}

/// Regel mit anderem COUNT.
String regelMitAnzahl(String rrule, int anzahl) {
  final teile = rrule.split(';').where((t) => !t.startsWith('COUNT=')).toList()..add('COUNT=$anzahl');
  return teile.join(';');
}
