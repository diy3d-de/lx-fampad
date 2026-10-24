// Zähler (Abschnitt 6l): Modelle, Klartext-Formate und Festkomma-Hilfen. Verbrauchsdaten verraten Anwesenheit: alles hier steht beim Server nur in e1-Hüllen (Ende-zu-Ende verschlüsselt).
//
//  - Zähler: Klartext `z1:` + JSON (Art, Name, Einheit, Zählernummer, Abrechnungsperiode, Preise mit Gültigkeitsdatum, Abschlag, Gruppe, Vorgänger, Ablese-Rhythmus, Solar-Angaben).
//    Im Ausgang lokal `l1:z1:…`. Hülle: Art `z`.
//  - Zählerstand: Klartext `a1:` + JSON (Datum, Stand, Notiz, Marke). Im Ausgang lokal `l1:a1:…`. Hülle: Art `a`, Bezug = Zähler.
//  - Monatswert (Eingabeart "Monatswerte", z. B. Balkonkraftwerk ohne Zähler): ebenfalls `a1:`, aber mit `v: 2`, Monat `m` (`YYYY-MM`), Wert `w` (Tausendstel der Einheit im Monat) und
//    Schreibzeit `t` (Millisekunden); OHNE Datum `d`. Ältere Apps lesen `v: 2` nicht (sie zeigen "neuere App-Version nötig") und halten ihn nie für einen Zählerstand. Der Server kennt
//    für Stände nur Zufalls-IDs: ein Monat kann darum mehrfach vorkommen (zwei Geräte); es gilt der Eintrag mit dem größten `t` (bei Gleichstand die größte ID), siehe `monatswerteZusammenfuehren`.
// Alle Mengen und Beträge sind GANZE ZAHLEN (Festkomma, keine Gleitkommafehler): Stände in Tausendstel der Einheit (1,234 kWh = 1234), Preise je Einheit in Zehntausendstel Euro
// (0,3456 €/kWh = 3456), Gebühren und Abschläge in Cent. Der Server liest nichts davon. Unbekannte Versionen (`v` größer als [kZaehlerFormat]) und kaputte Daten ergeben `null`
// (nicht lesbar), nie einen Absturz und nie einen Teilinhalt.
import 'dart:convert';

import '../medikamente/medikament_modelle.dart' show tagLesen, tagText;

/// Version des Klartext-Formats (Feld `v`).
const int kZaehlerFormat = 1;

/// Typpräfix der Klartexte (nach dem Hüllenpräfix `l1:` bzw. nach dem Öffnen der Hülle).
const String kPraefixZaehler = 'z1:';
const String kPraefixStand = 'a1:';

/// Art im AAD der Hülle (`HuellenKontext.art`): Zähler `z`, Zählerstand `a`. Eine Hülle lässt sich nie als andere Art lesen.
const String kArtZaehler = 'z';
const String kArtStand = 'a';

/// Obergrenzen (Zeichen bzw. Anzahl); das verschlüsselte Ergebnis bleibt damit unter den Grenzen des Servers (16384 bzw. 2048 Zeichen der Hülle).
const int kMaxNameZeichen = 60;
const int kMaxEinheitZeichen = 12;
const int kMaxNummerZeichen = 40;
const int kMaxNotizZeichen = 300;
const int kMaxStandNotizZeichen = 120;
const int kMaxGruppeZeichen = 40;
const int kMaxOrtZeichen = 40;
const int kMaxPreise = 40;
const int kMaxKlartextBytesZaehler = 8000;
const int kMaxKlartextBytesStand = 600;

/// Format-Version eines Monatswerts (`a1:` mit `v: 2`).
const int kMonatswertFormat = 2;

/// Größter Monatswert: 100 000 Einheiten je Monat (in Tausendsteln).
const int kMaxMonatswertMilli = 100000000;

/// Festkomma: Stände in Tausendstel, Preise in Zehntausendstel, Beträge in Cent.
const int kMengeNachkomma = 3;
const int kPreisNachkomma = 4;
const int kGeldNachkomma = 2;

