import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_screen.dart';
import '../chat/chat_screen.dart';
import '../files/files_screen.dart';
import '../home/home_screen.dart';
import '../lists/lists_screen.dart';
import '../update/update_service.dart';

/// Rahmen der angemeldeten App: Glow-Hintergrund, die fünf Tabs und die Material-3-NavigationBar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> with WidgetsBindingObserver {
  static const _screens = <Widget>[HomeScreen(), CalendarScreen(), ChatScreen(), FilesScreen(), ListsScreen()];

  int _tab = 0;
  DateTime? _letztePruefung;
  Timer? _ersteUpdatePruefung;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.read(updateProvider.notifier).init();
    // erste Update-Prüfung kurz nach dem Start, danach beim Zurückkehren in die App
    _ersteUpdatePruefung = Timer(const Duration(seconds: 15), _updatePruefen);
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(syncProvider.notifier).synchronisieren());
  }

  @override
  void dispose() {
    _ersteUpdatePruefung?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _updatePruefen() {
    _letztePruefung = DateTime.now();
    ref.read(updateProvider.notifier).pruefen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) return;
    ref.read(syncProvider.notifier).synchronisieren();
    final l = _letztePruefung;
    if (l == null || DateTime.now().difference(l) > const Duration(hours: 6)) _updatePruefen();
  }

  @override
  Widget build(BuildContext context) {
    final updateDa = ref.watch(updateProvider.select((u) => u.updateDa));
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(child: SafeArea(child: IndexedStack(index: _tab, children: _screens))),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (var i = 0; i < kTabs.length; i++)
            NavigationDestination(
              icon: Badge(isLabelVisible: updateDa && i == 0, child: Icon(kTabs[i].icon)),
              selectedIcon: Badge(isLabelVisible: updateDa && i == 0, child: Icon(kTabs[i].selectedIcon)),
              label: kTabs[i].label,
            ),
        ],
      ),
    );
  }
}
