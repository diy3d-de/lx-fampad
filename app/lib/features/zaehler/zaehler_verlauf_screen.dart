// Verlauf eines Zählers oder einer Gruppe (Abschnitt 6l): Balken je Monat (mit Vorjahr als Hülle, bedienbar), Zeitraumwahl (Kalenderjahr oder Abrechnungsperiode, zurückblättern),
// Zähler-Umschalter, Summen, Hochrechnung, Kosten und Abschläge (je Zähler schaltbar), Solar-Ersparnis und Amortisation, die letzten Stände mit Ändern und Löschen und eine Textfassung
// der Werte für Screenreader. Alles wird lokal aus den Ende-zu-Ende verschlüsselten Ständen berechnet.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/zaehler/zaehler_logik.dart';
import '../../data/zaehler/zaehler_modelle.dart';
import '../../data/zaehler/zaehler_monate.dart';
import '../../data/zaehler/zaehler_repository.dart';
import '../../data/zaehler/zaehler_state.dart';
import '../../data/zaehler/zaehler_uebersicht.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_anzeige.dart' show minutenTaktProvider;
import '../lists/list_dialogs.dart' show AuswahlKnopf, bestaetigen;
import 'zaehler_anzeige.dart';
import 'zaehler_bericht_screen.dart';
import 'zaehler_diagramm.dart';
import 'zaehler_editor.dart';
import 'zaehler_monat_screen.dart';
import 'zaehler_stand_screen.dart';

/// Öffnet den Verlauf der Kachel mit diesem Schlüssel (`z:<ID>` oder `g:<Art>:<Gruppe>`).
Future<void> verlaufOeffnen(BuildContext context, String schluessel) {
  if (!ProviderScope.containerOf(context).read(zaehlerDarfProvider)) return Future.value();
  return Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ZaehlerVerlaufScreen(schluessel: schluessel)));
}

enum _Modus { jahr, periode }

class ZaehlerVerlaufScreen extends ConsumerStatefulWidget {
  final String schluessel;
  const ZaehlerVerlaufScreen({super.key, required this.schluessel});

  @override
  ConsumerState<ZaehlerVerlaufScreen> createState() => _ZaehlerVerlaufScreenState();
}

class _ZaehlerVerlaufScreenState extends ConsumerState<ZaehlerVerlaufScreen> {
  late String _schluessel = widget.schluessel;
  var _modus = _Modus.jahr;
  var _zurueck = 0;
  var _vorjahr = true;
  var _tabelle = false;
  var _alleStaende = false;
  int? _cursor;

  Zeitraum _zeitraum(ZaehlerKachel k, DateTime heute) {
    final i = k.erste.inhalt;
    if (_modus == _Modus.jahr) {
      final j = heute.year - _zurueck;
      return Zeitraum(DateTime.utc(j, 1, 1), DateTime.utc(j + 1, 1, 1));
    }
    var p = abrechnungsperiode(heute, periodeMonat: i.periodeMonat, periodeTag: i.periodeTag);
    for (var n = 0; n < _zurueck; n++) {
      p = periodeDavor(p, periodeMonat: i.periodeMonat, periodeTag: i.periodeTag);
    }
    return p;
  }

