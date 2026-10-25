// Notfallblatt (P1): eine druckbare Seite mit dem Wiederherstellungsschlüssel und einer Kurzanleitung, damit die Familie im Ernstfall ohne Hilfe wieder an ihren
// Schlüssel kommt. Das Blatt ist ein einfaches PDF (A4, Standardschriften Helvetica und Courier, kein Paket, kein Netz, nichts wird irgendwohin gesendet).
// Es enthält das Geheimnis im Klartext und entsteht deshalb nur auf ausdrücklichen Klick, nur solange der Schlüssel ohnehin angezeigt wird (Bildschirmschutz),
// nur im Arbeitsspeicher und wird nie geloggt. Der Speichern-Dialog des Systems entscheidet, wohin es geht (Android: Dateiauswahl des Systems, Web: Download).
// Gedruckt wird es mit jedem PDF-Betrachter; danach soll die Datei gelöscht werden (steht auf dem Blatt).
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notfallblatt_download_stub.dart' if (dart.library.js_interop) 'notfallblatt_download_web.dart';

/// Schriftart in der Seitenbeschreibung (die drei Standardschriften jedes PDF-Betrachters).
enum _Schrift { normal, fett, mono }

class _Zeile {
  final _Schrift schrift;
  final double groesse;
  final double x;
  final double y;
  final String text;
  const _Zeile(this.schrift, this.groesse, this.x, this.y, this.text);
}

const double _seitenBreite = 595; // A4 in Punkt
const double _seitenHoehe = 842;
const double _rand = 54;

/// Windows-1252 (WinAnsiEncoding) für die Zeichen, die in deutschen Texten vorkommen; Unbekanntes wird zu "?".
List<int> _winAnsi(String s) {
  const sonder = {0x201E: 0x84, 0x201C: 0x93, 0x201D: 0x94, 0x2013: 0x96, 0x2014: 0x97, 0x2026: 0x85, 0x20AC: 0x80, 0x2022: 0x95};
  final out = <int>[];
  for (final r in s.runes) {
    if (r < 0x80 || (r >= 0xA0 && r <= 0xFF)) {
      out.add(r);
    } else {
      out.add(sonder[r] ?? 0x3F);
    }
  }
  return out;
}

/// Höchstzahl Zeichen des Namens auf dem Blatt (lange Namen würden aus dem Blatt laufen).
const int kNotfallblattNameMax = 40;

/// Der Name für das Blatt: Steuerzeichen und Zeilenumbrüche werden zu Leerzeichen, überflüssige Leerzeichen entfallen, zu lange Namen werden mit "..." gekürzt
/// (nach Zeichen, nie mitten in einem Zeichen). Was die Schrift nicht kennt (z. B. Emoji, nicht lateinische Schrift), wird beim Schreiben zu "?".
String _kurzerName(String name) {
  final sauber = name.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F  ]+'), ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();
  final zeichen = sauber.runes.toList();
  if (zeichen.length <= kNotfallblattNameMax) return sauber;
  return '${String.fromCharCodes(zeichen.take(kNotfallblattNameMax - 3)).trimRight()}...';
}

/// Maskiert ein Zeichen, das in einer PDF-Zeichenkette Bedeutung hat.
List<int> _maskiert(List<int> bytes) {
  final out = <int>[];
  for (final b in bytes) {
    if (b == 0x28 || b == 0x29 || b == 0x5C) out.add(0x5C);
    out.add(b);
  }
  return out;
}

/// Bricht [text] bei Wörtern auf höchstens [maxZeichen] Zeichen je Zeile um.
List<String> umbrechen(String text, int maxZeichen) {
  final zeilen = <String>[];
  var aktuell = '';
  for (final wort in text.split(RegExp(r'\s+'))) {
    if (wort.isEmpty) continue;
    if (aktuell.isEmpty) {
      aktuell = wort;
    } else if (aktuell.length + 1 + wort.length <= maxZeichen) {
      aktuell = '$aktuell $wort';
    } else {
      zeilen.add(aktuell);
      aktuell = wort;
    }
  }
  if (aktuell.isNotEmpty) zeilen.add(aktuell);
  return zeilen;
}

