// Detailseite Wetter: aktuelle Werte der Station, Min/Max und 24-Stunden-Verlauf (aus der eigenen Zwischenspeicherung des Servers),
// Offline-Stand mit Zeitstempel und der Schalter für die Startseite. Es gibt keine Karte und keine Angaben zum genauen Standort der Station.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';

class WetterScreen extends ConsumerStatefulWidget {
  /// Im Desktop-Layout ein Bereich der Shell (Seitenleiste und Fußzeile bleiben): ohne eigenes Gerüst, ohne Zurück-Pfeil, mit der gemeinsamen Kopfzeile.
  /// Die Shell fragt dann beim Wählen des Bereichs selbst frisch ab.
  final bool eingebettet;
  const WetterScreen({super.key, this.eingebettet = false});

  @override
  ConsumerState<WetterScreen> createState() => _WetterScreenState();
}

class _WetterScreenState extends ConsumerState<WetterScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.eingebettet) return;
    // beim Öffnen frisch abfragen (nicht während des Aufbaus den Zustand ändern)
    Future.microtask(() {
      if (mounted) unawaited(ref.read(wetterProvider.notifier).aktualisieren());
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(wetterProvider);
    final dto = st.dto;
    final a = dto?.aktuell;
    final jetzt = DateTime.now();
    final seite = AuthSeite(
      label: '// wetter',
      titel: dto != null && dto.verfuegbar && dto.ort.isNotEmpty
          ? dto.ort
          : 'Wetter',
      maxBreite: kMaxContentWidth,
      aktionen: [
        IconButton(
          tooltip: 'Aktualisieren',
          icon: st.laedt
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed: st.laedt
              ? null
              : () => unawaited(
                  ref.read(wetterProvider.notifier).aktualisieren(),
                ),
        ),
      ],
      kinder: [
        if (a == null)
          MeldungsBox(
            dto != null && !dto.verfuegbar
                ? 'Das Wetter ist auf dem Server nicht eingeschaltet.'
                : st.fehler
                ? 'Das Wetter konnte nicht geladen werden. Es gibt noch keinen gespeicherten Stand.'
                : st.laedt
                ? 'Das Wetter wird geladen …'
                : 'Es liegen noch keine Messwerte vor.',
            fehler: false,
          )
        else ...[
          _Kopf(st: st, jetzt: jetzt),
          const SizedBox(height: 16),
          _Werte(dto: dto!, a: a),
          const SizedBox(height: 16),
          _Verlauf(dto: dto),
        ],
        const SizedBox(height: 16),
        LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: const Text(
              'Wetter auf der Startseite',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'nur auf diesem Gerät',
              style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 11,
                color: kTextMuted,
              ),
            ),
            value: st.anzeigen,
            onChanged: (v) =>
                unawaited(ref.read(wetterProvider.notifier).anzeigenSetzen(v)),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Messwerte einer Wetterstation in der Nähe. Dein Gerät fragt nur den eigenen Server; abgerufen wird ausschließlich dort.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
    if (!widget.eingebettet) return seite;
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Row(children: [const Expanded(child: TabKopfzeile(title: 'Wetter')), ...seite.aktionen]),
          if (dto != null && dto.verfuegbar && dto.ort.isNotEmpty) ...[const SizedBox(height: 4), MonoLabel('// ${dto.ort}')],
          const SizedBox(height: 16),
          ...seite.kinder,
        ],
      ),
    );
  }
}

