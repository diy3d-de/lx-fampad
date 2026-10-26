import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';

/// Passkeys verwalten: auflisten, hinzufügen (mit Step-up) und entfernen (mit Step-up). Der letzte Zugang bleibt (Server: 409).
class PasskeysScreen extends ConsumerStatefulWidget {
  const PasskeysScreen({super.key});

  @override
  ConsumerState<PasskeysScreen> createState() => _PasskeysScreenState();
}

class _PasskeysScreenState extends ConsumerState<PasskeysScreen> with AktionsZustand<PasskeysScreen> {
  List<CredentialDto>? _zugaenge;
  bool? _passkeysDa;

  @override
  void initState() {
    super.initState();
    unawaited(_laden());
    unawaited(
      ref.read(passkeyServiceProvider).verfuegbar().then((v) {
        if (mounted) setState(() => _passkeysDa = v);
      }),
    );
  }

  Future<void> _ladeListe() async {
    final z = await ref.read(apiProvider).zugaenge();
    if (mounted) setState(() => _zugaenge = z);
  }

  Future<void> _laden() async {
    await ausfuehren(_ladeListe);
  }

  Future<void> _hinzufuegen() async {
    var erledigt = false;
    final ok = await ausfuehren(() async {
      final api = ref.read(apiProvider);
      final label = await _geraeteLabel();
      if (!mounted) return;
      // Step-up gilt für das Anfordern der Optionen; der Dialog erscheint, falls die Bestätigung älter als 5 Minuten ist
      final ch = await mitStepUp(context, ref, api.passkeyHinzufuegenOptionen);
      if (ch == null) return;
      final antwort = await ref.read(passkeyServiceProvider).erstellen(ch.options);
      await api.passkeyHinzufuegen(challengeId: ch.challengeId, antwort: antwort, bezeichnung: label);
      erledigt = true;
    });
    // Der Passkey ist angelegt: scheitert nur das Neuladen der Liste, bleibt es ein Erfolg
    if (ok && erledigt && mounted) {
      unawaited(ref.read(authProvider.notifier).neuLaden());
      await neuLadenMitHinweis(_ladeListe, erfolg: 'Passkey hinzugefügt.');
    }
  }

  Future<String?> _geraeteLabel() async {
    final n = (await ref.read(systemChannelProvider).geraetename())?.trim();
    return (n == null || n.isEmpty) ? 'Browser' : n;
  }

  Future<void> _entfernen(CredentialDto c) async {
    final ja = await showDialog<bool>(useRootNavigator: false,
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Passkey entfernen?'),
        content: Text('"${c.label ?? 'Passkey'}" kann danach nicht mehr zur Anmeldung genutzt werden.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), style: TextButton.styleFrom(foregroundColor: kDanger), child: const Text('Entfernen')),
        ],
      ),
    );
    if (ja != true || !mounted) return;
    var erledigt = false;
    final ok = await ausfuehren(() async {
      final api = ref.read(apiProvider);
      final fertig = await mitStepUp<bool>(context, ref, () async {
        await api.passkeyEntfernen(c.id);
        return true;
      });
      erledigt = fertig == true;
    });
    if (ok && erledigt && mounted) {
      unawaited(ref.read(authProvider.notifier).neuLaden());
      await neuLadenMitHinweis(_ladeListe);
    }
  }

  @override
  Widget build(BuildContext context) {
    final passkeys = _zugaenge?.where((c) => c.istPasskey).toList();
    final df = DateFormat('d. MMM yyyy', 'de_DE');
    return AuthSeite(
      label: 'Zugänge',
      titel: 'Anmelden ohne Passwort',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Mit einem Passkey meldest du dich per Fingerabdruck, Gesicht oder Bildschirmsperre an, ohne Passwort. '
          'Richte auf jedem Gerät, das du nutzt, einen eigenen ein.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (_passkeysDa == false) ...[
          const MeldungsBox('Dieses Gerät oder dieser Browser unterstützt kein Anmelden ohne Passwort. Du kannst es auf einem anderen Gerät einrichten.'),
          const SizedBox(height: 12),
        ],
        if (passkeys == null && laeuft)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (passkeys != null && passkeys.isEmpty)
          const EmptyState(icon: Icons.fingerprint, title: 'Noch nicht eingerichtet', hint: 'Richte es ein, um dich ohne Passwort anzumelden.')
        else if (passkeys != null)
          for (final c in passkeys)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LxCard(
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.fingerprint, color: kAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.label ?? 'Passkey', style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            'Angelegt am ${df.format(c.createdAt.toLocal())}${c.lastUsedAt == null ? '' : ', zuletzt benutzt am ${df.format(c.lastUsedAt!.toLocal())}'}',
                            style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Passkey ${c.label ?? ''} entfernen',
                      icon: const Icon(Icons.delete_outline, color: kDanger),
                      onPressed: laeuft ? null : () => _entfernen(c),
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 12),
        HauptKnopf(text: 'Passkey hinzufügen', icon: Icons.add, laeuft: laeuft && passkeys != null, onPressed: _passkeysDa == false ? null : _hinzufuegen),
        const SizedBox(height: 8),
        const Text(
          'Zum Hinzufügen und Entfernen bestätigst du noch einmal mit einem bestehenden Zugang.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}
