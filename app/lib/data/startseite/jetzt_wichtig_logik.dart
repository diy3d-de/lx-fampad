// Block "Jetzt wichtig" oben auf der Startseite: REINE Logik (keine Oberfläche, kein Netz, kein Server). Aus den lokalen Daten entstehen die wenigen Zeilen,
// bei denen jetzt etwas zu tun ist: Überfälliges (Aufgaben und Fristen), heute noch Anstehendes (Termine, heute fällige Aufgaben) und der Müll heute/morgen.
//  - Nichts aus Chat, Standort, Schlüsseln, Zählern, Tresor, Medikamenten, Vorsorge oder Dateien (Negativtest test/jetzt_wichtig_test.dart).
//  - Aufgaben und Fristen nur, was der Person laut den Regeln des Tagesbriefings zusteht ([briefingAufgabeFuerPerson]); Sicht `parents` nie für Kinder.
//  - Jede Zeile hat Symbol-Art UND Text (nie nur Farbe): "überfällig" steht als Wort im Zusatz.
import '../app_database.dart' show Aufgabe;
import '../calendar/geburtstag.dart' show vorkommenTitel;
import '../calendar/termin_repository.dart' show KalenderDaten;
import '../muell/muell_logik.dart' show artenText;
import '../muell/muell_modelle.dart' show MuellTag;
import '../tagesbriefing/briefing_logik.dart' show briefingAufgabeFuerPerson, briefingTermine;
import '../tasks/aufgabe_logik.dart' show faelligWand, istErledigt, istHeuteFaellig, istUeberfaellig, tagVon;
import '../tasks/fristen_logik.dart' show FristAmpel, fristAmpel;

/// Höchstens so viele Zeilen stehen im Block (der Rest als "+ n weitere").
const kJetztWichtigMax = 5;

enum JetztArt { ueberfaellig, termin, aufgabe, muell }

class JetztZeile {
  final JetztArt art;

  /// Hauptzeile (Titel der Aufgabe, des Termins; Müll: "Biotonne morgen").
  final String text;

  /// Rechts daneben: "2 Tage überfällig", "15:30", "heute fällig", "Müll".
  final String zusatz;
  const JetztZeile(this.art, this.text, this.zusatz);

  /// Dringend = Überfälliges (der Block hebt es mit dem Wort "überfällig" und einem Symbol hervor, nie nur mit Farbe).
  bool get dringend => art == JetztArt.ueberfaellig;
}

class JetztWichtig {
  /// Die gezeigten Zeilen (höchstens [kJetztWichtigMax]).
  final List<JetztZeile> zeilen;

  /// Alle Einträge, auch die nicht gezeigten.
  final int gesamt;
  const JetztWichtig({this.zeilen = const [], this.gesamt = 0});

  bool get hatInhalt => zeilen.isNotEmpty;
  int get weitere => gesamt - zeilen.length;
}

String _hhmm(DateTime w) => '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

String _ueberfaelligZusatz(int tage) => tage <= 0 ? 'überfällig' : (tage == 1 ? '1 Tag überfällig' : '$tage Tage überfällig');

/// Baut den Block für den Moment [jetzt]. [muell]: Abfuhrtermine (null = keine Daten).
JetztWichtig baueJetztWichtig({
  required KalenderDaten kalender,
  required List<Aufgabe> aufgaben,
  required String? ich,
  required bool elternRolle,
  required DateTime jetzt,
  List<MuellTag>? muell,
}) {
  if (ich == null) return const JetztWichtig();
  final heute = tagVon(jetzt);

  // 1. Überfälliges: Aufgaben (nicht Fristen) und überfällige Fristen, das Älteste zuerst
  final offen = [
    for (final a in aufgaben)
      if (!istErledigt(a) && briefingAufgabeFuerPerson(a, ich: ich, elternRolle: elternRolle)) a,
  ];
  final ueber = <(int, String)>[];
  for (final a in offen) {
    final bool faellt = a.frist ? fristAmpel(a, jetzt) == FristAmpel.ueberfaellig : istUeberfaellig(a, jetzt);
    if (!faellt) continue;
    final w = faelligWand(a);
    final tage = w == null ? 0 : heute.difference(DateTime.utc(w.year, w.month, w.day)).inDays;
    ueber.add((tage, a.titel.trim().isEmpty ? (a.frist ? 'Frist' : 'Aufgabe') : a.titel.trim()));
  }
  ueber.sort((a, b) => b.$1.compareTo(a.$1) != 0 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  final zeilen = <JetztZeile>[for (final u in ueber) JetztZeile(JetztArt.ueberfaellig, u.$2, _ueberfaelligZusatz(u.$1))];

  // 2. Heute: Termine, die noch nicht vorbei sind (Kalenderreihenfolge), dann heute fällige Aufgaben
  for (final v in briefingTermine(kalender, jetzt)) {
    final titel = v.titel.trim().isEmpty ? 'Termin' : vorkommenTitel(v);
    zeilen.add(JetztZeile(JetztArt.termin, titel, v.ganztaegig ? 'ganztägig' : _hhmm(v.startWand)));
  }
  for (final a in offen) {
    if (a.frist || !istHeuteFaellig(a, jetzt)) continue;
    zeilen.add(JetztZeile(JetztArt.aufgabe, a.titel.trim().isEmpty ? 'Aufgabe' : a.titel.trim(), 'heute fällig'));
  }

  // 3. Müll heute und morgen
  if (muell != null) {
    final morgen = DateTime.utc(heute.year, heute.month, heute.day + 1);
    for (final t in muell) {
      if (t.arten.isEmpty) continue;
      if (t.tag == heute) zeilen.add(JetztZeile(JetztArt.muell, '${artenText(t.arten)} heute', 'Müll'));
      if (t.tag == morgen) zeilen.add(JetztZeile(JetztArt.muell, '${artenText(t.arten)} morgen', 'Müll'));
    }
  }

  return JetztWichtig(zeilen: zeilen.take(kJetztWichtigMax).toList(), gesamt: zeilen.length);
}

/// Schlüssel in `sync_meta`: Block ein- oder ausgeschaltet ("nein" = aus, sonst an).
const kJetztWichtigSchluessel = 'jetzt_wichtig';
