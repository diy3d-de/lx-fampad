// Interaktiver Verlauf (Wetter): Diagramm per CustomPaint (kein Diagramm-Paket) mit Fadenkreuz per Berühren/Ziehen, Maus und Pfeiltasten (Web, Desktop),
// Messgrößen-Chips (nur Größen mit Daten), Zeitraum 24 Stunden / 3 Tage / 7 Tage und einer Textzusammenfassung für Screenreader.
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/wetter/wetter_verlauf.dart';
import '../../ui/widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;

class WetterVerlaufKarte extends StatefulWidget {
  final WetterDto dto;
  const WetterVerlaufKarte({super.key, required this.dto});

  @override
  State<WetterVerlaufKarte> createState() => _WetterVerlaufKarteState();
}

class _WetterVerlaufKarteState extends State<WetterVerlaufKarte> {
  WetterGroesse _groesse = WetterGroesse.temperatur;
  WetterZeitraum _zeitraum = WetterZeitraum.h24;
  int? _cursor;
  final _fokus = FocusNode(debugLabel: 'wetter-verlauf');

  @override
  void dispose() {
    _fokus.dispose();
    super.dispose();
  }

  List<WetterGroesse> get _groessen => [
    for (final g in WetterGroesse.values)
      if (groesseHatDaten(widget.dto, g)) g,
  ];

  void _setze(int? i, int n) => setState(() => _cursor = i?.clamp(0, n - 1));

