// Vorsorge und Impfungen (Abschnitt 6p): die Fälligkeit als reine Logik (keine Datenbank, keine Oberfläche, keine Zeitzone aus dem System).
//
// Gerechnet wird auf Kalendertagen (Wanduhr der Familienzone): Alle Daten sind Tage als UTC-Mitternacht, "heute" bestimmt der Aufrufer (`familienTag`). Monate und Jahre rechnen auf dem
// Kalender (Monatsende wird abgeschnitten, Schaltjahre stimmen), nie als feste Tageszahl. Es werden keine Fälligkeiten erfunden: fehlt das Geburtsdatum, ist die Vorlage nur ein Hinweis,
// und Dinge ohne klares Zeitfenster (Impfung nach Risiko) bleiben ohne Fälligkeit.
import '../medikamente/medikament_modelle.dart' show tagLesen;
import 'vorsorge_modelle.dart';
import 'vorsorge_vorlagen.dart';

/// Wie viele Tage vor Beginn eines Fensters ein Eintrag als "bald" gilt.
const int kBaldTage = 90;

/// Kalendertag (UTC-Mitternacht) aus Jahr, Monat, Tag eines beliebigen Datums.
DateTime nurTag(DateTime t) => DateTime.utc(t.year, t.month, t.day);

/// [d] plus [monate] Kalendermonate; ein nicht vorhandener Tag (31. im Folgemonat, 29. Februar) wird auf das Monatsende abgeschnitten.
DateTime monateDazu(DateTime d, int monate) {
  final gesamt = d.year * 12 + (d.month - 1) + monate;
  final y = gesamt ~/ 12;
  final m = gesamt % 12 + 1;
  final letzter = DateTime.utc(y, m + 1, 0).day;
  return DateTime.utc(y, m, d.day > letzter ? letzter : d.day);
}

/// Das Datum, an dem eine Person mit Geburtstag [geburt] das Alter [a] erreicht.
DateTime alterDatum(DateTime geburt, Alter a) => switch (a.einheit) {
  AlterEinheit.tage => geburt.add(Duration(days: a.wert)),
  AlterEinheit.wochen => geburt.add(Duration(days: a.wert * 7)),
  AlterEinheit.monate => monateDazu(geburt, a.wert),
  AlterEinheit.jahre => monateDazu(geburt, a.wert * 12),
};

/// Ganze Tage von [a] bis [b] (b später: positiv).
int tageZwischen(DateTime a, DateTime b) => nurTag(b).difference(nurTag(a)).inDays;

/// Alter in ganzen Jahren am Tag [heute] (Geburtstag zählt ab seinem Tag).
int alterInJahren(DateTime geburt, DateTime heute) {
  var j = heute.year - geburt.year;
  if (heute.month < geburt.month || (heute.month == geburt.month && heute.day < geburt.day)) j--;
  return j;
}

enum VorsorgeStatus {
  /// Das Zeitfenster ist abgelaufen und es ist nichts eingetragen.
  ueberfaellig,

  /// Das Zeitfenster hat begonnen (oder bei wiederkehrenden Terminen: der Termin ist erreicht).
  faellig,

  /// Das Zeitfenster beginnt in den nächsten [kBaldTage] Tagen.
  bald,

  /// Das Zeitfenster beginnt später; erledigt-Daten sind schon eingetragen oder es ist noch weit hin.
  spaeter,

  /// Nichts mehr zu tun (Serie abgeschlossen oder nicht mehr empfohlen).
  erledigt,

  /// Nur ein Hinweis (Impfung nach Risiko, kein klares Zeitfenster) oder nicht berechenbar (Geburtsdatum fehlt).
  keinTermin,
}

class VorsorgeFaelligkeit {
  final VorsorgeStatus status;

  /// Beginn des (nächsten) Zeitfensters; null, wenn keiner berechenbar ist.
  final DateTime? ab;

  /// Ende des Fensters (ausgeschlossen); null: nach oben offen.
  final DateTime? bis;

  /// Nummer der nächsten Dosis (1 = erste) und Gesamtzahl der Dosen einer Serie (0 bei wiederkehrenden Terminen).
  final int dosis;
  final int dosenGesamt;

  /// Warum es keine Fälligkeit gibt (nur bei [VorsorgeStatus.keinTermin] und [VorsorgeStatus.erledigt]).
  final String? grund;

