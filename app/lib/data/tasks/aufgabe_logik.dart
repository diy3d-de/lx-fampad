// Reine Logik der Aufgaben (ohne Datenbank und Oberfläche): Fälligkeit, Überfälligkeit, einfache Wiederholung, Filter und Sortierung.
// Zeiten sind Wanduhrzeiten der Familienzone (`DateTime.utc`-Markierung, siehe data/calendar/zeitzonen.dart); Tage sind `DateTime.utc(j, m, t)`.
import '../app_database.dart';
import '../calendar/expansion.dart' show tagAusText;
import '../calendar/zeitzonen.dart';
import '../lists/list_repository.dart' show ListenSicht;

/// Wer eine Aufgabe sieht (gleiche Stufen wie bei Listen und Terminen).
typedef AufgabeSicht = ListenSicht;

/// Obergrenze der Rechenschritte beim Suchen der nächsten Fälligkeit (Deckel gegen Endlosschleifen bei absurden Eingaben).
const kMaxWiederholSchritte = 1000;

enum AufgabePrio {
  keine(0, 'Keine'),
  niedrig(1, 'Niedrig'),
  mittel(2, 'Mittel'),
  hoch(3, 'Hoch');

  final int wert;
  final String label;
  const AufgabePrio(this.wert, this.label);

  /// Unbekannte Werte (neuere Server-Version) gelten als "keine".
  static AufgabePrio von(int wert) => values.firstWhere((p) => p.wert == wert, orElse: () => AufgabePrio.keine);
}

enum AufgabeWdh {
  keine(null, 'Einmalig'),
  taeglich('daily', 'Täglich'),
  woechentlich('weekly', 'Wöchentlich'),
  monatlich('monthly', 'Monatlich');

  final String? wire;
  final String label;
  const AufgabeWdh(this.wire, this.label);

  /// Unbekannte Werte gelten als "einmalig" (es entsteht keine Folgeaufgabe).
  static AufgabeWdh von(String? wire) => values.firstWhere((w) => w.wire == wire, orElse: () => AufgabeWdh.keine);
}

/// Heutiger Tag (0 Uhr, UTC-Markierung) in der Familienzone.
DateTime tagVon(DateTime jetzt) {
  final w = wandUhr(jetzt.toUtc(), familienOrt);
  return DateTime.utc(w.year, w.month, w.day);
}

/// Fälligkeit als Wanduhrzeit der Zeitzone der Aufgabe (Tag: 0 Uhr); null = ohne Fälligkeit.
DateTime? faelligWand(Aufgabe a) {
  final d = a.faelligDate;
  if (d != null) return tagAusText(d);
  final u = a.faelligUtc;
  if (u == null) return null;
  return wandUhr(u.toUtc(), ortFuer(a.tzid));
}

/// Hat die Fälligkeit eine Uhrzeit (sonst nur einen Tag oder gar keine)?
bool hatUhrzeit(Aufgabe a) => a.faelligUtc != null;

bool istErledigt(Aufgabe a) => a.erledigtAt != null;

/// Offen und die Fälligkeit liegt hinter uns: bei einem Tag ab dem Folgetag, bei einem Zeitpunkt sobald er vorbei ist.
bool istUeberfaellig(Aufgabe a, DateTime jetzt) {
  if (istErledigt(a)) return false;
  final d = a.faelligDate;
  if (d != null) {
    final tag = tagAusText(d);
    return tag != null && tag.isBefore(tagVon(jetzt));
  }
  final u = a.faelligUtc;
  return u != null && u.isBefore(jetzt);
}

/// Fällig heute (Tag = heute oder Zeitpunkt heute, noch nicht vorbei) und offen.
bool istHeuteFaellig(Aufgabe a, DateTime jetzt) {
  if (istErledigt(a)) return false;
  final w = faelligWand(a);
  return w != null && DateTime.utc(w.year, w.month, w.day) == tagVon(jetzt) && !istUeberfaellig(a, jetzt);
}

DateTime _schritt(DateTime basis, AufgabeWdh wdh, int k) {
  switch (wdh) {
    case AufgabeWdh.taeglich:
      return basis.add(Duration(days: k));
    case AufgabeWdh.woechentlich:
      return basis.add(Duration(days: 7 * k));
    case AufgabeWdh.monatlich:
      // vom ursprünglichen Tag des Monats aus (der 31. wird im Februar der 28./29., im März aber wieder der 31.)
      final m = basis.month - 1 + k;
      final jahr = basis.year + m ~/ 12;
      final monat = m % 12 + 1;
      final letzter = DateTime.utc(jahr, monat + 1, 0).day;
      return DateTime.utc(jahr, monat, basis.day < letzter ? basis.day : letzter, basis.hour, basis.minute);
    case AufgabeWdh.keine:
      return basis;
  }
}

