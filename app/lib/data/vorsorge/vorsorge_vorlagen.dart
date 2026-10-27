// Vorsorge und Impfungen (Abschnitt 6p): der Katalog der Richtwerte als reine Daten (keine Logik, keine Oberfläche). Quelle: docs/vorsorge-richtwerte.md (Recherche 27.10.2026).
//
// Das sind Richtwerte nach STIKO, G-BA und den gesetzlichen Krankenkassen, KEINE ärztliche Beratung. Was nicht live aus der Primärquelle belegt ist, trägt `ungeprueft` (in der App
// "bitte mit Impfpass oder Arztpraxis prüfen"); freiwillige Kassenleistungen tragen `freiwillig`; Impfungen nach Risiko und Dinge ohne klares Zeitfenster tragen `nurHinweis`
// (nur ein Hinweis, nie eine Fälligkeit und nie eine Erinnerung). Die App erfindet keine Fälligkeiten: wo etwas unsicher ist, steht das dabei.
//
// Aufbau einer Vorlage:
//  - Einzelne Untersuchung oder Impfserie: [dosen] (je Dosis ein Zeitfenster nach Alter, optional ein Mindestabstand zur vorigen Dosis); mit der Zahl der erledigten Einträge rückt die nächste Dosis nach.
//  - Wiederkehrend: [intervallMonate] ab [zielAb] (bis [zielBis], falls es eine Obergrenze gibt).
import 'vorsorge_modelle.dart' show VorsorgeArt, VorsorgeGeschlecht;

/// Einheit einer Altersangabe.
enum AlterEinheit { tage, wochen, monate, jahre }

/// Ein Alter ("2 Monate", "5 Jahre") ab der Geburt; das Datum rechnet `vorsorge_logik.dart` auf Kalendertagen.
class Alter {
  final int wert;
  final AlterEinheit einheit;
  const Alter(this.wert, this.einheit);
  const Alter.tage(int n) : this(n, AlterEinheit.tage);
  const Alter.wochen(int n) : this(n, AlterEinheit.wochen);
  const Alter.monate(int n) : this(n, AlterEinheit.monate);
  const Alter.jahre(int n) : this(n, AlterEinheit.jahre);
}

enum VorsorgeGruppe { kind, erwachsen }

/// Zeitfenster einer Dosis: [ab] (Beginn) bis [bis] (Ende, ausgeschlossen), jeweils als Alter; [nachVorigerMonate] = Mindestabstand zur vorigen erledigten Dosis in Monaten
/// (der spätere Zeitpunkt zählt). Ohne [bis] ist das Fenster nach oben offen.
class DosisFenster {
  final Alter? ab;
  final Alter? bis;
  final int? nachVorigerMonate;
  const DosisFenster({this.ab, this.bis, this.nachVorigerMonate});
}

class VorsorgeVorlage {
  /// Stabile Kennung (steht im verschlüsselten Eintrag; nie ändern).
  final String kennung;
  final String name;
  final VorsorgeGruppe gruppe;
  final VorsorgeArt art;
  final String hinweis;
  final String quelle;
  final bool ungeprueft;
  final bool freiwillig;
  final bool nurHinweis;

  /// Nur für dieses Geschlecht (Früherkennung); null = für alle.
  final VorsorgeGeschlecht? geschlecht;

  /// Nur für Personen, die im Jahr [geborenAb] oder später geboren sind (Masern: nach 1970).
  final int? geborenAb;
  final List<DosisFenster> dosen;
  final int? intervallMonate;
  final Alter? zielAb;
  final Alter? zielBis;

  const VorsorgeVorlage({
    required this.kennung,
    required this.name,
    required this.gruppe,
    required this.art,
    required this.hinweis,
    required this.quelle,
    this.ungeprueft = false,
    this.freiwillig = false,
    this.nurHinweis = false,
    this.geschlecht,
    this.geborenAb,
    this.dosen = const [],
    this.intervallMonate,
    this.zielAb,
    this.zielBis,
  });

  bool get wiederkehrend => intervallMonate != null;
}

