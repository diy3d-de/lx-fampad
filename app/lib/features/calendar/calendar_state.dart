// Zustand der Kalender-Ansicht: Ansicht (Agenda, Monat, Woche), gewählter Tag, Personenfilter; dazu die Hilfen zum Filtern und Beschriften.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/feiertage.dart' show feiertageSpeicherProvider, kKalenderAnsichtSchluessel;
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/termin_farben.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/lists/members.dart';

enum KalenderAnsicht {
  agenda('Agenda'),
  monat('Monat'),
  woche('Woche');

  final String label;
  const KalenderAnsicht(this.label);

  /// Gemerkter Wert ("agenda", "monat", "woche"); fehlt er oder ist er unbekannt: Monat (Standardansicht).
  static KalenderAnsicht ausText(String? text) => KalenderAnsicht.values.where((a) => a.name == text).firstOrNull ?? KalenderAnsicht.monat;
}

class KalenderAuswahl {
  final KalenderAnsicht ansicht;

  /// Gewählter Kalendertag (Markierung UTC, Wanduhr der Familienzone).
  final DateTime tag;

  /// Angezeigter Monat (erster Tag): getrennt vom gewählten Tag, damit ein Tipp auf einen Tag des Vor- oder Folgemonats den Monat nicht wechselt.
  final DateTime monat;

  /// Nur Termine dieser Personen (Ersteller oder Teilnehmer); leer = alle.
  final Set<String> personen;

  /// Wie viele Tage die Agenda ab heute zeigt.
  final int agendaTage;

  /// Ist die gemerkte Ansicht schon gelesen? Bis dahin zeichnet der Kalender noch nichts, damit er nicht von Monat auf die gemerkte Ansicht springt.
  final bool geladen;
  KalenderAuswahl({required this.ansicht, required this.tag, DateTime? monat, this.personen = const {}, this.agendaTage = kAgendaTage, this.geladen = true}) : monat = monat ?? DateTime.utc(tag.year, tag.month);

  KalenderAuswahl kopie({KalenderAnsicht? ansicht, DateTime? tag, DateTime? monat, Set<String>? personen, int? agendaTage, bool? geladen}) => KalenderAuswahl(
    ansicht: ansicht ?? this.ansicht,
    tag: tag ?? this.tag,
    monat: monat ?? this.monat,
    personen: personen ?? this.personen,
    agendaTage: agendaTage ?? this.agendaTage,
    geladen: geladen ?? this.geladen,
  );
}

const kAgendaTage = 60;

/// Heute (Kalendertag in der Familienzone).
DateTime heuteTag([DateTime? jetzt]) {
  final w = wandUhr(jetzt ?? DateTime.now().toUtc(), familienOrt);
  return DateTime.utc(w.year, w.month, w.day);
}

/// Uhr des Wochenrasters (Wanduhr der Familienzone als UTC): Linie der aktuellen Uhrzeit und "heute"; Tests setzen eine feste Uhr.
final kalenderJetztProvider = Provider<DateTime Function()>((ref) => () => wandUhr(DateTime.now().toUtc(), familienOrt));

class KalenderAuswahlNotifier extends Notifier<KalenderAuswahl> {
  bool _gesetzt = false;

  @override
  KalenderAuswahl build() {
    _gesetzt = false;
    _laden();
    return KalenderAuswahl(ansicht: KalenderAnsicht.monat, tag: heuteTag(), geladen: false);
  }

  /// Liest die gemerkte Ansicht (lokal je Gerät in `sync_meta`); Fehler oder unbekannter Wert: Monat. Eine inzwischen gesetzte Ansicht gewinnt.
  Future<void> _laden() async {
    var a = KalenderAnsicht.monat;
    try {
      a = KalenderAnsicht.ausText(await ref.read(feiertageSpeicherProvider).lesen(schluessel: kKalenderAnsichtSchluessel));
    } catch (_) {
      // nicht lesbar: Monat
    }
    if (!ref.mounted) return;
    state = state.kopie(ansicht: _gesetzt ? null : a, geladen: true);
  }

  /// Setzt die Ansicht, ohne sie zu merken (Sprung aus Benachrichtigung oder Widget).
  void ansicht(KalenderAnsicht a) {
    _gesetzt = true;
    state = state.kopie(ansicht: a);
  }

