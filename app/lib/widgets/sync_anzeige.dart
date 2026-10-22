import 'package:flutter/material.dart';

import '../constants.dart';
import '../data/sync_state.dart';

/// Text und Farbe des Sync-Zustands (Startseite mobil, Fußzeile im Desktop-Layout): eine Quelle für beide.
(String, Color) syncAnzeige(SyncState s) => switch (s.status) {
  SyncStatus.synchron => (s.offeneAenderungen > 0 ? 'synchron · ${s.offeneAenderungen} offen' : 'synchron', kTerminal),
  SyncStatus.laeuft => ('gleiche ab …', kTextMuted),
  SyncStatus.offline => (s.offeneAenderungen > 0 ? 'offline · ${s.offeneAenderungen} offen' : 'offline', kTextMuted),
  SyncStatus.fehler => ('abgleich fehlgeschlagen', kDanger),
  SyncStatus.updateNoetig => ('update nötig', kTextMuted),
  SyncStatus.wartung => (s.offeneAenderungen > 0 ? 'wartung · ${s.offeneAenderungen} offen' : 'wartung', kWarn),
  SyncStatus.getrennt => ('nicht verbunden', kTextMuted),
};
