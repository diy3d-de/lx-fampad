// Verbrauchs-Diagramm der Zähler (Abschnitt 6l): Balken je Monat mit dem Vorjahr als Hülle dahinter, ohne Diagramm-Paket (CustomPaint). Bedienbar: Berühren und Ziehen (Touch und Maus) wählt einen
// Balken, die Pfeiltasten wechseln ihn (Web und Tastatur), Bedienhilfen bekommen "erhöhen/verringern" und eine Textfassung aller Werte. Farben nur über Konstanten.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants.dart';

/// Ein Balken: [milli] ist der Verbrauch (null = noch offen, nichts gezeichnet), [vorjahrMilli] der Wert des Vorjahres (null = keiner), [teilweise] = nicht ganz von Ständen gedeckt.
class DiagrammBalken {
  final String label;
  final String beschriftung;
  final int? milli;
  final int? vorjahrMilli;
  final bool teilweise;
  const DiagrammBalken({required this.label, required this.beschriftung, this.milli, this.vorjahrMilli, this.teilweise = false});
}

class VerbrauchsDiagramm extends StatefulWidget {
  final List<DiagrammBalken> balken;
  final Color farbe;
  final int? cursor;
  final ValueChanged<int?> onCursor;
  final bool vorjahr;

  /// Text für Bedienhilfen: alle Werte (die Fassung des Wertes am Cursor kommt aus [wertText]).
  final String semantik;
  final String Function(int index) wertText;
  const VerbrauchsDiagramm({super.key, required this.balken, required this.farbe, required this.cursor, required this.onCursor, required this.vorjahr, required this.semantik, required this.wertText});

  @override
  State<VerbrauchsDiagramm> createState() => _VerbrauchsDiagrammState();
}

class _VerbrauchsDiagrammState extends State<VerbrauchsDiagramm> {
  var _fokus = false;
  static const _hoehe = 170.0;

  void _auf(double dx, double breite) {
    final n = widget.balken.length;
    if (n == 0 || breite <= 0) return;
    final i = ((dx / breite) * n).floor().clamp(0, n - 1);
    if (i != widget.cursor) widget.onCursor(i);
  }

  void _schritt(int d) {
    final n = widget.balken.length;
    if (n == 0) return;
    final c = widget.cursor;
    widget.onCursor(c == null ? (d > 0 ? 0 : n - 1) : (c + d).clamp(0, n - 1));
  }

  KeyEventResult _taste(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _schritt(1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _schritt(-1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.home) {
      widget.onCursor(0);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.end) {
      widget.onCursor(widget.balken.length - 1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCursor(null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cursor;
    return Semantics(
      container: true,
      label: widget.semantik,
      value: c == null || c >= widget.balken.length ? null : widget.wertText(c),
      increasedValue: c != null && c + 1 < widget.balken.length ? widget.wertText(c + 1) : null,
      decreasedValue: c != null && c > 0 ? widget.wertText(c - 1) : null,
      onIncrease: () => _schritt(1),
      onDecrease: () => _schritt(-1),
      focusable: true,
      focused: _fokus,
      child: ExcludeSemantics(
        child: Focus(
          onKeyEvent: _taste,
          onFocusChange: (f) => setState(() => _fokus = f),
          child: LayoutBuilder(
            builder: (context, k) => MouseRegion(
              cursor: SystemMouseCursors.precise,
              onHover: (e) => _auf(e.localPosition.dx, k.maxWidth),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  Focus.of(context).requestFocus();
                  _auf(d.localPosition.dx, k.maxWidth);
                },
                onHorizontalDragStart: (d) => _auf(d.localPosition.dx, k.maxWidth),
                onHorizontalDragUpdate: (d) => _auf(d.localPosition.dx, k.maxWidth),
                child: Container(
                  height: _hoehe,
                  decoration: _fokus ? BoxDecoration(border: Border.all(color: kAccent.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(8)) : null,
                  child: CustomPaint(size: Size(k.maxWidth, _hoehe), painter: _Maler(balken: widget.balken, farbe: widget.farbe, cursor: c, vorjahr: widget.vorjahr)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Maler extends CustomPainter {
  final List<DiagrammBalken> balken;
  final Color farbe;
  final int? cursor;
  final bool vorjahr;
  _Maler({required this.balken, required this.farbe, required this.cursor, required this.vorjahr});

  @override
  void paint(Canvas canvas, Size size) {
    const pl = 4.0, pr = 4.0, pt = 10.0, pb = 20.0;
    final n = balken.length;
    if (n == 0) return;
    final flaeche = size.height - pt - pb;
    var max = 1;
    for (final b in balken) {
      if ((b.milli ?? 0) > max) max = b.milli!;
      if (vorjahr && (b.vorjahrMilli ?? 0) > max) max = b.vorjahrMilli!;
    }
    final bw = (size.width - pl - pr) / n;
    final linie = Paint()
      ..color = kBorder
      ..strokeWidth = 1;
    for (var g = 0; g < 3; g++) {
      final y = pt + flaeche * g / 2;
      canvas.drawLine(Offset(pl, y), Offset(size.width - pr, y), linie);
    }
    for (var i = 0; i < n; i++) {
      final b = balken[i];
      final x = pl + i * bw + bw * 0.12;
      final w = bw * 0.76;
      if (vorjahr && b.vorjahrMilli != null && b.vorjahrMilli! > 0) {
        final h = flaeche * b.vorjahrMilli! / max;
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - pb - h, w, h), const Radius.circular(2)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = kTextMuted.withValues(alpha: 0.8),
        );
      }
      if (b.milli != null && b.milli! > 0) {
        final h = flaeche * b.milli! / max;
        final grundFarbe = cursor == i ? kAccent : farbe;
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - pb - h, w, h < 2 ? 2 : h), const Radius.circular(2)), Paint()..color = b.teilweise ? grundFarbe.withValues(alpha: 0.55) : grundFarbe);
      }
      final tp = TextPainter(
        text: TextSpan(text: b.label, style: TextStyle(fontFamily: kFontMono, fontSize: 10, color: cursor == i ? kAccent : kTextMuted)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + w / 2 - tp.width / 2, size.height - pb + 4));
    }
  }

  @override
  bool shouldRepaint(_Maler alt) => alt.cursor != cursor || alt.vorjahr != vorjahr || alt.farbe != farbe || alt.balken != balken;
}
