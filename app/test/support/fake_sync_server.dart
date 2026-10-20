// Ein kleiner Fake des Sync-Servers (POST /sync) mit den Regeln des echten Servers: Idempotenz über op_id, Last-write-wins pro Feld nach
// baseRev (Änderungen desselben Geräts sind keine Konflikte), Löschen gewinnt, Tombstones, Änderungsstrom seitenweise mit sinceRev,
// resync_required. Dient den Client-Tests; das Zusammenspiel mit dem echten Server prüft app/tool/vertrag_test.dart.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'fake_server.dart';

class FakeZeile {
  final String entity;
  final String id;
  Map<String, dynamic> fields;
  int rev;
  final Map<String, int> fieldRevs = {};
  final Map<int, String> schreiber = {}; // rev -> Gerät
  bool geloescht = false;
  FakeZeile(this.entity, this.id, this.fields, this.rev);
}

class FakeSyncServer {
  int rev = 0;
  int purgedRev = 0;
  final Map<String, FakeZeile> zeilen = {}; // "entity/id"
  final Map<String, Map<String, dynamic>> ergebnisse = {}; // op_id -> Ergebnis (Idempotenz)
  final List<Map<String, dynamic>> anfragen = [];
  int angewendet = 0;

  /// Nächste Antworten als Fehler (Status, Code); danach wieder normal.
  final List<(int, String)> fehlerQueue = [];

  /// Retry-After (Sekunden) der Fehler 429/503 aus [fehlerQueue].
  int retryAfterWert = 7;

  /// Antwort für die nächste Anfrage als resync_required.
  bool resyncNaechste = false;

  /// Alle Anfragen scheitern mit einem Netzwerkfehler (kein Netz).
  bool offline = false;

  /// Erzwingt die Ablehnung einer Op mit diesem Code (null: normal verarbeiten); die Op wird nicht angewendet.
  String? Function(Map<String, dynamic> op)? ablehnung;

  /// Wirft nach dem Verarbeiten einmal einen Fehler (Antwort geht verloren, der Server hat aber angewendet).
  bool antwortVerlieren = false;

  /// Maximale Änderungen je Seite (kleiner als der Wunsch des Clients, um Seiten zu erzwingen).
  int? seitenMax;
  String geraet = fixDevice;

  void registrieren(FakeServer s) {
    s.on('POST /sync', (req) {
      if (offline) throw http.ClientException('offline');
      if (fehlerQueue.isNotEmpty) {
        final (status, code) = fehlerQueue.removeAt(0);
        return fehler(status, code, retryAfter: status == 429 || status == 503 ? retryAfterWert : null);
      }
      final antwort = verarbeiten(req.json);
      if (antwortVerlieren) {
        antwortVerlieren = false;
        throw http.ClientException('Antwort verloren');
      }
      return jsonAntwort(antwort);
    });
    s.json('POST /ws-ticket', {'ticket': 'ticket-1', 'expiresInSec': 30});
  }

  Map<String, dynamic> verarbeiten(Map<String, dynamic> body) {
    anfragen.add(body);
    final acked = <String>[];
    final rejected = <Map<String, dynamic>>[];
    final conflicts = <Map<String, dynamic>>[];
    for (final o in (body['ops'] as List).cast<Map<String, dynamic>>()) {
      final opId = o['opId'] as String;
      final alt = ergebnisse[opId];
      if (alt != null) {
        _uebernehmen(alt, opId, acked, rejected, conflicts);
        continue;
      }
      final r = _op(o);
      ergebnisse[opId] = r;
      _uebernehmen(r, opId, acked, rejected, conflicts);
    }
    final since = body['sinceRev'] as int;
    // mehrseitiger Snapshot wie beim echten Server: Folgeseiten (sinceRev = Cursor, snapshotRev = Ziel) prüfen nie gegen purgedRev und
    // liefern keine Tombstones; die letzte Seite verweist auf den normalen Lauf ab dem Ziel, wenn die Familie weitergekommen ist
    final snapshotAnfrage = body['snapshotRev'] as int?;
    final folgeseite = since > 0 && snapshotAnfrage != null && snapshotAnfrage > since;
    final snapshotModus = folgeseite || since == 0;
    final ziel = folgeseite ? snapshotAnfrage : rev;
    if (resyncNaechste || (!folgeseite && since > 0 && since < purgedRev) || since > rev || ziel > rev) {
      resyncNaechste = false;
      return _antwort('resync_required', acked, rejected, conflicts, const [], false, 0);
    }
    final limit = (seitenMax != null && seitenMax! < (body['limit'] as int? ?? 500)) ? seitenMax! : (body['limit'] as int? ?? 500);
    final alle = zeilen.values.where((z) => z.rev > since && z.rev <= ziel && !(snapshotModus && z.geloescht)).toList()..sort((a, b) => a.rev.compareTo(b.rev));
    final seite = alle.take(limit).toList();
    final mehr = alle.length > limit;
    final hasMore = mehr || (snapshotModus && rev > ziel);
    return _antwort(
      'ok',
      acked,
      rejected,
      conflicts,
      [
        for (final z in seite)
          {'rev': z.rev, 'entity': z.entity, 'id': z.id, 'tombstone': z.geloescht, 'fields': z.geloescht ? <String, dynamic>{} : z.fields},
      ],
      hasMore,
      hasMore ? (mehr ? seite.last.rev : ziel) : rev,
      snapshotRev: mehr && snapshotModus ? ziel : null,
    );
  }

