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
        untertitel: 'passkeys, passwort, schlüssel, geräte',
        status: StatusPill('● ${a.antwort}', color: absicherungFarbe(a.ampel)),
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
      'Neue Wiederherstellungscodes?',
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
      label: '// profil',
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
                      Text('${a.wege} von ${a.wegeMoeglich} wegen zum schlüssel', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const MonoLabel('// anmeldung'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.fingerprint,
          titel: 'Passkeys',
          untertitel: me == null ? 'wird geladen …' : (me.passkeys == 0 ? 'keiner eingerichtet' : '${me.passkeys} aktiv'),
          status: me != null && me.passkeys > 0 ? const RollenPille('aktiv', farbe: kTerminal) : null,
          onTap: () => _oeffne(const PasskeysScreen()),
        ),
        EinstellungsZeile(
          icon: Icons.verified_user_outlined,
          titel: 'Passwort und Zwei-Faktor (TOTP)',
          untertitel: me == null ? 'wird geladen …' : (me.hasPassword && me.hasTotp ? 'authenticator-app' : 'nicht eingerichtet'),
          status: me != null && me.hasPassword && me.hasTotp ? const RollenPille('an', farbe: kTerminal) : null,
          onTap: me == null ? null : () => _oeffne(const PasswordScreen()),
        ),
        EinstellungsZeile(
          icon: Icons.key_outlined,
          titel: 'Wiederherstellungscodes',
          untertitel: me == null ? 'wird geladen …' : '${me.recoveryCodesRemaining} übrig · neue erzeugen',
          onTap: laeuft || me == null ? null : _neueCodes,
        ),
        const SizedBox(height: 4),
        const MonoLabel('// schlüssel und chat'),
        const SizedBox(height: 8),
        AbsicherungsZeile(onTap: () => _oeffne(const AbsicherungScreen())),
        VerschluesselungsZeile(onTap: () => _oeffne(const VerschluesselungScreen())),
        const SizedBox(height: 4),
        const MonoLabel('// geräte und ereignisse'),
        const SizedBox(height: 8),
        EinstellungsZeile(
          icon: Icons.phone_android,
          titel: 'Angemeldete Geräte',
          untertitel: 'einzeln abmelden',
          onTap: () => _oeffne(const DevicesScreen()),
        ),
        EinstellungsZeile(icon: Icons.shield_outlined, titel: 'Sicherheitsereignisse', untertitel: 'passwort-resets und hinweise', onTap: () => _oeffne(const SicherheitEreignisseScreen())),
      ],
    );
  }
}
