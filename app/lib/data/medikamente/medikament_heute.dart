// Medikamenten-Plan (Abschnitt 6k): reine Logik der Ansicht "Heute", der Warnungen (Vorrat, Rezept) und der Zähler für Badge und Startseite. Keine Datenbank, kein Netz, keine Oberfläche.
// Alles wird aus den (schon entschlüsselten) Plänen und Einnahmen berechnet, nie gespeichert.
import 'medikament_logik.dart';
import 'medikament_modelle.dart';
import 'medikament_state.dart' show MedEintrag;

/// Ab so vielen Tagen Restvorrat warnt die App ("reicht noch N Tage"). Fest, nicht einstellbar (das Klartext-Format kennt keine eigene Schwelle).
const int kVorratWarnTage = 7;

/// So viele Tage vor dem Ablauf des Rezepts warnt die App.
const int kRezeptWarnTage = 14;

/// So viele Tage zeigt die Detailseite im Verlauf.
const int kVerlaufTage = 7;

enum Tageszeit {
  morgens('Morgens'),
  mittags('Mittags'),
  nachmittags('Nachmittags'),
  abends('Abends'),
  nachts('Nachts');

  final String label;
  const Tageszeit(this.label);
}

/// Tageszeit einer Uhrzeit `HH:MM` (Wanduhr): 04:00-10:59 morgens, 11:00-14:59 mittags, 15:00-17:59 nachmittags, 18:00-21:59 abends, sonst nachts.
Tageszeit tageszeitVon(String zeit) {
  final m = zeitMinuten(zeit) ?? 0;
  if (m >= 4 * 60 && m < 11 * 60) return Tageszeit.morgens;
  if (m >= 11 * 60 && m < 15 * 60) return Tageszeit.mittags;
  if (m >= 15 * 60 && m < 18 * 60) return Tageszeit.nachmittags;
  if (m >= 18 * 60 && m < 22 * 60) return Tageszeit.abends;
  return Tageszeit.nachts;
}

/// Ein Slot eines Medikaments an diesem Tag.
class HeuteSlot {
  final MedEintrag eintrag;
  final TagesSlot slot;
  const HeuteSlot(this.eintrag, this.slot);

  String get zeit => slot.slot.zeit;
  String get subjektId => eintrag.subjektId;
  bool get erledigt => slot.status == SlotStatus.genommen || slot.status == SlotStatus.uebersprungen;

  /// Offen und die Uhrzeit ist erreicht, oder verpasst: das, was jetzt Aufmerksamkeit braucht (Badge).
  bool faellig(DateTime jetzt) => slot.status == SlotStatus.verpasst || (slot.status == SlotStatus.offen && !slot.slot.instant().isAfter(jetzt.toUtc()));
}

class TageszeitGruppe {
  final Tageszeit zeit;
  final List<HeuteSlot> slots;
  const TageszeitGruppe(this.zeit, this.slots);

  /// Früheste Uhrzeit der Gruppe (für die Überschrift "MORGENS · 08:00").
  String get ab => slots.first.zeit;
}

class HeuteAnsicht {
  final List<TageszeitGruppe> gruppen;

  /// Medikamente "bei Bedarf" (aktiv), getrennt von der Tagesliste.
  final List<MedEintrag> bedarf;
  final int erledigt;
  final int gesamt;

  /// Offene (Uhrzeit erreicht) und verpasste Slots.
  final int faellig;
  const HeuteAnsicht({this.gruppen = const [], this.bedarf = const [], this.erledigt = 0, this.gesamt = 0, this.faellig = 0});

  bool get leer => gruppen.isEmpty && bedarf.isEmpty;
}

/// Die Slots des Tages für [eintraege] (lesbare, nicht beendete Medikamente), nach Uhrzeit, dann Name sortiert.
List<HeuteSlot> heuteSlots(Iterable<MedEintrag> eintraege, DateTime jetzt) {
  final heute = familienTag(jetzt);
  final out = <HeuteSlot>[];
  for (final e in eintraege) {
    final m = e.inhalt;
    if (m == null) continue;
    for (final s in tagesplan(m, e.einnahmen, heute, jetzt)) {
      out.add(HeuteSlot(e, s));
    }
  }
  out.sort((a, b) {
    final c = a.zeit.compareTo(b.zeit);
    if (c != 0) return c;
    return (a.eintrag.inhalt!.name.toLowerCase()).compareTo(b.eintrag.inhalt!.name.toLowerCase());
  });
  return out;
}

/// Die Ansicht "Heute" für [eintraege] (der Filter nach Person wird vorher angewendet).
HeuteAnsicht heuteAnsicht(Iterable<MedEintrag> eintraege, DateTime jetzt) {
  final slots = heuteSlots(eintraege, jetzt);
  final gruppen = <TageszeitGruppe>[];
  for (final z in Tageszeit.values) {
    final s = [for (final x in slots) if (tageszeitVon(x.zeit) == z) x];
    if (s.isNotEmpty) gruppen.add(TageszeitGruppe(z, s));
  }
  final bedarf = [
    for (final e in eintraege)
      if (e.inhalt != null && e.inhalt!.rhythmus.art == RhythmusArt.bedarf && e.inhalt!.zustand == MedikamentZustand.aktiv) e,
  ]..sort((a, b) => a.inhalt!.name.toLowerCase().compareTo(b.inhalt!.name.toLowerCase()));
  return HeuteAnsicht(
    gruppen: gruppen,
    bedarf: bedarf,
    erledigt: slots.where((s) => s.erledigt).length,
    gesamt: slots.length,
    faellig: slots.where((s) => s.faellig(jetzt)).length,
  );
}

