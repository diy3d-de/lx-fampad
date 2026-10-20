// Karte der Teilenden (MapLibre, Kacheln als PMTiles vom eigenen Server, siehe docs/KARTE-SPIKE.md): je teilender Person eine Stecknadel mit Profilbild
// (dazu die eigene, solange du teilst), ein dezenter Genauigkeitskreis, Info beim Tippen (Name, "vor X", Genauigkeit), Kamera auf alle eingepasst,
// Knopf "Auf mich zentrieren", Umschalter dunkel/hell (Auswahl lokal gemerkt) und Vollbild. Bewegungen werden weich animiert (kein Springen). Fehlt die Kartendatei auf dem Server, steht hier "Karte noch nicht
// eingerichtet" und die Liste darunter bleibt die Anzeige; Teilende außerhalb des Kartenbereichs bleiben in der Liste, die Karte nennt sie.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Factory, ValueListenable, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/avatar/avatar_foto.dart';
import '../../data/avatar/avatar_vorlagen.dart';
import '../../data/standort/standort_dienst.dart';
import '../../data/standort/standort_modelle.dart';
import '../auth/auth_widgets.dart' show LinkKnopf;
import '../karte/karte_config.dart';
import '../karte/karte_stil.dart';
import '../karte/karte_verfuegbar.dart';
import 'standort_folgen.dart';
import 'standort_pin.dart';
import 'standort_pin_bild.dart';

/// Lädt den Kartenstil (Asset mit den Adressen des eigenen Servers); Tests überschreiben es.
final karteStilProvider = Provider<Future<String> Function(KartenStil stil)>((ref) {
  return (stil) async {
    final vorlage = await rootBundle.loadString(stil.asset);
    return karteStyleAusVorlage(vorlage, karteOrigin());
  };
});

/// Nur für Tests: statt der echten Karte (MapLibre läuft im Widget-Test nicht) eine Attrappe mit denselben Nadeln, Knöpfen und Infos.
final karteAttrappeProvider = Provider<bool>((ref) => false);

/// Nur für Tests: die Attrappe meldet nie "Stil geladen" (wie eine Karte, die auf dem Gerät leer bleibt).
final karteAttrappeLaedtNieProvider = Provider<bool>((ref) => false);

/// Wie lange die Karte auf "Stil geladen" wartet, bevor statt einer leeren Fläche eine Meldung erscheint.
final karteLadeFristProvider = Provider<Duration>((ref) => const Duration(seconds: 10));

/// Höhe der Karte auf der Seite.
const double kKarteHoehe = 320;

/// Ein Punkt auf der Karte (eine teilende Person oder die eigene).
class KartenEintrag {
  final String id;
  final UserDto? user;
  final String name;
  final int farbIndex;
  final double lat;
  final double lng;
  final double? genauigkeit;
  final DateTime messzeit;
  final bool eigene;
  const KartenEintrag({required this.id, required this.user, required this.name, required this.farbIndex, required this.lat, required this.lng, required this.genauigkeit, required this.messzeit, this.eigene = false});
}

/// Kreis um [lat]/[lng] mit [radiusMeter] als geschlossener Ring für eine Fläche; Näherung für kleine Radien.
List<Geographic> kreisRing(double lat, double lng, double radiusMeter, {int punkte = 40}) {
  const grad = 111320.0;
  final dLat = radiusMeter / grad;
  final dLng = radiusMeter / (grad * math.cos(lat * math.pi / 180));
  final ring = <Geographic>[
    for (var i = 0; i < punkte; i++) Geographic(lon: lng + dLng * math.cos(2 * math.pi * i / punkte), lat: lat + dLat * math.sin(2 * math.pi * i / punkte)),
  ];
  return [...ring, ring.first];
}

typedef _KartenDaten = ({List<GeteiltePosition> positionen, Map<String, UserDto> mitglieder});

/// Die Karte der Standort-Seite: in der Seite (Höhe [kKarteHoehe]) oder im Vollbild (eigene Seite über allem, ohne Ränder). Es gibt immer nur EINE Kartenfläche
/// (auf Android höchstens eine MapLibre-Instanz): beim Wechsel wird die andere abgebaut, die neue übernimmt Kamera und Auswahl der Vorgängerin.
class StandortKarte extends ConsumerStatefulWidget {
  final List<GeteiltePosition> positionen;
  final Map<String, UserDto> mitglieder;
  const StandortKarte({super.key, required this.positionen, required this.mitglieder});

  @override
  ConsumerState<StandortKarte> createState() => _StandortKarteState();
}

class _StandortKarteState extends ConsumerState<StandortKarte> {
  bool _vollbild = false;
  MapCamera? _kamera;
  String? _gewaehlt;
  bool _folgen = true;
  Route<void>? _route;
  late final ValueNotifier<_KartenDaten> _daten = ValueNotifier((positionen: widget.positionen, mitglieder: widget.mitglieder));

