// Desktop-Layout (Fenster ab kDesktopBreakpoint): Seitenleiste links, Inhalt, Fußzeile mit Sync-, Geräte-, Verbindungs- und Versionsangabe.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/geraete_anzahl.dart';
import '../../data/lists/members.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_anzeige.dart';
import '../auth/auth_widgets.dart';
import '../profile/profile_screen.dart';
import '../profile/ueber_screen.dart' show webVersionTeilen;
import '../update/update_service.dart';
import 'shell_tab.dart';
import '../../widgets/benutzer_avatar.dart';

/// Noch nicht gebaute Bereiche in der Seitenleiste (deaktiviert, mit "bald" markiert).
const _kBaldBereiche = <(String, IconData)>[
  ('Fotos', Icons.photo_library_outlined),
  ('Orte', Icons.place_outlined),
];

class DesktopShell extends ConsumerWidget {
  /// Bereiche in Reihenfolge von [kDesktopTabs]; Index 0 ist die Desktop-Startseite.
  final List<Widget> screens;
  const DesktopShell({super.key, required this.screens});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Seitenleiste(),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      // ein einziger Stapel: der Zustand der Bereiche bleibt beim Tab-Wechsel erhalten
                      child: IndexedStack(
                        index: tab,
                        children: [
                          for (var i = 0; i < screens.length; i++)
                            Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(constraints: BoxConstraints(maxWidth: i == 0 || i == kChatTab ? kMaxContentWidthDesktop : kMaxContentWidth), child: screens[i]),
                            ),
                        ],
                      ),
                    ),
                    const _Fusszeile(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Seitenleiste extends ConsumerWidget {
  const _Seitenleiste();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    final updateDa = ref.watch(updateProvider.select((u) => u.updateDa));
    final anzahl = ref.watch(mitgliederProvider).value?.length;
    final ungelesen = ref.watch(chatUngelesenProvider).value ?? 0;
    return Semantics(
      container: true,
      label: 'Navigation',
      child: Container(
        width: kSidebarWidth,
        decoration: BoxDecoration(
          color: kBgElevated.withValues(alpha: 0.85),
          border: const Border(right: BorderSide(color: kBorder)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kAppName, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.55, color: kTextStrong)),
                  SizedBox(height: 2),
                  Text(kInviteHost, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Familienauswahl: es gibt genau eine Familie je Konto, daher nur als Kopf (ohne Auswahl)
            Semantics(
              label: 'Familie${anzahl == null ? '' : ', $anzahl Mitglieder'}',
              excludeSemantics: true,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: kSurface.withValues(alpha: 0.7), border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: kAccentSoft, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.home_work_outlined, size: 16, color: kAccent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Familie', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600)),
                          if (anzahl != null)
                            Text('$anzahl ${anzahl == 1 ? 'mitglied' : 'mitglieder'}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FocusTraversalGroup(
                child: ListView(
                  children: [
                    for (var i = 0; i < kDesktopTabs.length; i++)
                      _NavEintrag(
                        icon: tab == i ? kDesktopTabs[i].selectedIcon : kDesktopTabs[i].icon,
                        label: kDesktopTabs[i].label,
                        gewaehlt: tab == i,
                        badge: updateDa && i == 0,
                        zaehler: i == kChatTab ? ungelesen : 0,
                        onTap: () => ref.read(shellTabProvider.notifier).waehlen(i),
                      ),
                    const SizedBox(height: 8),
                    for (final b in _kBaldBereiche) _NavEintrag(icon: b.$2, label: b.$1, gewaehlt: false, bald: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const _ProfilKachel(),
          ],
        ),
      ),
    );
  }
}

class _NavEintrag extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool gewaehlt;
  final bool bald;
  final bool badge;

  /// Anzahl ungelesener Nachrichten (0: kein Zeichen).
  final int zaehler;
  final VoidCallback? onTap;
  const _NavEintrag({required this.icon, required this.label, required this.gewaehlt, this.bald = false, this.badge = false, this.zaehler = 0, this.onTap});

  @override
  Widget build(BuildContext context) {
    final farbe = bald ? kTextFaint : (gewaehlt ? kAccent : kText);
    final inhalt = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        selected: gewaehlt,
        enabled: !bald,
        focusable: !bald,
        onTap: bald ? null : onTap,
        label: bald ? '$label, kommt bald' : (zaehler > 0 ? '$label, $zaehler ungelesen' : label),
        excludeSemantics: true,
        child: Material(
          color: gewaehlt ? kAccentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: bald ? null : onTap,
            focusColor: kAccent.withValues(alpha: 0.18),
            hoverColor: kSurfaceHover.withValues(alpha: 0.6),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Badge(isLabelVisible: badge || zaehler > 0, label: zaehler > 0 ? Text(zaehler > 99 ? '99+' : '$zaehler') : null, child: Icon(icon, size: 20, color: farbe)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: gewaehlt ? FontWeight.w700 : FontWeight.w500, color: farbe)),
                  ),
                  if (bald) const Text('bald', style: TextStyle(fontFamily: kFontMono, fontSize: 10, color: kTextFaint)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return bald ? Tooltip(message: '$label kommt in einer späteren Phase', child: inhalt) : inhalt;
  }
}

/// Unten in der Seitenleiste: Person mit Anmeldeart, öffnet Profil und Einstellungen.
class _ProfilKachel extends ConsumerWidget {
  const _ProfilKachel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider.select((s) => s.user));
    final me = ref.watch(authProvider.select((s) => s.me));
    final art = me == null
        ? null
        : [
            if (me.passkeys > 0) 'passkey',
            if (me.hasPassword) 'pw',
            if (me.hasTotp) '2fa',
          ].join(' + ');
    final name = user?.displayName ?? 'Profil';
    return Semantics(
      button: true,
      focusable: true,
      onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const ProfileScreen())),
      label: 'Profil und Einstellungen, $name${user == null ? '' : ', ${[user.role.label, if (user.familyRole != null && user.familyRole!.label != user.role.label) user.familyRole!.label].join(' und ')}'}${art == null || art.isEmpty ? '' : ', Anmeldung per $art'}',
      excludeSemantics: true,
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const ProfileScreen())),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              BenutzerAvatar(user: user, ersatzName: name, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (user != null) ...[
                      const SizedBox(height: 2),
                      Wrap(spacing: 4, runSpacing: 2, children: rollenPillen(user.role, user.familyRole)),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      art == null || art.isEmpty ? 'einstellungen' : art,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.settings_outlined, size: 18, color: kTextMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fusszeile extends ConsumerWidget {
  const _Fusszeile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final geraete = ref.watch(geraeteAnzahlProvider).value;
    final installiert = ref.watch(updateProvider.select((u) => u.installierteVersion));
    final version = installiert ?? (kWebVersion.isNotEmpty ? webVersionTeilen(kWebVersion).version : 'dev');
    final (text, farbe) = syncAnzeige(sync);
    const stil = TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted);
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: kBorderSoft))),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 24,
          runSpacing: 4,
          children: [
            Text.rich(TextSpan(children: [TextSpan(text: '● ', style: TextStyle(color: farbe)), TextSpan(text: 'sync: $text')]), style: stil),
            Text('geräte: ${geraete ?? '–'}', style: stil),
            Text('verbindung: ${sync.live ? 'live' : 'ohne live'}', style: stil),
            Text('version: $version', style: stil),
          ],
        ),
      ),
    );
  }
}
