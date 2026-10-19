// Zustand und Verdrahtung der Chat-Verschlüsselung (E2EE Phase 2): hält das [ChatKrypto] der angemeldeten Person (Schlüsselbund im Arbeitsspeicher), öffnet
// Wraps, wenn sich Epochen oder Wraps ändern, pflegt die Epochen (erste Epoche, Rotation bei Mitgliederwechsel) und entschlüsselt Nachrichten für die Oberfläche
// (Zwischenspeicher). Der Zustand ist nur ein Zähler: jede Änderung (neuer Schlüssel, entschlüsselte Nachricht) baut die Oberfläche neu auf.
// Offline-first: alles läuft auf der lokalen Datenbank und dem lokalen Personenschlüssel; das Netz braucht nur das Auffrischen der Mitglieder (neue Schlüssel).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/e2ee_state.dart';
import '../crypto/schluessel.dart';
import '../crypto/vertrauen.dart';
import '../database_provider.dart';
import '../sync/sync_store.dart';
import '../sync_state.dart';
import 'chat_krypto.dart';
import 'nachrichten_inhalt.dart';

/// Wartezeit zwischen dem Erkennen einer nötigen Rotation und dem Anlegen (damit nicht alle Geräte gleichzeitig rotieren; der erste Schreiber gewinnt ohnehin).
final chatKryptoVersatzProvider = Provider<Duration Function()>((ref) {
  final zufall = Random();
  return () => Duration(milliseconds: 200 + zufall.nextInt(2500));
});

/// Mindestabstand, in dem die Mitglieder (und ihre Schlüssel) beim Server aufgefrischt werden.
const kMitgliederAbstand = Duration(minutes: 3);

List<String> _teilnehmer(Konversation k) {
  try {
    final d = jsonDecode(k.teilnehmerJson);
    return d is List ? [for (final x in d) if (x is String) x] : const [];
  } catch (_) {
    return const [];
  }
}

/// Lesen und Öffnen der Nachrichten für die Oberfläche: Zwischenspeicher je Nachricht, Entschlüsselung im Hintergrund.
class E2eeNachrichtenInhalt implements NachrichtenInhalt {
  final Future<ChatKrypto?> Function() krypto;
  final Future<String?> Function(String konversationId) encVersion;
  final String? Function() ich;

  /// IDs der Nachrichten mit noch nicht gesendetem lokalem Klartext (`l1:`) laut Ausgang; null, solange der Ausgang noch nicht gelesen ist.
  final Set<String>? Function() lokaleIds;
  final void Function() beiAenderung;
  final Map<String, ({String wire, DekodierterInhalt inhalt})> _cache = {};
  final Set<String> _laufend = {};
  static const _namen = KlartextHuelle();

  E2eeNachrichtenInhalt({required this.krypto, required this.encVersion, required this.ich, required this.lokaleIds, required this.beiAenderung});

  @override
  String kodieren(String text) => _namen.kodieren(text);

  @override
  DekodierterInhalt dekodieren(String wire) => _namen.dekodieren(wire);

