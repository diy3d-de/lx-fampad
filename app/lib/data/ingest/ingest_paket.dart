// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), Päckchen öffnen. Formate verbindlich: docs/HA-FORMAT.md.
//
// `box` = libsodium Sealed Box (`crypto_box_seal`) an den Postfach-Schlüssel über den UTF-8-Text eines JSON:
//   { v: 1, kanal, d: "YYYY-MM-DD" (Kalendertag Europe/Berlin, Stand zum Tagesbeginn), t: Millisekunden, stand: "Dezimaltext", e: Einheit, mac: 64 Hex }
// MAC = BLAKE2b-256 mit Schlüssel `s` über "fampad-ingest-v1\n" + kanal + "\n" + d + "\n" + t + "\n" + stand + "\n" + e (stand und e exakt wie im Päckchen), Kleinbuchstaben-Hex,
// in konstanter Zeit verglichen. Alles streng: ein Päckchen mit unbekannter Version, falschem MAC oder ungültigem Kanal/Datum/Stand wird NIE eingetragen. Der Stand wird als
// Dezimaltext gelesen und ohne Gleitkomma in Tausendstel umgerechnet (mehr als drei Nachkommastellen werden kaufmännisch gerundet). Nie Werte loggen.
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/bytes.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../zaehler/zaehler_modelle.dart' show kMaxStandMilli, rundenDiv;

const int kPaketVersion = 1;
const String kMacKontext = 'fampad-ingest-v1';

final RegExp _kanalForm = RegExp(r'^[a-z0-9_]{1,40}$');
final RegExp _tagForm = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _standForm = RegExp(r'^(\d{1,10})(?:\.(\d{1,6}))?$');
final RegExp _hexForm = RegExp(r'^[0-9a-f]{64}$');

/// Warum ein Päckchen verworfen wird (nur Zählung und Anzeige im Zustand, nie der Inhalt).
enum PaketFehler { kodierung, entschluesselung, format, version, kanal, datum, stand, mac }

/// Ein geprüfter Wert: ein Kanal, ein Kalendertag und der Zählerstand zum Tagesbeginn in Tausendsteln der Einheit.
class IngestWert {
  final String kanal;

  /// Kalendertag (UTC-Mitternacht, nur das Datum zählt).
  final DateTime tag;
  final int milli;

  /// Ablesezeitpunkt (Millisekunden seit 1970) und Einheit laut Päckchen (nur Anzeige).
  final int zeit;
  final String einheit;
  const IngestWert({required this.kanal, required this.tag, required this.milli, required this.zeit, required this.einheit});
}

/// Ein echtes Päckchen (der MAC stimmt) mit einem Stand, der sich nicht als Zahl lesen lässt (zum Beispiel mehr als 10 Stellen). Der Text dient nur der Anzeige (gekürzt), nie dem Eintragen.
class IngestUngueltigerStand {
  final String kanal;
  final DateTime tag;
  final String text;
  final String einheit;
  const IngestUngueltigerStand({required this.kanal, required this.tag, required this.text, required this.einheit});
}

class PaketErgebnis {
  final IngestWert? wert;
  final PaketFehler? fehler;

  /// Nur bei [PaketFehler.stand] mit gültigem MAC: das Päckchen ist echt, trägt aber eine Information zum Wert und darf darum nie still gelöscht werden.
  final IngestUngueltigerStand? ungueltigerStand;
  const PaketErgebnis.ok(IngestWert w) : wert = w, fehler = null, ungueltigerStand = null;
  const PaketErgebnis.fehler(PaketFehler f, {this.ungueltigerStand}) : wert = null, fehler = f;
  bool get ok => wert != null;
}

/// Liest `YYYY-MM-DD` als Kalendertag (UTC); null bei allem, was kein echter Kalendertag der Jahre 2000 bis 2999 ist.
DateTime? ingestTagLesen(String text) {
  final m = _tagForm.firstMatch(text);
  if (m == null) return null;
  final j = int.parse(m[1]!);
  final mo = int.parse(m[2]!);
  final t = int.parse(m[3]!);
  if (j < 2000 || j > 2999) return null;
  final d = DateTime.utc(j, mo, t);
  return d.year == j && d.month == mo && d.day == t ? d : null;
}

