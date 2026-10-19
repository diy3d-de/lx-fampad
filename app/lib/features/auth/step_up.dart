// Erneute Bestätigung (Step-up) für sensible Aktionen: Passkey oder TOTP-/Wiederherstellungscode.
// Der Server verlangt sie bis 5 Minuten nach der letzten Bestätigung nicht erneut (403 step_up_required).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/auth/auth_state.dart';
import 'auth_widgets.dart';

/// Führt [aktion] aus. Verlangt der Server eine erneute Bestätigung, erscheint der Dialog; nach Erfolg läuft [aktion]
/// genau einmal erneut. Gibt null zurück, wenn die Person die Bestätigung abbricht. Andere Fehler werden weitergereicht.
Future<T?> mitStepUp<T>(BuildContext context, WidgetRef ref, Future<T> Function() aktion) async {
  try {
    return await aktion();
  } on ApiException catch (e) {
    if (!e.istStepUp) rethrow;
  }
  if (!context.mounted) return null;
  // Nicht per Tipp daneben schließbar: sonst bliebe ein laufender Passkey-Dialog ohne Empfänger zurück
  final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => const StepUpDialog());
  if (ok != true) return null;
  return aktion();
}

class StepUpDialog extends ConsumerStatefulWidget {
  const StepUpDialog({super.key});

  @override
  ConsumerState<StepUpDialog> createState() => _StepUpDialogState();
}

class _StepUpDialogState extends ConsumerState<StepUpDialog> with AktionsZustand<StepUpDialog> {
  final _code = TextEditingController();
  final _wiederherstellung = TextEditingController();
  bool _mitWiederherstellungscode = false;

  @override
  void dispose() {
    _code.dispose();
    _wiederherstellung.dispose();
    super.dispose();
  }

  Future<void> _passkey() async {
    final ok = await ausfuehren(() async {
      final api = ref.read(apiProvider);
      final ch = await api.stepUpPasskeyOptionen();
      final antwort = await ref.read(passkeyServiceProvider).bestaetigen(ch.options);
      await api.stepUpPasskey(challengeId: ch.challengeId, antwort: antwort);
    });
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _mitCode() async {
    final ok = await ausfuehren(() async {
      if (_mitWiederherstellungscode) {
        final c = _wiederherstellung.text.trim();
        if (c.isEmpty) throw const EingabeFehler('Bitte gib einen Wiederherstellungscode ein.');
        await ref.read(apiProvider).stepUpCode(wiederherstellungscode: c);
      } else {
        if (!RegExp(r'^\d{6}$').hasMatch(_code.text)) throw const EingabeFehler('Bitte gib den 6-stelligen Code ein.');
        await ref.read(apiProvider).stepUpCode(totp: _code.text);
      }
    });
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider.select((s) => s.me));
    // Ohne Angaben zu den Zugängen (z. B. offline gestartet) beide Wege anbieten
    final passkeys = me == null || me.passkeys > 0;
    final totp = me == null || me.hasTotp;
    final codeSichtbar = totp || _mitWiederherstellungscode || !passkeys;
    // Zurück-Taste/Geste ist gesperrt, solange eine Aktion (z. B. der Passkey-Dialog) läuft
    return PopScope(
      canPop: !laeuft,
      child: AlertDialog(
      title: const Text('Bitte bestätigen'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Für diese Aktion musst du dich noch einmal ausweisen.',
            style: TextStyle(color: kTextMuted, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (passkeys) HauptKnopf(text: 'Mit Passkey bestätigen', icon: Icons.fingerprint, laeuft: laeuft, onPressed: _passkey),
          if (passkeys) const SizedBox(height: 12),
          if (_mitWiederherstellungscode)
            TextField(
              controller: _wiederherstellung,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 16, color: kAccent),
              onSubmitted: (_) => _mitCode(),
              decoration: const InputDecoration(labelText: 'Wiederherstellungscode', hintText: 'XXXX-XXXX-XXXX-XXXX'),
            )
          else if (codeSichtbar)
            CodeFeld(controller: _code, label: 'Code aus der Authenticator-App', onSubmitted: (_) => _mitCode()),
          if (codeSichtbar) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Mit Code bestätigen', onPressed: laeuft ? null : _mitCode),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: LinkKnopf(
              _mitWiederherstellungscode ? 'Code aus der App nutzen' : 'Wiederherstellungscode nutzen',
              onPressed: laeuft
                  ? null
                  : () => setState(() {
                      _mitWiederherstellungscode = !_mitWiederherstellungscode;
                      fehler = null;
                    }),
            ),
          ),
        ],
      ),
      actions: [TextButton(onPressed: laeuft ? null : () => Navigator.of(context).pop(false), child: const Text('Abbrechen'))],
      ),
    );
  }
}
