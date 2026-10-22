// Gemeinsame Bausteine zum Anpassen der Startseite (Handy-Liste und Desktop-Raster): die "gehobene" Kachel beim Ziehen, die gestrichelte
// Lücke der Zielstelle. Farben nur über Konstanten, keine weichen Schatten.
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../constants.dart';

/// Kachel, die gerade gezogen wird: leicht größer, Akzentrand und hellere Fläche, kein Schatten.
class StartseiteGehoben extends StatelessWidget {
  final Widget child;

  /// Fortschritt des Anhebens 0..1 (Animation des Reorder-Proxys); null = ganz angehoben.
  final Animation<double>? animation;
  const StartseiteGehoben({super.key, required this.child, this.animation});

  Widget _bau(double t) => Transform.scale(
    scale: 1 + 0.03 * t,
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kAccent, width: 1.5),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(14), child: ColoredBox(color: kSurface2, child: child)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = animation;
    // Material: der Proxy liegt im Overlay, dort gibt es sonst weder Textstil noch Tinte
    return Material(
      type: MaterialType.transparency,
      child: a == null ? _bau(1) : AnimatedBuilder(animation: a, builder: (_, _) => _bau(Curves.easeOut.transform(a.value.clamp(0.0, 1.0)))),
    );
  }
}

/// Gestrichelte Lücke an der Stelle, an der die gezogene Kachel landet (Akzentfarbe, leicht getönt).
class StartseiteLuecke extends StatelessWidget {
  final double? hoehe;
  const StartseiteLuecke({super.key, this.hoehe});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      painter: _GestrichelterRand(),
      child: SizedBox(
        height: hoehe,
        width: double.infinity,
        child: const Center(
          child: Text('HIER ABLEGEN', style: TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 0.9, color: kAccent)),
        ),
      ),
    ),
  );
}

class _GestrichelterRand extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(14));
    canvas.drawRRect(rrect, Paint()..color = kAccentSoft);
    final stift = Paint()
      ..color = kAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final pfad = Path()..addRRect(rrect.deflate(0.75));
    for (final PathMetric m in pfad.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, (d + 5).clamp(0, m.length)), stift);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