  @override
  DekodierterInhalt nachricht(Nachricht n) {
    final w = n.inhalt;
    if (w.startsWith(kPraefixLokal)) {
      // Klartext einer noch nicht gesendeten eigenen Nachricht oder Bearbeitung auf diesem Gerät: er steht im Ausgang. Vom Server kommt so etwas nie (er lehnt es
      // ab); ein Eintrag, den der Ausgang nicht kennt, wird nie als Text angezeigt.
      final ids = lokaleIds();
      if (ids == null) return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
      if (n.autorId != null && n.autorId == ich() && (n.rev == 0 || ids.contains(n.id))) return DekodierterInhalt(w.substring(kPraefixLokal.length), InhaltStatus.bereit);
      return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'unverschlüsselt');
    }
    final c = _cache[n.id];
    if (c != null && c.wire == w) return c.inhalt;
    if (_laufend.add(n.id)) unawaited(_oeffnen(n));
    return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
  }

  Future<void> _oeffnen(Nachricht n) async {
    DekodierterInhalt r;
    try {
      final enc = await encVersion(n.konversationId);
      final w = n.inhalt;
      if (enc == null) {
        r = const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Chat nicht gefunden');
      } else if (enc != 'e1') {
        // Altbestand ohne Verschlüsselung: nur `p1:` ist dort gültig
        r = w.startsWith('p1:') ? DekodierterInhalt(w.substring(3), InhaltStatus.bereit) : const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'nicht lesbar');
      } else if (!w.startsWith(kPraefixE1)) {
        // Klartext in einem verschlüsselten Chat (Downgrade): nie anzeigen
        r = const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'unverschlüsselt, abgelehnt');
      } else {
        final k = await krypto();
        r = k == null
            ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Verschlüsselung nicht bereit')
            : await k.nachrichtOeffnen(konversationId: n.konversationId, nachrichtId: n.id, autorId: n.autorId, wire: w);
      }
      _cache[n.id] = (wire: n.inhalt, inhalt: r);
    } on Object {
      _cache[n.id] = (wire: n.inhalt, inhalt: const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'nicht lesbar'));
    } finally {
      _laufend.remove(n.id);
    }
    beiAenderung();
  }

  /// Ergebnisse, die nicht lesbar waren, werden beim nächsten Zugriff erneut versucht (z. B. nach einem neuen Epochenschlüssel).
  void fehlschlaegeVergessen() => _cache.removeWhere((_, v) => v.inhalt.status != InhaltStatus.bereit);

  /// Verwirft alles (Abmelden, Wechsel der Person, Schlüsselwechsel).
  void leeren() => _cache.clear();
}

/// Verschlüsselt Nachrichten im Ausgang unmittelbar vor dem Senden (Klartext `l1:` -> `e1:`), immer mit der dann aktuellen Epoche. Geht das nicht (kein Schlüssel,
/// eine neuere Epoche ist noch nicht bestätigt oder ihr Schlüssel fehlt), bleibt die Nachricht im Ausgang. Zur Sicherheit wird nie etwas im Klartext gesendet.
class ChatOpVorbereiter implements OpVorbereiter {
  final AppDatabase db;
  final Future<ChatKrypto?> Function() krypto;
  ChatOpVorbereiter({required this.db, required this.krypto});

  @override
  Future<String?> vorbereiten(OutboxData op) async {
    if (op.entity != 'nachricht' || op.op != 'upsert') return op.fieldsJson;
    final Object? f = jsonDecode(op.fieldsJson);
    if (f is! Map<String, dynamic>) return op.fieldsJson;
    final text = f['text'];
    if (text is! String || !text.startsWith(kPraefixLokal)) return op.fieldsJson;
    var konversationId = f['konversationId'];
    if (konversationId is! String) {
      konversationId = (await (db.select(db.nachrichten)..where((n) => n.id.equals(op.entityId))).getSingleOrNull())?.konversationId;
    }
    if (konversationId is! String) return null;
    final k = await krypto();
    if (k == null) return null;
    // frischer Stand der Schlüssel (der Abgleich hat vielleicht gerade eine neue Epoche und ihren Wrap geholt)
    await k.aktualisieren();
    final wire = await k.nachrichtVersiegeln(konversationId: konversationId, nachrichtId: op.entityId, klartext: text.substring(kPraefixLokal.length));
    if (wire == null) return null;
    return jsonEncode({...f, 'text': wire});
  }
}

final chatKryptoProvider = NotifierProvider<ChatKryptoController, int>(ChatKryptoController.new);

/// Der Inhalt der Nachrichten für die Oberfläche. Mit jeder Änderung (etwas ist entschlüsselt, ein Schlüssel ist eingetroffen) entsteht eine neue Sicht: Riverpod meldet
/// einen Provider nur weiter, wenn sich der Wert ändert, und der Zwischenspeicher selbst bleibt dasselbe Objekt.
final nachrichtenInhaltProvider = Provider<NachrichtenInhalt>((ref) {
  final stand = ref.watch(chatKryptoProvider);
  return _InhaltSicht(ref.read(chatKryptoProvider.notifier).inhalt, stand);
});

