// Belegung des Wochenrasters: Zeittermine werden auf die Tage der Woche aufgeteilt (über Mitternacht: Teil bis 24:00 und Teil ab 0:00), überlappende
// Termine eines Tages stehen nebeneinander (Spalten), Ganztägiges und Mehrtägiges gehört ins Band (Balken, Belegung in monat_layout.dart).
// Reine Logik ohne Oberfläche (testbar). Alle Zeiten sind Wanduhr der Familienzone (`Vorkommen.startWand`/`endeWand`, als UTC getarnt): eine
// Minute des Rasters ist die Minute der Wanduhr, die Zeitumstellung verschiebt also nichts im Raster (die Uhr springt, das Raster nicht).
import 'expansion.dart';

/// Ein Stück eines Zeittermins an einem Tag der Woche: [start] bis [ende] in Minuten seit 0:00 (0 bis 1440).
class WochenBlock {
  final Vorkommen v;

  /// Spalte der Woche (0 = Montag).
  final int tag;
  final int start;
  final int ende;

  /// Nebeneinander stehende Termine: Nummer der Spur ([spalte]) und Anzahl der Spuren der Überlappungsgruppe ([spalten]).
  final int spalte;
  final int spalten;

  /// Der Termin beginnt vor diesem Tag bzw. endet nach ihm (Fortsetzung über Mitternacht).
  final bool vorneOffen;
  final bool hintenOffen;
  const WochenBlock({
    required this.v,
    required this.tag,
    required this.start,
    required this.ende,
    this.spalte = 0,
    this.spalten = 1,
    this.vorneOffen = false,
    this.hintenOffen = false,
  });

  WochenBlock mitSpur(int spalte, int spalten) =>
      WochenBlock(v: v, tag: tag, start: start, ende: ende, spalte: spalte, spalten: spalten, vorneOffen: vorneOffen, hintenOffen: hintenOffen);
}

/// Mindestdauer in Minuten, die ein Block für die Überlappungsprüfung belegt (kurze Termine bekommen im Raster eine Mindesthöhe).
const kWochenMinDauer = 30;

Duration _echteDauer(Vorkommen v) {
  final t = v.termin;
  if (v.geaendert || t.startUtc == null || t.endUtc == null) return Duration.zero;
  return t.endUtc!.difference(t.startUtc!);
}

/// Ein Zeittermin in der doppelten Stunde der Herbst-Umstellung (z. B. 02:30 MESZ bis 02:30 MEZ): die Wanduhr steht am Ende vor oder auf dem
/// Beginn, obwohl der Termin real läuft.
bool istUmstellungsSpanne(Vorkommen v) => !v.ganztaegig && !v.endeWand.isAfter(v.startWand) && _echteDauer(v) > Duration.zero;

/// Ende im Raster: bei einer Umstellungsspanne Beginn plus reale Dauer (mindestens [minDauer] Minuten), sonst das Ende der Wanduhr.
DateTime _rasterEnde(Vorkommen v, int minDauer) {
  if (v.endeWand.isAfter(v.startWand)) return v.endeWand;
  if (!istUmstellungsSpanne(v)) return v.startWand;
  final min = _echteDauer(v).inMinutes;
  return v.startWand.add(Duration(minutes: min < minDauer ? minDauer : min));
}

String _hhmm(DateTime w) => '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

/// Zeitspanne für die Beschriftung eines Blocks ("15:00–16:30"); bei einer Umstellungsspanne mit Zonenkürzeln ("02:30 MESZ–02:30 MEZ").
String zeitspanneText(Vorkommen v) => istUmstellungsSpanne(v) ? '${_hhmm(v.startWand)} MESZ–${_hhmm(v.endeWand)} MEZ' : '${_hhmm(v.startWand)}–${_hhmm(v.endeWand)}';

/// Ob ein Vorkommen ins Band über dem Zeitraster gehört: ganztägige und solche von mindestens 24 Stunden.
bool gehoertInsBand(Vorkommen v) => v.ganztaegig || v.endeWand.difference(v.startWand) >= const Duration(hours: 24);