  @override
  void didUpdateWidget(StandortKarte alt) {
    super.didUpdateWidget(alt);
    // das Vollbild liegt in einer anderen Seite: erst nach dem Bau benachrichtigen (kein Neuaufbau mitten im Bau)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _daten.value = (positionen: widget.positionen, mitglieder: widget.mitglieder);
    });
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null && route.isActive) {
      // die Seite der Karte ist weg (etwa: niemand teilt mehr): das Vollbild nicht verwaist stehen lassen
      scheduleMicrotask(() => route.navigator?.removeRoute(route));
    }
    _daten.dispose();
    super.dispose();
  }

  void _vorgaenger(MapCamera k) => _kamera = k;
  void _auswahl(String? id) => _gewaehlt = id;
  void _folgenMerken(bool an) => _folgen = an;

  /// Öffnet das Vollbild: erst die Karte in der Seite abbauen (ein Bild lang), dann die Vollbild-Seite schieben.
  Future<void> _oeffnen() async {
    if (_vollbild) return;
    setState(() => _vollbild = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final route = PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => _VollbildSeite(daten: _daten, anfangsKamera: _kamera, anfangsGewaehlt: _gewaehlt, anfangsFolgen: _folgen, onKamera: _vorgaenger, onGewaehlt: _auswahl, onFolgen: _folgenMerken),
    );
    _route = route;
    await Navigator.of(context, rootNavigator: true).push(route);
    _route = null;
    // Erst wenn die Vollbild-Karte wirklich abgebaut ist (zwei Bilder), die Karte der Seite neu bauen: nie zwei MapLibre-Instanzen zugleich
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) setState(() => _vollbild = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_vollbild) {
      return const SizedBox(
        height: kKarteHoehe,
        child: _Rahmen(child: Center(child: Text('Karte im Vollbild', style: TextStyle(color: kTextMuted, fontSize: 13)))),
      );
    }
    return _KartenFlaeche(
      positionen: widget.positionen,
      mitglieder: widget.mitglieder,
      vollbild: false,
      anfangsKamera: _kamera,
      anfangsGewaehlt: _gewaehlt,
      anfangsFolgen: _folgen,
      onKamera: _vorgaenger,
      onGewaehlt: _auswahl,
      onFolgen: _folgenMerken,
      onVollbild: _oeffnen,
    );
  }
}

/// Die Vollbild-Seite: die Karte füllt den ganzen Bildschirm (auch hinter Statusleiste und Navigationsleiste). Systemzurück und Esc schließen nur das Vollbild.
class _VollbildSeite extends StatelessWidget {
  final ValueListenable<_KartenDaten> daten;
  final MapCamera? anfangsKamera;
  final String? anfangsGewaehlt;
  final bool anfangsFolgen;
  final ValueChanged<MapCamera> onKamera;
  final ValueChanged<String?> onGewaehlt;
  final ValueChanged<bool> onFolgen;
  const _VollbildSeite({required this.daten, required this.anfangsKamera, required this.anfangsGewaehlt, required this.anfangsFolgen, required this.onKamera, required this.onGewaehlt, required this.onFolgen});

  @override
  Widget build(BuildContext context) {
    final rand = MediaQuery.paddingOf(context);
    void schliessen() => Navigator.of(context).maybePop();
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): schliessen},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: kBg,
          body: Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<_KartenDaten>(
                  valueListenable: daten,
                  builder: (_, d, _) => _KartenFlaeche(
                    positionen: d.positionen,
                    mitglieder: d.mitglieder,
                    vollbild: true,
                    anfangsKamera: anfangsKamera,
                    anfangsGewaehlt: anfangsGewaehlt,
                    anfangsFolgen: anfangsFolgen,
                    onKamera: onKamera,
                    onGewaehlt: onGewaehlt,
                    onFolgen: onFolgen,
                  ),
                ),
              ),
              // dezenter Schleier unter der Statusleiste: ihre Zeichen bleiben auf hellem und dunklem Stil lesbar
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: rand.top + 12,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [kBg.withValues(alpha: 0.6), kBg.withValues(alpha: 0)])),
                  ),
                ),
              ),
              Positioned(left: 4 + rand.left, top: 4 + rand.top, child: _KartenKnopf(icon: Icons.fullscreen_exit, tooltip: 'Vollbild beenden', onTap: schliessen)),
            ],
          ),
        ),
      ),
    );
  }
}

class _KartenFlaeche extends ConsumerStatefulWidget {
  final List<GeteiltePosition> positionen;
  final Map<String, UserDto> mitglieder;
  final bool vollbild;

  /// Kamera und Auswahl der Vorgängerin (Wechsel zwischen Seite und Vollbild): die Karte öffnet dort, nicht auf "alle zeigen".
  final MapCamera? anfangsKamera;
  final String? anfangsGewaehlt;
  final bool anfangsFolgen;
  final ValueChanged<MapCamera>? onKamera;
  final ValueChanged<String?>? onGewaehlt;
  final ValueChanged<bool>? onFolgen;
  final VoidCallback? onVollbild;
  const _KartenFlaeche({required this.positionen, required this.mitglieder, required this.vollbild, this.anfangsKamera, this.anfangsGewaehlt, this.anfangsFolgen = true, this.onKamera, this.onGewaehlt, this.onFolgen, this.onVollbild});

  @override
  ConsumerState<_KartenFlaeche> createState() => _KartenFlaecheState();
}

class _Punkt {
  final double lat;
  final double lng;
  const _Punkt(this.lat, this.lng);
  static _Punkt lerp(_Punkt a, _Punkt b, double t) => _Punkt(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
}

class _KartenFlaecheState extends ConsumerState<_KartenFlaeche> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..addListener(() => setState(() {}));
  final Map<String, _Punkt> _von = {};
  final Map<String, _Punkt> _nach = {};
  Future<String>? _stil;
  MapController? _ctrl;

  /// Der Stil (dunkel/hell), den die Karte gerade zeigt bzw. lädt; null, bis der erste Stil angefordert ist.
  KartenStil? _angewandt;

  /// Zählt die Stilwechsel: Teil der Bild-Kennungen der Nadeln (nach einem Wechsel melden wir sie unter neuen Namen an, ob die Karte die alten Bilder behalten hat oder nicht).
  int _stilNr = 0;
  List<String> _alteBilder = [];

  /// Zuletzt gemeldete Kamera (für die Übergabe an die nächste Kartenfläche) und ob diese Fläche mit einer übernommenen Kamera begann.
  MapCamera? _kamera;
  late final bool _uebernommen = widget.anfangsKamera != null;

