// Bausteine für Tests der Chat-Verschlüsselung: Personen mit Personenschlüssel, ein [ChatKrypto] je Person auf ihrer eigenen lokalen Datenbank und ein kleiner
// Fake-Server, der die Regeln des echten Servers für Chat, Epochen und Wraps nachbildet (Sicht nach Teilnehmern, nur der Empfänger liest seinen Wrap, der erste
// Schreiber einer Epoche gewinnt, Hülle e1 statt Klartext). Alle Abgleiche laufen über den echten [SyncStore] mit dem echten [ChatOpVorbereiter].
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, OrderingTerm;
import 'package:drift/native.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/chat/chat_krypto_state.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/chat/nachrichten_inhalt.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/vertrauen.dart' show VertrauensAblageDefekt;
import 'package:lx_fampad/data/sync/sync_models.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';

const familieId = 'ffffffff-0000-4000-8000-00000000000f';

class TestPerson {
  final String id;
  final String name;
  Personenschluessel pk;
  int version;
  TestPerson(this.id, this.name, CryptoProvider crypto, {this.version = 1}) : pk = Personenschluessel.erzeugen(crypto);

  OeffentlicheSchluessel get oeffentlich => pk.oeffentlich(version);

  /// Neuer Personenschlüssel (Schlüsselwechsel): neue Version; die alten Wraps sind für diese Person nicht mehr lesbar. Der alte öffentliche Schlüssel
  /// bleibt in der Historie des Servers ([ChatWelt.historie]).
  void schluesselWechseln(ChatWelt welt) {
    welt.historie['$id:$version'] = oeffentlich;
    pk = Personenschluessel.erzeugen(welt.crypto);
    version++;
    welt.schluesselVersionen[id] = version;
  }
}

/// Ein Gerät einer Person: eigene Datenbank, Store, Krypto und Repository.
class Geraet {
  final TestPerson person;
  final AppDatabase db;
  final SyncStore store;
  late ChatKrypto krypto;
  late final ChatRepository repo;
  final ChatOpVorbereiter vorbereiter;
  int ops = 0;
  int sinceRev = 0;
  DateTime jetzt;
  final String name;
  bool bereit = true;

  Geraet._(this.person, this.db, this.store, this.vorbereiter, this.name, this.jetzt);

  /// Letzter Stand der Mitglieder (Schlüssel laut Server), den dieses Gerät kennt; null: unbekannt (offline).
  Map<String, OeffentlicheSchluessel?>? karte;

  /// Gemerkte (TOFU) Schlüssel.
  final Map<String, OeffentlicheSchluessel> tofu = {};

  /// Früher bestätigte Schlüssel ("userId:version"), vom Gerät selbst gemerkt.
  final Map<String, OeffentlicheSchluessel> frueher = {};

  /// Dauerhaft festgehaltener Stand der akzeptierten Chat-Mitglieder (überlebt [neuStarten], wie der Vertrauensspeicher).
  final Map<String, AkzeptierterStand> stand = {};

  /// Konversationen, deren festgehaltener Stand "beschädigt" ist (Laden wirft [VertrauensAblageDefekt]).
  final Set<String> standDefekt = {};

  static Geraet neu(ChatWelt welt, TestPerson person, {String? name, String? opPraefix, String Function()? neueId, void Function()? beiAenderung}) {
    final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final geraete = name ?? person.name;
    late Geraet g;
    late Geraet g0;
    final store = SyncStore(db, jetzt: () => g0.jetzt, opId: () => '${opPraefix ?? '$geraete-op-'}${++g.ops}');
    final v = ChatOpVorbereiter(db: db, krypto: () async => g.bereit ? g.krypto : null);
    g = Geraet._(person, db, store, v, geraete, DateTime.utc(2026, 10, 19, 9));
    g0 = g;
    g.welt = welt;
    g.neuStarten();
    g.repo = ChatRepository(
      db: db,
      store: store,
      inhalt: const KlartextHuelle(),
      krypto: () async => g.bereit ? g.krypto : null,
      ich: () => person.id,
      familie: () => familieId,
      beiAenderung: beiAenderung ?? () {},
      jetzt: () => g.jetzt,
      neueId: neueId,
    );
    return g;
  }

  late ChatWelt welt;

