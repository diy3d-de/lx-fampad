// Banner über dem Inhalt der angemeldeten Oberfläche (Betrieb, Paket 2b): Wartung des Betreibers (nicht wegklickbar, solange sie läuft) und der Familienhinweis des
// Betreibers (reiner Text, je Gerät wegklickbar, läuft von selbst ab). Beides gilt für alle Angemeldeten. Der Text kommt nur aus einem Feld, das die App als reinen Text
// zeigt (nie Markup, nie ein Link); Farben nur über die Konstanten.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../constants.dart';
import '../data/betrieb/familien_hinweis_state.dart';

/// "heute 14:30", sonst "23. okt., 14:30" (Ortszeit).
String endeText(DateTime t, DateTime jetzt) {
  final l = t.toLocal();
  final j = jetzt.toLocal();
  final uhr = DateFormat('HH:mm', 'de_DE').format(l);
  if (l.year == j.year && l.month == j.month && l.day == j.day) return 'heute $uhr';
  return '${DateFormat('d. MMM', 'de_DE').format(l)}, $uhr';
}

class FamilienHinweisBanner extends ConsumerWidget {
  const FamilienHinweisBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(familienHinweisProvider);
    final jetzt = DateTime.now();
    final hinweis = z.sichtbar(jetzt);
    final wartung = z.stand?.wartung;
    if (!z.wartung && hinweis == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (z.wartung)
            _Banner(
              icon: Icons.build_outlined,
              farbe: kWarn,
              text: wartung?.bis == null
                  ? 'Wartung: Die Familienzentrale wird gerade gewartet. Änderungen bleiben auf deinem Gerät und werden danach abgeglichen.'
                  : 'Wartung bis ${endeText(wartung!.bis!, jetzt)}: Änderungen bleiben auf deinem Gerät und werden danach abgeglichen.',
            ),
          if (z.wartung && hinweis != null) const SizedBox(height: 8),
          if (hinweis != null)
            _Banner(
              icon: Icons.campaign_outlined,
              farbe: kAccent,
              text: hinweis.text,
              schliessen: () => ref.read(familienHinweisProvider.notifier).schliessen(),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color farbe;
  final String text;
  final VoidCallback? schliessen;
  const _Banner({required this.icon, required this.farbe, required this.text, this.schliessen});

  @override
  Widget build(BuildContext context) {
    // sehr große Schrift: der Banner nimmt höchstens ein Drittel der Höhe und scrollt darin, der Inhalt darunter bleibt bedienbar
    final maxHoehe = MediaQuery.sizeOf(context).height / 3;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        constraints: BoxConstraints(minHeight: 48, maxHeight: maxHoehe < 96 ? 96 : maxHoehe),
        padding: EdgeInsets.only(left: 14, right: schliessen == null ? 14 : 0),
        decoration: BoxDecoration(color: farbe.withValues(alpha: 0.08), border: Border.all(color: farbe.withValues(alpha: 0.4)), borderRadius: BorderRadius.circular(12)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: farbe),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(text, style: const TextStyle(fontSize: 13, height: 1.35, color: kText)),
              ),
            ),
            if (schliessen != null) IconButton(tooltip: 'Hinweis schließen', constraints: const BoxConstraints(minWidth: 44, minHeight: 44), icon: const Icon(Icons.close, size: 18), onPressed: schliessen),
          ],
        ),
      ),
    );
  }
}
