// Medikamenten-Plan (Abschnitt 6k): reine Logik ohne Datenbank und ohne Netz. Slots (geplante Einnahmen) je Tag aus Rhythmus und Uhrzeiten, Status eines Slots (offen, genommen,
// übersprungen, verpasst), die nächste Einnahme und der Vorrat ("reicht noch N Tage").
//
// Zeit: Die Uhrzeiten sind Wanduhr der Familienzeitzone (Europe/Berlin, wie der Kalender). Ein Slot heißt `YYYY-MM-DDTHH:MM` (Wanduhr) und bleibt über die Sommerzeit stabil; sein Zeitpunkt
// (UTC) wird erst beim Vergleich mit "jetzt" berechnet (`instantAusWand`: eine ausgefallene Uhrzeit beim Vorstellen der Uhr rutscht auf die Zeit danach, bei der doppelten Stunde
// gilt die erste). Tage zählen als Kalendertage, nie als 24-Stunden-Blöcke: "alle 2 Tage" bleibt über eine 23- oder 25-Stunden-Nacht richtig.
import 'package:timezone/timezone.dart' as tz;

import '../calendar/zeitzonen.dart';
import 'medikament_modelle.dart';

/// Ab wann ein offener Slot als verpasst gilt (nach seiner Uhrzeit), wenn nichts anderes angegeben ist.
const Duration kVerpasstNach = Duration(hours: 2);

/// Wie weit die Vorratsrechnung vorausschaut (Tage); länger reichen heißt "reicht lange".
const int kVorratHorizontTage = 730;

/// Ein geplanter Einnahmezeitpunkt eines Tages (Wanduhr der Familienzeitzone).
class Slot {
  /// `YYYY-MM-DD` und `HH:MM`.
  final String tag;
  final String zeit;
  const Slot(this.tag, this.zeit);

  /// `YYYY-MM-DDTHH:MM`: so steht der Slot in der Einnahme (`EinnahmeInhalt.geplant`).
  String get schluessel => '${tag}T$zeit';

  /// Der Zeitpunkt (UTC), zu dem der Slot fällig ist.
  DateTime instant([tz.Location? ort]) {
    final t = tagLesen(tag)!;
    final min = zeitMinuten(zeit)!;
    final z = instantAusWand(DateTime.utc(t.year, t.month, t.day, min ~/ 60, min % 60), ort ?? familienOrt);
    // ein einfaches UTC-DateTime (kein TZDateTime): vergleichbar und gleich mit jedem anderen Zeitpunkt desselben Moments
    return DateTime.fromMillisecondsSinceEpoch(z.millisecondsSinceEpoch, isUtc: true);
  }

  @override
  bool operator ==(Object other) => other is Slot && other.schluessel == schluessel;

  @override
  int get hashCode => schluessel.hashCode;

  @override
  String toString() => schluessel;
}

enum SlotStatus { offen, genommen, uebersprungen, verpasst }

/// Ein Slot mit seinem Stand; [einnahme] ist der zugehörige Protokolleintrag (bei offen/verpasst null).
class TagesSlot {
  final Slot slot;
  final SlotStatus status;
  final EinnahmeAnsicht? einnahme;
  const TagesSlot(this.slot, this.status, this.einnahme);
}

/// Kalendertag (UTC-Mitternacht) des Zeitpunkts in der Familienzeitzone.
DateTime familienTag(DateTime instant, [tz.Location? ort]) {
  final w = wandUhr(instant, ort ?? familienOrt);
  return DateTime.utc(w.year, w.month, w.day);
}

DateTime _tag(DateTime t) => DateTime.utc(t.year, t.month, t.day);