  /// Baut den Schlüsselbund neu (App-Neustart, neuer Personenschlüssel dieser Person): Epochenschlüssel gibt es nur im Arbeitsspeicher und kommen aus den Wraps zurück.
  void neuStarten() {
    final w = welt;
    krypto = ChatKrypto(
      crypto: w.crypto,
      db: db,
      store: store,
      ichId: person.id,
      meinSchluessel: person.pk,
      meineKeyVersion: person.version,
      gemerkt: (u, {version}) async {
        final k = tofu[u];
        if (k == null || version == null || version == k.version) return k;
        return frueher['$u:$version'];
      },
      serverSchluessel: () => karte,
      absenderSchluessel: (u, version) async {
        final s = tofu[u];
        if (s != null && s.version == version) return s;
        // nur Schlüssel, die dieses Gerät selbst gemerkt hat (nie die Historie des Servers)
        final alt = frueher['$u:$version'];
        if (alt != null) return alt;
        throw const CryptoFehler(CryptoFehlerArt.signatur, 'Absender nicht bestätigt');
      },
      jetzt: () => jetzt,
      standLaden: (c) async {
        if (standDefekt.contains(c)) throw const VertrauensAblageDefekt();
        return stand[c];
      },
      standSpeichern: (c, s) async => stand[c] = s,
    );
  }

  /// Das Gerät lernt die Schlüssel der Mitglieder kennen (Abgleich mit dem Server, TOFU merkt neue Personen).
  void mitgliederLernen(List<TestPerson> mitglieder, {Set<String> ohneSchluessel = const {}, bool vertrauen = true}) {
    karte = {for (final m in mitglieder) m.id: ohneSchluessel.contains(m.id) ? null : m.oeffentlich};
    if (vertrauen) {
      for (final m in mitglieder) {
        if (m.id != person.id && !ohneSchluessel.contains(m.id)) tofu.putIfAbsent(m.id, () => m.oeffentlich);
      }
    }
    krypto.vertrauenGeaendert();
    krypto.mitgliederBeobachtet(); // jeder Aufruf steht für einen gelungenen Abruf der Mitglieder
  }

  Future<void> schliessen() => db.close();

  Future<List<Nachricht>> nachrichten(String konv) =>
      (db.select(db.nachrichten)
            ..where((n) => n.konversationId.equals(konv))
            ..orderBy([(n) => OrderingTerm.asc(n.createdAt), (n) => OrderingTerm.asc(n.id)]))
          .get();

  Future<List<OutboxData>> ausgang() => (db.select(db.outbox)..orderBy([(o) => OrderingTerm.asc(o.id)])).get();

  /// Text einer Nachricht, wie ihn die Oberfläche sähe (entschlüsselt, sonst der Hinweis).
  Future<String> lesen(Nachricht n) async {
    if (n.inhalt.startsWith(kPraefixLokal)) return n.inhalt.substring(kPraefixLokal.length);
    final d = await krypto.nachrichtOeffnen(konversationId: n.konversationId, nachrichtId: n.id, autorId: n.autorId, wire: n.inhalt, antwortAuf: n.antwortAuf);
    return d.lesbar ? d.text : '<${d.hinweis}>';
  }
}

/// Fake-Server mit den Regeln des echten für Chat, Epochen und Wraps.
class ChatWelt {
  final CryptoProvider crypto;
  ChatWelt(this.crypto);

  /// Frühere öffentliche Schlüssel (Historie des Servers): "userId:version" -> Schlüssel.
  final Map<String, OeffentlicheSchluessel> historie = {};

  /// Test: der Server lehnt jeden Wrap ab (z. B. Rate oder Ausfall); die Absender bekommen eine Ablehnung statt einer Bestätigung.
  bool wrapsVerweigern = false;

  /// Aktuelle Schlüsselversion je Person laut Server (fehlt: 1); für die Prüfung der Wrap-ID v2 (keine künftige Version).
  final Map<String, int> schluesselVersionen = {};

  int rev = 0;
  final Map<String, ServerZeile> _z = {};

  /// Gelöschte Zeilen (Tombstones), die die Geräte im Änderungsstrom erfahren.
  final List<({int rev, String entity, String id})> _tombs = [];
  final Map<String, Map<String, dynamic>> _ergebnis = {};
  final List<Map<String, dynamic>> gesehen = []; // alle Felder aller angenommenen Ops (zum Prüfen: nie Klartext)
  List<String> aktiveMitglieder = [];

  /// Anzahl abgelehnter Ops je Entität (für Tests der Rotation: der Verlierer wird abgelehnt).
  final Map<String, int> abgelehnt = {};

