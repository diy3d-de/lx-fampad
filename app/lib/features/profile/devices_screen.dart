import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/geraete_anzahl.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'abmelden_pruefung.dart';

/// Geräteliste: alle angemeldeten Geräte, jedes einzeln abmeldbar.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> with AktionsZustand<DevicesScreen> {
  List<DeviceDto>? _geraete;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
  }

  Future<void> _laden() => ausfuehren(() async {
    final g = await ref.read(apiProvider).geraete();
    if (mounted) setState(() => _geraete = g);
    if (mounted) ref.invalidate(geraeteAnzahlProvider);
  });

  Future<void> _abmelden(DeviceDto d) async {
    Future<bool> einfach() async =>
        await showDialog<bool>(useRootNavigator: false,
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Gerät abmelden?'),
            content: Text('"${d.name}" wird abgemeldet und muss sich neu anmelden.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
              TextButton(onPressed: () => Navigator.of(context).pop(true), style: TextButton.styleFrom(foregroundColor: kDanger), child: const Text('Abmelden')),
            ],
          ),
        ) ??
        false;
    // Das eigene Gerät: Rückfrage mit ruhigem Hinweis, dass der Schlüssel bleibt (abmelden_pruefung.dart)
    final ja = d.current
        ? await abmeldenBestaetigen(context, ref,
            titel: 'Dieses Gerät abmelden?',
            text: '"${d.name}" wird abgemeldet. Lokale Daten auf diesem Gerät werden gelöscht.',
            knopf: 'Abmelden')
        : await einfach();
    if (!ja || !mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ausfuehren(() => ref.read(apiProvider).geraetAbmelden(d.id));
    if (!ok) return;
    if (d.current) {
      final e = await ref.read(authProvider.notifier).dieseSitzungBeendet();
      nav.popUntil((r) => r.isFirst);
      if (!e.lokalSauber) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Lokale Daten auf diesem Gerät konnten nicht vollständig gelöscht werden.')));
      }
    } else {
      await neuLadenMitHinweis(() async {
        final g = await ref.read(apiProvider).geraete();
        if (mounted) setState(() => _geraete = g);
        if (mounted) ref.invalidate(geraeteAnzahlProvider);
      });
    }
  }

  IconData _symbol(String platform) => switch (platform) {
    'android' || 'ios' => Icons.phone_android,
    'web' => Icons.language,
    _ => Icons.computer,
  };

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d. MMM, HH:mm', 'de_DE');
    final g = _geraete;
    return AuthSeite(
      label: 'Sitzungen',
      titel: 'Angemeldete Geräte',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (g == null && laeuft)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (g != null)
          for (final d in g)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LxCard(
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                child: Row(
                  children: [
                    Icon(_symbol(d.platform), color: kAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            '${d.platform}${d.appVersion == null ? '' : ' · v${d.appVersion}'}'
                            '${d.lastSeenAt == null ? '' : ' · zuletzt ${df.format(d.lastSeenAt!.toLocal())}'}',
                            style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
                          ),
                          if (d.current) const Padding(padding: EdgeInsets.only(top: 6), child: RollenPille('Dieses Gerät', farbe: kTerminal)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '${d.name} abmelden',
                      icon: const Icon(Icons.logout, color: kDanger),
                      onPressed: laeuft ? null : () => _abmelden(d),
                    ),
                  ],
                ),
              ),
            ),
        if (g != null && g.isEmpty) const EmptyState(icon: Icons.phone_android, title: 'Keine Geräte', hint: 'Es ist kein Gerät angemeldet.'),
      ],
    );
  }
}
