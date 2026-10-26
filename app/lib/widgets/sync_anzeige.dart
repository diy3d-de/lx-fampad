import 'package:flutter/material.dart';

import '../constants.dart';
import '../data/sync_state.dart';

/// Text und Farbe des Sync-Zustands (Bedienhilfe-Text, Tooltip, Menü): eine Quelle für alle. Die Zahl offener Änderungen steht nur hier,
/// nie als Konsolen-Zeile auf der Oberfläche. Sichtbar wird Text nur über [syncHinweis], und das nur, wenn etwas nicht stimmt.
(String, Color) syncAnzeige(SyncState s) {
  final offen = s.offeneAenderungen;
  final zahl = offen == 0 ? '' : (offen == 1 ? ', 1 Änderung offen' : ', $offen Änderungen offen');
  return switch (s.status) {
    SyncStatus.synchron => ('Alles aktuell$zahl', kTerminal),
    SyncStatus.laeuft => ('Überträgt …', kTextMuted),
    SyncStatus.offline => ('Gerade keine Verbindung – Änderungen werden nachgeholt$zahl', kTextMuted),
    SyncStatus.fehler => ('Übertragen hat nicht geklappt$zahl', kDanger),
    SyncStatus.updateNoetig => ('Update nötig', kTextMuted),
    SyncStatus.wartung => ('Kurze Wartung$zahl', kWarn),
    SyncStatus.getrennt => ('Nicht verbunden', kTextMuted),
  };
}

/// Ruhiger Satz für die Oberfläche, nur wenn etwas nicht stimmt; bei "synchron" (und beim Abgleichen) `null`: dann zeigt die Oberfläche
/// höchstens einen kleinen Punkt.
String? syncHinweis(SyncState s) => switch (s.status) {
  SyncStatus.synchron || SyncStatus.laeuft => null,
  SyncStatus.offline => 'Gerade keine Verbindung – Änderungen werden nachgeholt',
  SyncStatus.fehler => 'Übertragen hat nicht geklappt',
  SyncStatus.updateNoetig => 'Update nötig',
  SyncStatus.wartung => 'Kurze Wartung',
  SyncStatus.getrennt => 'Nicht verbunden',
};