  /// Wechsel durch die Person: gilt sofort und wird für den nächsten Start gemerkt (schlägt das Schreiben fehl, gilt sie bis zum Schließen der App).
  Future<void> ansichtMerken(KalenderAnsicht a) async {
    ansicht(a);
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(a.name, schluessel: kKalenderAnsichtSchluessel);
    } catch (_) {
      // nur bis zum Schließen der App
    }
  }

  /// Springt zu einem Tag und zeigt dessen Monat.
  void tag(DateTime t) => state = state.kopie(tag: DateTime.utc(t.year, t.month, t.day), monat: DateTime.utc(t.year, t.month));

  /// Wählt einen Tag, ohne den angezeigten Monat zu wechseln (Tipp auf einen Tag im Raster).
  void waehleTag(DateTime t) => state = state.kopie(tag: DateTime.utc(t.year, t.month, t.day));
  void mehrTage() => state = state.kopie(agendaTage: state.agendaTage + kAgendaTage);

  void person(String id) {
    final p = {...state.personen};
    if (!p.remove(id)) p.add(id);
    state = state.kopie(personen: p);
  }

  void alle() => state = state.kopie(personen: const {});
}

final kalenderAuswahlProvider = NotifierProvider<KalenderAuswahlNotifier, KalenderAuswahl>(KalenderAuswahlNotifier.new);

/// Die gemeinsame Kopfzeile (`TabKopfzeile`) ist im Kalender eingeklappt, sobald im Raster gescrollt oder getippt wird, und kommt beim
/// Zurückscrollen an den Anfang oder beim Herunterziehen des Rasters wieder (Ausnahme der Design-Regel "Kopfzeile aller Tabs identisch").
class KalenderKopfNotifier extends Notifier<bool> {
  Duration _zuletzt = const Duration(days: -1);

  @override
  bool build() => false;

  /// Kurz nach einem Wechsel (Animation der Kopfzeile, die den sichtbaren Bereich ändert) kommen keine Wechsel durch Scrollen zustande.
  bool get beruhigt => SchedulerBinding.instance.currentSystemFrameTimeStamp - _zuletzt > const Duration(milliseconds: 250);

  void setzen(bool eingeklappt) {
    if (state == eingeklappt) return;
    _zuletzt = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    state = eingeklappt;
  }
}

final kalenderKopfEingeklapptProvider = NotifierProvider<KalenderKopfNotifier, bool>(KalenderKopfNotifier.new);

/// Passt das Vorkommen zum Personenfilter (Ersteller oder Teilnehmer)?
bool passtZumFilter(Vorkommen v, Set<String> personen, KalenderDaten daten) {
  if (personen.isEmpty) return true;
  final t = v.termin;
  if (t.ownerId != null && personen.contains(t.ownerId)) return true;
  return daten.teilnehmerIds(t.id).any(personen.contains);
}

/// Farbe eines Termins: Geburtstage immer `kGeburtstag`, sonst die Termin-Farbe (`farbe`, Serie und Ausnahmen gemeinsam),
/// ohne sie die Personenfarbe des Erstellers (unbekannt: Akzent).
Color terminFarbe(Vorkommen v, Mitglieder mitglieder) {
  if (istGeburtstag(v.termin)) return kGeburtstag;
  final u = mitglieder[v.termin.ownerId];
  return terminFarbeOderRueckfall(v.termin.farbe, u == null ? kAccent : personColor(u.colorIndex));
}

/// Schlüssel in `sync_meta`: kommagetrennte Nummern der im Kalender ausgeblendeten Termin-Farben (leer oder fehlt = alle an; lokal je Gerät).
const kFarbenAusSchluessel = 'kalender_farben_aus';

/// Ausgeblendete Termin-Farben (reine Anzeige, verändert nie Termine; Termine ohne Farbe, Geburtstage, Feiertage und Ferien bleiben immer sichtbar).
class FarbenAusNotifier extends Notifier<Set<int>> {
  bool _gesetzt = false;

  @override
  Set<int> build() {
    _gesetzt = false;
    _laden();
    return const {};
  }

  Future<void> _laden() async {
    try {
      final w = await ref.read(feiertageSpeicherProvider).lesen(schluessel: kFarbenAusSchluessel);
      if (ref.mounted && !_gesetzt) state = farbFilterAusText(w);
    } catch (_) {
      // nicht lesbar: alle an
    }
  }