  String _zeitraumTitel(ZaehlerKachel k, Zeitraum z) {
    final i = k.erste.inhalt;
    if (_modus == _Modus.jahr) return '${z.start.year}';
    return 'Periode ${periodenBezeichnung(z, periodeMonat: i.periodeMonat, periodeTag: i.periodeTag)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(zaehlerDarfProvider)) return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.')]);
    final daten = ref.watch(zaehlerDatenProvider);
    final k = daten.kachel(_schluessel);
    if (k == null) {
      return AuthSeite(label: 'Verlauf', titel: 'Verlauf', maxBreite: kMaxContentWidth, kinder: [if (!daten.geladen) const Center(child: CircularProgressIndicator()) else const MeldungsBox('Diesen Zähler gibt es nicht mehr.', fehler: false)]);
    }
    final heute = zaehlerHeute(ref.watch(minutenTaktProvider).value ?? DateTime.now());
    final einheit = k.einheit;
    final farbe = zaehlerFarbe(k.art);
    final erzeugung = istErzeugung(k.art);
    final z = _zeitraum(k, heute);
    final vj = vorjahrVon(z);
    final monate = kachelMonate(k, z.start, z.ende);
    final vjMonate = kachelMonate(k, vj.start, vj.ende);
    final balken = <DiagrammBalken>[
      for (var i = 0; i < monate.length; i++)
        DiagrammBalken(
          label: monatBuchstabe(monate[i].monat),
          beschriftung: '${monatName(monate[i].monat)} ${monate[i].jahr}',
          milli: monate[i].tage > 0 && (monate[i].vollstaendig || monate[i].milli > 0) ? monate[i].milli : null,
          vorjahrMilli: i < vjMonate.length && vjMonate[i].tage > 0 && (vjMonate[i].vollstaendig || vjMonate[i].milli > 0) ? vjMonate[i].milli : null,
          teilweise: !monate[i].vollstaendig,
        ),
    ];
    // Vorgabe: der jüngste Monat mit Werten
    final vorgabe = balken.lastIndexWhere((b) => b.milli != null);
    final c = _cursor != null && _cursor! < balken.length ? _cursor : (vorgabe >= 0 ? vorgabe : null);
    String wertText(int i) {
      final b = balken[i];
      final v = b.milli == null ? 'noch offen' : verbrauchAnzeige(b.milli!, einheit);
      final vjT = b.vorjahrMilli == null ? '' : ', Vorjahr ${verbrauchAnzeige(b.vorjahrMilli!, einheit)}';
      return '${b.beschriftung}: $v$vjT';
    }

    final wort = wertWort(k.art);
    final semantik = StringBuffer('$wort je Monat, ${k.titel}, ${_zeitraumTitel(k, z)}. ');
    for (var i = 0; i < balken.length; i++) {
      semantik.write('${wertText(i)}. ');
    }
    final gesamt = kachelVerbrauch(k, z.start, z.ende);
    final vjGesamt = kachelVerbrauch(k, vj.start, vj.ende);
    final laufend = !heute.isBefore(z.start) && heute.isBefore(z.ende);
    final einzel = !k.istGruppe ? k.erste : null;
    final kostenAn = einzel != null && einzel.inhalt.kosten && !erzeugung;
    return AuthSeite(
      label: k.art.anzeige,
      titel: k.titel,
      maxBreite: kMaxContentWidth,
      aktionen: [
        IconButton(tooltip: 'Bericht als PDF', icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: () => berichtOeffnen(context, schluessel: k.schluessel)),
      ],
      fussleiste: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: k.zumAblesen.isEmpty ? null : () => standEintragenOeffnen(context, reiheIds: [for (final r in k.zumAblesen) r.id]),
              icon: const Icon(Icons.edit_note),
              label: Text(k.istGruppe ? 'Alle ablesen' : (k.erste.monatlich ? 'Monatswert eintragen' : 'Stand eintragen')),
            ),
          ),
        ],
      ),
      kinder: [
        // Zähler-Umschalter
        if (daten.kacheln.length > 1 || !daten.kacheln.any((x) => x.schluessel == k.schluessel)) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in [...daten.kacheln, if (!daten.kacheln.any((y) => y.schluessel == k.schluessel)) k])
                AuswahlKnopf(
                  text: x.titel,
                  gewaehlt: x.schluessel == k.schluessel,
                  onTap: () => setState(() {
                    _schluessel = x.schluessel;
                    _cursor = null;
                    _zurueck = 0;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // Zeitraumwahl
        Row(
          children: [
            IconButton(tooltip: _modus == _Modus.jahr ? 'Ein Jahr zurück' : 'Eine Periode zurück', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.chevron_left), onPressed: () => setState(() {
              _zurueck++;
              _cursor = null;
            })),
            Expanded(child: Center(child: Text(_zeitraumTitel(k, z), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontWeight: FontWeight.w700, fontSize: 16)))),
            IconButton(tooltip: _modus == _Modus.jahr ? 'Ein Jahr weiter' : 'Eine Periode weiter', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.chevron_right), onPressed: _zurueck == 0 ? null : () => setState(() {
              _zurueck--;
              _cursor = null;
            })),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AuswahlKnopf(text: 'Kalenderjahr', gewaehlt: _modus == _Modus.jahr, onTap: () => setState(() {
              _modus = _Modus.jahr;
              _zurueck = 0;
              _cursor = null;
            })),
            if (k.erste.inhalt.periodeMonat != 1 || k.erste.inhalt.periodeTag != 1)
              AuswahlKnopf(text: 'Abrechnungsperiode', gewaehlt: _modus == _Modus.periode, onTap: () => setState(() {
                _modus = _Modus.periode;
                _zurueck = 0;
                _cursor = null;
              })),
            AuswahlKnopf(text: _vorjahr ? 'Vorjahr zeigen' : 'Ohne Vorjahr', gewaehlt: _vorjahr, onTap: () => setState(() => _vorjahr = !_vorjahr)),
          ],
        ),
        const SizedBox(height: 12),
        LxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MonoLabel(c == null ? _zeitraumTitel(k, z) : balken[c].beschriftung.toLowerCase(), color: kTextMuted),
                        Semantics(
                          liveRegion: true,
                          child: Text(c == null || balken[c].milli == null ? (c == null ? 'Noch keine Werte' : 'Noch offen') : verbrauchAnzeige(balken[c].milli!, einheit), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontWeight: FontWeight.w700, fontSize: 18)),
                        ),
                      ],
                    ),
                  ),
                  if (c != null) Flexible(child: _Veraenderung(balken: balken[c], einheit: einheit, erzeugung: erzeugung)),
                ],
              ),
              const SizedBox(height: 8),
              if (balken.isEmpty)
                const Text('Für diesen Zeitraum gibt es keine Werte.', style: TextStyle(color: kTextMuted))
              else
                VerbrauchsDiagramm(balken: balken, farbe: farbe, cursor: c, onCursor: (i) => setState(() => _cursor = i), vorjahr: _vorjahr, semantik: semantik.toString(), wertText: wertText),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => setState(() => _tabelle = !_tabelle), child: Text(_tabelle ? 'Werte ausblenden' : 'Werte als Liste')),
              ),
              if (_tabelle)
                for (var i = 0; i < balken.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text(balken[i].beschriftung)),
                      Text(balken[i].milli == null ? '–' : verbrauchAnzeige(balken[i].milli!, einheit), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13)),
                      SizedBox(width: 90, child: Text(balken[i].vorjahrMilli == null ? '' : verbrauchAnzeige(balken[i].vorjahrMilli!, '', mitEinheit: false), textAlign: TextAlign.right, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted))),
                    ]),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LxCard(
          child: Column(
            children: [
              _Zeile(laufend ? '${_zeitraumTitel(k, z)} bisher' : '$wort ${_zeitraumTitel(k, z)}', gesamt.abgedeckteTage == 0 ? 'noch offen' : '${verbrauchAnzeige(gesamt.milli, einheit)}${gesamt.vollstaendig ? '' : ' (unvollständig)'}'),
              if (vjGesamt.abgedeckteTage > 0) _Zeile('Vorjahr', '${verbrauchAnzeige(vjGesamt.milli, einheit)}${vjGesamt.vollstaendig ? '' : ' (unvollständig)'}'),
              ..._hochrechnung(k, z, heute, vjGesamt, einheit),
              ..._kosten(k, z, heute, kostenAn),
              if (einzel != null && erzeugung && einzel.inhalt.kosten) ..._solar(einzel, z, heute),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (kostenAn && einzel.inhalt.preise.isEmpty)
          const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('Für die Kosten fehlt noch ein Tarif. Trage ihn unter „Zähler bearbeiten“ ein.', style: TextStyle(fontSize: 12, color: kTextMuted))),
        if (ungewoehnlichHoch(k, heute))
          const Padding(padding: EdgeInsets.only(bottom: 12), child: Row(children: [Icon(Icons.warning_amber_rounded, size: 16, color: kWarn), SizedBox(width: 6), Expanded(child: Text('Der Verbrauch des letzten Monats liegt über deiner Warnschwelle.', style: TextStyle(fontSize: 13, color: kWarn)))])),
        // Stände je Zähler
        for (final r in k.reihen) _StaendeAbschnitt(reihe: r, daten: daten, mitTitel: k.istGruppe, alle: _alleStaende),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => setState(() => _alleStaende = !_alleStaende), child: Text(k.reihen.every((r) => r.monatlich) ? (_alleStaende ? 'Nur die letzten Werte' : 'Alle Werte zeigen') : (_alleStaende ? 'Nur die letzten Stände' : 'Alle Stände zeigen'))),
        ),
      ],
    );
  }

  List<Widget> _hochrechnung(ZaehlerKachel k, Zeitraum z, DateTime heute, Verbrauch vjGesamt, String einheit) {
    if (heute.isBefore(z.start) || !heute.isBefore(z.ende)) return const [];
    var summe = 0;
    var geschaetzt = 0;
    for (final r in k.reihen) {
      if (r.monatlich) {
        final h = monatsHochrechnung(r.monatswerte, z, heute);
        if (h == null) return const [];
        summe += h.prognoseMilli;
        if (h.geschaetzteMonate > geschaetzt) geschaetzt = h.geschaetzteMonate;
        continue;
      }
      final h = hochrechnung(r.kurve, z, heute);
      if (h == null) return const [];
      summe += h.prognoseMilli;
    }
    final schaetzText = geschaetzt == 0 ? '' : ' · geschätzt, $geschaetzt ${geschaetzt == 1 ? 'Monat' : 'Monate'} aus Vorjahr oder Durchschnitt';
    return [_Zeile('Hochrechnung ${_zeitraumTitel(k, z)}', '${verbrauchAnzeige(summe, einheit)}$schaetzText${vjGesamt.vollstaendig ? ' (Vorjahr ${verbrauchAnzeige(vjGesamt.milli, einheit, mitEinheit: false)})' : ''}')];
  }

  List<Widget> _kosten(ZaehlerKachel k, Zeitraum z, DateTime heute, bool an) {
    if (!an) return const [];
    final r = k.erste;
    if (r.inhalt.preise.isEmpty) return const [];
    final p = periodenKosten(r.inhalt, r.kurve, z, heute);
    final b = p.bisher;
    final laufend = p.laufend;
    final ganz = p.ganzePeriode;
    return [
      _Zeile(laufend ? 'Kosten bisher' : 'Kosten', '${euroAnzeige(b.gesamtCent)}${b.preisLuecke ? ' (Preis fehlt für einen Teil)' : ''}'),
      _Zeile('davon', 'Arbeit ${euroKurz(b.verbrauchCent)} + Grund ${euroKurz(b.grundCent)}${b.zaehlerCent > 0 ? ' + Zähler ${euroKurz(b.zaehlerCent)}' : ''}'),
      if (laufend && p.prognose != null) _Zeile('Kosten Hochrechnung', euroAnzeige(p.prognose!.gesamtCent)),
      if (p.abschlaegeBisherCent != null) _Zeile(laufend ? 'Abschläge bisher' : 'Abschläge', euroAnzeige(laufend ? p.abschlaegeBisherCent! : p.abschlaegeGesamtCent!)),
      if (p.saldoCent != null && ganz != null) _Zeile(laufend ? 'Voraussichtlich' : 'Saldo', p.saldoCent! >= 0 ? 'Nachzahlung ca. ${euroAnzeige(p.saldoCent!)}' : 'Rückzahlung ca. ${euroAnzeige(-p.saldoCent!)}'),
    ];
  }

  List<Widget> _solar(ZaehlerReihe r, Zeitraum z, DateTime heute) {
    final bisHeute = r.inhalt.monatlich ? heute.add(const Duration(days: 1)) : heute; // Monatswerte reichen bis einschließlich heute
    final bis = bisHeute.isBefore(z.ende) ? (bisHeute.isBefore(z.start) ? z.start : bisHeute) : z.ende;
    final s = solarVorteil(r.inhalt, r.kurve, Zeitraum(z.start, bis), r.inhalt.preise);
    final a = solarAuswertung(r, heute).amortisation;
    return [
      _Zeile('Eigenverbrauch', verbrauchAnzeige(s.eigenMilli, r.inhalt.einheit)),
      _Zeile('Eingespeist', verbrauchAnzeige(s.einspeiseMilli, r.inhalt.einheit)),
      _Zeile('Ersparnis', '${euroAnzeige(s.ersparnisCent)}${s.preisLuecke ? ' (Strompreis fehlt für einen Teil)' : ''}'),
      if (s.verguetungCent > 0) _Zeile('Einspeisevergütung', euroAnzeige(s.verguetungCent)),
      if (a != null) _Zeile('Anschaffung', a.amortisiert ? 'bezahlt gemacht' : '${a.prozent.round()} % drin${a.restJahre == null ? '' : ', noch ca. ${a.restJahre!.toStringAsFixed(1).replaceAll('.', ',')} Jahre'}'),
    ];
  }
}