/// Die Anleitung auf dem Blatt (feste Texte; geprüft in den Tests, damit sie zur App passen).
const List<(String, String)> kNotfallblattAnleitung = [
  (
    'Wofür ist dieser Schlüssel?',
    'Mit dem Wiederherstellungsschlüssel holst du deinen Verschlüsselungsschlüssel zurück, wenn du alle Geräte verloren hast oder dein Passwort nicht mehr kennst. '
        'Ohne ihn, ohne die Passwort-Sicherung und ohne ein Gerät, auf dem du angemeldet bist, ist dein Chat-Verlauf nicht mehr lesbar. Auch ein Admin kann ihn nicht wiederherstellen.',
  ),
  (
    'So stellst du deinen Schlüssel wieder her',
    '1. Öffne die App (familyhub.lx-labs.dev) und melde dich an. 2. Gehe zu Profil > Verschlüsselung > „Gerät verbinden“ > „Mit Wiederherstellungsschlüssel“. '
        '3. Tippe den Schlüssel von diesem Blatt ab. Groß- und Kleinschreibung, Leerzeichen und Bindestriche sind egal.',
  ),
  (
    'So bewahrst du das Blatt auf',
    'Drucke das Blatt aus und lege es an einen sicheren Ort, nicht neben das Gerät (Schublade, Ordner mit wichtigen Papieren). Fotografiere es nicht, schicke es nicht per E-Mail oder Chat und lege es nicht in einer Cloud ab. '
        'Wer den Schlüssel kennt, kann deine Chats lesen. Lösche die PDF-Datei nach dem Drucken.',
  ),
  (
    'Wenn der Schlüssel in falsche Hände geraten ist',
    'Erzeuge unter Profil > Verschlüsselung > Erweitert einen neuen Wiederherstellungsschlüssel. Der alte gilt dann nicht mehr. Sage es einem Admin.',
  ),
];

/// Die Seite als Liste von Textzeilen (Zeichen und Stellen), getrennt vom PDF-Aufbau, damit sie sich prüfen lässt.
List<_Zeile> _seite({required List<String> gruppen, required String name, required DateTime datum}) {
  final z = <_Zeile>[];
  var y = _seitenHoehe - 72;
  z.add(_Zeile(_Schrift.fett, 22, _rand, y, 'Notfallblatt'));
  y -= 20;
  z.add(_Zeile(_Schrift.normal, 11, _rand, y, 'lx-fampad · Wiederherstellungsschlüssel'));
  y -= 15;
  z.add(_Zeile(_Schrift.normal, 11, _rand, y, 'für $name · erstellt am ${datum.day.toString().padLeft(2, '0')}.${datum.month.toString().padLeft(2, '0')}.${datum.year}'));
  y -= 30;
  // der Schlüssel in einem Rahmen: je Zeile sieben Gruppen
  final zeilen = <String>[for (var i = 0; i < gruppen.length; i += 7) gruppen.sublist(i, i + 7 > gruppen.length ? gruppen.length : i + 7).join('  ')];
  z.add(_Zeile(_Schrift.normal, 9, _rand + 12, y, 'WIEDERHERSTELLUNGSSCHLÜSSEL (GEHEIM)'));
  y -= 28;
  for (final l in zeilen) {
    z.add(_Zeile(_Schrift.mono, 17, _rand + 12, y, l));
    y -= 28;
  }
  y -= 6;
  for (final (titel, text) in kNotfallblattAnleitung) {
    z.add(_Zeile(_Schrift.fett, 12, _rand, y, titel));
    y -= 16;
    for (final l in umbrechen(text, 86)) {
      z.add(_Zeile(_Schrift.normal, 10.5, _rand, y, l));
      y -= 14;
    }
    y -= 10;
  }
  y -= 4;
  z.add(_Zeile(_Schrift.normal, 10.5, _rand, y, 'Abgelegt am: ______________________    Ort: ________________________________________'));
  return z;
}

/// Höhe des Rahmens um den Schlüssel (für die Zeichnung).
({double oben, double unten}) _rahmen(List<_Zeile> z) {
  final mono = z.where((e) => e.schrift == _Schrift.mono).toList();
  final kopf = z.firstWhere((e) => e.text.startsWith('WIEDERHERSTELLUNGSSCHLÜSSEL'));
  return (oben: kopf.y + 16, unten: mono.last.y - 12);
}

