// Die Stecknadel als Bild (PNG): Für die Karte im Web. Dort liegt die Karte als eigenes Browser-Element unter dem Flutter-Zeichenbereich; Nadeln als Flutter-Widgets
// hinken beim Ziehen und Zoomen der Karte um mindestens ein Bild hinterher (die Karte meldet die Bewegung, Flutter zeichnet danach neu). Als Symbol der Karte selbst
// (WebGL, vom Stil aus dem Bild) bleibt die Nadel dagegen im selben Bild an ihrer Stelle. Gezeichnet wird wie das Widget [StandortPin] (Tropfen, Ring, Kopf).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../constants.dart';
import 'standort_pin.dart';

/// Alles, was das Bild einer Nadel bestimmt (dasselbe Bild für gleiche Angaben).
class PinBildAngaben {
  final int farbIndex;
  final String name;

  /// Foto oder Platzhalter-Zeichnung (PNG/JPEG/WebP-Bytes); null: Initialen.
  final Uint8List? kopfBild;
  final bool veraltet;
  final bool gewaehlt;
  final bool eigene;

  /// Platzhalter-Zeichnung (transparent) liegt auf der Personenfarbe, ein Foto nicht.
  final bool bildAufFarbe;
  const PinBildAngaben({required this.farbIndex, required this.name, this.kopfBild, this.bildAufFarbe = false, this.veraltet = false, this.gewaehlt = false, this.eigene = false});

  /// Schlüssel für den Vergleich: ändert sich er, wird ein neues Bild gebraucht.
  String get schluessel => '$farbIndex|$name|$bildAufFarbe|${kopfBild == null ? 0 : kopfBild!.length}|${kopfBild?.fold<int>(0, (a, b) => (a * 31 + b) & 0x7fffffff) ?? 0}|$veraltet|$gewaehlt|$eigene';
}

/// Maßstab des Bildes (Pixel je logischem Pixel); die Karte zeigt es mit 1/[kPinBildMassstab], damit die Nadel scharf bleibt.
const double kPinBildMassstab = 2;

/// Zeichnet die Nadel als PNG ([kPinGroesse] mal [kPinBildMassstab] Pixel); die Spitze liegt auf der Mitte der Unterkante.
Future<Uint8List> pinPng(PinBildAngaben a) async {
  final w = kPinGroesse.width, h = kPinGroesse.height;
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, w * kPinBildMassstab, h * kPinBildMassstab));
  canvas.scale(kPinBildMassstab);
  if (a.veraltet) canvas.saveLayer(ui.Rect.fromLTWH(0, 0, w, h), ui.Paint()..color = const ui.Color(0x99000000));
  PinMaler(fuellung: personColor(a.farbIndex), rand: a.gewaehlt || a.eigene ? kAccent : kTextStrong, randBreite: a.gewaehlt ? 3 : 2).paint(canvas, kPinGroesse);
  final mitte = ui.Offset(w / 2, PinMaler.kopfMitteY);
  const r = kPinBild / 2;
  canvas.save();
  canvas.clipPath(ui.Path()..addOval(ui.Rect.fromCircle(center: mitte, radius: r)));
  // dunkle Scheibe unter dem Bild (wie im Widget): sonst wären die Initialen in der Farbe der Nadel unsichtbar
  canvas.drawCircle(mitte, r, ui.Paint()..color = kSurface);
  ui.Image? bild;
  if (a.kopfBild != null) {
    try {
      final codec = await ui.instantiateImageCodec(a.kopfBild!, targetWidth: (kPinBild * kPinBildMassstab).round());
      try {
        bild = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      bild = null; // unlesbares Bild: Initialen
    }
  }
  final farbe = personColor(a.farbIndex);
  if (bild != null) {
    if (a.bildAufFarbe) canvas.drawCircle(mitte, r, ui.Paint()..color = farbe);
    paintImage(canvas: canvas, rect: ui.Rect.fromCircle(center: mitte, radius: r), image: bild, fit: BoxFit.cover);
  } else {
    canvas.drawCircle(mitte, r, ui.Paint()..color = farbe.withValues(alpha: 0.18));
    final tp = TextPainter(
      text: TextSpan(text: personInitials(a.name), style: TextStyle(fontFamily: kFontMono, fontSize: kPinBild * 0.34, fontWeight: FontWeight.w600, color: farbe)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, mitte - ui.Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }
  canvas.restore();
  if (a.veraltet) canvas.restore();
  final bildFertig = await rec.endRecording().toImage((w * kPinBildMassstab).round(), (h * kPinBildMassstab).round());
  try {
    final bytes = await bildFertig.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    bildFertig.dispose();
    bild?.dispose();
  }
}

/// Trifft ein Tipp auf [tipp] (Bildschirmpunkt) die Nadel, deren Spitze auf [spitze] liegt? Die Nadel steht über der Spitze: Rechteck [kPinGroesse].
bool pinGetroffen(ui.Offset tipp, ui.Offset spitze) {
  final rect = ui.Rect.fromLTRB(spitze.dx - kPinGroesse.width / 2, spitze.dy - kPinGroesse.height, spitze.dx + kPinGroesse.width / 2, spitze.dy);
  return rect.contains(tipp);
}

/// Buch über die Nadel-Bilder im Kartenstil (Web), ohne Karte testbar: je Person genau ein Bild im Stil, nichts doppelt, nichts bleibt liegen.
/// Die Karte erzeugt das Bild, wenn [anfordern] true liefert, und meldet das Ergebnis mit [fertig]; die zurückgegebenen Kennungen entfernt sie aus dem Stil.
class PinBildCache {
  /// Fertig im Stil: Person -> Bild-Kennung.
  final Map<String, String> bereit = {};
  final Map<String, String> _gewuenscht = {};
  final Set<String> _laeuft = {};
  final Set<String> _gescheitert = {};

  /// Die Person soll das Bild [id] zeigen. True: es muss erzeugt werden (läuft noch nicht, ist nicht fertig, schlug nicht schon fehl).
  bool anfordern(String person, String id) {
    _gewuenscht[person] = id;
    if (bereit[person] == id || _laeuft.contains(id) || _gescheitert.contains(id)) return false;
    _laeuft.add(id);
    return true;
  }

  /// Ergebnis der Erzeugung. [ok]: das Bild liegt im Stil. Liefert die Kennungen, die jetzt aus dem Stil zu entfernen sind
  /// (das abgelöste Bild der Person, oder das neue selbst, wenn die Person inzwischen etwas anderes zeigen soll oder weg ist).
  List<String> fertig(String person, String id, {required bool ok}) {
    _laeuft.remove(id);
    if (!ok) {
      _gescheitert.add(id);
      return const [];
    }
    if (_gewuenscht[person] != id) return [id];
    final alt = bereit[person];
    bereit[person] = id;
    return [if (alt != null && alt != id) alt];
  }

  /// Personen, die nicht mehr auf der Karte stehen: ihre Bilder gehören entfernt (Liefert die Kennungen).
  List<String> aufraeumen(Set<String> personen) {
    final weg = [for (final p in {..._gewuenscht.keys, ...bereit.keys}) if (!personen.contains(p)) p];
    final ids = <String>[];
    for (final p in weg) {
      _gewuenscht.remove(p);
      final b = bereit.remove(p);
      if (b != null) ids.add(b);
    }
    return ids;
  }

  /// Neue Karten-Ansicht (anderer Stil): nichts gilt mehr.
  void leeren() {
    bereit.clear();
    _gewuenscht.clear();
    _laeuft.clear();
    _gescheitert.clear();
  }
}