  /// Eine Antwort mit dem genannten Stand (Entität, ID, Felder), ohne dass ein Gerät etwas gesendet hat (Tests, die einen Zustand herstellen).
  SyncResult antwortMit(List<(String, String, Map<String, dynamic>)> aenderungen) => SyncResult(
    resyncNoetig: false,
    rev: ++rev,
    acked: const [],
    rejected: const [],
    conflicts: const [],
    changes: [for (final (e, i, f) in aenderungen) SyncChange(rev: rev, entity: e, id: i, tombstone: false, hidden: false, fields: f)],
    hasMore: false,
    next: rev,
    snapshotRev: null,
    serverTime: null,
  );

  ServerZeile? zeile(String entity, String id) => _z['$entity/$id'];
  List<ServerZeile> alle(String entity) => [for (final z in _z.values) if (z.entity == entity) z];

  /// Zeilen der Entität, die der Server dieser Person ausliefert.
  List<ServerZeile> sichtbarFuer(String user, String entity) => [for (final z in alle(entity)) if (_sichtbar(z, user)) z];

  bool _sichtbar(ServerZeile z, String user) {
    final k = z.entity == 'konversation' ? z : _z['konversation/${z.fields['konversationId']}'];
    if (k == null) return false;
    final art = k.fields['art'];
    final teil = (k.fields['teilnehmer'] as List?)?.cast<String>() ?? const [];
    final imKreis = art == 'family' ? aktiveMitglieder.contains(user) : teil.contains(user);
    if (!imKreis) return false;
    if (z.entity == 'epoche_wrap') return z.fields['empfaengerId'] == user;
    if (z.entity == 'lesestand') return z.fields['userId'] == user;
    return true;
  }

  /// Ein Abgleich: Ausgang senden (mit Vorbereitung), Antwort und Änderungsstrom übernehmen. Wiederholt, bis der Ausgang leer oder nichts mehr sendbar ist.
  Future<void> abgleichen(Geraet g, {int maxRunden = 10}) async {
    for (var runde = 0; runde < maxRunden; runde++) {
      final nurAbholen = runde == 0 && await g.store.hatAltenKlartext(const Duration(seconds: 20));
      final ops = nurAbholen ? const <OutboxData>[] : await g.store.naechsteOps(50, vorbereiter: g.vorbereiter);
      final acked = <String>[];
      final rejected = <SyncRejected>[];
      for (final o in ops) {
        final r = _op(g, o);
        if (r == null) {
          acked.add(o.opId);
        } else {
          rejected.add(SyncRejected(o.opId, r));
        }
      }
      final changes = [
        for (final z in _z.values)
          if (z.rev > g.sinceRev && _sichtbar(z, g.person.id))
            SyncChange(rev: z.rev, entity: z.entity, id: z.id, tombstone: false, hidden: false, fields: {...z.fields}),
        for (final t in _tombs)
          if (t.rev > g.sinceRev) SyncChange(rev: t.rev, entity: t.entity, id: t.id, tombstone: true, hidden: false, fields: const {}),
      ]..sort((a, b) => a.rev.compareTo(b.rev));
      final res = SyncResult(
        resyncNoetig: false,
        rev: rev,
        acked: acked,
        rejected: rejected,
        conflicts: const [],
        changes: changes,
        hasMore: false,
        next: rev,
        snapshotRev: null,
        serverTime: null,
      );
      g.sinceRev = rev;
      final bericht = await g.store.uebernehmen(res, ops);
      if (bericht.neuLaden) {
        await g.store.neuLadenVormerken();
        g.sinceRev = 0;
      }
      await g.krypto.aktualisieren(); // wie der Controller der App: neue Wraps öffnen
      if (ops.isEmpty && !bericht.neuLaden && !nurAbholen) break;
    }
  }

  /// null = angenommen, sonst der Ablehnungsgrund.
  String? _op(Geraet g, OutboxData o) {
    final alt = _ergebnis[o.opId];
    if (alt != null) return alt['code'] as String?;
    final f = jsonDecode(o.fieldsJson) as Map<String, dynamic>;
    final code = _anwenden(g, o, f);
    _ergebnis[o.opId] = {'code': code};
    if (code != null) abgelehnt[o.entity] = (abgelehnt[o.entity] ?? 0) + 1;
    return code;
  }

