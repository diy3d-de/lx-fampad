import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/chat/chat_repository.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_screen.dart';
import '../chat/chat_screen.dart';
import '../files/files_screen.dart';
import '../home/desktop_home.dart';
import '../home/home_screen.dart';
import '../lists/lists_screen.dart';
import '../update/update_service.dart';
import 'desktop_shell.dart';
import 'shell_tab.dart';

/// Rahmen der angemeldeten App: Glow-Hintergrund, die fünf Tabs und die Material-3-NavigationBar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  // Die Bereiche tragen GlobalKeys: Beim Wechsel zwischen Mobil und Desktop (Fenstergröße) bleibt ihr Zustand (Eingaben, Scrollposition) erhalten.
  // Start unterscheidet sich je Layout (HomeScreen / DesktopHome) und hat daher keinen Schlüssel.
  final _keys = List.generate(4, (_) => GlobalKey());
  late final _screens = <Widget>[
    const HomeScreen(),
    CalendarScreen(key: _keys[0]),
    ChatScreen(key: _keys[1]),
    FilesScreen(key: _keys[2]),
    ListsScreen(key: _keys[3]),
  ];
  late final _desktopScreens = <Widget>[const DesktopHome(), ..._screens.sublist(1)];

  DateTime? _letztePruefung;
  Timer? _ersteUpdatePruefung;
  late final SyncController _sync;

  @override
  void initState() {
    super.initState();
    _sync = ref.read(syncProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    ref.read(updateProvider.notifier).init();
    // erste Update-Prüfung kurz nach dem Start (Pflicht-Updates sollen früh auffallen), danach beim Zurückkehren in die App
    _ersteUpdatePruefung = Timer(const Duration(seconds: 3), _updatePruefen);
    // Sync-Dienst: Abgleich beim Start, WebSocket und Zeitgeber laufen, solange die angemeldete Oberfläche offen ist
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(syncProvider.notifier).starten();
    });
  }

  @override
  void dispose() {
    _ersteUpdatePruefung?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Abmelden oder Sitzungsverlust: kein Abgleich mehr (der Ausgang bleibt in der Datenbank)
    _sync.stoppen(zustandAendern: false); // mitten im Abbau des Widget-Baums keinen Zustand ändern
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
    if (s != AppLifecycleState.resumed) return;
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
    return LayoutBuilder(builder: (context, c) {
      // Desktop-Layout ab kDesktopBreakpoint, darunter unverändert mobil
      if (c.maxWidth >= kDesktopBreakpoint) return DesktopShell(screens: _desktopScreens);
      return _mobil(updateDa, tab, ungelesen);
    });
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
