// Desktop-Layout (Fenster ab kDesktopBreakpoint): Seitenleiste links, Inhalt, Fußzeile mit Sync-, Geräte-, Verbindungs- und Versionsangabe.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/geraete_anzahl.dart';
import '../../data/lists/members.dart';
import '../../data/sync_state.dart';
import '../../data/wetter/wetter_state.dart';
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

/// Marke im Baum: "hier ist die Desktop-Shell". So entscheidet [standortOeffnen] danach, ob der Bereich zu wählen ist (statt nach der Fensterbreite zu raten);
/// eine gepushte Seite über der Shell liegt nicht darunter und öffnet wie mobil eine Seite.
class DesktopShellMarke extends InheritedWidget {
  const DesktopShellMarke({super.key, required super.child});

  static bool vorhanden(BuildContext context) => context.getInheritedWidgetOfExactType<DesktopShellMarke>() != null;

  @override
  bool updateShouldNotify(DesktopShellMarke alt) => false;
}

/// Beobachtet den Seiten-Stapel im Inhaltsbereich der Shell: Tiefe (für die Zurück-Taste) und ob die Konto-Seite (Marker [kKontoMarke] in den Argumenten der Route) offen ist.
class _ShellBeobachter extends NavigatorObserver {
  final tiefe = ValueNotifier<int>(0);
  final konto = ValueNotifier<bool>(false);
  final _routen = <Route<dynamic>>[];

  bool _verworfen = false;

  // Per Microtask: der Navigator meldet sich auch mitten im Bauen (erste Seite), da darf kein Zuhörer neu bauen lassen
  /// Anzahl der Seiten im Stapel (sofort, ohne Microtask): so erkennt [_DesktopShellState._unterseitenSchliessen], ob ein Schließen gelungen ist.
  int get anzahl => _routen.length;

  /// Gerade geöffnete Seiten (Kopie des Stapels).
  List<Route<dynamic>> get routen => [..._routen];

  /// Meldet jede Änderung des Stapels (nach dem Bauen).
  VoidCallback? beiAenderung;

  void _aktualisieren() => scheduleMicrotask(() {
    if (_verworfen) return;
    beiAenderung?.call();
    tiefe.value = _routen.length;
    konto.value = _routen.any((r) => r.settings.arguments == kKontoMarke);
  });

  void verwerfen() {
    _verworfen = true;
    tiefe.dispose();
    konto.dispose();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routen.add(route);
    _aktualisieren();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routen.remove(route);
    _aktualisieren();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routen.remove(route);
    _aktualisieren();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routen.indexOf(oldRoute);
    if (i >= 0) _routen.removeAt(i);
    if (newRoute != null) _routen.insert(i < 0 ? _routen.length : i, newRoute);
    _aktualisieren();
  }
}

/// Seitenleiste und Fußzeile bleiben stehen; Unterseiten (Konto und deren Seiten, Editoren, Import) liegen in einem eigenen Navigator
/// im Inhaltsbereich statt als Vollseite über der Shell. Jedes `Navigator.of(context).push` aus einem Bereich landet dort von selbst;
/// Dialoge und Blätter öffnen mit `useRootNavigator: false` im selben Navigator wie ihre Seite (ihr `pop` trifft so den richtigen).
class DesktopShell extends ConsumerStatefulWidget {
  /// Bereiche in Reihenfolge von [kDesktopTabs]; Index 0 ist die Desktop-Startseite.
  final List<Widget> screens;
  const DesktopShell({super.key, required this.screens});

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  final _navKey = GlobalKey<NavigatorState>();
  final _beobachter = _ShellBeobachter();
  // Die erste Seite des Navigators entsteht nur einmal; sie liest die (wachsende) Liste der Bereiche über diesen Halter
  late final _screens = ValueNotifier<List<Widget>>(widget.screens);

  @override
  void didUpdateWidget(DesktopShell alt) {
    super.didUpdateWidget(alt);
    _screens.value = widget.screens;
  }

