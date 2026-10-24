// Vorhersage und amtliche Warnungen des Deutschen Wetterdienstes: Modelle der Antwort von `GET /weather/forecast`. Alles tolerant: ein Wert, den die App nicht
// versteht, wird übersprungen (nie die ganze Vorhersage verworfen), unbekannte Symbole werden "unbekannt", ältere Server ohne die Route ergeben "keine Vorhersage".
// Der Server liefert nie Koordinaten oder Quelle-Adressen; die Quelle steht nur als Name ("Deutscher Wetterdienst").
import 'package:flutter/foundation.dart' show immutable;

/// Feste Symbolcodes des Servers (nie Bilder von außen).
enum WetterSymbol {
  sonne('sonne', 'sonnig'),
  nacht('nacht', 'klare Nacht'),
  teils('teils', 'teils bewölkt'),
  teilsNacht('teils-nacht', 'teils bewölkt'),
  wolken('wolken', 'bewölkt'),
  nebel('nebel', 'neblig'),
  wind('wind', 'windig'),
  regen('regen', 'Regen'),
  schneeregen('schneeregen', 'Schneeregen'),
  schnee('schnee', 'Schnee'),
  hagel('hagel', 'Hagel'),
  gewitter('gewitter', 'Gewitter'),
  unbekannt('unbekannt', 'unbekannt');

  final String code;
  final String text;
  const WetterSymbol(this.code, this.text);

  static WetterSymbol von(Object? v) {
    for (final s in values) {
      if (s.code == v) return s;
    }
    return unbekannt;
  }
}

/// Feste Arten der amtlichen Warnungen.
enum WarnArt {
  gewitter('gewitter'),
  wind('wind'),
  regen('regen'),
  schnee('schnee'),
  glaette('glaette'),
  frost('frost'),
  hitze('hitze'),
  nebel('nebel'),
  uv('uv'),
  tauwetter('tauwetter'),
  sonst('sonst');

  final String code;
  const WarnArt(this.code);

  static WarnArt von(Object? v) {
    for (final a in values) {
      if (a.code == v) return a;
    }
    return sonst;
  }
}

double? _zahl(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _ganz(Object? v) => v is num && v.isFinite ? v.round() : null;

@immutable
class VorhersageTag {
  /// Kalendertag (Familienzone), nur Datum.
  final DateTime datum;
  final double min;
  final double max;
  final double regenMm;

  /// Regenwahrscheinlichkeit in Prozent; null = nicht angegeben.
  final int? regenProzent;
  final int? windKmh;
  final int? boeKmh;
  final WetterSymbol symbol;
  const VorhersageTag({
    required this.datum,
    required this.min,
    required this.max,
    required this.regenMm,
    this.regenProzent,
    this.windKmh,
    this.boeKmh,
    required this.symbol,
  });

  static final _datum = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  static VorhersageTag? versuche(Object? raw) {
    if (raw is! Map) return null;
    final d = raw['date'];
    final m = d is String ? _datum.firstMatch(d) : null;
    final min = _zahl(raw['min']);
    final max = _zahl(raw['max']);
    if (m == null || min == null || max == null) return null;
    return VorhersageTag(
      datum: DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)),
      min: min,
      max: max < min ? min : max,
      regenMm: _zahl(raw['rain']) ?? 0,
      regenProzent: _ganz(raw['pop']),
      windKmh: _ganz(raw['windKmh']),
      boeKmh: _ganz(raw['gustKmh']),
      symbol: WetterSymbol.von(raw['symbol']),
    );
  }
}

@immutable
class VorhersageStunde {
  /// Beginn der Stunde (lokal dargestellt).
  final DateTime zeit;
  final double temperatur;
  final double regenMm;
  final int? regenProzent;
  final int? windKmh;
  final int? boeKmh;
  final WetterSymbol symbol;
  const VorhersageStunde({
    required this.zeit,
    required this.temperatur,
    required this.regenMm,
    this.regenProzent,
    this.windKmh,
    this.boeKmh,
    required this.symbol,
  });

  static VorhersageStunde? versuche(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['t'];
    final zeit = t is String ? DateTime.tryParse(t) : null;
    final temp = _zahl(raw['temp']);
    if (zeit == null || temp == null) return null;
    return VorhersageStunde(
      zeit: zeit.toLocal(),
      temperatur: temp,
      regenMm: _zahl(raw['rain']) ?? 0,
      regenProzent: _ganz(raw['pop']),
      windKmh: _ganz(raw['windKmh']),
      boeKmh: _ganz(raw['gustKmh']),
      symbol: WetterSymbol.von(raw['symbol']),
    );
  }
}

