// Wochenraster des Kalenders: oben Mo bis So mit Tageszahl (heute hervorgehoben), darunter ein Band für Ganztägiges und Mehrtägiges (Balken über die
// Spalten, Überlauf als "+n"), darunter das Zeitraster mit Stundenlinien und den Terminblöcken in Personenfarbe (Höhe nach Dauer, überlappende
// Termine nebeneinander), einer Linie für die aktuelle Uhrzeit und dem Scrollen über 24 Stunden. Tipp auf einen Block öffnet den Termin, Tipp auf
// einen Tageskopf den Tag (Tagesblatt bzw. Tagespanel), Tipp auf eine leere Stelle legt einen Termin an; Wischen wechselt die Woche.
// Die Belegung (Aufteilung über Mitternacht, Spuren, Spuren des Bands) steht in data/calendar/woche_layout.dart und monat_layout.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/geburtstag.dart' show vorkommenTitel;
import '../../data/calendar/monat_layout.dart';
import '../../data/calendar/woche_layout.dart';
import 'calendar_state.dart';

/// Stundenhöhe: Mindestmaß aus der Textgröße (Stundenbeschriftung), mobil 38, Desktop 60.
double _stundenHoehe(BuildContext context, bool breit) {
  final s = MediaQuery.textScalerOf(context);
  final min = s.scale(breit ? 11 : 10) * 1.4 + 16;
  final soll = breit ? 60.0 : 38.0;
  return soll > min ? soll : min;
}

double _bandSpur(BuildContext context, bool breit) {
  final s = MediaQuery.textScalerOf(context);
  final min = s.scale(breit ? 12 : 10) * 1.4 + 3;
  final soll = breit ? 24.0 : 18.0;
  return soll > min ? soll : min;
}

double _blockSchrift(bool breit) => breit ? 12.0 : 9.0;

/// Abstand oben und unten im Block (Polster, Rand), von der Zeilenzahl abgezogen.
double _blockRand(bool breit) => breit ? 10.0 : 6.0;

/// Mindesthöhe eines Blocks im Zeitraster: mindestens eine Textzeile (mit der Textskala wächst sie mit), sonst 18 bzw. 24 px.
double _blockMin(BuildContext context, bool breit) {
  final mind = breit ? 24.0 : 18.0;
  final text = MediaQuery.textScalerOf(context).scale(_blockSchrift(breit)) * 1.25 + _blockRand(breit);
  return text > mind ? text : mind;
}

class WochenRaster extends StatefulWidget {
  /// Montag der angezeigten Woche (UTC-Markierung).
  final DateTime montag;
  final DateTime gewaehlt;

  /// Der gewählte Tag wird markiert (Desktop mit Tagespanel).
  final bool gewaehltMarkieren;
  final bool breit;
  final List<WochenBlock> bloecke;

  /// Einträge des Bands (Ganztägiges, Mehrtägiges, Feiertage, Ferien).
  final List<BalkenQuelle> band;
  final Color Function(WochenBlock) farbe;

  /// Name der Person hinter dem Block (Ersteller; für die Beschreibung der Screenreader), `null` = unbekannt.
  final String? Function(WochenBlock)? person;

  /// Aktuelle Uhrzeit der Familienzone (Wanduhr als UTC); daraus ergeben sich heute (Hervorhebung, Linie) und der Wechsel um Mitternacht.
  final DateTime Function() jetzt;
  final void Function(DateTime tag) onTag;
  final void Function(WochenBlock b) onBlock;

  /// Tipp auf eine leere Stelle (Tag, Minute seit 0:00); `null` = darf nicht anlegen.
  final void Function(DateTime tag, int minute)? onLeer;

  /// Wischen: -1 = vorherige, 1 = nächste Woche.
  final void Function(int richtung) onWoche;

  /// Platz unter dem Raster (mobil für den runden Knopf).
  final double unten;
  const WochenRaster({
    super.key,
    required this.montag,
    required this.gewaehlt,
    this.gewaehltMarkieren = false,
    this.breit = false,
    required this.bloecke,
    required this.band,
    required this.farbe,
    this.person,
    required this.jetzt,
    required this.onTag,
    required this.onBlock,
    required this.onLeer,
    required this.onWoche,
    this.unten = 0,
  });

