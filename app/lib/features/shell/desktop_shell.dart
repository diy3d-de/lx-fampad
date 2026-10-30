// Desktop-Layout (Fenster ab kDesktopBreakpoint): Seitenleiste links, Inhalt, Fußzeile mit Sync-, Geräte-, Verbindungs- und Versionsangabe.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/lists/members.dart';
import '../../data/shell/zuletzt_state.dart';
import '../../data/sync_state.dart';
import '../../data/tasks/aufgabe_logik.dart' show AufgabeFilter;
import '../../ui/widgets.dart';
import '../../widgets/familien_hinweis_banner.dart';
import '../../widgets/sync_anzeige.dart';
import '../auth/auth_widgets.dart';
import '../betrieb/betrieb_screen.dart';
import '../profile/profile_screen.dart';
import '../profile/ueber_screen.dart' show webVersionTeilen;
import '../update/update_service.dart';
import '../suche/such_screen.dart' show SuchScreen;
import '../tasks/tasks_state.dart' show aufgabenAnsichtProvider;
import 'mehr_menue.dart' show MehrEintrag, MehrGruppe, bereichsEintraege;
import 'schnellwahl.dart';
import 'shell_tab.dart';
import '../../widgets/benutzer_avatar.dart';

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
  final betrieb = ValueNotifier<bool>(false);
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
    betrieb.value = _routen.any((r) => r.settings.arguments == kBetriebMarke);
  });

  void verwerfen() {
    _verworfen = true;
    tiefe.dispose();
    konto.dispose();
    betrieb.dispose();
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

  /// Schließt alle Unterseiten per `maybePop` (nie `popUntil`): Seiten mit `PopScope` (Notfall-Codes, Step-up, laufende Aktionen,
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

  /// Konto und Betrieb stapeln nicht: vor dem Öffnen werden die offenen Unterseiten (auch die andere der beiden) per `maybePop` geschlossen;
  /// lehnt eine Seite das Schließen ab (ungespeicherte Eingaben), bleibt alles, wie es ist.
  Future<void> _kontoOeffnen() async {
    if (_navKey.currentState == null || _beobachter.konto.value) return;
    if (_beobachter.betrieb.value && !await _unterseitenSchliessen()) return;
    if (!mounted || _beobachter.konto.value) return;
    unawaited(_navKey.currentState?.push<void>(ProfileScreen.route()));
  }

  /// Betreiber-Ansicht "Betrieb" (nur für den Betreiber in der Seitenleiste): wie das Konto eine Unterseite im Inhaltsbereich.
  Future<void> _betriebOeffnen() async {
    if (_navKey.currentState == null || _beobachter.betrieb.value) return;
    if (_beobachter.konto.value && !await _unterseitenSchliessen()) return;
    if (!mounted || _beobachter.betrieb.value) return;
    unawaited(_navKey.currentState?.push<void>(BetriebScreen.route()));
  }

  /// Suche (Eintrag der Seitenleiste): eine Unterseite im Inhaltsbereich wie das Konto.
  void _suchen() => unawaited(_navKey.currentState?.push<void>(SuchScreen.route()));

  /// Eintrag der Gruppen (Seitenleiste und Schnellwahl): als zuletzt benutzt merken und öffnen.
  void _eintragOeffnen(MehrEintrag e) {
    unawaited(ref.read(shellMerkerProvider.notifier).merken(e.id));
    if (e.tab == null) {
      _suchen();
    } else {
      e.vorWahl?.call(ref);
      _bereichWaehlen(e.tab!);
    }
  }

  var _schnellwahlOffen = false;

  /// Schnellwahl (Strg+K): Fenster mit Suchfeld über den Bereichsnamen; liegt im Navigator des Inhaltsbereichs wie die Unterseiten.
  Future<void> _schnellwahl() async {
    final nav = _navKey.currentState;
    final kontext = _navKey.currentContext;
    if (nav == null || kontext == null || _schnellwahlOffen) return;
    final eintraege = bereichsEintraege(ref, offenerTab: ref.read(shellTabProvider));
    final ziele = [
      for (var i = 0; i <= kChatTab; i++) SchnellwahlZiel(id: kDesktopTabs[i].label, label: kDesktopTabs[i].label, icon: kDesktopTabs[i].icon, oeffnen: () => _bereichWaehlen(i)),
      for (final e in eintraege) SchnellwahlZiel(id: e.id, label: e.label, icon: e.icon, gruppe: e.gruppe.label, oeffnen: () => _eintragOeffnen(e)),
    ];
    _schnellwahlOffen = true;
    try {
      await nav.push<void>(schnellwahlRoute(kontext, ziele));
    } finally {
      _schnellwahlOffen = false;
    }
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
              _Seitenleiste(konto: _beobachter.konto, kontoOeffnen: _kontoOeffnen, betrieb: _beobachter.betrieb, betriebOeffnen: _betriebOeffnen, waehlen: _bereichWaehlen, eintragOeffnen: _eintragOeffnen, schnellwahl: _schnellwahl),
              Expanded(
                child: Column(
                  children: [
                    // Banner des Betreibers (Wartung, Familienhinweis); ohne Hinweis ist er leer
                    Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kMaxContentWidthDesktop), child: const FamilienHinweisBanner())),
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
    // Strg+K (macOS: Cmd+K) öffnet die Schnellwahl von überall; der Fokusknoten sorgt dafür, dass die Taste auch ohne fokussiertes Feld ankommt
    return DesktopShellMarke(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => unawaited(_schnellwahl()),
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => unawaited(_schnellwahl()),
        },
        child: Focus(autofocus: true, skipTraversal: true, child: shell),
      ),
    );
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
  final ValueListenable<bool> betrieb;
  final VoidCallback betriebOeffnen;
  final ValueChanged<int> waehlen;
  final ValueChanged<MehrEintrag> eintragOeffnen;
  final VoidCallback schnellwahl;
  const _Seitenleiste({required this.konto, required this.kontoOeffnen, required this.betrieb, required this.betriebOeffnen, required this.waehlen, required this.eintragOeffnen, required this.schnellwahl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    final updateDa = ref.watch(updateProvider.select((u) => u.updateDa));
    final anzahl = ref.watch(mitgliederProvider).value?.length;
    final ungelesen = ref.watch(chatUngelesenProvider).value ?? 0;
    final betreiber = ref.watch(authProvider.select((s) => s.istBetreiber));
    // Einträge der drei Gruppen (Sichtbarkeit nach Rolle, Server-Fähigkeiten und Hinweis-Zahlen: bereichsEintraege in mehr_menue.dart; Wetter und Müll bleiben sichtbar, solange ihr Bereich offen ist)
    final eintraege = bereichsEintraege(ref, offenerTab: tab);
    final fristenAnsicht = ref.watch(aufgabenAnsichtProvider.select((a) => a.filter == AufgabeFilter.fristen));
    final gruppenZu = ref.watch(shellMerkerProvider.select((m) => m.gruppenZu));
    return Semantics(
      container: true,
      label: 'Navigation',
      child: Container(
        width: kSidebarWidth,
        decoration: BoxDecoration(
          color: kBgElevated.withValues(alpha: 0.85),
          
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
                  Text(kInviteHost, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
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
                decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
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
                            Text('$anzahl ${anzahl == 1 ? 'Mitglied' : 'Mitglieder'}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
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
                    // Start, Kalender und Chat stehen oben; darunter dieselben Gruppen und Einträge wie im Blatt "Mehr" (mehr_menue.dart)
                    for (var i = 0; i <= kChatTab; i++)
                      _NavEintrag(
                        icon: tab == i ? kDesktopTabs[i].selectedIcon : kDesktopTabs[i].icon,
                        label: kDesktopTabs[i].label,
                        gewaehlt: tab == i,
                        badge: updateDa && i == 0,
                        zaehler: i == kChatTab ? ungelesen : 0,
                        onTap: () => waehlen(i),
                      ),
                    for (final g in MehrGruppe.values)
                      if (eintraege.any((e) => e.gruppe == g)) ...[
                        _GruppenKopf(
                          text: g.label,
                          zu: gruppenZu.contains(g.label),
                          onTap: () => unawaited(ref.read(shellMerkerProvider.notifier).gruppeUmschalten(g.label)),
                        ),
                        for (final e in eintraege.where((e) => e.gruppe == g))
                          // eine eingeklappte Gruppe zeigt nur noch den gewählten Bereich (damit er nicht unter dir verschwindet)
                          if (!gruppenZu.contains(g.label) || _istGewaehlt(e, tab, fristenAnsicht))
                            _NavEintrag(
                              icon: e.icon,
                              label: e.label,
                              gewaehlt: _istGewaehlt(e, tab, fristenAnsicht),
                              zaehler: e.hinweis,
                              ueberfaellig: e.ueberfaellig,
                              onTap: () => eintragOeffnen(e),
                            ),
                      ],
                    // nur der Betreiber des Servers sieht "Betrieb" (Konto-Flag, nicht die Rolle); öffnet wie das Konto eine Unterseite
                    if (betreiber)
                      ValueListenableBuilder<bool>(
                        valueListenable: betrieb,
                        builder: (context, offen, _) => _NavEintrag(icon: Icons.monitor_heart_outlined, label: 'Betrieb', gewaehlt: offen, onTap: betriebOeffnen),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            _NavEintrag(icon: Icons.manage_search_outlined, label: 'Bereich suchen', gewaehlt: false, kurz: 'Strg K', onTap: schnellwahl),
            const SizedBox(height: 4),
            _ProfilKachel(konto: konto, oeffnen: kontoOeffnen),
          ],
        ),
      ),
    );
  }
}

bool _istGewaehlt(MehrEintrag e, int tab, bool fristenAnsicht) =>
    e.id == 'fristen' ? (tab == kAufgabenTab && fristenAnsicht) : (e.tab != null && tab == e.tab && !(e.tab == kAufgabenTab && fristenAnsicht));

/// Zwischenüberschrift einer Gruppe der Seitenleiste (Familie, Zuhause, Ablage): ein Tipp klappt die Gruppe ein oder aus (nur lokal gemerkt).
class _GruppenKopf extends StatelessWidget {
  final String text;
  final bool zu;
  final VoidCallback onTap;
  const _GruppenKopf({required this.text, required this.zu, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    expanded: !zu,
    label: text,
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
          child: Row(
            children: [
              Expanded(child: MonoLabel(text, color: kTextMuted)),
              Icon(zu ? Icons.chevron_right : Icons.expand_more, size: 18, color: kTextMuted),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NavEintrag extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool gewaehlt;
  final bool badge;

  /// Anzahl ungelesener Nachrichten (0: kein Zeichen).
  final int zaehler;

  /// Überfälliges dabei: die Zahl bekommt dann im Vorlesetext den Zusatz, im Bild ein Ausrufezeichen (nie nur Farbe).
  final bool ueberfaellig;

  /// Kurzer Hinweis rechts (z. B. die Tastenkombination).
  final String? kurz;
  final VoidCallback? onTap;
  const _NavEintrag({required this.icon, required this.label, required this.gewaehlt, this.badge = false, this.zaehler = 0, this.ueberfaellig = false, this.kurz, this.onTap});

  @override
  Widget build(BuildContext context) {
    final farbe = gewaehlt ? kAccent : kText;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        selected: gewaehlt,
        enabled: true,
        focusable: true,
        onTap: onTap,
        label: zaehler > 0 ? '$label, $zaehler ${label == 'Chat' ? 'ungelesen' : (zaehler == 1 ? 'Hinweis' : 'Hinweise')}${ueberfaellig ? ', Überfälliges dabei' : ''}' : (kurz == null ? label : '$label, Tastenkürzel $kurz'),
        excludeSemantics: true,
        child: Material(
          color: gewaehlt ? kAccentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            focusColor: kAccent.withValues(alpha: 0.18),
            hoverColor: kSurfaceHover.withValues(alpha: 0.6),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Badge(isLabelVisible: badge || zaehler > 0, label: zaehler > 0 ? Text('${zaehler > 99 ? '99+' : zaehler}${ueberfaellig ? '!' : ''}') : null, child: Icon(icon, size: 20, color: farbe)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: gewaehlt ? FontWeight.w700 : FontWeight.w500, color: farbe)),
                  ),
                  if (kurz != null) Text(kurz!, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
            if (me.passkeys > 0) 'Passkey',
            if (me.hasPassword) 'Passwort',
            if (me.hasTotp) 'zweiter Schritt',
          ].join(', ');
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
                      'Einstellungen',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
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
    final installiert = ref.watch(updateProvider.select((u) => u.installierteVersion));
    final version = installiert ?? (kWebVersion.isNotEmpty ? webVersionTeilen(kWebVersion).version : 'dev');
    final (bedienText, farbe) = syncAnzeige(sync);
    final zeile = syncZeile(sync);
    const stil = TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted);
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 24,
          runSpacing: 4,
          children: [
            // Zustand immer als Symbol UND Text (nie nur Farbe): bei "synchron" ein kurzes „Alles aktuell“, sonst die ruhige Zeile (ein Fehler mit "Erneut versuchen");
            // die Zahl offener Änderungen steht nur, solange welche warten
            Semantics(
              label: zeile == null ? 'Sync: $bedienText' : null,
              liveRegion: zeile != null,
              excludeSemantics: zeile == null,
              container: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (zeile != null) ...[
                    ExcludeSemantics(child: Icon(zeile.symbol, size: 14, color: zeile.alarm ? kDanger : kTextMuted)),
                    const SizedBox(width: 6),
                  ],
                  Text(zeile?.text ?? (sync.status == SyncStatus.laeuft ? 'Überträgt …' : 'Alles aktuell'), style: stil.copyWith(color: zeile == null ? farbe : kTextMuted)),
                  if (zeile?.handlung != null)
                    TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 8), foregroundColor: kAccent, textStyle: stil),
                      onPressed: () => unawaited(ref.read(syncProvider.notifier).synchronisieren(manuell: true)),
                      child: Text(zeile!.handlung!),
                    ),
                ],
              ),
            ),
            Text('Version $version', style: stil),
          ],
        ),
      ),
    );
  }
}
