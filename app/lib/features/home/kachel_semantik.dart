// Vorlesetexte der Startseiten-Kacheln (mobil und Desktop): nicht nur "3 fällig", sondern die ersten Einträge mit ihrem Zustand, damit ein Lesegerät
// vorlesen kann, was auf der Kachel steht. Überfälliges steht als WORT im Text (nie nur als Farbe). Reine Funktionen ohne Oberfläche.
import '../../data/app_database.dart';
import '../../data/calendar/expansion.dart' show Vorkommen;
import '../../data/calendar/geburtstag.dart' show vorkommenTitel;
import '../../data/tasks/aufgabe_logik.dart' show istUeberfaellig;
import '../calendar/calendar_anzeige.dart' show anstehenderTerminText;
import '../tasks/aufgaben_anzeige.dart' show faelligText;

/// So viele Einträge liest eine Kachel höchstens vor.
const kSemantikMax = 4;

String _aufzaehlung(List<String> teile, int gesamt) {
  final text = teile.take(kSemantikMax).join('; ');
  return gesamt > kSemantikMax ? '$text; und ${gesamt - kSemantikMax} weitere' : text;
}

/// "Rechnung zahlen, überfällig, gestern; Müll rausbringen, heute" für die ersten Aufgaben.
String aufgabenSemantik(List<Aufgabe> liste, DateTime jetzt) => _aufzaehlung([
  for (final a in liste.take(kSemantikMax)) '${a.titel}, ${istUeberfaellig(a, jetzt) ? 'überfällig, ' : ''}${faelligText(a, jetzt)}',
], liste.length);

/// "Zahnarzt, heute · 15:30; Elternabend, morgen · 19:00" für die ersten Termine.
String termineSemantik(List<Vorkommen> liste, DateTime heute) => _aufzaehlung([
  for (final v in liste.take(kSemantikMax)) '${vorkommenTitel(v)}, ${anstehenderTerminText(v, heute)}',
], liste.length);

/// "Milch; Brot; Eier" für die ersten offenen Einträge.
String einkaufSemantik(List<Listeneintrag> offen) => _aufzaehlung([for (final e in offen.take(kSemantikMax)) e.inhalt], offen.length);
