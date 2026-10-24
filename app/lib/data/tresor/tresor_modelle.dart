// Tresor (Abschnitt 6m): Modelle und Klartext-Format. Zugangsdaten, Ausweis- und Versicherungsnummern, Notfall-Infos: alles hier steht beim Server nur in e1-Hüllen (Ende-zu-Ende
// verschlüsselt, der Server sieht ID, Zeitstempel und Größe, sonst nichts).
//
//  - Eintrag: Klartext `t1:` + JSON (Kategorie, Titel, geordnete Felder je Bezeichnung/Wert/geheim, Notiz, Vorlage, Zeitpunkt der letzten Änderung). Im Ausgang lokal `l1:t1:…`.
//    Hülle: Art `t`. Der Eintrag ist an die Konversation, seine eigene ID und den Bearbeiter gebunden (AAD), nie als andere Art lesbar.
//  - Ein EINZIGER gemeinsamer Tresor für alle Eltern und Admins: kein Besitzer, keine Sichtbarkeit je Eintrag (`bearbeiterId` ist nur der letzte Schreiber).
//  - Keine Dokument-Anhänge in dieser Version (kommen mit dem Dateien-Bereich); das Format ist dafür offen (`v` hochzählen, unbekannte Felder werden beim Lesen ignoriert).
// Unbekannte Versionen (`v` größer als [kTresorFormat]) und kaputte Daten ergeben `null` (nicht lesbar), nie einen Absturz und nie einen Teilinhalt.
import 'dart:convert';

/// Version des Klartext-Formats (Feld `v`).
const int kTresorFormat = 1;

/// Typpräfix des Klartexts (nach dem Hüllenpräfix `l1:` bzw. nach dem Öffnen der Hülle).
const String kPraefixTresor = 't1:';

/// Art im AAD der Hülle (`HuellenKontext.art`): Tresor-Eintrag `t`. Eine Hülle lässt sich nie als andere Art lesen.
const String kArtTresor = 't';

/// Obergrenzen (wie der Server und die Hülle): höchstens so viele Einträge im Tresor, Felder je Eintrag und Byte Klartext je Eintrag (der Server nimmt Hüllen bis 24576 Zeichen an).
const int kMaxTresorEintraege = 500;
const int kMaxTresorFelder = 20;
const int kMaxKlartextBytesTresor = 16000;

/// Obergrenzen der Texte (Zeichen).
const int kMaxTresorTitel = 80;
const int kMaxTresorKategorieName = 30;
const int kMaxTresorBezeichnung = 40;
const int kMaxTresorWert = 1000;
const int kMaxTresorNotiz = 4000;

/// Die Kategorien des Tresors. `eigene` trägt einen frei gewählten Namen ([TresorInhalt.kategorieName]).
enum TresorKategorie {
  notfall('notfall', 'Notfall'),
  dokumente('dokumente', 'Dokumente'),
  zugang('zugang', 'Zugangsdaten'),
  haushalt('haushalt', 'Haushalt'),
  eigene('eigene', 'Eigene');

  final String wire;
  final String anzeige;
  const TresorKategorie(this.wire, this.anzeige);