  @override
  State<WochenRaster> createState() => _WochenRasterState();
}

class _WochenRasterState extends State<WochenRaster> {
  ScrollController? _scroll;
  late DateTime _jetzt;
  Timer? _takt;

  /// Beim nächsten Aufbau prüfen, ob der erste Termin sichtbar ist (neue Woche, erste Termine eingetroffen).
  var _scrollPruefen = false;

  /// Während eines Sprungs gehen keine Scroll-Meldungen nach oben (sie würden die Kopfzeile einklappen).
  var _springt = false;

  /// Maße des letzten Aufbaus für den Sprung.
  double _sichtHoehe = 0;
  double _stunde = 0;
  double _maxOffset = 0;
  int _ziel = 0;
  int? _fruehesteMinute;

  /// Heute in der Familienzone, aus der Uhr des Rasters (wechselt um Mitternacht mit).
  DateTime get _heute => DateTime.utc(_jetzt.year, _jetzt.month, _jetzt.day);

  /// Wischen: Start (Randgeste?) und Weg.
  var _wischRand = false;
  var _wischWeg = 0.0;
  var _breite = 0.0;

  @override
  void initState() {
    super.initState();
    _jetzt = widget.jetzt();
    // die Linie der aktuellen Uhrzeit wandert im Minutentakt
    _takt = Timer.periodic(const Duration(seconds: 30), (_) {
      final j = widget.jetzt();
      if (mounted && (j.minute != _jetzt.minute || j.hour != _jetzt.hour || j.day != _jetzt.day)) setState(() => _jetzt = j);
    });
  }

  @override
  void didUpdateWidget(WochenRaster alt) {
    super.didUpdateWidget(alt);
    if (alt.montag != widget.montag || (alt.bloecke.isEmpty && widget.bloecke.isNotEmpty)) _scrollPruefen = true;
  }

  /// Springt auf den Zielwert, wenn der früheste Termin der Woche außerhalb des sichtbaren Bereichs liegt.
  void _scrollAnpassen() {
    final c = _scroll;
    final frueh = _fruehesteMinute;
    if (c == null || !c.hasClients || frueh == null) return;
    final oben = frueh / 60 * _stunde;
    final aktuell = c.offset;
    if (oben >= aktuell && oben + _stunde <= aktuell + _sichtHoehe) return;
    final ziel = (_ziel / 60 * _stunde).clamp(0.0, _maxOffset < 0 ? 0.0 : _maxOffset);
    if ((ziel - aktuell).abs() < 0.5) return;
    _springt = true;
    try {
      c.jumpTo(ziel);
    } finally {
      _springt = false;
    }
  }

  @override
  void dispose() {
    _takt?.cancel();
    _scroll?.dispose();
    super.dispose();
  }

  static final _tagFormat = DateFormat('EEEE, d. MMMM', 'de_DE');
  static const _kurz = ['MO', 'DI', 'MI', 'DO', 'FR', 'SA', 'SO'];

