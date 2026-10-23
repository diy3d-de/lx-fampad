// Reine Logik des Fristen-Trackers (ohne Datenbank und Oberfläche). Eine Frist ist eine Aufgabe mit `frist = true`: Ablaufdatum = Fälligkeit
// (Tag), Vorwarnzeit = `erinnerungMin` (Tage * 1440), Wiederholung = `fristMonate` (12 = jährlich). Tage sind `DateTime.utc(j, m, t)`.
import '../app_database.dart';
import 'aufgabe_logik.dart';

/// Vorwarnzeiten (Tage), die der Editor anbietet. Der Server erlaubt bis 365 Tage (`erinnerungMin` bis 525600).
const kFristVorwarnTage = <int>[7, 30, 60, 90];

/// Standard-Vorwarnzeit einer neuen Frist.
const kFristVorwarnStandard = 30;

/// Wiederholungen des Editors in Monaten (null = einmalig).
const kFristWiederholungen = <int?>[null, 6, 12, 24, 36, 60];

/// Text einer Wiederholung: "Einmalig", "Halbjährlich", "Jährlich", "Alle 2 Jahre", "Alle 18 Monate".
String fristWiederholungText(int? monate) {
  if (monate == null) return 'Einmalig';
  if (monate == 6) return 'Halbjährlich';
  if (monate == 12) return 'Jährlich';
  if (monate % 12 == 0) return 'Alle ${monate ~/ 12} Jahre';
  return 'Alle $monate Monate';
}

/// Vorwarnzeit in Minuten für [tage] Tage und zurück (nur ganze Tage; sonst null).
int fristVorwarnMin(int tage) => tage * 1440;
int? fristVorwarnTage(int? erinnerungMin) => erinnerungMin == null || erinnerungMin < 0 ? null : erinnerungMin ~/ 1440;

/// Text der Vorwarnzeit: "7 Tage vorher".
String fristVorwarnText(int tage) => tage == 1 ? '1 Tag vorher' : '$tage Tage vorher';

/// Eine Vorlage, die den Editor nur vorbelegt (jederzeit änderbar).
class FristVorlage {
  final String titel;

  /// Wiederholung in Monaten.
  final int monate;
  final int vorwarnTage;
  const FristVorlage(this.titel, this.monate, this.vorwarnTage);
}

const kFristVorlagen = <FristVorlage>[
  FristVorlage('Reisepass', 120, 90),
  FristVorlage('Personalausweis', 120, 90),
  FristVorlage('TÜV', 24, 30),
  FristVorlage('Versicherung', 12, 90),
  FristVorlage('Heizungswartung', 12, 30),
  FristVorlage('Filterwechsel', 6, 7),
];

enum FristAmpel {
  /// Abgelaufen.
  ueberfaellig,

  /// Innerhalb der Vorwarnzeit (inklusive Ablauftag).
  bald,

  /// Noch ruhig.
  ruhig,

  /// Erledigt.
  erledigt,
}

bool istFrist(Aufgabe a) => a.frist;

/// Ablaufdatum der Frist (Tag, UTC-Markierung); null ohne Datum.
DateTime? fristTag(Aufgabe a) {
  final w = faelligWand(a);
  return w == null ? null : DateTime.utc(w.year, w.month, w.day);
}

/// Tage bis zum Ablauf (negativ = überfällig); null ohne Datum. Der Ablauftag selbst ist 0 und noch nicht überfällig.
int? fristRestTage(Aufgabe a, DateTime jetzt) {
  final t = fristTag(a);
  return t?.difference(tagVon(jetzt)).inDays;
}

/// Vorwarnzeit in Tagen; ohne Angabe [kFristVorwarnStandard].
int fristVorwarnTageOderStandard(Aufgabe a) => fristVorwarnTage(a.erinnerungMin) ?? kFristVorwarnStandard;