/// Gilt für das Medikament an diesem Kalendertag ein Plan (Beginn/Ende, Pause, beendet, Rhythmus)? "Bei Bedarf" hat nie feste Tage.
bool tagAktiv(MedikamentInhalt m, DateTime tag) {
  final d = _tag(tag);
  final t = tagText(d);
  if (m.beginn != null && t.compareTo(m.beginn!) < 0) return false;
  if (m.ende != null && t.compareTo(m.ende!) > 0) return false;
  switch (m.zustand) {
    case MedikamentZustand.beendet:
      if (m.zustandAb == null || t.compareTo(m.zustandAb!) >= 0) return false;
    case MedikamentZustand.pausiert:
      if ((m.zustandAb == null || t.compareTo(m.zustandAb!) >= 0) && (m.pauseBis == null || t.compareTo(m.pauseBis!) <= 0)) return false;
    case MedikamentZustand.aktiv:
      break;
  }
  switch (m.rhythmus.art) {
    case RhythmusArt.bedarf:
      return false;
    case RhythmusArt.taeglich:
      return true;
    case RhythmusArt.wochentage:
      return m.rhythmus.wochentage.contains(d.weekday);
    case RhythmusArt.intervall:
      final anker = tagLesen(m.rhythmus.ab);
      if (anker == null) return false;
      final delta = d.difference(anker).inDays;
      return delta >= 0 && delta % m.rhythmus.alleNTage == 0;
  }
}

/// Die Slots des Medikaments an einem Tag (aufsteigend nach Uhrzeit).
List<Slot> slotsAmTag(MedikamentInhalt m, DateTime tag) {
  if (!tagAktiv(m, tag)) return const [];
  final t = tagText(_tag(tag));
  return [for (final z in m.zeiten) Slot(t, z)];
}

/// Der Protokolleintrag zu einem Slot. Gibt es mehrere (zwei Geräte haben denselben Slot gleichzeitig erfasst), gilt "genommen" vor "übersprungen", dann der früheste.
EinnahmeAnsicht? einnahmeFuerSlot(Iterable<EinnahmeAnsicht> einnahmen, Slot slot) {
  EinnahmeAnsicht? beste;
  for (final e in einnahmen) {
    final i = e.inhalt;
    if (i == null || i.geplant != slot.schluessel) continue;
    if (beste == null || _besser(e, beste)) beste = e;
  }
  return beste;
}

bool _besser(EinnahmeAnsicht a, EinnahmeAnsicht b) {
  final ia = a.inhalt!;
  final ib = b.inhalt!;
  if (ia.status != ib.status) return ia.status == EinnahmeStatus.genommen;
  final c = ia.um.compareTo(ib.um);
  return c != 0 ? c < 0 : a.id.compareTo(b.id) < 0;
}

/// Der Stand eines Slots zum Zeitpunkt [jetzt]: erfasst (genommen/übersprungen), sonst verpasst, wenn [verpasstNach] nach seiner Uhrzeit vergangen ist, sonst offen.
TagesSlot slotStand(Slot slot, Iterable<EinnahmeAnsicht> einnahmen, DateTime jetzt, {Duration verpasstNach = kVerpasstNach, tz.Location? ort}) {
  final e = einnahmeFuerSlot(einnahmen, slot);
  if (e != null) return TagesSlot(slot, e.inhalt!.status == EinnahmeStatus.genommen ? SlotStatus.genommen : SlotStatus.uebersprungen, e);
  final spaetestens = slot.instant(ort).add(verpasstNach);
  return TagesSlot(slot, jetzt.toUtc().isAfter(spaetestens) ? SlotStatus.verpasst : SlotStatus.offen, null);
}

/// Der Plan eines Tages mit dem Stand jedes Slots.
/// [ab]: Slots vor diesem Zeitpunkt (Anlegen des Plans) gibt es nicht: sie sind nie offen, fällig oder verpasst.
List<TagesSlot> tagesplan(MedikamentInhalt m, Iterable<EinnahmeAnsicht> einnahmen, DateTime tag, DateTime jetzt, {Duration verpasstNach = kVerpasstNach, tz.Location? ort, DateTime? ab}) => [
  for (final s in slotsAmTag(m, tag))
    if (ab == null || !s.instant(ort).isBefore(ab.toUtc())) slotStand(s, einnahmen, jetzt, verpasstNach: verpasstNach, ort: ort),
];