  @override
  Widget build(BuildContext context) {
    final breit = widget.breit;
    final montag = widget.montag;
    final tage = [for (var i = 0; i < 7; i++) DateTime.utc(montag.year, montag.month, montag.day + i)];
    final heute = _heute;
    final heuteIndex = tage.indexOf(heute);
    final randLinks = breit ? 52.0 : 30.0;
    final spur = _bandSpur(context, breit);
    final maxSpuren = breit ? 4 : 3;
    final layout = wochenLayout(montag: montag, quellen: widget.band, maxSpuren: maxSpuren);
    final bandZeilen = layout.spuren + (layout.hatMehr ? 1 : 0);
    final stunde = _stundenHoehe(context, breit);

    // Einträge je Tag für die Beschriftung der Tageskoepfe (Screenreader)
    String beschriftung(int i) {
      final tag = tage[i];
      final termine = widget.bloecke.where((b) => b.tag == i).length + widget.band.where((q) => q.art == BalkenArt.termin && q.faelltAuf(tag)).length;
      final hinweise = widget.band
          .where((q) => q.art != BalkenArt.termin && q.faelltAuf(tag))
          .map((q) => q.art == BalkenArt.feiertag ? 'Feiertag ${q.text}' : 'Schulferien ${q.text}');
      return [
        _tagFormat.format(tag),
        if (tag == heute) 'heute',
        ...hinweise,
        if (termine == 0) 'keine Termine' else termine == 1 ? '1 Termin' : '$termine Termine',
      ].join(', ');
    }

    final kopf = Padding(
      padding: EdgeInsets.fromLTRB(0, breit ? 8 : 4, 0, 0),
      child: Row(
        children: [
          SizedBox(
            width: randLinks,
            child: ExcludeSemantics(
              child: Padding(
                padding: EdgeInsets.only(left: breit ? 10 : 0),
                child: Text(
                  'KW ${kalenderwoche(montag)}',
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 10 : 8, color: kTextFaint),
                ),
              ),
            ),
          ),
          for (var i = 0; i < 7; i++)
            Expanded(
              child: _Tageskopf(
                tag: tage[i],
                spalte: i,
                heute: heute,
                markiert: widget.gewaehltMarkieren && tage[i] == widget.gewaehlt,
                breit: breit,
                label: beschriftung(i),
                onTag: widget.onTag,
              ),
            ),
        ],
      ),
    );

    final bandWidget = bandZeilen == 0
        ? const SizedBox.shrink()
        : Container(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: kBorderSoft),
                bottom: BorderSide(color: kBorder),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: randLinks,
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: EdgeInsets.only(left: breit ? 10 : 0, top: 4),
                      child: Text(
                        'GANZ',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 10 : 8, color: kTextFaint),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final w = c.maxWidth / 7;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => widget.onTag(tage[(d.localPosition.dx ~/ w).clamp(0, 6)]),
                        child: ExcludeSemantics(
                          child: SizedBox(
                            height: bandZeilen * spur + 6,
                            child: Stack(
                              children: [
                                for (final b in layout.balken)
                                  Positioned(
                                    left: b.start * w,
                                    width: b.spanne * w,
                                    top: 3 + b.spur * spur,
                                    height: spur,
                                    child: _BandBalken(b: b, breit: breit),
                                  ),
                                if (layout.hatMehr)
                                  for (var i = 0; i < 7; i++)
                                    if (layout.mehr[i] > 0)
                                      Positioned(
                                        left: i * w,
                                        width: w,
                                        top: 3 + layout.spuren * spur,
                                        height: spur,
                                        child: Center(
                                          child: Text(
                                            '+${layout.mehr[i]}',
                                            maxLines: 1,
                                            style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 12 : 10, fontWeight: FontWeight.w600, color: kTextMuted),
                                          ),
                                        ),
                                      ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );

    final raster = Expanded(
      child: LayoutBuilder(
        builder: (context, c) {
          final gesamt = 24 * stunde;
          // beim ersten Aufbau auf die aktuelle Uhrzeit bzw. den ersten Termin der Woche scrollen (ohne Scroll-Meldung, die die Kopfzeile einklappen würde)
          final ziel = scrollZielMinute(bloecke: widget.bloecke, jetztMinute: heuteIndex >= 0 ? _jetzt.hour * 60 + _jetzt.minute : null);
          final maxOffset = gesamt + widget.unten - c.maxHeight;
          _ziel = ziel;
          _stunde = stunde;
          _sichtHoehe = c.maxHeight;
          _maxOffset = maxOffset;
          _fruehesteMinute = widget.bloecke.isEmpty ? null : widget.bloecke.map((b) => b.start).reduce((a, b) => a < b ? a : b);
          _scroll ??= ScrollController(initialScrollOffset: (ziel / 60 * stunde).clamp(0.0, maxOffset < 0 ? 0.0 : maxOffset));
          if (_scrollPruefen) {
            _scrollPruefen = false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _scrollAnpassen();
            });
          }
          return NotificationListener<ScrollNotification>(
            onNotification: (_) => _springt,
            child: SingleChildScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              child: Padding(
                padding: EdgeInsets.only(bottom: widget.unten),
                child: _Zeitraster(
                  tage: tage,
                  heuteIndex: heuteIndex,
                  jetzt: _jetzt,
                  bloecke: widget.bloecke,
                  farbe: widget.farbe,
                  person: widget.person,
                  stunde: stunde,
                  randLinks: randLinks,
                  breit: breit,
                  onBlock: widget.onBlock,
                  onLeer: widget.onLeer,
                ),
              ),
            ),
          );
        },
      ),
    );