FristAmpel fristAmpel(Aufgabe a, DateTime jetzt) {
  if (istErledigt(a)) return FristAmpel.erledigt;
  final rest = fristRestTage(a, jetzt);
  if (rest == null) return FristAmpel.ruhig;
  if (rest < 0) return FristAmpel.ueberfaellig;
  return rest <= fristVorwarnTageOderStandard(a) ? FristAmpel.bald : FristAmpel.ruhig;
}

/// "überfällig seit 3 Tagen", "heute", "morgen", "in 12 Tagen", "in 3 Monaten" (ab 90 Tagen).
String fristRestText(int rest) {
  if (rest < 0) return rest == -1 ? 'seit gestern überfällig' : 'seit ${-rest} Tagen überfällig';
  if (rest == 0) return 'läuft heute ab';
  if (rest == 1) return 'läuft morgen ab';
  if (rest < 90) return 'in $rest Tagen';
  final monate = (rest / 30.44).round();
  if (monate < 24) return 'in $monate Monaten';
  return 'in ${(rest / 365.25).toStringAsFixed(rest % 365 == 0 ? 0 : 1).replaceAll('.', ',')} Jahren';
}

/// Offene Fristen, nach Ablauf sortiert (überfällige zuerst, dann nach Datum); ohne Datum am Ende.
List<Aufgabe> offeneFristen(Iterable<Aufgabe> alle) {
  final liste = [for (final a in alle) if (a.frist && !istErledigt(a)) a];
  final tage = {for (final a in liste) a.id: fristTag(a)};
  liste.sort((a, b) {
    final x = tage[a.id];
    final y = tage[b.id];
    if (x == null && y == null) return a.id.compareTo(b.id);
    if (x == null) return 1;
    if (y == null) return -1;
    final c = x.compareTo(y);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return liste;
}

/// Offene Fristen, die überfällig sind oder innerhalb ihrer Vorwarnzeit liegen (Startseiten-Kachel), nach Ablauf sortiert.
List<Aufgabe> dringendeFristen(Iterable<Aufgabe> alle, DateTime jetzt) => [
  for (final a in offeneFristen(alle))
    if (fristAmpel(a, jetzt) != FristAmpel.ruhig) a,
];

/// Der Tag [k] * [monate] Monate nach [basis] (Tag des Monats [wunschTag], im kurzen Monat auf dessen letzten Tag gekürzt: 29.2. + 1 Jahr =
/// 28.2., + 4 Jahre = 29.2.).
DateTime _monateNach(DateTime basis, int monate, int k, int wunschTag) {
  final m = basis.month - 1 + monate * k;
  final jahr = basis.year + m ~/ 12;
  final monat = m % 12 + 1;
  final letzter = DateTime.utc(jahr, monat + 1, 0).day;
  return DateTime.utc(jahr, monat, wunschTag < letzter ? wunschTag : letzter);
}

/// Ablaufdatum der Folgefrist: der erste Schritt von [monate] Monaten ab [basis], der nach heute liegt (gerechnet, nicht gezählt: eine uralte
/// Frist ergibt den nächsten Termin ab heute). [wunschTag]: Tag des Monats, der in der Kette erhalten bleibt (Standard: Tag der Basis).
/// Null bei ungültigen Monaten (< 1).
DateTime? naechsteFristFaelligkeit({required DateTime basis, required int monate, required DateTime jetzt, int? wunschTag}) {
  if (monate < 1) return null;
  final heute = tagVon(jetzt);
  final tag = wunschTag ?? basis.day;
  var k = ((heute.year - basis.year) * 12 + heute.month - basis.month) ~/ monate;
  if (k < 1) k = 1;
  if (k > 1) k -= 1; // die Schätzung kann einen Schritt zu hoch sein
  for (var i = 0; i < kMaxWiederholSchritte; i++, k++) {
    final c = _monateNach(basis, monate, k, tag);
    if (c.isAfter(heute)) return c;
  }
  return null;
}
