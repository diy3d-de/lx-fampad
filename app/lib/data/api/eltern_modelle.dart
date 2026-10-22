// Modelle der Eltern-Wiederherstellung für Kinder (docs/API.md, "Eltern-Wiederherstellung"; nur mit Schalter des Servers). Streng bei Pflichtfeldern, tolerant bei zusätzlichen
// Feldern; alles Undurchsichtige (Blobs, Signaturen, Zufallszahlen) bleibt Text, den nur die Krypto-Bausteine (data/crypto/eltern_wiederherstellung.dart) lesen.
import 'api_error.dart';
import 'models.dart' show asJson;

Never _fehler() => throw ApiException.unerwarteteAntwort;

String _s(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v is String && v.isNotEmpty ? v : _fehler();
}

String? _sn(Map<String, dynamic> m, String k) {
  final v = m[k];
  if (v == null) return null;
  return v is String ? v : _fehler();
}

int _i(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v is int ? v : _fehler();
}

DateTime _t(Map<String, dynamic> m, String k) => DateTime.tryParse(_s(m, k)) ?? _fehler();

/// Zustand einer Anfrage zur Wiederherstellung (Server: pending, challenged, revealed, released, done, cancelled, declined, expired).
enum AnfrageZustand {
  /// Verpflichtung abgelegt, die Wartefrist läuft.
  wartet,

  /// Ein Elternteil hat die Anfrage übernommen: das Kind legt jetzt den flüchtigen Schlüssel offen.
  uebernommen,

  /// Offengelegt: der Kurzcode steht, das Elternteil prüft ihn.
  offengelegt,

  /// Das Elternteil hat die Übergabe abgelegt: das Kind übernimmt den Schlüssel.
  freigegeben,
  fertig,
  abgebrochen,
  abgelehnt,
  abgelaufen;

  static AnfrageZustand parse(Object? v) => switch (v) {
    'pending' => AnfrageZustand.wartet,
    'challenged' => AnfrageZustand.uebernommen,
    'revealed' => AnfrageZustand.offengelegt,
    'released' => AnfrageZustand.freigegeben,
    'done' => AnfrageZustand.fertig,
    'cancelled' => AnfrageZustand.abgebrochen,
    'declined' => AnfrageZustand.abgelehnt,
    'expired' => AnfrageZustand.abgelaufen,
    _ => _fehler(),
  };

  /// Läuft die Anfrage noch?
  bool get offen => this == wartet || this == uebernommen || this == offengelegt || this == freigegeben;
}

/// Ein Elternteil mit Hinterlegung (nur Namen, Versionen, nie Blobs).
class HinterlegtesElternteil {
  final String id;
  final String name;
  final int schluesselVersion;

  /// Der Eintrag ist veraltet (Schlüssel des Kindes oder des Elternteils hat sich geändert): "Hinterlegung aktualisieren".
  final bool veraltet;
  const HinterlegtesElternteil({required this.id, required this.name, required this.schluesselVersion, required this.veraltet});
}

/// `GET /me/guardian-escrow`.
class HinterlegungStand {
  /// Die Person darf die Funktion überhaupt nutzen (Rolle Kind).
  final bool berechtigt;
  final bool aktiv;
  final DateTime? seit;
  final int? schluesselVersion;
  final List<HinterlegtesElternteil> eltern;
  const HinterlegungStand({required this.berechtigt, required this.aktiv, this.seit, this.schluesselVersion, this.eltern = const []});

  static const keine = HinterlegungStand(berechtigt: false, aktiv: false);

  factory HinterlegungStand.fromJson(Object? raw) {
    final m = asJson(raw);
    final g = m['guardians'];
    final seit = m['since'];
    return HinterlegungStand(
      berechtigt: m['eligible'] == true,
      aktiv: m['enabled'] == true,
      seit: seit is String ? DateTime.tryParse(seit) : null,
      schluesselVersion: m['keyVersion'] is int ? m['keyVersion'] as int : null,
      eltern: g is List
          ? [
              for (final e in g)
                if (e is Map<String, dynamic> && e['id'] is String && e['displayName'] is String && e['guardianKeyVersion'] is int)
                  HinterlegtesElternteil(id: e['id'] as String, name: e['displayName'] as String, schluesselVersion: e['guardianKeyVersion'] as int, veraltet: e['stale'] != false),
            ]
          : const [],
    );
  }
}

/// Eine Anfrage aus Sicht des Kindes (`GET /me/guardian-recovery`, `POST /me/guardian-recovery`).
class AnfrageDto {
  final String id;
  final AnfrageZustand zustand;
  final int schluesselVersion;
  final DateTime bereitAb;
  final DateTime laeuftAb;

