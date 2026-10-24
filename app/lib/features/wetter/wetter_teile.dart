// Bausteine der erweiterten Wetterseite: Kacheln (Temperatur, gefühlt, Feuchte, Druck), Regen je Stunde, Wind-Kompass, Vergleich Heute/Gestern/Woche und
// Sonnenzeiten. Jeder Baustein erscheint nur, wenn die Daten da sind (ältere Server ohne Stundenreihen zeigen weniger).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/wetter/wetter_logik.dart';
import '../../data/wetter/wetter_state.dart';
import '../../data/wetter/wetter_verlauf.dart' show zahlText;
import '../../ui/widgets.dart';

/// Eine Kachel: Beschriftung, Wert, Zusatz. [farbe] färbt den Zusatz (Trend).
class _Kachel extends StatelessWidget {
  final String label;
  final String wert;
  final String? zusatz;
  final Color zusatzFarbe;
  final String semantik;
  const _Kachel({required this.label, required this.wert, this.zusatz, this.zusatzFarbe = kTextMuted, required this.semantik});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semantik,
    excludeSemantics: true,
    child: LxCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 0.9, color: kTextMuted)),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(fit: BoxFit.scaleDown, child: Text(wert, style: const TextStyle(fontFamily: kFontMono, fontSize: 20, fontWeight: FontWeight.w700, color: kTextStrong))),
            ),
            if (zusatz != null) Text(zusatz!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: zusatzFarbe)),
          ],
        ),
      ),
    ),
  );
}

/// Steigend warm (gelb), fallend kalt (hellblau), stabil neutral.
Color _trendFarbe(Trend? t) => t == null || t.richtung == TrendRichtung.stabil ? kTextMuted : (t.richtung == TrendRichtung.steigt ? kWarn : kWetterKalt);

/// Zwei Spalten; ab Textskala 1,75 eine (sonst läuft der Text über).
class WetterKacheln extends StatelessWidget {
  final WetterDto dto;
  const WetterKacheln({super.key, required this.dto});

  @override
  Widget build(BuildContext context) {
    final a = dto.aktuell!;
    final tt = temperaturTrend(dto.stunden);
    final dt = druckTrend(dto.stunden);
    final gefuehlt = gefuehlteTemperatur(temperatur: a.temperatur, feuchte: a.feuchte, windKmh: a.windKmh);
    final td = taupunkt(temperatur: a.temperatur, feuchte: a.feuchte);
    String gefuehltZusatz() {
      final t = a.temperatur!;
      if (t <= 10 && (a.windKmh ?? 0) > 4.8) return 'Wind ${windText(a.windKmh)}';
      if (t >= 27 && (a.feuchte ?? 0) >= 40) return 'Hitzeindex';
      return 'wie gemessen';
    }

    final kacheln = <Widget>[
      if (a.temperatur != null)
        _Kachel(
          label: 'Temperatur',
          wert: temperaturKurz(a.temperatur),
          zusatz: tt == null ? null : trendTemperaturText(tt),
          zusatzFarbe: _trendFarbe(tt),
          semantik: 'Temperatur ${temperaturText(a.temperatur)}${tt == null ? '' : ', ${trendSprechtext(tt, 'Grad')}'}',
        ),
      if (gefuehlt != null && a.temperatur != null)
        _Kachel(label: 'Gefühlt', wert: temperaturKurz(gefuehlt), zusatz: gefuehltZusatz(), semantik: 'Gefühlte Temperatur ${temperaturText(double.parse(gefuehlt.toStringAsFixed(1)))}, ${gefuehltZusatz()}'),
      if (a.feuchte != null)
        _Kachel(
          label: 'Luftfeuchte',
          wert: feuchteText(a.feuchte),
          zusatz: td == null ? null : 'Taupunkt ${temperaturKurz(td)}',
          semantik: 'Luftfeuchte ${feuchteText(a.feuchte)}${td == null ? '' : ', Taupunkt ${temperaturText(double.parse(td.toStringAsFixed(1)))}'}',
        ),
      if (a.druck != null)
        _Kachel(
          label: 'Luftdruck',
          wert: druckText(a.druck),
          zusatz: dt == null ? null : trendDruckText(dt),
          zusatzFarbe: _trendFarbe(dt),
          semantik: 'Luftdruck ${druckText(a.druck)}${dt == null ? '' : ', ${trendSprechtext(dt, 'hPa')}'}',
        ),
    ];
    if (kacheln.isEmpty) return const SizedBox.shrink();
    final skala = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, box) {
        final breit = skala >= 1.75 ? box.maxWidth : (box.maxWidth - 8) / 2;
        return Wrap(spacing: 8, runSpacing: 8, children: [for (final k in kacheln) SizedBox(width: breit, child: k)]);
      },
    );
  }
}