  KeyEventResult _taste(KeyEvent e, int n) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final aktuell = _cursor ?? (n - 1);
    if (k == LogicalKeyboardKey.arrowLeft) {
      _setze(_cursor == null ? n - 1 : aktuell - 1, n);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _setze(_cursor == null ? n - 1 : aktuell + 1, n);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _setze(aktuell - 6, n);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _setze(aktuell + 6, n);
    } else if (k == LogicalKeyboardKey.home) {
      _setze(0, n);
    } else if (k == LogicalKeyboardKey.end) {
      _setze(n - 1, n);
    } else if (k == LogicalKeyboardKey.escape) {
      _setze(null, n);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final groessen = _groessen;
    if (groessen.isEmpty) {
      return const LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MonoLabel('// verlauf'),
            SizedBox(height: 12),
            Text(
              'Noch zu wenige Messwerte für einen Verlauf.',
              style: TextStyle(color: kTextMuted),
            ),
          ],
        ),
      );
    }
    final g = groessen.contains(_groesse) ? _groesse : groessen.first;
    final zeitraeume = verfuegbareZeitraeume(widget.dto);
    final z = zeitraeume.contains(_zeitraum) ? _zeitraum : zeitraeume.first;
    final punkte = verlaufPunkte(widget.dto, g, z.stunden);
    final mitTag = z != WetterZeitraum.h24;
    final mitWerten = punkte.where((p) => p.wert != null).length;
    final ex = extremeIndizes(punkte);
    final cursor = _cursor != null && _cursor! < punkte.length ? _cursor : null;
    final letzter = punkte.lastWhere(
      (p) => p.wert != null,
      orElse: () => VerlaufPunkt(DateTime(2000), null),
    );
    final zusammenfassung = verlaufZusammenfassung(g, punkte, z);

    String kopfZeit;
    String kopfWert;
    String kopfInfo;
    if (cursor != null) {
      final p = punkte[cursor];
      kopfZeit = '// ${verlaufZeitText(p.zeit, mitTag: mitTag)}';
      kopfWert = wertText(g, p.wert);
      kopfInfo = p.wert == null
          ? 'keine Messung'
          : _zumSchnitt(g, p.wert!, punkte);
    } else {
      kopfZeit = '// jetzt';
      kopfWert = wertText(g, letzter.wert);
      if (ex == null) {
        kopfInfo = '';
      } else if (g.balken) {
        final summe = punkte.fold<double>(0, (s, x) => s + (x.wert ?? 0));
        kopfInfo = 'Summe ${zahlText(summe, 1)} mm';
      } else {
        kopfInfo =
            'Tief ${wertText(g, punkte[ex.tief].wert)} · Hoch ${wertText(g, punkte[ex.hoch].wert)}';
      }
    }

    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in groessen)
                AuswahlKnopf(
                  text: x.bezeichnung,
                  gewaehlt: x == g,
                  onTap: () => setState(() {
                    _groesse = x;
                    _cursor = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            kopfZeit.toUpperCase(),
            style: const TextStyle(
              fontFamily: kFontMono,
              fontSize: 11,
              letterSpacing: 0.9,
              color: kTextMuted,
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                kopfWert,
                style: const TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: kAccent,
                ),
              ),
            ),
          ),
          if (kopfInfo.isNotEmpty)
            Text(
              kopfInfo,
              style: const TextStyle(
                fontFamily: kFontMono,
                fontSize: 11,
                color: kTextMuted,
              ),
            ),
          const SizedBox(height: 8),
          if (mitWerten < 2)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Noch zu wenige Messwerte für einen Verlauf.',
                style: TextStyle(color: kTextMuted),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, box) {
                final n = punkte.length;
                int indexAn(double dx) =>
                    (((dx - _kRand) / (box.maxWidth - 2 * _kRand)) * (n - 1))
                        .round()
                        .clamp(0, n - 1);
                return Semantics(
                  container: true,
                  label: zusammenfassung,
                  // Wert und beide Nachbarn immer gesetzt (Flutter verlangt sie paarweise); ohne Fadenkreuz gilt der jüngste Punkt
                  value: verlaufPunktSprechtext(
                    g,
                    punkte[cursor ?? n - 1],
                    mitTag: mitTag,
                  ),
                  increasedValue: verlaufPunktSprechtext(
                    g,
                    punkte[math.min((cursor ?? n - 1) + 1, n - 1)],
                    mitTag: mitTag,
                  ),
                  decreasedValue: verlaufPunktSprechtext(
                    g,
                    punkte[math.max((cursor ?? n - 1) - 1, 0)],
                    mitTag: mitTag,
                  ),
                  onIncrease: () =>
                      _setze(cursor == null ? n - 1 : cursor + 1, n),
                  onDecrease: () =>
                      _setze(cursor == null ? n - 1 : cursor - 1, n),
                  excludeSemantics: true,
                  child: Focus(
                    focusNode: _fokus,
                    onKeyEvent: (_, e) => _taste(e, n),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.precise,
                      onHover: (e) => _setze(indexAn(e.localPosition.dx), n),
                      onExit: (_) => _setze(null, n),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) {
                          _fokus.requestFocus();
                          final i = indexAn(d.localPosition.dx);
                          _setze(
                            d.kind != PointerDeviceKind.mouse && _cursor == i
                                ? null
                                : i,
                            n,
                          );
                        },
                        onHorizontalDragStart: (d) =>
                            _setze(indexAn(d.localPosition.dx), n),
                        onHorizontalDragUpdate: (d) =>
                            _setze(indexAn(d.localPosition.dx), n),
                        child: SizedBox(
                          key: const ValueKey('wetter-diagramm'),
                          height: 190,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: _VerlaufPainter(
                              punkte: punkte,
                              groesse: g,
                              cursor: cursor,
                              extreme: ex,
                              beschriftung: verlaufZeitText(
                                punkte.first.zeit,
                                mitTag: mitTag,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          if (zeitraeume.length > 1) const SizedBox(height: 8),
          if (zeitraeume.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final x in zeitraeume)
                  AuswahlKnopf(
                    text: x.text,
                    gewaehlt: x == z,
                    onTap: () => setState(() {
                      _zeitraum = x;
                      _cursor = null;
                    }),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Text(
            g.balken
                ? 'Niederschlag je Stunde. Berühren oder ziehen zeigt eine Stunde.'
                : 'Berühren oder ziehen zeigt Zeit und Wert; Pfeiltasten im Browser.',
            style: const TextStyle(fontSize: 12, color: kTextMuted),
          ),
        ],
      ),
    );
  }

  /// "+1,2 zum Schnitt" bzw. "−0,4 zum Schnitt" (Regen: Anteil an der Summe entfällt, dort nichts).
  static String _zumSchnitt(WetterGroesse g, double v, List<VerlaufPunkt> p) {
    if (g.balken) return '';
    final w = [
      for (final x in p)
        if (x.wert != null) x.wert!,
    ];
    if (w.isEmpty) return '';
    final schnitt = w.reduce((a, b) => a + b) / w.length;
    final d = v - schnitt;
    final r = double.parse(d.toStringAsFixed(g.stellen));
    final text = zahlText(r.abs(), g.stellen);
    return '${r > 0 ? '+' : (r < 0 ? '−' : '')}$text zum Schnitt';
  }
}

const double _kRand = 6;

class _VerlaufPainter extends CustomPainter {
  final List<VerlaufPunkt> punkte;
  final WetterGroesse groesse;
  final int? cursor;
  final ({int tief, int hoch})? extreme;
  final String beschriftung;
  _VerlaufPainter({
    required this.punkte,
    required this.groesse,
    required this.cursor,
    required this.extreme,
    required this.beschriftung,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const oben = 14.0;
    const unten = 20.0;
    final n = punkte.length;
    final werte = [
      for (final p in punkte)
        if (p.wert != null) p.wert!,
    ];
    if (n < 2 || werte.length < 2) return;
    var lo = werte.reduce((a, b) => a < b ? a : b);
    var hi = werte.reduce((a, b) => a > b ? a : b);
    if (groesse.balken) {
      lo = 0;
      if (hi < 1) hi = 1;
    } else {
      if (hi - lo < 1e-6) {
        lo -= 1;
        hi += 1;
      }
      final pad = (hi - lo) * 0.15;
      lo -= pad;
      hi += pad;
    }
    final w = size.width - 2 * _kRand;
    final h = size.height - oben - unten;
    double x(int i) => _kRand + w * i / (n - 1);
    double y(double v) => oben + h * (1 - (v - lo) / (hi - lo));
    final raster = Paint()
      ..color = kBorder
      ..strokeWidth = 1;
    for (var g = 0; g < 4; g++) {
      final gy = oben + h * g / 3;
      canvas.drawLine(
        Offset(_kRand, gy),
        Offset(size.width - _kRand, gy),
        raster,
      );
    }
    if (groesse.balken) {
      final bw = (w / n * 0.8).clamp(1.5, 14.0);
      final farbe = Paint()..color = kWetterRegen;
      for (var i = 0; i < n; i++) {
        final v = punkte[i].wert;
        if (v == null || v <= 0) continue;
        final top = y(v);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(x(i) - bw / 2, top, x(i) + bw / 2, oben + h),
            const Radius.circular(1.5),
          ),
          farbe,
        );
      }
    } else {
      final linie = Paint()
        ..color = kAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      Path? pfad;
      int? einzel;
      void abschliessen() {
        if (pfad != null) canvas.drawPath(pfad!, linie);
        if (einzel != null) {
          canvas.drawCircle(Offset(x(einzel!), y(punkte[einzel!].wert!)), 2, Paint()..color = kAccent);
        }
        pfad = null;
        einzel = null;
      }

      var laenge = 0;
      for (var i = 0; i < n; i++) {
        final v = punkte[i].wert;
        if (v == null) {
          abschliessen();
          laenge = 0;
          continue;
        }
        if (laenge == 0) {
          pfad = Path()..moveTo(x(i), y(v));
          einzel = i;
        } else {
          pfad!.lineTo(x(i), y(v));
          einzel = null;
        }
        laenge++;
      }
      abschliessen();
      final e = extreme;
      if (e != null && e.hoch != e.tief) {
        canvas.drawCircle(
          Offset(x(e.hoch), y(punkte[e.hoch].wert!)),
          3.5,
          Paint()..color = kWarn,
        );
        canvas.drawCircle(
          Offset(x(e.tief), y(punkte[e.tief].wert!)),
          3.5,
          Paint()..color = kWetterKalt,
        );
      }
    }
    final c = cursor;
    if (c != null) {
      final cx = x(c);
      final strich = Paint()
        ..color = kText
        ..strokeWidth = 1;
      for (var yy = oben; yy < oben + h; yy += 6) {
        canvas.drawLine(
          Offset(cx, yy),
          Offset(cx, (yy + 3).clamp(oben, oben + h)),
          strich,
        );
      }
      final v = punkte[c].wert;
      if (v != null) {
        canvas.drawCircle(Offset(cx, y(v)), 5, Paint()..color = kBg);
        canvas.drawCircle(
          Offset(cx, y(v)),
          5,
          Paint()
            ..color = kAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    // Beschriftung der Zeitachse: Beginn links, "jetzt" rechts (feste Größe, die Zusammenfassung steht für Screenreader im Text)
    final stil = const TextStyle(
      fontFamily: kFontMono,
      fontSize: 10,
      color: kTextMuted,
    );
    final links = TextPainter(
      text: TextSpan(text: beschriftung, style: stil),
      textDirection: TextDirection.ltr,
    )..layout();
    links.paint(canvas, Offset(_kRand, size.height - links.height - 2));
    final rechts = TextPainter(
      text: TextSpan(text: 'jetzt', style: stil),
      textDirection: TextDirection.ltr,
    )..layout();
    rechts.paint(
      canvas,
      Offset(
        size.width - _kRand - rechts.width,
        size.height - rechts.height - 2,
      ),
    );
  }

  @override
  bool shouldRepaint(_VerlaufPainter old) =>
      old.punkte != punkte ||
      old.cursor != cursor ||
      old.groesse != groesse ||
      old.extreme != extreme;
}
