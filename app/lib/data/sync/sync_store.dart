// Lokaler Speicher des Sync: schreibt Änderungen sofort in die lokalen Tabellen und in den Ausgang (outbox), liefert dem Service die
// zu sendenden Ops und übernimmt die Antwort des Servers (Bestätigungen, Ablehnungen, Konflikte, Änderungsstrom) in EINER Transaktion.
// Die Oberfläche wartet nie auf den Server: alles hier arbeitet nur auf der lokalen Datenbank.
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../api/models.dart';
import '../app_database.dart';
import 'sync_entities.dart';
import 'sync_models.dart';

/// Zufällige UUID Version 4 (für op_id und neue Datensätze). Aus dem CSPRNG, kein zusätzliches Paket nötig.
String neueUuid([Random? zufall]) {
  final r = zufall ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
}

/// Hinweis für die Person (z. B. "Eintrag „Milch“ wurde auf einem anderen Gerät gelöscht").
class SyncHinweis {
  final String text;
  const SyncHinweis(this.text);
}

/// Was beim Übernehmen einer Antwort auffiel.
class UebernahmeBericht {
  final List<SyncHinweis> hinweise = [];

  /// Eine Op wurde abgelehnt, deren lokale Änderung sich nicht einfach zurücknehmen lässt: der Stand des Servers soll neu geladen werden.
  bool neuLaden = false;

  /// Der Server verlangt eine vollständige Neuübertragung (die lokalen Tabellen wurden geleert, sinceRev ist 0).
  bool resync = false;
}

class SyncStore {
  final AppDatabase db;
  final Map<String, SyncEntity> entitaeten;
  final DateTime Function() _jetzt;
  final String Function() _neueOpId;

  SyncStore(this.db, {Map<String, SyncEntity>? entitaeten, DateTime Function()? jetzt, String Function()? opId})
    : entitaeten = entitaeten ?? syncEntities,
      _jetzt = jetzt ?? DateTime.now,
      _neueOpId = opId ?? neueUuid;

  static const kSinceRev = 'sinceRev';
  static const kDeviceId = 'deviceId';
  static const kSnapshotRev = 'snapshotRev';

  SyncEntity _entitaet(String name) => entitaeten[name] ?? (throw ArgumentError('Unbekannte Entität: $name'));

  // ------------------------------------------------------------------ Zustand

  Future<int> sinceRev() async => int.tryParse(await db.metaLesen(kSinceRev) ?? '') ?? 0;

  Future<void> sinceRevSetzen(int rev) => db.metaSchreiben(kSinceRev, '$rev');

  /// Ziel-Revision eines laufenden mehrseitigen Snapshots (null: keiner läuft). Mit [sinceRev] als Cursor wird er fortgesetzt.
  Future<int?> snapshotRev() async => int.tryParse(await db.metaLesen(kSnapshotRev) ?? '');

  Future<void> _snapshotRevSetzen(int? rev) => rev == null ? db.metaLoeschen(kSnapshotRev) : db.metaSchreiben(kSnapshotRev, '$rev');

  /// Anzahl noch nicht bestätigter Änderungen (live).
  Stream<int> offeneAenderungen() {
    final anzahl = db.outbox.id.count();
    return (db.selectOnly(db.outbox)..addColumns([anzahl])).map((r) => r.read(anzahl) ?? 0).watchSingle();
  }

  Future<int> offeneAnzahl() async {
    final anzahl = db.outbox.id.count();
    return (await (db.selectOnly(db.outbox)..addColumns([anzahl])).map((r) => r.read(anzahl) ?? 0).getSingle());
  }

  /// Ordnet die lokalen Daten diesem Gerät zu. Wechselt die Geräte-ID (neue Anmeldung, z. B. nach Rollenwechsel), beruht der lokale
  /// Stand auf einem anderen Gerät beim Server: die Fachtabellen werden geleert und neu geladen (der Ausgang bleibt erhalten; lokal
  /// neu angelegte, noch unbestätigte Zeilen werden wiederhergestellt, damit sie nicht bis zum Senden verschwinden).
  /// Liefert true, wenn geleert wurde.
  Future<bool> geraetZuordnen(String deviceId) => db.transaction(() async {
    final bisher = await db.metaLesen(kDeviceId);
    if (bisher == deviceId) return false;
    final geleert = bisher != null;
    if (geleert) await _neuAufsetzen();
    await db.metaSchreiben(kDeviceId, deviceId);
    return geleert;
  });

  // ------------------------------------------------------------------ lokale Änderungen

