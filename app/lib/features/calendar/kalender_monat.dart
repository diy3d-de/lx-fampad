// Monatsraster des Kalenders: füllt den verfügbaren Platz (kein Scrollen der Seite), links die Kalenderwochen, je Wochenzeile Tageszahlen und
// darunter Balken: mehrtägige Termine und Ferien laufen durchgehend über die Tage (an den Wochenrändern abgeschnitten), eintägige sind kurze
// Balken. Wie viele Balken je Zeile passen, ergibt sich aus der Höhe (und der Textgröße); der Rest steht als "+n" am Tag. Ein Tipp auf einen Tag
// öffnet das Tagesblatt (mobil) bzw. wählt den Tag für das Tagespanel (Desktop). Die Belegung der Spuren steht in data/calendar/monat_layout.dart.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/monat_layout.dart';
import '../../data/muell/muell_modelle.dart';
import 'muell_kalender.dart';

/// Mindesthöhe einer Wochenzeile (darunter scrollt das Raster): Tageszeile plus zwei Spuren.
double _tageszeileHoehe(BuildContext context, bool breit) {
  final s = MediaQuery.textScalerOf(context);
  final min = breit ? 28.0 : 22.0;
  final h = s.scale(breit ? 13 : 12) * 1.35 + 6;
  return h > min ? h : min;
}

double _spurHoehe(BuildContext context, bool breit) {
  final s = MediaQuery.textScalerOf(context);
  final min = breit ? 21.0 : 16.0;
  final h = s.scale(breit ? 12 : 10) * 1.4 + 3;
  return h > min ? h : min;
}

class MonatsRaster extends StatelessWidget {
  /// Erster Tag des angezeigten Monats (UTC-Markierung).
  final DateTime monat;
  final DateTime heute;
  final DateTime gewaehlt;

  /// Der gewählte Tag wird markiert (Desktop mit Tagespanel); mobil gibt es nur "heute".
  final bool gewaehltMarkieren;

  /// Desktop-Maße (größere Schrift, Zeit im Balken).
  final bool breit;
  final List<BalkenQuelle> quellen;
  final void Function(DateTime tag) onTag;

  /// Abfuhrtermine (nur Anzeige, nur mit eingeschaltetem Schalter): je Tag die Arten; als schmaler Streifen am unteren Rand der Zelle.
  final Map<DateTime, List<MuellArt>> muell;
  const MonatsRaster({super.key, required this.monat, required this.heute, required this.gewaehlt, this.gewaehltMarkieren = false, this.breit = false, required this.quellen, required this.onTag, this.muell = const {}});

