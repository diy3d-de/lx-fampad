import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/auth/reset_hinweis.dart';
import '../../data/betrieb/betrieb_hinweis.dart';
import '../betrieb/betrieb_screen.dart';
import '../../data/database_provider.dart';
import '../profile/sicherheit_ereignisse_screen.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/crypto/auto_verbinden.dart';
import '../../data/crypto/e2ee_state.dart' show e2eeProvider;
import '../../data/crypto/geraet_schluessel_melder.dart';
import '../../data/push/push_state.dart';
import '../../data/push/sicherheits_pruefer.dart';
import '../../data/standort/standort_dienst.dart';
import '../../data/standort/standort_hinweis.dart';
import '../../data/sync_state.dart';
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_screen.dart';
import '../chat/chat_screen.dart';
import '../files/files_screen.dart';
import '../home/desktop_home.dart';
import '../home/home_screen.dart';
import '../lists/lists_screen.dart';
import '../standort/standort_screen.dart';
import '../tasks/tasks_screen.dart';
import '../update/update_service.dart';
import '../wetter/wetter_screen.dart';
import 'desktop_shell.dart';
import 'shell_tab.dart';

/// Rahmen der angemeldeten App: Glow-Hintergrund, die sechs Tabs (Desktop: dazu Standort) und die Material-3-NavigationBar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  // Die Bereiche tragen GlobalKeys: Beim Wechsel zwischen Mobil und Desktop (Fenstergröße) bleibt ihr Zustand (Eingaben, Scrollposition) erhalten.
  // Start unterscheidet sich je Layout (HomeScreen / DesktopHome) und hat daher keinen Schlüssel.
  final _keys = List.generate(7, (_) => GlobalKey());
  late final _screens = <Widget>[
    const HomeScreen(),
    CalendarScreen(key: _keys[0]),
    ChatScreen(key: _keys[1]),
    FilesScreen(key: _keys[2]),
    ListsScreen(key: _keys[3]),
    TasksScreen(key: _keys[4]),
  ];
  // Desktop: dazu Standort als Bereich neben den anderen (mobil eine eigene Seite)
  // Standort (Karte, Kacheln, Zeitgeber) wird erst beim ersten Öffnen gebaut und bleibt danach im Stapel (Zustand erhalten)
  bool _standortBesucht = false;
  bool _wetterBesucht = false;
  List<Widget> get _desktopScreens => [const DesktopHome(), ..._screens.sublist(1), if (_standortBesucht) StandortScreen(key: _keys[5], eingebettet: true) else const SizedBox.shrink(), if (_wetterBesucht) WetterScreen(key: _keys[6], eingebettet: true) else const SizedBox.shrink()];

  /// Zuletzt gebautes Layout (aus der Breite der Shell, dieselbe Quelle wie die Weiche unten): bestimmt, wohin "Standort öffnen" führt.
  bool _desktopLayout = false;

  DateTime? _letztePruefung;
  Timer? _ersteUpdatePruefung;
  late final SyncController _sync;
  late final StandortController _standort;

  @override
  void initState() {
    super.initState();
    _sync = ref.read(syncProvider.notifier);
    _standort = ref.read(standortProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    ref.read(updateProvider.notifier).init();
    // erste Update-Prüfung kurz nach dem Start (Pflicht-Updates sollen früh auffallen), danach beim Zurückkehren in die App
    _ersteUpdatePruefung = Timer(const Duration(seconds: 3), _updatePruefen);
    // Sync-Dienst: Abgleich beim Start, WebSocket und Zeitgeber laufen, solange die angemeldete Oberfläche offen ist
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(syncProvider.notifier).starten();
      // ein Hinweis, der kam, bevor die Oberfläche stand (schneller Abschluss der neuen Passwort-Sicherung)
      _resetHinweisZeigen(ref.read(resetHinweisProvider));
      _autoVerbindenHinweisZeigen(ref.read(autoVerbindenHinweisProvider));
      unawaited(_abgemeldetHinweisPruefen());
      // Sicherheitsereignisse seit dem letzten Mal (Passwort-Reset für dein Konto angefordert oder durchgeführt)
      unawaited(ref.read(sicherheitsPrueferProvider).pruefenUndMelden(vordergrund: true, hinweis: ref.read(resetHinweisProvider.notifier)));
      // Push (nur Android): Zustand laden und, falls eingeschaltet, bei jedem Start erneut beim Verteiler registrieren
      unawaited(ref.read(pushProvider.notifier).starten());
      // Standort teilen: Empfang der Freigaben anderer (die Verbindung steht nur im Vordergrund oder solange du teilst)
      _standort.starten();
      // Kanal "Standortfreigaben" anlegen, damit er in den Android-Einstellungen steht (sonst erst bei der ersten Freigabe)
      unawaited(ref.read(standortBenachrichtigerProvider).kanalAnlegen());
    });
  }

  @override
  void dispose() {
    _ersteUpdatePruefung?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Abmelden oder Sitzungsverlust: kein Abgleich mehr (der Ausgang bleibt in der Datenbank)
    _sync.stoppen(zustandAendern: false); // mitten im Abbau des Widget-Baums keinen Zustand ändern
    _standort.anhalten();
    super.dispose();
  }

  void _updatePruefen() {
    _letztePruefung = DateTime.now();
    ref.read(updateProvider.notifier).pruefen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // WebSocket und Zeitgeber nur im Vordergrund; bei der Rückkehr sofort abgleichen
    unawaited(ref.read(syncProvider.notifier).vordergrund(s == AppLifecycleState.resumed || s == AppLifecycleState.inactive));
    _standort.vordergrund(s == AppLifecycleState.resumed || s == AppLifecycleState.inactive);
    if (s != AppLifecycleState.resumed) return;
    // Schlüsselstand dieses Geräts (nur die Zahl) erneut melden, wenn die letzte Meldung über 12 Stunden her ist (der Server wertet sie 30 Tage lang)
    unawaited(ref.read(geraetSchluesselMelderZustandProvider).auffrischen(ref.read(apiProvider), ref.read(authProvider).user, ref.read(e2eeProvider)));
    final l = _letztePruefung;
    // Web: häufiger, der Hinweis "Neue Version - neu laden" ist billig (eine kleine JSON-Abfrage)
    final abstand = kIsWeb ? const Duration(minutes: 15) : const Duration(hours: 6);
    if (l == null || DateTime.now().difference(l) > abstand) _updatePruefen();
  }

  @override
  Widget build(BuildContext context) {
    final updateDa = ref.watch(updateProvider.select((u) => u.updateDa));
    final tab = ref.watch(shellTabProvider);
    final ungelesen = ref.watch(chatUngelesenProvider).value ?? 0;
    // Standortfreigaben: Tipp auf die Benachrichtigung bzw. "Ansehen" öffnet die Standort-Seite; im Vordergrund ein dezenter Hinweis
    ref.listen(standortOeffnenProvider, (_, _) => _standortOeffnen());
    ref.listen(standortHinweisProvider, (_, h) {
      if (h != null) _standortHinweisZeigen(h);
    });
    // Nach einem Passwort-Reset: was mit der Passwort-Sicherung geschehen ist (einmal, lange genug zum Lesen)
    ref.listen(resetHinweisProvider, (_, text) => _resetHinweisZeigen(text));
    // Nach der Anmeldung mit Passwort: Gerät automatisch mit dem Schlüssel verbunden (oder warum nicht)
    ref.listen(autoVerbindenHinweisProvider, (_, text) => _autoVerbindenHinweisZeigen(text));
    // Tipp auf die Sicherheitsbenachrichtigung: Profil > Sicherheitsereignisse
    ref.listen(sicherheitOeffnenProvider, (_, _) {
      if (mounted) unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const SicherheitEreignisseScreen())));
    });
    // Betreiber-Warnung: im Vordergrund ein kurzer Hinweis mit festem Text, ein Tipp auf die Benachrichtigung öffnet "Betrieb" (nur für den Betreiber)
    ref.listen(betriebHinweisProvider, (_, _) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(kBetriebHinweisTitel),
            duration: const Duration(seconds: 8),
            // "Öffnen" führt zum Bereich Betrieb (nur der Betreiber bekommt den Hinweis; die Prüfung steht trotzdem im Rückruf)
            action: SnackBarAction(
              label: 'Öffnen',
              onPressed: () {
                if (mounted && ref.read(authProvider).istBetreiber) unawaited(Navigator.of(context).push<void>(BetriebScreen.route()));
              },
            ),
          ),
        );
    });
    ref.listen(betriebOeffnenProvider, (_, _) {
      if (mounted && ref.read(authProvider).istBetreiber) unawaited(Navigator.of(context).push<void>(BetriebScreen.route()));
    });
    ref.listen(shellTabProvider, (_, t) {
      if (t == kStandortTab) unawaited(ref.read(standortBenachrichtigerProvider).alleEntfernen());
      // Wetter-Bereich: bei jedem Wählen frisch abfragen (wie das Öffnen der Seite mobil)
      if (t == kWetterTab) unawaited(ref.read(wetterProvider.notifier).aktualisieren());
    });
    return LayoutBuilder(builder: (context, c) {
      _desktopLayout = c.maxWidth >= kDesktopBreakpoint;
      // Desktop-Layout ab kDesktopBreakpoint, darunter unverändert mobil
      if (c.maxWidth >= kDesktopBreakpoint) {
        if (tab == kStandortTab) _standortBesucht = true;
        if (tab == kWetterTab) _wetterBesucht = true;
        return DesktopShell(screens: _desktopScreens);
      }
      // Standort ist nur im Desktop-Layout ein Tab: nach dem Verkleinern des Fensters zeigt die Leiste wieder die Startseite
      return _mobil(updateDa, tab < kTabs.length ? tab : 0, ungelesen);
    });
  }

  /// Hinweis nach einem Passwort-Reset: ein Dialog, der stehen bleibt, bis die Person ihn bestätigt (kein flüchtiger Hinweis); der Zustand wird sofort geleert.
  void _resetHinweisZeigen(String? text) {
    if (text == null || !mounted) return;
    ref.read(resetHinweisProvider.notifier).setzen(null);
    unawaited(_dialogZeigen('Sicherheitshinweis', text));
  }

  /// Hinweis nach dem automatischen Verbinden (P1): kurz und ruhig, kein Dialog. Der Zustand wird sofort geleert.
  void _autoVerbindenHinweisZeigen(String? text) {
    if (text == null || !mounted) return;
    ref.read(autoVerbindenHinweisProvider.notifier).setzen(null);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 10)));
  }

  Future<void> _dialogZeigen(String titel, String text, {VoidCallback? danach}) async {
    await showDialog<void>(
      useRootNavigator: false,
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(titel),
        scrollable: true,
        content: Text(text, style: const TextStyle(height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Verstanden'),
          ),
        ],
      ),
    );
    danach?.call();
  }

  /// Nach dem Anmelden: Hat die App im Hintergrund erfahren, dass die Sitzung nach einem Passwort-Reset widerrufen wurde, steht der Hinweis, bis er bestätigt ist.
  Future<void> _abgemeldetHinweisPruefen() async {
    try {
      final db = ref.read(appDatabaseProvider);
      if (await db.metaLesen(kSicherheitAbgemeldetSchluessel) == null || !mounted) return;
      await _dialogZeigen(
        'Dein Passwort wurde zurückgesetzt',
        'Du wurdest abgemeldet, weil dein Passwort zurückgesetzt wurde. Warst du das nicht, melde dich mit einem Wiederherstellungscode an und sage es einem Admin. '
            'Details stehen unter Profil > Sicherheitsereignisse.',
      );
      await db.metaLoeschen(kSicherheitAbgemeldetSchluessel);
    } catch (_) {}
  }

  /// Öffnet die Standort-Seite: im Desktop-Layout der Bereich der Shell, sonst eine eigene Seite (nicht doppelt).
  void _standortOeffnen() {
    if (!mounted) return;
    if (_desktopLayout) {
      ref.read(shellTabProvider.notifier).waehlen(kStandortTab);
    } else if (!ref.read(standortSeiteOffenProvider)) {
      unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const StandortScreen())));
    }
  }

  /// Dezenter Hinweis im Vordergrund, außer die Standort-Seite ist selbst zu sehen.
  void _standortHinweisZeigen(StandortHinweis h) {
    if (!mounted) return;
    final sichtbar = ref.read(standortSeiteOffenProvider) || (_desktopLayout && ref.read(shellTabProvider) == kStandortTab);
    if (sichtbar) return;
    final name = ref.read(standortMitgliederProvider)[h.von]?.displayName ?? 'Jemand';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$name teilt seinen Standort'), action: SnackBarAction(label: 'Ansehen', onPressed: _standortOeffnen)));
  }

  Widget _mobil(bool updateDa, int tab, int ungelesen) {
    // Zeichen am Tab: Update-Hinweis am Start, Anzahl ungelesener Nachrichten am Chat
    Widget symbol(int i, IconData icon) {
      final chat = i == kChatTab && ungelesen > 0;
      return Badge(
        isLabelVisible: (updateDa && i == 0) || chat,
        label: chat ? Text(ungelesen > 99 ? '99+' : '$ungelesen') : null,
        child: Icon(icon),
      );
    }

    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: SafeArea(child: LxContentWidth(child: IndexedStack(index: tab, children: _screens))),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => ref.read(shellTabProvider.notifier).waehlen(i),
        destinations: [
          for (var i = 0; i < kTabs.length; i++)
            NavigationDestination(
              icon: symbol(i, kTabs[i].icon),
              selectedIcon: symbol(i, kTabs[i].selectedIcon),
              label: kTabs[i].label,
              tooltip: i == kChatTab && ungelesen > 0 ? 'Chat, $ungelesen ungelesen' : kTabs[i].label,
            ),
        ],
      ),
    );
  }
}
