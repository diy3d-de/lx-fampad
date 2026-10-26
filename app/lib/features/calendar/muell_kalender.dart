// Abfuhrtermine im Kalender (optional, Schalter "Müll" im Filterblatt bzw. in den Müll-Einstellungen, je Gerät, Standard aus): reine Anzeige wie Feiertage
// und Ferien, nie als Termin gespeichert oder synchronisiert. Dezent und ohne echte Termine zu verdrängen: im Monatsraster ein schmaler Streifen am
// unteren Rand der Zelle (auf dem Desktop dazu kleine Symbole), in der Woche Punkte unter der Tageszahl, in Agenda und Tagesblatt Kapseln mit Symbol und Name.
// Alle Farben über [MuellArt.farbe] (Konstanten `kMuell…`).
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_modelle.dart';

/// Beschreibung für Screenreader: "Müll: Bioabfall, Gelber Sack".
String muellKalenderText(List<MuellArt> arten) => 'Müll: ${artenText(arten)}';

/// Schmaler Streifen in den Farben der Arten (Monatsraster, unterer Rand der Zelle).
class MuellStreifen extends StatelessWidget {
  final List<MuellArt> arten;
  final double hoehe;
  const MuellStreifen({super.key, required this.arten, this.hoehe = 3});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: hoehe,
      child: Row(children: [for (final a in arten) Expanded(child: ColoredBox(color: a.farbe))]),
    ),
  );
}

/// Kleine Punkte in den Farben der Arten (Kopf der Wochenansicht).
class MuellPunkte extends StatelessWidget {
  final List<MuellArt> arten;
  final double groesse;
  const MuellPunkte({super.key, required this.arten, this.groesse = 5});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in arten.take(4))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(width: groesse, height: groesse, decoration: BoxDecoration(color: a.farbe, shape: BoxShape.circle)),
          ),
      ],
    ),
  );
}

/// Winzige Symbole der Arten (Monatsraster auf dem Desktop, oben rechts in der Zelle).
class MuellMiniSymbole extends StatelessWidget {
  final List<MuellArt> arten;
  const MuellMiniSymbole({super.key, required this.arten});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(mainAxisSize: MainAxisSize.min, children: [for (final a in arten.take(3)) Padding(padding: const EdgeInsets.only(left: 2), child: Icon(a.icon, size: 13, color: a.farbe))]),
  );
}

/// Kapseln mit Symbol und Name der Abfallarten eines Tages (Agenda, Tagesblatt, Tagespanel); nicht antippbar.
class MuellTagesZeile extends StatelessWidget {
  final List<MuellArt> arten;
  const MuellTagesZeile({super.key, required this.arten});

  @override
  Widget build(BuildContext context) {
    if (arten.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        label: muellKalenderText(arten),
        excludeSemantics: true,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in arten)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: a.farbe.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8), border: Border.all(color: a.farbe.withValues(alpha: 0.35))),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(a.icon, size: 14, color: a.farbe),
                    const SizedBox(width: 6),
                    Flexible(child: Text(a.name, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: a.farbe))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
