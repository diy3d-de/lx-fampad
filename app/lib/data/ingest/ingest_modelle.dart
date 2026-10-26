// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), Antworten des Servers (docs/API.md "Einwurf (Home Assistant)"). Tolerant bei zusätzlichen Feldern, streng bei Pflichtfeldern;
// ein Eintrag, den die App nicht versteht, wird übersprungen. Der Server sieht nur undurchsichtige Päckchen: hier steht nie ein Wert.
import '../api/api_error.dart';
import '../api/models.dart';

Never _fehler() => throw ApiException.unerwarteteAntwort;

String _s(Json m, String k) => m[k] is String ? m[k] as String : _fehler();

DateTime? _zeit(Json m, String k) {
  final v = m[k];
  if (v == null) return null;
  return v is String ? (DateTime.tryParse(v) ?? _fehler()) : _fehler();
}

/// Eine Verbindung von Home Assistant (ein Einwurf-Token). Nie der Klartext des Tokens.
class IngestToken {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;
  const IngestToken({required this.id, required this.name, required this.createdAt, this.lastUsedAt, this.revokedAt});

  bool get aktiv => revokedAt == null;

  factory IngestToken.fromJson(Object? raw) {
    final m = asJson(raw);
    return IngestToken(id: _s(m, 'id'), name: _s(m, 'name'), createdAt: _zeit(m, 'createdAt') ?? _fehler(), lastUsedAt: _zeit(m, 'lastUsedAt'), revokedAt: _zeit(m, 'revokedAt'));
  }
}

/// Antwort von `POST /ingest/tokens`: das Klartext-Token steht NUR hier (und im Kopplungscode); nie speichern oder loggen.
class IngestTokenNeu {
  final String token;
  final IngestToken eintrag;
  const IngestTokenNeu(this.token, this.eintrag);

  factory IngestTokenNeu.fromJson(Object? raw) {
    final m = asJson(raw);
    return IngestTokenNeu(_s(m, 'token'), IngestToken.fromJson(m));
  }
}

/// Ein abholbares Päckchen: undurchsichtige Box (Base64) mit ihrer Kennung.
class IngestPaket {
  final String id;
  final String box;
  final DateTime? empfangen;
  const IngestPaket({required this.id, required this.box, this.empfangen});

  factory IngestPaket.fromJson(Object? raw) {
    final m = asJson(raw);
    return IngestPaket(id: _s(m, 'id'), box: _s(m, 'box'), empfangen: _zeit(m, 'receivedAt'));
  }
}

/// Eine Seite von `GET /ingest/zaehler/pending`; [next] null = die letzte Seite.
class IngestSeite {
  final List<IngestPaket> pakete;
  final String? next;
  const IngestSeite(this.pakete, this.next);

  factory IngestSeite.fromJson(Object? raw) {
    final m = asJson(raw);
    final n = m['next'];
    if (n != null && n is! String && n is! int) _fehler();
    return IngestSeite(parseListe(m['items'], IngestPaket.fromJson), n?.toString());
  }
}