// Quellen (nur Links; die App öffnet sie über den vorhandenen Weg, nie eingebettet)
const String kQuelleRki = 'https://www.rki.de/DE/Themen/Infektionskrankheiten/Impfen/Impfkalender/impfkalender-node.html';
const String kQuelleBmgKinder = 'https://www.bundesgesundheitsministerium.de/themen/praevention/kindergesundheit/frueherkennungsuntersuchung-bei-kindern';
const String kQuelleGbaCheckup = 'https://www.g-ba.de/themen/methodenbewertung/erwachsene/gesundheitsuntersuchungen/';
const String kQuelleBmgKrebs = 'https://www.bundesgesundheitsministerium.de/krebsfrueherkennung/';
const String kQuelleGbaZahn = 'https://www.g-ba.de/themen/zahnaerztliche-versorgung/prophylaxe-frueherkennung/';

/// Stand der Richtwerte (steht in der App neben dem Hinweis).
const String kVorsorgeStand = 'Oktober 2026';

/// Der Pflichthinweis, der in der Oberfläche immer bei den Richtwerten steht.
const String kVorsorgeHinweis = 'Richtwerte nach STIKO, G-BA und gesetzlichen Krankenkassen, Stand $kVorsorgeStand. Das ist keine ärztliche Beratung – dein Impfpass und deine Ärztin oder dein Arzt entscheiden.';

VorsorgeVorlage _u(String kennung, String name, Alter ab, Alter bis, String hinweis, {bool ungeprueft = false, bool freiwillig = false}) => VorsorgeVorlage(
  kennung: kennung,
  name: name,
  gruppe: VorsorgeGruppe.kind,
  art: VorsorgeArt.vorsorge,
  hinweis: hinweis,
  quelle: kQuelleBmgKinder,
  ungeprueft: ungeprueft,
  freiwillig: freiwillig,
  dosen: [DosisFenster(ab: ab, bis: bis)],
);

VorsorgeVorlage _kindImpf(String kennung, String name, List<DosisFenster> dosen, String hinweis, {bool ungeprueft = true, bool nurHinweis = false}) => VorsorgeVorlage(
  kennung: kennung,
  name: name,
  gruppe: VorsorgeGruppe.kind,
  art: VorsorgeArt.impfung,
  hinweis: hinweis,
  quelle: kQuelleRki,
  ungeprueft: ungeprueft,
  nurHinweis: nurHinweis,
  dosen: dosen,
);

VorsorgeVorlage _erwImpf(
  String kennung,
  String name,
  String hinweis, {
  List<DosisFenster> dosen = const [],
  int? intervallMonate,
  Alter? zielAb,
  bool ungeprueft = false,
  bool nurHinweis = false,
  int? geborenAb,
}) => VorsorgeVorlage(
  kennung: kennung,
  name: name,
  gruppe: VorsorgeGruppe.erwachsen,
  art: VorsorgeArt.impfung,
  hinweis: hinweis,
  quelle: kQuelleRki,
  ungeprueft: ungeprueft,
  nurHinweis: nurHinweis,
  geborenAb: geborenAb,
  dosen: dosen,
  intervallMonate: intervallMonate,
  zielAb: zielAb,
);

VorsorgeVorlage _frueh(
  String kennung,
  String name,
  String hinweis,
  String quelle, {
  List<DosisFenster> dosen = const [],
  int? intervallMonate,
  Alter? zielAb,
  Alter? zielBis,
  VorsorgeGeschlecht? geschlecht,
  bool ungeprueft = false,
  bool nurHinweis = false,
  VorsorgeArt art = VorsorgeArt.vorsorge,
}) => VorsorgeVorlage(
  kennung: kennung,
  name: name,
  gruppe: VorsorgeGruppe.erwachsen,
  art: art,
  hinweis: hinweis,
  quelle: quelle,
  ungeprueft: ungeprueft,
  nurHinweis: nurHinweis,
  geschlecht: geschlecht,
  dosen: dosen,
  intervallMonate: intervallMonate,
  zielAb: zielAb,
  zielBis: zielBis,
);