class _Veraenderung extends StatelessWidget {
  final DiagrammBalken balken;
  final String einheit;
  final bool erzeugung;
  const _Veraenderung({required this.balken, required this.einheit, required this.erzeugung});

  @override
  Widget build(BuildContext context) {
    final v = balken.vorjahrMilli;
    if (v == null) return const Text('Kein Vorjahreswert', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: kTextMuted));
    final p = balken.milli == null || v <= 0 ? null : (balken.milli! - v) * 100 / v;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('Vorjahr ${verbrauchAnzeige(v, einheit)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: kTextMuted)),
        if (p != null) Text(prozentAnzeige(p), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: prozentFarbe(p, erzeugung: erzeugung))),
      ],
    );
  }
}

class _Zeile extends StatelessWidget {
  final String label;
  final String wert;
  const _Zeile(this.label, this.wert);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 2, child: Text(label, style: const TextStyle(color: kTextMuted))),
        const SizedBox(width: 12),
        Expanded(flex: 3, child: Text(wert, textAlign: TextAlign.right, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 13, fontWeight: FontWeight.w600))),
      ],
    ),
  );
}

/// Die letzten Stände eines Zählers (samt Vorgängern der Kette) mit Ändern und Löschen.
class _StaendeAbschnitt extends ConsumerWidget {
  final ZaehlerReihe reihe;
  final ZaehlerDaten daten;
  final bool mitTitel;
  final bool alle;
  const _StaendeAbschnitt({required this.reihe, required this.daten, required this.mitTitel, required this.alle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (reihe.monatlich) return _MonatswerteAbschnitt(reihe: reihe, mitTitel: mitTitel, alle: alle);
    // alle lesbaren Stände der Kette, neueste zuerst; der Unterschied zum vorigen Stand desselben Zählers steht daneben
    final zeilen = <({StandAnsicht a, StandInhalt s, int? delta})>[];
    for (final id in reihe.ids) {
      final e = daten.eintrag(id);
      if (e == null) continue;
      final lesbar = [for (final s in e.staende) if (s.inhalt?.tag != null) s];
      lesbar.sort((a, b) {
        final c = a.inhalt!.datum.compareTo(b.inhalt!.datum);
        return c != 0 ? c : a.erstelltAt.compareTo(b.erstelltAt);
      });
      for (var i = 0; i < lesbar.length; i++) {
        final d = i == 0 ? null : lesbar[i].inhalt!.milli - lesbar[i - 1].inhalt!.milli;
        zeilen.add((a: lesbar[i], s: lesbar[i].inhalt!, delta: d));
      }
    }
    zeilen.sort((x, y) {
      final c = y.s.datum.compareTo(x.s.datum);
      return c != 0 ? c : y.a.erstelltAt.compareTo(x.a.erstelltAt);
    });
    final sichtbar = alle ? zeilen : zeilen.take(6).toList();
    final einheit = reihe.inhalt.einheit;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: MonoLabel(mitTitel ? 'Letzte Stände · ${reihe.name}' : 'Letzte Stände', color: kTextMuted)),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => zaehlerEditorOeffnen(context, id: reihe.id),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Zähler bearbeiten'),
                ),
              ],
            ),
            if (zeilen.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Noch kein Stand eingetragen.', style: TextStyle(color: kTextMuted))),
            for (final z in sichtbar)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(datumTextDeutsch(z.s.datum)),
                          if (z.s.marke != null || z.s.notiz.isNotEmpty || z.s.automatisch)
                            Text(
                              [if (z.s.automatisch) 'aus Home Assistant', if (z.s.marke == StandMarke.ende) 'Endstand beim Zählerwechsel', if (z.s.marke == StandMarke.start) 'Startstand nach Zählerwechsel', if (z.s.notiz.isNotEmpty) z.s.notiz].join(' · '),
                              style: const TextStyle(fontSize: 12, color: kTextMuted),
                            ),
                        ],
                      ),
                    ),
                    Semantics(
                      label: '${standAnzeige(z.s.milli)} $einheit${z.delta == null ? '' : ', ${z.delta! >= 0 ? 'plus' : 'minus'} ${verbrauchAnzeige(z.delta!.abs(), einheit)}'}',
                      excludeSemantics: true,
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: standAnzeige(z.s.milli), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontWeight: FontWeight.w600)),
                          if (z.delta != null) TextSpan(text: ' (${z.delta! >= 0 ? '+' : '-'}${verbrauchAnzeige(z.delta!.abs(), einheit, mitEinheit: false)})', style: const TextStyle(fontSize: 12, color: kTextMuted)),
                        ]),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Stand vom ${datumTextDeutsch(z.s.datum)}: Aktionen',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onSelected: (v) async {
                        if (v == 'aendern') {
                          await standBearbeitenOeffnen(context, ref, reihe, z.a);
                        } else if (v == 'loeschen') {
                          final ok = await bestaetigen(context, titel: 'Stand löschen?', text: 'Der Stand vom ${datumTextDeutsch(z.s.datum)} (${standAnzeige(z.s.milli)} $einheit) wird gelöscht.', knopf: 'Löschen');
                          if (!ok || !context.mounted) return;
                          try {
                            await ref.read(zaehlerRepositoryProvider).standLoeschen(z.a.id);
                          } on Object catch (e) {
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(zaehlerFehlerText(e))));
                          }
                        }
                      },
                      itemBuilder: (_) => const [PopupMenuItem(value: 'aendern', child: Text('Bearbeiten')), PopupMenuItem(value: 'loeschen', child: Text('Löschen'))],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Die letzten Monatswerte eines Zählers (Eingabeart Monatswerte), nach Monat, neueste zuerst, mit Bearbeiten und Löschen (mit Bestätigung).