  /// Nur Web: Die Nadeln sind dort Symbole der Karte selbst (WebGL), nicht Flutter-Widgets darüber. Flutter zeichnet nach einer Kartenbewegung erst im
  /// nächsten Bild neu, die Nadeln "schwammen" deshalb beim Ziehen. [_style] nimmt die Bilder auf, [_bilder] führt Buch über die Bilder je Person.
  StyleController? _style;
  final PinBildCache _bilder = PinBildCache();
  String? _gewaehlt;

  /// "Folgen": die Karte wandert mit der gewählten (oder einzigen) Person mit. Standard an; ein Schieben oder Zoomen mit der Hand und "Alle zeigen" schalten es aus,
  /// ein Tipp auf den Knopf oder auf die Nadel wieder an.
  late bool _folgen = widget.anfangsFolgen;
  Set<String> _angepasst = {};
  Timer? _auffrischen;

  /// Stil geladen (MapLibre meldet "fertig"): erst dann gibt es Nadeln und Kreise; ohne Stil zeigt die Karte nach [karteLadeFristProvider] eine Meldung.
  bool _geladen = false;
  bool _zeitueberschreitung = false;
  Timer? _ladeTimer;
  Key _kartenSchluessel = UniqueKey();

  /// Bereich der Kartendatei (aus ihrem Kopf), gesetzt, sobald die Karte gebaut wird.
  KartenBereich _bereich = KartenBereich.westerburg175;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _kamera = widget.anfangsKamera;
    _gewaehlt = widget.anfangsGewaehlt;
    _auffrischen = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auffrischen?.cancel();
    _ladeTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  /// Rückkehr in die App: Gab es die Datei nicht oder war der Server nicht erreichbar, noch einmal nachsehen (eine Anfrage).
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _nochmalPruefen();
  }

  void _nochmalPruefen() {
    final d = ref.read(karteDateiProvider);
    if (!d.isLoading && (d.hasError || d.value == null)) ref.invalidate(karteDateiProvider);
  }

  void _stilGeladen() {
    _ladeTimer?.cancel();
    if (!mounted) return;
    final erstes = !_geladen;
    if (erstes) setState(() => _geladen = true);
    // Einpassen noch einmal mit fertiger Karte: Im Web steht beim ersten Mal (onMapCreated) die Größe der Karten-Ansicht noch nicht, das Zoomen ginge falsch aus
    // (nicht bei übernommener Kamera: die Person soll dort weitermachen, wo sie war)
    if (erstes && !_uebernommen) Future<void>.delayed(const Duration(milliseconds: 300), () => mounted ? _alleZeigen() : null);
    // Stilwechsel: die Bilder der Nadeln (Web) gehen mit dem alten Stil verloren und werden im neuen neu angemeldet (Neuaufbau löst _bilderSichern aus)
    if (erstes) unawaited(_stilAbgleichen()); // Wahl, die während des ersten Ladens getroffen wurde
    if (!erstes) {
      final style = _style;
      if (style != null) _bilderEntfernen(style, _alteBilder);
      _alteBilder = [];
      setState(() {});
    }
  }

  bool _stilLaeuft = false;

  /// Bringt die Karte auf den gewählten Stil (Gerätewahl, nicht je Person). [_angewandt] ist immer der Stil, den die Karte wirklich zeigt: Er ändert sich erst nach
  /// erfolgreichem `setStyle`. Vorher (Karte noch nicht geladen) wird die Wahl gemerkt und nach dem Laden angewendet; bei einem Fehler bleibt die Karte im bisherigen Stil
  /// und nichts (Nadelbilder, Zähler) wird verändert; `setStyle` läuft nur, wenn der Zielstil vom gezeigten abweicht (schnelles A-B-A kostet nichts).
  Future<void> _stilAbgleichen() async {
    if (_stilLaeuft || !mounted) return;
    final attrappe = ref.read(karteAttrappeProvider);
    _stilLaeuft = true;
    try {
      while (mounted && _geladen && (_ctrl != null || attrappe)) {
        final ziel = ref.read(kartenStilProvider);
        if (_angewandt == null || ziel == _angewandt) return;
        final json = await ref.read(karteStilProvider)(ziel);
        if (!mounted || ref.read(kartenStilProvider) != ziel) continue; // inzwischen wieder umgeschaltet: neu entscheiden
        _ctrl?.setStyle(json);
        // erst nach erfolgreichem setStyle: Nadelbilder des alten Stils vormerken, neuer Zähler (neue Kennungen), Bilder neu anmelden
        _style = null;
        _alteBilder = [..._alteBilder, ..._bilder.bereit.values];
        _stilNr++;
        _bilder.leeren();
        setState(() => _angewandt = ziel);
      }
    } catch (_) {
      // Stil nicht ladbar oder nicht setzbar: die Karte bleibt im bisherigen Stil (Knopf und Kreis zeigen ihn)
    } finally {
      _stilLaeuft = false;
    }
  }

  Future<String> _stilLaden() async {
    await ref.read(kartenStilProvider.notifier).bereit; // gespeicherte Auswahl zuerst, sonst blitzt erst der Standard auf
    final wahl = ref.read(kartenStilProvider);
    _angewandt = wahl;
    return ref.read(karteStilProvider)(wahl);
  }

  void _waehle(String? id) {
    setState(() {
      _gewaehlt = id;
      if (id != null) _folgen = true; // Tipp auf die Nadel: dieser Person folgen
    });
    widget.onGewaehlt?.call(id);
    widget.onFolgen?.call(_folgen);
    if (id != null) unawaited(_folgenZentrieren());
  }

  void _folgenSetzen(bool an) {
    if (_folgen == an) return;
    setState(() => _folgen = an);
    widget.onFolgen?.call(an);
  }

  /// Wer gerade verfolgt würde: die gewählte Person, sonst die einzige auf der Karte (nur im Kartenbereich).
  String? _folgeZiel() => folgeZiel(gewaehlt: _gewaehlt, ids: [for (final e in _imBereich(_eintraege())) e.id]);

  /// Zentriert die Karte sanft auf das Ziel, der Zoom bleibt (kein Springen). Nur bei aktivem Folgen.
  Future<void> _folgenZentrieren() async {
    final c = _ctrl;
    final ziel = _folgeZiel();
    if (!_folgen || c == null || ziel == null) return;
    final p = _nach[ziel];
    if (p == null) return;
    try {
      await c.animateCamera(center: Geographic(lon: p.lng, lat: p.lat), zoom: _kamera?.zoom, nativeDuration: const Duration(milliseconds: 800));
    } catch (_) {
      // die Karte ist nicht bereit oder schon weg
    }
  }

  /// Wartet auf "Stil geladen"; bleibt die Meldung aus (Kacheln oder Stil kommen nicht an, Darstellung scheitert), erscheint nach der Frist eine Meldung.
  void _ladeFristStarten() {
    if (_geladen || _ladeTimer?.isActive == true || _zeitueberschreitung) return;
    _ladeTimer = Timer(ref.read(karteLadeFristProvider), () {
      if (mounted && !_geladen) setState(() => _zeitueberschreitung = true);
    });
  }

  /// "Erneut versuchen" nach einer Zeitüberschreitung: neue Karten-Ansicht, neuer Stil.
  void _neuVersuchen() {
    _ladeTimer?.cancel();
    setState(() {
      _zeitueberschreitung = false;
      _geladen = ref.read(karteAttrappeProvider) && !ref.read(karteAttrappeLaedtNieProvider);
      _kartenSchluessel = UniqueKey();
      _stil = null;
      _style = null;
      _alteBilder = [];
      _bilder.leeren();
    });
    ref.invalidate(karteDateiProvider);
  }

  /// "Erneut prüfen" auch bei einem Fehler beim Laden des Stils: der gemerkte Fehler-Future wird verworfen.
  void _neuPruefen() {
    setState(() => _stil = null);
    ref.invalidate(karteDateiProvider);
  }

  List<KartenEintrag> _eintraege() {
    final st = ref.read(standortProvider);
    final ich = ref.read(authProvider).user;
    final liste = <KartenEintrag>[
      for (final p in widget.positionen)
        if (p.hatPosition)
          KartenEintrag(
            id: p.userId,
            user: widget.mitglieder[p.userId],
            name: widget.mitglieder[p.userId]?.displayName ?? 'Unbekannt',
            farbIndex: widget.mitglieder[p.userId]?.colorIndex ?? 0,
            lat: p.breite!,
            lng: p.laenge!,
            genauigkeit: p.genauigkeit,
            messzeit: p.messzeit!,
          ),
    ];
    final e = st.eigene;
    if (st.phase == StandortPhase.teilt && e != null && ich != null) {
      liste.add(KartenEintrag(id: ich.id, user: ich, name: 'Du', farbIndex: ich.colorIndex, lat: e.breite, lng: e.laenge, genauigkeit: e.genauigkeit, messzeit: e.zeit, eigene: true));
    }
    return liste;
  }

  /// Aktuell gezeigter (animierter) Punkt einer Person.
  _Punkt _gezeigt(String id, _Punkt ziel) {
    final nach = _nach[id];
    final von = _von[id];
    if (nach == null || von == null) return ziel;
    return _Punkt.lerp(von, nach, Curves.easeInOut.transform(_anim.value));
  }

  /// Neue Ziele übernehmen und die Bewegung von der jetzt gezeigten Stelle aus starten.
  Set<String> _ziele(List<KartenEintrag> eintraege) {
    final bewegte = <String>{};
    var bewegt = false;
    final ids = {for (final e in eintraege) e.id};
    _von.removeWhere((id, _) => !ids.contains(id));
    _nach.removeWhere((id, _) => !ids.contains(id));
    for (final e in eintraege) {
      final ziel = _Punkt(e.lat, e.lng);
      final alt = _nach[e.id];
      if (alt == null) {
        _von[e.id] = ziel;
        _nach[e.id] = ziel;
      } else if (alt.lat != ziel.lat || alt.lng != ziel.lng) {
        _von[e.id] = _gezeigt(e.id, alt);
        _nach[e.id] = ziel;
        bewegt = true;
        bewegte.add(e.id);
      }
    }
    if (bewegt) _anim.forward(from: 0);
    return bewegte;
  }

  @override
  void didUpdateWidget(_KartenFlaeche alt) {
    super.didUpdateWidget(alt);
    final bewegte = _ziele(_eintraege());
    _einpassenWennNeu();
    // ein neues Standortpaket der verfolgten Person: Karte sanft mitnehmen
    final ziel = _folgeZiel();
    if (_folgen && ziel != null && bewegte.contains(ziel)) unawaited(_folgenZentrieren());
  }

  List<KartenEintrag> _imBereich(List<KartenEintrag> l) => [for (final e in l) if (_bereich.enthaelt(e.lat, e.lng)) e];

  /// Passt die Kamera an, wenn jemand dazugekommen oder weggegangen ist (nicht bei jeder Bewegung: die Person darf selbst schieben).
  void _einpassenWennNeu() {
    final ids = {for (final e in _imBereich(_eintraege())) e.id};
    if (ids.isEmpty || (ids.length == _angepasst.length && ids.containsAll(_angepasst))) return;
    _angepasst = ids;
    unawaited(_alleZeigen());
  }

  Future<void> _alleZeigen() async {
    final c = _ctrl;
    final e = _imBereich(_eintraege());
    if (c == null || e.isEmpty) return;
    try {
      if (e.length == 1 || _eng(e)) {
        await c.animateCamera(center: Geographic(lon: e.first.lng, lat: e.first.lat), zoom: 15, nativeDuration: const Duration(milliseconds: 800));
        return;
      }
      var w = e.first.lng, o = e.first.lng, s = e.first.lat, n = e.first.lat;
      for (final x in e) {
        w = w < x.lng ? w : x.lng;
        o = o > x.lng ? o : x.lng;
        s = s < x.lat ? s : x.lat;
        n = n > x.lat ? n : x.lat;
      }
      await c.fitBounds(
        bounds: LngLatBounds(longitudeWest: w, longitudeEast: o, latitudeSouth: s, latitudeNorth: n),
        padding: const EdgeInsets.fromLTRB(64, 96, 64, 96),
        webMaxZoom: 16,
        nativeDuration: const Duration(milliseconds: 800),
      );
    } catch (_) {
      // die Karte ist (noch) nicht bereit oder schon weg: nichts zu tun
    }
  }

  /// Alle Punkte liegen praktisch aufeinander (unter etwa 30 m): kein Einpassen, sondern auf die Stelle zoomen.
  bool _eng(List<KartenEintrag> e) {
    for (final x in e) {
      if ((x.lat - e.first.lat).abs() > 0.0003 || (x.lng - e.first.lng).abs() > 0.0004) return false;
    }
    return true;
  }

  Future<void> _aufMich() async {
    final c = _ctrl;
    final ich = _eintraege().where((e) => e.eigene).firstOrNull;
    if (c == null || ich == null) return;
    try {
      await c.animateCamera(center: Geographic(lon: ich.lng, lat: ich.lat), zoom: 16, nativeDuration: const Duration(milliseconds: 800));
    } catch (_) {}
  }

  /// Kopfbild einer Person für die Nadel (Platzhalter-Zeichnung oder Foto); null: Initialen.
  Future<({Uint8List? bytes, bool aufFarbe})> _kopfBild(UserDto? u) async {
    final a = u?.avatar;
    if (u == null || a == null) return (bytes: null, aufFarbe: false);
    try {
      if (!a.istFoto) {
        final v = avatarVorlage(a.vorlage);
        if (v == null) return (bytes: null, aufFarbe: false);
        final d = await rootBundle.load(v.asset);
        return (bytes: d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes), aufFarbe: true);
      }
      return (bytes: await ref.read(avatarFotoProvider((userId: u.id, version: a.version)).future), aufFarbe: false);
    } catch (_) {
      return (bytes: null, aufFarbe: false);
    }
  }

  /// Entfernt abgelöste Bilder aus dem Stil, kurz verzögert: Die Karte stellt die Symbole erst im nächsten Bild auf das neue Bild um.
  void _bilderEntfernen(StyleController style, List<String> ids) {
    if (ids.isEmpty) return;
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      for (final id in ids) {
        try {
          await style.removeImage(id);
        } catch (_) {
          // schon weg (neue Karten-Ansicht): nichts zu tun
        }
      }
    });
  }

  /// Pixeldichte, mit der das Web-Paket die Bilder der Karte anmeldet (dieselbe Quelle wie dort: die erste Ansicht).
  double _pixeldichte() => WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

  /// Sorgt dafür, dass zu jeder Nadel genau ein passendes Bild im Kartenstil liegt (Web); Buchführung in [PinBildCache].
  /// Fertig: die Karte zeichnet neu. Das Vorgängerbild und die Bilder gegangener Personen werden entfernt, fehlgeschlagene Bilder nicht erneut versucht.
  void _bilderSichern(List<KartenEintrag> eintraege, DateTime jetzt) {
    final style = _style;
    if (style == null) return;
    final massstab = pinMassstab(_pixeldichte());
    _bilderEntfernen(style, _bilder.aufraeumen({for (final e in eintraege) e.id}));
    for (final e in eintraege) {
      final a = e.user?.avatar;
      final veraltet = !e.eigene && jetzt.difference(e.messzeit) >= kStandortVeraltetNach;
      final gewaehlt = e.id == _gewaehlt;
      final id = 'pin-${e.id}-${Object.hash(e.farbIndex, e.name, a?.istFoto, a?.vorlage, a?.version, veraltet, gewaehlt, e.eigene, massstab, _stilNr)}';
      if (!_bilder.anfordern(e.id, id)) continue;
      unawaited(() async {
        var ok = false;
        try {
          final k = await _kopfBild(e.user);
          final png = await pinPng(PinBildAngaben(farbIndex: e.farbIndex, name: e.name, kopfBild: k.bytes, bildAufFarbe: k.aufFarbe, veraltet: veraltet, gewaehlt: gewaehlt, eigene: e.eigene), massstab: massstab);
          if (mounted && _style == style) {
            await style.addImage(id, png);
            ok = true;
          }
        } catch (_) {
          // Bild nicht möglich: diese Nadel fehlt, der Rest der Karte bleibt benutzbar
        }
        if (_style != style) return; // neue Karten-Ansicht: der Stil ist weg, das Buch wurde geleert
        final weg = _bilder.fertig(e.id, id, ok: ok);
        _bilderEntfernen(style, weg);
        if (mounted && ok) setState(() {});
      }());
    }
  }

  /// Stabile Reihenfolge der Ebenen: nach Kennung. Die Ebenen der Karte hängen an ihrer Stelle in der Liste; ein Umsortieren (etwa die gewählte Person ans Ende)
  /// würde bei jedem Animationsschritt Ebenen neu aufbauen. Die Auswahl zeigt das Bild (Rand), nicht die Reihenfolge.
  List<KartenEintrag> _nachId(List<KartenEintrag> l) => [...l]..sort((a, b) => a.id.compareTo(b.id));

  /// Tipp auf die Karte (Web): die getroffene Nadel (bei Überdeckung die vorderste) wählen oder abwählen.
  void _kartenEreignis(MapEvent ev, List<KartenEintrag> eintraege) {
    final c = _ctrl;
    if (ev is! MapEventClick || c == null || !_geladen) return;
    // vorderste Nadel zuerst: die Karte zeichnet die Symbole in der Reihenfolge der Ebenen (nach Kennung, siehe [_nachId])
    for (final e in _nachId(eintraege).reversed) {
      if (!_bereich.enthaelt(e.lat, e.lng) || _bilder.bereit[e.id] == null) continue;
      final p = _gezeigt(e.id, _Punkt(e.lat, e.lng));
      if (pinGetroffen(ev.screenPoint, c.toScreenLocation(Geographic(lon: p.lng, lat: p.lat)))) {
        _waehle(_gewaehlt == e.id ? null : e.id);
        return;
      }
    }
  }

  void _kartenFertig(MapController c) {
    _ctrl = c;
    _angepasst = {};
    if (_uebernommen) {
      // Kamera der Vorgängerin übernommen: nicht neu einpassen, nur merken, wer schon berücksichtigt ist
      _angepasst = {for (final e in _imBereich(_eintraege())) e.id};
    } else {
      _einpassenWennNeu();
    }
  }

  @override
  Widget build(BuildContext context) {
    final datei = ref.watch(karteDateiProvider);
    // die Verbindung steht wieder: Karte noch einmal suchen
    ref.listen(standortProvider.select((s) => s.verbunden), (_, verbunden) {
      if (verbunden) _nochmalPruefen();
    });
    return SizedBox(
      height: widget.vollbild ? null : kKarteHoehe,
      child: datei.when(
        loading: () => const _Rahmen(child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))),
        error: (_, _) => _NichtEingerichtet(titel: 'Karte nicht erreichbar', text: 'Der Kartenserver ließ sich nicht erreichen (Verbindung?).', onNeuPruefen: _neuPruefen),
        data: (bereich) => bereich == null ? _NichtEingerichtet(onNeuPruefen: _neuPruefen) : _karte(context, bereich),
      ),
    );
  }

  Widget _karte(BuildContext context, KartenBereich bereich) {
    _bereich = bereich;
    // in der Attrappe (Tests) braucht es keinen Stil
    _stil ??= _stilLaden();
    ref.listen(kartenStilProvider, (_, _) => unawaited(_stilAbgleichen()));
    // Knopf und Kreisfarbe zeigen den Stil, den die Karte wirklich hat (bis zum ersten Laden die Wahl)
    final KartenStil stilWahl = _angewandt ?? ref.watch(kartenStilProvider);
    final rand = widget.vollbild ? MediaQuery.paddingOf(context) : EdgeInsets.zero;
    final attrappe = ref.read(karteAttrappeProvider);
    // die Attrappe (Tests) gilt als geladen, außer sie soll nie laden
    if (attrappe && !ref.read(karteAttrappeLaedtNieProvider)) _geladen = true;
    _ladeFristStarten();
    final eintraege = _eintraege();
    if (_nach.isEmpty && eintraege.isNotEmpty) _ziele(eintraege);
    final jetzt = ref.read(standortUhrProvider)();
    final glPins = kIsWeb && !attrappe;
    final geordnet = _nachId(eintraege);
    if (glPins && _geladen) _bilderSichern(eintraege, jetzt);
    final ausserhalb = [for (final e in eintraege) if (!bereich.enthaelt(e.lat, e.lng)) e.eigene ? 'Du' : e.name];
    final gewaehlt = eintraege.where((e) => e.id == _gewaehlt).firstOrNull;
    final folgeZielJetzt = folgeZiel(gewaehlt: _gewaehlt, ids: [for (final e in eintraege) if (bereich.enthaelt(e.lat, e.lng)) e.id]);
    // "Auf mich zentrieren" nur, wenn die eigene Position auf der Karte liegt
    final hatEigene = eintraege.any((e) => e.eigene && bereich.enthaelt(e.lat, e.lng));

    List<Marker> marker() => [
      for (final e in eintraege)
        // ohne geladene Karte keine Nadeln (keine Nadeln auf leerer Fläche)
        if (_geladen && bereich.enthaelt(e.lat, e.lng))
          Marker(
            point: () {
              final p = _gezeigt(e.id, _Punkt(e.lat, e.lng));
              return Geographic(lon: p.lng, lat: p.lat);
            }(),
            size: kPinGroesse,
            alignment: Alignment.bottomCenter,
            child: _PinKnopf(eintrag: e, gewaehlt: e.id == _gewaehlt, veraltet: !e.eigene && jetzt.difference(e.messzeit) >= kStandortVeraltetNach, onTap: () => _waehle(_gewaehlt == e.id ? null : e.id)),
          ),
    ];

    return _Rahmen(
      rund: !widget.vollbild,
      child: FutureBuilder<String>(
        future: _stil,
        builder: (context, snap) {
          if (snap.hasError) return _NichtEingerichtet(titel: 'Karte nicht verfügbar', text: 'Der Kartenstil konnte nicht geladen werden.', onNeuPruefen: _neuPruefen);
          if (!snap.hasData) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
          final attrappe = ref.watch(karteAttrappeProvider);
          return Stack(
            children: [
              Positioned.fill(
                child: attrappe
                    ? Center(child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.end, children: [for (final m in marker()) SizedBox(width: m.size.width, height: m.size.height, child: m.child)]))
                    : MapLibreMap(
                        options: MapOptions(
                          initStyle: snap.data!,
                          initCenter: _kamera?.center ?? const Geographic(lon: 7.9741, lat: 50.5612),
                          initZoom: _kamera?.zoom ?? 8,
                          initBearing: _kamera?.bearing ?? 0,
                          initPitch: _kamera?.pitch ?? 0,
                          minZoom: 5,
                          maxZoom: 17,
                          maxBounds: LngLatBounds(longitudeWest: bereich.west, longitudeEast: bereich.ost, latitudeSouth: bereich.sued, latitudeNorth: bereich.nord),
                        ),
                        key: _kartenSchluessel,
                        onMapCreated: _kartenFertig,
                        onStyleLoaded: (s) {
                          _style = s;
                          _stilGeladen();
                        },
                        onEvent: (ev) {
                          if (ev is MapEventStartMoveCamera && ev.reason == CameraChangeReason.apiGesture) {
                            _folgenSetzen(false); // die Person schiebt oder zoomt selbst
                          } else if (ev is MapEventMoveCamera) {
                            _kamera = ev.camera;
                            widget.onKamera?.call(ev.camera);
                          } else if (glPins) {
                            _kartenEreignis(ev, eintraege);
                          }
                        },
                        // die Karte bekommt alle Gesten, auch in der scrollenden Seite (sonst scrollt jede Wischgeste die Seite statt die Karte zu bewegen)
                        gestureRecognizers: {Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new)},
                        layers: [
                          PolygonLayer(
                            polygons: [
                              for (final e in eintraege)
                                if (_geladen && bereich.enthaelt(e.lat, e.lng) && e.genauigkeit != null && e.genauigkeit! > 3)
                                  () {
                                    final p = _gezeigt(e.id, _Punkt(e.lat, e.lng));
                                    return Feature(geometry: Polygon.from([kreisRing(p.lat, p.lng, e.genauigkeit!)]));
                                  }(),
                            ],
                            // auf dem hellen Stil ist Cyan kaum zu sehen: dort Violett (Design-Token neural)
                            color: (stilWahl.istHell ? kNeural : kAccent).withValues(alpha: stilWahl.istHell ? 0.14 : 0.10),
                            outlineColor: (stilWahl.istHell ? kNeural : kAccent).withValues(alpha: stilWahl.istHell ? 0.75 : 0.45),
                          ),
                          if (glPins)
                            for (final e in geordnet)
                              if (_geladen && bereich.enthaelt(e.lat, e.lng) && _bilder.bereit[e.id] != null)
                                MarkerLayer(
                                  points: [
                                    () {
                                      final p = _gezeigt(e.id, _Punkt(e.lat, e.lng));
                                      return Feature(geometry: Point(Geographic(lon: p.lng, lat: p.lat)));
                                    }(),
                                  ],
                                  iconImage: _bilder.bereit[e.id],
                                  iconAnchor: IconAnchor.bottom,
                                  iconAllowOverlap: true,
                                  iconIgnorePlacement: true,
                                  iconSize: pinIconSize(pinMassstab(_pixeldichte()), _pixeldichte()),
                                  // Ausrichtung zur Bildschirmfläche (Vorgabe 'auto' = viewport für Punktsymbole): die Nadel bleibt auch bei gedrehter oder geneigter Karte aufrecht
                                ),
                        ],
                        // Android: Nadeln als Flutter-Widgets über der Karte (dort bewegen sich Karte und Widgets im selben Bild)
                        children: glPins ? const [] : [WidgetLayer(markers: marker())],
                      ),
              ),
              if (_zeitueberschreitung && !_geladen)
                Positioned.fill(
                  child: _NichtEingerichtet(
                    titel: 'Karte konnte nicht geladen werden',
                    text: 'Kartenstil oder Kacheln kamen nicht an (Verbindung?).',
                    knopf: 'Erneut versuchen',
                    onNeuPruefen: _neuVersuchen,
                  ),
                ),
              if (ausserhalb.isNotEmpty && _geladen)
                Positioned(
                  left: widget.vollbild ? 56 + rand.left : 8,
                  top: 8 + rand.top,
                  right: 64 + rand.right,
                  child: _Zettel(text: '${ausserhalb.join(', ')}: außerhalb des Kartenbereichs (nur in der Liste)', farbe: kWarn),
                ),
              Positioned(
                right: 4 + rand.right,
                top: 4 + rand.top,
                child: Column(
                  children: [
                    if (!widget.vollbild) _KartenKnopf(icon: Icons.fullscreen, tooltip: 'Vollbild', onTap: widget.onVollbild),
                    _KartenKnopf(
                      icon: stilWahl.istHell ? Icons.dark_mode : Icons.light_mode,
                      tooltip: stilWahl.umschaltText,
                      onTap: () => unawaited(ref.read(kartenStilProvider.notifier).umschalten()),
                    ),
                    _KartenKnopf(
                      icon: _folgen && folgeZielJetzt != null ? Icons.gps_fixed : Icons.gps_not_fixed,
                      tooltip: _folgen && folgeZielJetzt != null ? 'Folgen beenden' : 'Folgen',
                      aktiv: _folgen && folgeZielJetzt != null,
                      onTap: folgeZielJetzt == null
                          ? null
                          : () {
                              _folgenSetzen(!_folgen);
                              if (_folgen) unawaited(_folgenZentrieren());
                            },
                    ),
                    _KartenKnopf(
                      icon: Icons.zoom_out_map,
                      tooltip: 'Alle zeigen',
                      onTap: () {
                        _folgenSetzen(false);
                        unawaited(_alleZeigen());
                      },
                    ),
                    _KartenKnopf(
                      icon: Icons.my_location,
                      tooltip: 'Auf mich zentrieren',
                      onTap: hatEigene
                          ? () {
                              _folgenSetzen(false);
                              unawaited(_aufMich());
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              if (gewaehlt != null)
                Positioned(left: 8 + rand.left, right: 8 + rand.right, bottom: 34 + rand.bottom, child: _Info(eintrag: gewaehlt, jetzt: jetzt, onSchliessen: () => _waehle(null))),
              Positioned(right: 8 + rand.right, bottom: 8 + rand.bottom, child: const _Attribution()),
            ],
          );
        },
      ),
    );
  }
}

/// Rahmen wie eine Karte der Oberfläche.
class _Rahmen extends StatelessWidget {
  final Widget child;

  /// Mit Rand und runden Ecken (in der Seite); im Vollbild füllt die Karte alles.
  final bool rund;
  const _Rahmen({required this.child, this.rund = true});

  @override
  Widget build(BuildContext context) => rund
      ? DecoratedBox(
          decoration: BoxDecoration(color: kSurface, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(14)),
          child: ClipRRect(borderRadius: BorderRadius.circular(13), child: child),
        )
      : ColoredBox(color: kSurface, child: child);
}

/// Ersatz, solange es keine Kartendatei gibt: kein Fehler, die Liste zeigt weiter alles.
class _NichtEingerichtet extends StatelessWidget {
  final String titel;
  final String text;
  final VoidCallback onNeuPruefen;
  final String knopf;
  const _NichtEingerichtet({this.knopf = 'Erneut prüfen', this.titel = 'Karte noch nicht eingerichtet', this.text = 'Die Kartendaten sind auf dem Server noch nicht hinterlegt.', required this.onNeuPruefen});

  @override
  Widget build(BuildContext context) => _Rahmen(
    // scrollbar: bei kleiner Höhe oder großer Schrift (Textskala 1.5) darf nichts überlaufen
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 32, color: kTextFaint),
            const SizedBox(height: 6),
            Text(titel, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('$text Die Liste unten zeigt weiterhin alle Positionen.', textAlign: TextAlign.center, style: const TextStyle(color: kTextMuted, fontSize: 13)),
            LinkKnopf(knopf, icon: Icons.refresh, onPressed: onNeuPruefen),
          ],
        ),
      ),
    ),
  );
}

