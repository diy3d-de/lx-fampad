// Profil (Hauptseite): Profilkarte, kurze Zeilen in Unterseiten (Sicherheit, Benachrichtigungen, Startseite und Anzeige, Kalender, Müll), Familie (Eltern/Admin),
// Betrieb (Betreiber), App (Über, Abmelden). Die Einstellungen selbst liegen auf den Unterseiten.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/muell/muell_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/eltern_state.dart';
import '../../ui/widgets.dart';
import '../admin/admin_screen.dart';
import '../auth/auth_widgets.dart';
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../betrieb/betrieb_screen.dart';
import '../muell/muell_einstellungen_screen.dart';
import 'abmelden_pruefung.dart';
import 'anzeige_screen.dart';
import 'benachrichtigungen_screen.dart';
import 'kalender_einstellungen_screen.dart';
import 'profil_plattform.dart';
import 'sicherheit_screen.dart';
import 'ueber_screen.dart';
import 'profilbild_screen.dart';
import '../../widgets/benutzer_avatar.dart';

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
                    Text(untertitel!, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
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

/// Marker in den Argumenten der Konto-Route (kein Routenname: der Wurzel-Navigator schreibt benannte Routen im Web in die Adresszeile). Die Desktop-Shell erkennt daran, dass das Konto offen ist.
const kKontoMarke = 'konto-seite';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  /// Route der Konto-Seite (mobil eine Vollseite, im Desktop-Layout eine Seite im Inhaltsbereich der Shell).
  static Route<void> route() => MaterialPageRoute<void>(settings: const RouteSettings(arguments: kKontoMarke), builder: (_) => const ProfileScreen());

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(authProvider.notifier).neuLaden());
      // Stand der Verschlüsselung für die Warnanzeige (Schlüsselwechsel) in der Zeile unten
      unawaited(ref.read(e2eeProvider.notifier).laden());
    });
  }

  void _oeffne(Widget seite) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => seite));

  Future<void> _familienrolle(FamilyRole? aktuell) async {
    final wahl = await familienrolleWaehlen(context, titel: 'Familienrolle', aktuell: aktuell);
    if (wahl == null || wahl.rolle == aktuell || !mounted) return;
    final ok = await ausfuehren(() => ref.read(apiProvider).familienrolleSetzen(wahl.rolle));
    if (ok && mounted) await ref.read(authProvider.notifier).neuLaden();
  }

  Future<void> _abmelden({required bool ueberall}) async {
    final titel = ueberall ? 'Überall abmelden?' : 'Abmelden?';
    final text = ueberall
        ? 'Alle deine Geräte werden abgemeldet, auch dieses. Lokale Daten auf diesem Gerät werden gelöscht.'
        : 'Du wirst auf diesem Gerät abgemeldet. Lokale Daten auf diesem Gerät werden gelöscht.';
    final knopf = ueberall ? 'Überall abmelden' : 'Abmelden';
    // Rückfrage mit ruhigem Hinweis, dass der Schlüssel auf diesem Gerät bleibt (abmelden_pruefung.dart)
    final ja = await abmeldenBestaetigen(context, ref, titel: titel, text: text, knopf: knopf, ueberall: ueberall);
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
              'Du kannst sie später unter "Angemeldete Geräte" beenden.',
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
    final web = ref.watch(profilWebProvider);
    return AuthSeite(
      label: 'Konto',
      titel: 'Profil',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (user != null)
          LxCard(
            onTap: () => _oeffne(const ProfilbildScreen()),
            child: Row(
              children: [
                Semantics(label: 'Profilbild ändern', button: true, child: BenutzerAvatar(user: user, size: 56)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: kTextStrong)),
                      if (user.email != null)
                        Text(user.email!, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [...rollenPillen(user.role, user.familyRole), if (ref.watch(elternHilfeAktivProvider)) const RollenPille('Eltern-Hilfe aktiv', farbe: kTerminal)],
                      ),
                      const SizedBox(height: 2),
                      Semantics(
                        button: true,
                        label: 'Familienrolle ändern',
                        child: InkWell(
                          onTap: laeuft || auth.offline ? null : () => _familienrolle(user.familyRole),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Familienrolle ändern (nur Anzeige)', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kAccent)),
                            ),
                          ),
                        ),
                      ),
                      const Text('Profilbild ändern', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kAccent)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 20, color: kTextMuted),
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
        const SizedBox(height: 12),
        const MonoLabel('Einstellungen'),
        const SizedBox(height: 8),
        SicherheitsZeile(onTap: () => _oeffne(const SicherheitScreen())),
        EinstellungsZeile(icon: Icons.notifications_none, titel: 'Benachrichtigungen', untertitel: web ? 'Erinnerungen' : 'Erinnerungen und Hinweise aufs Handy', onTap: () => _oeffne(const BenachrichtigungenScreen())),
        EinstellungsZeile(icon: Icons.dashboard_customize_outlined, titel: 'Startseite und Anzeige', untertitel: web ? 'Kacheln und Wetter' : 'Kacheln, Wetter und Widget', onTap: () => _oeffne(const AnzeigeScreen())),
        EinstellungsZeile(icon: Icons.calendar_month_outlined, titel: 'Kalender', untertitel: 'Termine importieren und exportieren', onTap: () => _oeffne(const KalenderEinstellungenScreen())),
        const _MuellZeile(),
        if (auth.darfEinladen) ...[
          const SizedBox(height: 12),
          const MonoLabel('Familie'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.group_outlined,
            titel: auth.istAdmin ? 'Mitglieder und Einladungen' : 'Einladungen',
            untertitel: auth.istAdmin ? 'Mitglieder verwalten' : 'Einladungen für Kinder',
            onTap: () => _oeffne(const AdminScreen()),
          ),
        ],
        // Betreiber-Ansicht (Konto-Flag, nicht die Rolle): nur lesen, auch mobil über das Profil erreichbar
        if (auth.istBetreiber) ...[
          const SizedBox(height: 12),
          const MonoLabel('Betrieb'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.monitor_heart_outlined,
            titel: 'Betrieb',
            untertitel: 'Zustand des Servers und Protokoll',
            // im Desktop-Layout ersetzt die Seite das Konto (beide stapeln dort nicht), mobil liegt sie darüber
            onTap: () => DesktopShellMarke.vorhanden(context) ? Navigator.of(context).pushReplacement<void, void>(BetriebScreen.route()) : Navigator.of(context).push<void>(BetriebScreen.route()),
          ),
        ],
        const SizedBox(height: 12),
        const MonoLabel('App'),
        const SizedBox(height: 8),
        EinstellungsZeile(icon: Icons.info_outline, titel: 'Über $kAppName', untertitel: 'Version und Updates', onTap: () => _oeffne(const UeberScreen())),
        const SizedBox(height: 4),
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

/// Zeile "Müll" (Abfuhrtermine): öffnet die Müll-Seite, auch wenn die Kachel der Startseite fehlt; nur wenn der Server die Abfuhrtermine eingeschaltet hat.
/// Im Desktop-Layout steht der Bereich in der Seitenleiste, dort führt die Zeile ebenfalls auf die Seite.
class _MuellZeile extends ConsumerWidget {
  const _MuellZeile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(muellProvider.select((m) => m.verfuegbar))) return const SizedBox.shrink();
    return EinstellungsZeile(
      icon: Icons.delete_outline,
      titel: 'Müll',
      untertitel: 'Erinnerung und Abfuhrkalender',
      onTap: () => unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MuellEinstellungenScreen()))),
    );
  }
}
