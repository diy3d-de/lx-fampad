// Betrieb, Paket 3 (Nutzung und Stand): aktive Personen und Geräte, Verlaufsgrafiken, Wetter-Dienst und Push-Wecker sowie der Update-Stand der Geräte. Zeigt nur Zahlen,
// Zustände und feste Texte der App (nie ein Servertext, nie Namen, Inhalte, Endpunkte oder Pfade). Einzelheiten je Person (welches Gerät auf welcher Version ist) stehen in der
// Seite "Mitglieder" und brauchen eine frische Bestätigung.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/betrieb/betrieb_modelle.dart';
import '../../data/betrieb/betrieb_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'betrieb_anzeige.dart';
import 'betrieb_bausteine.dart';
import 'betrieb_verlauf.dart';

class BetriebNutzungSeite extends ConsumerStatefulWidget {
  /// Wechselt zur Seite "Mitglieder" (Einzelheiten je Person).
  final VoidCallback oeffneMitglieder;
  const BetriebNutzungSeite({super.key, required this.oeffneMitglieder});

  @override
  ConsumerState<BetriebNutzungSeite> createState() => _BetriebNutzungSeiteState();
}

class _BetriebNutzungSeiteState extends ConsumerState<BetriebNutzungSeite> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final v = ref.read(betriebVerlaufProvider);
      if (v.wert == null && !v.laedt) unawaited(ref.read(betriebVerlaufProvider.notifier).laden());
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(betriebStatusProvider);
    final s = st.status;
    if (s == null) {
      return st.fehler != null ? MeldungsBox(fehlerText(st.fehler!)) : const MeldungsBox('Der Zustand wird geladen …', fehler: false);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (st.fehler != null) ...[MeldungsBox('${fehlerText(st.fehler!)} Angezeigt wird der letzte Stand.'), const SizedBox(height: 12)],
        _NutzungAbschnitt(s: s),
        const SizedBox(height: 20),
        const _VerlaufAbschnitt(),
        const SizedBox(height: 20),
        _WetterPushAbschnitt(s: s),
        if (s.ingest?.zeigen ?? false) ...[const SizedBox(height: 20), _IngestAbschnitt(i: s.ingest!)],
        const SizedBox(height: 20),
        UpdateStandAbschnitt(s: s, oeffneMitglieder: widget.oeffneMitglieder),
      ],
    );
  }
}

/// Zeile mit einer Zahl rechts; eine Zahl über null bekommt Farbe und Wort in der Beschreibung, nie nur Farbe.
Widget _zahl(int n, {Color farbe = kText}) => Text('$n', textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 15, fontWeight: FontWeight.w700, color: n > 0 ? farbe : kTextMuted));

Widget _wert(String text, {Color farbe = kText}) => Text(text, textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, color: farbe));

// ------------------------------------------------------------------ Nutzung (aktuelle Zahlen)

class _NutzungAbschnitt extends ConsumerWidget {
  final BetriebStatus s;
  const _NutzungAbschnitt({required this.s});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(betriebVerlaufProvider);
    // "heute"-Zahlen nur, wenn der letzte Messpunkt wirklich von heute (UTC) ist; sonst wie ohne Messpunkte (nie Zahlen von gestern als heutige ausgeben)
    final letzter = v.wert?.letzter;
    final jetzt = DateTime.now().toUtc();
    final heute = letzter != null && letzter.tag.year == jetzt.year && letzter.tag.month == jetzt.month && letzter.tag.day == jetzt.day ? letzter : null;
    final Widget inhalt;
    if (heute == null) {
      inhalt = BetriebListe([
        BetriebZeile(name: 'Mitglieder', info: '${s.geraete} Geräte · ${s.sitzungen} Sitzungen', pille: _zahl(s.mitglieder)),
        BetriebZeile(name: 'Datenbank', info: 'Größe', pille: _wert(groesseText(s.datenbankBytes))),
        const BetriebZeile(name: 'Messpunkte', info: 'noch keine oder nicht abrufbar', pille: Text('–', style: TextStyle(color: kTextMuted))),
      ]);
    } else {
      inhalt = BetriebListe([
        BetriebZeile(name: 'Aktive Personen', info: 'letzte 7 Tage · letzte 30 Tage · von ${s.mitglieder}', pille: _wert('${heute.personen7} · ${heute.personen30}')),
        BetriebZeile(name: 'Aktive Geräte', info: 'letzte 7 Tage · letzte 30 Tage · von ${s.geraete}', pille: _wert('${heute.geraete7} · ${heute.geraete30}')),
        BetriebZeile(name: 'Abgleiche heute', info: 'Anfragen an den Abgleich seit 00:00 UTC', pille: _zahl(heute.abgleiche)),
        BetriebZeile(name: 'Fehler im Abgleich heute', info: 'Serverfehler (ohne Wartung)', pille: _zahl(heute.fehler, farbe: kDanger)),
        BetriebZeile(name: 'Rate-Limit-Treffer heute', info: 'Antworten „zu viele Anfragen“', pille: _zahl(heute.rateLimit, farbe: kWarn)),
        BetriebZeile(name: 'Datenbank', info: 'Größe', pille: _wert(groesseText(heute.datenbankBytes ?? s.datenbankBytes))),
        BetriebZeile(name: 'Dateiablage', info: heute.dateienBytes == null ? 'nicht gemessen oder leer' : 'Summe, ohne Namen', pille: _wert(heute.dateienBytes == null ? '–' : groesseText(heute.dateienBytes))),
      ]);
    }
    return BetriebAbschnitt(
      label: 'Nutzung',
      kind: inhalt,
      hinweis: 'Aktiv heißt: ein Gerät hat sich angemeldet, erneuert oder abgeglichen. Es werden nur Zahlen gezählt, nie Inhalte, Titel oder Namen.',
    );
  }
}