  /// Verpflichtung, die der Server für diese Anfrage führt (aus Sicht des Kindes: die eigene; null bei älteren Antworten).
  final String? commit;
  final String? elternteilId;
  final String? elternteilName;

  /// Zufallszahl des Elternteils (ab "übernommen").
  final String? challenge;

  /// Übergabe des Elternteils (nur "freigegeben", nur für das Kind).
  final String? freigabeBlob;
  final String? freigabeSig;
  const AnfrageDto({
    required this.id,
    required this.zustand,
    required this.schluesselVersion,
    required this.bereitAb,
    required this.laeuftAb,
    this.commit,
    this.elternteilId,
    this.elternteilName,
    this.challenge,
    this.freigabeBlob,
    this.freigabeSig,
  });

  factory AnfrageDto.fromJson(Object? raw) {
    final m = asJson(raw);
    return AnfrageDto(
      id: _s(m, 'id'),
      zustand: AnfrageZustand.parse(m['state']),
      schluesselVersion: _i(m, 'keyVersion'),
      bereitAb: _t(m, 'readyAt'),
      laeuftAb: _t(m, 'expiresAt'),
      commit: _sn(m, 'commit'),
      elternteilId: _sn(m, 'guardianId'),
      elternteilName: _sn(m, 'guardianName'),
      challenge: _sn(m, 'challenge'),
      freigabeBlob: _sn(m, 'releaseBlob'),
      freigabeSig: _sn(m, 'releaseSig'),
    );
  }

  /// Die Wartefrist ist vorbei: ein Elternteil darf übernehmen.
  bool bereit(DateTime jetzt) => !jetzt.isBefore(bereitAb);
}

/// Ein Kind, für das dieses Elternteil helfen kann.
class HilfeKind {
  final String id;
  final String name;
  final bool veraltet;
  const HilfeKind({required this.id, required this.name, required this.veraltet});
}

/// Eine Anfrage aus Sicht eines Elternteils.
class HilfeAnfrage {
  final AnfrageDto anfrage;
  final String kindId;
  final String kindName;

  /// Verpflichtung des Kindes auf seinen flüchtigen Schlüssel.
  final String verpflichtung;

  /// Offengelegter flüchtiger Schlüssel und Nonce (nur für das übernehmende Elternteil, ab "offengelegt").
  final String? offenerSchluessel;
  final String? offeneNonce;

  /// Der Eintrag dieses Elternteils (nur für das übernehmende Elternteil im Zustand "offengelegt", sonst null).
  final String? hinterlegungBlob;
  final String? hinterlegungSig;
  final int? hinterlegungKindVersion;
  final int? hinterlegungElternVersion;
  const HilfeAnfrage({
    required this.anfrage,
    required this.kindId,
    required this.kindName,
    required this.verpflichtung,
    this.offenerSchluessel,
    this.offeneNonce,
    this.hinterlegungBlob,
    this.hinterlegungSig,
    this.hinterlegungKindVersion,
    this.hinterlegungElternVersion,
  });

  factory HilfeAnfrage.fromJson(Object? raw) {
    final m = asJson(raw);
    final e = m['escrow'];
    final em = e is Map<String, dynamic> ? e : null;
    return HilfeAnfrage(
      anfrage: AnfrageDto.fromJson(m),
      kindId: _s(m, 'childId'),
      kindName: _s(m, 'childName'),
      verpflichtung: _s(m, 'commit'),
      offenerSchluessel: _sn(m, 'revealPub'),
      offeneNonce: _sn(m, 'revealNonce'),
      hinterlegungBlob: em == null ? null : _s(em, 'blob'),
      hinterlegungSig: em == null ? null : _s(em, 'sig'),
      hinterlegungKindVersion: em == null ? null : _i(em, 'keyVersion'),
      hinterlegungElternVersion: em == null ? null : _i(em, 'guardianKeyVersion'),
    );
  }
}

/// `GET /guardian/recoveries`.
class HilfeUebersicht {
  final List<HilfeKind> kinder;
  final List<HilfeAnfrage> anfragen;
  const HilfeUebersicht({required this.kinder, required this.anfragen});

  static const leer = HilfeUebersicht(kinder: [], anfragen: []);

  factory HilfeUebersicht.fromJson(Object? raw) {
    final m = asJson(raw);
    final k = m['children'];
    final a = m['requests'];
    return HilfeUebersicht(
      kinder: k is List
          ? [
              for (final e in k)
                if (e is Map<String, dynamic> && e['id'] is String && e['displayName'] is String) HilfeKind(id: e['id'] as String, name: e['displayName'] as String, veraltet: e['stale'] != false),
            ]
          : const [],
      anfragen: a is List ? [for (final e in a) HilfeAnfrage.fromJson(e)] : const [],
    );
  }
}
