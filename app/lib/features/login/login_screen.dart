import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';

/// Platzhalter-Anmeldung wie im Mockup (Passkey, Passwort). Phase 0: keine Prüfung, keine Netzwerkaufrufe.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const MonoLabel('// anmelden'),
                const SizedBox(height: 4),
                const Text(
                  'Familienzentrale',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.7, color: kTextStrong),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () => zeigePhase1Hinweis(context),
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Mit Passkey anmelden'),
                ),
                const SizedBox(height: 20),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: MonoLabel('oder mit passwort', color: kTextMuted)),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 20),
                const TextField(
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: [AutofillHints.username],
                  decoration: InputDecoration(labelText: 'E-Mail'),
                ),
                const SizedBox(height: 12),
                const TextField(
                  obscureText: true,
                  autofillHints: [AutofillHints.password],
                  decoration: InputDecoration(labelText: 'Passwort'),
                ),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: () => zeigePhase1Hinweis(context), child: const Text('Weiter')),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: ref.read(authProvider.notifier).signInPreview,
                  child: const Text('Vorschau ohne Anmeldung (Phase 0)'),
                ),
                const SizedBox(height: 12),
                const Center(child: StatusPill('● familie.lx-labs.dev · tls 1.3')),
              ],
            ),
          ),
        ),
      );
}