class _Kopf extends StatelessWidget {
  final WetterZustand st;
  final DateTime jetzt;
  const _Kopf({required this.st, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final a = st.dto!.aktuell!;
    final stand = wetterStand(st, jetzt);
    final abgerufen = st.abgerufen;
    return LxCard(
      child: Semantics(
        container: true,
        label: 'Temperatur ${temperaturText(a.temperatur)}. ${stand.text}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('// jetzt'),
            const SizedBox(height: 8),
            Text(
              temperaturText(a.temperatur),
              style: const TextStyle(
                fontFamily: kFontMono,
                fontSize: 40,
                fontWeight: FontWeight.w700,
                color: kAccent,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              stand.text,
              style: TextStyle(
                fontFamily: kFontMono,
                fontSize: 12,
                color: stand.warnung ? kWarn : kTextMuted,
              ),
            ),
            if (abgerufen != null)
              Text(
                st.fehler
                    ? 'zuletzt abgerufen ${standText(abgerufen, jetzt)}'
                    : 'abgerufen ${standText(abgerufen, jetzt)}',
                style: const TextStyle(
                  fontFamily: kFontMono,
                  fontSize: 11,
                  color: kTextFaint,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Werte extends StatelessWidget {
  final WetterDto dto;
  final WetterAktuell a;
  const _Werte({required this.dto, required this.a});

  @override
  Widget build(BuildContext context) {
    final zeilen = <(String, String)>[
      if (dto.min24h != null && dto.max24h != null)
        (
          'Min / Max (24 h)',
          '${temperaturText(dto.min24h)} / ${temperaturText(dto.max24h)}',
        ),
      if (a.feuchte != null) ('Luftfeuchte', feuchteText(a.feuchte)),
      if (a.druck != null) ('Luftdruck', druckText(a.druck)),
      if (a.regen1h != null || a.regen24h != null)
        (
          'Regen (1 h / 24 h)',
          '${regenText(a.regen1h)} / ${regenText(a.regen24h)}',
        ),
      if (a.windKmh != null)
        (
          'Wind',
          '${windText(a.windKmh)}${a.windRichtung != null ? ' aus ${windRichtungText(a.windRichtung!)}' : ''}',
        ),
      if (a.boeKmh != null) ('Böen', windText(a.boeKmh)),
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
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        z.$1,
                        style: const TextStyle(color: kTextMuted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 6,
                      child: Text(
                        z.$2,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontFamily: kFontMono,
                          fontSize: 14,
                          color: kTextStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Verlauf extends StatelessWidget {
  final WetterDto dto;
  const _Verlauf({required this.dto});

  @override
  Widget build(BuildContext context) {
    final p = dto.verlauf;
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MonoLabel('// verlauf 24 h'),
          const SizedBox(height: 12),
          if (p.length < 2)
            const Text(
              'Noch zu wenige Messwerte für einen Verlauf.',
              style: TextStyle(color: kTextMuted),
            )
          else
            Semantics(
              container: true,
              label:
                  'Temperaturverlauf der letzten 24 Stunden, von ${temperaturText(dto.min24h)} bis ${temperaturText(dto.max24h)}',
              excludeSemantics: true,
              child: SizedBox(
                height: 140,
                width: double.infinity,
                child: CustomPaint(painter: _VerlaufPainter(p)),
              ),
            ),
        ],
      ),
    );
  }
}

class _VerlaufPainter extends CustomPainter {
  final List<WetterPunkt> punkte;
  _VerlaufPainter(this.punkte);

  @override
  void paint(Canvas canvas, Size size) {
    final temps = punkte.map((p) => p.temperatur);
    var lo = temps.reduce((a, b) => a < b ? a : b);
    var hi = temps.reduce((a, b) => a > b ? a : b);
    if (hi - lo < 2) {
      final mitte = (hi + lo) / 2;
      lo = mitte - 1;
      hi = mitte + 1;
    }
    final t0 = punkte.first.zeit.millisecondsSinceEpoch.toDouble();
    final t1 = punkte.last.zeit.millisecondsSinceEpoch.toDouble();
    final spanne = (t1 - t0) == 0 ? 1.0 : (t1 - t0);
    Offset pos(WetterPunkt p) => Offset(
      (p.zeit.millisecondsSinceEpoch - t0) / spanne * size.width,
      size.height - (p.temperatur - lo) / (hi - lo) * size.height,
    );
    final raster = Paint()
      ..color = kBorder
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), raster);
    }
    final start = pos(punkte.first);
    final pfad = Path()..moveTo(start.dx, start.dy);
    for (final p in punkte.skip(1)) {
      final o = pos(p);
      pfad.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      pfad,
      Paint()
        ..color = kAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(pos(punkte.last), 3.5, Paint()..color = kAccent);
  }

  @override
  bool shouldRepaint(_VerlaufPainter old) => old.punkte != punkte;
}
