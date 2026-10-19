// Profil und Sicherheit (Mockup "Sicherheit & System"): Zugänge, Wiederherstellungscodes, Geräte, Familie (Admin/Eltern), Abmelden.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../ui/widgets.dart';
import '../admin/admin_screen.dart';
import '../auth/auth_widgets.dart';
import '../auth/recovery_codes_screen.dart';
import '../auth/step_up.dart';
import 'devices_screen.dart';
import 'password_screen.dart';
import 'passkeys_screen.dart';

/// Zeile der Einstellungen: Symbol, Titel, Untertitel (Mono), rechts Status oder Pfeil. Mindestens 56 px hoch.
class EinstellungsZeile extends StatelessWidget {
  final IconData icon;
  final String titel;
  final String? untertitel;
  final Widget? status;
  final VoidCallback? onTap;
  const EinstellungsZeile({super.key, required this.icon, required this.titel, this.untertitel, this.status, this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: LxCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            Icon(icon, color: kAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titel, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (untertitel != null)
                    Text(untertitel!, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
            if (status != null) ...[const SizedBox(width: 8), status!],
            if (onTap != null) ...[const SizedBox(width: 4), const Icon(Icons.chevron_right, size: 20, color: kTextMuted)],
          ],
        ),
      ),
    ),
  );
}

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> with AktionsZustand<ProfileScreen> {
  /// Web: Das Abmelden auf dem Server ist gescheitert. Die Person gilt weiter als angemeldet und kann es erneut versuchen
  /// oder nur lokal abmelden (die Sitzung bleibt dann auf dem Server bis zum Ablauf gültig).
  bool _abmeldenGescheitert = false;
  bool _abmeldenUeberall = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(ref.read(authProvider.notifier).neuLaden()));
  }

  void _oeffne(Widget seite) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => seite));

  Future<bool> _bestaetigen(String titel, String text, String knopf) async =>
      await showDialog<bool>(
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

  Future<void> _abmelden({required bool ueberall}) async {
    final ja = await _bestaetigen(
      ueberall ? 'Überall abmelden?' : 'Abmelden?',
      ueberall
          ? 'Alle deine Geräte werden abgemeldet, auch dieses. Lokale Daten auf diesem Gerät werden gelöscht.'
          : 'Du wirst auf diesem Gerät abgemeldet. Lokale Daten auf diesem Gerät werden gelöscht.',
      ueberall ? 'Überall abmelden' : 'Abmelden',
    );
    if (!ja || !mounted) return;
    await _abmeldenAusfuehren(ueberall: ueberall);
  }

  Future<void> _abmeldenAusfuehren({required bool ueberall, bool nurLokal = false}) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    AbmeldeErgebnis? ergebnis;
    setState(() {
      _abmeldenGescheitert = false;
      _abmeldenUeberall = ueberall;
    });
    final ok = await ausfuehren(() async {
      ergebnis = await ref.read(authProvider.notifier).abmelden(ueberall: ueberall, nurLokal: nurLokal);
    });
    if (!ok) {
      // Web bei Serverfehler (oder unerwarteter Fehler): NICHT als abgemeldet anzeigen, Fehler + Wiederholen anbieten
      if (mounted) setState(() => _abmeldenGescheitert = true);
      return;
    }
    nav.popUntil((r) => r.isFirst);
    final e = ergebnis;
    if (e != null && !e.serverAbgemeldet) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 8),
            content: Text(
              'Du wurdest nur auf diesem Gerät abgemeldet: Der Server war nicht erreichbar. Die Sitzung dort bleibt bis zum Ablauf gültig; '
              'du kannst sie später unter "Angemeldete Geräte" beenden.',
            ),
          ),
        );
    } else if (e != null && !e.lokalSauber) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Lokale Daten auf diesem Gerät konnten nicht vollständig gelöscht werden.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final me = auth.me;
    return AuthSeite(
      label: '// konto',
      titel: 'Profil & Sicherheit',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (user != null)
          LxCard(
            child: Row(
              children: [
                PersonAvatar(name: user.displayName, colorIndex: user.colorIndex, size: 48),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: kTextStrong)),
                      if (user.email != null)
                        Text(user.email!, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
                      const SizedBox(height: 6),
                      RollenPille(user.role.label),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (auth.offline) ...[const SizedBox(height: 12), const MeldungsBox('Keine Verbindung zum Server. Einstellungen sind erst wieder online verfügbar.')],
        if (fehler != null && !_abmeldenGescheitert) ...[const SizedBox(height: 12), MeldungsBox(fehler!)],
        if (_abmeldenGescheitert) ...[
          const SizedBox(height: 12),
          const MeldungsBox(
            'Du bist noch angemeldet: Das Abmelden auf dem Server hat nicht geklappt. Versuche es erneut. '
            'Wenn du nur lokal abmeldest, bleibt die Sitzung auf dem Server bis zum Ablauf gültig und ist beim nächsten Laden der Seite möglicherweise wieder aktiv.',
          ),
          const SizedBox(height: 8),
          ZweitKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: laeuft ? null : () => _abmeldenAusfuehren(ueberall: _abmeldenUeberall)),
          const SizedBox(height: 8),
          LinkKnopf('Trotzdem nur lokal abmelden', onPressed: laeuft ? null : () => _abmeldenAusfuehren(ueberall: _abmeldenUeberall, nurLokal: true)),
        ],
        const SizedBox(height: 20),
        const MonoLabel('// sicherheit'),
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
        EinstellungsZeile(
          icon: Icons.phone_android,
          titel: 'Angemeldete Geräte',
          untertitel: 'einzeln abmelden',
          onTap: () => _oeffne(const DevicesScreen()),
        ),
        if (auth.darfEinladen) ...[
          const SizedBox(height: 12),
          const MonoLabel('// familie'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.group_outlined,
            titel: auth.istAdmin ? 'Mitglieder und Einladungen' : 'Einladungen',
            untertitel: auth.istAdmin ? 'verwalten' : 'für Kinder',
            onTap: () => _oeffne(const AdminScreen()),
          ),
        ],
        const SizedBox(height: 12),
        const MonoLabel('// konto'),
        const SizedBox(height: 8),
        ZweitKnopf(text: 'Abmelden', icon: Icons.logout, onPressed: laeuft ? null : () => _abmelden(ueberall: false)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: laeuft ? null : () => _abmelden(ueberall: true),
          style: OutlinedButton.styleFrom(foregroundColor: kDanger, side: const BorderSide(color: kDanger), minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.phonelink_erase),
          label: const Text('Überall abmelden'),
        ),
      ],
    );
  }
}
