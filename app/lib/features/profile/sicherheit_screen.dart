// Profil > Sicherheit: alles, was mit Anmeldung, Schlüsseln und Geräten der eigenen Person zu tun hat. Oben die Gesamtantwort der Absicherungs-Ampel,
// darunter die bisherigen Seiten unverändert (Passkeys, Passwort, Codes, Absicherung, Verschlüsselung, Geräte, Ereignisse).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/absicherung.dart';
import '../../data/crypto/absicherung_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/recovery_codes_screen.dart';
import '../auth/step_up.dart';
import 'absicherung_screen.dart';
import 'devices_screen.dart';
import 'passkeys_screen.dart';
import 'password_screen.dart';
import 'profile_screen.dart' show EinstellungsZeile;
import 'sicherheit_ereignisse_screen.dart';
import 'verschluesselung_screen.dart';

/// Zeile der Profil-Hauptseite: Sicherheit mit der Antwort der Absicherungs-Ampel als Pille (mit Wort, unbekannt nie grün).
class SicherheitsZeile extends ConsumerWidget {
  final VoidCallback onTap;
  const SicherheitsZeile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(absicherungProvider);
    return Semantics(
      label: 'Sicherheit. Bin ich abgesichert? ${a.wort}',
      child: EinstellungsZeile(
        icon: Icons.shield_outlined,
        titel: 'Sicherheit',
        untertitel: 'Anmelden, Nachrichten-Schutz und Geräte',
        status: StatusPill(a.antwort, color: absicherungFarbe(a.ampel)),
        onTap: onTap,
      ),
    );
  }
}

class SicherheitScreen extends ConsumerStatefulWidget {
  const SicherheitScreen({super.key});

  @override
  ConsumerState<SicherheitScreen> createState() => _SicherheitScreenState();
}

class _SicherheitScreenState extends ConsumerState<SicherheitScreen> with AktionsZustand<SicherheitScreen> {
  @override
  void initState() {
    super.initState();
    // Stand der Verschlüsselung für die Zeilen (Warnung bei Schlüsselwechsel)
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(ref.read(e2eeProvider.notifier).laden()));
  }

  void _oeffne(Widget seite) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => seite));

  Future<bool> _bestaetigen(String titel, String text, String knopf) async =>
      await showDialog<bool>(useRootNavigator: false,
        context: context,
        builder: (_) => AlertDialog(
          title: Text(titel),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: kDanger),
              child: Text(knopf),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _neueCodes() async {
    final ja = await _bestaetigen(
      'Neue Notfall-Codes?',
      'Die bisherigen Codes werden damit ungültig. Die neuen Codes siehst du nur einmal.',
      'Neue Codes erzeugen',
    );
    if (!ja || !mounted) return;
    await ausfuehren(() async {
      final codes = await mitStepUp(context, ref, () => ref.read(apiProvider).neueWiederherstellungscodes());
      if (codes == null || !mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => RecoveryCodesScreen(codes: codes, onFertig: () => ref.read(authProvider.notifier).neuLaden()),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider.select((a) => a.me));
    final a = ref.watch(absicherungProvider);
    return AuthSeite(
      label: 'Profil',
      titel: 'Sicherheit',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        LxCard(
          child: Row(
            children: [
              Icon(Icons.verified_user_outlined, color: absicherungFarbe(a.ampel), size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.wort, style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
                    if (a.ampel != AbsicherungAmpel.unbekannt)
                      Text('Dein Zugang zu den Chats ist auf ${a.wege} von ${a.wegeMoeglich} Wegen gesichert.', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const MonoLabel('Anmeldung'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.fingerprint,
          titel: 'Anmelden ohne Passwort',
          untertitel: me == null ? 'Lädt …' : (me.passkeys == 0 ? 'Noch nicht eingerichtet' : (me.passkeys == 1 ? 'Mit Fingerabdruck, Gesicht oder Gerätesperre' : 'Auf ${me.passkeys} Geräten oder Schlüsseln')),
          status: me != null && me.passkeys > 0 ? const RollenPille('Aktiv', farbe: kTerminal) : null,
          onTap: () => _oeffne(const PasskeysScreen()),
        ),
        EinstellungsZeile(
          icon: Icons.verified_user_outlined,
          titel: 'Passwort und zweiter Schritt',
          untertitel: me == null ? 'Lädt …' : (me.hasPassword && me.hasTotp ? 'Mit Code aus deiner Authenticator-App' : 'Noch nicht eingerichtet'),
          status: me != null && me.hasPassword && me.hasTotp ? const RollenPille('Aktiv', farbe: kTerminal) : null,
          onTap: me == null ? null : () => _oeffne(const PasswordScreen()),
        ),
        EinstellungsZeile(
          icon: Icons.key_outlined,
          titel: 'Notfall-Codes',
          untertitel: me == null ? 'Lädt …' : (me.recoveryCodesRemaining == 1 ? 'Noch 1 Code übrig. Du kannst neue erzeugen.' : 'Noch ${me.recoveryCodesRemaining} Codes übrig. Du kannst neue erzeugen.'),
          onTap: laeuft || me == null ? null : _neueCodes,
        ),
        const SizedBox(height: 4),
        const MonoLabel('Schlüssel und Chat'),
        const SizedBox(height: 8),
        AbsicherungsZeile(onTap: () => _oeffne(const AbsicherungScreen())),
        VerschluesselungsZeile(onTap: () => _oeffne(const VerschluesselungScreen())),
        const SizedBox(height: 4),
        const MonoLabel('Geräte und Ereignisse'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.phone_android,
          titel: 'Angemeldete Geräte',
          untertitel: 'Jedes Gerät einzeln abmelden',
          onTap: () => _oeffne(const DevicesScreen()),
        ),
        EinstellungsZeile(icon: Icons.shield_outlined, titel: 'Sicherheitsereignisse', untertitel: 'Zum Beispiel ein zurückgesetztes Passwort', onTap: () => _oeffne(const SicherheitEreignisseScreen())),
      ],
    );
  }
}
