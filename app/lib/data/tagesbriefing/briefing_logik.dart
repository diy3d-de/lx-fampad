// Tagesbriefing: REINE Logik (keine Oberfläche, kein Netz, kein Server). Aus den lokalen Daten entsteht eine kurze Zusammenfassung des Tages:
// Termine, fällige und überfällige Aufgaben, dringende Fristen, Abfuhrtermine und das Wetter (nur mit frischem Stand).
//  - Nichts aus Chat, Standort, Schlüsseln, Zählern, Tresor, Medikamenten oder Dateien (Negativtest test/tagesbriefing_nie_zeigen_test.dart).
//  - Aufgaben und Fristen nur, was der Person laut den Regeln der Erinnerungen zusteht ([aufgabeBetrifftPerson]); Eltern-Aufgaben (Sicht `parents`) sieht ein Kind nie,
//    Fristen anderer sehen nur Eltern und Admins (wie bei den Frist-Erinnerungen).
//  - "Jetzt" ist der Bezugszeitpunkt des Briefings: Tag und "noch nicht vorbei" richten sich danach. Für die Benachrichtigung am Morgen ist es die geplante Uhrzeit.
//  - Der neutrale Text ([Tagesbriefing.neutralerText]) enthält nur Zahlen, nie Titel oder Namen (er steht auch auf dem Sperrbildschirm).
import '../app_database.dart' show Aufgabe;
import '../calendar/expansion.dart' show Vorkommen, vorkommenImFenster;
import '../calendar/geburtstag.dart' show vorkommenTitel;
import '../calendar/termin_repository.dart' show KalenderDaten;
import '../calendar/zeitzonen.dart';
import '../erinnerungen/erinnerung_planung.dart' show aufgabeBetrifftPerson;
import '../muell/muell_logik.dart' show artenText;
import '../muell/muell_modelle.dart' show MuellTag;
import '../tasks/aufgabe_logik.dart' show istErledigt, istHeuteFaellig, istUeberfaellig, tagVon;
import '../tasks/fristen_logik.dart' show FristAmpel, fristAmpel;
import '../wetter/vorhersage_modelle.dart' show VorhersageTag;

enum BriefingArt { termine, aufgaben, fristen, muell, wetter }

class BriefingZeile {
  final BriefingArt art;
  final String text;
  const BriefingZeile(this.art, this.text);
}

class Tagesbriefing {
  final List<BriefingZeile> zeilen;

  /// Zahlen für den neutralen Text.
  final int termine;
  final int aufgaben;
  final int fristen;
  const Tagesbriefing({this.zeilen = const [], this.termine = 0, this.aufgaben = 0, this.fristen = 0});

  /// Es gibt etwas zu zeigen, das nicht nur das Wetter ist (das Wetter allein ergibt kein Briefing: dafür gibt es die Wetter-Kachel).
  bool get hatInhalt => zeilen.any((z) => z.art != BriefingArt.wetter);

  /// "Heute: 3 Termine, 2 Aufgaben" (nur Zahlen); null, wenn alle Zahlen 0 sind.
  String? get neutralerText => neutralerBriefingText(termine: termine, aufgaben: aufgaben, fristen: fristen);
}

String _zahl(int n, String eins, String viele) => '$n ${n == 1 ? eins : viele}';

/// Benachrichtigungstext am Morgen: nur Zahlen, null ohne Inhalt.
String? neutralerBriefingText({required int termine, required int aufgaben, required int fristen}) {
  final teile = [
    if (termine > 0) _zahl(termine, 'Termin', 'Termine'),
    if (aufgaben > 0) _zahl(aufgaben, 'Aufgabe', 'Aufgaben'),
    if (fristen > 0) _zahl(fristen, 'Frist', 'Fristen'),
  ];
  return teile.isEmpty ? null : 'Heute: ${teile.join(', ')}';
}

String _hhmm(DateTime w) => '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

/// Darf die Person diese Aufgabe sehen und ist sie für sie gedacht? Sicht `parents` nur für Eltern/Admins; sonst zugewiesen (ohne Zuständige: selbst angelegt),
/// Fristen zusätzlich für alle Eltern und Admins (wie bei den Frist-Erinnerungen).
bool briefingAufgabeFuerPerson(Aufgabe a, {required String? ich, required bool elternRolle}) {
  if (a.audience == 'parents' && !elternRolle) return false;
  if (aufgabeBetrifftPerson(a.assigneeId, a.ownerId, ich)) return true;
  return a.frist && elternRolle;
}

/// Termine des Tages von [jetzt] (Familienzone), die noch nicht vorbei sind, in der Reihenfolge des Kalenders.
List<Vorkommen> briefingTermine(KalenderDaten daten, DateTime jetzt) {
  final heute = tagVon(jetzt);
  final jetztWand = wandUhr(jetzt.toUtc(), familienOrt);
  final alle = vorkommenImFenster(
    termine: daten.termine,
    ausnahmen: daten.ausnahmen,
    vonWand: heute,
    bisWand: DateTime.utc(heute.year, heute.month, heute.day + 1),
    jetzt: jetzt.toUtc(),
  );
  return [
    for (final v in alle)
      if (v.endeWand.isAfter(jetztWand) || (v.endeWand == v.startWand && !v.startWand.isBefore(jetztWand))) v,
  ];
}