  /// Gilt dieser Eintrag für die Person gar nicht (zum Beispiel anderes Geschlecht oder Alter)?
  final bool nichtRelevant;

  const VorsorgeFaelligkeit(this.status, {this.ab, this.bis, this.dosis = 0, this.dosenGesamt = 0, this.grund, this.nichtRelevant = false});

  /// Tage bis zum Beginn des Fensters (negativ: schon begonnen); null ohne Beginn.
  int? tageBisAb(DateTime heute) => ab == null ? null : tageZwischen(heute, ab!);

  /// Muss die Person etwas tun (Karte "Fällig oder überfällig")?
  bool get offen => status == VorsorgeStatus.faellig || status == VorsorgeStatus.ueberfaellig;
}

/// Die Fälligkeit eines Eintrags. [vorlage] null = eigener Eintrag. [geburt] null: das Profil fehlt (Fenster nach Alter sind dann nicht berechenbar).
VorsorgeFaelligkeit vorsorgeFaelligkeit({
  required VorsorgeVorlage? vorlage,
  required VorsorgeEintragInhalt eintrag,
  DateTime? geburt,
  VorsorgeGeschlecht? geschlecht,
  required DateTime heute,
}) {
  final tag = nurTag(heute);
  final g = geburt == null ? null : nurTag(geburt);
  final letzte = eintrag.letzte;
  final erledigtAnzahl = eintrag.erledigt.length;

  // Von Hand gesetztes nächstes Datum: hat Vorrang (solange es nach dem letzten Erledigt-Datum liegt)
  final manuell = eintrag.naechstes == null ? null : tagLesen(eintrag.naechstes);
  if (manuell != null && (letzte == null || manuell.isAfter(letzte))) return _zustand(manuell, null, tag);

  if (vorlage == null) {
    final iv = eintrag.intervallMonate;
    if (iv != null && letzte != null) return _zustand(monateDazu(letzte, iv), null, tag);
    return VorsorgeFaelligkeit(erledigtAnzahl > 0 ? VorsorgeStatus.erledigt : VorsorgeStatus.keinTermin, grund: erledigtAnzahl > 0 ? 'Kein nächster Termin eingetragen.' : 'Noch kein Termin eingetragen.');
  }

  // Passt die Vorlage zur Person?
  if (vorlage.geschlecht != null && geschlecht != null && geschlecht != vorlage.geschlecht) {
    return const VorsorgeFaelligkeit(VorsorgeStatus.keinTermin, nichtRelevant: true, grund: 'Gilt für ein anderes Geschlecht.');
  }
  if (vorlage.geborenAb != null && g != null && g.year < vorlage.geborenAb! && erledigtAnzahl == 0) {
    return VorsorgeFaelligkeit(VorsorgeStatus.keinTermin, nichtRelevant: true, grund: 'Gilt für Personen, die ${vorlage.geborenAb} oder später geboren sind.');
  }
  if (vorlage.nurHinweis) {
    return VorsorgeFaelligkeit(erledigtAnzahl > 0 ? VorsorgeStatus.erledigt : VorsorgeStatus.keinTermin, grund: 'Nur ein Hinweis: kein festes Zeitfenster.');
  }

  if (vorlage.wiederkehrend) {
    final iv = vorlage.intervallMonate!;
    DateTime ab;
    if (letzte != null) {
      ab = monateDazu(letzte, iv);
    } else {
      if (g == null || vorlage.zielAb == null) return const VorsorgeFaelligkeit(VorsorgeStatus.keinTermin, grund: 'Trag das Geburtsdatum ein, dann rechnet die App das Zeitfenster aus.');
      ab = alterDatum(g, vorlage.zielAb!);
    }
    if (g != null && vorlage.zielBis != null && !ab.isBefore(alterDatum(g, vorlage.zielBis!))) {
      return VorsorgeFaelligkeit(letzte != null ? VorsorgeStatus.erledigt : VorsorgeStatus.keinTermin, nichtRelevant: letzte == null, grund: 'Nicht mehr empfohlen.');
    }
    return _zustand(ab, null, tag);
  }

  // Serie oder einzelne Untersuchung
  final dosen = vorlage.dosen;
  if (dosen.isEmpty) return const VorsorgeFaelligkeit(VorsorgeStatus.keinTermin, grund: 'Kein Zeitfenster hinterlegt.');
  if (erledigtAnzahl >= dosen.length) return VorsorgeFaelligkeit(VorsorgeStatus.erledigt, dosis: dosen.length, dosenGesamt: dosen.length);
  final d = dosen[erledigtAnzahl];
  DateTime? ab;
  DateTime? bis;
  if (d.ab != null || d.bis != null) {
    if (g == null) return VorsorgeFaelligkeit(VorsorgeStatus.keinTermin, dosis: erledigtAnzahl + 1, dosenGesamt: dosen.length, grund: 'Trag das Geburtsdatum ein, dann rechnet die App das Zeitfenster aus.');
    if (d.ab != null) ab = alterDatum(g, d.ab!);
    if (d.bis != null) bis = alterDatum(g, d.bis!);
  }
  if (d.nachVorigerMonate != null && letzte != null) {
    final rel = monateDazu(letzte, d.nachVorigerMonate!);
    ab = ab == null || rel.isAfter(ab) ? rel : ab;
  }
  if (ab == null) return VorsorgeFaelligkeit(VorsorgeStatus.keinTermin, dosis: erledigtAnzahl + 1, dosenGesamt: dosen.length, grund: 'Kein Zeitfenster berechenbar.');
  final z = _zustand(ab, bis, tag);
  return VorsorgeFaelligkeit(z.status, ab: z.ab, bis: z.bis, dosis: erledigtAnzahl + 1, dosenGesamt: dosen.length);
}