class _InhaltSicht implements NachrichtenInhalt {
  final NachrichtenInhalt _innen;
  // ignore: unused_field
  final int _stand;
  const _InhaltSicht(this._innen, this._stand);

  @override
  String kodieren(String text) => _innen.kodieren(text);

  @override
  DekodierterInhalt dekodieren(String wire) => _innen.dekodieren(wire);

  @override
  DekodierterInhalt nachricht(Nachricht n) => _innen.nachricht(n);
}

/// Hält die Chat-Verschlüsselung am Laufen (am Wurzel-Widget beobachtet, dort wird er nie pausiert, siehe app.dart).
final chatKryptoSteuerungProvider = Provider<void>((ref) {
  final ich = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet ? s.user?.id : null));
  if (ich == null) return;
  Future.microtask(() => ref.read(chatKryptoProvider.notifier).starten());
});

class ChatKryptoController extends Notifier<int> {
  ChatKrypto? _krypto;
  Personenschluessel? _kSchluessel;
  int? _kVersion;
  String? _kBesitzer;
  E2eeNachrichtenInhalt? _inhalt;
  bool _bumpOffen = false;
  bool _laufOffen = false;
  bool _laeuft = false;
  bool _nochmal = false;
  StreamSubscription<Object?>? _dbSub;
  StreamSubscription<List<OutboxData>>? _outboxSub;
  Set<String>? _lokaleIds;
  DateTime? _mitgliederStand;
  final Map<String, DateTime> _rotiert = {};

  /// Inhalt für die Oberfläche (Zwischenspeicher der entschlüsselten Nachrichten).
  NachrichtenInhalt get inhalt => _inhalt!;

  AppDatabase get _db => ref.read(appDatabaseProvider);

  @override
  int build() {
    _dbSub?.cancel();
    _dbSub = null;
    _krypto?.vergessen();
    _krypto = null;
    _mitgliederStand = null;
    _inhalt = E2eeNachrichtenInhalt(
      krypto: krypto,
      encVersion: (id) async => (await (_db.select(_db.konversationen)..where((k) => k.id.equals(id))).getSingleOrNull())?.encVersion,
      ich: () => ref.read(authProvider).user?.id,
      lokaleIds: () => _lokaleIds,
      beiAenderung: _anstossen,
    );
    _lokaleIds = null;
    _outboxSub?.cancel();
    _outboxSub = _db.select(_db.outbox).watch().listen(_outboxAuswerten);
    ref.watch(authProvider.select((s) => s.user?.id));
    ref.listen(e2eeProvider, (alt, neu) {
      if (alt?.status != neu.status || !identical(alt?.mitglieder, neu.mitglieder) || !identical(alt?.warnungen, neu.warnungen)) {
        _krypto?.vertrauenGeaendert();
        _geplant();
      }
    });
    ref.listen(syncProvider.select((s) => s.letzterAbgleich), (_, _) {
      _geplant();
      unawaited(mitgliederAktualisieren());
    });
    ref.onDispose(() {
      _outboxSub?.cancel();
      _dbSub?.cancel();
      _krypto?.vergessen();
      _krypto = null;
      _inhalt?.leeren();
    });
    return 0;
  }

  /// Welche Nachrichten haben noch lokalen Klartext im Ausgang (Neu und Bearbeitung)? Nur diese zeigt [E2eeNachrichtenInhalt] als `l1:`-Text.
  void _outboxAuswerten(List<OutboxData> ops) {
    final ids = <String>{};
    for (final o in ops) {
      if (o.entity != 'nachricht' || o.op != 'upsert' || !o.fieldsJson.contains(kPraefixLokal)) continue;
      try {
        final f = jsonDecode(o.fieldsJson);
        if (f is Map && f['text'] is String && (f['text'] as String).startsWith(kPraefixLokal)) ids.add(o.entityId);
      } on FormatException {
        // unlesbarer Eintrag: zählt nicht
      }
    }
    final alt = _lokaleIds;
    _lokaleIds = ids;
    if (alt == null || alt.length != ids.length || !alt.containsAll(ids)) _anstossen();
  }

