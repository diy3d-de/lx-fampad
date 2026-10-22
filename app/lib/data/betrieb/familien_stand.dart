// Betrieb, Paket 2b: Wartungsmodus, Familienhinweis und Konfiguration (Modelle zu `GET /family-notice`, `GET /admin/settings` und `GET /admin/config`).
// Die Auswertung ist tolerant: unbekannte Felder und Werte einer neueren Server-Version werden ignoriert, nie ein Absturz. Angezeigt wird nie ein Servertext
// außer dem Hinweistext des Betreibers selbst (reiner Text, nie Markup, in der Länge begrenzt).
import '../api/models.dart';

String? _text(Object? v) => v is String ? v : null;
DateTime? _zeit(Object? v) => v is String ? DateTime.tryParse(v) : null;
Json _map(Object? v) => v is Map<String, dynamic> ? v : const <String, dynamic>{};

/// Längster Hinweistext, den die App anzeigt (der Server erlaubt 280 Zeichen).
const kHinweisMaxZeichen = 280;

/// Wartungsmodus laut Server (`maintenance`).
class WartungStand {
  final bool aktiv;
  final DateTime? seit;

  /// Automatisches Ende (null: bis der Betreiber ausschaltet).
  final DateTime? bis;
  const WartungStand({this.aktiv = false, this.seit, this.bis});

  factory WartungStand.fromJson(Object? raw) {
    final m = _map(raw);
    return WartungStand(aktiv: m['active'] == true, seit: _zeit(m['since']), bis: _zeit(m['until']));
  }
}

/// Der Familienhinweis des Betreibers (reiner Text). [version] ist der Zeitpunkt des Setzens: daran merkt sich ein Gerät, was weggeklickt wurde.
class FamilienHinweis {
  final String text;
  final DateTime version;
  final DateTime? ablauf;
  const FamilienHinweis({required this.text, required this.version, this.ablauf});

  static FamilienHinweis? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final text = _text(raw['text'])?.trim();
    final version = _zeit(raw['setAt']);
    // eine unbrauchbare Angabe (kein Text, überlang, keine Version) zeigt die App nicht
    if (text == null || text.isEmpty || text.runes.length > kHinweisMaxZeichen || version == null) return null;
    return FamilienHinweis(text: text, version: version, ablauf: _zeit(raw['expiresAt']));
  }
}

/// `GET /family-notice` (für alle Angemeldeten) und `GET /admin/settings` (Betreiber): Wartung und Hinweis.
class FamilienStand {
  final WartungStand wartung;
  final FamilienHinweis? hinweis;
  const FamilienStand({this.wartung = const WartungStand(), this.hinweis});

  factory FamilienStand.fromJson(Object? raw) {
    final m = asJson(raw);
    return FamilienStand(wartung: WartungStand.fromJson(m['maintenance']), hinweis: FamilienHinweis.versuchen(m['notice']));
  }
}

/// Ein Wert der Konfigurationsansicht: Name der Umgebungsvariablen (oder feste Kennung), Wert (Schalter, Zahl oder kurzer Text) und Einheit.
class KonfigWert {
  final String key;
  final Object? wert;
  final String? einheit;
  const KonfigWert({required this.key, required this.wert, this.einheit});

  static KonfigWert? versuchen(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final key = _text(raw['key']);
    if (key == null || key.isEmpty || key.length > 80) return null;
    final v = raw['value'];
    final wert = v is bool || (v is String && v.length <= 80) || (v is num && v.isFinite) ? v : null;
    return KonfigWert(key: key, wert: wert, einheit: _text(raw['unit']));
  }
}

class KonfigGruppe {
  final String id;
  final List<KonfigWert> werte;
  const KonfigGruppe({required this.id, required this.werte});
}

/// `GET /admin/config`
class BetriebKonfiguration {
  final List<KonfigGruppe> gruppen;
  const BetriebKonfiguration(this.gruppen);

  factory BetriebKonfiguration.fromJson(Object? raw) {
    final m = asJson(raw);
    final gruppen = <KonfigGruppe>[];
    if (m['groups'] is List) {
      for (final g in m['groups'] as List) {
        if (g is! Map<String, dynamic>) continue;
        final id = _text(g['id']);
        if (id == null) continue;
        gruppen.add(KonfigGruppe(id: id, werte: [if (g['items'] is List) for (final i in g['items'] as List) ?KonfigWert.versuchen(i)]));
      }
    }
    return BetriebKonfiguration(gruppen);
  }
}
