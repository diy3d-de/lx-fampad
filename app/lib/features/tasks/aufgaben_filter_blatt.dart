import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/app_database.dart';
import '../../data/auth/auth_state.dart';
import '../../data/lists/members.dart';
import '../../data/tasks/aufgabe_logik.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../data/tasks/fristen_logik.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'tasks_state.dart';

/// Filter und Anzeige der Aufgaben: mobil ein Bottom-Sheet, im Desktop-Layout ein Seitenpanel rechts (wie im Kalender-Filterblatt).
/// Die Auswahl wirkt sofort auf die Liste; "n Aufgaben zeigen" schließt nur.
Future<void> aufgabenFilterBlattOeffnen(BuildContext context) {
  if (MediaQuery.sizeOf(context).width >= kDesktopBreakpoint) {
    return showGeneralDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      barrierLabel: 'Filter schließen',
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (c, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: kSurface,
          borderRadius: const BorderRadius.horizontal(left: Radius.circular(18)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(width: 340, height: double.infinity, child: const SafeArea(child: _FilterInhalt(panel: true))),
        ),
      ),
      transitionBuilder: (c, anim, _, kind) =>
          SlideTransition(position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)), child: kind),
    );
  }
  return showModalBottomSheet<void>(
    useRootNavigator: false,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => const SafeArea(child: _FilterInhalt(panel: false)),
  );
}

/// Zahl der Aufgaben, die mit der gewählten Ansicht in der Liste stehen.
int _trefferZahl(List<Aufgabe> alle, AufgabenAnsicht a, String? ich) {
  final gefiltert = filtereAufgaben(alle, filter: a.filter, person: a.person, ich: ich);
  return a.filter == AufgabeFilter.fristen ? offeneFristen(gefiltert).length : gefiltert.length;
}

class _FilterInhalt extends ConsumerWidget {
  final bool panel;
  const _FilterInhalt({required this.panel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ansicht = ref.watch(aufgabenAnsichtProvider);
    final n = ref.read(aufgabenAnsichtProvider.notifier);
    final ich = ref.watch(authProvider.select((a) => a.user?.id));
    final daten = ref.watch(aufgabenDatenProvider);
    final personen = ref.watch(mitgliederProvider).value ?? const <UserDto>[];
    final fristen = ansicht.filter == AufgabeFilter.fristen;
    final treffer = _trefferZahl(daten.aufgaben, ansicht, ich);

    final kopf = Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
      child: Row(
        children: [
          const Expanded(child: Text('Filter und Anzeige', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong))),
          IconButton(tooltip: 'Schließen', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
        ],
      ),
    );

    final koerper = ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      children: [
        const SizedBox(height: 8),
        const MonoLabel('Anzeigen'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final f in AufgabeFilter.values) AuswahlKnopf(text: f.label, gewaehlt: ansicht.filter == f, onTap: () => n.filter(f))],
        ),
        if (personen.length > 1) ...[
          const SizedBox(height: 16),
          const MonoLabel('Person'),
          const SizedBox(height: 4),
          _PersonZeile(titel: 'Alle Personen', gewaehlt: ansicht.person == null, leading: const Icon(Icons.groups_outlined, color: kTextMuted), onTap: () => n.person(null)),
          for (final p in personen)
            _PersonZeile(titel: p.displayName, gewaehlt: ansicht.person == p.id, leading: BenutzerAvatar(user: p, size: 32), onTap: () => n.person(p.id)),
        ],
        const SizedBox(height: 16),
        const MonoLabel('Sortieren'),
        const SizedBox(height: 8),
        Opacity(
          opacity: fristen ? 0.45 : 1,
          child: IgnorePointer(
            ignoring: fristen,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final s in AufgabeSortierung.values) AuswahlKnopf(text: s.label, gewaehlt: !fristen && ansicht.sortierung == s, onTap: () => n.sortierung(s))],
            ),
          ),
        ),
        if (fristen) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Fristen sind immer nach Ablauf sortiert.', style: TextStyle(fontSize: 12.5, color: kTextMuted))),
      ],
    );

    final fuss = Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Row(
        children: [
          TextButton(style: TextButton.styleFrom(minimumSize: const Size(44, 48)), onPressed: aktiveAufgabenFilter(ansicht) == 0 ? null : n.zuruecksetzen, child: const Text('Zurücksetzen')),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(44, 48)),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(treffer == 1 ? '1 Aufgabe zeigen' : '$treffer Aufgaben zeigen', textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );

    final spalte = Column(mainAxisSize: panel ? MainAxisSize.max : MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      kopf,
      if (panel) Expanded(child: koerper) else Flexible(child: koerper),
      fuss,
    ]);
    return spalte;
  }
}

class _PersonZeile extends StatelessWidget {
  final String titel;
  final bool gewaehlt;
  final Widget leading;
  final VoidCallback onTap;
  const _PersonZeile({required this.titel, required this.gewaehlt, required this.leading, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: gewaehlt,
    label: titel,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: gewaehlt ? kAccentSoft : null, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            SizedBox(width: 32, height: 32, child: Center(child: leading)),
            const SizedBox(width: 12),
            Expanded(child: Text(titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: gewaehlt ? kAccent : kText))),
            if (gewaehlt) const Icon(Icons.check, size: 20, color: kAccent),
          ],
        ),
      ),
    ),
  );
}
