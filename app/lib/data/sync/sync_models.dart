// Nachrichten des Sync-Protokolls (POST /api/v1/sync, docs/API.md). Parsing streng bei Pflichtfeldern, tolerant bei zusätzlichen
// Feldern und unbekannten Ablehnungsgründen (neuere Server).
import '../api/api_error.dart';
import '../api/models.dart';

/// Eine Änderung des Clients.
class SyncOp {
  final String opId;
  final String op; // upsert | delete
  final String entity;
  final String id;
  final Json fields;
  final int baseRev;
  const SyncOp({required this.opId, required this.op, required this.entity, required this.id, this.fields = const {}, this.baseRev = 0});

  Json toJson() => {'opId': opId, 'op': op, 'entity': entity, 'id': id, if (op == 'upsert') 'fields': fields, 'baseRev': baseRev};
}

class SyncRejected {
  final String opId;

  /// Grund (`invalid`, `forbidden`, `not_found`, `deleted`, `parent_deleted`, `invalid_reference`, `id_taken`, `limit_reached`,
  /// `duplicate_op`, `unknown_entity`); unbekannte Werte bleiben erhalten und gelten als allgemeine Ablehnung.
  final String code;
  const SyncRejected(this.opId, this.code);
}

/// Felder einer Op, die nicht übernommen wurden: der Server hat sie schon neuer geändert und nennt seinen Wert.
class SyncConflict {
  final String opId;
  final String entity;
  final String id;
  final Json fields;
  final int serverRev;
  const SyncConflict({required this.opId, required this.entity, required this.id, required this.fields, required this.serverRev});
}

/// Aktueller Stand eines Datensatzes (oder sein Verschwinden) aus dem Änderungsstrom.
class SyncChange {
  final int rev;
  final String entity;
  final String id;

  /// Datensatz gelöscht oder (mit [hidden]) für diese Person nicht mehr sichtbar: lokal entfernen.
  final bool tombstone;
  final bool hidden;
  final Json fields;
  const SyncChange({required this.rev, required this.entity, required this.id, required this.tombstone, required this.hidden, required this.fields});
}

class SyncResult {
  final bool resyncNoetig;
  final int rev;
  final List<String> acked;
  final List<SyncRejected> rejected;
  final List<SyncConflict> conflicts;
  final List<SyncChange> changes;
  final bool hasMore;
  final int next;
  final DateTime? serverTime;
  const SyncResult({
    required this.resyncNoetig,
    required this.rev,
    required this.acked,
    required this.rejected,
    required this.conflicts,
    required this.changes,
    required this.hasMore,
    required this.next,
    required this.serverTime,
  });

  factory SyncResult.fromJson(Object? raw) {
    final m = asJson(raw);
    final status = m['status'];
    if (status != 'ok' && status != 'resync_required') throw ApiException.unerwarteteAntwort;
    int i(String k) {
      final v = m[k];
      return v is int ? v : (throw ApiException.unerwarteteAntwort);
    }

    List<T> liste<T>(String k, T Function(Json) f) {
      final v = m[k];
      if (v is! List) throw ApiException.unerwarteteAntwort;
      final out = <T>[];
      for (final e in v) {
        try {
          out.add(f(asJson(e)));
        } on ApiException {
          // unbekannter oder kaputter Eintrag: überspringen (neuere Server)
        }
      }
      return out;
    }

    String s(Json j, String k) {
      final v = j[k];
      return v is String ? v : (throw ApiException.unerwarteteAntwort);
    }

    int ji(Json j, String k) {
      final v = j[k];
      return v is int ? v : (throw ApiException.unerwarteteAntwort);
    }

    final ack = m['acked'];
    if (ack is! List) throw ApiException.unerwarteteAntwort;
    return SyncResult(
      resyncNoetig: status == 'resync_required',
      rev: i('rev'),
      acked: [for (final a in ack) a is String ? a : throw ApiException.unerwarteteAntwort],
      rejected: liste('rejected', (j) => SyncRejected(s(j, 'opId'), s(j, 'code'))),
      conflicts: liste(
        'conflicts',
        (j) => SyncConflict(opId: s(j, 'opId'), entity: s(j, 'entity'), id: s(j, 'id'), fields: asJson(j['fields']), serverRev: ji(j, 'serverRev')),
      ),
      changes: liste(
        'changes',
        (j) => SyncChange(
          rev: ji(j, 'rev'),
          entity: s(j, 'entity'),
          id: s(j, 'id'),
          tombstone: j['tombstone'] == true,
          hidden: j['hidden'] == true,
          fields: j['fields'] is Map<String, dynamic> ? j['fields'] as Json : const {},
        ),
      ),
      hasMore: m['hasMore'] == true,
      next: m['next'] is int ? m['next'] as int : 0,
      serverTime: m['serverTime'] is String ? DateTime.tryParse(m['serverTime'] as String) : null,
    );
  }
}