/// Fälligkeit der Folgeaufgabe: der erste Schritt ab [basisWand], der nach heute (Tag) bzw. nach jetzt (mit Uhrzeit) liegt.
/// Null bei "einmalig" oder wenn der Deckel [kMaxWiederholSchritte] erreicht ist.
DateTime? naechsteFaelligkeit({required DateTime basisWand, required AufgabeWdh wdh, required bool mitUhrzeit, required DateTime jetzt}) {
  if (wdh == AufgabeWdh.keine) return null;
  final jetztWand = wandUhr(jetzt.toUtc(), familienOrt);
  final heute = DateTime.utc(jetztWand.year, jetztWand.month, jetztWand.day);
  for (var k = 1; k <= kMaxWiederholSchritte; k++) {
    final c = _schritt(basisWand, wdh, k);
    if (mitUhrzeit ? c.isAfter(jetztWand) : c.isAfter(heute)) return c;
  }
  return null;
}

// ------------------------------------------------------------------ Filter und Sortierung

enum AufgabeFilter {
  offen('Offen'),
  alle('Alle'),
  meine('Meine'),
  erledigt('Erledigt');

  final String label;
  const AufgabeFilter(this.label);
}

enum AufgabeSortierung {
  faelligkeit('Fälligkeit'),
  prioritaet('Priorität');

  final String label;
  const AufgabeSortierung(this.label);
}

/// Wendet Filter und Person an. [person]: nur Aufgaben dieser zuständigen Person (zusätzlich zum Filter).
List<Aufgabe> filtereAufgaben(List<Aufgabe> alle, {required AufgabeFilter filter, String? person, String? ich}) => [
  for (final a in alle)
    if (switch (filter) {
          AufgabeFilter.alle => true,
          AufgabeFilter.offen => !istErledigt(a),
          AufgabeFilter.erledigt => istErledigt(a),
          AufgabeFilter.meine => ich != null && a.assigneeId == ich && !istErledigt(a),
        } &&
        (person == null || a.assigneeId == person))
      a,
];

int _faelligVergleich(Aufgabe a, Aufgabe b) {
  final x = faelligWand(a);
  final y = faelligWand(b);
  if (x == null && y == null) return 0;
  if (x == null) return 1; // ohne Fälligkeit nach hinten
  if (y == null) return -1;
  return x.compareTo(y);
}

/// Sortiert: offene vor erledigten; offene nach Fälligkeit (dann Priorität) bzw. Priorität (dann Fälligkeit), erledigte nach Erledigung (neueste zuerst).
List<Aufgabe> sortiereAufgaben(List<Aufgabe> alle, AufgabeSortierung art) {
  int stabil(Aufgabe a, Aufgabe b) {
    final t = a.createdAt.compareTo(b.createdAt);
    return t != 0 ? t : a.id.compareTo(b.id);
  }

  final offen = alle.where((a) => !istErledigt(a)).toList()
    ..sort((a, b) {
      final c = switch (art) {
        AufgabeSortierung.faelligkeit => _faelligVergleich(a, b) != 0 ? _faelligVergleich(a, b) : b.prioritaet.compareTo(a.prioritaet),
        AufgabeSortierung.prioritaet => b.prioritaet.compareTo(a.prioritaet) != 0 ? b.prioritaet.compareTo(a.prioritaet) : _faelligVergleich(a, b),
      };
      return c != 0 ? c : stabil(a, b);
    });
  final erledigt = alle.where(istErledigt).toList()
    ..sort((a, b) {
      final c = b.erledigtAt!.compareTo(a.erledigtAt!);
      return c != 0 ? c : stabil(a, b);
    });
  return [...offen, ...erledigt];
}

/// Offene Unteraufgaben-Zähler "erledigt / gesamt" einer Aufgabe.
({int erledigt, int gesamt}) punkteStand(List<AufgabePunkt> punkte) => (erledigt: punkte.where((p) => p.doneAt != null).length, gesamt: punkte.length);

/// Unteraufgaben in Anzeigereihenfolge (Position, dann Anlage).
List<AufgabePunkt> sortierePunkte(List<AufgabePunkt> punkte) => [...punkte]
  ..sort((a, b) {
    final p = a.position.compareTo(b.position);
    if (p != 0) return p;
    final t = a.createdAt.compareTo(b.createdAt);
    return t != 0 ? t : a.id.compareTo(b.id);
  });