/// Größte Werte (Stand: 10^13 Tausendstel = 10 Milliarden Einheiten; Preis je Einheit 1000 €; Gebühren und Abschläge 100 000 €).
const int kMaxStandMilli = 10000000000000;
const int kMaxPreisAp = 10000000;
const int kMaxGeldCent = 10000000;

// ---------------------------------------------------------------- Festkomma

/// Liest eine Zahl wie "1234,567", "1.234,5" oder "12.5" als ganze Zahl mit [nachkomma] Nachkommastellen (null: keine gültige, nichtnegative Zahl, mehr Nachkommastellen als erlaubt).
/// Komma ist immer das Dezimalzeichen (dann sind Punkte Tausendertrenner); mit nur Punkten ist ein einzelner Punkt das Dezimalzeichen, mehrere sind Tausendertrenner.
int? festkommaParsen(String text, int nachkomma) {
  var t = text.trim().replaceAll(RegExp(r'[\s  ]'), '');
  if (t.isEmpty) return null;
  if (t.contains(',')) {
    if (t.indexOf(',') != t.lastIndexOf(',')) return null;
    t = t.replaceAll('.', '').replaceAll(',', '.');
  } else if (t.contains('.') && t.indexOf('.') != t.lastIndexOf('.')) {
    t = t.replaceAll('.', '');
  }
  final m = RegExp(r'^(\d{1,15})(?:\.(\d+))?$').firstMatch(t);
  if (m == null) return null;
  final ganz = m.group(1)!;
  final rest = m.group(2) ?? '';
  if (rest.length > nachkomma) {
    // überzählige Nullen ("1,500") sind harmlos, echte Stellen nicht
    if (rest.substring(nachkomma).replaceAll('0', '').isNotEmpty) return null;
  }
  final stellen = rest.length > nachkomma ? rest.substring(0, nachkomma) : rest.padRight(nachkomma, '0');
  final wert = int.tryParse('$ganz$stellen');
  return wert;
}

/// Gegenstück zu [festkommaParsen]: "1234,567" (Komma, ohne Tausenderpunkt); [kuerzen] lässt überflüssige Nullen am Ende weg.
String festkommaText(int wert, int nachkomma, {bool kuerzen = false}) {
  final neg = wert < 0;
  final s = wert.abs().toString().padLeft(nachkomma + 1, '0');
  final ganz = s.substring(0, s.length - nachkomma);
  var rest = nachkomma == 0 ? '' : s.substring(s.length - nachkomma);
  if (kuerzen) rest = rest.replaceFirst(RegExp(r'0+$'), '');
  return '${neg ? '-' : ''}$ganz${rest.isEmpty ? '' : ',$rest'}';
}

int? mengeParsen(String text) => festkommaParsen(text, kMengeNachkomma);
int? preisParsen(String text) => festkommaParsen(text, kPreisNachkomma);
int? geldParsen(String text) => festkommaParsen(text, kGeldNachkomma);
String mengeText(int milli, {bool kuerzen = false}) => festkommaText(milli, kMengeNachkomma, kuerzen: kuerzen);
String preisText(int ap) => festkommaText(ap, kPreisNachkomma);
String geldText(int cent) => festkommaText(cent, kGeldNachkomma);

/// Ganzzahlige Division mit Rundung auf die nächste ganze Zahl (halbe nach oben, bei negativen Zählern von null weg); [nenner] > 0.
int rundenDiv(int zaehler, int nenner) {
  assert(nenner > 0);
  final a = zaehler.abs();
  final q = (a * 2 + nenner) ~/ (nenner * 2);
  return zaehler < 0 ? -q : q;
}

// ---------------------------------------------------------------- Hilfen

String? _text(Object? v, int max, {bool leerErlaubt = false}) {
  if (v is! String || v.length > max) return null;
  if (!leerErlaubt && v.trim().isEmpty) return null;
  return v;
}

int? _ganz(Object? v, int min, int max) => v is int && v >= min && v <= max ? v : null;

// ---------------------------------------------------------------- Eingabeart