  @override
  void initState() {
    super.initState();
    _beobachter.beiAenderung = _stapelGeaendert;
  }

  @override
  void dispose() {
    _beobachter.verwerfen();
    _screens.dispose();
    super.dispose();
  }

  /// Schließt alle Unterseiten per `maybePop` (nie `popUntil`): Seiten mit `PopScope` (Wiederherstellungscodes, Step-up, laufende Aktionen,
  /// Editoren mit Eingaben) behalten ihr Vetorecht. Gelingt das Schließen einer Seite nicht, bleibt sie offen und der Bereich unverändert (false).
  Future<bool> _unterseitenSchliessen() async {
    final nav = _navKey.currentState;
    if (nav == null) return true;
    // nur die Seiten, die jetzt offen sind: eine währenddessen frisch geöffnete (z. B. Editor aus einer Benachrichtigung) bleibt
    final alte = _beobachter.routen.skip(1).toSet();
    while (true) {
      final offen = _beobachter.routen;
      if (offen.length <= 1 || !alte.contains(offen.last)) return true;
      await nav.maybePop();
      if (_beobachter.routen.contains(offen.last)) {
        _blockTiefe = offen.length;
        return false;
      }
    }
  }

  // Ziel eines Wechsels, der an einer Rückfrage hängt: Wählt die Person dort "Verwerfen", schließt die Seite und das Ziel wird gewählt.
  int? _ziel;
  int _blockTiefe = 0; // Anzahl der Seiten, als eine sich nicht schließen ließ
  int _zielTiefe = 0;
  var _zielDialogGesehen = false;

  void _stapelGeaendert() {
    final ziel = _ziel;
    if (ziel == null || !mounted) return;
    final n = _beobachter.anzahl;
    if (n < _zielTiefe) {
      _ziel = null;
      ref.read(shellTabProvider.notifier).waehlen(ziel);
    } else if (n > _zielTiefe) {
      _zielDialogGesehen = true;
    } else if (_zielDialogGesehen) {
      _ziel = null; // Rückfrage mit "Weiter bearbeiten" beantwortet: Wechsel bleibt abgebrochen
    }
  }

  int? _ignoriereTab;

  /// Bereichswechsel von außen (Karte, Benachrichtigung, Widget): bleibt eine Unterseite offen, wird der Wechsel zurückgenommen.
  Future<void> _bereichGewechselt(int alt, int neu) async {
    if (_ignoriereTab == neu) {
      _ignoriereTab = null;
      return;
    }
    _ziel = null;
    if (await _unterseitenSchliessen() || !mounted) return;
    if (ref.read(shellTabProvider) != neu) return; // inzwischen anders gewählt
    _ziel = neu;
    _zielTiefe = _blockTiefe;
    _zielDialogGesehen = false;
    _ignoriereTab = alt;
    ref.read(shellTabProvider.notifier).waehlen(alt);
  }

  /// Seitenleiste: anderer Bereich wählen; derselbe Bereich schließt nur die Unterseiten.
  void _bereichWaehlen(int i) {
    if (ref.read(shellTabProvider) == i) {
      unawaited(_unterseitenSchliessen());
    } else {
      ref.read(shellTabProvider.notifier).waehlen(i);
    }
  }

  void _kontoOeffnen() {
    final nav = _navKey.currentState;
    if (nav == null || _beobachter.konto.value) return;
    nav.push<void>(ProfileScreen.route());
  }

