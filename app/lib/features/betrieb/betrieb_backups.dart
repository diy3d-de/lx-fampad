// Betrieb, Paket 3 (Backups): die Sicherung auf dem Server (Statusdatei des Servers) und die Rückmeldung des NAS (letzte Abholung, letzter Wiederherstellungstest).
// Zeigt nur Zustände, Zeiten und Zähler mit festen Texten der App (nie ein Servertext, nie Pfade oder Dateinamen). Die Angaben des NAS sind ein Hinweis mit Alter,
// kein Beweis: ein übernommenes NAS könnte "ok" melden. Solange das NAS nichts gemeldet hat, ist es "noch nicht eingerichtet", nie ein Alarm.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/betrieb/betrieb_modelle.dart';
import '../../data/betrieb/betrieb_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'betrieb_anzeige.dart';
import 'betrieb_bausteine.dart';

/// Pille zu einer Stufe; ohne Messwert ([BetriebStufe.unbekannt]) "keine Angabe" statt eines Alarms.
Widget _pille(BetriebStufe s, {String ok = 'in Ordnung'}) => StatusPill(s == BetriebStufe.unbekannt ? 'keine Angabe' : stufeText(s, okText: ok), color: stufeFarbe(s));

/// "gestern 22:03 · vor 14 Std" bzw. "–".
String _zeitMitAlter(DateTime? t, DateTime jetzt) => t == null ? '–' : '${zeitText(t, jetzt)} · ${vorText(jetzt.difference(t))}';

