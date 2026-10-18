import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_indicator.dart';

/// Dateien: Einstiege (Fotos & Alben, Tresor) und leere Liste "zuletzt". Phase 0: ohne Funktion.
class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        children: const [
          ScreenHeader(title: 'Dateien', actions: [SyncIndicator()]),
          SizedBox(height: 16),
          _Einstieg(icon: Icons.photo_library_outlined, titel: 'Fotos & Alben', untertitel: 'folgt in Phase 2'),
          SizedBox(height: 10),
          _Einstieg(icon: Icons.lock_outline, titel: 'Tresor', untertitel: 'nur Eltern · Passkey · Phase 2'),
          SizedBox(height: 20),
          MonoLabel('// zuletzt'),
          SizedBox(height: 12),
          LxCard(child: Text('Noch keine Dateien', style: TextStyle(color: kTextMuted))),
        ],
      );
}

class _Einstieg extends StatelessWidget {
  final IconData icon;
  final String titel;
  final String untertitel;
  const _Einstieg({required this.icon, required this.titel, required this.untertitel});

  @override
  Widget build(BuildContext context) => LxCard(
        onTap: () => zeigePhase1Hinweis(context),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: kAccent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(untertitel, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: kTextFaint),
          ],
        ),
      );
}
