// Betrieb, Paket 3 (Nutzung und Stand): Update-Stand der Geräte. Zeigt nur Zähler, Zustände und feste Texte der App (nie ein Servertext, nie Namen, Inhalte oder Pfade). Einzelheiten
// je Person (welches Gerät auf welcher Version ist) stehen in der Seite "Mitglieder" und brauchen eine frische Bestätigung.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/betrieb/betrieb_modelle.dart';
import '../../data/betrieb/betrieb_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'betrieb_bausteine.dart';

class BetriebNutzungSeite extends ConsumerWidget {
  /// Wechselt zur Seite "Mitglieder" (Einzelheiten je Person).
  final VoidCallback oeffneMitglieder;
  const BetriebNutzungSeite({super.key, required this.oeffneMitglieder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(betriebStatusProvider);
    final s = st.status;
    if (s == null) {
      return st.fehler != null ? MeldungsBox(fehlerText(st.fehler!)) : const MeldungsBox('Der Zustand wird geladen …', fehler: false);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (st.fehler != null) ...[MeldungsBox('${fehlerText(st.fehler!)} Angezeigt wird der letzte Stand.'), const SizedBox(height: 12)],
        UpdateStandAbschnitt(s: s, oeffneMitglieder: oeffneMitglieder),
      ],
    );
  }
}

/// Zeile mit einer Zahl rechts; eine Zahl über null bekommt Farbe und Wort in der Beschreibung, nie nur Farbe.
Widget _zahl(int n, {Color farbe = kText}) => Text('$n', textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontMono, fontSize: 15, fontWeight: FontWeight.w700, color: n > 0 ? farbe : kTextMuted));

class UpdateStandAbschnitt extends StatelessWidget {
  final BetriebStatus s;
  final VoidCallback oeffneMitglieder;
  const UpdateStandAbschnitt({super.key, required this.s, required this.oeffneMitglieder});

  @override
  Widget build(BuildContext context) {
    final u = s.updates;
    final app = s.appVersion;
    Widget version(String? v) => Text(v ?? 'unbekannt', textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontMono, fontSize: 13, color: v == null ? kTextMuted : kText));
    final Widget geraete;
    if (u == null) {
      geraete = const LxCard(padding: EdgeInsets.all(14), child: Text('Dieser Server kennt den Update-Stand noch nicht (älterer Stand).', style: TextStyle(color: kTextMuted, fontSize: 13)));
    } else if (u.gesamt == 0) {
      geraete = const LxCard(padding: EdgeInsets.all(14), child: Text('Noch keine Android-Geräte, die ihre Version melden.', style: TextStyle(color: kTextMuted, fontSize: 13)));
    } else {
      geraete = BetriebListe([
        BetriebZeile(
          name: 'Android-Geräte',
          info: u.neueste == null ? 'neueste Version unbekannt (Manifest nicht lesbar)' : 'neueste Version ${u.neueste}',
          pille: _zahl(u.gesamt),
        ),
        BetriebZeile(name: 'Auf der neuesten Version', info: 'aktuell', pille: _zahl(u.aktuell, farbe: kTerminal)),
        BetriebZeile(name: 'Auf älterer Version', info: 'Hinweis, Update empfohlen', pille: _zahl(u.aelter, farbe: kWarn)),
        BetriebZeile(name: 'Unter der Mindestversion', info: 'Update nötig, ab ${u.mindestversion}', pille: _zahl(u.unterMindestversion, farbe: kDanger)),
        if (u.unbekannt > 0) BetriebZeile(name: 'Version unbekannt', info: 'ältere App, meldet noch nichts', pille: _zahl(u.unbekannt)),
        if (u.inaktiv > 0) BetriebZeile(name: 'Lange nicht gesehen', info: 'über 90 Tage, zählt nicht als veraltet', pille: _zahl(u.inaktiv)),
      ]);
    }
    return BetriebAbschnitt(
      label: '// update-stand',
      kind: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BetriebListe([
            BetriebZeile(name: 'Server', info: 'Protokoll ${s.protokoll}', pille: version(s.serverVersion)),
            BetriebZeile(name: 'Web-App', info: 'ausgelieferter Build, immer mit dem Server', pille: version(s.webVersion)),
            BetriebZeile(name: 'Android-App', info: 'neueste veröffentlichte Version', pille: version(app?.version)),
          ]),
          const SizedBox(height: 12),
          geraete,
          if (u != null && u.personenZurueck > 0) ...[
            const SizedBox(height: 4),
            TextButton(
              onPressed: oeffneMitglieder,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44), alignment: Alignment.centerLeft),
              child: Text(u.personenZurueck == 1 ? '1 Person hat ein Gerät auf älterer Version: Einzelheiten (mit Bestätigung)' : '${u.personenZurueck} Personen haben ein Gerät auf älterer Version: Einzelheiten (mit Bestätigung)'),
            ),
          ],
        ],
      ),
      hinweis: 'Die Version meldet jedes Gerät selbst beim Start (kein Beweis). Ausstehende Systemupdates des Servers werden hier bewusst nicht angezeigt: der Dienst darf sie ohne Administratorrechte nicht lesen.',
    );
  }
}
