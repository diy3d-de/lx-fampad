// Einstieg in eine Suche: auf der Startseite die globale Suche (mobil ein Knopf rechts neben dem Sync-Status, im Desktop-Layout ein Feld neben "Neu"), auf der Chat-Liste ein
// Feld für die Suche über alle Chats. Die gemeinsame Kopfzeile der Tabs bleibt unverändert (keine eigenen Aktionen dort).
import 'package:flutter/material.dart';

import '../../constants.dart';
import 'such_screen.dart';

/// Ein Feld, das wie ein Suchfeld aussieht und beim Tippen [onTap] ausführt (die Eingabe selbst geschieht auf der Suchseite).
class SuchFeldKnopf extends StatelessWidget {
  final String label;
  final String semantik;
  final VoidCallback onTap;

  /// Feste Breite (Desktop-Kopf); null = volle Breite.
  final double? breite;
  const SuchFeldKnopf({super.key, required this.label, required this.semantik, required this.onTap, this.breite});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semantik,
    excludeSemantics: true,
    onTap: onTap,
    child: SizedBox(
      width: breite,
      child: Material(
        color: kSurface.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kBorder)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 20, color: kTextMuted),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kTextMuted))),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Quadratischer Such-Knopf (Handy-Startseite, neben dem Sync-Status: kostet keine zusätzliche Zeile); gleicher Rand wie die Streifen und Karten.
class SuchKnopf extends StatelessWidget {
  const SuchKnopf({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Suchen',
    child: Semantics(
      button: true,
      label: 'Suchen in Terminen, Aufgaben und Listen',
      excludeSemantics: true,
      onTap: () => Navigator.of(context).push<void>(SuchScreen.route()),
      child: Material(
        color: kSurface.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kBorder)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push<void>(SuchScreen.route()),
          child: const SizedBox(width: 44, height: 44, child: Icon(Icons.search, size: 22, color: kAccent)),
        ),
      ),
    ),
  );
}

/// Einstieg in die globale Suche (Desktop-Kopf der Startseite).
class SuchEinstieg extends StatelessWidget {
  final double? breite;
  const SuchEinstieg({super.key, this.breite});

  @override
  Widget build(BuildContext context) => SuchFeldKnopf(
    label: 'Suchen …',
    semantik: 'Suchen in Terminen, Aufgaben und Listen',
    breite: breite,
    onTap: () => Navigator.of(context).push<void>(SuchScreen.route()),
  );
}
