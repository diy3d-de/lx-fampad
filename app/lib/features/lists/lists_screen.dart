import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_indicator.dart';

/// Listen: Reiter Einkauf / Aufgaben / Packliste, Eingabe und leere Liste. Phase 0: ohne Daten.
class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  static const _namen = ['Einkauf', 'Aufgaben', 'Packliste'];
  int _tab = 0;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        children: [
          const ScreenHeader(title: 'Listen', actions: [StatusPill('● offline', color: kTextMuted), SyncIndicator()]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: kSurface, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [for (var i = 0; i < _namen.length; i++) Expanded(child: _reiter(i))]),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  readOnly: true,
                  onTap: () => zeigePhase1Hinweis(context),
                  decoration: InputDecoration(hintText: 'Neuer Eintrag in ${_namen[_tab]}'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Hinzufügen',
                onPressed: () => zeigePhase1Hinweis(context),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const EmptyState(icon: Icons.checklist_outlined, title: 'Noch nichts drauf', hint: 'Listen starten in Phase 1.'),
        ],
      );

  Widget _reiter(int i) {
    final aktiv = i == _tab;
    return Semantics(
      button: true,
      selected: aktiv,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() => _tab = i),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: aktiv ? kAccentSoft : null,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: aktiv ? kAccent.withValues(alpha: 0.4) : Colors.transparent),
          ),
          child: Text(
            _namen[i],
            style: TextStyle(fontSize: 14, fontWeight: aktiv ? FontWeight.w600 : FontWeight.w400, color: aktiv ? kAccent : kTextMuted),
          ),
        ),
      ),
    );
  }
}