  Future<void> _setzen(Set<int> aus) async {
    _gesetzt = true;
    state = aus;
    try {
      // leerer Text = alle an (kein Löschen: ein Eintrag mit "loeschen" im Kalender-Code stört den Wächter der Schlüssel-Löschstellen)
      await ref.read(feiertageSpeicherProvider).schreiben(farbFilterAlsText(aus), schluessel: kFarbenAusSchluessel);
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  /// Schaltet eine Farbe an oder aus.
  Future<void> umschalten(int farbe) {
    final aus = {...state};
    if (!aus.remove(farbe)) aus.add(farbe);
    return _setzen(aus);
  }

  Future<void> alleAn() => _setzen(const {});
  Future<void> alleAus() => _setzen({for (var i = 0; i < kTerminFarbenAnzahl; i++) i});
}

final farbenAusProvider = NotifierProvider<FarbenAusNotifier, Set<int>>(FarbenAusNotifier.new);

String _hhmm(DateTime w) => '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

/// Zeitangabe eines Vorkommens an einem bestimmten [tag]: "ganztägig", "10:00–11:00", "ab 22:00", "bis 08:00" bei Mehrtägigen.
String zeitText(Vorkommen v, [DateTime? tag]) {
  if (v.ganztaegig) return 'ganztägig';
  final t = tag ?? v.ersterTag;
  final beginntHeute = !v.ersterTag.isAfter(t) && v.ersterTag == t;
  final endetHeute = v.letzterTag == t;
  if (beginntHeute && endetHeute) return v.endeWand == v.startWand ? _hhmm(v.startWand) : '${_hhmm(v.startWand)}–${_hhmm(v.endeWand)}';
  if (beginntHeute) return 'ab ${_hhmm(v.startWand)}';
  if (endetHeute) return 'bis ${_hhmm(v.endeWand)}';
  return 'ganztägig';
}

/// Zeit in der Tagesliste (Tagesblatt, Tagespanel): Beginn als Uhrzeit, sonst wie [zeitText] ("ganztägig", "bis 08:00").
String startZeitText(Vorkommen v, DateTime tag) {
  if (v.ganztaegig) return 'ganztägig';
  return v.ersterTag == tag ? _hhmm(v.startWand) : zeitText(v, tag);
}

/// Uhrzeit "HH:mm" einer Wanduhr-Zeit (für Balkenbeschriftungen).
String uhrzeitText(DateTime wand) => _hhmm(wand);

/// Datum und Zeit eines Vorkommens für Detailansichten ("Di, 20. Okt 2026, 10:00–11:00").
String datumZeitText(Vorkommen v) {
  final tag = DateFormat('EEEE, d. MMMM y', 'de_DE');
  final kurz = DateFormat('E, d. MMM', 'de_DE');
  if (v.ganztaegig) {
    if (v.letzterTag == v.ersterTag) return tag.format(v.ersterTag);
    return '${kurz.format(v.ersterTag)} – ${kurz.format(v.letzterTag)} · ganztägig';
  }
  if (v.letzterTag == v.ersterTag) return '${tag.format(v.startWand)}, ${zeitText(v)}';
  return '${kurz.format(v.startWand)}, ${_hhmm(v.startWand)} – ${kurz.format(v.endeWand)}, ${_hhmm(v.endeWand)}';
}

/// Kopf eines Tages in der Agenda ("// mo, 20. okt").
String tagesLabel(DateTime tag) => DateFormat('E, d. MMM', 'de_DE').format(tag);

String erinnerungText(int? min) => switch (min) {
  null => 'Keine Erinnerung',
  0 => 'Zur Startzeit',
  < 60 => '$min Minuten vorher',
  60 => '1 Stunde vorher',
  < 1440 => '${min ~/ 60} Stunden vorher',
  1440 => '1 Tag vorher',
  10080 => '1 Woche vorher',
  _ => '${min ~/ 1440} Tage vorher',
};

const kErinnerungen = <int?>[null, 0, 5, 15, 30, 60, 1440, 10080];


/// Vorkommen im Fenster [von] bis [bis] (Wanduhr, bis exklusiv) nach Personen- und Farbfilter; ohne Geburtstage, wenn deren Anzeige ausgeschaltet ist.
List<Vorkommen> gefilterteVorkommen(KalenderAuswahl a, KalenderDaten daten, DateTime von, DateTime bis, {bool geburtstage = true, Set<int> farbenAus = const {}}) => [
  for (final v in vorkommenImFenster(termine: daten.termine, ausnahmen: daten.ausnahmen, vonWand: von, bisWand: bis))
    if (passtZumFilter(v, a.personen, daten) && (geburtstage || !istGeburtstag(v.termin)) && (istGeburtstag(v.termin) || passtZumFarbFilter(v.termin.farbe, farbenAus))) v,
];