/// Die Stücke der Zeittermine in [liste] für die Woche ab [montag], je Tag nach Überlappungen in Spuren verteilt; sortiert nach Tag und Beginn.
/// Ganztägige und Termine im Band ([gehoertInsBand]) werden ausgelassen.
List<WochenBlock> zeitBloecke(DateTime montag, Iterable<Vorkommen> liste, {int minDauer = kWochenMinDauer}) {
  final proTag = List.generate(7, (_) => <WochenBlock>[]);
  for (final v in liste) {
    if (gehoertInsBand(v)) continue;
    final ende = _rasterEnde(v, minDauer);
    for (var i = 0; i < 7; i++) {
      final tagBeginn = DateTime.utc(montag.year, montag.month, montag.day + i);
      final tagEnde = DateTime.utc(montag.year, montag.month, montag.day + i + 1);
      final beginntVorEnde = v.startWand.isBefore(tagEnde);
      final reicht = ende.isAfter(tagBeginn) || (ende == v.startWand && !v.startWand.isBefore(tagBeginn));
      if (!beginntVorEnde || !reicht) continue;
      final s = v.startWand.isBefore(tagBeginn) ? tagBeginn : v.startWand;
      final e = ende.isAfter(tagEnde) ? tagEnde : ende;
      proTag[i].add(
        WochenBlock(
          v: v,
          tag: i,
          start: s.difference(tagBeginn).inMinutes,
          ende: e.difference(tagBeginn).inMinutes,
          vorneOffen: v.startWand.isBefore(tagBeginn),
          hintenOffen: ende.isAfter(tagEnde),
        ),
      );
    }
  }
  return [for (final tag in proTag) ..._spuren(tag, minDauer)];
}

int _belegtBis(WochenBlock b, int minDauer) => b.ende - b.start < minDauer ? b.start + minDauer : b.ende;

/// Verteilt die Blöcke eines Tages auf Spuren: Gruppen zusammenhängend überlappender Blöcke teilen sich die Breite, jeder Block nimmt die erste freie Spur.
List<WochenBlock> _spuren(List<WochenBlock> bloecke, int minDauer) {
  bloecke.sort((a, b) {
    final s = a.start.compareTo(b.start);
    if (s != 0) return s;
    final e = b.ende.compareTo(a.ende); // längere zuerst
    return e != 0 ? e : a.v.termin.id.compareTo(b.v.termin.id);
  });
  final out = <WochenBlock>[];
  var gruppe = <(WochenBlock, int)>[];
  final spurEnde = <int>[];
  var gruppeEnde = 0;
  void abschliessen() {
    for (final (b, spur) in gruppe) {
      out.add(b.mitSpur(spur, spurEnde.length));
    }
    gruppe = [];
    spurEnde.clear();
  }

  for (final b in bloecke) {
    if (gruppe.isNotEmpty && b.start >= gruppeEnde) abschliessen();
    var spur = spurEnde.indexWhere((ende) => ende <= b.start);
    final bis = _belegtBis(b, minDauer);
    if (spur < 0) {
      spur = spurEnde.length;
      spurEnde.add(bis);
    } else {
      spurEnde[spur] = bis;
    }
    gruppeEnde = gruppe.isEmpty || bis > gruppeEnde ? bis : gruppeEnde;
    gruppe.add((b, spur));
  }
  abschliessen();
  return out;
}

/// Minute (seit 0:00), auf die das Raster beim Öffnen scrollt: eine Stunde vor der aktuellen Uhrzeit, wenn die Woche heute enthält
/// ([jetztMinute] gesetzt), sonst eine halbe Stunde vor dem frühesten Termin der Woche, ohne Termine [standard] (7:00).
int scrollZielMinute({required Iterable<WochenBlock> bloecke, int? jetztMinute, int standard = 7 * 60}) {
  if (jetztMinute != null) return jetztMinute - 60 < 0 ? 0 : jetztMinute - 60;
  if (bloecke.isEmpty) return standard;
  final frueh = bloecke.map((b) => b.start).reduce((a, b) => a < b ? a : b);
  return frueh - 30 < 0 ? 0 : frueh - 30;
}

/// Uhrzeit für einen Tipp auf eine leere Stelle: die Minute [minute] des Rasters, auf [raster] Minuten abgerundet, spätestens 23:30.
int gerundeteMinute(double minute, {int raster = 30}) {
  final m = (minute ~/ raster) * raster;
  return m < 0 ? 0 : (m > 24 * 60 - 30 ? 24 * 60 - 30 : m);
}
