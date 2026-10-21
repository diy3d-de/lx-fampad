// Geburtstage als eigene Termin-Art, ohne Server- oder Schemaänderung: ein ganztägiger Termin mit jährlicher Wiederholung (`FREQ=YEARLY`).
//
// Marke: `icalUid` = `lxfampad-geb-<Geburtsjahr oder 0000>-<UUID>`. Die UID ist ein vorhandenes, synchronisiertes Feld, das die Oberfläche nie
// zeigt; so reist die Marke samt Geburtsjahr mit dem Termin zu allen Geräten (Server und Schema bleiben unverändert). Der Server erlaubt
// Kalendertage erst ab dem Jahr 2000: bei früherem oder unbekanntem Geburtsjahr beginnt die Serie im Jahr 2000 (Monat und Tag stimmen), das
// Geburtsjahr steht nur in der UID. Das Alter ergibt sich aus Jahr des Vorkommens minus Geburtsjahr.
//
// Zusätzlich gelten importierte Termine (z. B. FamilyWall: "Geburtstag Max", ganztägig, jährlich) als Geburtstage (Titel enthält
// "Geburtstag"/"Birthday"); sie haben kein bekanntes Geburtsjahr und zeigen deshalb kein Alter.
import '../app_database.dart';
import 'expansion.dart';

const kGeburtstagUidPraefix = 'lxfampad-geb-';

/// Jährliche Wiederholung eines Geburtstags.
const kGeburtstagRegel = 'FREQ=YEARLY';

final _uidMuster = RegExp(r'^lxfampad-geb-(\d{4})-[0-9a-fA-F-]{8,}$');
final _titelMuster = RegExp(r'geburtstag|birthday', caseSensitive: false);

/// Eine UID mit Marke (Geburtsjahr null = unbekannt). [suffix] bleibt bei einer Änderung erhalten, sonst eine neue UUID.
String geburtstagUid(int? geburtsjahr, String suffix) => '$kGeburtstagUidPraefix${(geburtsjahr ?? 0).toString().padLeft(4, '0')}-$suffix';

/// Der UUID-Teil einer markierten UID (null bei anderen UIDs).
String? geburtstagUidSuffix(String? uid) {
  if (uid == null || !_uidMuster.hasMatch(uid)) return null;
  return uid.substring(kGeburtstagUidPraefix.length + 5);
}

/// Der Termin trägt die Marke dieser App.
bool hatGeburtstagsMarke(Termin t) => t.icalUid != null && _uidMuster.hasMatch(t.icalUid!);

/// Geburtsjahr aus der Marke; null bei unbekanntem Jahr oder ohne Marke.
int? geburtsjahr(Termin t) {
  final m = t.icalUid == null ? null : _uidMuster.firstMatch(t.icalUid!);
  if (m == null) return null;
  final j = int.parse(m.group(1)!);
  return j == 0 ? null : j;
}

/// Ein Geburtstag: mit Marke, oder ein ganztägiger, eintägiger, jährlicher Termin, dessen Titel "Geburtstag"/"Birthday" enthält (Import).
bool istGeburtstag(Termin t) {
  if (hatGeburtstagsMarke(t)) return true;
  if (!t.ganztaegig || t.rrule == null || !_titelMuster.hasMatch(t.titel)) return false;
  final r = t.rrule!;
  final jaehrlich = r.startsWith('FREQ=YEARLY') || r.contains(';FREQ=YEARLY');
  if (!jaehrlich) return false;
  final s = tagAusText(t.startDate);
  final e = tagAusText(t.endDate);
  return s != null && e != null && e.difference(s).inDays == 1;
}

/// Alter, das die Person an diesem Vorkommen wird; null ohne bekanntes Geburtsjahr oder bei einem Wert unter 1.
int? alterBeiVorkommen(Vorkommen v) {
  final j = geburtsjahr(v.termin);
  if (j == null) return null;
  final alter = v.ersterTag.year - j;
  return alter >= 1 ? alter : null;
}

/// Anzeigetitel: "Max wird 8" (Geburtsjahr bekannt), "Max hat Geburtstag" (markiert, Jahr unbekannt), sonst der Titel unverändert
/// (auch bei importierten Geburtstagen, deren Titel das Wort schon enthält).
String vorkommenTitel(Vorkommen v) {
  if (!hatGeburtstagsMarke(v.termin)) return v.titel;
  final alter = alterBeiVorkommen(v);
  return alter != null ? '${v.titel} wird $alter' : '${v.titel} hat Geburtstag';
}

/// Die nächsten Geburtstage aus einer nach Beginn sortierten Vorkommensliste.
List<Vorkommen> nurGeburtstage(Iterable<Vorkommen> v) => [
  for (final x in v)
    if (istGeburtstag(x.termin)) x,
];