/// Noch nicht erledigte Slots heute (offen, auch zukünftige, und verpasste).
int nichtErledigtHeute(Iterable<MedEintrag> eintraege, DateTime jetzt) => heuteSlots(eintraege, jetzt).where((s) => !s.erledigt).length;

/// Der nächste offene Slot heute (Startseite): nicht erledigt, früheste Uhrzeit.
HeuteSlot? naechsterOffenerSlot(Iterable<MedEintrag> eintraege, DateTime jetzt) {
  for (final s in heuteSlots(eintraege, jetzt)) {
    if (!s.erledigt) return s;
  }
  return null;
}

enum WarnArt { vorrat, rezept }

class MedWarnung {
  final MedEintrag eintrag;
  final WarnArt art;

  /// Vorrat: Tage, die er noch reicht (0 = reicht nicht mehr für die nächste Einnahme). Rezept: Tage bis zum Ablauf (negativ: abgelaufen).
  final int tage;
  const MedWarnung(this.eintrag, this.art, this.tage);
}

int _tageBis(String tag, DateTime jetzt) {
  final z = tagLesen(tag);
  if (z == null) return 1 << 30;
  return z.difference(familienTag(jetzt)).inDays;
}

/// Restvorrat in Tagen, wenn die App warnen soll (aktiver Plan mit erfasstem Bestand und höchstens [kVorratWarnTage] Tagen), sonst null.
int? vorratWarnTage(MedEintrag e, DateTime jetzt) {
  final m = e.inhalt;
  if (m == null || m.zustand != MedikamentZustand.aktiv || m.bestand == null) return null;
  final p = vorratPrognose(m, e.einnahmen, jetzt);
  final t = p.tage;
  if (t == null || t > kVorratWarnTage) return null;
  return t;
}

/// Tage bis zum Ablauf des Rezepts, wenn die App warnen soll (höchstens [kRezeptWarnTage], auch abgelaufen), sonst null.
int? rezeptWarnTage(MedEintrag e, DateTime jetzt) {
  final m = e.inhalt;
  if (m == null || m.zustand == MedikamentZustand.beendet || m.rezeptDatum == null) return null;
  final t = _tageBis(m.rezeptDatum!, jetzt);
  return t <= kRezeptWarnTage ? t : null;
}

/// Alle Warnungen (Vorrat zuerst, nach Dringlichkeit).
List<MedWarnung> warnungen(Iterable<MedEintrag> eintraege, DateTime jetzt) {
  final out = <MedWarnung>[];
  for (final e in eintraege) {
    final v = vorratWarnTage(e, jetzt);
    if (v != null) out.add(MedWarnung(e, WarnArt.vorrat, v));
    final r = rezeptWarnTage(e, jetzt);
    if (r != null) out.add(MedWarnung(e, WarnArt.rezept, r));
  }
  out.sort((a, b) {
    if (a.art != b.art) return a.art == WarnArt.vorrat ? -1 : 1;
    return a.tage.compareTo(b.tage);
  });
  return out;
}

/// "reicht noch 6 Tage" (Vorrat) bzw. "reicht nicht mehr für die nächste Einnahme".
String vorratText(int tage) => tage <= 0 ? 'reicht nicht mehr für die nächste Einnahme' : (tage == 1 ? 'reicht noch 1 Tag' : 'reicht noch $tage Tage');

/// "läuft in 10 Tagen ab", "läuft heute ab", "ist abgelaufen".
String rezeptText(int tage) => tage < 0 ? 'ist abgelaufen' : (tage == 0 ? 'läuft heute ab' : (tage == 1 ? 'läuft morgen ab' : 'läuft in $tage Tagen ab'));

/// Ein Tag des Verlaufs der letzten Tage.
enum VerlaufStand { genommen, verpasst, offen, keinPlan }

class VerlaufTag {
  final DateTime tag;

  /// `genommen`: alle Slots des Tages erfasst; `verpasst`: mindestens einer verpasst; `offen`: Rest des heutigen Tages; `keinPlan`: an dem Tag war nichts geplant.
  final VerlaufStand stand;
  const VerlaufTag(this.tag, this.stand);
}

/// Die letzten [tage] Tage bis heute (älteste zuerst) für ein Medikament.
List<VerlaufTag> verlauf(MedEintrag e, DateTime jetzt, {int tage = kVerlaufTage}) {
  final m = e.inhalt;
  final heute = familienTag(jetzt);
  final out = <VerlaufTag>[];
  for (var i = tage - 1; i >= 0; i--) {
    final tag = DateTime.utc(heute.year, heute.month, heute.day - i);
    final plan = m == null ? const <TagesSlot>[] : tagesplan(m, e.einnahmen, tag, jetzt);
    final VerlaufStand s;
    if (plan.isEmpty) {
      s = VerlaufStand.keinPlan;
    } else if (plan.any((x) => x.status == SlotStatus.verpasst)) {
      s = VerlaufStand.verpasst;
    } else if (plan.any((x) => x.status == SlotStatus.offen)) {
      s = VerlaufStand.offen;
    } else {
      s = VerlaufStand.genommen;
    }
    out.add(VerlaufTag(tag, s));
  }
  return out;
}

/// "6 von 7 Tagen genommen." (nur Tage mit Plan zählen); null ohne geplante Tage.
String? verlaufText(List<VerlaufTag> v) {
  final geplant = v.where((x) => x.stand != VerlaufStand.keinPlan && x.stand != VerlaufStand.offen).toList();
  if (geplant.isEmpty) return null;
  final gut = geplant.where((x) => x.stand == VerlaufStand.genommen).length;
  return '$gut von ${geplant.length} ${geplant.length == 1 ? 'Tag' : 'Tagen'} genommen.';
}
