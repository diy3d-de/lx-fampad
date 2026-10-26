// Sicherheitsereignisse der eigenen Person: Passwort-Reset angefordert oder durchgeführt, kompletter Zugangs-Reset. Nur lesend, nur die eigenen, ohne Inhalte.
// So fällt ein Reset auf, den du nicht selbst ausgelöst hast (zusätzlich zum Push-Hinweis).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/auth/sicherheit_text.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';

class SicherheitEreignisseScreen extends ConsumerStatefulWidget {
  const SicherheitEreignisseScreen({super.key});

  @override
  ConsumerState<SicherheitEreignisseScreen> createState() => _SicherheitEreignisseScreenState();
}

class _SicherheitEreignisseScreenState extends ConsumerState<SicherheitEreignisseScreen> with AktionsZustand<SicherheitEreignisseScreen> {
  List<SicherheitsEreignisDto>? _liste;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
  }

  Future<void> _laden() => ausfuehren(() async {
    final l = await ref.read(apiProvider).sicherheitsEreignisse();
    if (mounted) setState(() => _liste = l);
  });

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d. MMM yyyy, HH:mm', 'de_DE');
    final l = _liste;
    return AuthSeite(
      label: 'Sicherheit',
      titel: 'Sicherheitsereignisse',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Hier steht, wenn dein Passwort zurückgesetzt wurde oder jemand einen Link dafür erstellt hat. '
          'Warst du das nicht, sage es sofort einem Admin und prüfe unter „Angemeldete Geräte“, ob alles stimmt.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (l == null && laeuft) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (l != null)
          for (final e in l)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LxCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(e.art == SicherheitsArt.passwortResetAngefordert ? Icons.link : Icons.lock_reset, color: e.durchAdmin ? kWarn : kAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(sicherheitsEreignisText(e), style: const TextStyle(height: 1.4)),
                          const SizedBox(height: 4),
                          Text(df.format(e.zeit.toLocal()), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        if (l != null && l.isEmpty) const EmptyState(icon: Icons.shield_outlined, title: 'Keine Ereignisse', hint: 'Dein Passwort wurde bisher nicht zurückgesetzt.'),
        const SizedBox(height: 8),
        Center(child: LinkKnopf('Neu laden', icon: Icons.refresh, onPressed: laeuft ? null : _laden)),
      ],
    );
  }
}