/// Nadel als Knopf: Touch-Ziel mindestens 44 px (die Nadel ist 48 x 62), mit Beschriftung für Screenreader.
class _PinKnopf extends StatelessWidget {
  final KartenEintrag eintrag;
  final bool gewaehlt;
  final bool veraltet;
  final VoidCallback onTap;
  const _PinKnopf({required this.eintrag, required this.gewaehlt, required this.veraltet, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${eintrag.eigene ? 'Dein Standort' : 'Standort von ${eintrag.name}'}${veraltet ? ', nicht mehr aktuell' : ''}',
    excludeSemantics: true,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: StandortPin(user: eintrag.user, name: eintrag.name, farbIndex: eintrag.farbIndex, gewaehlt: gewaehlt, veraltet: veraltet, eigene: eintrag.eigene),
    ),
  );
}

/// Kartenknopf (48 px, wie ein IconButton), auf der Karte lesbar durch eine Fläche in der Oberflächenfarbe.
class _KartenKnopf extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// Eingeschalteter Zustand (z. B. "Folgen"): Akzentrand und -fläche, zusätzlich zum Symbol und zum Tooltip.
  final bool aktiv;
  const _KartenKnopf({required this.icon, required this.tooltip, required this.onTap, this.aktiv = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: aktiv ? kAccentSoft : kBg.withValues(alpha: 0.85),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: aktiv ? kAccent : kBorder)),
      child: Semantics(
        toggled: aktiv ? true : null,
        child: IconButton(icon: Icon(icon, color: onTap == null ? kTextFaint : kAccent), tooltip: tooltip, onPressed: onTap, constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
      ),
    ),
  );
}

