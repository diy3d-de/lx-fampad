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
    SyncStatus.fehler => ('Das Übertragen hat nicht geklappt$zahl', kDanger),
    SyncStatus.updateNoetig => ('Update nötig', kTextMuted),
    SyncStatus.wartung => ('Kurze Wartung$zahl', kTextMuted),
    SyncStatus.getrennt => ('Nicht verbunden', kTextMuted),
  };
}

/// Ruhige Zeile für die Oberfläche (Startseite mobil, Fußzeile im Desktop-Layout): Symbol UND Text (nie nur Farbe), optional eine Handlung.
/// [alarm] nur beim Fehler (Symbol in [kDanger]); Wartung ist ein Zustand, kein Fehler (neutral, keine Handlung außer Warten).
class SyncZeileDaten {
  final IconData symbol;
  final String text;

  /// Beschriftung der einen Handlung ("Erneut versuchen"), sonst null.
  final String? handlung;
  final bool alarm;
  const SyncZeileDaten({required this.symbol, required this.text, this.handlung, this.alarm = false});
}

String _aenderungen(int n) => n == 1 ? '1 Änderung' : '$n Änderungen';

/// Der Offline-Text, EINE Stelle für Startseiten-Zeile, Statusleiste der Bereiche und die Rückmeldung nach "Jetzt abgleichen".
String syncOfflineText(int offen) => offen == 0
    ? 'Du bist offline. Alles ist auf diesem Gerät gespeichert.'
    : (offen == 1 ? '1 Änderung wartet auf Verbindung' : '$offen Änderungen warten auf Verbindung');

/// Der Fehlertext, wenn das Übertragen nicht geklappt hat (kurz für Zeile und Rückmeldung).
const kSyncFehlerText = 'Das Übertragen hat nicht geklappt.';

/// Text der Statusleiste über dem Inhalt eines Bereichs (Listen, Kalender): nur, wenn etwas nicht stimmt, sonst `null`.
String? syncLeistenText(SyncState s) {
  final offen = s.offeneAenderungen;
  return switch (s.status) {
    SyncStatus.offline => syncOfflineText(offen),
    SyncStatus.fehler => '$kSyncFehlerText Deine Änderungen bleiben gespeichert und werden erneut gesendet.',
    SyncStatus.updateNoetig => 'Bitte aktualisiere die App, damit wieder alles übertragen wird.',
    SyncStatus.wartung => offen > 0 ? 'Wartung – ${_aenderungen(offen)} ${offen == 1 ? 'wird' : 'werden'} danach übertragen.' : 'Wartung – danach geht es weiter.',
    _ => null,
  };
}

/// Kurze Rückmeldung nach "Jetzt abgleichen" (Hinweis unten).
String syncRueckmeldung(SyncState s) => switch (s.status) {
  SyncStatus.synchron => 'Alles aktuell',
  SyncStatus.offline => syncOfflineText(s.offeneAenderungen),
  SyncStatus.wartung => 'Wartung – Änderungen werden danach übertragen.',
  SyncStatus.getrennt => 'Nicht verbunden',
  _ => s.meldung ?? kSyncFehlerText,
};

/// Die Zeile zum Zustand; bei "synchron" (und beim Abgleichen ohne offene Änderungen) `null`: dann zeigt die Oberfläche nichts (die Kopfzeile hat das
/// Wolken-Symbol). Die Zahl offener Änderungen steht nur, solange welche warten.
SyncZeileDaten? syncZeile(SyncState s) {
  final offen = s.offeneAenderungen;
  return switch (s.status) {
    SyncStatus.synchron => null,
    SyncStatus.laeuft => offen == 0 ? null : SyncZeileDaten(symbol: Icons.sync, text: 'Wird übertragen, noch ${_aenderungen(offen)}'),
    SyncStatus.offline => SyncZeileDaten(symbol: offen == 0 ? Icons.cloud_off : Icons.schedule, text: syncOfflineText(offen)),
    SyncStatus.fehler => const SyncZeileDaten(symbol: Icons.error_outline, text: 'Das Übertragen hat nicht geklappt', handlung: 'Erneut versuchen', alarm: true),
    SyncStatus.updateNoetig => const SyncZeileDaten(symbol: Icons.system_update_alt, text: 'Update nötig'),
    SyncStatus.wartung => const SyncZeileDaten(symbol: Icons.build_outlined, text: 'Wartung läuft. Deine Änderungen bleiben gespeichert.'),
    SyncStatus.getrennt => const SyncZeileDaten(symbol: Icons.cloud_off, text: 'Nicht verbunden'),
  };
}

/// Der Text der Zeile (siehe [syncZeile]); `null`, wenn nichts zu zeigen ist.
String? syncHinweis(SyncState s) => syncZeile(s)?.text;

/// Die ruhige Zeile unter der Kopfzeile (Startseite mobil): Fläche ohne Rand, Symbol + Text + optional eine Handlung (Touch-Ziel mindestens 44 px).
/// Ein Lesegerät bekommt Zustand und Handlung getrennt und liest Änderungen sofort vor (Live-Region).
class SyncZeileFlaeche extends StatelessWidget {
  final SyncZeileDaten daten;
  final VoidCallback? onHandlung;
  const SyncZeileFlaeche({super.key, required this.daten, this.onHandlung});

  @override
  Widget build(BuildContext context) {
    final d = daten;
    // bei stark vergrößerter Schrift steht die Handlung unter dem Text (sonst läuft die Zeile über)
    final darunter = MediaQuery.textScalerOf(context).scale(13) > 18;
    final knopf = d.handlung == null || onHandlung == null
        ? null
        : TextButton(style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: kAccent), onPressed: onHandlung, child: Text(d.handlung!));
    final text = Row(
      children: [
        ExcludeSemantics(child: Icon(d.symbol, size: 16, color: d.alarm ? kDanger : kTextMuted)),
        const SizedBox(width: 10),
        Expanded(child: Text(d.text, style: const TextStyle(fontSize: 13, color: kText))),
        if (knopf != null && !darunter) knopf,
      ],
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: EdgeInsets.only(left: 14, right: knopf != null && !darunter ? 4 : 14, top: 6, bottom: knopf != null && darunter ? 2 : 6),
        decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(18)),
        child: knopf != null && darunter ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [text, Align(alignment: Alignment.centerRight, child: knopf)]) : text,
      ),
    );
  }
}