/// Der nächste noch offene Slot (nicht erfasst, nicht verpasst), von gestern an gesucht (ein Slot kurz vor Mitternacht gilt noch); null, wenn es keinen gibt (bei Bedarf, beendet, ...).
TagesSlot? naechsteEinnahme(MedikamentInhalt m, Iterable<EinnahmeAnsicht> einnahmen, DateTime jetzt, {Duration verpasstNach = kVerpasstNach, tz.Location? ort, int horizontTage = 400}) {
  final heute = familienTag(jetzt, ort);
  for (var i = -1; i <= horizontTage; i++) {
    final tag = heute.add(Duration(days: i));
    for (final s in tagesplan(m, einnahmen, DateTime.utc(tag.year, tag.month, tag.day), jetzt, verpasstNach: verpasstNach, ort: ort)) {
      if (s.status == SlotStatus.offen) return s;
    }
  }
  return null;
}

/// Alle verpassten Slots in einem Zeitraum (Tage, beide inklusive), älteste zuerst. Der Zeitraum ist auf die Aufbewahrung des Protokolls begrenzt.
List<TagesSlot> verpassteSlots(MedikamentInhalt m, Iterable<EinnahmeAnsicht> einnahmen, DateTime von, DateTime bis, DateTime jetzt, {Duration verpasstNach = kVerpasstNach, tz.Location? ort}) {
  final out = <TagesSlot>[];
  var tag = _tag(von);
  final ende = _tag(bis);
  for (var n = 0; !tag.isAfter(ende) && n <= kEinnahmenAufbewahrungTage + 1; n++) {
    for (final s in tagesplan(m, einnahmen, tag, jetzt, verpasstNach: verpasstNach, ort: ort)) {
      if (s.status == SlotStatus.verpasst) out.add(s);
    }
    tag = DateTime.utc(tag.year, tag.month, tag.day + 1);
  }
  return out;
}

// ---------------------------------------------------------------- Vorrat

/// Durchschnittlicher Verbrauch je Tag (Stück) laut Plan; 0 bei "nur bei Bedarf".
double verbrauchProTag(MedikamentInhalt m) {
  final je = m.zeiten.length * m.menge;
  return switch (m.rhythmus.art) {
    RhythmusArt.bedarf => 0,
    RhythmusArt.taeglich => je,
    RhythmusArt.wochentage => je * m.rhythmus.wochentage.length / 7,
    RhythmusArt.intervall => je / m.rhythmus.alleNTage,
  };
}

/// Der aktuelle Bestand: der erfasste [MedikamentInhalt.bestand] zum Stichtag abzüglich der danach genommenen Mengen (nie unter 0); null ohne erfassten Bestand. Eine Einnahme zählt
/// je Slot nur einmal (zwei Geräte), Einnahmen außer der Reihe jede für sich; übersprungene zählen nicht. Hinweis: Der Server hebt Einträge nach 120 Tagen auf, ein älterer Stichtag
/// ergibt deshalb einen zu hohen Bestand: dann den Bestand neu erfassen.
double? bestandJetzt(MedikamentInhalt m, Iterable<EinnahmeAnsicht> einnahmen) {
  final start = m.bestand;
  final stand = m.bestandStand;
  if (start == null || stand == null) return null;
  final gezaehlt = <String>{};
  var verbraucht = 0.0;
  // je Slot den gültigen Eintrag (genommen vor übersprungen, der früheste); Einträge ohne Slot einzeln
  final nachSlot = <String, EinnahmeAnsicht>{};
  final ohneSlot = <EinnahmeAnsicht>[];
  for (final e in einnahmen) {
    final i = e.inhalt;
    if (i == null) continue;
    if (i.geplant == null) {
      ohneSlot.add(e);
    } else {
      final alt = nachSlot[i.geplant!];
      if (alt == null || _besser(e, alt)) nachSlot[i.geplant!] = e;
    }
  }
  for (final e in [...nachSlot.values, ...ohneSlot]) {
    final i = e.inhalt!;
    if (i.status != EinnahmeStatus.genommen || !i.um.isAfter(stand) || !gezaehlt.add(e.id)) continue;
    verbraucht += i.menge ?? m.menge;
  }
  final rest = start - verbraucht;
  return rest < 0 ? 0 : rest;
}