  @override
  Widget build(BuildContext context) {
    // Anderer Bereich gewählt (Seitenleiste, Karte, Benachrichtigung): offene Unterseiten schließen, sofern sie sich schließen lassen
    ref.listen(shellTabProvider, (alt, neu) {
      if (alt != null) unawaited(_bereichGewechselt(alt, neu));
    });
    final shell = Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Seitenleiste(konto: _beobachter.konto, kontoOeffnen: _kontoOeffnen, waehlen: _bereichWaehlen),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      // Eigene Semantik-Grenze: die Seiten des Navigators sperren sonst (BlockSemantics) die davor gemalte Seitenleiste für Screenreader
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        // Zurück (Android, Browser) schließt zuerst die Unterseite, erst danach greift der äußere Navigator
                        child: ValueListenableBuilder<int>(
                          valueListenable: _beobachter.tiefe,
                          builder: (context, tiefe, kind) => NavigatorPopHandler(
                            enabled: tiefe > 1,
                            onPopWithResult: (Object? r) => _navKey.currentState?.maybePop(r),
                            child: kind!,
                          ),
                          child: Navigator(
                            key: _navKey,
                            observers: [_beobachter],
                            onGenerateRoute: (s) => PageRouteBuilder<void>(settings: s, pageBuilder: (_, _, _) => _Bereiche(screens: _screens), transitionDuration: Duration.zero),
                          ),
                        ),
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
    return DesktopShellMarke(child: shell);
  }
}

/// Die Bereiche der Shell (erste Seite des Navigators): ein einziger Stapel, der Zustand der Bereiche bleibt beim Tab-Wechsel erhalten.
class _Bereiche extends ConsumerWidget {
  final ValueListenable<List<Widget>> screens;
  const _Bereiche({required this.screens});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    return ValueListenableBuilder<List<Widget>>(
      valueListenable: screens,
      builder: (context, liste, _) => IndexedStack(
        index: tab,
        children: [
          for (var i = 0; i < liste.length; i++)
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: BoxConstraints(maxWidth: i == 0 || i == kChatTab || i == kKalenderTab ? kMaxContentWidthDesktop : kMaxContentWidth), child: liste[i]),
            ),
        ],
      ),
    );
  }
}

class _Seitenleiste extends ConsumerWidget {
  final ValueListenable<bool> konto;
  final VoidCallback kontoOeffnen;
  final ValueChanged<int> waehlen;
  const _Seitenleiste({required this.konto, required this.kontoOeffnen, required this.waehlen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    final updateDa = ref.watch(updateProvider.select((u) => u.updateDa));
    final anzahl = ref.watch(mitgliederProvider).value?.length;
    final ungelesen = ref.watch(chatUngelesenProvider).value ?? 0;
    // Wetter nur, wenn auch die Kachel der Startseite sichtbar ist (oder der Bereich gerade offen ist, damit er beim Ausschalten nicht unter dir verschwindet)
    final wetter = ref.watch(wetterProvider.select((w) => w.kachelSichtbar)) || tab == kWetterTab;
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
                      if (i != kWetterTab || wetter)
                      _NavEintrag(
                        icon: tab == i ? kDesktopTabs[i].selectedIcon : kDesktopTabs[i].icon,
                        label: kDesktopTabs[i].label,
                        gewaehlt: tab == i,
                        badge: updateDa && i == 0,
                        zaehler: i == kChatTab ? ungelesen : 0,
                        onTap: () => waehlen(i),
                      ),
                    const SizedBox(height: 8),
                    for (final b in _kBaldBereiche) _NavEintrag(icon: b.$2, label: b.$1, gewaehlt: false, bald: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _ProfilKachel(konto: konto, oeffnen: kontoOeffnen),
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
  final ValueListenable<bool> konto;
  final VoidCallback oeffnen;
  const _ProfilKachel({required this.konto, required this.oeffnen});

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
    return ValueListenableBuilder<bool>(
      valueListenable: konto,
      builder: (context, offen, kind) => Semantics(
      button: true,
      focusable: true,
      onTap: oeffnen,
      selected: offen,
      label: 'Profil und Einstellungen, $name${user == null ? '' : ', ${[user.role.label, if (user.familyRole != null && user.familyRole!.label != user.role.label) user.familyRole!.label].join(' und ')}'}${art == null || art.isEmpty ? '' : ', Anmeldung per $art'}',
      excludeSemantics: true,
      child: LxCard(gewaehlt: offen, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), onTap: oeffnen, child: kind!),
      ),
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
