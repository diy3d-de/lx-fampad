// Medikamenten-Plan (Abschnitt 6k): Modelle und Klartext-Formate. Gesundheitsdaten: alles hier steht beim Server nur in e1-Hüllen (Ende-zu-Ende verschlüsselt).
//
//  - Medikament (Plan): Klartext `m1:` + JSON (Name, Dosis, Rhythmus, Uhrzeiten, Menge, Beginn/Ende, Zustand, Vorrat, Rezeptdatum, Notiz). Im Ausgang lokal `l1:m1:…`.
//  - Einnahme (Protokolleintrag): Klartext `n1:` + JSON (geplanter Slot, Zeitpunkt, Status, Menge). Im Ausgang lokal `l1:n1:…`.
// Der Server liest nichts davon. Unbekannte Versionen (`v` größer als [kFormatVersion]) und kaputte Daten ergeben `null` (nicht lesbar), nie einen Absturz und nie einen Teilinhalt.
import 'dart:convert';
export '../crypto/huellen_arten.dart' show kArtMedikament, kArtEinnahme;

/// Version des Klartext-Formats (Feld `v`).
const int kFormatVersion = 1;

/// Typpräfix der Klartexte (nach dem Hüllenpräfix `l1:` bzw. nach dem Öffnen der Hülle).
const String kPraefixMedikament = 'm1:';
const String kPraefixEinnahme = 'n1:';

/// Art im AAD der Hülle (`HuellenKontext.art`): Medikament `m`, Einnahme `n`. Eine Hülle lässt sich nie als andere Art lesen.

/// Obergrenzen (Zeichen bzw. Anzahl); das verschlüsselte Ergebnis bleibt damit unter den Grenzen des Servers (16384 bzw. 2048 Zeichen der Hülle).
const int kMaxNameZeichen = 80;
const int kMaxDosisZeichen = 60;
const int kMaxNotizZeichen = 500;
const int kMaxZeiten = 12;
const double kMaxMenge = 100;
const double kMaxBestand = 100000;
const int kMaxKlartextBytesMedikament = 4000;
const int kMaxKlartextBytesEinnahme = 600;

/// Wie lange der Server Einnahmen aufbewahrt (Tage); ältere Einträge sind dort gelöscht, die App zeigt und rechnet nur damit.
const int kEinnahmenAufbewahrungTage = 120;

// ---------------------------------------------------------------- Hilfen

final RegExp _zeitRegex = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final RegExp _slotRegex = RegExp(r'^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d$');
final RegExp _tagRegex = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Kalendertag `YYYY-MM-DD` (gültig), sonst null.
DateTime? tagLesen(Object? v) {
  if (v is! String || !_tagRegex.hasMatch(v)) return null;
  final t = DateTime.tryParse('${v}T00:00:00Z');
  return t != null && tagText(t) == v ? t : null;
}

