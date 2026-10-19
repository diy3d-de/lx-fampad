import 'package:flutter/material.dart';

import '../constants.dart';

/// Seitenhintergrund mit violett-cyanem Schimmer oben, wie auf lx-labs.dev (zwei Radialverläufe).
class LxBackground extends StatelessWidget {
  final Widget child;
  const LxBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(color: kBg),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.4, -1.15),
              radius: 1.1,
              colors: [kNeural.withValues(alpha: kGlowNeuralAlpha), kNeural.withValues(alpha: 0.0)],
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.8, -1.1),
                radius: 0.8,
                colors: [kAccent.withValues(alpha: kGlowAccentAlpha), kAccent.withValues(alpha: 0.0)],
              ),
            ),
            child: child,
          ),
        ),
      );
}

/// Begrenzt die Inhaltsbreite auf [kMaxContentWidth] und zentriert sie (Desktop/Tablet, wie die Anmeldung).
class LxContentWidth extends StatelessWidget {
  final Widget child;
  const LxContentWidth({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kMaxContentWidth), child: child),
      );
}

/// Abschnitts-Label im Terminal-Stil ("// so, 18. okt"): Mono, Großbuchstaben, Cyan.
class MonoLabel extends StatelessWidget {
  final String text;
  final Color color;
  const MonoLabel(this.text, {super.key, this.color = kAccent});

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 0.9, color: color),
      );
}

/// Kopfzeile eines Tabs: Titel (Inter 800, enger Letter-Spacing) und rechts frei wählbare Aktionen.
class ScreenHeader extends StatelessWidget {
  final String title;
  final String? label;
  final List<Widget> actions;
  const ScreenHeader({super.key, required this.title, this.label, this.actions = const []});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label != null) ...[MonoLabel(label!), const SizedBox(height: 4)],
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      );
}

/// Karte wie `.lx-card`: Fläche `surface` (leicht transparent), 1-px-Rand, Radius 14.
class LxCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const LxCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: kSurface.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kBorder)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

/// Leerer Zustand: Symbol, Titel und kurzer Hinweis, zentriert.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  const EmptyState({super.key, required this.icon, required this.title, required this.hint});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: kTextFaint),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: kTextMuted)),
            ],
          ),
        ),
      );
}

/// Hinweis für Bedienelemente, die erst in Phase 1 eine Funktion bekommen.
void zeigePhase1Hinweis(BuildContext context) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Kommt in Phase 1')));
}

/// Kapsel mit Mono-Text, z. B. "● live" (Terminal-Grün) oder "● offline" (gedämpft).
class StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  const StatusPill(this.text, {super.key, this.color = kTerminal});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: color)),
      );
}

/// Runder Avatar: Benutzerbild (Foto oder Platzhalter-Zeichnung) oder, solange es keines gibt oder es nicht lädt, die Initialen
/// in der Personenfarbe. Platzhalter-Zeichnungen sind transparent und sitzen auf der vollen Personenfarbe ([bildAufFarbe]).
/// Mit Daten der Familie baut man ihn über `BenutzerAvatar` (widgets/benutzer_avatar.dart), der das Bild der Person auflöst.
class PersonAvatar extends StatelessWidget {
  final String name;
  final int colorIndex;
  final double size;

  /// Benutzerbild; fehlt es oder lässt es sich nicht laden, zeigt der Kreis die Initialen.
  final ImageProvider<Object>? bild;

  /// Das Bild ist eine transparente Platzhalter-Zeichnung: Hintergrund in voller Personenfarbe statt der blassen Fläche.
  final bool bildAufFarbe;
  const PersonAvatar({super.key, required this.name, required this.colorIndex, this.size = 40, this.bild, this.bildAufFarbe = false});

  @override
  Widget build(BuildContext context) {
    final farbe = personColor(colorIndex);
    final initialen = Center(
      child: Text(personInitials(name), style: TextStyle(fontFamily: kFontMono, fontSize: size * 0.34, fontWeight: FontWeight.w600, color: farbe)),
    );
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bild != null && bildAufFarbe ? farbe : farbe.withValues(alpha: 0.18),
          border: Border.all(color: farbe.withValues(alpha: 0.6)),
        ),
        child: bild == null
            ? initialen
            : Image(
                image: bild!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => initialen,
                frameBuilder: (_, kind, frame, sofort) => frame == null && !sofort ? initialen : kind,
              ),
      ),
    );
  }
}