/// Temperatur mit Grad ohne Einheit-Buchstabe ("11,4°") für die schmalen Kacheln.
String temperaturKurz(double? v) => v == null ? '–' : '${zahlText(v, 1)}°';

/// Regen je Stunde der letzten 24 Stunden als Balken, daneben Stunde und 24-Stunden-Summe der Station.
class WetterRegenKarte extends StatelessWidget {
  final WetterDto dto;
  const WetterRegenKarte({super.key, required this.dto});

  @override
  Widget build(BuildContext context) {
    final a = dto.aktuell!;
    final balken = regenLetzte24(dto.stunden);
    if (a.regen1h == null && a.regen24h == null && balken.isEmpty) return const SizedBox.shrink();
    final zeile = '1 h: ${zahlText(a.regen1h ?? 0, 1)} · 24 h: ${zahlText(a.regen24h ?? 0, 1)} mm';
    final summe = balken.fold<double>(0, (s, v) => s + (v ?? 0));
    final nass = balken.where((v) => (v ?? 0) > 0).length;
    final sprech = balken.isEmpty
        ? 'Regen: $zeile'
        : 'Regen je Stunde, letzte 24 Stunden: ${nass == 0 ? 'kein Niederschlag' : 'in $nass Stunden Niederschlag, zusammen ${zahlText(summe, 1)} Millimeter'}. Letzte Stunde ${zahlText(a.regen1h ?? 0, 1)} Millimeter';
    return Semantics(
      container: true,
      label: sprech,
      excludeSemantics: true,
      child: LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('// regen'),
            const SizedBox(height: 4),
            Text(zeile, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
            if (balken.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(height: 56, width: double.infinity, child: CustomPaint(painter: _RegenPainter(balken))),
              const SizedBox(height: 4),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('vor 24 h', style: TextStyle(fontSize: 11, color: kTextMuted)),
                  Text('jetzt', style: TextStyle(fontSize: 11, color: kTextMuted)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RegenPainter extends CustomPainter {
  final List<double?> werte;
  _RegenPainter(this.werte);

  @override
  void paint(Canvas canvas, Size size) {
    final n = werte.length;
    if (n == 0) return;
    var hi = 1.0;
    for (final v in werte) {
      if (v != null && v > hi) hi = v;
    }
    final slot = size.width / n;
    final bw = slot * 0.7;
    final farbe = Paint()..color = kWetterRegen;
    final leer = Paint()..color = kBorder;
    for (var i = 0; i < n; i++) {
      final v = werte[i];
      final cx = slot * (i + 0.5);
      if (v == null || v <= 0) {
        // trocken oder keine Messung: ein dünner Strich am Boden
        canvas.drawRect(Rect.fromLTWH(cx - bw / 2, size.height - 2, bw, 2), leer);
        continue;
      }
      final hoehe = math.max(2.0, v / hi * size.height);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(cx - bw / 2, size.height - hoehe, bw, hoehe), const Radius.circular(2)), farbe);
    }
  }

  @override
  bool shouldRepaint(_RegenPainter old) => old.werte != werte;
}

/// Wind mit Kompass (Pfeil zeigt dorthin, woher der Wind kommt) und Böen.
class WetterWindKarte extends StatelessWidget {
  final WetterAktuell a;
  const WetterWindKarte({super.key, required this.a});

  @override
  Widget build(BuildContext context) {
    final wind = a.windKmh;
    if (wind == null && a.boeKmh == null) return const SizedBox.shrink();
    final richtung = a.windRichtung == null ? null : windRichtungText(a.windRichtung!);
    final text = [if (richtung != null) 'aus $richtung', if (a.boeKmh != null) 'Böen bis ${windText(a.boeKmh)}'].join(' · ');
    return Semantics(
      container: true,
      label: 'Wind ${windText(wind)}${richtung == null ? '' : ' aus ${_richtungLang(richtung)}'}${a.boeKmh == null ? '' : ', Böen bis ${windText(a.boeKmh)}'}',
      excludeSemantics: true,
      child: LxCard(
        child: Row(
          children: [
            if (a.windRichtung != null) ...[SizedBox(width: 96, height: 96, child: CustomPaint(painter: _KompassPainter(a.windRichtung!))), const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const MonoLabel('// wind'),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(fit: BoxFit.scaleDown, child: Text(windText(wind), style: const TextStyle(fontFamily: kFontMono, fontSize: 22, fontWeight: FontWeight.w700, color: kTextStrong))),
                  ),
                  if (text.isNotEmpty) Text(text, style: const TextStyle(fontSize: 12, color: kTextMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _richtungLang(String k) => switch (k) {
  'N' => 'Norden',
  'NO' => 'Nordosten',
  'O' => 'Osten',
  'SO' => 'Südosten',
  'S' => 'Süden',
  'SW' => 'Südwesten',
  'W' => 'Westen',
  _ => 'Nordwesten',
};

class _KompassPainter extends CustomPainter {
  final double grad;
  _KompassPainter(this.grad);

  @override
  void paint(Canvas canvas, Size size) {
    final mitte = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1;
    canvas.drawCircle(mitte, r, Paint()..color = kSurface2);
    canvas.drawCircle(
      mitte,
      r,
      Paint()
        ..color = kBorder
        ..style = PaintingStyle.stroke,
    );
    const stil = TextStyle(fontFamily: kFontMono, fontSize: 10, fontWeight: FontWeight.w700, color: kTextMuted);
    void buchstabe(String t, Offset o) {
      final p = TextPainter(text: TextSpan(text: t, style: stil), textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling)..layout();
      p.paint(canvas, o - Offset(p.width / 2, p.height / 2));
    }

    buchstabe('N', mitte + Offset(0, -r + 8));
    buchstabe('S', mitte + Offset(0, r - 8));
    buchstabe('O', mitte + Offset(r - 8, 0));
    buchstabe('W', mitte + Offset(-r + 8, 0));
    final w = grad * math.pi / 180;
    final spitze = mitte + Offset(math.sin(w), -math.cos(w)) * (r - 20);
    canvas.drawLine(
      mitte,
      spitze,
      Paint()
        ..color = kAccent
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(spitze, 4, Paint()..color = kAccent);
    canvas.drawCircle(mitte, 3, Paint()..color = kAccent);
  }

  @override
  bool shouldRepaint(_KompassPainter old) => old.grad != grad;
}

/// Vergleich Heute/Gestern/Woche und Sonnenzeiten als Zeilen (nur vorhandene). Die Zeile "Letzte 24 h" gibt es auch bei älteren Servern.
class WetterVergleichKarte extends StatelessWidget {
  final WetterDto dto;
  const WetterVergleichKarte({super.key, required this.dto});

  @override
  Widget build(BuildContext context) {
    final jetzt = DateTime.now();
    final v = tagesVergleich(dto, jetzt);
    final w = wochenExtreme(dto.tage);
    String bis(double lo, double hi) => '${temperaturText(lo)} bis ${temperaturText(hi)}';
    final zeilen = <(String, String)>[
      if (dto.min24h != null && dto.max24h != null) ('Min / Max (24 h)', '${temperaturText(dto.min24h)} / ${temperaturText(dto.max24h)}'),
      if (v != null) ('Heute', bis(v.heute.min, v.heute.max)),
      if (v?.gestern != null) ('Gestern', '${bis(v!.gestern!.min, v.gestern!.max)}${v.vergleich == null ? '' : ' (${v.vergleich})'}'),
      if (w != null && dto.tage.length >= 2)
        ('Diese Woche', 'Tief ${temperaturText(w.tief.min)} (${wochentagKurz(w.tief.datum)}) · Hoch ${temperaturText(w.hoch.max)} (${wochentagKurz(w.hoch.datum)})'),
      for (final s in dto.sonne.take(2))
        if (s.aufgang != null && s.untergang != null) (s.datum == heutigerTag(dto, jetzt) ? 'Sonne heute' : 'Sonne morgen', '${s.aufgang} bis ${s.untergang} Uhr'),
    ];
    if (zeilen.isEmpty) return const SizedBox.shrink();
    return LxCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          for (final z in zeilen)
            Semantics(
              container: true,
              label: '${z.$1}: ${z.$2}',
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(flex: 4, child: Text(z.$1, style: const TextStyle(color: kTextMuted))),
                      const SizedBox(width: 8),
                      Expanded(flex: 7, child: Text(z.$2, textAlign: TextAlign.end, style: const TextStyle(fontFamily: kFontMono, fontSize: 13, color: kTextStrong))),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
