// "Startseite anpassen" (Einstellungen, nur dieses Gerät und dieses Layout): Kacheln der Startseite ordnen und ausblenden, ohne Ziehen auf
// der Startseite selbst. Je Kachel: Ziehgriff, Pfeile hoch/runter (mindestens 44 px, für Bedienhilfen und kleine Bildschirme) und ein
// Schalter "anzeigen"; unten "Zurücksetzen" (Standardreihenfolge, alles sichtbar; mit Meldung und "Rückgängig", aus, solange schon Standard ist) und "Fertig". Änderungen gelten sofort.
// Die Warnkarte "Bin ich abgesichert?" steht fest oben und lässt sich weder verschieben noch ausblenden (hier nur als Hinweiszeile).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/startseite/startseite_logik.dart';
import '../../data/startseite/startseite_state.dart';
import '../../ui/widgets.dart';
import 'startseite_verfuegbar.dart';
import 'startseite_widgets.dart';

class StartseiteAnpassenScreen extends ConsumerWidget {
  /// Layout, dessen Kacheln gezeigt werden; null = nach der Breite (ab [kDesktopBreakpoint] Desktop-Raster, sonst Handy-Liste).
  final StartLayout? layout;
  const StartseiteAnpassenScreen({super.key, this.layout});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const StartseiteAnpassenScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = layout ?? (MediaQuery.sizeOf(context).width >= kDesktopBreakpoint ? StartLayout.desktop : StartLayout.mobil);
    final anordnung = ref.watch(startseiteProvider(l));
    final verf = ref.watch(verfuegbarProvider(l));
    final notifier = ref.read(startseiteProvider(l).notifier);
    final geladen = anordnung.geladen;
    // bis der gespeicherte Stand gelesen ist, gibt es keine Bedienelemente (sonst würde eine Änderung auf den Standard statt auf den gespeicherten Stand wirken)
    final ids = geladen ? angeboteneKacheln(reihenfolge: anordnung.reihenfolge, verfuegbar: verf) : const <String>[];
    final titel = {for (final k in l.kacheln) k.id: k};

    Widget eintrag(String id, int i, {bool flach = false}) => _Eintrag(
      key: ValueKey('eintrag:$id'),
      kachel: titel[id]!,
      index: i,
      anzahl: ids.length,
      an: !anordnung.ausgeblendet.contains(id),
      leer: verf.leer.contains(id),
      flach: flach,
      onHoch: i > 0 ? () => unawaited(notifier.schieben(ids, id, -1)) : null,
      onRunter: i < ids.length - 1 ? () => unawaited(notifier.schieben(ids, id, 1)) : null,
      onAn: (v) => unawaited(notifier.anzeigen(id, v)),
    );

    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(tooltip: 'Zurück', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
                    ),
                    Expanded(
                      child: CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                            sliver: SliverList.list(
                              children: [
                                const MonoLabel('// einstellungen'),
                                const SizedBox(height: 4),
                                Semantics(
                                  header: true,
                                  child: const Text(
                                    'Startseite anpassen',
                                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Ordne die Kacheln der ${l.anzeigename} und blende aus, was du nicht brauchst. '
                                  'Das gilt nur für die ${l.anzeigename} dieses Geräts. Auf der Startseite selbst kannst du eine Kachel auch gedrückt halten und ziehen.',
                                  style: const TextStyle(fontSize: 13, color: kTextMuted),
                                ),
                                const SizedBox(height: 16),
                                const _FesterEintrag(),
                              ],
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            sliver: SliverReorderableList(
                              itemCount: ids.length,
                              itemBuilder: (context, i) => Padding(key: ValueKey(ids[i]), padding: const EdgeInsets.only(bottom: 8), child: eintrag(ids[i], i)),
                              proxyDecorator: (child, index, animation) => Align(
                                alignment: Alignment.topCenter,
                                child: SizedBox(width: double.infinity, child: StartseiteGehoben(animation: animation, child: eintrag(ids[index], index, flach: true))),
                              ),
                              onReorderItem: (alt, ziel) {
                                if (ziel == alt) return;
                                final liste = List.of(ids);
                                liste.insert(ziel, liste.removeAt(alt));
                                unawaited(notifier.teilmengeOrdnen(liste));
                              },
                            ),
                          ),
                          if (!geladen) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))))),
                          const SliverToBoxAdapter(child: SizedBox(height: 8)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      // unten, damit die Meldung "Zurückgesetzt" die Knöpfe nicht verdeckt
      bottomNavigationBar: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: geladen && !anordnung.istStandard(l) ? () => unawaited(_aufStandard(context, notifier)) : null,
                      child: const Text('Zurücksetzen'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Fertig'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Setzt die Ansicht zurück und bietet "Rückgängig" an (kein Dialog: die Änderung ist harmlos und umkehrbar).
  Future<void> _aufStandard(BuildContext context, StartseiteNotifier notifier) async {
    final messenger = ScaffoldMessenger.of(context);
    final alt = await notifier.aufStandardSetzen();
    if (alt == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Zurückgesetzt'),
          action: SnackBarAction(label: 'Rückgängig', onPressed: () => unawaited(notifier.wiederherstellen(alt))),
        ),
      );
  }
}