VorsorgeFaelligkeit _zustand(DateTime ab, DateTime? bis, DateTime heute) {
  final VorsorgeStatus s;
  if (bis != null && !heute.isBefore(bis)) {
    s = VorsorgeStatus.ueberfaellig;
  } else if (!heute.isBefore(ab)) {
    s = VorsorgeStatus.faellig;
  } else if (ab.difference(heute).inDays <= kBaldTage) {
    s = VorsorgeStatus.bald;
  } else {
    s = VorsorgeStatus.spaeter;
  }
  return VorsorgeFaelligkeit(s, ab: ab, bis: bis);
}

/// Empfiehlt sich diese Vorlage jetzt für die Person (Auswahlblatt: "Empfohlen für dich" zuerst)? Nie bei nur-Hinweis, nie bei unpassendem oder unbekanntem Geschlecht einer
/// geschlechtsabhängigen Vorlage, und nur, wenn das Fenster noch nicht vorbei ist und innerhalb des nächsten Jahres beginnt.
bool vorsorgeEmpfohlen(VorsorgeVorlage v, {required DateTime geburt, VorsorgeGeschlecht? geschlecht, required DateTime heute}) {
  if (v.nurHinweis) return false;
  if (v.geschlecht != null && geschlecht != v.geschlecht) return false;
  final g = nurTag(geburt);
  if (v.geborenAb != null && g.year < v.geborenAb!) return false;
  final tag = nurTag(heute);
  DateTime? start;
  DateTime? ende;
  if (v.wiederkehrend) {
    if (v.zielAb != null) start = alterDatum(g, v.zielAb!);
    if (v.zielBis != null) ende = alterDatum(g, v.zielBis!);
  } else if (v.dosen.isNotEmpty) {
    final erste = v.dosen.first;
    final letzte = v.dosen.last;
    if (erste.ab != null) start = alterDatum(g, erste.ab!);
    // das Ende der letzten Dosis mit festem Ende; eine offene Serie endet nie
    if (letzte.bis != null) ende = alterDatum(g, letzte.bis!);
  }
  if (ende != null && !tag.isBefore(ende)) return false;
  if (start != null && start.difference(tag).inDays > 365) return false;
  return true;
}

/// Eine Zeile der Übersicht: ein Eintrag mit seiner Fälligkeit.
class VorsorgePosten {
  final VorsorgeAnsicht eintrag;
  final VorsorgeVorlage? vorlage;
  final VorsorgeFaelligkeit faelligkeit;
  const VorsorgePosten(this.eintrag, this.vorlage, this.faelligkeit);
}

/// Die Karten der Übersicht einer Person.
class VorsorgeKarten {
  final List<VorsorgePosten> faellig;
  final List<VorsorgePosten> bald;
  final List<VorsorgePosten> spaeterOderErledigt;
  final List<VorsorgePosten> hinweise;
  const VorsorgeKarten({this.faellig = const [], this.bald = const [], this.spaeterOderErledigt = const [], this.hinweise = const []});

  bool get leer => faellig.isEmpty && bald.isEmpty && spaeterOderErledigt.isEmpty && hinweise.isEmpty;
}

