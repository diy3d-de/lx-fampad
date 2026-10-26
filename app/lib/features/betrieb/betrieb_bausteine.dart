// Gemeinsame Bausteine der Seiten der Betreiber-Ansicht: eine Zeile (Name, Kleinschrift darunter, Pille rechts), eine Liste solcher Zeilen in einer Karte und eine Kachel.
// Touch-Ziele mindestens 44 px, lange Texte brechen um (kein Überlauf bei 360 px und Textskala 1.5), Farben nur über Konstanten.
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';

/// Eine Zeile einer Liste: Name, darunter eine Mono-Zeile mit Einzelheiten, rechts eine Pille oder ein kurzer Wert.
class BetriebZeile extends StatelessWidget {
  final String name;
  final String info;
  final Widget pille;
  const BetriebZeile({super.key, required this.name, required this.info, required this.pille});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(info, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // begrenzt (lange Versionskennungen brechen um, statt die Zeile zu sprengen)
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: pille),
        ],
      ),
    ),
  );
}

/// Zeilen in einer Karte mit feinen Trennlinien.
class BetriebListe extends StatelessWidget {
  final List<Widget> zeilen;
  const BetriebListe(this.zeilen, {super.key});

  @override
  Widget build(BuildContext context) => LxCard(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    child: Column(
      children: [
        for (var i = 0; i < zeilen.length; i++) ...[if (i > 0) const Divider(height: 1, color: kBorderSoft), zeilen[i]],
      ],
    ),
  );
}

/// Ein Abschnitt: Mono-Label, Inhalt, optional eine kleine Erklärung darunter.
class BetriebAbschnitt extends StatelessWidget {
  final String label;
  final Widget kind;
  final String? hinweis;
  const BetriebAbschnitt({super.key, required this.label, required this.kind, this.hinweis});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MonoLabel(label),
      const SizedBox(height: 8),
      kind,
      if (hinweis != null) ...[const SizedBox(height: 4), Text(hinweis!, style: const TextStyle(fontSize: 12, color: kTextMuted))],
    ],
  );
}