  void _uebernehmen(Map<String, dynamic> r, String opId, List<String> acked, List<Map<String, dynamic>> rejected, List<Map<String, dynamic>> conflicts) {
    if (r['status'] == 'rejected') {
      rejected.add({'opId': opId, 'code': r['code']});
    } else {
      acked.add(opId);
      for (final c in (r['conflicts'] as List).cast<Map<String, dynamic>>()) {
        conflicts.add({'opId': opId, ...c});
      }
    }
  }

  Map<String, dynamic> _antwort(String status, List<String> acked, List<Map<String, dynamic>> rejected, List<Map<String, dynamic>> conflicts, List<Map<String, dynamic>> changes, bool hasMore, int next, {int? snapshotRev}) => {
    'status': status,
    'rev': rev,
    'acked': acked,
    'rejected': rejected,
    'conflicts': conflicts,
    'changes': changes,
    'hasMore': hasMore,
    'next': next,
    'snapshotRev': ?snapshotRev,
    'serverTime': DateTime.now().toUtc().toIso8601String(),
  };

  /// Untergeordnete Entitäten: Name -> (Elternteil, Feld).
  static const _eltern = {
    'list_item': ('list', 'listId'),
    'termin_teilnehmer': ('termin', 'terminId'),
    'termin_ausnahmen': ('termin', 'terminId'),
    'aufgabe_punkt': ('aufgabe', 'aufgabeId'),
    'nachricht': ('konversation', 'konversationId'),
    'lesestand': ('konversation', 'konversationId'),
  };

  static Map<String, dynamic> _terminStandard(String owner) => {
    'ort': '',
    'beschreibung': '',
    'ganztaegig': false,
    'startUtc': null,
    'endUtc': null,
    'tzid': null,
    'startDate': null,
    'endDate': null,
    'rrule': null,
    'erinnerungMin': null,
    'icalUid': null,
    'audience': 'family',
    'ownerId': owner,
  };

  static Map<String, dynamic> _aufgabeStandard(String owner) => {
    'beschreibung': '',
    'faelligDate': null,
    'faelligUtc': null,
    'tzid': null,
    'prioritaet': 0,
    'assigneeId': null,
    'erledigtAt': null,
    'erledigtVon': null,
    'wiederholung': null,
    'erinnerungMin': null,
    'audience': 'family',
    'ownerId': owner,
  };

  /// Vom Server gesetzte Felder des Chats (Besitzer bzw. Autor ist die schreibende Person).
  static Map<String, dynamic> _chatStandard(String entity, String person) => switch (entity) {
    'konversation' => {'titel': '', 'teilnehmer': <String>[], 'ownerId': person},
    'nachricht' => {'autorId': person, 'antwortAuf': null, 'bearbeitetAt': null},
    _ => const {},
  };

  Map<String, dynamic> _ab(String code) => {'status': 'rejected', 'code': code, 'conflicts': <Map<String, dynamic>>[]};
  Map<String, dynamic> _ok([List<Map<String, dynamic>> conflicts = const []]) => {'status': 'acked', 'conflicts': conflicts};

