// Zähler (Abschnitt 6l): der PDF-Bericht als einfaches PDF (A4, mehrere Seiten, Standardschriften Helvetica und Courier, kein Paket, kein Netz), im hellen Druckstil (schwarz auf weiß; die
// Farben stehen hier fest im PDF-Code, nicht in der App-Oberfläche). Wie das Notfallblatt (data/crypto/notfallblatt.dart) entsteht es nur lokal im Arbeitsspeicher; gespeichert oder gedruckt
// wird über den Dialog des Systems. Es enthält Verbrauchsdaten: nie loggen, nie senden. Rechtsbündige Zahlen nutzen die Zeichenbreiten von Helvetica (Zahlen und Satzzeichen genau).
import 'dart:convert';
import 'dart:typed_data';

import '../../constants.dart' show kAppName;
import 'zaehler_bericht.dart';

const double _breite = 595; // A4 in Punkt
const double _hoehe = 842;
const double _rand = 48;
const double _unten = 60;

// Druckfarben (RGB 0..1): Text, gedämpft, Linien, Balken, Vorjahr
const _cText = [0.078, 0.09, 0.122]; // #14171F
const _cMuted = [0.294, 0.322, 0.388]; // #4B5263
const _cLinie = [0.788, 0.808, 0.855]; // #C9CEDA
const _cVorjahr = [0.604, 0.639, 0.71]; // #9AA3B5

String _f(List<double> c) => '${c[0]} ${c[1]} ${c[2]}';

/// Windows-1252 (WinAnsiEncoding) für die Zeichen aus deutschen Texten; Unbekanntes wird zu "?".
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

List<int> _maskiert(List<int> bytes) {
  final out = <int>[];
  for (final b in bytes) {
    if (b == 0x28 || b == 0x29 || b == 0x5C) out.add(0x5C);
    out.add(b);
  }
  return out;
}

const _schmal = 'fijltI.,:;|!\'()[]/ ';

/// Breite eines Textes in Punkt (Helvetica; Zahlen und Satzzeichen genau, Buchstaben nach Gruppen).
double textBreite(String t, double groesse, {bool fett = false}) {
  var w = 0.0;
  for (final r in t.runes) {
    final c = String.fromCharCode(r);
    double e;
    if (r >= 0x30 && r <= 0x39) {
      e = 0.556;
    } else if (c == '.' || c == ',' || c == ':' || c == ';' || c == ' ' || c == '/') {
      e = 0.278;
    } else if (c == '-') {
      e = 0.333;
    } else if (c == '%') {
      e = 0.889;
    } else if (c == '+') {
      e = 0.584;
    } else if (c == '(' || c == ')') {
      e = 0.333;
    } else if (c == 'm' || c == 'M') {
      e = 0.833;
    } else if (c == 'w' || c == 'W') {
      e = 0.8;
    } else if (_schmal.contains(c)) {
      e = 0.25;
    } else if (r >= 0x41 && r <= 0x5A) {
      e = 0.69;
    } else {
      e = 0.54;
    }
    w += e * (fett && !(r >= 0x30 && r <= 0x39) ? 1.06 : 1);
  }
  return w * groesse;
}

/// Bricht [text] bei Wörtern so um, dass jede Zeile höchstens [maxBreite] Punkt breit ist.
List<String> umbrechenNachBreite(String text, double groesse, double maxBreite, {bool fett = false}) {
  final zeilen = <String>[];
  var aktuell = '';
  for (final wort in text.split(RegExp(r'\s+'))) {
    if (wort.isEmpty) continue;
    final probe = aktuell.isEmpty ? wort : '$aktuell $wort';
    if (aktuell.isEmpty || textBreite(probe, groesse, fett: fett) <= maxBreite) {
      aktuell = probe;
    } else {
      zeilen.add(aktuell);
      aktuell = wort;
    }
  }
  if (aktuell.isNotEmpty) zeilen.add(aktuell);
  return zeilen;
}

class _Seite {
  final inhalt = StringBuffer();
  final texte = <int>[]; // nur für die Seitennummer
}

