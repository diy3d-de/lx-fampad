// Vorsorge und Impfungen (Abschnitt 6p): Modelle und Klartext-Formate. Gesundheitsdaten: alles hier steht beim Server nur in e1-Hüllen (Ende-zu-Ende verschlüsselt).
//
//  - Profil (je Person eines): Klartext `vp1:` + JSON (Geburtsdatum, Geschlecht optional). Im Ausgang lokal `l1:vp1:…`.
//  - Eintrag: Klartext `ve1:` + JSON (Vorlage oder eigener Name, Art, Erledigt-Daten, optional nächstes Datum und Intervall, Vorlauf der Erinnerung, Notiz). Im Ausgang lokal `l1:ve1:…`.
// Der Server liest nichts davon. Unbekannte Versionen (`v` größer als [kVorsorgeFormat]) und kaputte Daten ergeben `null` (nicht lesbar), nie einen Absturz und nie einen Teilinhalt.
import 'dart:convert';

import '../medikamente/medikament_modelle.dart' show tagLesen, tagText;
export '../crypto/huellen_arten.dart' show kArtVorsorgeProfil, kArtVorsorgeEintrag;

/// Version des Klartext-Formats (Feld `v`).
const int kVorsorgeFormat = 1;

const String kPraefixVorsorgeProfil = 'vp1:';
const String kPraefixVorsorgeEintrag = 've1:';

/// Art im AAD der Hülle (`HuellenKontext.art`): Profil `p`, Eintrag `v`. Eine Hülle lässt sich nie als andere Art lesen (die Art ist Teil der Signatur).

const int kMaxVorsorgeNameZeichen = 80;
const int kMaxVorsorgeNotizZeichen = 300;
const int kMaxVorsorgeErledigt = 60;
const int kMaxVorsorgeVorlauf = 365;
const int kStandardVorsorgeVorlauf = 14;
const int kMaxVorsorgeIntervall = 600;
const int kMaxKlartextBytesVorsorgeProfil = 400;
const int kMaxKlartextBytesVorsorgeEintrag = 4000;

enum VorsorgeGeschlecht {
  weiblich('w', 'Weiblich'),
  maennlich('m', 'Männlich'),
  divers('x', 'Divers');

  final String wire;
  final String label;
  const VorsorgeGeschlecht(this.wire, this.label);

  static VorsorgeGeschlecht? tolerant(Object? v) {
    for (final g in values) {
      if (g.wire == v) return g;
    }
    return null;
  }
}

enum VorsorgeArt {
  impfung('i', 'Impfung'),
  vorsorge('v', 'Vorsorge'),
  zahn('z', 'Zahnvorsorge'),
  sonstiges('s', 'Sonstiges');

  final String wire;
  final String label;
  const VorsorgeArt(this.wire, this.label);

  static VorsorgeArt? tolerant(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    return null;
  }
}

String? _text(Object? v, int max, {bool leerErlaubt = false}) {
  if (v is! String || v.length > max) return null;
  if (!leerErlaubt && v.trim().isEmpty) return null;
  return v;
}

// ---------------------------------------------------------------- Profil

class VorsorgeProfilInhalt {
  /// Geburtsdatum als Kalendertag `YYYY-MM-DD`.
  final String geburt;

  /// Nur für geschlechtsabhängige Früherkennung; null = keine Angabe.
  final VorsorgeGeschlecht? geschlecht;
  const VorsorgeProfilInhalt({required this.geburt, this.geschlecht});

  DateTime? get geburtTag => tagLesen(geburt);

  bool get gueltig => geburtTag != null && geburt.compareTo('1900-01-01') >= 0;

  Map<String, dynamic> toJson() => {'v': kVorsorgeFormat, 'geburt': geburt, if (geschlecht != null) 'geschlecht': geschlecht!.wire};

  @override
  bool operator ==(Object other) => other is VorsorgeProfilInhalt && other.geburt == geburt && other.geschlecht == geschlecht;

  @override
  int get hashCode => Object.hash(geburt, geschlecht);
}