  static TresorKategorie? tolerant(Object? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// Die Vorlagen beim Anlegen (Felder vorbelegt, siehe `tresor_vorlagen.dart`). Gespeichert wird nur die Kennung, damit die Oberfläche das passende Symbol zeigen kann.
enum TresorVorlage {
  wlan('wlan'),
  versicherung('versicherung'),
  ausweis('ausweis'),
  arzt('arzt'),
  eigener('eigener');

  final String wire;
  const TresorVorlage(this.wire);

  static TresorVorlage? tolerant(Object? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// Ein Feld eines Eintrags: Bezeichnung, Wert und ob der Wert geheim ist (verdeckt anzeigen, nie durchsuchen, nie in Vorschauen).
class TresorFeld {
  final String bezeichnung;
  final String wert;
  final bool geheim;
  const TresorFeld({required this.bezeichnung, this.wert = '', this.geheim = false});

  bool get gueltig => bezeichnung.trim().isNotEmpty && bezeichnung.length <= kMaxTresorBezeichnung && wert.length <= kMaxTresorWert;

  TresorFeld kopie({String? bezeichnung, String? wert, bool? geheim}) => TresorFeld(bezeichnung: bezeichnung ?? this.bezeichnung, wert: wert ?? this.wert, geheim: geheim ?? this.geheim);

  Map<String, Object?> toJson() => {'b': bezeichnung, if (wert.isNotEmpty) 'w': wert, if (geheim) 'g': true};

  static TresorFeld? fromJson(Object? v) {
    if (v is! Map) return null;
    final b = v['b'];
    final w = v.containsKey('w') ? v['w'] : '';
    final g = v.containsKey('g') ? v['g'] : false;
    if (b is! String || w is! String || g is! bool) return null;
    final f = TresorFeld(bezeichnung: b, wert: w, geheim: g);
    return f.gueltig ? f : null;
  }

  @override
  bool operator ==(Object other) => other is TresorFeld && other.bezeichnung == bezeichnung && other.wert == wert && other.geheim == geheim;

  @override
  int get hashCode => Object.hash(bezeichnung, wert, geheim);
}

/// Der Inhalt eines Tresor-Eintrags (nur im Klartext auf dem Gerät).
class TresorInhalt {
  final TresorKategorie kategorie;

  /// Name der eigenen Kategorie (nur bei [TresorKategorie.eigene], dort Pflicht; sonst leer).
  final String kategorieName;
  final String titel;
  final List<TresorFeld> felder;
  final String notiz;
  final TresorVorlage? vorlage;

  /// Zeitpunkt der letzten Änderung (Millisekunden seit 1970, UTC) auf dem Gerät der schreibenden Person; 0 = unbekannt.
  final int geaendert;

  const TresorInhalt({
    required this.kategorie,
    this.kategorieName = '',
    required this.titel,
    this.felder = const [],
    this.notiz = '',
    this.vorlage,
    this.geaendert = 0,
  });

  /// Anzeigename der Kategorie (bei `eigene` der gewählte Name).
  String get kategorieAnzeige => kategorie == TresorKategorie.eigene && kategorieName.trim().isNotEmpty ? kategorieName.trim() : kategorie.anzeige;

  /// Ist der Inhalt in sich stimmig (alles, was [tresorLesen] beim Lesen verlangt)? Ein ungültiger Inhalt wird nie geschrieben. Die Größe prüft [tresorKodieren].
  bool get gueltig {
    if (titel.trim().isEmpty || titel.length > kMaxTresorTitel) return false;
    if (kategorie == TresorKategorie.eigene) {
      if (kategorieName.trim().isEmpty || kategorieName.length > kMaxTresorKategorieName) return false;
    } else if (kategorieName.isNotEmpty) {
      return false;
    }
    if (felder.length > kMaxTresorFelder || felder.any((f) => !f.gueltig)) return false;
    if (notiz.length > kMaxTresorNotiz) return false;
    if (geaendert < 0 || geaendert > 4503599627370496) return false;
    return true;
  }

  TresorInhalt kopie({
    TresorKategorie? kategorie,
    String? kategorieName,
    String? titel,
    List<TresorFeld>? felder,
    String? notiz,
    TresorVorlage? Function()? vorlage,
    int? geaendert,
  }) {
    final neueKategorie = kategorie ?? this.kategorie;
    return TresorInhalt(
      kategorie: neueKategorie,
      // der Name gehört nur zu `eigene`: wer die Kategorie wechselt, verliert ihn
      kategorieName: neueKategorie == TresorKategorie.eigene ? (kategorieName ?? this.kategorieName) : '',
      titel: titel ?? this.titel,
      felder: felder ?? this.felder,
      notiz: notiz ?? this.notiz,
      vorlage: vorlage != null ? vorlage() : this.vorlage,
      geaendert: geaendert ?? this.geaendert,
    );
  }

  Map<String, Object?> toJson() => {
    'v': kTresorFormat,
    'kat': kategorie.wire,
    if (kategorie == TresorKategorie.eigene) 'kn': kategorieName,
    't': titel,
    'f': [for (final f in felder) f.toJson()],
    if (notiz.isNotEmpty) 'n': notiz,
    if (vorlage != null) 'vl': vorlage!.wire,
    'g': geaendert,
  };

  @override
  bool operator ==(Object other) =>
      other is TresorInhalt &&
      other.kategorie == kategorie &&
      other.kategorieName == kategorieName &&
      other.titel == titel &&
      other.notiz == notiz &&
      other.vorlage == vorlage &&
      other.geaendert == geaendert &&
      other.felder.length == felder.length &&
      [for (var i = 0; i < felder.length; i++) felder[i] == other.felder[i]].every((x) => x);

  @override
  int get hashCode => Object.hash(kategorie, kategorieName, titel, notiz, vorlage, geaendert, Object.hashAll(felder));
}

/// Klartext eines Eintrags (`t1:` + JSON). Ein ungültiger Inhalt ([ArgumentError]) oder ein zu großer (mehr als [kMaxKlartextBytesTresor] Byte) wird nie geschrieben.
String tresorKodieren(TresorInhalt t) {
  if (!t.gueltig) throw ArgumentError('Ungültiger Tresor-Eintrag');
  final text = '$kPraefixTresor${jsonEncode(t.toJson())}';
  if (utf8.encode(text).length > kMaxKlartextBytesTresor) throw ArgumentError('Tresor-Eintrag zu groß');
  return text;
}

/// Liest den Klartext eines Eintrags; null bei kaputtem Text, falschem Typ, unbekannter (neuerer) Version oder ungültigen Werten.
TresorInhalt? tresorLesen(String klar) {
  if (!klar.startsWith(kPraefixTresor)) return null;
  final Object? d;
  try {
    d = jsonDecode(klar.substring(kPraefixTresor.length));
  } on FormatException {
    return null;
  }
  if (d is! Map || d['v'] is! int || (d['v'] as int) < 1 || (d['v'] as int) > kTresorFormat) return null;
  final kat = TresorKategorie.tolerant(d['kat']);
  final titel = d['t'];
  final kn = d.containsKey('kn') ? d['kn'] : '';
  final notiz = d.containsKey('n') ? d['n'] : '';
  final g = d['g'];
  if (kat == null || titel is! String || kn is! String || notiz is! String || g is! int) return null;
  final felder = <TresorFeld>[];
  final f = d['f'];
  if (f is! List) return null;
  for (final e in f) {
    final feld = TresorFeld.fromJson(e);
    if (feld == null) return null;
    felder.add(feld);
  }
  TresorVorlage? vorlage;
  if (d.containsKey('vl')) {
    vorlage = TresorVorlage.tolerant(d['vl']); // eine unbekannte (neuere) Vorlage ist nur ein Symbol: der Eintrag bleibt lesbar
  }
  final t = TresorInhalt(kategorie: kat, kategorieName: kn, titel: titel, felder: felder, notiz: notiz, vorlage: vorlage, geaendert: g);
  return t.gueltig ? t : null;
}