/// Das Notfallblatt als PDF-Datei (A4, eine Seite). [gruppen] sind die Vierergruppen des Schlüssels (`Wiederherstellung.gruppen`), [name] der Name der Person.
/// Der Rückgabewert enthält den Schlüssel im Klartext: nur speichern, nie loggen; danach [Uint8List.fillRange] mit 0.
Uint8List notfallblattPdf({required List<String> gruppen, required String name, DateTime? datum}) {
  if (gruppen.isEmpty || gruppen.any((g) => g.isEmpty)) throw ArgumentError('Ohne Schlüssel gibt es kein Notfallblatt.');
  final seite = _seite(gruppen: gruppen, name: _kurzerName(name), datum: datum ?? DateTime.now());
  final r = _rahmen(seite);

  // Inhalt der Seite (Zeichenstrom)
  final inhalt = BytesBuilder();
  void roh(String s) => inhalt.add(latin1.encode(s));
  // Rahmen (heller Druckstil: schwarz auf weiß)
  roh('0.8 w ${_rand.toStringAsFixed(1)} ${r.unten.toStringAsFixed(1)} ${(_seitenBreite - 2 * _rand).toStringAsFixed(1)} ${(r.oben - r.unten).toStringAsFixed(1)} re S\n');
  for (final l in seite) {
    final f = switch (l.schrift) {
      _Schrift.normal => '/F1',
      _Schrift.fett => '/F2',
      _Schrift.mono => '/F3',
    };
    roh('BT $f ${l.groesse} Tf ${l.x.toStringAsFixed(1)} ${l.y.toStringAsFixed(1)} Td (');
    inhalt.add(_maskiert(_winAnsi(l.text)));
    roh(') Tj ET\n');
  }
  final strom = inhalt.takeBytes();

  // Objekte
  final objekte = <List<int>>[
    latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    latin1.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    latin1.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R /F2 5 0 R /F3 6 0 R >> >> /Contents 7 0 R >>'),
    latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'),
    latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'),
    latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>'),
    [...latin1.encode('<< /Length ${strom.length} >>\nstream\n'), ...strom, ...latin1.encode('\nendstream')],
    latin1.encode('<< /Title (Notfallblatt lx-fampad) /Producer (lx-fampad) >>'),
  ];
  final aus = BytesBuilder();
  aus.add(latin1.encode('%PDF-1.4\n%âãÏÓ\n'));
  final stellen = <int>[];
  for (var i = 0; i < objekte.length; i++) {
    stellen.add(aus.length);
    aus.add(latin1.encode('${i + 1} 0 obj\n'));
    aus.add(objekte[i]);
    aus.add(latin1.encode('\nendobj\n'));
  }
  final xref = aus.length;
  final n = objekte.length + 1;
  aus.add(latin1.encode('xref\n0 $n\n0000000000 65535 f \n'));
  for (final s in stellen) {
    aus.add(latin1.encode('${s.toString().padLeft(10, '0')} 00000 n \n'));
  }
  aus.add(latin1.encode('trailer\n<< /Size $n /Root 1 0 R /Info ${objekte.length} 0 R >>\nstartxref\n$xref\n%%EOF\n'));
  final ergebnis = aus.takeBytes();
  // Zwischenpuffer mit dem Schlüssel im Klartext überschreiben (der Strom und seine Kopie im Seitenobjekt); das Ergebnis überschreibt der Aufrufer nach dem Speichern
  strom.fillRange(0, strom.length, 0);
  final seiteninhalt = objekte[6];
  for (var i = 0; i < seiteninhalt.length; i++) {
    seiteninhalt[i] = 0;
  }
  return ergebnis;
}

/// Dateiname des Notfallblatts (ohne Namen oder Kennungen der Person).
const String kNotfallblattDateiname = 'lx-fampad-notfallblatt.pdf';

/// Speichert [bytes] unter [name] über den Speichern-Dialog des Systems; false = die Person hat abgebrochen. Für Tests überschreibbar.
typedef NotfallblattSpeichern = Future<bool> Function(String name, Uint8List bytes);

Future<bool> _systemSpeichern(String name, Uint8List bytes) async {
  // Web: eigener Anker-Download (file_picker widerruft die Blob-Adresse sofort nach dem Klick); der Browser meldet weder Ziel noch Abbruch
  if (kIsWeb) return notfallblattHerunterladen(name, bytes);
  final ziel = await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    mimeType: 'application/pdf',
    dialogTitle: 'Notfallblatt speichern',
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );
  // Android: null = die Person hat abgebrochen
  return ziel != null;
}

final notfallblattSpeichernProvider = Provider<NotfallblattSpeichern>((ref) => _systemSpeichern);
