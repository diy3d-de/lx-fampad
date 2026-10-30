// Schnellwahl im Desktop-Layout (Strg+K bzw. Cmd+K, auch über "Bereich suchen" in der Seitenleiste): ein kleines Fenster mit Suchfeld und den Bereichen.
// Gesucht wird nur in den NAMEN der Bereiche (Quelle: `bereichsEintraege` plus Start, Kalender, Chat), nie in Inhalten. Pfeiltasten wählen, Enter öffnet,
// Esc schließt. Das Fenster liegt im Navigator des Inhaltsbereichs (nicht im Wurzel-Navigator), wie alle Unterseiten der Desktop-Shell.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants.dart';
import '../../data/shell/zuletzt_logik.dart';
import '../../ui/widgets.dart';

/// Ein Ziel der Schnellwahl.
class SchnellwahlZiel {
  final String id;
  final String label;
  final IconData icon;

  /// Gruppe als Beschriftung rechts ("Familie", "Zuhause", "Ablage"), null bei Start, Kalender und Chat.
  final String? gruppe;
  final VoidCallback oeffnen;
  const SchnellwahlZiel({required this.id, required this.label, required this.icon, required this.oeffnen, this.gruppe});
}

/// Die Treffer zur Eingabe (höchstens [limit]); ohne Eingabe alle Ziele in ihrer Reihenfolge.
List<SchnellwahlZiel> schnellwahlTreffer(List<SchnellwahlZiel> ziele, String eingabe, {int limit = 8}) => [
  for (final z in ziele)
    if (bereichPasst(z.label, eingabe)) z,
].take(limit).toList();

/// Das Fenster als Route (im Navigator des Inhaltsbereichs zu öffnen, siehe `desktop_shell.dart`).
Route<void> schnellwahlRoute(BuildContext navigatorKontext, List<SchnellwahlZiel> ziele) => DialogRoute<void>(
  context: navigatorKontext,
  barrierLabel: 'Schnellwahl schließen',
  builder: (_) => Schnellwahl(ziele: ziele),
);

class Schnellwahl extends StatefulWidget {
  final List<SchnellwahlZiel> ziele;
  const Schnellwahl({super.key, required this.ziele});

  @override
  State<Schnellwahl> createState() => _SchnellwahlState();
}

class _SchnellwahlState extends State<Schnellwahl> {
  final _eingabe = TextEditingController();
  int _auswahl = 0;

  @override
  void dispose() {
    _eingabe.dispose();
    super.dispose();
  }

  List<SchnellwahlZiel> get _treffer => schnellwahlTreffer(widget.ziele, _eingabe.text);

  void _waehlen(SchnellwahlZiel z) {
    Navigator.of(context).pop();
    z.oeffnen();
  }

  KeyEventResult _taste(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final n = _treffer.length;
    if (n == 0) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _auswahl = (_auswahl + 1) % n);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _auswahl = (_auswahl - 1 + n) % n);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final treffer = _treffer;
    final auswahl = treffer.isEmpty ? 0 : _auswahl.clamp(0, treffer.length - 1);
    return Dialog(
      backgroundColor: kSurface,
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(padding: EdgeInsets.fromLTRB(2, 0, 2, 8), child: MonoLabel('Schnellwahl')),
              Focus(
                onKeyEvent: _taste,
                child: TextField(
                  controller: _eingabe,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  decoration: const InputDecoration(hintText: 'Bereich suchen', prefixIcon: Icon(Icons.search)),
                  onChanged: (_) => setState(() => _auswahl = 0),
                  onSubmitted: (_) {
                    if (treffer.isNotEmpty) _waehlen(treffer[auswahl]);
                  },
                ),
              ),
              const SizedBox(height: 8),
              if (treffer.isEmpty)
                const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Keinen Bereich gefunden.', textAlign: TextAlign.center, style: TextStyle(color: kTextMuted)))
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (i, z) in treffer.indexed)
                        Semantics(
                          button: true,
                          selected: i == auswahl,
                          label: z.gruppe == null ? z.label : '${z.label}, ${z.gruppe}',
                          excludeSemantics: true,
                          child: Material(
                            color: i == auswahl ? kAccentSoft : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              key: ValueKey('schnellwahl:${z.id}'),
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _waehlen(z),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(minHeight: 48),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Row(
                                    children: [
                                      Icon(z.icon, size: 20, color: i == auswahl ? kAccent : kTextMuted),
                                      const SizedBox(width: 12),
                                      Expanded(child: Text(z.label, style: TextStyle(fontWeight: i == auswahl ? FontWeight.w700 : FontWeight.w500))),
                                      if (z.gruppe != null) Text(z.gruppe!, style: const TextStyle(fontSize: 12, color: kTextMuted)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              const Text('Pfeiltasten wählen, Enter öffnet, Esc schließt.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