/// Dezimaltext mit Punkt (höchstens 6 Nachkommastellen, nie negativ, kein Exponent) in Tausendstel; mehr als drei Nachkommastellen werden kaufmännisch gerundet (halbe nach oben).
/// Reine Ganzzahlrechnung, nie Gleitkomma. null bei jeder anderen Form oder einem Wert über dem Zählerstand-Höchstwert.
int? ingestStandInMilli(String text) {
  final m = _standForm.firstMatch(text);
  if (m == null) return null;
  final ganz = int.parse(m[1]!);
  final rest = (m[2] ?? '').padRight(6, '0');
  final milli = ganz * 1000 + rundenDiv(int.parse(rest), 1000); // 999,9996 -> 1000 Tausendstel: der Übertrag ergibt sich von selbst
  return milli > kMaxStandMilli ? null : milli;
}

/// Der erwartete MAC als Kleinbuchstaben-Hex.
String ingestMac(CryptoProvider c, Uint8List geheimnis, {required String kanal, required String d, required int t, required String stand, required String einheit}) {
  final nachricht = utf8Bytes('$kMacKontext\n$kanal\n$d\n$t\n$stand\n$einheit');
  return c.hash(nachricht, schluessel: geheimnis, laenge: 32).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Vergleich zweier Texte in konstanter Zeit (gleiche Länge vorausgesetzt, sonst falsch).
bool gleicherText(String a, String b) => gleicheBytes(utf8.encode(a), utf8.encode(b));

/// Öffnet ein Päckchen: [boxBase64] (Standard-Base64) an den Postfach-Schlüssel ([oeffentlich], [geheim]), Prüfgeheimnis [geheimnis]. Wirft nie, sondern liefert den Grund.
PaketErgebnis paketOeffnen(CryptoProvider c, String boxBase64, {required Uint8List oeffentlich, required Uint8List geheim, required Uint8List geheimnis}) {
  final Uint8List box;
  try {
    box = Uint8List.fromList(base64.decode(boxBase64));
  } on FormatException {
    return const PaketErgebnis.fehler(PaketFehler.kodierung);
  }
  final Uint8List klar;
  try {
    klar = c.versiegelungOeffnen(box, oeffentlich, geheim);
  } on CryptoFehler {
    return const PaketErgebnis.fehler(PaketFehler.entschluesselung);
  }
  final Object? d;
  try {
    d = jsonDecode(utf8.decode(klar));
  } on Object {
    return const PaketErgebnis.fehler(PaketFehler.format);
  }
  if (d is! Map) return const PaketErgebnis.fehler(PaketFehler.format);
  if (d['v'] is! int) return const PaketErgebnis.fehler(PaketFehler.format);
  if (d['v'] != kPaketVersion) return const PaketErgebnis.fehler(PaketFehler.version);
  final kanal = d['kanal'];
  final tag = d['d'];
  final t = d['t'];
  final stand = d['stand'];
  final e = d['e'];
  final mac = d['mac'];
  if (kanal is! String || tag is! String || t is! int || stand is! String || e is! String || mac is! String) return const PaketErgebnis.fehler(PaketFehler.format);
  if (!_kanalForm.hasMatch(kanal)) return const PaketErgebnis.fehler(PaketFehler.kanal);
  final datum = ingestTagLesen(tag);
  if (datum == null || t < 0 || t > 4102444800000) return const PaketErgebnis.fehler(PaketFehler.datum);
  final milli = ingestStandInMilli(stand);
  if (e.isEmpty || e.length > 16) return const PaketErgebnis.fehler(PaketFehler.format);
  // der MAC zuletzt: erst jetzt ist sicher, dass alle Felder die Form haben, über die er gebildet wird
  final macOk = _hexForm.hasMatch(mac) && gleicherText(mac, ingestMac(c, geheimnis, kanal: kanal, d: tag, t: t, stand: stand, einheit: e));
  if (!macOk) return const PaketErgebnis.fehler(PaketFehler.mac);
  if (milli == null) {
    // echtes Päckchen mit unlesbarem Stand: es trägt eine Information zum Wert und wird der Person vorgelegt (nur Anzeige, gekürzt), nie still gelöscht
    final kurz = stand.length > 40 ? '${stand.substring(0, 40)}…' : stand;
    return PaketErgebnis.fehler(PaketFehler.stand, ungueltigerStand: IngestUngueltigerStand(kanal: kanal, tag: datum, text: kurz, einheit: e));
  }
  return PaketErgebnis.ok(IngestWert(kanal: kanal, tag: datum, milli: milli, zeit: t, einheit: e));
}