  /// Beginnt zu beobachten: Änderungen der Epochen, Wraps und Konversationen in der lokalen Datenbank, dazu ein erstes Auffrischen der Mitglieder.
  void starten() {
    if (_dbSub != null) return;
    final db = _db;
    _dbSub = db.tableUpdates(TableUpdateQuery.onAllTables([db.konversationEpochen, db.epocheWraps, db.konversationen])).listen((_) => _geplant());
    _geplant();
    unawaited(mitgliederAktualisieren());
  }

  /// Aktuelle Mitglieder und ihre Schlüssel beim Server holen (neue Schlüssel, Entfernte). Höchstens alle [kMitgliederAbstand], sofort mit [erzwingen].
  Future<void> mitgliederAktualisieren({bool erzwingen = false}) async {
    final jetzt = DateTime.now();
    final stand = _mitgliederStand;
    if (!erzwingen && stand != null && jetzt.difference(stand) < kMitgliederAbstand) return;
    _mitgliederStand = jetzt;
    try {
      await ref.read(e2eeProvider.notifier).laden();
    } on Object {
      // offline: der Schlüsselbund arbeitet mit dem, was lokal da ist
    }
    _geplant();
  }

  /// Meldet der Oberfläche eine Änderung (gebündelt: viele Ergebnisse in einem Durchgang ergeben eine Neuzeichnung).
  void _anstossen() {
    if (!ref.mounted || _bumpOffen) return;
    _bumpOffen = true;
    scheduleMicrotask(() {
      _bumpOffen = false;
      if (ref.mounted) state = state + 1;
    });
  }

  /// Plant einen Lauf (gebündelt: viele Auslöser in einem Durchgang ergeben einen Lauf; ein laufender Lauf wiederholt sich danach einmal).
  void _geplant() {
    if (!ref.mounted || _laufOffen) return;
    _laufOffen = true;
    scheduleMicrotask(() {
      _laufOffen = false;
      if (ref.mounted) unawaited(_lauf());
    });
  }

  /// Die aktiven Mitglieder mit ihren Schlüsseln laut dem letzten erfolgreichen Abgleich mit dem Server (null: noch nicht bekannt, z. B. offline).
  Map<String, OeffentlicheSchluessel?>? _serverSchluessel() {
    final e = ref.read(e2eeProvider);
    if (e.mitglieder.isEmpty) return null;
    return {
      for (final m in e.mitglieder)
        if (m.status == MemberStatus.active) m.id: m.schluessel,
    };
  }

  /// Das [ChatKrypto] dieser Person (null, solange kein lokaler Schlüssel oder keine Schlüsselversion bekannt ist).
  Future<ChatKrypto?> krypto() async {
    final ich = ref.read(authProvider).user?.id;
    if (ich == null) return null;
    final e2ee = ref.read(e2eeProvider.notifier);
    final pk = e2ee.lokalerSchluessel;
    if (pk == null) return null;
    final version = ref.read(e2eeProvider).serverSchluessel?.version ?? await e2ee.letzteBekannteVersion();
    if (version == null) return null;
    final vorhanden = _krypto;
    if (vorhanden != null && identical(_kSchluessel, pk) && _kVersion == version && _kBesitzer == ich) return vorhanden;
    vorhanden?.vergessen();
    final CryptoProvider cp;
    try {
      cp = await ref.read(cryptoProviderProvider.future);
    } on Object {
      return null;
    }
    final pruefer = VertrauensPruefer(ref.read(schluesselSpeicherProvider), eigeneUserId: ich);
    final neu = ChatKrypto(
      crypto: cp,
      db: _db,
      store: ref.read(syncStoreProvider),
      ichId: ich,
      meinSchluessel: pk,
      meineKeyVersion: version,
      gemerkt: pruefer.gemerkterSchluessel,
      serverSchluessel: _serverSchluessel,
      absenderSchluessel: (u, v) => e2ee.absenderSchluessel(u, v),
    );
    _krypto = neu;
    _kSchluessel = pk;
    _kVersion = version;
    _kBesitzer = ich;
    return neu;
  }