class _Zettel extends StatelessWidget {
  final String text;
  final Color farbe;
  const _Zettel({required this.text, required this.farbe});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: DecoratedBox(
      decoration: BoxDecoration(color: kBg.withValues(alpha: 0.88), border: Border.all(color: farbe.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(8)),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Text(text, style: TextStyle(fontSize: 12, color: farbe))),
    ),
  );
}

/// Info zur gewählten Nadel: Name, "vor X", Genauigkeit.
class _Info extends StatelessWidget {
  final KartenEintrag eintrag;
  final DateTime jetzt;
  final VoidCallback onSchliessen;
  const _Info({required this.eintrag, required this.jetzt, required this.onSchliessen});

  @override
  Widget build(BuildContext context) {
    final alter = jetzt.difference(eintrag.messzeit);
    final zeile = '${alterText(alter.isNegative ? Duration.zero : alter)} · ${genauigkeitText(eintrag.genauigkeit)}';
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${eintrag.name}, $zeile',
      child: DecoratedBox(
        decoration: BoxDecoration(color: kBg.withValues(alpha: 0.92), border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(eintrag.eigene ? 'Du' : eintrag.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
                    Text(zeile, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
              IconButton(icon: const Icon(Icons.close, size: 18), tooltip: 'Schließen', onPressed: onSchliessen, constraints: const BoxConstraints(minWidth: 48, minHeight: 48)),
            ],
          ),
        ),
      ),
    );
  }
}

/// ODbL: Hinweis auf die Datenquelle, immer sichtbar.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Kartendaten $kKarteAttribution',
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(color: kBg.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(6)),
      child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Text(kKarteAttribution, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted))),
    ),
  );
}