/// Schreibt Seiten mit Textzeilen, Linien und Balken; fängt am Ende jeder Seite eine neue an.
class _Schreiber {
  final seiten = <_Seite>[_Seite()];
  final bytes = <List<int>>[];
  double y = _hoehe - _rand;

  _Seite get _s => seiten.last;

  void _roh(String s) => _s.inhalt.write(s);

  void neueSeite() {
    seiten.add(_Seite());
    y = _hoehe - _rand;
  }

  /// Platz für [h] Punkt unter der aktuellen Zeile; sonst neue Seite.
  void platz(double h) {
    if (y - h < _unten) neueSeite();
  }

  void text(String t, double x, double groesse, {bool fett = false, bool mono = false, List<double> farbe = _cText, bool rechts = false, double? yy}) {
    final px = rechts ? x - textBreite(t, groesse, fett: fett) : x;
    final f = mono ? '/F3' : (fett ? '/F2' : '/F1');
    final bytesText = _maskiert(_winAnsi(t));
    _roh('${_f(farbe)} rg BT $f $groesse Tf ${px.toStringAsFixed(1)} ${(yy ?? y).toStringAsFixed(1)} Td (');
    _s.inhalt.write(latin1.decode(bytesText, allowInvalid: true));
    _roh(') Tj ET\n');
  }

  void linie(double x1, double x2, double yy, {double dicke = 0.6, List<double> farbe = _cLinie}) => _roh('${_f(farbe)} RG $dicke w ${x1.toStringAsFixed(1)} ${yy.toStringAsFixed(1)} m ${x2.toStringAsFixed(1)} ${yy.toStringAsFixed(1)} l S\n');

  void fuellen(double x, double yy, double w, double h, List<double> farbe) => _roh('${_f(farbe)} rg ${x.toStringAsFixed(1)} ${yy.toStringAsFixed(1)} ${w.toStringAsFixed(1)} ${h.toStringAsFixed(1)} re f\n');

  void rahmen(double x, double yy, double w, double h, List<double> farbe) => _roh('${_f(farbe)} RG 0.7 w ${x.toStringAsFixed(1)} ${yy.toStringAsFixed(1)} ${w.toStringAsFixed(1)} ${h.toStringAsFixed(1)} re S\n');
}