// ------------------------------------------------------------------ Verlauf

class _VerlaufAbschnitt extends ConsumerWidget {
  const _VerlaufAbschnitt();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(betriebVerlaufProvider);
    final v = z.wert;
    final jetzt = DateTime.now().toUtc();
    final Widget inhalt;
    if (v == null) {
      inhalt = z.fehler != null
          ? LxCard(
              padding: const EdgeInsets.all(14),
              child: Text(z.fehler is ApiException && (z.fehler! as ApiException).status == 404 ? 'Dieser Server kennt den Verlauf noch nicht (älterer Stand).' : 'Der Verlauf ist gerade nicht abrufbar. Mit „Prüfung neu starten“ erneut versuchen.', style: const TextStyle(color: kTextMuted, fontSize: 13)),
            )
          : const LxCard(padding: EdgeInsets.all(14), child: Text('Der Verlauf wird geladen …', style: TextStyle(color: kTextMuted, fontSize: 13)));
    } else {
      final n = z.tage;
      final von = DateTime.utc(jetzt.year, jetzt.month, jetzt.day).subtract(Duration(days: n - 1));
      List<double?> reihe(num? Function(VerlaufTag) f) => verlaufReihe(v.tage, n, jetzt, f);
      final db = reihe((t) => t.datenbankBytes);
      final dateien = reihe((t) => t.dateienBytes);
      final dbLetzter = db.lastWhere((x) => x != null, orElse: () => null);
      final dateienLetzter = dateien.lastWhere((x) => x != null, orElse: () => null);
      final personen30 = reihe((t) => t.personen30);
      final abgleiche = reihe((t) => t.abgleiche);
      inhalt = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VerlaufDiagramm(
            titel: 'aktive personen',
            zuletzt: personen30.lastWhere((x) => x != null, orElse: () => null)?.round().toString() ?? '–',
            reihen: [
              VerlaufReihe(name: 'letzte 30 Tage', werte: personen30, farbe: kAccent),
              VerlaufReihe(name: 'letzte 7 Tage', werte: reihe((t) => t.personen7), farbe: kNeural),
            ],
            von: von,
            bis: jetzt,
            format: anzahlText,
          ),
          const SizedBox(height: 12),
          VerlaufDiagramm(
            titel: 'abgleiche je tag',
            zuletzt: abgleiche.lastWhere((x) => x != null, orElse: () => null)?.round().toString() ?? '–',
            reihen: [VerlaufReihe(name: 'Abgleiche', werte: abgleiche, farbe: kAccent)],
            von: von,
            bis: jetzt,
            format: anzahlText,
            balken: true,
          ),
          const SizedBox(height: 12),
          VerlaufDiagramm(
            titel: 'fehler und limits je tag',
            zuletzt: '${reihe((t) => t.fehler).lastWhere((x) => x != null, orElse: () => null)?.round() ?? '–'} · ${reihe((t) => t.rateLimit).lastWhere((x) => x != null, orElse: () => null)?.round() ?? '–'}',
            reihen: [
              VerlaufReihe(name: 'Fehler im Abgleich', werte: reihe((t) => t.fehler), farbe: kDanger),
              VerlaufReihe(name: 'Rate-Limit-Treffer', werte: reihe((t) => t.rateLimit), farbe: kWarn),
            ],
            von: von,
            bis: jetzt,
            format: anzahlText,
          ),
          const SizedBox(height: 12),
          VerlaufDiagramm(
            titel: 'datenbankgröße',
            zuletzt: dbLetzter == null ? '–' : groesseWert(dbLetzter),
            reihen: [VerlaufReihe(name: 'Datenbank', werte: db, farbe: kTerminal)],
            von: von,
            bis: jetzt,
            format: groesseWert,
            achse: VerlaufAchse.bereich,
          ),
          if (dateienLetzter != null) ...[
            const SizedBox(height: 12),
            VerlaufDiagramm(
              titel: 'dateiablage',
              zuletzt: groesseWert(dateienLetzter),
              reihen: [VerlaufReihe(name: 'Dateiablage', werte: dateien, farbe: kTerminal)],
              von: von,
              bis: jetzt,
              format: groesseWert,
              achse: VerlaufAchse.bereich,
            ),
          ],
          if (v.tage.isEmpty) ...[const SizedBox(height: 8), const Text('Noch keine Messpunkte: der Server schreibt sie ab jetzt alle 5 Minuten in den Tagespunkt.', style: TextStyle(fontSize: 12, color: kTextMuted))],
        ],
      );
    }
    return BetriebAbschnitt(
      label: 'Verlauf',
      kind: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in kVerlaufSpannen)
                Semantics(
                  button: true,
                  selected: z.tage == t,
                  label: 'Verlauf der letzten $t Tage',
                  excludeSemantics: true,
                  child: Material(
                    color: z.tage == t ? kAccentSoft : Colors.transparent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide(color: z.tage == t ? kAccent : Colors.transparent)),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => unawaited(ref.read(betriebVerlaufProvider.notifier).laden(tage: t)),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Text('$t Tage', style: TextStyle(fontWeight: FontWeight.w600, color: z.tage == t ? kAccent : kText)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          inhalt,
        ],
      ),
      hinweis: v == null ? null : 'Ein Messpunkt je Tag (UTC), Aufbewahrung ${v.aufbewahrungTage} Tage. Tage ohne Messpunkt bleiben Lücken. Nur Zahlen.',
    );
  }
}

