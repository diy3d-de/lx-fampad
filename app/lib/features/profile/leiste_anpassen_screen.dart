// Profil > Startseite und Anzeige > Untere Leiste: welche vier Bereiche in der Leiste stehen (nur Handy-Ansicht, nur dieses Gerät).
// Je Platz: Pfeile hoch/runter (mindestens 44 px) und "Bereich ändern" (Auswahl unter den Bereichen hinter "Mehr"); "Start" bleibt immer in der Leiste.
// "Mehr" ist fest das fünfte Feld. Änderungen gelten sofort; "Zurücksetzen" stellt den Standard her.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/shell/leiste_logik.dart';
import '../../data/shell/leiste_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';

class LeisteAnpassenScreen extends ConsumerWidget {
  const LeisteAnpassenScreen({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const LeisteAnpassenScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(leisteProvider);
    final notifier = ref.read(leisteProvider.notifier);
    final tabs = st.tabs;
    final dahinter = hinterMehr(tabs);
    return AuthSeite(
      label: '// profil · anzeige',
      titel: 'Untere Leiste',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Wähle vier Bereiche für die Leiste. „Mehr“ bleibt immer das fünfte Feld, alles andere liegt dahinter. Das gilt nur für die Handy-Ansicht dieses Geräts.',
          style: TextStyle(fontSize: 13, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        const MonoLabel('// in der leiste'),
        const SizedBox(height: 8),
        if (!st.geladen)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))))
        else ...[
          for (var i = 0; i < tabs.length; i++)
            _Platz(
              key: ValueKey('leiste:${tabs[i]}'),
              nummer: i + 1,
              tab: tabs[i],
              dahinter: dahinter,
              onHoch: i > 0 ? () => unawaited(notifier.schieben(i, -1)) : null,
              onRunter: i < tabs.length - 1 ? () => unawaited(notifier.schieben(i, 1)) : null,
              onErsetzen: (neu) => unawaited(notifier.ersetzen(i, neu)),
            ),
          const _FesterPlatz(),
          const SizedBox(height: 12),
          const MonoLabel('// hinter „mehr“'),
          const SizedBox(height: 8),
          Text(
            dahinter.isEmpty ? 'Fristen, Müll, Wetter, Standort und Suche' : '${dahinter.map((t) => kTabs[t].label).join(', ')}, Fristen, Müll, Wetter, Standort und Suche',
            style: const TextStyle(fontSize: 13, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: !st.istStandard ? () => unawaited(notifier.aufStandardSetzen()) : null,
              child: const Text('Zurücksetzen'),
            ),
          ),
        ],
      ],
    );
  }
}

class _Platz extends StatelessWidget {
  final int nummer;
  final int tab;
  final List<int> dahinter;
  final VoidCallback? onHoch;
  final VoidCallback? onRunter;
  final void Function(int tab) onErsetzen;
  const _Platz({super.key, required this.nummer, required this.tab, required this.dahinter, required this.onHoch, required this.onRunter, required this.onErsetzen});

  @override
  Widget build(BuildContext context) {
    final name = kTabs[tab].label;
    final fest = tab == 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Row(
            children: [
              SizedBox(width: 24, child: Text('$nummer', textAlign: TextAlign.center, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted))),
              const SizedBox(width: 8),
              Icon(kTabs[tab].icon, color: kAccent, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              IconButton(constraints: const BoxConstraints(minWidth: 44, minHeight: 44), tooltip: '$name nach oben', icon: const Icon(Icons.keyboard_arrow_up), onPressed: onHoch),
              IconButton(constraints: const BoxConstraints(minWidth: 44, minHeight: 44), tooltip: '$name nach unten', icon: const Icon(Icons.keyboard_arrow_down), onPressed: onRunter),
              if (fest)
                const SizedBox(width: 44, height: 44, child: Tooltip(message: 'Start bleibt in der Leiste', child: Icon(Icons.lock_outline, size: 18, color: kTextMuted)))
              else
                PopupMenuButton<int>(
                  tooltip: '$name ersetzen',
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: const Icon(Icons.swap_horiz),
                  enabled: dahinter.isNotEmpty,
                  onSelected: onErsetzen,
                  itemBuilder: (_) => [
                    for (final t in dahinter) PopupMenuItem<int>(value: t, height: 48, child: Row(children: [Icon(kTabs[t].icon, size: 20, color: kAccent), const SizedBox(width: 10), Text(kTabs[t].label)])),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FesterPlatz extends StatelessWidget {
  const _FesterPlatz();

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Platz 5: Mehr, fest',
    excludeSemantics: true,
    child: Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: kBgElevated, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
      child: const Row(
        children: [
          SizedBox(width: 24, child: Text('5', textAlign: TextAlign.center, style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted))),
          SizedBox(width: 8),
          Icon(Icons.apps, color: kTextMuted, size: 22),
          SizedBox(width: 10),
          Expanded(child: Text('Mehr', style: TextStyle(fontWeight: FontWeight.w600, color: kTextMuted))),
          StatusPill('fest', color: kTextMuted),
        ],
      ),
    ),
  );
}