  /// Schreibt eine Änderung sofort lokal und stellt die Op in den Ausgang. [fields] gehen zum Server (Schnittstellenformat),
  /// [nurLokal] nur in die lokale Zeile (z. B. createdAt und ownerId einer neuen Zeile, bis der Server sie liefert).
  Future<void> aendern(String entity, String id, Json fields, {Json nurLokal = const {}}) => db.transaction(() async {
    final def = _entitaet(entity);
    final rev = await def.rev(db, id);
    if (rev == null && !def.kannAnlegen(fields)) return; // Zeile gibt es nicht mehr (anderswo gelöscht): keine Teilzeile anlegen
    await def.schreiben(db, id, {...nurLokal, ...fields});
    final offen = await (db.select(db.outbox)
          ..where((o) => o.entity.equals(entity) & o.entityId.equals(id) & o.op.equals('upsert') & o.sentAt.isNull())
          ..orderBy([(o) => OrderingTerm.desc(o.id)])
          ..limit(1))
        .getSingleOrNull();
    if (offen != null && offen.baseRev == (rev ?? 0)) {
      // noch nicht gesendet und auf derselben Revision aufgebaut: mit der früheren Änderung verschmelzen (später gewinnt je Feld).
      // Ist die Zeile inzwischen weitergekommen (Änderung des Servers übernommen), baut die neue Änderung auf der neuen Revision
      // auf und wird eine eigene Op: sonst würde sie mit der alten baseRev einen Konflikt vortäuschen.
      final alt = jsonDecode(offen.fieldsJson) as Map<String, dynamic>;
      await (db.update(db.outbox)..where((o) => o.id.equals(offen.id))).write(OutboxCompanion(fieldsJson: Value(jsonEncode({...alt, ...fields}))));
      return;
    }
    await db.into(db.outbox).insert(
      OutboxCompanion.insert(opId: _neueOpId(), op: 'upsert', entity: entity, entityId: id, fieldsJson: Value(jsonEncode(fields)), baseRev: Value(rev ?? 0), createdAt: Value(_jetzt())),
    );
  });

  /// Löscht lokal sofort (samt untergeordneten Zeilen) und merkt die Löschung für den Server vor. Eine Zeile, die der Server nie
  /// gesehen hat, verschwindet spurlos (ohne Op).
  Future<void> loeschen(String entity, String id) => db.transaction(() async {
    final def = _entitaet(entity);
    final rev = await def.rev(db, id);
    if (rev == null) return;
    final baum = await _baum(entity, id);
    // rev 0: der Server hat die Zeile nie bestätigt (uebernehmen setzt bei der Bestätigung einer Anlage mindestens 1). Wurde die Anlage
    // schon gesendet, aber nicht bestätigt (Antwort verloren), kennt der Server die Zeile womöglich: dann braucht er die Löschung.
    final gesendet = await (db.select(db.outbox)
          ..where((o) => o.entity.equals(entity) & o.entityId.equals(id) & o.sentAt.isNotNull()))
        .get();
    final nurLokal = rev == 0 && gesendet.isEmpty;
    for (final (e, i) in baum) {
      // ungesendete Ops der betroffenen Zeilen entfallen; gesendete bleiben (der Server hat sie vielleicht schon angewendet)
      await (db.delete(db.outbox)..where((o) => o.entity.equals(e) & o.entityId.equals(i) & o.sentAt.isNull())).go();
      await _entitaet(e).entfernen(db, i);
    }
    if (!nurLokal) {
      await db.into(db.outbox).insert(
        OutboxCompanion.insert(opId: _neueOpId(), op: 'delete', entity: entity, entityId: id, baseRev: Value(rev), createdAt: Value(_jetzt())),
      );
    }
  });

