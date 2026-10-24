// Detailseite Wetter: aktuelle Werte der Station, Min/Max und 24-Stunden-Verlauf (aus der eigenen Zwischenspeicherung des Servers),
// Offline-Stand mit Zeitstempel und der Schalter für die Startseite. Es gibt keine Karte und keine Angaben zum genauen Standort der Station.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/wetter_logik.dart' show gefuehlteTemperatur, regenLetzte24;
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import 'wetter_hinweise_screen.dart';
import 'wetter_teile.dart';
import 'wetter_verlauf_karte.dart';

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
          WetterVerlaufKarte(dto: dto!),
          const SizedBox(height: 16),
          WetterKacheln(dto: dto),
          const SizedBox(height: 16),
          WetterRegenKarte(dto: dto),
          if (dto.aktuell!.regen1h != null || dto.aktuell!.regen24h != null || regenLetzte24(dto.stunden).isNotEmpty) const SizedBox(height: 16),
          WetterWindKarte(a: a),
          if (a.windKmh != null || a.boeKmh != null) const SizedBox(height: 16),
          WetterVergleichKarte(dto: dto),
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
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: LinkKnopf('Wetter-Hinweise einstellen', onPressed: () => unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const WetterHinweiseScreen())))),
        ),
        const SizedBox(height: 4),
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
    final gefuehlt = a.temperatur == null ? null : gefuehlteTemperatur(temperatur: a.temperatur, feuchte: a.feuchte, windKmh: a.windKmh);
    return LxCard(
      child: Semantics(
        container: true,
        label: 'Temperatur ${temperaturText(a.temperatur)}${gefuehlt == null ? '' : ', gefühlt ${temperaturText(gefuehlt)}'}. ${stand.text}',
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
            if (gefuehlt != null) ...[
              const SizedBox(height: 4),
              Text('gefühlt ${temperaturText(gefuehlt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
            ],
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
                  color: kTextMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
