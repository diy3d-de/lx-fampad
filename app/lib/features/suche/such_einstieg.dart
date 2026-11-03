// Einstieg in eine Suche: auf der Startseite die globale Suche (mobil ein Feld in voller Breite ganz oben, im Desktop-Layout ein Feld neben "Neu"), auf der Chat-Liste ein
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
        color: kSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

/// Suchfeld in voller Breite (Handy-Startseite, ganz oben unter der Kopfzeile; der Platzhalter sagt, was durchsucht wird).
class SuchKnopf extends StatelessWidget {
  const SuchKnopf({super.key});

  @override
  Widget build(BuildContext context) => SuchFeldKnopf(
    label: 'Suchen in Terminen, Aufgaben, Listen …',
    semantik: 'Suchen in Terminen, Aufgaben und Listen',
    onTap: () => Navigator.of(context).push<void>(SuchScreen.route()),
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