@immutable
class WetterWarnung {
  /// DWD-Stufe 1 bis 4 (Wetterwarnung, markant, Unwetter, extrem).
  final int stufe;
  final WarnArt art;
  final String titel;
  final String text;
  final DateTime von;
  final DateTime? bis;
  const WetterWarnung({
    required this.stufe,
    required this.art,
    required this.titel,
    required this.text,
    required this.von,
    this.bis,
  });

  static WetterWarnung? versuche(Object? raw) {
    if (raw is! Map) return null;
    final stufe = _ganz(raw['level']);
    final von = raw['from'] is String ? DateTime.tryParse(raw['from'] as String) : null;
    if (stufe == null || stufe < 1 || stufe > 4 || von == null) return null;
    final bis = raw['until'] is String ? DateTime.tryParse(raw['until'] as String) : null;
    final titel = raw['title'];
    final text = raw['text'];
    return WetterWarnung(
      stufe: stufe,
      art: WarnArt.von(raw['kind']),
      titel: titel is String && titel.trim().isNotEmpty ? titel.trim() : 'Wetterwarnung',
      text: text is String ? text.trim() : '',
      von: von.toLocal(),
      bis: bis?.toLocal(),
    );
  }
}

@immutable
class VorhersageTeil {
  final DateTime aktualisiert;

  /// Laut Server veraltet (älter als 12 Stunden); die App rechnet bei einem Offline-Stand selbst nach (`vorhersageVeraltet`).
  final bool veraltet;
  final List<VorhersageTag> tage;
  final List<VorhersageStunde> stunden;
  const VorhersageTeil({required this.aktualisiert, required this.veraltet, required this.tage, required this.stunden});
}

@immutable
class WarnungenTeil {
  final DateTime aktualisiert;
  final bool veraltet;
  final List<WetterWarnung> items;
  const WarnungenTeil({required this.aktualisiert, required this.veraltet, required this.items});
}

@immutable
class VorhersageDto {
  /// Der Server hat Wetter und Vorhersage eingeschaltet.
  final bool verfuegbar;
  final String quelle;
  final VorhersageTeil? vorhersage;
  final WarnungenTeil? warnungen;
  const VorhersageDto({required this.verfuegbar, this.quelle = 'Deutscher Wetterdienst', this.vorhersage, this.warnungen});

  static const nichtVerfuegbar = VorhersageDto(verfuegbar: false);

  /// Nie ein Fehler: alles, was nicht passt, ergibt "nicht verfügbar" bzw. fehlende Teile.
  factory VorhersageDto.fromJson(Object? raw) {
    if (raw is! Map || raw['available'] != true) return nichtVerfuegbar;
    final q = raw['source'];
    var quelle = q is String && q.trim().isNotEmpty && q.length <= 60 ? q.trim() : 'Deutscher Wetterdienst';
    if (quelle.contains('<') || quelle.contains('>')) quelle = 'Deutscher Wetterdienst';
    VorhersageTeil? vorhersage;
    final f = raw['forecast'];
    if (f is Map) {
      final t = f['updatedAt'] is String ? DateTime.tryParse(f['updatedAt'] as String) : null;
      final tage = <VorhersageTag>[
        if (f['days'] is List)
          for (final e in f['days'] as List)
            ?VorhersageTag.versuche(e),
      ];
      final stunden = <VorhersageStunde>[
        if (f['hours'] is List)
          for (final e in f['hours'] as List)
            ?VorhersageStunde.versuche(e),
      ];
      if (t != null && tage.isNotEmpty) {
        vorhersage = VorhersageTeil(aktualisiert: t.toLocal(), veraltet: f['stale'] == true, tage: tage, stunden: stunden);
      }
    }
    WarnungenTeil? warnungen;
    final w = raw['warnings'];
    if (w is Map) {
      final t = w['updatedAt'] is String ? DateTime.tryParse(w['updatedAt'] as String) : null;
      if (t != null) {
        warnungen = WarnungenTeil(
          aktualisiert: t.toLocal(),
          veraltet: w['stale'] == true,
          items: [
            if (w['items'] is List)
              for (final e in w['items'] as List)
                ?WetterWarnung.versuche(e),
          ],
        );
      }
    }
    return VorhersageDto(verfuegbar: true, quelle: quelle, vorhersage: vorhersage, warnungen: warnungen);
  }
}
