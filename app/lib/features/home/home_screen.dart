import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_indicator.dart';
import '../update/update_banner.dart';

/// Start: Begrüßung, Sync-Status, Schnellzugriffe, "Als Nächstes". Phase 0: ohne Daten.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final heute = DateFormat('E, d. MMM', 'de_DE').format(DateTime.now()).toLowerCase();
    final verbunden = sync.status == SyncStatus.synchron;
    final farbe = verbunden ? kTerminal : kTextMuted;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        ScreenHeader(label: '// $heute', title: 'Hallo', actions: const [SyncIndicator()]),
        const SizedBox(height: 20),
        const UpdateAnzeige(),
        Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: farbe.withValues(alpha: 0.08),
            border: Border.all(color: farbe.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(verbunden ? Icons.sync : Icons.cloud_off, size: 16, color: farbe),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  verbunden ? 'synchron' : 'nicht verbunden',
                  style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: farbe),
                ),
              ),
              const Text('phase 0', style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        GridView.count(
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          shrinkWrap: true,
          childAspectRatio: 0.95,
          physics: const NeverScrollableScrollPhysics(),
          children: const [
            _Schnellzugriff('Termin', Icons.calendar_today_outlined),
            _Schnellzugriff('Eintrag', Icons.checklist_outlined),
            _Schnellzugriff('Foto', Icons.image_outlined),
            _Schnellzugriff('Datei', Icons.upload_outlined),
          ],
        ),
        const SizedBox(height: 20),
        const LxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoLabel('// als nächstes'),
              SizedBox(height: 12),
              Text('Keine anstehenden Termine', style: TextStyle(color: kTextMuted)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Schnellzugriff extends StatelessWidget {
  final String label;
  final IconData icon;
  const _Schnellzugriff(this.label, this.icon);

  @override
  Widget build(BuildContext context) => LxCard(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        onTap: () => zeigePhase1Hinweis(context),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: kAccent),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}