    return LayoutBuilder(
      builder: (context, c) {
        _breite = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Wischen wechselt die Woche: erst ab 40 px Weg und 300 px/s, nicht bei einer Randgeste (die ersten und letzten 8 px gehören dem System)
          onHorizontalDragStart: (d) {
            _wischWeg = 0;
            _wischRand = d.localPosition.dx < 8 || d.localPosition.dx > _breite - 8;
          },
          onHorizontalDragUpdate: (d) => _wischWeg += d.primaryDelta ?? 0,
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (!_wischRand && v.abs() > 300 && _wischWeg.abs() >= 40 && (v < 0) == (_wischWeg < 0)) widget.onWoche(v < 0 ? 1 : -1);
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [kopf, bandWidget, raster]),
        );
      },
    );
  }
}

class _Tageskopf extends StatelessWidget {
  final DateTime tag;
  final int spalte;
  final DateTime heute;
  final bool markiert;
  final bool breit;
  final String label;
  final void Function(DateTime tag) onTag;
  const _Tageskopf({
    required this.tag,
    required this.spalte,
    required this.heute,
    required this.markiert,
    required this.breit,
    required this.label,
    required this.onTag,
  });

  @override
  Widget build(BuildContext context) {
    final istHeute = tag == heute;
    final wochenende = spalte >= 5;
    final zahl = Container(
      constraints: BoxConstraints(minWidth: breit ? 32 : 26, minHeight: breit ? 32 : 26),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(color: istHeute ? kAccent : null, borderRadius: BorderRadius.circular(breit ? 16 : 13)),
      child: Text(
        '${tag.day}',
        maxLines: 1,
        style: TextStyle(fontSize: breit ? 17 : 14, fontWeight: FontWeight.w600, color: istHeute ? kOnAccent : (wochenende ? kTextMuted : kText)),
      ),
    );
    return Semantics(
      button: true,
      selected: markiert,
      label: label,
      excludeSemantics: true,
      onTap: () => onTag(tag),
      child: InkWell(
        key: ValueKey('woche-kopf-${tag.toIso8601String().substring(0, 10)}'),
        onTap: () => onTag(tag),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(color: markiert ? kAccentSoft : null),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _WochenRasterState._kurz[spalte],
                maxLines: 1,
                style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 11 : 10, color: istHeute ? kAccent : kTextMuted),
              ),
              const SizedBox(height: 2),
              zahl,
            ],
          ),
        ),
      ),
    );
  }
}

class _BandBalken extends StatelessWidget {
  final WochenBalken b;
  final bool breit;
  const _BandBalken({required this.b, required this.breit});

  @override
  Widget build(BuildContext context) {
    final r = Radius.circular(breit ? 5 : 4);
    return Padding(
      padding: EdgeInsets.fromLTRB(b.vorneOffen ? 0 : (breit ? 3 : 1), 0.5, b.hintenOffen ? 0 : (breit ? 3 : 1), 0.5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: b.quelle.farbe,
          borderRadius: BorderRadius.horizontal(left: b.vorneOffen ? Radius.zero : r, right: b.hintenOffen ? Radius.zero : r),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: breit ? 8 : 3),
            child: Text(
              b.quelle.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(fontSize: breit ? 12 : 10, fontWeight: FontWeight.w600, color: kOnAccent, height: 1.0),
            ),
          ),
        ),
      ),
    );
  }
}