/// Ordnet die Einträge einer Person in die Karten. Nicht lesbare Einträge fehlen hier (die Oberfläche zeigt sie getrennt). Sortierung: fällige nach Beginn, danach nach Name.
VorsorgeKarten vorsorgeKarten(Iterable<VorsorgeAnsicht> eintraege, {DateTime? geburt, VorsorgeGeschlecht? geschlecht, required DateTime heute}) {
  final faellig = <VorsorgePosten>[];
  final bald = <VorsorgePosten>[];
  final spaeter = <VorsorgePosten>[];
  final hinweise = <VorsorgePosten>[];
  for (final a in eintraege) {
    final i = a.inhalt;
    if (i == null) continue;
    final v = vorsorgeVorlage(i.vorlage);
    final f = vorsorgeFaelligkeit(vorlage: v, eintrag: i, geburt: geburt, geschlecht: geschlecht, heute: heute);
    final p = VorsorgePosten(a, v, f);
    switch (f.status) {
      case VorsorgeStatus.ueberfaellig:
      case VorsorgeStatus.faellig:
        faellig.add(p);
      case VorsorgeStatus.bald:
        bald.add(p);
      case VorsorgeStatus.spaeter:
      case VorsorgeStatus.erledigt:
        spaeter.add(p);
      case VorsorgeStatus.keinTermin:
        hinweise.add(p);
    }
  }
  int nachAb(VorsorgePosten a, VorsorgePosten b) {
    final c = (a.faelligkeit.ab ?? DateTime.utc(9999)).compareTo(b.faelligkeit.ab ?? DateTime.utc(9999));
    return c != 0 ? c : vorsorgeName(a.vorlage, a.eintrag.inhalt!).toLowerCase().compareTo(vorsorgeName(b.vorlage, b.eintrag.inhalt!).toLowerCase());
  }

  faellig.sort(nachAb);
  bald.sort(nachAb);
  spaeter.sort(nachAb);
  hinweise.sort(nachAb);
  return VorsorgeKarten(faellig: faellig, bald: bald, spaeterOderErledigt: spaeter, hinweise: hinweise);
}

/// Der Anzeigename: der eigene Name, sonst der Name der Vorlage, sonst "Eintrag".
String vorsorgeName(VorsorgeVorlage? v, VorsorgeEintragInhalt i) => i.name.isNotEmpty ? i.name : (v?.name ?? 'Eintrag');

/// Wie viele Einträge sind fällig oder überfällig (für Hinweiszahlen)?
int vorsorgeOffeneZahl(Iterable<VorsorgeAnsicht> eintraege, {DateTime? geburt, VorsorgeGeschlecht? geschlecht, required DateTime heute}) => vorsorgeKarten(eintraege, geburt: geburt, geschlecht: geschlecht, heute: heute).faellig.length;

/// Deutsches Datum `TT.MM.JJJJ`.
String vorsorgeDatum(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

/// Kurzer Text zum Stand eines Eintrags ("fällig seit 3 Tagen", "ab 12.03.2027", "in 14 Tagen").
String vorsorgeStandText(VorsorgeFaelligkeit f, DateTime heute) {
  final tage = f.tageBisAb(heute);
  switch (f.status) {
    case VorsorgeStatus.ueberfaellig:
      final ende = f.bis == null ? null : tageZwischen(f.bis!, heute);
      return ende == null || ende <= 0 ? 'Überfällig' : 'Überfällig seit ${_tage(ende)}';
    case VorsorgeStatus.faellig:
      if (f.bis != null) return 'Jetzt möglich bis ${vorsorgeDatum(f.bis!.subtract(const Duration(days: 1)))}';
      final seit = tage == null ? 0 : -tage;
      return seit <= 0 ? 'Jetzt fällig' : 'Fällig seit ${_tage(seit)}';
    case VorsorgeStatus.bald:
      return tage == null ? 'Bald' : 'Ab ${vorsorgeDatum(f.ab!)} (in ${_tage(tage)})';
    case VorsorgeStatus.spaeter:
      return f.ab == null ? 'Später' : 'Nächster Termin ab ${vorsorgeDatum(f.ab!)}';
    case VorsorgeStatus.erledigt:
      return 'Erledigt';
    case VorsorgeStatus.keinTermin:
      return f.grund ?? 'Kein Termin';
  }
}

String _tage(int n) => n == 1 ? '1 Tag' : '$n Tagen';
