// Einstieg in die globale Suche auf der Startseite (mobil eine Zeile unter dem Sync-Status, im Desktop-Layout das Feld neben "Neu"). Die gemeinsame
// Kopfzeile der Tabs bleibt unverändert (keine eigenen Aktionen dort).
import 'package:flutter/material.dart';

import '../../constants.dart';
import 'such_screen.dart';

class SuchEinstieg extends StatelessWidget {
  /// Feste Breite (Desktop-Kopf); null = volle Breite.
  final double? breite;
  const SuchEinstieg({super.key, this.breite});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Suchen in Terminen, Aufgaben und Listen',
    excludeSemantics: true,
    onTap: () => Navigator.of(context).push<void>(SuchScreen.route()),
    child: SizedBox(
      width: breite,
      child: Material(
        color: kSurface.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: kBorder)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push<void>(SuchScreen.route()),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(Icons.search, size: 20, color: kTextMuted),
                  SizedBox(width: 10),
                  Expanded(child: Text('Suchen …', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kTextMuted))),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