/// Wie die Werte eines Zählers erfasst werden: als Zählerstand (Differenzen ergeben den Verbrauch) oder als Monatswert (Verbrauch bzw. Erzeugung je Monat direkt, z. B. aus einer
/// Hersteller-App). Beim Standard `stand` steht nichts im Klartext (bestehende Zähler bleiben byte-gleich).
enum ZaehlerModus {
  stand('stand'),
  monat('monat');

  final String wire;
  const ZaehlerModus(this.wire);

  static ZaehlerModus? tolerant(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }

  /// Vorbelegung beim Einrichten: Erzeugung (kein richtiger Zähler) = Monatswerte, sonst Zählerstand.
  static ZaehlerModus standardFuer(ZaehlerArt art) => art == ZaehlerArt.erzeugung ? monat : stand;
}

// ---------------------------------------------------------------- Art

enum ZaehlerArt {
  strom('s', 'Strom', 'kWh', true),
  kaltwasser('k', 'Kaltwasser', 'm³', false),
  warmwasser('w', 'Warmwasser', 'm³', false),
  gas('g', 'Gas', 'm³', true),
  waerme('h', 'Wärmemenge', 'kWh', true),
  erzeugung('e', 'Erzeugung (Solar)', 'kWh', true),
  eigen('x', 'Eigener Zähler', '', false);

  final String wire;
  final String anzeige;

  /// Vorgeschlagene Einheit (beim eigenen Zähler leer: die Person wählt).
  final String einheit;

  /// Rechnet die Art standardmäßig Kosten (Wasser: Miete und Nebenkosten, ohne Kosten); jeder Zähler kann es ändern.
  final bool kostenStandard;
  const ZaehlerArt(this.wire, this.anzeige, this.einheit, this.kostenStandard);

  bool get istWasser => this == kaltwasser || this == warmwasser;