// ------------------------------------------------------------------ Wetter und Push

class _WetterPushAbschnitt extends StatelessWidget {
  final BetriebStatus s;
  const _WetterPushAbschnitt({required this.s});

  @override
  Widget build(BuildContext context) {
    final jetzt = DateTime.now();
    final w = s.dienst('weather');
    final n = s.dienst('ntfy');
    final push = s.push;
    final wStufe = w?.stufe ?? BetriebStufe.unbekannt;
    final fehlerZahl = w?.detail['errorCount'] is num ? (w!.detail['errorCount'] as num).toInt() : null;
    final minuten = w?.detail['lastOkMinutesAgo'] is num ? (w!.detail['lastOkMinutesAgo'] as num).toInt() : null;
    final code = w?.detail['lastErrorCode'];
    final wetterInfo = switch (wStufe) {
      BetriebStufe.aus => 'ausgeschaltet (WEATHER_ENABLED)',
      BetriebStufe.fehler => 'abgeschaltet: Zugangsdaten ungültig, neu einrichten',
      BetriebStufe.warn when w?.detail['configured'] == false => 'keine Zugangsdaten gespeichert',
      BetriebStufe.warn || BetriebStufe.ok => minuten == null ? 'noch kein erfolgreicher Abruf' : 'letzter Erfolg ${vorText(Duration(minutes: minuten))}',
      _ => 'Zustand unbekannt',
    };
    final nStufe = n?.stufe ?? BetriebStufe.unbekannt;
    final Widget pushZeilen;
    if (push == null) {
      pushZeilen = BetriebZeile(name: 'Push-Wecker (ntfy)', info: nStufe == BetriebStufe.aus ? 'ausgeschaltet' : '${s.pushGeraete} Geräte angemeldet', pille: StatusPill(stufeText(nStufe), color: stufeFarbe(nStufe)));
    } else {
      pushZeilen = Column(
        children: [
          BetriebZeile(
            name: 'ntfy (Push-Wecker)',
            info: nStufe == BetriebStufe.aus ? 'ausgeschaltet' : (nStufe == BetriebStufe.ok ? 'lokal erreichbar' : 'lokal nicht erreichbar'),
            pille: StatusPill(stufeText(nStufe), color: stufeFarbe(nStufe)),
          ),
          const Divider(height: 1, color: kBorderSoft),
          BetriebZeile(name: 'Geräte mit Wecker', info: '${push.deaktiviert} deaktiviert · ${push.fehlerhaft} mit Zustellfehler in Folge', pille: _zahl(push.aktiv, farbe: kTerminal)),
          const Divider(height: 1, color: kBorderSoft),
          BetriebZeile(name: 'Zustellfehler, 24 Stunden', info: 'Geräte mit mindestens einem Fehler', pille: _zahl(push.fehler24h, farbe: kWarn)),
          const Divider(height: 1, color: kBorderSoft),
          BetriebZeile(name: 'Letzte Zustellung', info: 'an irgendein Gerät', pille: _wert(push.letzterErfolg == null ? '–' : vorText(jetzt.difference(push.letzterErfolg!)))),
        ],
      );
    }
    return BetriebAbschnitt(
      label: 'Wetter und Push',
      kind: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          children: [
            BetriebZeile(name: 'Wetter-Dienst', info: wetterInfo, pille: StatusPill(stufeText(wStufe), color: stufeFarbe(wStufe))),
            if (fehlerZahl != null && fehlerZahl > 0) ...[
              const Divider(height: 1, color: kBorderSoft),
              BetriebZeile(name: 'Fehler in Folge', info: code is String ? wetterFehlerText(code) : 'Ursache unbekannt', pille: _zahl(fehlerZahl, farbe: kWarn)),
            ],
            const Divider(height: 1, color: kBorderSoft),
            pushZeilen,
          ],
        ),
      ),
      hinweis: 'Der Wetter-Dienst läuft als eigener Dienst (lx-fampad-weather). Die Seite zeigt nur Zähler und feste Codes, nie Fehlertexte, Endpunkte oder Zugangsdaten.',
    );
  }
}