  String? _anwenden(Geraet g, OutboxData o, Map<String, dynamic> f) {
    final key = '${o.entity}/${o.entityId}';
    if (o.op == 'delete') {
      // Kaskade wie beim echten Server: Reaktionen, Stimmen und Pins hängen an der Nachricht
      if (o.entity == 'nachricht') {
        for (final z in [for (final z in _z.values) if (const {'reaktion', 'stimme', 'pin'}.contains(z.entity) && z.fields['nachrichtId'] == o.entityId) z]) {
          _z.remove('${z.entity}/${z.id}');
          _tombs.add((rev: ++rev, entity: z.entity, id: z.id));
        }
      }
      if (_z.remove(key) != null) _tombs.add((rev: ++rev, entity: o.entity, id: o.entityId));
      return null;
    }
    final vorhanden = _z[key];
    switch (o.entity) {
      case 'konversation':
        if (vorhanden == null) {
          _z[key] = ServerZeile(o.entity, o.entityId, {...f, 'encVersion': f['encVersion'] ?? 'e1'}, ++rev);
          return null;
        }
        vorhanden.fields.addAll(f..remove('encVersion'));
        vorhanden.rev = ++rev;
        return null;
      case 'nachricht':
        final konv = _z['konversation/${vorhanden?.fields['konversationId'] ?? f['konversationId']}'];
        if (konv == null) return 'not_found';
        final text = (f['text'] ?? vorhanden?.fields['text']) as String;
        if (!text.startsWith('${konv.fields['encVersion']}:')) return 'invalid';
        if (konv.fields['encVersion'] == 'e1' && text.length < 150) return 'invalid';
        gesehen.add({'entity': 'nachricht', ...f});
        if (vorhanden == null) {
          _z[key] = ServerZeile(o.entity, o.entityId, {...f, 'autorId': g.person.id, 'createdAt': DateTime.utc(2026, 10, 19, 9).add(Duration(seconds: rev + 1)).toIso8601String()}, ++rev);
        } else {
          vorhanden.fields.addAll(f);
          vorhanden.rev = ++rev;
        }
        return null;
      case 'epoche':
        {
          final konv = _z['konversation/${f['konversationId']}'];
          if (konv == null || konv.fields['encVersion'] != 'e1') return 'invalid';
          final n = f['epoche'] as int;
          if (o.entityId != epocheId(f['konversationId'] as String, n)) return 'invalid';
          if (vorhanden != null) return vorhanden.fields['mitglieder'] == f['mitglieder'] ? null : 'invalid'; // der erste gewinnt
          if (n > 1 && _z['epoche/${epocheId(f['konversationId'] as String, n - 1)}'] == null) return 'invalid';
          gesehen.add({'entity': 'epoche', ...f});
          _z[key] = ServerZeile(o.entity, o.entityId, {...f, 'verteilerId': g.person.id}, ++rev);
          return null;
        }
      case 'epoche_wrap':
        {
          final konv = _z['konversation/${f['konversationId']}'];
          if (konv == null || konv.fields['encVersion'] != 'e1') return 'invalid';
          final n = f['epoche'] as int;
          final emp = f['empfaengerId'] as String;
          if (wrapsVerweigern) return 'invalid'; // Test: der Server lehnt Wraps ab
          // Wrap-ID v2: mit keyVersion die ID v2, ohne die ID v1 (wie der echte Server); eine künftige Version der Person gibt es nicht
          final version = f['keyVersion'] as int?;
          final erwartet = version == null ? wrapId(f['konversationId'] as String, n, emp) : wrapIdV2(f['konversationId'] as String, n, emp, version, g.person.id);
          if (o.entityId != erwartet) return 'invalid';
          if (version != null && version > (schluesselVersionen[emp] ?? 1)) return 'invalid';
          if (_z['epoche/${epocheId(f['konversationId'] as String, n)}'] == null) return 'invalid';
          final teil = (konv.fields['teilnehmer'] as List?)?.cast<String>() ?? const [];
          if (konv.fields['art'] != 'family' && !teil.contains(emp)) return 'invalid';
          if (vorhanden != null) return 'not_found'; // der erste gewinnt (je Konversation, Epoche, Empfänger und Schlüsselversion)
          gesehen.add({'entity': 'epoche_wrap', ...f});
          _z[key] = ServerZeile(o.entity, o.entityId, {...f, 'verteilerId': g.person.id}, ++rev);
          return null;
        }
      default:
        if (vorhanden == null) {
          _z[key] = ServerZeile(o.entity, o.entityId, {...f}, ++rev);
        } else {
          vorhanden.fields.addAll(f);
          vorhanden.rev = ++rev;
        }
        return null;
    }
  }
}

class ServerZeile {
  final String entity;
  final String id;
  final Map<String, dynamic> fields;
  int rev;
  ServerZeile(this.entity, this.id, this.fields, this.rev);
}

/// Hilfen für Tests, die ein Gerät und seinen Schlüsselbund auffrischen.
Future<void> auffrischen(Geraet g) async {
  await g.krypto.aktualisieren();
}
