// Zustand der Kalender-Ansicht: Ansicht (Agenda, Monat, Woche), gewählter Tag, Personenfilter; dazu die Hilfen zum Filtern und Beschriften.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/geburtstag.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/lists/members.dart';

enum KalenderAnsicht {
  agenda('Agenda'),
  monat('Monat'),
  woche('Woche');

  final String label;
  const KalenderAnsicht(this.label);
}

class KalenderAuswahl {
  final KalenderAnsicht ansicht;

  /// Gewählter Kalendertag (Markierung UTC, Wanduhr der Familienzone).
  final DateTime tag;

  /// Nur Termine dieser Personen (Ersteller oder Teilnehmer); leer = alle.
  final Set<String> personen;

  /// Wie viele Tage die Agenda ab heute zeigt.
  final int agendaTage;
  const KalenderAuswahl({required this.ansicht, required this.tag, this.personen = const {}, this.agendaTage = kAgendaTage});

  KalenderAuswahl kopie({KalenderAnsicht? ansicht, DateTime? tag, Set<String>? personen, int? agendaTage}) => KalenderAuswahl(
    ansicht: ansicht ?? this.ansicht,
    tag: tag ?? this.tag,
    personen: personen ?? this.personen,
    agendaTage: agendaTage ?? this.agendaTage,
  );
}

const kAgendaTage = 60;

/// Heute (Kalendertag in der Familienzone).
DateTime heuteTag([DateTime? jetzt]) {
  final w = wandUhr(jetzt ?? DateTime.now().toUtc(), familienOrt);
  return DateTime.utc(w.year, w.month, w.day);
}

class KalenderAuswahlNotifier extends Notifier<KalenderAuswahl> {
  @override
  KalenderAuswahl build() => KalenderAuswahl(ansicht: KalenderAnsicht.agenda, tag: heuteTag());

  void ansicht(KalenderAnsicht a) => state = state.kopie(ansicht: a);
  void tag(DateTime t) => state = state.kopie(tag: DateTime.utc(t.year, t.month, t.day));
  void mehrTage() => state = state.kopie(agendaTage: state.agendaTage + kAgendaTage);

  void person(String id) {
    final p = {...state.personen};
    if (!p.remove(id)) p.add(id);
    state = state.kopie(personen: p);
  }

  void alle() => state = state.kopie(personen: const {});
}

final kalenderAuswahlProvider = NotifierProvider<KalenderAuswahlNotifier, KalenderAuswahl>(KalenderAuswahlNotifier.new);

/// Passt das Vorkommen zum Personenfilter (Ersteller oder Teilnehmer)?
bool passtZumFilter(Vorkommen v, Set<String> personen, KalenderDaten daten) {
  if (personen.isEmpty) return true;
  final t = v.termin;
  if (t.ownerId != null && personen.contains(t.ownerId)) return true;
  return daten.teilnehmerIds(t.id).any(personen.contains);
}

/// Farbe eines Termins: Personenfarbe des Erstellers (unbekannt: Akzent).
Color terminFarbe(Vorkommen v, Mitglieder mitglieder) {
  if (istGeburtstag(v.termin)) return kGeburtstag;
  final u = mitglieder[v.termin.ownerId];
  return u == null ? kAccent : personColor(u.colorIndex);
}

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
String tagesLabel(DateTime tag) => '// ${DateFormat('E, d. MMM', 'de_DE').format(tag).toLowerCase()}';

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