// ------------------------------------------------------------------ Home Assistant (Einwurf)

class _IngestAbschnitt extends StatelessWidget {
  final BetriebIngest i;
  const _IngestAbschnitt({required this.i});

  @override
  Widget build(BuildContext context) {
    final jetzt = DateTime.now();
    final stufe = i.aktiv ? i.stufe : BetriebStufe.aus;
    return BetriebAbschnitt(
      label: 'Home Assistant',
      kind: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          children: [
            BetriebZeile(name: 'Einwurf', info: ingestInfo(i), pille: StatusPill(stufeText(stufe), color: stufeFarbe(stufe))),
            const Divider(height: 1, color: kBorderSoft),
            BetriebZeile(name: 'Verbindungen', info: 'aktive Zugangsschlüssel', pille: _wert(i.tokens == null ? '–' : '${i.tokens}')),
            const Divider(height: 1, color: kBorderSoft),
            BetriebZeile(name: 'Postfach', info: i.postfach == null ? 'nicht messbar' : 'Päckchen, Grenze ${i.grenze}', pille: _wert(i.postfach == null ? '–' : '${i.postfach}')),
            const Divider(height: 1, color: kBorderSoft),
            BetriebZeile(name: 'Ältestes Päckchen', info: 'wartet auf Abholung', pille: _wert(i.postfach == 0 ? 'keins' : (i.aeltestStunden == null ? '–' : vorText(Duration(hours: i.aeltestStunden!))))),
            const Divider(height: 1, color: kBorderSoft),
            BetriebZeile(name: 'Letzter Einwurf', info: 'zuletzt genutzte Verbindung', pille: _wert(i.letzterEinwurf == null ? '–' : vorText(jetzt.difference(i.letzterEinwurf!)))),
          ],
        ),
      ),
      hinweis: 'Der Server sieht nur undurchsichtige Päckchen. Die Seite zeigt nur Zahlen und Zeiten, nie Schlüssel, Namen oder Werte.',
    );
  }
}

// ------------------------------------------------------------------ Update-Stand

class UpdateStandAbschnitt extends StatelessWidget {
  final BetriebStatus s;
  final VoidCallback oeffneMitglieder;
  const UpdateStandAbschnitt({super.key, required this.s, required this.oeffneMitglieder});

  @override
  Widget build(BuildContext context) {
    final u = s.updates;
    final app = s.appVersion;
    Widget version(String? v) => Text(v ?? 'unbekannt', textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, color: v == null ? kTextMuted : kText));
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
      label: 'Update-Stand',
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