String vorsorgeProfilKodieren(VorsorgeProfilInhalt p) {
  if (!p.gueltig) throw ArgumentError('Ungültiges Profil');
  final text = '$kPraefixVorsorgeProfil${jsonEncode(p.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesVorsorgeProfil) throw ArgumentError('Profil zu groß');
  return text;
}

/// Liest den Klartext eines Profils; null bei kaputtem Text, falschem Typ, unbekannter (neuerer) Version oder ungültigen Werten.
VorsorgeProfilInhalt? vorsorgeProfilLesen(String klar) {
  if (!klar.startsWith(kPraefixVorsorgeProfil)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixVorsorgeProfil.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int || (d['v'] as int) < 1 || (d['v'] as int) > kVorsorgeFormat) return null;
  final geburt = d['geburt'];
  if (geburt is! String) return null;
  final g = d.containsKey('geschlecht') ? VorsorgeGeschlecht.tolerant(d['geschlecht']) : null;
  if (d.containsKey('geschlecht') && g == null) return null;
  final p = VorsorgeProfilInhalt(geburt: geburt, geschlecht: g);
  return p.gueltig ? p : null;
}

// ---------------------------------------------------------------- Eintrag

class VorsorgeEintragInhalt {
  /// Kennung einer Vorlage aus dem Katalog (`vorsorge_vorlagen.dart`); null = eigener Eintrag.
  final String? vorlage;

  /// Eigener Name (Pflicht bei eigenen Einträgen; bei Vorlagen nur, wenn der Name angepasst wurde).
  final String name;
  final VorsorgeArt art;

  /// Erledigt-Daten (Kalendertage, aufsteigend, ohne Doppelte).
  final List<String> erledigt;

  /// Von Hand gesetztes nächstes Datum (Vorrang vor der Berechnung).
  final String? naechstes;

  /// Nur eigene Einträge: Wiederholung in Monaten.
  final int? intervallMonate;

  /// Wie viele Tage vor Beginn des Zeitfensters die Erinnerung kommt.
  final int vorlauf;
  final String notiz;

  const VorsorgeEintragInhalt({
    this.vorlage,
    this.name = '',
    required this.art,
    this.erledigt = const [],
    this.naechstes,
    this.intervallMonate,
    this.vorlauf = kStandardVorsorgeVorlauf,
    this.notiz = '',
  });

  VorsorgeEintragInhalt kopie({
    String? name,
    VorsorgeArt? art,
    List<String>? erledigt,
    String? Function()? naechstes,
    int? Function()? intervallMonate,
    int? vorlauf,
    String? notiz,
  }) => VorsorgeEintragInhalt(
    vorlage: vorlage,
    name: name ?? this.name,
    art: art ?? this.art,
    erledigt: erledigt ?? this.erledigt,
    naechstes: naechstes != null ? naechstes() : this.naechstes,
    intervallMonate: intervallMonate != null ? intervallMonate() : this.intervallMonate,
    vorlauf: vorlauf ?? this.vorlauf,
    notiz: notiz ?? this.notiz,
  );

  /// Letztes Erledigt-Datum (null: noch nie).
  DateTime? get letzte => erledigt.isEmpty ? null : tagLesen(erledigt.last);

  bool get gueltig {
    if (vorlage == null && name.trim().isEmpty) return false;
    if (vorlage != null && vorlage!.isEmpty) return false;
    if (name.length > kMaxVorsorgeNameZeichen || notiz.length > kMaxVorsorgeNotizZeichen) return false;
    if (vorlauf < 0 || vorlauf > kMaxVorsorgeVorlauf) return false;
    if (intervallMonate != null && (intervallMonate! < 1 || intervallMonate! > kMaxVorsorgeIntervall)) return false;
    if (erledigt.length > kMaxVorsorgeErledigt || erledigt.any((t) => tagLesen(t) == null)) return false;
    for (var i = 1; i < erledigt.length; i++) {
      if (erledigt[i - 1].compareTo(erledigt[i]) >= 0) return false;
    }
    if (naechstes != null && tagLesen(naechstes) == null) return false;
    return true;
  }