  @override
  Widget build(BuildContext context) {
    final wochen = wochenDesMonats(monat);
    final kwBreite = breit ? 36.0 : 24.0;
    final mindest = _tageszeileHoehe(context, breit) + 2 * _spurHoehe(context, breit) + 2;
    // Einträge je Tag einmal vorab (Beschriftung für Screenreader, Ferien/Feiertage als Zellenfarbe), nicht je Zelle und Aufbau
    final proTag = <DateTime, List<BalkenQuelle>>{};
    for (final q in quellen) {
      for (var t = q.von.isBefore(wochen.first) ? wochen.first : q.von; !t.isAfter(q.bis) && t.isBefore(DateTime.utc(wochen.last.year, wochen.last.month, wochen.last.day + 7)); t = DateTime.utc(t.year, t.month, t.day + 1)) {
        proTag.putIfAbsent(t, () => []).add(q);
      }
    }
    for (final l in proTag.values) {
      l.sort((a, b) => a.art.index != b.art.index ? b.art.index.compareTo(a.art.index) : a.sortierung.compareTo(b.sortierung));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.fromLTRB(0, breit ? 8 : 4, 0, breit ? 6 : 2),
            child: Row(
              children: [
                SizedBox(width: kwBreite),
                for (final t in breit ? const ['MO', 'DI', 'MI', 'DO', 'FR', 'SA', 'SO'] : const ['M', 'D', 'M', 'D', 'F', 'S', 'S'])
                  Expanded(
                    child: Center(
                      child: Text(t, style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 12 : 11, color: kTextMuted)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final hoehe = c.maxHeight.isFinite ? c.maxHeight : mindest * wochen.length;
              final zeile = (hoehe / wochen.length) < mindest ? mindest : hoehe / wochen.length;
              // immer scrollbar (auch ohne Überlänge): so greift das Herunterziehen zum Abgleichen und zum Einblenden der Kopfzeile
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Column(
                  children: [
                    for (final montag in wochen)
                      SizedBox(
                        height: zeile,
                        child: _WochenZeile(
                          montag: montag,
                          monat: monat,
                          heute: heute,
                          gewaehlt: gewaehlt,
                          gewaehltMarkieren: gewaehltMarkieren,
                          breit: breit,
                          kwBreite: kwBreite,
                          quellen: quellen,
                          proTag: proTag,
                          muell: muell,
                          onTag: onTag,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WochenZeile extends StatelessWidget {
  final DateTime montag;
  final DateTime monat;
  final DateTime heute;
  final DateTime gewaehlt;
  final bool gewaehltMarkieren;
  final bool breit;
  final double kwBreite;
  final List<BalkenQuelle> quellen;
  final Map<DateTime, List<BalkenQuelle>> proTag;
  final Map<DateTime, List<MuellArt>> muell;
  final void Function(DateTime tag) onTag;
  const _WochenZeile({
    required this.montag,
    required this.monat,
    required this.heute,
    required this.gewaehlt,
    required this.gewaehltMarkieren,
    required this.breit,
    required this.kwBreite,
    required this.quellen,
    required this.proTag,
    required this.muell,
    required this.onTag,
  });

  static final _tagFormat = DateFormat('EEEE, d. MMMM', 'de_DE');

  @override
  Widget build(BuildContext context) {
    final tageszeile = _tageszeileHoehe(context, breit);
    final spur = _spurHoehe(context, breit);
    return LayoutBuilder(
      builder: (context, c) {
        final maxSpuren = spurenFuerHoehe(c.maxHeight, tageszeile, spur);
        // Ferien und Feiertage nehmen auf kleinen Bildschirmen den Terminen den Platz: unter drei Spuren nur als Zellenfarbe (Streifen oben, Tönung), der Name steht im Tagesblatt
        final kompakt = !hinweiseAlsBalken(maxSpuren);
        final layout = wochenLayout(montag: montag, quellen: kompakt ? [for (final q in quellen) if (q.art == BalkenArt.termin) q] : quellen, maxSpuren: maxSpuren);
        final spaltenBreite = (c.maxWidth - kwBreite) / 7;
        final tage = [for (var i = 0; i < 7; i++) DateTime.utc(montag.year, montag.month, montag.day + i)];
        final schriftBalken = TextStyle(fontSize: breit ? 12 : 10, fontWeight: FontWeight.w600, color: kOnAccent, height: 1.0);
        return Stack(
          children: [
            // Tageszellen: antippbar, mit Beschreibung für Screenreader (die Balken darüber sind nur Anzeige)
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: kBorderSoft))),
                child: Row(
                  children: [
                    SizedBox(
                      width: kwBreite,
                      child: Padding(
                        padding: EdgeInsets.only(top: breit ? 6 : 4, left: breit ? 8 : 0),
                        child: ExcludeSemantics(
                          child: Text('${kalenderwoche(montag)}', maxLines: 1, style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 11 : 10, color: kTextFaint)),
                        ),
                      ),
                    ),
                    for (var i = 0; i < 7; i++) Expanded(child: _tagZelle(tage[i], i, kompakt)),
                  ],
                ),
              ),
            ),
            for (final b in layout.balken)
              Positioned(
                left: kwBreite + b.start * spaltenBreite,
                width: b.spanne * spaltenBreite,
                top: tageszeile + b.spur * spur,
                height: spur,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(b.vorneOffen ? 0 : 1, 0.5, b.hintenOffen ? 0 : 1, 0.5),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: b.quelle.farbe,
                          borderRadius: BorderRadius.horizontal(
                            left: b.vorneOffen ? Radius.zero : Radius.circular(breit ? 5 : 4),
                            right: b.hintenOffen ? Radius.zero : Radius.circular(breit ? 5 : 4),
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: breit ? 7 : 3),
                            child: Text(b.quelle.text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: schriftBalken),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (layout.hatMehr && layout.spuren < maxSpuren)
              for (var i = 0; i < 7; i++)
                if (layout.mehr[i] > 0)
                  Positioned(
                    left: kwBreite + i * spaltenBreite,
                    width: spaltenBreite,
                    top: tageszeile + layout.spuren * spur,
                    height: spur,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: Center(child: Text('+${layout.mehr[i]}', maxLines: 1, style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 12 : 10, fontWeight: FontWeight.w600, color: kTextMuted))),
                      ),
                    ),
                  ),
          ],
        );
      },
    );
  }

  static Color? _grundfarbe({required bool markiert, required bool hatFerien, required bool wochenende}) {
    final ferien = hatFerien ? kFerien.withValues(alpha: 0.14) : null;
    if (markiert) return ferien == null ? kAccentSoft : Color.alphaBlend(kAccentSoft, ferien);
    return ferien ?? (wochenende ? kTextStrong.withValues(alpha: 0.025) : null);
  }

  Widget _tagZelle(DateTime tag, int spalte, bool kompakt) {
    final istHeute = tag == heute;
    final imMonat = tag.month == monat.month && tag.year == monat.year;
    final markiert = gewaehltMarkieren && tag == gewaehlt;
    final eintraege = proTag[tag] ?? const <BalkenQuelle>[];
    final hatFerien = kompakt && eintraege.any((q) => q.art == BalkenArt.ferien);
    final hatFeiertag = kompakt && eintraege.any((q) => q.art == BalkenArt.feiertag);
    final termine = eintraege.where((q) => q.art == BalkenArt.termin).toList();
    final hinweise = eintraege.where((q) => q.art != BalkenArt.termin).map((q) => q.art == BalkenArt.feiertag ? 'Feiertag ${q.text}' : 'Schulferien ${q.text}');
    final abfuhr = muell[tag] ?? const <MuellArt>[];
    final label = [
      _tagFormat.format(tag),
      if (istHeute) 'heute',
      ...hinweise,
      if (abfuhr.isNotEmpty) muellKalenderText(abfuhr),
      if (termine.isEmpty) 'keine Termine' else '${termine.length == 1 ? '1 Termin' : '${termine.length} Termine'}: ${termine.take(3).map((q) => q.text).join(', ')}${termine.length > 3 ? ' und weitere' : ''}',
    ].join(', ');
    final zahlStil = TextStyle(
      fontSize: breit ? 13 : 12,
      fontWeight: FontWeight.w600,
      height: 1.1,
      color: istHeute ? kOnAccent : (imMonat ? kText : kTextFaint),
    );
    return Semantics(
      button: true,
      selected: markiert,
      label: label,
      excludeSemantics: true,
      onTap: () => onTag(tag),
      child: InkWell(
        key: ValueKey('kalender-tag-${tag.toIso8601String().substring(0, 10)}'),
        onTap: () => onTag(tag),
        child: Container(
          // Ferien-Tönung bleibt unter der Markierung von heute und dem gewählten Tag sichtbar (nur überlagert, nie ersetzt)
          decoration: BoxDecoration(
            color: _grundfarbe(markiert: markiert, hatFerien: hatFerien, wochenende: spalte >= 5),
            border: const Border(left: BorderSide(color: kBorderSoft)),
          ),
          foregroundDecoration: istHeute ? BoxDecoration(color: kAccent.withValues(alpha: 0.07), border: Border.all(color: kAccent)) : null,
          child: Stack(
            children: [
              // Feiertag (bei wenig Platz): Streifen oben, ohne den Inhalt der Zelle zu verschieben
              if (hatFeiertag) const Positioned(left: 0, right: 0, top: 0, height: 3, child: ColoredBox(color: kFeiertag)),
              // Abfuhr (nur Anzeige): schmaler Streifen unten in der Zelle, auf dem Desktop dazu kleine Symbole oben rechts; verdrängt keine Termine
              if (abfuhr.isNotEmpty) Positioned(left: 0, right: 0, bottom: 0, child: MuellStreifen(key: ValueKey('muell-streifen-${tag.toIso8601String().substring(0, 10)}'), arten: abfuhr)),
              if (abfuhr.isNotEmpty && breit) Positioned(right: 4, top: 6, child: MuellMiniSymbole(arten: abfuhr)),
              Positioned.fill(
                child: Align(
                  alignment: breit ? Alignment.topLeft : Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: breit ? 5 : 2, left: breit ? 8 : 0),
                    child: Container(
                      constraints: BoxConstraints(minWidth: breit ? 24 : 20),
                      padding: EdgeInsets.symmetric(horizontal: breit ? 5 : 3, vertical: 2),
                      decoration: BoxDecoration(color: istHeute ? kAccent : null, borderRadius: BorderRadius.circular(11)),
                      child: Text('${tag.day}', textAlign: TextAlign.center, style: zahlStil),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