class BetriebBackupsSeite extends ConsumerWidget {
  const BetriebBackupsSeite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(betriebStatusProvider);
    final s = st.status;
    if (s == null) {
      return st.fehler != null ? MeldungsBox(fehlerText(st.fehler!)) : const MeldungsBox('Der Zustand wird geladen …', fehler: false);
    }
    final jetzt = DateTime.now();
    final b = s.sicherung;
    final nas = s.nas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (st.fehler != null) ...[MeldungsBox('${fehlerText(st.fehler!)} Angezeigt wird der letzte Stand.'), const SizedBox(height: 12)],
        BetriebAbschnitt(
          label: '// sicherung auf dem server',
          kind: BetriebListe([
            BetriebZeile(
              name: 'Letzte Sicherung',
              info: b.letzterErfolg == null
                  ? 'Statusdatei nicht lesbar'
                  : '${_zeitMitAlter(b.letzterErfolg, jetzt)}${b.bytes == null ? '' : ' · ${groesseText(b.bytes)}'}',
              pille: _pille(b.stufe),
            ),
            if (b.ergebnis != null)
              BetriebZeile(
                name: 'Letzter Lauf',
                info: 'laut Statusdatei des Servers',
                pille: StatusPill(b.ergebnis == 'ok' ? 'erfolgreich' : 'fehlgeschlagen', color: b.ergebnis == 'ok' ? kTerminal : kDanger),
              ),
          ]),
          hinweis: 'Täglich um 03:30 Uhr, verschlüsselt, auf dem Server bleiben die letzten 3 Tage. Hinweis ab 36 Stunden Alter.',
        ),
        const SizedBox(height: 20),
        BetriebAbschnitt(
          label: '// abholung durch das nas',
          kind: !nas.bekannt
              ? const _Leer('Dieser Server kennt die Rückmeldung des NAS noch nicht (älterer Stand).')
              : !nas.eingerichtet
              ? _Leer(
                  nas.ungueltig
                      ? 'Die Rückmeldung des NAS ist nicht lesbar (ungültiges Format). Es gibt deshalb keine Angabe und keine Warnung.'
                      : 'Noch keine Rückmeldung vom NAS. Bis zur Einrichtung gibt es dazu keine Angabe und keine Warnung (Anleitung: Sicherung einrichten, Abschnitt 11).',
                )
              : _Abholung(nas: nas, jetzt: jetzt),
          hinweis: 'Das NAS holt um 04:30 Uhr ab und meldet danach den Stand. Hinweis, wenn die letzte Abholung älter als 36 Stunden ist oder fehlschlug.',
        ),
        const SizedBox(height: 20),
        BetriebAbschnitt(
          label: '// wiederherstellungstest',
          kind: !nas.bekannt
              ? const _Leer('Dieser Server kennt die Rückmeldung des NAS noch nicht (älterer Stand).')
              : !nas.eingerichtet || nas.test.ergebnis == null
              ? const _Leer('Noch kein Wiederherstellungstest gemeldet. Bis dahin gibt es keine Angabe und keine Warnung.')
              : _Test(test: nas.test, jetzt: jetzt),
          hinweis: 'Das NAS spielt wöchentlich eine Sicherung in eine Wegwerf-Datenbank ein. Hinweis, wenn der letzte Erfolg älter als 10 Tage ist oder der Test fehlschlug.',
        ),
        const SizedBox(height: 16),
        const Text(
          'Die Angaben des NAS stammen vom NAS selbst: sie zeigen, was es meldet, und sind kein Beweis. Mach zusätzlich etwa halbjährlich einen Wiederherstellungstest von Hand (Wiederherstellung, Abschnitt 2). Die Seite zeigt nie Pfade, Dateinamen oder Inhalte.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

class _Leer extends StatelessWidget {
  final String text;
  const _Leer(this.text);

  @override
  Widget build(BuildContext context) => LxCard(padding: const EdgeInsets.all(14), child: Text(text, style: const TextStyle(color: kTextMuted, fontSize: 13)));
}

class _Abholung extends StatelessWidget {
  final BetriebNas nas;
  final DateTime jetzt;
  const _Abholung({required this.nas, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final a = nas.abholung;
    return BetriebListe([
      BetriebZeile(
        name: 'Letzte erfolgreiche Abholung',
        info: _zeitMitAlter(a.letzterErfolg, jetzt),
        pille: _pille(a.stufe),
      ),
      if (a.ergebnis != null)
        BetriebZeile(
          name: 'Letzter Lauf',
          info: a.letzterLauf == null ? 'Zeitpunkt unbekannt' : zeitText(a.letzterLauf!, jetzt),
          pille: StatusPill(a.ergebnis == 'ok' ? 'erfolgreich' : 'fehlgeschlagen', color: a.ergebnis == 'ok' ? kTerminal : kDanger),
        ),
      if (a.neuesteSicherung != null || a.anzahl != null)
        BetriebZeile(
          name: 'Stände auf dem NAS',
          info: a.neuesteSicherung == null ? 'neueste Sicherung unbekannt' : 'neueste: ${_zeitMitAlter(a.neuesteSicherung, jetzt)}',
          pille: Text(a.anzahl == null ? '–' : '${a.anzahl}', textAlign: TextAlign.end, style: const TextStyle(fontFamily: kFontMono, fontSize: 13)),
        ),
      if (nas.empfangen != null)
        BetriebZeile(
          name: 'Meldung empfangen',
          info: _zeitMitAlter(nas.empfangen, jetzt),
          pille: const Text('vom NAS', textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
        ),
    ]);
  }
}

class _Test extends StatelessWidget {
  final BetriebNasTest test;
  final DateTime jetzt;
  const _Test({required this.test, required this.jetzt});

  @override
  Widget build(BuildContext context) => BetriebListe([
    BetriebZeile(
      name: 'Letzter erfolgreicher Test',
      info: _zeitMitAlter(test.letzterErfolg, jetzt),
      pille: _pille(test.stufe, ok: 'bestanden'),
    ),
    if (test.ergebnis != null)
      BetriebZeile(
        name: 'Letzter Lauf',
        info: test.letzterLauf == null ? 'Zeitpunkt unbekannt' : zeitText(test.letzterLauf!, jetzt),
        pille: StatusPill(test.ergebnis == 'ok' ? 'bestanden' : 'fehlgeschlagen', color: test.ergebnis == 'ok' ? kTerminal : kDanger),
      ),
    if (test.konfigGeprueft != null)
      BetriebZeile(
        name: 'Konfigurationsarchiv geprüft',
        info: test.konfigGeprueft! ? 'mit dem Schlüssel des Tests gelesen' : 'bewusst nicht (enthält Geheimnisse): halbjährlich von Hand',
        pille: StatusPill(test.konfigGeprueft! ? 'ja' : 'nein', color: test.konfigGeprueft! ? kTerminal : kTextMuted),
      ),
  ]);
}