String _terminZeilenText(List<Vorkommen> liste, DateTime jetzt) {
  final n = liste.length;
  final jetztWand = wandUhr(jetzt.toUtc(), familienOrt);
  String titel(Vorkommen v) => v.titel.trim().isEmpty ? 'Termin' : vorkommenTitel(v);
  if (n == 1) {
    final v = liste.first;
    return v.ganztaegig ? 'Heute steht 1 Termin an: ${titel(v)}, ganztägig.' : 'Heute steht 1 Termin an: ${_hhmm(v.startWand)} Uhr, ${titel(v)}.';
  }
  final kopf = 'Heute stehen $n Termine an.';
  final naechster = liste.where((v) => !v.ganztaegig && !v.startWand.isBefore(jetztWand)).firstOrNull;
  return naechster == null ? kopf : '$kopf Der nächste ist um ${_hhmm(naechster.startWand)} Uhr: ${titel(naechster)}.';
}

/// Wettertext aus der Vorhersage des Tages ("Heute werden es 8 bis 16 °C, Regen ist wahrscheinlich (70 %)."); [tag] muss der heutige Tag sein (prüft der Aufrufer).
String briefingWetterText(VorhersageTag tag) {
  final lo = tag.min.round();
  final hi = tag.max.round();
  final temp = lo == hi ? 'um $lo °C' : '$lo bis $hi °C';
  final p = tag.regenProzent;
  final String regen;
  if ((p != null && p >= 50) || tag.regenMm >= 1) {
    regen = 'Regen ist wahrscheinlich${p == null ? '' : ' ($p %)'}';
  } else if (p != null && p >= 20) {
    regen = 'Regen ist möglich ($p %)';
  } else {
    regen = 'es bleibt voraussichtlich trocken';
  }
  return 'Heute werden es $temp, $regen.';
}

/// Baut das Briefing für den Tag von [jetzt]. [muell]: Abfuhrtermine (null = keine Daten); [wetter]: die Vorhersage des heutigen Tages, nur aus einem
/// frischen Stand und nur bei eingeschaltetem Wetter (sonst null).
Tagesbriefing baueTagesbriefing({
  required KalenderDaten kalender,
  required List<Aufgabe> aufgaben,
  required String? ich,
  required bool elternRolle,
  required DateTime jetzt,
  List<MuellTag>? muell,
  VorhersageTag? wetter,
}) {
  if (ich == null) return const Tagesbriefing();
  final zeilen = <BriefingZeile>[];
  final termine = briefingTermine(kalender, jetzt);
  if (termine.isNotEmpty) zeilen.add(BriefingZeile(BriefingArt.termine, _terminZeilenText(termine, jetzt)));

  final offen = [
    for (final a in aufgaben)
      if (!istErledigt(a) && briefingAufgabeFuerPerson(a, ich: ich, elternRolle: elternRolle)) a,
  ];
  final normal = [for (final a in offen) if (!a.frist) a];
  final heuteFaellig = normal.where((a) => istHeuteFaellig(a, jetzt)).length;
  final ueberfaellig = normal.where((a) => istUeberfaellig(a, jetzt)).length;
  if (heuteFaellig > 0) zeilen.add(BriefingZeile(BriefingArt.aufgaben, heuteFaellig == 1 ? 'Heute ist 1 Aufgabe fällig.' : 'Heute sind $heuteFaellig Aufgaben fällig.'));
  if (ueberfaellig > 0) zeilen.add(BriefingZeile(BriefingArt.aufgaben, ueberfaellig == 1 ? '1 Aufgabe ist überfällig.' : '$ueberfaellig Aufgaben sind überfällig.'));

  var fristUeber = 0;
  var fristBald = 0;
  for (final a in offen.where((a) => a.frist)) {
    switch (fristAmpel(a, jetzt)) {
      case FristAmpel.ueberfaellig:
        fristUeber++;
      case FristAmpel.bald:
        fristBald++;
      case FristAmpel.ruhig || FristAmpel.erledigt:
        break;
    }
  }
  if (fristUeber > 0) zeilen.add(BriefingZeile(BriefingArt.fristen, fristUeber == 1 ? '1 Frist ist überfällig.' : '$fristUeber Fristen sind überfällig.'));
  if (fristBald > 0) zeilen.add(BriefingZeile(BriefingArt.fristen, fristBald == 1 ? '1 Frist läuft bald ab.' : '$fristBald Fristen laufen bald ab.'));

  if (muell != null) {
    final heute = tagVon(jetzt);
    final morgen = DateTime.utc(heute.year, heute.month, heute.day + 1);
    for (final t in muell) {
      if (t.arten.isEmpty) continue;
      if (t.tag == heute) zeilen.add(BriefingZeile(BriefingArt.muell, 'Heute ist Müllabfuhr: ${artenText(t.arten)}.'));
      if (t.tag == morgen) zeilen.add(BriefingZeile(BriefingArt.muell, 'Morgen ist Müllabfuhr: ${artenText(t.arten)}.'));
    }
  }

  if (wetter != null) zeilen.add(BriefingZeile(BriefingArt.wetter, briefingWetterText(wetter)));

  return Tagesbriefing(zeilen: zeilen, termine: termine.length, aufgaben: heuteFaellig + ueberfaellig, fristen: fristUeber + fristBald);
}
