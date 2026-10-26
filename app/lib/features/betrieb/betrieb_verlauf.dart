// Betrieb, Paket 3 (Nutzung und Verlauf): kleine Verlaufsgrafiken per CustomPaint (kein Diagramm-Paket). Gezeichnet werden nur Zahlen der täglichen Messpunkte; Tage ohne
// Messpunkt bleiben Lücken (nie erfundene Werte). Farben nur über Konstanten, jede Grafik trägt Beschriftung und Zusammenfassung für Screenreader (nie nur Farbe: die Legende
// nennt die Reihen mit Worten).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/betrieb/betrieb_modelle.dart';
import '../../ui/widgets.dart';
import 'betrieb_anzeige.dart';

const _tagMs = 86400000;

/// Werte je Kalendertag (UTC) der letzten [anzahl] Tage bis einschließlich [bis]: Tage ohne Messpunkt (oder ohne Wert) sind null, also eine Lücke.
List<double?> verlaufReihe(List<VerlaufTag> tage, int anzahl, DateTime bis, num? Function(VerlaufTag) wert) {
  final ende = DateTime.utc(bis.year, bis.month, bis.day);
  final byTag = {for (final t in tage) t.tag.millisecondsSinceEpoch ~/ _tagMs: t};
  final endeTag = ende.millisecondsSinceEpoch ~/ _tagMs;
  return [
    for (var i = anzahl - 1; i >= 0; i--)
      () {
        final t = byTag[endeTag - i];
        final w = t == null ? null : wert(t);
        return w?.toDouble();
      }(),
  ];
}

/// Eine Reihe einer Grafik: Werte, Farbe und Bezeichnung für die Legende.
class VerlaufReihe {
  final String name;
  final List<double?> werte;
  final Color farbe;
  const VerlaufReihe({required this.name, required this.werte, required this.farbe});

  double? get letzter {
    for (var i = werte.length - 1; i >= 0; i--) {
      if (werte[i] != null) return werte[i];
    }
    return null;
  }
}

/// Wie die Achse gelegt wird: [null] zählt ab 0 (Anzahlen), [bereich] von Minimum bis Maximum (Größen, damit ein Wachstum sichtbar bleibt).
enum VerlaufAchse { abNull, bereich }

class VerlaufDiagramm extends StatelessWidget {
  final String titel;

  /// Der Wert rechts oben ("zuletzt").
  final String zuletzt;
  final List<VerlaufReihe> reihen;
  final DateTime von;
  final DateTime bis;
  final bool balken;
  final VerlaufAchse achse;

  /// Text zu einem Wert für die Zusammenfassung (z. B. Größe).
  final String Function(double) format;
  const VerlaufDiagramm({
    super.key,
    required this.titel,
    required this.zuletzt,
    required this.reihen,
    required this.von,
    required this.bis,
    required this.format,
    this.balken = false,
    this.achse = VerlaufAchse.abNull,
  });

  /// (kleinster, größter) Wert über alle Reihen; null ohne Werte.
  (double, double)? get spanne {
    double? lo, hi;
    for (final r in reihen) {
      for (final w in r.werte) {
        if (w == null) continue;
        lo = lo == null ? w : math.min(lo, w);
        hi = hi == null ? w : math.max(hi, w);
      }
    }
    return lo == null || hi == null ? null : (lo, hi);
  }