/// `YYYY-MM-DD` aus Jahr, Monat und Tag von [t] (die Uhrzeit zählt nicht).
String tagText(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Uhrzeit `HH:MM` (00:00 bis 23:59) -> Minuten seit Mitternacht, sonst null.
int? zeitMinuten(Object? v) {
  if (v is! String || !_zeitRegex.hasMatch(v)) return null;
  return int.parse(v.substring(0, 2)) * 60 + int.parse(v.substring(3, 5));
}

String zeitText(int minuten) => '${(minuten ~/ 60).toString().padLeft(2, '0')}:${(minuten % 60).toString().padLeft(2, '0')}';

double? _zahl(Object? v, double min, double max, {bool exklusivMin = false}) {
  if (v is! num || !v.isFinite) return null;
  final d = v.toDouble();
  if (d > max || d < min || (exklusivMin && d == min)) return null;
  return d;
}

String? _text(Object? v, int max, {bool leerErlaubt = false}) {
  if (v is! String || v.length > max) return null;
  if (!leerErlaubt && v.trim().isEmpty) return null;
  return v;
}

// ---------------------------------------------------------------- Rhythmus

enum RhythmusArt {
  taeglich('t'),
  wochentage('w'),
  intervall('i'),
  bedarf('b');

  final String wire;
  const RhythmusArt(this.wire);
  static RhythmusArt? tolerant(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

/// Wann ein Medikament genommen wird: täglich, an bestimmten Wochentagen (1 = Montag bis 7 = Sonntag wie [DateTime.weekday]), alle N Tage ab einem Starttag
/// oder nur bei Bedarf (keine festen Zeiten).
class Rhythmus {
  final RhythmusArt art;
  final Set<int> wochentage;
  final int alleNTage;

  /// Starttag des Intervalls (`YYYY-MM-DD`): jeder N-te Tag ab hier.
  final String? ab;
  const Rhythmus._(this.art, this.wochentage, this.alleNTage, this.ab);

  const Rhythmus.taeglich() : this._(RhythmusArt.taeglich, const {}, 1, null);
  const Rhythmus.bedarf() : this._(RhythmusArt.bedarf, const {}, 1, null);
  Rhythmus.wochentage(Set<int> tage) : this._(RhythmusArt.wochentage, Set.unmodifiable(tage), 1, null);
  Rhythmus.intervall(int n, {required String ab}) : this._(RhythmusArt.intervall, const {}, n, ab);

  bool get festeZeiten => art != RhythmusArt.bedarf;

  /// Stimmig (Wochentage 1..7 und nicht leer, Intervall 1..365 mit gültigem Starttag)?
  bool get gueltig => switch (art) {
    RhythmusArt.taeglich || RhythmusArt.bedarf => true,
    RhythmusArt.wochentage => wochentage.isNotEmpty && wochentage.every((d) => d >= 1 && d <= 7),
    RhythmusArt.intervall => alleNTage >= 1 && alleNTage <= 365 && tagLesen(ab) != null,
  };

  Map<String, dynamic> toJson() => {
    'art': art.wire,
    if (art == RhythmusArt.wochentage) 'tage': (wochentage.toList()..sort()),
    if (art == RhythmusArt.intervall) ...{'alle': alleNTage, 'ab': ab},
  };

  static Rhythmus? fromJson(Object? v) {
    if (v is! Map) return null;
    final art = RhythmusArt.tolerant(v['art']);
    if (art == null) return null;
    final r = switch (art) {
      RhythmusArt.taeglich => const Rhythmus.taeglich(),
      RhythmusArt.bedarf => const Rhythmus.bedarf(),
      RhythmusArt.wochentage => v['tage'] is List && (v['tage'] as List).every((t) => t is int) ? Rhythmus.wochentage({...(v['tage'] as List).cast<int>()}) : null,
      RhythmusArt.intervall => v['alle'] is int && v['ab'] is String ? Rhythmus.intervall(v['alle'] as int, ab: v['ab'] as String) : null,
    };
    return r != null && r.gueltig ? r : null;
  }

  @override
  bool operator ==(Object other) => other is Rhythmus && other.art == art && other.alleNTage == alleNTage && other.ab == ab && _gleich(other.wochentage, wochentage);

  @override
  int get hashCode => Object.hash(art, alleNTage, ab, Object.hashAllUnordered(wochentage));

  static bool _gleich(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);
}

// ---------------------------------------------------------------- Medikament

enum MedikamentZustand {
  aktiv('a'),
  pausiert('p'),
  beendet('e');

  final String wire;
  const MedikamentZustand(this.wire);
  static MedikamentZustand? tolerant(Object? v) {
    for (final z in values) {
      if (z.wire == v) return z;
    }
    return null;
  }
}

/// Der Inhalt eines Medikaments (Klartext `m1:`), ohne Bezug zu Zeile, Person und Konversation (die stehen in [MedikamentAnsicht]).
class MedikamentInhalt {
  final String name;
  final String dosis;
  final Rhythmus rhythmus;

  /// Uhrzeiten (`HH:MM`, aufsteigend, eindeutig); leer bei "nur bei Bedarf".
  final List<String> zeiten;

  /// Menge je Einnahme (Stück, auch halbe).
  final double menge;

  /// Erster und letzter Tag der Einnahme (`YYYY-MM-DD`, beide inklusive), z. B. für eine Kur; null = unbegrenzt.
  final String? beginn;
  final String? ende;
  final MedikamentZustand zustand;

  /// Ab wann der Zustand gilt (`YYYY-MM-DD`, null = ab sofort/immer) und bis wann eine Pause dauert (inklusive; null = bis zur Wiederaufnahme).
  final String? zustandAb;
  final String? pauseBis;

  /// Vorrat: [bestand] Stück zum Zeitpunkt [bestandStand] (UTC), [packung] Stück je Packung. Der aktuelle Stand wird aus den Einnahmen danach berechnet (medikament_logik.dart).
  final double? bestand;
  final DateTime? bestandStand;
  final double? packung;

  /// Datum des letzten Rezepts (`YYYY-MM-DD`) und freie Notiz.
  final String? rezeptDatum;
  final String notiz;

  const MedikamentInhalt({
    required this.name,
    this.dosis = '',
    this.rhythmus = const Rhythmus.taeglich(),
    this.zeiten = const [],
    this.menge = 1,
    this.beginn,
    this.ende,
    this.zustand = MedikamentZustand.aktiv,
    this.zustandAb,
    this.pauseBis,
    this.bestand,
    this.bestandStand,
    this.packung,
    this.rezeptDatum,
    this.notiz = '',
  });

  MedikamentInhalt kopie({
    String? name,
    String? dosis,
    Rhythmus? rhythmus,
    List<String>? zeiten,
    double? menge,
    String? Function()? beginn,
    String? Function()? ende,
    MedikamentZustand? zustand,
    String? Function()? zustandAb,
    String? Function()? pauseBis,
    double? Function()? bestand,
    DateTime? Function()? bestandStand,
    double? Function()? packung,
    String? Function()? rezeptDatum,
    String? notiz,
  }) => MedikamentInhalt(
    name: name ?? this.name,
    dosis: dosis ?? this.dosis,
    rhythmus: rhythmus ?? this.rhythmus,
    zeiten: zeiten ?? this.zeiten,
    menge: menge ?? this.menge,
    beginn: beginn != null ? beginn() : this.beginn,
    ende: ende != null ? ende() : this.ende,
    zustand: zustand ?? this.zustand,
    zustandAb: zustandAb != null ? zustandAb() : this.zustandAb,
    pauseBis: pauseBis != null ? pauseBis() : this.pauseBis,
    bestand: bestand != null ? bestand() : this.bestand,
    bestandStand: bestandStand != null ? bestandStand() : this.bestandStand,
    packung: packung != null ? packung() : this.packung,
    rezeptDatum: rezeptDatum != null ? rezeptDatum() : this.rezeptDatum,
    notiz: notiz ?? this.notiz,
  );

  /// Ist der Inhalt in sich stimmig (alles, was [medikamentLesen] beim Lesen verlangt)? Ein ungültiger Inhalt wird nie geschrieben.
  bool get gueltig {
    if (name.trim().isEmpty || name.length > kMaxNameZeichen || dosis.length > kMaxDosisZeichen || notiz.length > kMaxNotizZeichen) return false;
    if (!(menge > 0 && menge <= kMaxMenge) || !rhythmus.gueltig) return false;
    if (zeiten.length > kMaxZeiten || zeiten.any((z) => zeitMinuten(z) == null)) return false;
    // aufsteigend und ohne Doppelte
    for (var i = 1; i < zeiten.length; i++) {
      if (zeiten[i - 1].compareTo(zeiten[i]) >= 0) return false;
    }
    // feste Zeiten brauchen mindestens eine Uhrzeit, "bei Bedarf" keine
    if (rhythmus.festeZeiten ? zeiten.isEmpty : zeiten.isNotEmpty) return false;
    for (final t in [beginn, ende, zustandAb, pauseBis, rezeptDatum]) {
      if (t != null && tagLesen(t) == null) return false;
    }
    if (beginn != null && ende != null && ende!.compareTo(beginn!) < 0) return false;
    if (bestand != null && !(bestand! >= 0 && bestand! <= kMaxBestand)) return false;
    if ((bestand == null) != (bestandStand == null)) return false;
    if (packung != null && !(packung! > 0 && packung! <= kMaxBestand)) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
    'v': kFormatVersion,
    'name': name,
    if (dosis.isNotEmpty) 'dosis': dosis,
    'rhythmus': rhythmus.toJson(),
    'zeiten': zeiten,
    'menge': menge,
    if (beginn != null) 'beginn': beginn,
    if (ende != null) 'ende': ende,
    'zustand': zustand.wire,
    if (zustandAb != null) 'zustandAb': zustandAb,
    if (pauseBis != null) 'pauseBis': pauseBis,
    if (bestand != null) 'bestand': bestand,
    if (bestandStand != null) 'bestandStand': bestandStand!.toUtc().toIso8601String(),
    if (packung != null) 'packung': packung,
    if (rezeptDatum != null) 'rezeptDatum': rezeptDatum,
    if (notiz.isNotEmpty) 'notiz': notiz,
  };

  @override
  bool operator ==(Object other) => other is MedikamentInhalt && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Kodiert ein Medikament als Klartext (`m1:` + JSON); wirft [ArgumentError] bei ungültigem oder zu großem Inhalt (es wird nie etwas Ungültiges geschrieben).
String medikamentKodieren(MedikamentInhalt m) {
  if (!m.gueltig) throw ArgumentError('Ungültiges Medikament');
  final text = '$kPraefixMedikament${jsonEncode(m.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesMedikament) throw ArgumentError('Medikament zu groß');
  return text;
}

/// Liest den Klartext eines Medikaments; null bei kaputtem Text, falschem Typ, unbekannter (neuerer) Version oder ungültigen Werten.
MedikamentInhalt? medikamentLesen(String klar) {
  if (!klar.startsWith(kPraefixMedikament)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixMedikament.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int || (d['v'] as int) < 1 || (d['v'] as int) > kFormatVersion) return null;
  final name = _text(d['name'], kMaxNameZeichen);
  final rhythmus = Rhythmus.fromJson(d['rhythmus']);
  final zustand = MedikamentZustand.tolerant(d['zustand']);
  final menge = _zahl(d['menge'], 0, kMaxMenge, exklusivMin: true);
  if (name == null || rhythmus == null || zustand == null || menge == null) return null;
  if (d['zeiten'] is! List || (d['zeiten'] as List).any((z) => z is! String)) return null;
  final zeiten = (d['zeiten'] as List).cast<String>();
  final dosis = d.containsKey('dosis') ? _text(d['dosis'], kMaxDosisZeichen, leerErlaubt: true) : '';
  final notiz = d.containsKey('notiz') ? _text(d['notiz'], kMaxNotizZeichen, leerErlaubt: true) : '';
  if (dosis == null || notiz == null) return null;
  // ein vorhandenes, aber falsch geformtes Datum ("?") macht den ganzen Inhalt ungültig (gueltig prüft es)
  final Map<Object?, Object?> karte = d;
  String? tag(String k) => karte.containsKey(k) ? (karte[k] is String ? karte[k] as String : '?') : null;
  final bestand = d.containsKey('bestand') ? _zahl(d['bestand'], 0, kMaxBestand) : null;
  final packung = d.containsKey('packung') ? _zahl(d['packung'], 0, kMaxBestand, exklusivMin: true) : null;
  if ((d.containsKey('bestand') && bestand == null) || (d.containsKey('packung') && packung == null)) return null;
  DateTime? stand;
  if (d.containsKey('bestandStand')) {
    stand = d['bestandStand'] is String ? DateTime.tryParse(d['bestandStand'] as String)?.toUtc() : null;
    if (stand == null) return null;
  }
  final m = MedikamentInhalt(
    name: name,
    dosis: dosis,
    rhythmus: rhythmus,
    zeiten: zeiten,
    menge: menge,
    beginn: tag('beginn'),
    ende: tag('ende'),
    zustand: zustand,
    zustandAb: tag('zustandAb'),
    pauseBis: tag('pauseBis'),
    bestand: bestand,
    bestandStand: stand,
    packung: packung,
    rezeptDatum: tag('rezeptDatum'),
    notiz: notiz,
  );
  return m.gueltig ? m : null;
}

// ---------------------------------------------------------------- Einnahme

enum EinnahmeStatus {
  genommen('g'),
  uebersprungen('u');

  final String wire;
  const EinnahmeStatus(this.wire);
  static EinnahmeStatus? tolerant(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// Der Inhalt eines Einnahme-Eintrags (Klartext `n1:`).
class EinnahmeInhalt {
  final EinnahmeStatus status;

  /// Geplanter Slot als Wanduhr der Familienzeitzone (`YYYY-MM-DDTHH:MM`); null bei einer Einnahme außer der Reihe ("bei Bedarf", zusätzlich).
  final String? geplant;

  /// Zeitpunkt der Einnahme bzw. der Entscheidung "übersprungen" (UTC).
  final DateTime um;

  /// Menge in Stück; null = die Menge des Medikaments.
  final double? menge;
  const EinnahmeInhalt({required this.status, required this.um, this.geplant, this.menge});

  bool get gueltig {
    if (geplant != null && (!_slotRegex.hasMatch(geplant!) || tagLesen(geplant!.substring(0, 10)) == null)) return false;
    if (menge != null && !(menge! > 0 && menge! <= kMaxMenge)) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
    'v': kFormatVersion,
    's': status.wire,
    if (geplant != null) 'g': geplant,
    'um': um.toUtc().toIso8601String(),
    if (menge != null) 'm': menge,
  };

  @override
  bool operator ==(Object other) => other is EinnahmeInhalt && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

String einnahmeKodieren(EinnahmeInhalt e) {
  if (!e.gueltig) throw ArgumentError('Ungültige Einnahme');
  final text = '$kPraefixEinnahme${jsonEncode(e.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesEinnahme) throw ArgumentError('Einnahme zu groß');
  return text;
}

EinnahmeInhalt? einnahmeLesen(String klar) {
  if (!klar.startsWith(kPraefixEinnahme)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixEinnahme.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int || (d['v'] as int) < 1 || (d['v'] as int) > kFormatVersion) return null;
  final status = EinnahmeStatus.tolerant(d['s']);
  final um = d['um'] is String ? DateTime.tryParse(d['um'] as String)?.toUtc() : null;
  if (status == null || um == null) return null;
  if (d.containsKey('g') && d['g'] is! String) return null;
  final menge = d.containsKey('m') ? _zahl(d['m'], 0, kMaxMenge, exklusivMin: true) : null;
  if (d.containsKey('m') && menge == null) return null;
  final e = EinnahmeInhalt(status: status, um: um, geplant: d['g'] as String?, menge: menge);
  return e.gueltig ? e : null;
}

// ---------------------------------------------------------------- Ansichten (Zeile + gelesener Inhalt)

/// Ein Medikament mit gelesenem Inhalt. [inhalt] ist null, solange die Hülle nicht lesbar ist ([hinweis] nennt den Grund, nie einen Inhalt).
class MedikamentAnsicht {
  final String id;
  final String konversationId;

  /// Die Person, um deren Medikamente es geht.
  final String subjektId;
  final MedikamentInhalt? inhalt;
  final String? hinweis;
  final DateTime erstelltAt;

  /// Noch nicht vom Server bestätigt (liegt im Ausgang).
  final bool lokalNeu;
  const MedikamentAnsicht({required this.id, required this.konversationId, required this.subjektId, required this.inhalt, this.hinweis, required this.erstelltAt, this.lokalNeu = false});

  bool get lesbar => inhalt != null;
}

/// Eine Einnahme mit gelesenem Inhalt.
class EinnahmeAnsicht {
  final String id;
  final String medikamentId;
  final EinnahmeInhalt? inhalt;
  final String? hinweis;
  final DateTime erstelltAt;
  const EinnahmeAnsicht({required this.id, required this.medikamentId, required this.inhalt, this.hinweis, required this.erstelltAt});

  bool get lesbar => inhalt != null;
}