  Future<void> _lauf() async {
    if (_laeuft) {
      _nochmal = true;
      return;
    }
    _laeuft = true;
    try {
      do {
        _nochmal = false;
        final k = await krypto();
        if (k == null) {
          _inhalt?.fehlschlaegeVergessen();
          _anstossen();
          continue;
        }
        final geaendert = await k.aktualisieren();
        if (geaendert) {
          _inhalt?.fehlschlaegeVergessen();
          _anstossen();
          // gehaltene Nachrichten im Ausgang können jetzt vielleicht verschlüsselt werden
          ref.read(syncProvider.notifier).lokaleAenderung();
        }
        await _pflegen(k);
      } while (_nochmal);
    } on Object {
      // der nächste Auslöser versucht es erneut; nie Interna zeigen
    } finally {
      _laeuft = false;
    }
  }

  /// Epochen pflegen: erste Epoche für Konversationen ohne, neue Epoche bei Mitgliederwechsel. Nur mit frischem Stand der Mitglieder vom Server.
  Future<void> _pflegen(ChatKrypto k) async {
    final e = ref.read(e2eeProvider);
    if (e.status != E2eeStatus.bereit || e.mitglieder.isEmpty) return;
    final jetzt = DateTime.now();
    for (final konv in await _db.select(_db.konversationen).get()) {
      if (konv.encVersion != 'e1' || konv.rev == 0) continue;
      final letzte = _rotiert[konv.id];
      if (letzte != null && jetzt.difference(letzte) < const Duration(seconds: 30)) continue;
      final teilnehmer = _teilnehmer(konv).toSet();
      var erste = await k.ersteEpocheNoetig(konversation: konv, teilnehmer: teilnehmer);
      var rot = erste == null ? await k.rotationNoetig(konversation: konv, teilnehmer: teilnehmer) : null;
      if (erste == null && rot == null) continue;
      // nicht alle Geräte gleichzeitig: kurz warten und neu prüfen (der erste Schreiber gewinnt, die anderen übernehmen seine Epoche)
      await Future<void>.delayed(ref.read(chatKryptoVersatzProvider)());
      if (!ref.mounted) return;
      final frisch = await (_db.select(_db.konversationen)..where((t) => t.id.equals(konv.id))).getSingleOrNull();
      if (frisch == null) continue;
      erste = await k.ersteEpocheNoetig(konversation: frisch, teilnehmer: _teilnehmer(frisch).toSet());
      rot = erste == null ? await k.rotationNoetig(konversation: frisch, teilnehmer: _teilnehmer(frisch).toSet()) : null;
      if (erste == null && rot == null) continue;
      try {
        final aenderungen = await k.epocheErstellen(
          konversationId: konv.id,
          mitglieder: erste ?? rot!.mitglieder,
          // Familienchat: neue Mitglieder sehen die Historie; Gruppen und Direktchats: nur der Mitgliederwechsel in der Oberfläche entscheidet darüber
          historieFuer: konv.art == 'family' && rot != null ? rot.neu : const {},
          unvertrauteAuslassen: true,
        );
        await ref.read(syncStoreProvider).aendernMehrere(aenderungen);
        _rotiert[konv.id] = jetzt;
        ref.read(syncProvider.notifier).lokaleAenderung();
        _geplant();
      } on SchluesselFehlt {
        // jemand hat keinen vertrauenswürdigen Schlüssel mehr: beim nächsten Auslöser neu prüfen
      } on VerschluesselungNichtBereit {
        // dieses Gerät ist gerade nicht bereit
      } on CryptoFehler {
        // nichts anlegen
      }
    }
  }
}

