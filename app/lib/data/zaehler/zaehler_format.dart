// Zähler (Abschnitt 6l): deutsche Formate für Stände, Verbrauch, Beträge, Prozent und Zeiträume. Rein (kein Flutter), damit Oberfläche und PDF-Bericht dieselben Texte nutzen.
// Alles rechnet mit den ganzen Zahlen der Logik (Tausendstel, Zehntausendstel, Cent); gerundet wird nur zur Anzeige.
import 'zaehler_logik.dart';
import 'zaehler_modelle.dart';
import 'zaehler_uebersicht.dart' show tagDeutsch;

const _monate = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];
const _monateKurz = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];
const _monateBuchstabe = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];

String monatName(int monat) => _monate[(monat - 1) % 12];
String monatKurz(int monat) => _monateKurz[(monat - 1) % 12];
String monatBuchstabe(int monat) => _monateBuchstabe[(monat - 1) % 12];

/// Ganze Zahl mit Tausenderpunkten: 48213 -> "48.213".
String tausender(String ganz) {
  final neg = ganz.startsWith('-');
  final z = neg ? ganz.substring(1) : ganz;
  final b = StringBuffer();
  for (var i = 0; i < z.length; i++) {
    if (i > 0 && (z.length - i) % 3 == 0) b.write('.');
    b.write(z[i]);
  }
  return '${neg ? '-' : ''}$b';
}

/// Zählerstand wie am Zähler: "48.213" oder "47.901,5" (nur nötige Nachkommastellen).
String standAnzeige(int milli) {
  final t = mengeText(milli, kuerzen: true);
  final i = t.indexOf(',');
  return i < 0 ? tausender(t) : '${tausender(t.substring(0, i))}${t.substring(i)}';
}

/// Verbrauch gerundet nach Größe: kWh ab 10 ganz, sonst eine Stelle; andere Einheiten ab 100 ganz, sonst eine Stelle. "312 kWh", "9,4 m³".
String verbrauchAnzeige(int milli, String einheit, {bool mitEinheit = true}) {
  final neg = milli < 0;
  final a = milli.abs();
  final stellen = einheit == 'kWh' ? (a >= 10000 ? 0 : 1) : (a >= 100000 ? 0 : 1);
  final faktor = stellen == 0 ? 1000 : 100;
  final r = rundenDiv(a, faktor);
  final ganz = stellen == 0 ? '$r' : '${r ~/ 10},${r % 10}';
  final i = ganz.indexOf(',');
  final t = i < 0 ? tausender(ganz) : '${tausender(ganz.substring(0, i))}${ganz.substring(i)}';
  return '${neg ? '-' : ''}$t${mitEinheit && einheit.isNotEmpty ? ' $einheit' : ''}';
}

/// Betrag in Euro: "1.046,00 €".
String euroAnzeige(int cent) {
  final neg = cent < 0;
  final t = geldText(cent.abs());
  final i = t.indexOf(',');
  return '${neg ? '-' : ''}${tausender(t.substring(0, i))}${t.substring(i)} €';
}

/// Euro ohne Cent bei ganzen Beträgen: "95 €", sonst "95,50 €".
String euroKurz(int cent) => cent % 100 == 0 ? '${tausender('${cent ~/ 100}')} €' : euroAnzeige(cent);

/// Preis je Einheit: "0,3456 €" (die vier Nachkommastellen, überflüssige Nullen bis auf zwei gekürzt).
String preisAnzeige(int ap) {
  var t = preisText(ap);
  while (t.endsWith('0') && t.length - t.indexOf(',') > 3) {
    t = t.substring(0, t.length - 1);
  }
  return '$t €';
}

/// "▲ 12 %" bzw. "▼ 8 %" (null ohne Wert).
String prozentAnzeige(double? p) {
  if (p == null) return '';
  final r = p.abs() < 0.5 ? 0 : p.abs().round();
  if (r == 0) return '± 0 %';
  return '${p > 0 ? '▲' : '▼'} $r %';
}

/// Zeitraum als Text: "01.03.2025 bis 28.02.2026" (das Ende ist im Zeitraum exklusiv, im Text der letzte Tag).
String zeitraumText(Zeitraum z) => '${tagDeutsch(z.start)} bis ${tagDeutsch(z.ende.subtract(const Duration(days: 1)))}';