  Map<String, dynamic> toJson() => {
    'v': kVorsorgeFormat,
    if (vorlage != null) 'vorlage': vorlage,
    if (name.isNotEmpty) 'name': name,
    'art': art.wire,
    'erledigt': erledigt,
    if (naechstes != null) 'naechstes': naechstes,
    if (intervallMonate != null) 'intervall': intervallMonate,
    'vorlauf': vorlauf,
    if (notiz.isNotEmpty) 'notiz': notiz,
  };

  @override
  bool operator ==(Object other) =>
      other is VorsorgeEintragInhalt &&
      other.vorlage == vorlage &&
      other.name == name &&
      other.art == art &&
      _gleich(other.erledigt, erledigt) &&
      other.naechstes == naechstes &&
      other.intervallMonate == intervallMonate &&
      other.vorlauf == vorlauf &&
      other.notiz == notiz;

  @override
  int get hashCode => Object.hash(vorlage, name, art, Object.hashAll(erledigt), naechstes, intervallMonate, vorlauf, notiz);
}

bool _gleich(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String vorsorgeEintragKodieren(VorsorgeEintragInhalt e) {
  if (!e.gueltig) throw ArgumentError('Ungültiger Eintrag');
  final text = '$kPraefixVorsorgeEintrag${jsonEncode(e.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesVorsorgeEintrag) throw ArgumentError('Eintrag zu groß');
  return text;
}

/// Liest den Klartext eines Eintrags; null bei kaputtem Text, falschem Typ, unbekannter (neuerer) Version oder ungültigen Werten.
VorsorgeEintragInhalt? vorsorgeEintragLesen(String klar) {
  if (!klar.startsWith(kPraefixVorsorgeEintrag)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixVorsorgeEintrag.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int || (d['v'] as int) < 1 || (d['v'] as int) > kVorsorgeFormat) return null;
  final art = VorsorgeArt.tolerant(d['art']);
  if (art == null) return null;
  final vorlage = d.containsKey('vorlage') ? _text(d['vorlage'], 60) : null;
  if (d.containsKey('vorlage') && vorlage == null) return null;
  final name = d.containsKey('name') ? _text(d['name'], kMaxVorsorgeNameZeichen) : '';
  final notiz = d.containsKey('notiz') ? _text(d['notiz'], kMaxVorsorgeNotizZeichen, leerErlaubt: true) : '';
  if (name == null || notiz == null) return null;
  if (d['erledigt'] is! List || (d['erledigt'] as List).any((t) => t is! String)) return null;
  final erledigt = (d['erledigt'] as List).cast<String>();
  final naechstes = d.containsKey('naechstes') ? (d['naechstes'] is String ? d['naechstes'] as String : '?') : null;
  final intervall = d.containsKey('intervall') ? d['intervall'] : null;
  if (d.containsKey('intervall') && intervall is! int) return null;
  final vorlauf = d.containsKey('vorlauf') ? d['vorlauf'] : kStandardVorsorgeVorlauf;
  if (vorlauf is! int) return null;
  final e = VorsorgeEintragInhalt(
    vorlage: vorlage,
    name: name,
    art: art,
    erledigt: erledigt,
    naechstes: naechstes,
    intervallMonate: intervall as int?,
    vorlauf: vorlauf,
    notiz: notiz,
  );
  return e.gueltig ? e : null;
}

/// Ein Eintrag für die Oberfläche (nicht lesbare haben keinen Inhalt, nur einen Hinweis).
class VorsorgeAnsicht {
  final String id;
  final String konversationId;
  final String subjektId;
  final VorsorgeEintragInhalt? inhalt;
  final String? hinweis;
  final DateTime erstelltAt;
  final bool lokalNeu;
  const VorsorgeAnsicht({required this.id, required this.konversationId, required this.subjektId, this.inhalt, this.hinweis, required this.erstelltAt, this.lokalNeu = false});
}

/// Heutiger Kalendertag als `YYYY-MM-DD` aus einem Datum (Wanduhr des Aufrufers).
String vorsorgeTagText(DateTime t) => tagText(t);