class _MonatswerteAbschnitt extends ConsumerWidget {
  final ZaehlerReihe reihe;
  final bool mitTitel;
  final bool alle;
  const _MonatswerteAbschnitt({required this.reihe, required this.mitTitel, required this.alle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heute = zaehlerHeute(ref.watch(minutenTaktProvider).value ?? DateTime.now());
    final werte = reihe.monatswerte.reversed.toList();
    final sichtbar = alle ? werte : werte.take(6).toList();
    final einheit = reihe.inhalt.einheit;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: MonoLabel(mitTitel ? 'Letzte Werte · ${reihe.name}' : 'Letzte Werte', color: kTextMuted)),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => zaehlerEditorOeffnen(context, id: reihe.id),
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Zähler bearbeiten'),
                ),
              ],
            ),
            if (werte.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Noch kein Monatswert eingetragen.', style: TextStyle(color: kTextMuted))),
            for (final w in sichtbar)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(monatTitel(w.jahr, w.monat)),
                          if (w.jahr == heute.year && w.monat == heute.month || w.notiz.isNotEmpty)
                            Text([if (w.jahr == heute.year && w.monat == heute.month) 'Zwischenstand', if (w.notiz.isNotEmpty) w.notiz].join(' · '), style: const TextStyle(fontSize: 12, color: kTextMuted)),
                        ],
                      ),
                    ),
                    Semantics(
                      label: 'Monatswert ${monatTitel(w.jahr, w.monat)}: ${verbrauchAnzeige(w.milli, einheit)}',
                      excludeSemantics: true,
                      child: Text(verbrauchAnzeige(w.milli, einheit), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontWeight: FontWeight.w600)),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Monatswert ${monatTitel(w.jahr, w.monat)}: Aktionen',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onSelected: (v) async {
                        if (v == 'aendern') {
                          await monatswertEintragenOeffnen(context, reiheId: reihe.id, monat: (jahr: w.jahr, monat: w.monat), bearbeiten: true);
                        } else if (v == 'loeschen') {
                          final ok = await bestaetigen(context, titel: 'Monatswert löschen?', text: 'Der Wert für ${monatTitel(w.jahr, w.monat)} (${verbrauchAnzeige(w.milli, einheit)}) wird gelöscht.', knopf: 'Löschen');
                          if (!ok || !context.mounted) return;
                          try {
                            await ref.read(zaehlerRepositoryProvider).monatswertLoeschen(reihe.id, jahr: w.jahr, monat: w.monat);
                          } on Object catch (e) {
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(zaehlerFehlerText(e))));
                          }
                        }
                      },
                      itemBuilder: (_) => const [PopupMenuItem(value: 'aendern', child: Text('Bearbeiten')), PopupMenuItem(value: 'loeschen', child: Text('Löschen'))],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