/// Das 24-Stunden-Raster: Stundenlinien und -zahlen, Spalten je Tag mit Tipp-Fläche, Blöcke, Linie der aktuellen Uhrzeit.
class _Zeitraster extends StatelessWidget {
  final List<DateTime> tage;
  final int heuteIndex;
  final DateTime jetzt;
  final List<WochenBlock> bloecke;
  final Color Function(WochenBlock) farbe;
  final String? Function(WochenBlock)? person;
  final double stunde;
  final double randLinks;
  final bool breit;
  final void Function(WochenBlock) onBlock;
  final void Function(DateTime tag, int minute)? onLeer;
  const _Zeitraster({
    required this.tage,
    required this.heuteIndex,
    required this.jetzt,
    required this.bloecke,
    required this.farbe,
    required this.person,
    required this.stunde,
    required this.randLinks,
    required this.breit,
    required this.onBlock,
    required this.onLeer,
  });

  @override
  Widget build(BuildContext context) {
    final gesamt = 24 * stunde;
    final blockMin = _blockMin(context, breit);
    return SizedBox(
      height: gesamt,
      child: LayoutBuilder(
        builder: (context, c) {
          final spalte = (c.maxWidth - randLinks) / 7;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Stundenlinien und Beschriftung (die 0-Uhr-Linie ist der obere Rand)
              for (var h = 0; h <= 24; h++) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  top: h * stunde,
                  height: 1,
                  child: const ColoredBox(color: kBorderSoft),
                ),
                if (h > 0 && h < 24)
                  Positioned(
                    left: breit ? 10 : 0,
                    width: randLinks - (breit ? 10 : 0),
                    top: h * stunde - 7,
                    child: ExcludeSemantics(
                      child: Text(
                        breit ? '${h.toString().padLeft(2, '0')}:00' : h.toString().padLeft(2, '0'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: TextStyle(fontFamily: kFontMono, fontSize: breit ? 11 : 10, color: kTextFaint, height: 1.0),
                      ),
                    ),
                  ),
              ],
              for (var i = 0; i < 7; i++)
                Positioned(
                  left: randLinks + i * spalte,
                  width: spalte,
                  top: 0,
                  height: gesamt,
                  child: _TagesSpalte(tag: tage[i], spalte: i, heute: i == heuteIndex, stunde: stunde, breit: breit, onLeer: onLeer),
                ),
              for (final b in bloecke)
                Positioned(
                  left: randLinks + b.tag * spalte + b.spalte * spalte / b.spalten,
                  width: spalte / b.spalten,
                  top: b.start / 60 * stunde,
                  height: _blockHoehe(b, stunde, blockMin),
                  child: _Block(b: b, farbe: farbe(b), person: person?.call(b), breit: breit, onTap: () => onBlock(b)),
                ),
              if (heuteIndex >= 0)
                Positioned(
                  left: randLinks,
                  right: 0,
                  top: (jetzt.hour * 60 + jetzt.minute) / 60 * stunde - 1,
                  height: 2,
                  child: IgnorePointer(
                    key: const ValueKey('woche-jetzt'),
                    child: ExcludeSemantics(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Positioned.fill(child: ColoredBox(color: kDanger)),
                          Positioned(
                            left: heuteIndex * spalte - (breit ? 5 : 4),
                            top: breit ? -4.0 : -3.0,
                            width: breit ? 10 : 8,
                            height: breit ? 10 : 8,
                            child: const DecoratedBox(
                              decoration: BoxDecoration(color: kDanger, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

double _blockHoehe(WochenBlock b, double stunde, double min) {
  final h = (b.ende - b.start) / 60 * stunde - 1;
  final ziel = h < min ? min : h;
  // ein kurzer Block am unteren Rand ragt nicht über 24:00 hinaus
  final platz = 24 * stunde - b.start / 60 * stunde;
  return ziel > platz ? platz : ziel;
}

/// Eine Tagesspalte: Trennlinie, Tönung (Wochenende, heute) und die Tipp-Fläche für leere Stellen.
class _TagesSpalte extends StatelessWidget {
  final DateTime tag;
  final int spalte;
  final bool heute;
  final double stunde;
  final bool breit;
  final void Function(DateTime tag, int minute)? onLeer;
  const _TagesSpalte({required this.tag, required this.spalte, required this.heute, required this.stunde, required this.breit, required this.onLeer});

  @override
  Widget build(BuildContext context) {
    final inhalt = DecoratedBox(
      decoration: BoxDecoration(
        color: heute ? kAccent.withValues(alpha: 0.06) : (spalte >= 5 ? kTextStrong.withValues(alpha: 0.025) : null),
        border: const Border(left: BorderSide(color: kBorderSoft)),
      ),
      child: const SizedBox.expand(),
    );
    final leer = onLeer;
    if (leer == null) return inhalt;
    // Handy: Tipp oder Lang-Tipp legt an; Desktop und Web (Maus): nur Doppelklick oder langes Drücken, ein einzelner Klick tut nichts
    return ExcludeSemantics(
      child: _LeerStelle(
        key: ValueKey('woche-spalte-${tag.toIso8601String().substring(0, 10)}'),
        doppelklick: breit,
        onLeer: (dy) => leer(tag, gerundeteMinute(dy / stunde * 60)),
        child: inhalt,
      ),
    );
  }
}

/// Tipp-Fläche einer Tagesspalte: meldet die Höhe (dy) der Stelle für Tipp bzw. Doppelklick und Lang-Tipp.
class _LeerStelle extends StatefulWidget {
  final bool doppelklick;
  final void Function(double dy) onLeer;
  final Widget child;
  const _LeerStelle({super.key, required this.doppelklick, required this.onLeer, required this.child});

  @override
  State<_LeerStelle> createState() => _LeerStelleState();
}

class _LeerStelleState extends State<_LeerStelle> {
  var _dy = 0.0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: (d) => _dy = d.localPosition.dy,
    onTap: widget.doppelklick ? null : () => widget.onLeer(_dy),
    onDoubleTap: widget.doppelklick ? () => widget.onLeer(_dy) : null,
    onLongPressStart: (d) => widget.onLeer(d.localPosition.dy),
    child: widget.child,
  );
}

class _Block extends StatelessWidget {
  final WochenBlock b;
  final Color farbe;
  final String? person;
  final bool breit;
  final VoidCallback onTap;
  const _Block({required this.b, required this.farbe, required this.person, required this.breit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final v = b.v;
    final titel = vorkommenTitel(v);
    final r = Radius.circular(breit ? 6 : 4);
    final schrift = _blockSchrift(breit);
    final rand = _blockRand(breit);
    final spanne = zeitspanneText(v);
    return LayoutBuilder(
      builder: (context, c) {
        final skala = MediaQuery.textScalerOf(context);
        final zeile = skala.scale(schrift) * 1.25;
        final zeilen = ((c.maxHeight - rand) / zeile + 1e-6).floor();
        final mitZeit = breit && zeilen >= 2;
        return Semantics(
          button: true,
          label: [
            titel,
            istUmstellungsSpanne(v) ? '${datumZeitText(v)} ($spanne)' : datumZeitText(v),
            if (v.ort.isNotEmpty) v.ort,
            if (person != null && person!.isNotEmpty) 'von $person',
          ].join(', '),
          excludeSemantics: true,
          onTap: onTap,
          child: GestureDetector(
            key: ValueKey('woche-block-${v.termin.id}|${v.schluessel}|${b.tag}'),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0.5, 0.5, 0.5, 0.5),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: farbe,
                  border: Border.all(color: kBgElevated),
                  borderRadius: BorderRadius.vertical(top: b.vorneOffen ? Radius.zero : r, bottom: b.hintenOffen ? Radius.zero : r),
                ),
                child: ClipRect(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: breit ? 7 : 2, vertical: breit ? 4 : 1),
                    child: zeilen < 1
                        ? const SizedBox.shrink()
                        : Text.rich(
                            TextSpan(
                              text: titel,
                              style: TextStyle(fontSize: schrift, fontWeight: FontWeight.w600, color: kOnAccent, height: 1.25),
                              children: [
                                if (mitZeit)
                                  TextSpan(
                                    text: '\n$spanne',
                                    style: const TextStyle(fontFamily: kFontMono, fontSize: 10, fontWeight: FontWeight.w400),
                                  ),
                              ],
                            ),
                            maxLines: zeilen,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