  @override
  Widget build(BuildContext context) {
    final s = spanne;
    final zusammenfassung = s == null
        ? 'noch keine Messpunkte'
        : '${reihen.map((r) => '${r.name} zuletzt ${r.letzter == null ? 'ohne Wert' : format(r.letzter!)}').join(', ')}, kleinster Wert ${format(s.$1)}, größter Wert ${format(s.$2)}';
    return Semantics(
      container: true,
      label: 'Verlauf $titel, ${datumText(von)} bis ${datumText(bis)}: $zusammenfassung',
      excludeSemantics: true,
      child: LxCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: MonoLabel(titel)),
                const SizedBox(width: 8),
                Flexible(child: Text(zuletzt, textAlign: TextAlign.end, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, fontWeight: FontWeight.w700))),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 84,
              child: s == null
                  ? const Center(child: Text('Noch keine Messpunkte', style: TextStyle(fontSize: 12, color: kTextMuted)))
                  : CustomPaint(painter: VerlaufPainter(reihen: reihen, balken: balken, achse: achse, spanne: s), size: Size.infinite),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Text(datumText(von), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 10, color: kTextMuted))),
                if (s != null) Text('${format(s.$1)} bis ${format(s.$2)}', textAlign: TextAlign.center, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 10, color: kTextMuted)),
                Expanded(child: Text(datumText(bis), textAlign: TextAlign.end, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 10, color: kTextMuted))),
              ],
            ),
            if (reihen.length > 1) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final r in reihen)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 10, height: 3, decoration: BoxDecoration(color: r.farbe, borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 6),
                        Text(r.name, style: const TextStyle(fontSize: 12, color: kTextMuted)),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Zeichnet Linien (mit Lücken) oder Balken über die Reihen. Die Achse beginnt bei 0 oder reicht von Minimum bis Maximum.
class VerlaufPainter extends CustomPainter {
  final List<VerlaufReihe> reihen;
  final bool balken;
  final VerlaufAchse achse;
  final (double, double) spanne;
  const VerlaufPainter({required this.reihen, required this.balken, required this.achse, required this.spanne});

  @override
  void paint(Canvas canvas, Size size) {
    final raster = Paint()
      ..color = kBorderSoft
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), raster);
    }
    var lo = achse == VerlaufAchse.abNull ? 0.0 : spanne.$1;
    var hi = spanne.$2;
    if (hi <= lo) {
      // alle Werte gleich: eine Linie mittig bzw. bei Anzahlen mit etwas Luft nach oben
      hi = lo + (achse == VerlaufAchse.abNull ? math.max(1.0, lo) : math.max(1.0, lo.abs() * 0.01));
    }
    if (achse == VerlaufAchse.bereich) {
      final luft = (hi - lo) * 0.08;
      lo -= luft;
      hi += luft;
    }
    final n = reihen.isEmpty ? 0 : reihen.first.werte.length;
    if (n == 0) return;
    double xAt(int i) => n == 1 ? size.width / 2 : size.width * i / (n - 1);
    double yAt(double v) => size.height - (v - lo) / (hi - lo) * size.height;

    for (final r in reihen) {
      if (balken) {
        final breite = math.max(1.5, size.width / n * 0.7);
        final f = Paint()..color = r.farbe.withValues(alpha: 0.85);
        for (var i = 0; i < n; i++) {
          final w = r.werte[i];
          if (w == null) continue;
          final y = yAt(w);
          final x = n == 1 ? size.width / 2 : (size.width - breite) * i / (n - 1) + breite / 2;
          canvas.drawRect(Rect.fromLTRB(x - breite / 2, math.min(y, size.height - 1), x + breite / 2, size.height), f);
        }
        continue;
      }
      final linie = Paint()
        ..color = r.farbe
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final punkt = Paint()..color = r.farbe;
      Path? pfad;
      var laenge = 0;
      void abschliessen(int letzter) {
        if (pfad != null && laenge >= 2) canvas.drawPath(pfad!, linie);
        if (laenge == 1) canvas.drawCircle(Offset(xAt(letzter), yAt(r.werte[letzter]!)), 2.5, punkt);
        pfad = null;
        laenge = 0;
      }

      for (var i = 0; i < n; i++) {
        final w = r.werte[i];
        if (w == null) {
          abschliessen(i - 1);
          continue;
        }
        final p = Offset(xAt(i), yAt(w));
        if (pfad == null) {
          pfad = Path()..moveTo(p.dx, p.dy);
        } else {
          pfad!.lineTo(p.dx, p.dy);
        }
        laenge++;
      }
      abschliessen(n - 1);
    }
  }

  @override
  bool shouldRepaint(VerlaufPainter alt) => alt.reihen != reihen || alt.balken != balken || alt.achse != achse || alt.spanne != spanne;
}

/// Beschriftung zum Einzelwert einer Anzahl.
String anzahlText(double v) => v.round().toString();

/// Größe in Byte als Text (wie die Übersicht).
String groesseWert(double v) => groesseText(v.round());
