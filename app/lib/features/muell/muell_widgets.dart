// Gemeinsame Bausteine der Müll-Oberfläche: Symbol einer Abfallart (abgerundetes Quadrat in der Farbe der Art, wie im Mockup), Symbolreihe
// und Legende. Farben nur über die Konstanten `kMuell…` (über [MuellArt.farbe]).
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/muell/muell_modelle.dart';

/// Symbol einer Abfallart: Rand und Tönung in der Farbe der Art, Symbol darin. Mit [beschriftet] sagt es Screenreadern den Namen.
class MuellSymbol extends StatelessWidget {
  final MuellArt art;
  final double groesse;
  final bool beschriftet;
  const MuellSymbol(this.art, {super.key, this.groesse = 26, this.beschriftet = false});

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: groesse,
      height: groesse,
      decoration: BoxDecoration(
        color: art.farbe.withValues(alpha: 0.14),
        border: Border.all(color: art.farbe),
        borderRadius: BorderRadius.circular(groesse * 0.29),
      ),
      child: Icon(art.icon, size: groesse * 0.58, color: art.farbe),
    );
    return beschriftet ? Semantics(label: art.name, child: ExcludeSemantics(child: box)) : ExcludeSemantics(child: box);
  }
}

/// Mehrere Symbole nebeneinander (bricht um, nie ein Überlauf bei großer Schrift).
class MuellSymbolReihe extends StatelessWidget {
  final List<MuellArt> arten;
  final double groesse;
  const MuellSymbolReihe(this.arten, {super.key, this.groesse = 26});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [for (final a in arten) MuellSymbol(a, groesse: groesse)]);
}

/// Legende: alle Arten (oder die übergebenen) mit Symbol und Name.
class MuellLegende extends StatelessWidget {
  final List<MuellArt> arten;
  const MuellLegende({super.key, required this.arten});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 16,
    runSpacing: 8,
    children: [
      for (final a in arten)
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 30),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MuellSymbol(a, groesse: 24),
              const SizedBox(width: 8),
              Text(a.name, style: const TextStyle(fontSize: 13, color: kText)),
            ],
          ),
        ),
    ],
  );
}
