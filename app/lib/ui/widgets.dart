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

/// Abschnitts-Beschriftung in Inter (Name stammt aus der Terminal-Zeit, das Widget ist NICHT mehr Mono): Satzschreibung, 13 px, w600, `kTextMuted`.
/// Ein führendes "// " wird entfernt und der erste Buchstabe groß geschrieben (der Rest bleibt unverändert, Eigennamen wie "Wi-Fi" bleiben).
/// Für echte Codes (Sicherheitscode, Schlüssel, Seriennummern) bleibt `kFontMono`.
class MonoLabel extends StatelessWidget {
  final String text;
  final Color color;
  const MonoLabel(this.text, {super.key, this.color = kTextMuted});

  @override
  Widget build(BuildContext context) => Text(
        beschriftungText(text),
        style: TextStyle(fontFamily: kFontSans, fontSize: 13, fontWeight: FontWeight.w600, color: color),
      );
}

/// Beschriftung in Satzschreibung: führendes "// " weg; der erste Buchstabe wird nur groß, wenn er klein ist und das zweite Zeichen
/// kein Großbuchstabe ist (also nie "KWh" aus "kWh" oder "IPhone" aus "iPhone"). Ziffer, "ß" (würde zu "SS") und Emoji bleiben unverändert.
String beschriftungText(String roh) {
  var s = roh.startsWith('// ') ? roh.substring(3) : (roh.startsWith('//') ? roh.substring(2) : roh);
  s = s.trimLeft();
  if (s.isEmpty) return s;
  final zeichen = s.characters;
  final erstes = zeichen.first;
  final gross = erstes.toUpperCase();
  if (gross == erstes || gross.characters.length != 1) return s;
  final rest = zeichen.skip(1);
  if (rest.isNotEmpty) {
    final zweites = rest.first;
    if (zweites != zweites.toLowerCase() && zweites == zweites.toUpperCase()) return s;
  }
  return gross + rest.toString();
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

/// Karte: Fläche `surface` ohne Rand (Trennung nur durch die Flächenfarbe), Radius 18, keine Schatten. Nur die gewählte Karte trägt einen Akzentrand.
class LxCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Hervorgehoben (Akzentrand), z. B. die Konto-Kachel der Seitenleiste, solange die Konto-Seite offen ist.
  final bool gewaehlt;
  const LxCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.gewaehlt = false});

  @override
  Widget build(BuildContext context) => Material(
        color: gewaehlt ? kAccentSoft : kSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: gewaehlt ? const BorderSide(color: kAccent) : BorderSide.none),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

/// Leerer Zustand: Symbol, Titel und kurzer Hinweis, zentriert.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;

  /// Optionaler nächster Schritt als Knopf (Beschriftung und Aktion gehören zusammen).
  final String? knopf;
  final VoidCallback? onKnopf;
  const EmptyState({super.key, required this.icon, required this.title, required this.hint, this.knopf, this.onKnopf});

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
              if (knopf != null && onKnopf != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onKnopf, child: Text(knopf!)),
              ],
            ],
          ),
        ),
      );
}

/// Kapsel mit Text in Inter, z. B. "Live" (Grün) oder "Offline" (gedämpft); ohne Rand.
class StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  const StatusPill(this.text, {super.key, this.color = kTerminal});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: color)),
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
      child: Text(personInitials(name), style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: size * 0.34, fontWeight: FontWeight.w600, color: farbe)),
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