/// Alle Vorlagen. Reihenfolge = Reihenfolge in der Auswahl.
final List<VorsorgeVorlage> kVorsorgeVorlagen = List.unmodifiable([
  // ------------------------------------------------------------ Kinder: Früherkennungsuntersuchungen (belegt, BMG)
  _u('u1', 'U1 (direkt nach der Geburt)', const Alter.tage(0), const Alter.tage(3), 'Direkt nach der Geburt, meist in der Klinik.'),
  _u('u2', 'U2 (3. bis 10. Lebenstag)', const Alter.tage(2), const Alter.tage(10), 'Zwischen dem 3. und 10. Lebenstag.'),
  _u('u3', 'U3 (4. bis 5. Lebenswoche)', const Alter.tage(21), const Alter.tage(35), 'In der 4. bis 5. Lebenswoche.'),
  _u('u4', 'U4 (3. bis 4. Monat)', const Alter.monate(2), const Alter.monate(4), 'Im 3. bis 4. Lebensmonat.'),
  _u('u5', 'U5 (6. bis 7. Monat)', const Alter.monate(5), const Alter.monate(7), 'Im 6. bis 7. Lebensmonat.'),
  _u('u6', 'U6 (10. bis 12. Monat)', const Alter.monate(9), const Alter.monate(12), 'Im 10. bis 12. Lebensmonat.'),
  _u('u7', 'U7 (21. bis 24. Monat)', const Alter.monate(20), const Alter.monate(24), 'Im 21. bis 24. Lebensmonat.'),
  _u('u7a', 'U7a (34. bis 36. Monat)', const Alter.monate(33), const Alter.monate(36), 'Im 34. bis 36. Lebensmonat.'),
  _u('u8', 'U8 (46. bis 48. Monat)', const Alter.monate(45), const Alter.monate(48), 'Im 46. bis 48. Lebensmonat.'),
  _u('u9', 'U9 (60. bis 64. Monat)', const Alter.monate(59), const Alter.monate(64), 'Im 60. bis 64. Lebensmonat.'),
  _u('j1', 'J1 (13. bis 14. Lebensjahr)', const Alter.jahre(12), const Alter.jahre(14), 'Jugenduntersuchung im 13. bis 14. Lebensjahr.'),
  _u('u10', 'U10 (freiwillig)', const Alter.jahre(7), const Alter.jahre(9), 'Keine Regelleistung der Krankenkassen: Manche Kassen oder Regionalverträge bezahlen sie freiwillig. Frag deine Krankenkasse.', ungeprueft: true, freiwillig: true),
  _u('u11', 'U11 (freiwillig)', const Alter.jahre(9), const Alter.jahre(11), 'Keine Regelleistung der Krankenkassen: Manche Kassen oder Regionalverträge bezahlen sie freiwillig. Frag deine Krankenkasse.', ungeprueft: true, freiwillig: true),
  _u('j2', 'J2 (freiwillig)', const Alter.jahre(16), const Alter.jahre(18), 'Keine Regelleistung der Krankenkassen: Manche Kassen oder Regionalverträge bezahlen sie freiwillig. Frag deine Krankenkasse.', ungeprueft: true, freiwillig: true),
  VorsorgeVorlage(
    kennung: 'zahn_kleinkind',
    name: 'Zahnarzt für Kleinkinder',
    gruppe: VorsorgeGruppe.kind,
    art: VorsorgeArt.zahn,
    hinweis: 'Sechs Früherkennungsuntersuchungen zwischen dem 6. und 72. Lebensmonat; die Abstände sind uneinheitlich, stimm sie mit der Zahnarztpraxis ab.',
    quelle: kQuelleGbaZahn,
    ungeprueft: true,
    intervallMonate: 12,
    zielAb: const Alter.monate(6),
    zielBis: const Alter.monate(72),
  ),
  VorsorgeVorlage(
    kennung: 'zahn_kind',
    name: 'Zahnarzt für Kinder und Jugendliche',
    gruppe: VorsorgeGruppe.kind,
    art: VorsorgeArt.zahn,
    hinweis: 'Individualprophylaxe vom 7. bis 18. Lebensjahr, halbjährlich. Ab 12 Jahren zählt das Bonusheft.',
    quelle: kQuelleGbaZahn,
    ungeprueft: true,
    intervallMonate: 6,
    zielAb: const Alter.jahre(7),
    zielBis: const Alter.jahre(18),
  ),
  // ------------------------------------------------------------ Kinder: Impfungen (STIKO; nicht live aus der Primärquelle gelesen)
  _kindImpf(
    'rotavirus',
    'Rotavirus',
    const [
      DosisFenster(ab: Alter.wochen(6), bis: Alter.wochen(12)),
      DosisFenster(bis: Alter.wochen(24), nachVorigerMonate: 1),
    ],
    'Ab 6 Wochen, je nach Impfstoff 2 oder 3 Dosen; die Serie sollte früh abgeschlossen sein.',
  ),
  _kindImpf(
    'sechsfach',
    '6-fach (Tetanus, Diphtherie, Keuchhusten, Hib, Kinderlähmung, Hepatitis B)',
    const [
      DosisFenster(ab: Alter.monate(2), bis: Alter.monate(4)),
      DosisFenster(ab: Alter.monate(4), bis: Alter.monate(6), nachVorigerMonate: 2),
      DosisFenster(ab: Alter.monate(11), bis: Alter.monate(15), nachVorigerMonate: 6),
    ],
    'Üblich mit 2, 4 und 11 Monaten. Bei Frühgeborenen gilt ein anderes Schema (zusätzliche Dosis).',
  ),
  _kindImpf(
    'pneumokokken_kind',
    'Pneumokokken (Säuglinge)',
    const [
      DosisFenster(ab: Alter.monate(2), bis: Alter.monate(4)),
      DosisFenster(ab: Alter.monate(4), bis: Alter.monate(6), nachVorigerMonate: 2),
      DosisFenster(ab: Alter.monate(11), bis: Alter.monate(15), nachVorigerMonate: 6),
    ],
    'Üblich mit 2, 4 und 11 Monaten. Kinder ab 2 Jahren mit Risiko: nur PCV20.',
  ),
  _kindImpf(
    'mmr',
    'Masern, Mumps, Röteln',
    const [
      DosisFenster(ab: Alter.monate(11), bis: Alter.monate(15)),
      DosisFenster(ab: Alter.monate(15), bis: Alter.monate(24), nachVorigerMonate: 1),
    ],
    '1. Dosis mit 11 bis 14 Monaten, 2. Dosis ab 15 Monaten (mindestens 4 Wochen Abstand). Nachholen ist jederzeit möglich.',
  ),
  _kindImpf(
    'varizellen',
    'Windpocken (Varizellen)',
    const [
      DosisFenster(ab: Alter.monate(11), bis: Alter.monate(15)),
      DosisFenster(ab: Alter.monate(15), bis: Alter.monate(24), nachVorigerMonate: 1),
    ],
    '1. Dosis mit 11 bis 14 Monaten, 2. Dosis ab 15 Monaten (mindestens 4 Wochen Abstand). Nachholen ist jederzeit möglich.',
  ),
  _kindImpf(
    'menacwy',
    'Meningokokken ACWY',
    const [DosisFenster(ab: Alter.jahre(12), bis: Alter.jahre(15))],
    'Neu: eine Dosis mit 12 bis 14 Jahren, Nachholen bis 25 Jahre. Die frühere Meningokokken-C-Impfung im Säuglingsalter entfällt.',
    ungeprueft: false,
  ),
  _kindImpf(
    'tdap_5',
    'Auffrischung Tetanus, Diphtherie, Keuchhusten (5 bis 6 Jahre)',
    const [DosisFenster(ab: Alter.jahre(5), bis: Alter.jahre(7))],
    'Auffrischung mit 5 bis 6 Jahren.',
  ),
  _kindImpf(
    'tdap_ipv_9',
    'Auffrischung Td(ap) und Kinderlähmung (9 bis 16 Jahre)',
    const [DosisFenster(ab: Alter.jahre(9), bis: Alter.jahre(17))],
    'Auffrischung zwischen 9 und 16 Jahren.',
  ),
  _kindImpf(
    'hpv',
    'HPV (Gebärmutterhalskrebs-Vorsorge)',
    const [
      DosisFenster(ab: Alter.jahre(9), bis: Alter.jahre(15)),
      DosisFenster(bis: Alter.jahre(18), nachVorigerMonate: 5),
    ],
    '2 Dosen mit 9 bis 14 Jahren (5 Monate Abstand); ab 15 Jahren sind 3 Dosen nötig. Nachholen bis 17 Jahre.',
  ),
  _kindImpf(
    'rsv_saeugling',
    'RSV (Säuglinge)',
    const [],
    'Einmal in der ersten RSV-Saison. Die Empfehlung hängt vom Geburtszeitpunkt ab, frag die Kinderarztpraxis.',
    nurHinweis: true,
  ),
  // ------------------------------------------------------------ Erwachsene: Impfungen
  _erwImpf('td_auffrischung', 'Tetanus und Diphtherie (Auffrischung)', 'Alle 10 Jahre. Bei der nächsten fälligen Dosis einmalig mit Keuchhusten (Tdap).', intervallMonate: 120, zielAb: const Alter.jahre(18), ungeprueft: true),
  _erwImpf('pertussis_einmalig', 'Keuchhusten (einmalig)', 'Einmalig bei der nächsten fälligen Tetanus-Dosis (Tdap).', dosen: const [DosisFenster(ab: Alter.jahre(18))], ungeprueft: true),
  _erwImpf(
    'masern_erwachsene',
    'Masern (Erwachsene)',
    'Für nach 1970 Geborene mit unklarem Impfstatus oder nur einer Dosis: einmalig impfen.',
    dosen: const [DosisFenster(ab: Alter.jahre(18))],
    geborenAb: 1971,
  ),
  _erwImpf('influenza', 'Grippe (Influenza)', 'Ab 60 Jahren jährlich, am besten im Herbst.', intervallMonate: 12, zielAb: const Alter.jahre(60)),
  _erwImpf('pneumokokken_erw', 'Pneumokokken', 'Ab 60 Jahren einmalig (PCV20). Nach einer früheren PPSV23-Impfung mindestens 6 Jahre Abstand.', dosen: const [DosisFenster(ab: Alter.jahre(60))]),
  _erwImpf(
    'zoster',
    'Gürtelrose (Herpes zoster)',
    'Ab 60 Jahren, Totimpfstoff in 2 Dosen im Abstand von 2 bis 6 Monaten. Ab 18 Jahren bei erhöhter Gefährdung.',
    dosen: const [DosisFenster(ab: Alter.jahre(60)), DosisFenster(nachVorigerMonate: 2)],
    ungeprueft: true,
  ),
  _erwImpf('covid', 'COVID-19', 'Ab 75 Jahren jährlich, mindestens 6 Monate nach der letzten Impfung oder Infektion (Altersgrenze seit Juli 2026, Stand 15.10.2026). Jünger nur bei Risiko.', intervallMonate: 12, zielAb: const Alter.jahre(75)),
  _erwImpf('rsv_erwachsene', 'RSV (Erwachsene)', 'Ab 75 Jahren einmalig. Mit 60 bis 74 Jahren nur bei schwerer Grunderkrankung oder im Pflegeheim.', dosen: const [DosisFenster(ab: Alter.jahre(75))]),
  _erwImpf('hepatitis_b_risiko', 'Hepatitis B (nur nach Risiko)', 'Nur bei erhöhtem Risiko (zum Beispiel Beruf). Besprich es mit deiner Arztpraxis.', nurHinweis: true),
  _erwImpf('fsme_risiko', 'FSME (Risikogebiet)', 'Nur wenn du in oder bei einem Risikogebiet lebst oder dorthin reist.', nurHinweis: true),
  _erwImpf('chikungunya_risiko', 'Chikungunya (Reise oder Beruf)', 'Nur bei Reisen in betroffene Gebiete oder beruflichem Risiko.', nurHinweis: true),
  // ------------------------------------------------------------ Erwachsene: Früherkennung (gesetzliche Krankenkassen)
  _frueh(
    'checkup_18_34',
    'Gesundheits-Check-up (18 bis 34 Jahre)',
    'Einmalig zwischen 18 und 34 Jahren.',
    kQuelleGbaCheckup,
    dosen: const [DosisFenster(ab: Alter.jahre(18), bis: Alter.jahre(35))],
  ),
  _frueh('checkup_35', 'Gesundheits-Check-up (ab 35 Jahren)', 'Ab 35 Jahren alle 3 Jahre.', kQuelleGbaCheckup, intervallMonate: 36, zielAb: const Alter.jahre(35)),
  _frueh('hautkrebs', 'Hautkrebs-Screening', 'Ab 35 Jahren alle 2 Jahre.', kQuelleBmgKrebs, intervallMonate: 24, zielAb: const Alter.jahre(35)),
  _frueh('darm_stuhltest', 'Darmkrebs: Stuhltest', 'Ab 50 Jahren alle 2 Jahre.', kQuelleBmgKrebs, intervallMonate: 24, zielAb: const Alter.jahre(50)),
  _frueh(
    'darm_koloskopie',
    'Darmkrebs: Darmspiegelung',
    'Ab 50 Jahren, zwei Untersuchungen im Abstand von 10 Jahren (seit April 2025 auch für Frauen ab 50).',
    kQuelleBmgKrebs,
    dosen: const [DosisFenster(ab: Alter.jahre(50)), DosisFenster(nachVorigerMonate: 120)],
  ),
  _frueh(
    'gebaermutterhals_20_34',
    'Gebärmutterhals: Abstrich (20 bis 34 Jahre)',
    'Frauen von 20 bis 34 Jahren jährlich (Pap-Abstrich).',
    kQuelleBmgKrebs,
    intervallMonate: 12,
    zielAb: const Alter.jahre(20),
    zielBis: const Alter.jahre(35),
    geschlecht: VorsorgeGeschlecht.weiblich,
  ),
  _frueh(
    'gebaermutterhals_35',
    'Gebärmutterhals: HPV-Test und Abstrich (ab 35 Jahren)',
    'Frauen ab 35 Jahren alle 3 Jahre.',
    kQuelleBmgKrebs,
    intervallMonate: 36,
    zielAb: const Alter.jahre(35),
    geschlecht: VorsorgeGeschlecht.weiblich,
  ),
  _frueh('brust_abtasten', 'Brust: Abtasten', 'Frauen ab 30 Jahren jährlich.', kQuelleBmgKrebs, intervallMonate: 12, zielAb: const Alter.jahre(30), geschlecht: VorsorgeGeschlecht.weiblich),
  _frueh(
    'mammographie',
    'Brust: Mammographie-Screening',
    'Frauen von 50 bis 69 Jahren alle 2 Jahre. Von 70 bis 75 auf Wunsch (die Grenze ist unsicher).',
    kQuelleBmgKrebs,
    intervallMonate: 24,
    zielAb: const Alter.jahre(50),
    zielBis: const Alter.jahre(70),
    geschlecht: VorsorgeGeschlecht.weiblich,
    ungeprueft: true,
  ),
  _frueh('prostata', 'Prostata: Tastuntersuchung', 'Männer ab 45 Jahren jährlich.', kQuelleBmgKrebs, intervallMonate: 12, zielAb: const Alter.jahre(45), geschlecht: VorsorgeGeschlecht.maennlich),
  _frueh(
    'lunge_ldct',
    'Lungenkrebs: Low-Dose-CT (nur nach Risiko)',
    'Mit 50 bis 75 Jahren, nur bei starken (ehemaligen) Raucherinnen und Rauchern, jährlich. Die Kriterien sind eng, frag deine Arztpraxis.',
    kQuelleBmgKrebs,
    nurHinweis: true,
  ),
  _frueh(
    'zahn_erwachsene',
    'Zahnarzt-Kontrolle',
    'Halbjährlich üblich. Das Bonusheft braucht mindestens einen Besuch im Jahr, Zahnstein-Entfernung einmal im Jahr.',
    kQuelleGbaZahn,
    intervallMonate: 6,
    zielAb: const Alter.jahre(18),
    ungeprueft: true,
    art: VorsorgeArt.zahn,
  ),
]);

/// Die Vorlage mit dieser Kennung (null: unbekannt, zum Beispiel aus einer neueren App-Version).
VorsorgeVorlage? vorsorgeVorlage(String? kennung) {
  if (kennung == null) return null;
  for (final v in kVorsorgeVorlagen) {
    if (v.kennung == kennung) return v;
  }
  return null;
}
