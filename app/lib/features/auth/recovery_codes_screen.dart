import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import 'auth_widgets.dart';

/// Zeigt die Wiederherstellungscodes EINMAL. Weiter geht es erst, wenn die Person bestätigt, sie gespeichert zu haben.
/// Android: Bildschirmfoto-Schutz (FLAG_SECURE). Die Zwischenablage wird nur auf ausdrücklichen Klick befüllt.
class RecoveryCodesScreen extends ConsumerStatefulWidget {
  final List<String> codes;

  /// Wird nach der Bestätigung ausgeführt (z. B. Sitzung übernehmen).
  final Future<void> Function() onFertig;

  /// Nach dem Fertig bis zur ersten Seite zurück (Registrierung) statt nur diese Seite zu schließen (neue Codes im Profil).
  final bool zurWurzel;
  final String weiterText;

  const RecoveryCodesScreen({super.key, required this.codes, required this.onFertig, this.zurWurzel = false, this.weiterText = 'Weiter'});

  @override
  ConsumerState<RecoveryCodesScreen> createState() => _RecoveryCodesScreenState();
}

class _RecoveryCodesScreenState extends ConsumerState<RecoveryCodesScreen> with AktionsZustand<RecoveryCodesScreen> {
  bool _gespeichert = false;

  Future<void> _weiter() async {
    final ok = await ausfuehren(widget.onFertig);
    if (!ok || !mounted) return;
    final nav = Navigator.of(context);
    if (widget.zurWurzel) {
      nav.popUntil((r) => r.isFirst);
    } else {
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false, // erst nach der Bestätigung weiter: die Codes werden nie wieder angezeigt
    child: BildschirmSchutz(
      child: AuthSeite(
        zurueck: false,
        label: '// einmalig',
        titel: 'Wiederherstellungscodes',
        kinder: [
          const Text(
            'Mit diesen Codes kommst du wieder in dein Konto, wenn du Passkey oder Authenticator verlierst. '
            'Jeder Code gilt nur einmal. Sie werden nur jetzt angezeigt.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Wiederherstellungscodes, ${widget.codes.length} Stück',
            child: LxCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final c in widget.codes)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(
                        c,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontFamily: kFontMono, fontSize: 16, letterSpacing: 1.2, color: kAccent),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ZweitKnopf(
            text: 'Alle Codes kopieren',
            icon: Icons.copy,
            onPressed: () =>
                inZwischenablage(context, widget.codes.join('\n'), 'Codes kopiert. Lege sie sicher ab und lösche sie aus der Zwischenablage.', geheim: true),
          ),
          const SizedBox(height: 8),
          const Text(
            'Speichere die Codes in einem Passwortmanager oder drucke sie aus und bewahre sie sicher auf. '
            'Gib sie nicht weiter und schicke sie nicht unverschlüsselt per Messenger.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _gespeichert,
            onChanged: laeuft ? null : (v) => setState(() => _gespeichert = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('Ich habe die Codes sicher gespeichert.'),
          ),
          if (fehler != null) ...[const SizedBox(height: 8), MeldungsBox(fehler!)],
          const SizedBox(height: 12),
          HauptKnopf(text: widget.weiterText, laeuft: laeuft, onPressed: _gespeichert ? _weiter : null),
        ],
      ),
    ),
  );
}