  /// Die Zeile und alle untergeordneten (rekursiv) als (Entität, ID).
  Future<List<(String, String)>> _baum(String entity, String id) async {
    final out = <(String, String)>[(entity, id)];
    for (final k in _entitaet(entity).kinder) {
      for (final kid in await _entitaet(k.entity).kindIds(db, k.field, id)) {
        out.addAll(await _baum(k.entity, kid));
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ Senden

  /// Die nächsten Ops (älteste zuerst), als gesendet markiert. Schon gesendete, noch nicht bestätigte Ops gehen erneut mit (gleiche op_id).
  Future<List<OutboxData>> naechsteOps(int max) => db.transaction(() async {
    final zeilen = await (db.select(db.outbox)
          ..orderBy([(o) => OrderingTerm.asc(o.id)])
          ..limit(max))
        .get();
    if (zeilen.isNotEmpty) {
      await (db.update(db.outbox)..where((o) => o.id.isIn([for (final z in zeilen) z.id]))).write(OutboxCompanion(sentAt: Value(_jetzt())));
    }
    return zeilen;
  });

  static SyncOp alsOp(OutboxData z) =>
      SyncOp(opId: z.opId, op: z.op, entity: z.entity, id: z.entityId, fields: jsonDecode(z.fieldsJson) as Map<String, dynamic>, baseRev: z.baseRev);

  // ------------------------------------------------------------------ Antwort übernehmen

  /// Noch offene lokale Änderungen je (Entität/ID): die Werte der Felder (spätere Ops gewinnen) und die vorgemerkten Löschungen.
  Future<({Map<String, Json> werte, Set<String> geloescht})> _offen() async {
    final werte = <String, Json>{};
    final geloescht = <String>{};
    for (final z in await (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get()) {
      final key = '${z.entity}/${z.entityId}';
      if (z.op == 'delete') {
        geloescht.add(key);
      } else {
        werte.putIfAbsent(key, () => {}).addAll(jsonDecode(z.fieldsJson) as Map<String, dynamic>);
      }
    }
    return (werte: werte, geloescht: geloescht);
  }

  Future<void> _verwerfeOps(String entity, String id) =>
      (db.delete(db.outbox)..where((o) => o.entity.equals(entity) & o.entityId.equals(id))).go();

  /// Entfernt die Zeile samt untergeordneten und deren offenen Ops. Liefert den Anzeigenamen der Zeile (für Hinweise), falls es sie gab.
  Future<String?> _entferneBaum(String entity, String id) async {
    final name = await _entitaet(entity).anzeigename(db, id);
    for (final (e, i) in await _baum(entity, id)) {
      await _verwerfeOps(e, i);
      await _entitaet(e).entfernen(db, i);
    }
    return name;
  }

  /// Übernimmt die Antwort des Servers. [gesendet] sind die Ops dieser Anfrage.
  Future<UebernahmeBericht> uebernehmen(SyncResult r, List<OutboxData> gesendet) => db.transaction(() async {
    final bericht = UebernahmeBericht();
    final opVon = {for (final z in gesendet) z.opId: z};

    // 1. bestätigte Ops aus dem Ausgang nehmen
    for (final id in r.acked) {
      await (db.delete(db.outbox)..where((o) => o.opId.equals(id))).go();
      // Anlage bestätigt: die Zeile ist dem Server bekannt, auch wenn ihr Stand erst auf einer späteren Seite des Stroms folgt
      // (rev 0 hieße "nie gesendet"; ein späteres Löschen würde dann ohne Op verschwinden und beim Server stehen bleiben)
      final z = opVon[id];
      final def = z == null ? null : entitaeten[z.entity];
      if (z != null && def != null && z.op == 'upsert' && z.baseRev == 0 && await def.rev(db, z.entityId) == 0) {
        await def.schreiben(db, z.entityId, const {}, rev: 1);
      }
    }

    // 2. abgelehnte Ops: nicht still verwerfen, sondern sichtbar machen
    for (final a in r.rejected) {
      final z = opVon[a.opId];
      await (db.delete(db.outbox)..where((o) => o.opId.equals(a.opId))).go();
      if (z == null) continue;
      await _abgelehnt(z, a.code, bericht);
    }

    // 3. Konflikte: der Wert des Servers gilt, außer eine spätere lokale Änderung desselben Felds wartet noch
    var offen = await _offen();
    for (final c in r.conflicts) {
      final def = entitaeten[c.entity];
      if (def == null || await def.rev(db, c.id) == null) continue;
      await def.schreiben(db, c.id, c.fields, ueberspringen: (offen.werte['${c.entity}/${c.id}'] ?? const {}).keys.toSet());
      final text = c.fields.keys.any((f) => f == 'name' || f == 'text' || f == 'titel');
      if (text) {
        final n = await def.anzeigename(db, c.id);
        bericht.hinweise.add(SyncHinweis('${n ?? 'Ein Eintrag'} wurde gleichzeitig auf einem anderen Gerät geändert. Dessen Stand gilt.'));
      }
    }

    // 4. vollständige Neuübertragung gewünscht: lokale Fachtabellen leeren (der Ausgang bleibt)
    if (r.resyncNoetig) {
      await _neuAufsetzen();
      bericht.resync = true;
      return bericht;
    }

    // 5. Änderungsstrom: Stand des Servers übernehmen, offene lokale Änderungen bleiben darüber erhalten
    offen = await _offen();
    for (final ch in r.changes) {
      final def = entitaeten[ch.entity];
      if (def == null) continue; // Entität einer neueren App-Version
      final key = '${ch.entity}/${ch.id}';
      if (ch.tombstone) {
        // Änderungen der Zeile oder ihrer untergeordneten, die noch auf dem Weg waren, gehen verloren: der Person Bescheid sagen
        final verloren = <String>[];
        if (!ch.hidden && !offen.geloescht.contains(key)) {
          for (final (e, i) in await _baum(ch.entity, ch.id)) {
            if (offen.werte.containsKey('$e/$i')) verloren.add(await _entitaet(e).anzeigename(db, i) ?? 'Ein Eintrag');
          }
        }
        await _entferneBaum(ch.entity, ch.id);
        if (verloren.isNotEmpty) {
          bericht.hinweise.add(SyncHinweis('${verloren.first} wurde auf einem anderen Gerät gelöscht. Deine Änderung wurde nicht übernommen.'));
        }
        continue;
      }
      if (offen.geloescht.contains(key)) continue; // lokal gelöscht, die Löschung ist unterwegs
      // Stand des Servers, darüber die noch offenen lokalen Änderungen (auch wenn die Zeile lokal gerade fehlte)
      await def.schreiben(db, ch.id, ch.fields, rev: ch.rev);
      final lokal = offen.werte[key];
      if (lokal != null) await def.schreiben(db, ch.id, lokal);
    }

    // 6. Fortschritt: bei weiteren Seiten bis zur letzten gelieferten, sonst bis zum Stand der Familie
    await sinceRevSetzen(r.hasMore ? r.next : r.rev);
    await _snapshotRevSetzen(r.hasMore ? r.snapshotRev : null);
    return bericht;
  });

  Future<void> _abgelehnt(OutboxData z, String code, UebernahmeBericht bericht) async {
    final def = entitaeten[z.entity];
    if (def == null) return;
    final name = await def.anzeigename(db, z.entityId) ?? 'Ein Eintrag';
    final neu = z.baseRev == 0 && z.op == 'upsert';
    switch (code) {
      case 'deleted' || 'not_found' || 'parent_deleted':
        if (z.op == 'delete') return; // schon weg: nichts zu tun
        await _entferneBaum(z.entity, z.entityId);
        bericht.hinweise.add(
          SyncHinweis(
            code == 'parent_deleted' ? '$name konnte nicht gespeichert werden: ${def.elternGeloescht}' : '$name wurde auf einem anderen Gerät gelöscht. Deine Änderung wurde nicht übernommen.',
          ),
        );
      case 'forbidden':
        bericht.hinweise.add(SyncHinweis('Das darfst du nicht: $name wurde nicht geändert.'));
        await _zuruecknehmen(z, neu, bericht);
      case 'invalid_reference':
        bericht.hinweise.add(SyncHinweis('Die zugewiesene Person gehört nicht mehr zur Familie. $name wurde nicht geändert.'));
        await _zuruecknehmen(z, neu, bericht);
      case 'limit_reached':
        bericht.hinweise.add(SyncHinweis('${def.grenzeErreicht}: $name konnte nicht gespeichert werden.'));
        await _zuruecknehmen(z, neu, bericht);
      case 'duplicate_op':
        break; // Wiederholung eines fremden Aufrufs: nichts zu tun
      default:
        bericht.hinweise.add(SyncHinweis('Eine Änderung an $name wurde vom Server abgelehnt und verworfen.'));
        await _zuruecknehmen(z, neu, bericht);
    }
  }

  /// Nimmt eine abgelehnte Änderung zurück: eine neue Zeile verschwindet, bei einer bestehenden wird der Stand des Servers neu geladen.
  Future<void> _zuruecknehmen(OutboxData z, bool neu, UebernahmeBericht bericht) async {
    if (z.op == 'delete') {
      bericht.neuLaden = true; // die Zeile fehlt lokal, der Server hat sie noch
      return;
    }
    if (neu) {
      await _entferneBaum(z.entity, z.entityId);
    } else {
      bericht.neuLaden = true;
    }
  }

  /// Verwirft den lokalen Stand der Fachtabellen und setzt sinceRev zurück (nächster Abgleich lädt alles; der Ausgang bleibt).
  Future<void> neuLadenVormerken() => db.transaction(_neuAufsetzen);

  /// Leert die Fachtabellen und setzt sinceRev auf 0. Lokal neu angelegte, noch unbestätigte Zeilen (Ops mit baseRev 0) werden aus dem
  /// Ausgang wiederhergestellt, damit sie nicht verschwinden; alle anderen Zeilen kommen mit dem nächsten Abgleich zurück.
  Future<void> _neuAufsetzen() async {
    for (final e in entitaeten.values) {
      await e.leeren(db);
    }
    await sinceRevSetzen(0);
    await _snapshotRevSetzen(null);
    final offen = await _offen();
    final angelegt = await (db.select(db.outbox)
          ..where((o) => o.op.equals('upsert') & o.baseRev.equals(0))
          ..orderBy([(o) => OrderingTerm.asc(o.id)]))
        .get();
    for (final z in angelegt) {
      final def = entitaeten[z.entity];
      if (def == null || offen.geloescht.contains('${z.entity}/${z.entityId}')) continue;
      await def.schreiben(db, z.entityId, offen.werte['${z.entity}/${z.entityId}'] ?? const {});
    }
  }
}
