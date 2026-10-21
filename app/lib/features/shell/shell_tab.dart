import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Gewählter Tab der Navigationsleiste (Reihenfolge wie [kTabs]); Karten der Startseite wechseln darüber in einen Bereich.
class ShellTab extends Notifier<int> {
  @override
  int build() => 0;

  void waehlen(int index) => state = index;
}

final shellTabProvider = NotifierProvider<ShellTab, int>(ShellTab.new);

/// Index des Listen-Tabs in [kTabs].
const kListenTab = 4;

/// Index des Aufgaben-Tabs in [kTabs].
const kAufgabenTab = 5;

/// Index des Kalender-Tabs in [kTabs].
const kKalenderTab = 1;

/// Index des Chat-Tabs in [kTabs].
const kChatTab = 2;

/// Index des Standort-Bereichs in [kDesktopTabs] (nur im Desktop-Layout ein Bereich der Shell; mobil keine Tab-Leiste dafür).
const kStandortTab = 6;

/// Index des Wetter-Bereichs in [kDesktopTabs] (nur im Desktop-Layout ein Bereich der Shell, und dort nur in der Seitenleiste, wenn die Kachel sichtbar ist; mobil eine Seite).
const kWetterTab = 7;
