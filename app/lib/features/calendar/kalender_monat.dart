// Monatsraster des Kalenders: füllt den verfügbaren Platz (kein Scrollen der Seite), links die Kalenderwochen, je Wochenzeile Tageszahlen und
// darunter Balken: mehrtägige Termine und Ferien laufen durchgehend über die Tage (an den Wochenrändern abgeschnitten), eintägige sind kurze
// Balken. Wie viele Balken je Zeile passen, ergibt sich aus der Höhe (und der Textgröße); der Rest steht als "+n" am Tag. Ein Tipp auf einen Tag
// öffnet das Tagesblatt (mobil) bzw. wählt den Tag für das Tagespanel (Desktop). Die Belegung der Spuren steht in data/calendar/monat_layout.dart.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/monat_layout.dart';

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
  const MonatsRaster({super.key, required this.monat, required this.heute, required this.gewaehlt, this.gewaehltMarkieren = false, this.breit = false, required this.quellen, required this.onTag});

  @override
  Widget build(BuildContext context) {
    final wochen = wochenDesMonats(monat);
    final kwBreite = breit ? 36.0 : 24.0;
    final mindest = _tageszeileHoehe(context, breit) + 2 * _spurHoehe(context, breit) + 2;
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
    required this.onTag,
  });

  static final _tagFormat = DateFormat('EEEE, d. MMMM', 'de_DE');

  @override
  Widget build(BuildContext context) {
    final tageszeile = _tageszeileHoehe(context, breit);
    final spur = _spurHoehe(context, breit);
    return LayoutBuilder(
      builder: (context, c) {
        final maxSpuren = ((c.maxHeight - tageszeile - 2) / spur).floor();
        final layout = wochenLayout(montag: montag, quellen: quellen, maxSpuren: maxSpuren);
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
                    for (var i = 0; i < 7; i++) Expanded(child: _tagZelle(tage[i], i, layout)),
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

  Widget _tagZelle(DateTime tag, int spalte, WochenLayout layout) {
    final istHeute = tag == heute;
    final imMonat = tag.month == monat.month && tag.year == monat.year;
    final markiert = gewaehltMarkieren && tag == gewaehlt;
    final eintraege = [
      for (final q in quellen)
        if (q.faelltAuf(tag)) q,
    ]..sort((a, b) => a.art.index != b.art.index ? b.art.index.compareTo(a.art.index) : a.sortierung.compareTo(b.sortierung));
    final termine = eintraege.where((q) => q.art == BalkenArt.termin).toList();
    final hinweise = eintraege.where((q) => q.art != BalkenArt.termin).map((q) => q.art == BalkenArt.feiertag ? 'Feiertag ${q.text}' : 'Schulferien ${q.text}');
    final label = [
      _tagFormat.format(tag),
      if (istHeute) 'heute',
      ...hinweise,
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
          decoration: BoxDecoration(
            color: markiert ? kAccentSoft : (istHeute ? kAccent.withValues(alpha: 0.07) : (spalte >= 5 ? kTextStrong.withValues(alpha: 0.025) : null)),
            border: Border(left: const BorderSide(color: kBorderSoft)),
          ),
          foregroundDecoration: istHeute ? BoxDecoration(border: Border.all(color: kAccent)) : null,
          alignment: breit ? Alignment.topLeft : Alignment.topCenter,
          padding: EdgeInsets.only(top: breit ? 5 : 2, left: breit ? 8 : 0),
          child: Container(
            constraints: BoxConstraints(minWidth: breit ? 24 : 20),
            padding: EdgeInsets.symmetric(horizontal: breit ? 5 : 3, vertical: 2),
            decoration: BoxDecoration(color: istHeute ? kAccent : null, borderRadius: BorderRadius.circular(11)),
            child: Text('${tag.day}', textAlign: TextAlign.center, style: zahlStil),
          ),
        ),
      ),
    );
  }
}