/// Der Bericht als PDF-Datei (A4, bei Bedarf mehrere Seiten). Enthält Verbrauchsdaten: nur speichern, nie loggen.
Uint8List zaehlerBerichtPdf(BerichtDaten d) {
  final s = _Schreiber();
  const links = _rand;
  const rechts = _breite - _rand;
  // Kopf
  s.text('Zählerbericht', links, 17, fett: true);
  s.text(kAppName.toUpperCase(), rechts, 9, mono: true, rechts: true);
  s.y -= 8;
  s.linie(links, rechts, s.y, dicke: 1.6, farbe: _cText);
  s.y -= 18;

  for (var a = 0; a < d.abschnitte.length; a++) {
    final ab = d.abschnitte[a];
    s.platz(a == 0 ? 120 : 220);
    if (a > 0) {
      s.y -= 14;
    }
    s.text(ab.titel, links, 13, fett: true);
    s.y -= 14;
    for (final z in umbrechenNachBreite('${ab.art} · ${ab.zeitraum}${ab.nummer == null ? '' : ' · Zähler ${ab.nummer}'}', 10, rechts - links)) {
      s.text(z, links, 10, farbe: _cMuted);
      s.y -= 13;
    }
    if (ab.unvollstaendig) {
      s.text('Hinweis: Für einen Teil des Zeitraums fehlen Ablesungen; die Werte gelten nur für den abgedeckten Teil.', links, 8.5, farbe: _cMuted);
      s.y -= 12;
    }
    s.y -= 6;

    // Stände je Zähler
    for (final t in ab.tabellen) {
      s.platz(60);
      if (ab.tabellen.length > 1 || t.nummer != null) {
        s.text('${t.titel}${t.nummer == null ? '' : ' · Zähler ${t.nummer}'}', links, 10, fett: true);
        s.y -= 13;
      }
      _kopfzeile(s, ['Datum', 'Stand ${ab.einheit}', 'Verbrauch', if (d.wahl.vorjahr) 'Vorjahr']);
      if (t.zeilen.isEmpty) {
        s.text('Keine Stände in diesem Zeitraum.', links, 9.5, farbe: _cMuted);
        s.y -= 14;
      }
      for (final z in t.zeilen) {
        s.platz(16);
        s.text(z.datum, links, 9.5);
        s.text(z.stand, links + 190, 9.5, rechts: true);
        s.text(z.verbrauch, links + 280, 9.5, rechts: true);
        if (d.wahl.vorjahr) s.text(z.vorjahr, links + 370, 9.5, rechts: true, farbe: _cMuted);
        if (z.vermerk.isNotEmpty) s.text(z.vermerk, links + 385, 8, farbe: _cMuted);
        s.y -= 13.5;
      }
      s.y -= 6;
    }

    // Verbrauch je Monat: Balken und Tabelle
    if (ab.monate.isNotEmpty) {
      s.platz(130);
      s.text('Verbrauch je Monat (${ab.einheit})', links, 10, fett: true);
      s.y -= 8;
      const hoehe = 56.0;
      var max = 1;
      for (final m in ab.monate) {
        if ((m.milli ?? 0) > max) max = m.milli!;
        if ((m.vorjahrMilli ?? 0) > max) max = m.vorjahrMilli!;
      }
      final n = ab.monate.length;
      final bw = (rechts - links) / n;
      final boden = s.y - hoehe;
      for (var i = 0; i < n; i++) {
        final m = ab.monate[i];
        final x = links + i * bw + bw * 0.12;
        final w = bw * 0.76;
        if (m.vorjahrMilli != null && m.vorjahrMilli! > 0) s.rahmen(x, boden, w, hoehe * m.vorjahrMilli! / max, _cVorjahr);
        if (m.milli != null && m.milli! > 0) s.fuellen(x, boden, w, (hoehe * m.milli! / max).clamp(0.8, hoehe), _cText);
        s.text(m.monat.substring(0, 3), x + w / 2 - textBreite(m.monat.substring(0, 3), 7) / 2, 7, farbe: _cMuted, yy: boden - 9);
      }
      s.y = boden - 18;
      if (d.wahl.vorjahr) {
        s.text('Die Umrisse zeigen das Vorjahr.', links, 8, farbe: _cMuted);
        s.y -= 12;
      }
      _kopfzeile(s, ['Monat', 'Verbrauch', if (d.wahl.vorjahr) 'Vorjahr', if (d.wahl.vorjahr) 'Veränd.']);
      for (final m in ab.monate) {
        s.platz(16);
        s.text('${m.monat}${m.teilweise && m.milli != null ? ' *' : ''}', links, 9.5);
        s.text(m.verbrauch, links + 190, 9.5, rechts: true);
        if (d.wahl.vorjahr) {
          s.text(m.vorjahr, links + 280, 9.5, rechts: true, farbe: _cMuted);
          s.text(m.veraenderung, links + 370, 9.5, rechts: true, farbe: _cMuted);
        }
        s.y -= 13.5;
      }
      if (ab.monate.any((m) => m.teilweise && m.milli != null)) {
        s.text('* nicht der ganze Monat ist durch Ablesungen gedeckt', links, 8, farbe: _cMuted);
        s.y -= 12;
      }
      s.y -= 6;
    }

    // Summen
    s.platz(60);
    s.linie(links, rechts, s.y + 6);
    s.y -= 8;
    s.text('Gesamtverbrauch', links, 10.5);
    s.text(ab.gesamt, rechts, 10.5, fett: true, rechts: true);
    s.y -= 14;
    if (ab.vorjahrGesamt != null) {
      s.text('Vorjahreszeitraum', links, 10.5);
      s.text('${ab.vorjahrGesamt}${ab.vorjahrVeraenderung == null || ab.vorjahrVeraenderung!.isEmpty ? '' : ' (${ab.vorjahrVeraenderung})'}', rechts, 10.5, rechts: true);
      s.y -= 14;
    }

    // Kosten
    if (ab.kosten.isNotEmpty) {
      s.platz(30 + ab.kosten.length * 14);
      s.y -= 6;
      s.text(ab.kostenTitel, links, 10, fett: true);
      s.y -= 14;
      for (final (l, w) in ab.kosten) {
        s.platz(16);
        s.text(l, links, 10);
        s.text(w, rechts, 10, rechts: true);
        s.y -= 13.5;
      }
    }
    s.y -= 10;
  }

  // Fuß jeder Seite: Erstellungsdatum, Hinweis, Seitenzahl
  final n = s.seiten.length;
  for (var i = 0; i < n; i++) {
    final seite = s.seiten[i];
    final tmp = _Schreiber();
    tmp.seiten[0] = seite;
    seite.inhalt.write('');
    tmp.linie(links, rechts, 48);
    tmp.text('Erstellt am ${d.erstellt} · Werte laut eigenen Ablesungen', links, 8, farbe: _cMuted, yy: 36);
    tmp.text('Seite ${i + 1} von $n', rechts, 8, farbe: _cMuted, rechts: true, yy: 36);
  }

  // Objekte: 1 Katalog, 2 Seiten, 3..5 Schriften, danach je Seite (Seite, Inhalt), zuletzt Info
  final objekte = <List<int>>[];
  final kinderIds = <int>[];
  const anzahlFest = 5;
  for (var i = 0; i < n; i++) {
    kinderIds.add(anzahlFest + 1 + i * 2);
  }
  objekte.add(latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  objekte.add(latin1.encode('<< /Type /Pages /Kids [${kinderIds.map((e) => '$e 0 R').join(' ')}] /Count $n >>'));
  objekte.add(latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'));
  objekte.add(latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'));
  objekte.add(latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>'));
  for (var i = 0; i < n; i++) {
    final strom = latin1.encode(s.seiten[i].inhalt.toString());
    objekte.add(latin1.encode('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents ${anzahlFest + 2 + i * 2} 0 R >>'));
    objekte.add([...latin1.encode('<< /Length ${strom.length} >>\nstream\n'), ...strom, ...latin1.encode('\nendstream')]);
  }
  objekte.add(latin1.encode('<< /Title (Zaehlerbericht) /Producer (lx-fampad) >>'));
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
  final anz = objekte.length + 1;
  aus.add(latin1.encode('xref\n0 $anz\n0000000000 65535 f \n'));
  for (final st in stellen) {
    aus.add(latin1.encode('${st.toString().padLeft(10, '0')} 00000 n \n'));
  }
  aus.add(latin1.encode('trailer\n<< /Size $anz /Root 1 0 R /Info ${objekte.length} 0 R >>\nstartxref\n$xref\n%%EOF\n'));
  return aus.takeBytes();
}

void _kopfzeile(_Schreiber s, List<String> spalten) {
  s.platz(30);
  const links = _rand;
  s.text(spalten[0], links, 9, fett: true, farbe: _cMuted);
  final xs = [links + 190, links + 280, links + 370];
  for (var i = 1; i < spalten.length; i++) {
    s.text(spalten[i], xs[i - 1], 9, fett: true, farbe: _cMuted, rechts: true);
  }
  s.y -= 4;
  s.linie(links, _breite - _rand, s.y);
  s.y -= 11;
}

/// Hilfe für Tests: die Textstücke einer erzeugten Seite (Inhalt der `( ... ) Tj`-Befehle).
List<String> pdfTextstuecke(Uint8List pdf) {
  final s = latin1.decode(pdf, allowInvalid: true);
  final out = <String>[];
  final re = RegExp(r'\(((?:\\.|[^\\)])*)\) Tj');
  for (final m in re.allMatches(s)) {
    out.add(m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (e) => e.group(1)!));
  }
  return out;
}