  static ZaehlerArt? tolerant(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

// ---------------------------------------------------------------- Preis

/// Ein Preisstand ab einem Tag (Preisverlauf): Arbeitspreis je Einheit in Zehntausendstel Euro, Grund- und Zählergebühr je Jahr in Cent (anteilig auf Tage).
class Preis {
  /// Gilt ab diesem Tag (`YYYY-MM-DD`), bis ein späterer Preisstand beginnt.
  final String ab;
  final int arbeitspreis;
  final int grundgebuehrJahr;
  final int zaehlergebuehrJahr;
  const Preis({required this.ab, this.arbeitspreis = 0, this.grundgebuehrJahr = 0, this.zaehlergebuehrJahr = 0});

  DateTime? get abTag => tagLesen(ab);

  bool get gueltig =>
      abTag != null &&
      arbeitspreis >= 0 && arbeitspreis <= kMaxPreisAp &&
      grundgebuehrJahr >= 0 && grundgebuehrJahr <= kMaxGeldCent &&
      zaehlergebuehrJahr >= 0 && zaehlergebuehrJahr <= kMaxGeldCent;

  Map<String, dynamic> toJson() => {
    'ab': ab,
    'ap': arbeitspreis,
    if (grundgebuehrJahr != 0) 'gg': grundgebuehrJahr,
    if (zaehlergebuehrJahr != 0) 'zg': zaehlergebuehrJahr,
  };

  static Preis? fromJson(Object? v) {
    if (v is! Map) return null;
    final ap = _ganz(v['ap'], 0, kMaxPreisAp);
    final gg = v.containsKey('gg') ? _ganz(v['gg'], 0, kMaxGeldCent) : 0;
    final zg = v.containsKey('zg') ? _ganz(v['zg'], 0, kMaxGeldCent) : 0;
    if (v['ab'] is! String || ap == null || gg == null || zg == null) return null;
    final p = Preis(ab: v['ab'] as String, arbeitspreis: ap, grundgebuehrJahr: gg, zaehlergebuehrJahr: zg);
    return p.gueltig ? p : null;
  }

  @override
  bool operator ==(Object other) => other is Preis && other.ab == ab && other.arbeitspreis == arbeitspreis && other.grundgebuehrJahr == grundgebuehrJahr && other.zaehlergebuehrJahr == zaehlergebuehrJahr;

  @override
  int get hashCode => Object.hash(ab, arbeitspreis, grundgebuehrJahr, zaehlergebuehrJahr);
}

// ---------------------------------------------------------------- Ablese-Rhythmus

enum AblesungArt {
  monatlich('m'),
  jaehrlich('j');

  final String wire;
  const AblesungArt(this.wire);
  static AblesungArt? tolerant(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

/// Wann der Zähler abgelesen werden soll: jeden Monat an einem Tag (1..31, in kurzen Monaten der letzte Tag) oder einmal im Jahr an einem Tag und Monat.
class Ablesung {
  final AblesungArt art;
  final int tag;
  final int monat;
  const Ablesung._(this.art, this.tag, this.monat);
  const Ablesung.monatlich(int tag) : this._(AblesungArt.monatlich, tag, 1);
  const Ablesung.jaehrlich({required int monat, required int tag}) : this._(AblesungArt.jaehrlich, tag, monat);

  bool get gueltig => tag >= 1 && tag <= 31 && monat >= 1 && monat <= 12;

  Map<String, dynamic> toJson() => {'r': art.wire, 't': tag, if (art == AblesungArt.jaehrlich) 'm': monat};

  static Ablesung? fromJson(Object? v) {
    if (v is! Map) return null;
    final art = AblesungArt.tolerant(v['r']);
    final tag = _ganz(v['t'], 1, 31);
    final monat = art == AblesungArt.jaehrlich ? _ganz(v['m'], 1, 12) : 1;
    if (art == null || tag == null || monat == null) return null;
    return Ablesung._(art, tag, monat);
  }

  @override
  bool operator ==(Object other) => other is Ablesung && other.art == art && other.tag == tag && other.monat == monat;

  @override
  int get hashCode => Object.hash(art, tag, monat);
}

// ---------------------------------------------------------------- Zähler

/// Ein Zähler des Haushalts. Unveränderlich; [kopie] ersetzt einzelne Felder.
class ZaehlerInhalt {
  final ZaehlerArt art;
  final String name;
  final String einheit;
  final String nummer;
  final String notiz;

  /// Abrechnungsperiode: beginnt am [periodeTag]. [periodeMonat] (Standard 1. Januar = Kalenderjahr).
  final int periodeMonat;
  final int periodeTag;

  /// Rechnet dieser Zähler Kosten?
  final bool kosten;

  /// Preisverlauf, aufsteigend nach `ab`, jedes Datum nur einmal.
  final List<Preis> preise;

  /// Abschlag je Monat in Cent (null: keiner).
  final int? abschlag;

  /// Gruppe (z. B. "Wasser Haus"): Zähler gleicher Art mit gleicher Gruppe werden zu einer Summe zusammengefasst. Leer: keine.
  final String gruppe;

  /// Der Zähler, den dieser ersetzt (Zählerwechsel): die Kette läuft vom ältesten Vorgänger zum neuesten Zähler.
  final String? vorgaenger;

  /// Archiviert ab diesem Tag (`YYYY-MM-DD`; der Zähler zählt nicht mehr, seine Stände bleiben).
  final String? archiviertAb;

  final Ablesung? ablesung;

  /// Nur Erzeugung (Solar): Eigenverbrauchsanteil in Hundertstel Prozent (0..10000), Anlagenkosten in Cent, Einspeisevergütung je kWh in Zehntausendstel Euro.
  final int? eigenverbrauchBp;
  final int? anlagenkosten;
  final int? einspeiseVerguetung;

  /// Wo der Zähler hängt (z. B. "Waschkeller"); nur zur Anzeige.
  final String ort;

  /// Warnschwelle: ab wie viel Prozent über dem Vorjahr der Verbrauch als ungewöhnlich hoch gilt (null: keine Warnung).
  final int? warnProzent;

  /// Eingabeart: Zählerstand (Standard) oder Monatswerte.
  final ZaehlerModus modus;

  ZaehlerInhalt({
    required this.art,
    required this.name,
    String? einheit,
    this.nummer = '',
    this.notiz = '',
    this.periodeMonat = 1,
    this.periodeTag = 1,
    bool? kosten,
    List<Preis> preise = const [],
    this.abschlag,
    this.gruppe = '',
    this.vorgaenger,
    this.archiviertAb,
    this.ablesung,
    this.eigenverbrauchBp,
    this.anlagenkosten,
    this.einspeiseVerguetung,
    this.ort = '',
    this.warnProzent,
    this.modus = ZaehlerModus.stand,
  }) : einheit = einheit ?? art.einheit,
       kosten = kosten ?? art.kostenStandard,
       preise = List.unmodifiable(preise);

  bool get archiviert => archiviertAb != null;

  bool get monatlich => modus == ZaehlerModus.monat;

  /// Ist der Inhalt in sich stimmig (alles, was [zaehlerLesen] beim Lesen verlangt)? Ein ungültiger Inhalt wird nie geschrieben.
  bool get gueltig {
    if (name.trim().isEmpty || name.length > kMaxNameZeichen) return false;
    if (einheit.trim().isEmpty || einheit.length > kMaxEinheitZeichen) return false;
    if (nummer.length > kMaxNummerZeichen || ort.length > kMaxOrtZeichen || notiz.length > kMaxNotizZeichen || gruppe.length > kMaxGruppeZeichen) return false;
    if (periodeMonat < 1 || periodeMonat > 12 || periodeTag < 1 || periodeTag > 31) return false;
    if (preise.length > kMaxPreise || preise.any((p) => !p.gueltig)) return false;
    for (var i = 1; i < preise.length; i++) {
      if (preise[i].ab.compareTo(preise[i - 1].ab) <= 0) return false; // aufsteigend, keine Doppelten
    }
    if (abschlag != null && (abschlag! < 0 || abschlag! > kMaxGeldCent)) return false;
    if (vorgaenger != null && vorgaenger!.isEmpty) return false;
    if (archiviertAb != null && tagLesen(archiviertAb) == null) return false;
    if (ablesung != null && !ablesung!.gueltig) return false;
    if (eigenverbrauchBp != null && (eigenverbrauchBp! < 0 || eigenverbrauchBp! > 10000)) return false;
    if (anlagenkosten != null && (anlagenkosten! < 0 || anlagenkosten! > 100 * kMaxGeldCent)) return false;
    if (einspeiseVerguetung != null && (einspeiseVerguetung! < 0 || einspeiseVerguetung! > kMaxPreisAp)) return false;
    if (warnProzent != null && (warnProzent! < 1 || warnProzent! > 1000)) return false;
    return true;
  }

  ZaehlerInhalt kopie({
    ZaehlerArt? art,
    String? name,
    String? einheit,
    String? nummer,
    String? notiz,
    int? periodeMonat,
    int? periodeTag,
    bool? kosten,
    List<Preis>? preise,
    int? Function()? abschlag,
    String? gruppe,
    String? Function()? vorgaenger,
    String? Function()? archiviertAb,
    Ablesung? Function()? ablesung,
    int? Function()? eigenverbrauchBp,
    int? Function()? anlagenkosten,
    int? Function()? einspeiseVerguetung,
    String? ort,
    int? Function()? warnProzent,
    ZaehlerModus? modus,
  }) => ZaehlerInhalt(
    art: art ?? this.art,
    name: name ?? this.name,
    einheit: einheit ?? this.einheit,
    nummer: nummer ?? this.nummer,
    notiz: notiz ?? this.notiz,
    periodeMonat: periodeMonat ?? this.periodeMonat,
    periodeTag: periodeTag ?? this.periodeTag,
    kosten: kosten ?? this.kosten,
    preise: preise ?? this.preise,
    abschlag: abschlag != null ? abschlag() : this.abschlag,
    gruppe: gruppe ?? this.gruppe,
    vorgaenger: vorgaenger != null ? vorgaenger() : this.vorgaenger,
    archiviertAb: archiviertAb != null ? archiviertAb() : this.archiviertAb,
    ablesung: ablesung != null ? ablesung() : this.ablesung,
    eigenverbrauchBp: eigenverbrauchBp != null ? eigenverbrauchBp() : this.eigenverbrauchBp,
    anlagenkosten: anlagenkosten != null ? anlagenkosten() : this.anlagenkosten,
    einspeiseVerguetung: einspeiseVerguetung != null ? einspeiseVerguetung() : this.einspeiseVerguetung,
    ort: ort ?? this.ort,
    warnProzent: warnProzent != null ? warnProzent() : this.warnProzent,
    modus: modus ?? this.modus,
  );

  Map<String, dynamic> toJson() => {
    'v': kZaehlerFormat,
    'art': art.wire,
    'name': name,
    'einheit': einheit,
    if (nummer.isNotEmpty) 'nr': nummer,
    if (notiz.isNotEmpty) 'notiz': notiz,
    if (periodeMonat != 1) 'pm': periodeMonat,
    if (periodeTag != 1) 'pt': periodeTag,
    'kosten': kosten,
    if (preise.isNotEmpty) 'preise': [for (final p in preise) p.toJson()],
    if (abschlag != null) 'abschlag': abschlag,
    if (gruppe.isNotEmpty) 'gruppe': gruppe,
    if (vorgaenger != null) 'vor': vorgaenger,
    if (archiviertAb != null) 'arch': archiviertAb,
    if (ablesung != null) 'ablese': ablesung!.toJson(),
    if (eigenverbrauchBp != null) 'eigen': eigenverbrauchBp,
    if (anlagenkosten != null) 'anlage': anlagenkosten,
    if (einspeiseVerguetung != null) 'einsp': einspeiseVerguetung,
    if (ort.isNotEmpty) 'ort': ort,
    if (warnProzent != null) 'warn': warnProzent,
    if (modus != ZaehlerModus.stand) 'modus': modus.wire,
  };

  @override
  bool operator ==(Object other) => other is ZaehlerInhalt && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Kodiert einen Zähler als Klartext (`z1:` + JSON); wirft [ArgumentError] bei ungültigem oder zu großem Inhalt (es wird nie etwas Ungültiges geschrieben).
String zaehlerKodieren(ZaehlerInhalt z) {
  if (!z.gueltig) throw ArgumentError('Ungültiger Zähler');
  final text = '$kPraefixZaehler${jsonEncode(z.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesZaehler) throw ArgumentError('Zähler zu groß');
  return text;
}

/// Liest den Klartext eines Zählers; null bei kaputtem Text, falschem Typ, unbekannter (neuerer) Version oder ungültigen Werten.
ZaehlerInhalt? zaehlerLesen(String klar) {
  if (!klar.startsWith(kPraefixZaehler)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixZaehler.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int || (d['v'] as int) < 1 || (d['v'] as int) > kZaehlerFormat) return null;
  final art = ZaehlerArt.tolerant(d['art']);
  final name = _text(d['name'], kMaxNameZeichen);
  final einheit = _text(d['einheit'], kMaxEinheitZeichen);
  final nummer = d.containsKey('nr') ? _text(d['nr'], kMaxNummerZeichen, leerErlaubt: true) : '';
  final notiz = d.containsKey('notiz') ? _text(d['notiz'], kMaxNotizZeichen, leerErlaubt: true) : '';
  final gruppe = d.containsKey('gruppe') ? _text(d['gruppe'], kMaxGruppeZeichen, leerErlaubt: true) : '';
  final pm = d.containsKey('pm') ? _ganz(d['pm'], 1, 12) : 1;
  final pt = d.containsKey('pt') ? _ganz(d['pt'], 1, 31) : 1;
  if (art == null || name == null || einheit == null || nummer == null || notiz == null || gruppe == null || pm == null || pt == null) return null;
  if (d['kosten'] is! bool) return null;
  final preise = <Preis>[];
  if (d.containsKey('preise')) {
    if (d['preise'] is! List) return null;
    for (final e in d['preise'] as List) {
      final p = Preis.fromJson(e);
      if (p == null) return null;
      preise.add(p);
    }
  }
  final Map<Object?, Object?> karte = d;
  int? optGanz(String k, int max) {
    if (!karte.containsKey(k)) return null;
    return _ganz(karte[k], 0, max) ?? -1;
  }

  final ort = d.containsKey('ort') ? _text(d['ort'], kMaxOrtZeichen, leerErlaubt: true) : '';
  if (ort == null) return null;
  final warn = d.containsKey('warn') ? (_ganz(d['warn'], 1, 1000) ?? -1) : null;
  if (warn == -1) return null;
  final modus = d.containsKey('modus') ? ZaehlerModus.tolerant(d['modus']) : ZaehlerModus.stand;
  if (modus == null) return null;
  final abschlag = optGanz('abschlag', kMaxGeldCent);
  final eigen = optGanz('eigen', 10000);
  final anlage = optGanz('anlage', 100 * kMaxGeldCent);
  final einsp = optGanz('einsp', kMaxPreisAp);
  if (abschlag == -1 || eigen == -1 || anlage == -1 || einsp == -1) return null;
  final vor = d.containsKey('vor') ? (d['vor'] is String && (d['vor'] as String).isNotEmpty ? d['vor'] as String : '') : null;
  if (vor == '') return null;
  final arch = d.containsKey('arch') ? (d['arch'] is String ? d['arch'] as String : '?') : null;
  Ablesung? ablesung;
  if (d.containsKey('ablese')) {
    ablesung = Ablesung.fromJson(d['ablese']);
    if (ablesung == null) return null;
  }
  final z = ZaehlerInhalt(
    art: art,
    name: name,
    einheit: einheit,
    nummer: nummer,
    notiz: notiz,
    periodeMonat: pm,
    periodeTag: pt,
    kosten: d['kosten'] as bool,
    preise: preise,
    abschlag: abschlag,
    gruppe: gruppe,
    vorgaenger: vor,
    archiviertAb: arch,
    ablesung: ablesung,
    eigenverbrauchBp: eigen,
    anlagenkosten: anlage,
    einspeiseVerguetung: einsp,
    ort: ort,
    warnProzent: warn,
    modus: modus,
  );
  return z.gueltig ? z : null;
}

// ---------------------------------------------------------------- Zählerstand

/// Besonderer Stand beim Zählerwechsel: Endstand des alten Zählers bzw. Startstand des neuen.
enum StandMarke {
  ende('e'),
  start('s');

  final String wire;
  const StandMarke(this.wire);
  static StandMarke? tolerant(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

/// Eine Ablesung (der Zählerstand an einem Kalendertag, in Tausendsteln der Einheit) ODER ein Monatswert ([monat] gesetzt: Verbrauch bzw. Erzeugung dieses Monats in Tausendsteln).
class StandInhalt {
  /// Tag der Ablesung (`YYYY-MM-DD`); bei einem Monatswert der Monatserste (nur abgeleitet, steht nie im Klartext).
  final String datum;
  final int milli;
  final String notiz;
  final StandMarke? marke;

  /// Nur Monatswert: Monat (`YYYY-MM`) und Schreibzeit in Millisekunden (für "der letzte Eintrag je Monat gewinnt").
  final String? monat;
  final int zeit;
  const StandInhalt({required this.datum, required this.milli, this.notiz = '', this.marke}) : monat = null, zeit = 0;

  /// Ein Monatswert für [monat] (`YYYY-MM`).
  StandInhalt.monatswert({required String this.monat, required this.milli, required this.zeit, this.notiz = ''}) : datum = '$monat-01', marke = null;

  bool get istMonatswert => monat != null;

  DateTime? get tag => tagLesen(datum);

  bool get gueltig {
    if (notiz.length > kMaxStandNotizZeichen) return false;
    if (istMonatswert) return monatLesen(monat) != null && milli >= 0 && milli <= kMaxMonatswertMilli && zeit >= 0;
    return tag != null && milli >= 0 && milli <= kMaxStandMilli;
  }

  StandInhalt kopie({String? datum, int? milli, String? notiz, StandMarke? Function()? marke}) => istMonatswert
      ? StandInhalt.monatswert(monat: monat!, milli: milli ?? this.milli, zeit: zeit, notiz: notiz ?? this.notiz)
      : StandInhalt(datum: datum ?? this.datum, milli: milli ?? this.milli, notiz: notiz ?? this.notiz, marke: marke != null ? marke() : this.marke);

  Map<String, dynamic> toJson() => istMonatswert
      ? {'v': kMonatswertFormat, 'm': monat, 'w': milli, 't': zeit, if (notiz.isNotEmpty) 'n': notiz}
      : {
          'v': kZaehlerFormat,
          'd': datum,
          'w': milli,
          if (notiz.isNotEmpty) 'n': notiz,
          if (marke != null) 'k': marke!.wire,
        };

  @override
  bool operator ==(Object other) => other is StandInhalt && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Liest einen Monat `YYYY-MM` als (Jahr, Monat); null bei allem anderen.
({int jahr, int monat})? monatLesen(String? text) {
  if (text == null) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(text);
  if (m == null) return null;
  final j = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  if (j < 2000 || j > 2999 || mo < 1 || mo > 12) return null;
  return (jahr: j, monat: mo);
}

String monatText(int jahr, int monat) => '${jahr.toString().padLeft(4, '0')}-${monat.toString().padLeft(2, '0')}';

String standKodieren(StandInhalt s) {
  if (!s.gueltig) throw ArgumentError('Ungültiger Zählerstand');
  final text = '$kPraefixStand${jsonEncode(s.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesStand) throw ArgumentError('Zählerstand zu groß');
  return text;
}

StandInhalt? standLesen(String klar) {
  if (!klar.startsWith(kPraefixStand)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixStand.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int) return null;
  final v = d['v'] as int;
  final notiz = d.containsKey('n') ? _text(d['n'], kMaxStandNotizZeichen, leerErlaubt: true) : '';
  if (notiz == null) return null;
  if (v == kMonatswertFormat) {
    final w = _ganz(d['w'], 0, kMaxMonatswertMilli);
    final t = _ganz(d['t'], 0, 1 << 52);
    if (d['m'] is! String || w == null || t == null) return null;
    final m = StandInhalt.monatswert(monat: d['m'] as String, milli: w, zeit: t, notiz: notiz);
    return m.gueltig ? m : null;
  }
  if (v < 1 || v > kZaehlerFormat) return null;
  final datum = d['d'];
  final w = _ganz(d['w'], 0, kMaxStandMilli);
  final marke = d.containsKey('k') ? StandMarke.tolerant(d['k']) : null;
  if (datum is! String || w == null || (d.containsKey('k') && marke == null)) return null;
  final s = StandInhalt(datum: datum, milli: w, notiz: notiz, marke: marke);
  return s.gueltig ? s : null;
}

// ---------------------------------------------------------------- Ansichten (für die Oberfläche)

/// Ein gelesener Zähler (oder einer, der sich nicht lesen lässt: [inhalt] null mit [hinweis]).
class ZaehlerAnsicht {
  final String id;
  final String konversationId;
  final ZaehlerInhalt? inhalt;
  final String? hinweis;
  final DateTime erstelltAt;

  /// Noch nicht vom Server bestätigt (liegt im Ausgang).
  final bool lokalNeu;
  const ZaehlerAnsicht({required this.id, required this.konversationId, required this.inhalt, this.hinweis, required this.erstelltAt, this.lokalNeu = false});
}

class StandAnsicht {
  final String id;
  final String zaehlerId;
  final StandInhalt? inhalt;
  final String? hinweis;
  final DateTime erstelltAt;
  const StandAnsicht({required this.id, required this.zaehlerId, required this.inhalt, this.hinweis, required this.erstelltAt});
}

/// Hilfen für Tage in der Oberfläche.
String zaehlerTagText(DateTime tag) => tagText(tag);