/// Die Warnkarte "Bin ich abgesichert?": fest oben, nur zur Information.
class _FesterEintrag extends StatelessWidget {
  const _FesterEintrag();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      container: true,
      label: 'Bin ich abgesichert? Bleibt fest oben, nicht verschiebbar, erscheint nur bei Problemen',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: kBgElevated, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
        child: const Row(
          children: [
            Icon(Icons.push_pin_outlined, size: 18, color: kTextFaint),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bin ich abgesichert?', style: TextStyle(fontWeight: FontWeight.w600)),
                  Text('bleibt oben, nur bei problemen sichtbar', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
            SizedBox(width: 8),
            StatusPill('fest', color: kTextMuted),
          ],
        ),
      ),
    ),
  );
}

/// Eine Zeile der Liste: Griff, Name, Pfeile, Schalter. Schmal (unter 460 px) stehen die Pfeile in einer zweiten Zeile.
class _Eintrag extends StatelessWidget {
  final StartKachel kachel;
  final int index;
  final int anzahl;
  final bool an;
  final bool leer;

  /// Ohne eigenen Rand und eigene Fläche (im gehobenen Zustand beim Ziehen zeichnet [StartseiteGehoben] beides).
  final bool flach;
  final VoidCallback? onHoch;
  final VoidCallback? onRunter;
  final ValueChanged<bool> onAn;
  const _Eintrag({
    super.key,
    required this.kachel,
    required this.index,
    required this.anzahl,
    required this.an,
    required this.leer,
    required this.flach,
    required this.onHoch,
    required this.onRunter,
    required this.onAn,
  });

  String get _position => 'Position ${index + 1} von $anzahl';

  Widget _pfeil({required bool hoch, required VoidCallback? onTap}) {
    final richtung = hoch ? 'nach oben' : 'nach unten';
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: 'Kachel ${kachel.titel}, $_position, $richtung verschieben',
      excludeSemantics: true,
      onTap: onTap,
      child: IconButton(
        key: ValueKey('${hoch ? 'hoch' : 'runter'}:${kachel.id}'),
        tooltip: hoch ? 'Nach oben' : 'Nach unten',
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        icon: Icon(hoch ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
        onPressed: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final griff = ReorderableDragStartListener(
      index: index,
      child: const MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: ExcludeSemantics(child: SizedBox(width: 44, height: 44, child: Icon(Icons.drag_indicator, color: kTextFaint))),
      ),
    );
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kachel.titel, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(
          !an
              ? 'ausgeblendet'
              : leer
              ? 'gerade nichts anzuzeigen'
              : kachel.hinweis,
          style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
        ),
      ],
    );
    final schalter = MergeSemantics(
      child: Semantics(
        label: 'Kachel ${kachel.titel} anzeigen',
        child: Switch(key: ValueKey('an:${kachel.id}'), value: an, onChanged: onAn),
      ),
    );
    return LayoutBuilder(
      builder: (context, c) {
        final schmal = c.maxWidth < 460;
        final inhalt = schmal
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [griff, const SizedBox(width: 4), Expanded(child: name), const SizedBox(width: 8), schalter]),
                  Row(
                    children: [
                      const SizedBox(width: 48),
                      _pfeil(hoch: true, onTap: onHoch),
                      _pfeil(hoch: false, onTap: onRunter),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_position.toLowerCase(), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted))),
                    ],
                  ),
                ],
              )
            : Row(children: [griff, const SizedBox(width: 4), Expanded(child: name), _pfeil(hoch: true, onTap: onHoch), _pfeil(hoch: false, onTap: onRunter), const SizedBox(width: 8), schalter]);
        return Opacity(
          opacity: an ? 1 : 0.6,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
            decoration: flach ? null : BoxDecoration(color: kSurface.withValues(alpha: 0.7), border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
            child: inhalt,
          ),
        );
      },
    );
  }
}