/// Vorhersage des Vorrats.
class VorratPrognose {
  /// Aktueller Bestand (null: nicht erfasst).
  final double? bestand;

  /// Ganze Tage ab heute, die der Bestand noch deckt (0: reicht nicht mehr für den nächsten offenen Slot); null, wenn unbekannt oder unbegrenzt.
  final int? tage;

  /// Der erste Tag (`YYYY-MM-DD`), an dem eine Einnahme nicht mehr gedeckt ist; null, wenn unbekannt oder unbegrenzt.
  final String? leerAm;

  /// Der Plan verbraucht nichts (nur bei Bedarf, beendet, pausiert ohne Ende, Ende vor heute) bzw. reicht über den Horizont hinaus.
  final bool keinVerbrauch;
  final bool reichtLange;
  const VorratPrognose({this.bestand, this.tage, this.leerAm, this.keinVerbrauch = false, this.reichtLange = false});
}

/// "Reicht noch N Tage": der Plan wird Slot für Slot ab jetzt durchgerechnet (Rhythmus, Pause, Ende des Plans). Heutige Slots zählen, wenn sie noch offen sind (nicht erfasst, nicht
/// verpasst); spätere Tage voll. So stimmt die Zahl auch bei Wochentagen und Intervallen, nicht nur im Durchschnitt.
VorratPrognose vorratPrognose(MedikamentInhalt m, Iterable<EinnahmeAnsicht> einnahmen, DateTime jetzt, {Duration verpasstNach = kVerpasstNach, tz.Location? ort, int horizontTage = kVorratHorizontTage, DateTime? ab}) {
  final bestand = bestandJetzt(m, einnahmen);
  if (bestand == null) return const VorratPrognose();
  var rest = bestand;
  final heute = familienTag(jetzt, ort);
  var verbrauchtIrgendwas = false;
  for (var i = 0; i <= horizontTage; i++) {
    final tag = DateTime.utc(heute.year, heute.month, heute.day + i);
    for (final s in tagesplan(m, einnahmen, tag, jetzt, verpasstNach: verpasstNach, ort: ort, ab: ab)) {
      if (i == 0 && s.status != SlotStatus.offen) continue; // heute: erfasste und verpasste Slots verbrauchen nichts mehr
      verbrauchtIrgendwas = true;
      if (rest + 1e-9 < m.menge) return VorratPrognose(bestand: bestand, tage: i, leerAm: tagText(tag));
      rest -= m.menge;
    }
  }
  return VorratPrognose(bestand: bestand, keinVerbrauch: !verbrauchtIrgendwas, reichtLange: verbrauchtIrgendwas);
}

/// Neuer Inhalt nach dem Auffüllen des Vorrats: der aktuelle Bestand plus [packungen] Packungen (oder [stueck]), Stichtag jetzt. Ohne bekannte Packungsgröße geht nur [stueck].
MedikamentInhalt vorratAuffuellen(MedikamentInhalt m, Iterable<EinnahmeAnsicht> einnahmen, DateTime jetzt, {int packungen = 0, double stueck = 0}) {
  final je = m.packung;
  if (packungen > 0 && je == null) throw ArgumentError('Packungsgröße unbekannt');
  final neu = (bestandJetzt(m, einnahmen) ?? 0) + packungen * (je ?? 0) + stueck;
  return m.kopie(bestand: () => neu, bestandStand: () => jetzt.toUtc());
}