  Map<String, dynamic> _op(Map<String, dynamic> o) {
    final erzwungen = ablehnung?.call(o);
    if (erzwungen != null) return _ab(erzwungen);
    final key = '${o['entity']}/${o['id']}';
    final z = zeilen[key];
    final baseRev = o['baseRev'] as int;
    if (o['op'] == 'delete') {
      if (z == null) return _ab('not_found');
      if (z.geloescht) return _ok();
      _loeschen(z);
      return _ok();
    }
    final fields = (o['fields'] as Map<String, dynamic>);
    if (z == null) {
      if (baseRev > 0) return _ab('not_found');
      final eltern = _eltern[o['entity']];
      if (eltern != null) {
        final l = zeilen['${eltern.$1}/${fields[eltern.$2]}'];
        if (l == null) return _ab('not_found');
        if (l.geloescht) return _ab('parent_deleted');
      }
      final neu = FakeZeile(o['entity'] as String, o['id'] as String, {
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        if (o['entity'] == 'list') ...{'kind': 'custom', 'audience': 'family', 'ownerId': fixIdAdmin},
        if (o['entity'] == 'list_item') ...{'assigneeId': null, 'doneAt': null, 'position': 0},
        if (o['entity'] == 'termin') ..._terminStandard(fixIdAdmin),
        if (o['entity'] == 'aufgabe') ..._aufgabeStandard(fixIdAdmin),
        if (o['entity'] == 'aufgabe_punkt') ...{'doneAt': null, 'position': 0},
        ..._chatStandard(o['entity'] as String, fixIdAdmin),
        ...fields,
      }, ++rev);
      for (final f in fields.keys) {
        neu.fieldRevs[f] = neu.rev;
      }
      neu.schreiber[neu.rev] = geraet;
      zeilen[key] = neu;
      angewendet++;
      return _ok();
    }
    if (z.geloescht) return _ab('deleted');
    final verloren = <String, dynamic>{};
    final geaendert = <String, dynamic>{};
    for (final e in fields.entries) {
      if (jsonEncode(z.fields[e.key]) == jsonEncode(e.value)) continue;
      final fr = z.fieldRevs[e.key] ?? 0;
      final eigenes = z.schreiber[fr] == geraet;
      if (fr > baseRev && !eigenes) {
        verloren[e.key] = z.fields[e.key];
      } else {
        geaendert[e.key] = e.value;
      }
    }
    if (geaendert.isNotEmpty) {
      z.rev = ++rev;
      z.fields = {...z.fields, ...geaendert};
      // der Server setzt die Zeit der Bearbeitung
      if (z.entity == 'nachricht' && geaendert.containsKey('text')) z.fields['bearbeitetAt'] = DateTime.now().toUtc().toIso8601String();
      for (final f in geaendert.keys) {
        z.fieldRevs[f] = z.rev;
      }
      z.schreiber[z.rev] = geraet;
      angewendet++;
    }
    return _ok(verloren.isEmpty ? const [] : [{'entity': o['entity'], 'id': o['id'], 'fields': verloren, 'serverRev': z.rev}]);
  }

  void _loeschen(FakeZeile z) {
    z.geloescht = true;
    z.rev = ++rev;
    z.fields = {};
    // untergeordnete Einträge zuerst (niedrigere Revisionen wären im echten Server so; hier genügt ein Tombstone je Eintrag)
    for (final e in _eltern.entries) {
      if (e.value.$1 != z.entity) continue;
      for (final k in zeilen.values.where((k) => k.entity == e.key && k.fields[e.value.$2] == z.id && !k.geloescht).toList()) {
        k.geloescht = true;
        k.rev = ++rev;
        k.fields = {};
      }
    }
  }

  // ------------------------------------------------------------------ Änderungen "von einem anderen Gerät"

  /// Ändert Felder (oder legt an) wie ein anderes Gerät.
  FakeZeile andereAendert(String entity, String id, Map<String, dynamic> fields) {
    final key = '$entity/$id';
    var z = zeilen[key];
    if (z == null) {
      z = FakeZeile(entity, id, {
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        if (entity == 'list') ...{'kind': 'custom', 'audience': 'family', 'ownerId': fixIdKind},
        if (entity == 'list_item') ...{'assigneeId': null, 'doneAt': null, 'position': 0},
        if (entity == 'termin') ..._terminStandard(fixIdKind),
        if (entity == 'aufgabe') ..._aufgabeStandard(fixIdKind),
        if (entity == 'aufgabe_punkt') ...{'doneAt': null, 'position': 0},
        ..._chatStandard(entity, fixIdKind),
        ...fields,
      }, ++rev);
      zeilen[key] = z;
    } else {
      z.fields = {...z.fields, ...fields};
      z.rev = ++rev;
    }
    for (final f in fields.keys) {
      z.fieldRevs[f] = z.rev;
    }
    z.schreiber[z.rev] = 'anderes-geraet';
    return z;
  }

  void andereLoescht(String entity, String id) => _loeschen(zeilen['$entity/$id']!);

  /// Entfernt Tombstones bis [bis] (wie die Wartung) und merkt die Grenze.
  void bereinigen(int bis) {
    zeilen.removeWhere((_, z) => z.geloescht && z.rev <= bis);
    purgedRev = bis;
  }
}
