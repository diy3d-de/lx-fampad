// Zustand und Verdrahtung der Chat-Verschlüsselung (E2EE Phase 2): hält das [ChatKrypto] der angemeldeten Person (Schlüsselbund im Arbeitsspeicher), öffnet
// Wraps, wenn sich Epochen oder Wraps ändern, pflegt die Epochen (erste Epoche, Rotation bei Mitgliederwechsel) und entschlüsselt Nachrichten für die Oberfläche
// (Zwischenspeicher). Der Zustand ist nur ein Zähler: jede Änderung (neuer Schlüssel, entschlüsselte Nachricht) baut die Oberfläche neu auf.
// Offline-first: alles läuft auf der lokalen Datenbank und dem lokalen Personenschlüssel; das Netz braucht nur das Auffrischen der Mitglieder (neue Schlüssel).
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../crypto/bytes.dart';
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
  final Map<String, ({String wire, DekodierterInhalt inhalt})> _zusatzCache = {};
  // groß genug für alle Reaktionen und Stimmen sichtbarer Chats: ein ausgeworfener Eintrag würde beim nächsten Aufbau neu geöffnet (und löst wieder einen Aufbau aus)
  static const maxZusatzCache = 5000;

  /// Höchstzahl der entschlüsselten Nachrichten im Arbeitsspeicher (die ältesten fliegen zuerst raus; sie werden bei Bedarf neu geöffnet).
  static const maxCache = 500;

  void _merke(String id, ({String wire, DekodierterInhalt inhalt}) v) {
    _cache.remove(id);
    _cache[id] = v;
    while (_cache.length > maxCache) {
      _cache.remove(_cache.keys.first);
    }
  }

  void _merkeZusatz(String id, ({String wire, DekodierterInhalt inhalt}) v) {
    _zusatzCache.remove(id);
    _zusatzCache[id] = v;
    while (_zusatzCache.length > maxZusatzCache) {
      _zusatzCache.remove(_zusatzCache.keys.first);
    }
  }

  /// Anzahl der Einträge im Zwischenspeicher (Tests).
  int get cacheGroesse => _cache.length;
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
      if (n.autorId != null && n.autorId == ich() && (n.rev == 0 || ids.contains(n.id))) {
        final t = w.substring(kPraefixLokal.length);
        if (t.startsWith('r1:') || t.startsWith('s1:')) return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'ungültiger Inhalt');
        return DekodierterInhalt(t, InhaltStatus.bereit);
      }
      // eigene Nachricht, die der Server schon kennt, deren Text hier aber noch nicht durch die Antwort ersetzt ist: sie ist unterwegs, nicht unverschlüsselt
      if (n.autorId != null && n.autorId == ich()) return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'wird gesendet');
      return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'unverschlüsselt');
    }
    final c = _cache[n.id];
    if (c != null && c.wire == w) {
      _merke(n.id, c);
      return c.inhalt;
    }
    if (_laufend.add(n.id)) unawaited(_oeffnen(n));
    return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
  }

  @override
  DekodierterInhalt zusatz(ZusatzRef z) {
    final w = z.wire;
    if (w.startsWith(kPraefixLokal)) {
      // eigener, noch nicht gesendeter Klartext (nur im Ausgang dieses Geräts); alles andere mit `l1:` gilt nie als lesbar
      final ids = lokaleIds();
      if (ids == null) return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
      if (z.userId == ich() && (z.rev == 0 || ids.contains(z.id))) return DekodierterInhalt(w.substring(kPraefixLokal.length), InhaltStatus.bereit);
      return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'unverschlüsselt');
    }
    final c = _zusatzCache[z.id];
    if (c != null && c.wire == w) {
      _merkeZusatz(z.id, c);
      return c.inhalt;
    }
    if (_laufend.add('z:${z.id}')) unawaited(_zusatzOeffnen(z));
    return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
  }

  Future<void> _zusatzOeffnen(ZusatzRef z) async {
    DekodierterInhalt r;
    try {
      final enc = await encVersion(z.konversationId);
      if (enc != 'e1' || !z.wire.startsWith(kPraefixE1)) {
        r = const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'unverschlüsselt, abgelehnt');
      } else {
        final k = await krypto();
        r = k == null
            ? const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Verschlüsselung nicht bereit')
            : await k.nachrichtOeffnen(konversationId: z.konversationId, nachrichtId: z.id, autorId: z.userId, wire: z.wire, antwortAuf: z.nachrichtId, art: z.art);
      }
      _merkeZusatz(z.id, (wire: z.wire, inhalt: r));
    } on Object {
      _merkeZusatz(z.id, (wire: z.wire, inhalt: const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'nicht lesbar')));
    } finally {
      _laufend.remove('z:${z.id}');
    }
    beiAenderung();
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
            : await k.nachrichtOeffnen(konversationId: n.konversationId, nachrichtId: n.id, autorId: n.autorId, wire: w, antwortAuf: n.antwortAuf);
        // Inhalte von Reaktionen und Stimmen sind nie Nachrichtentext (eine Nachricht mit diesem Präfix wird nicht angezeigt)
        if (r.lesbar && (r.text.startsWith('r1:') || r.text.startsWith('s1:'))) r = const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'ungültiger Inhalt');
      }
      _merke(n.id, (wire: n.inhalt, inhalt: r));
    } on Object {
      _merke(n.id, (wire: n.inhalt, inhalt: const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'nicht lesbar')));
    } finally {
      _laufend.remove(n.id);
    }
    beiAenderung();
  }

  /// Ergebnisse, die nicht lesbar waren, werden beim nächsten Zugriff erneut versucht (z. B. nach einem neuen Epochenschlüssel).
  void fehlschlaegeVergessen() {
    _cache.removeWhere((_, v) => v.inhalt.status != InhaltStatus.bereit);
    _zusatzCache.removeWhere((_, v) => v.inhalt.status != InhaltStatus.bereit);
  }

  /// Verwirft alles (Abmelden, Wechsel der Person, Schlüsselwechsel).
  void leeren() {
    _cache.clear();
    _zusatzCache.clear();
  }
}

/// Verschlüsselt Nachrichten im Ausgang unmittelbar vor dem Senden (Klartext `l1:` -> `e1:`), immer mit der dann aktuellen Epoche. Geht das nicht (kein Schlüssel,
/// eine neuere Epoche ist noch nicht bestätigt oder ihr Schlüssel fehlt), bleibt die Nachricht im Ausgang. Zur Sicherheit wird nie etwas im Klartext gesendet.
class ChatOpVorbereiter implements OpVorbereiter {
  final AppDatabase db;
  final Future<ChatKrypto?> Function() krypto;
  ChatOpVorbereiter({required this.db, required this.krypto});

  @override
  Future<String?> vorbereiten(OutboxData op) async {
    final feld = kVerschluesselteFelder[op.entity];
    if (feld == null || op.op != 'upsert') return op.fieldsJson;
    final Object? f = jsonDecode(op.fieldsJson);
    if (f is! Map<String, dynamic>) return op.fieldsJson;
    final text = f[feld];
    if (text is! String) return op.fieldsJson;
    final klar = text.startsWith(kPraefixLokal);
    // schon verschlüsselt: nur anfassen, wenn inzwischen eine neuere Epoche gilt (dann neu verschlüsseln); sonst unverändert
    if (!klar && !text.startsWith(kPraefixE1)) return op.fieldsJson;
    // Konversation und Bezug (Nachricht: Antwort-auf; Reaktion und Stimme: die Nachricht, auf die sie sich beziehen) aus der Op, sonst aus der lokalen Zeile
    String? konv = f['konversationId'] is String ? f['konversationId'] as String : null;
    String? antwortAuf;
    switch (op.entity) {
      case 'nachricht':
        final zeile = await (db.select(db.nachrichten)..where((n) => n.id.equals(op.entityId))).getSingleOrNull();
        konv ??= zeile?.konversationId;
        final antwort = f.containsKey('antwortAuf') ? f['antwortAuf'] : zeile?.antwortAuf;
        antwortAuf = antwort is String ? antwort : null;
      case 'reaktion':
        final zeile = await (db.select(db.reaktionen)..where((n) => n.id.equals(op.entityId))).getSingleOrNull();
        konv ??= zeile?.konversationId;
        antwortAuf = f['nachrichtId'] is String ? f['nachrichtId'] as String : zeile?.nachrichtId;
      case 'stimme':
        final zeile = await (db.select(db.stimmen)..where((n) => n.id.equals(op.entityId))).getSingleOrNull();
        konv ??= zeile?.konversationId;
        antwortAuf = f['nachrichtId'] is String ? f['nachrichtId'] as String : zeile?.nachrichtId;
    }
    if (konv == null) return null;
    final konversationId = konv;
    final art = switch (op.entity) { 'reaktion' => 'r', 'stimme' => 's', _ => null };
    if (op.entity != 'nachricht' && antwortAuf == null) return null;
    final k = await krypto();
    if (k == null) return null;
    // frischer Stand der Schlüssel (der Abgleich hat vielleicht gerade eine neue Epoche und ihren Wrap geholt)
    await k.aktualisieren();
    if (!klar) {
      final neu = await k.nachrichtNeuVersiegeln(konversationId: konversationId, nachrichtId: op.entityId, wire: text, antwortAuf: antwortAuf, art: art);
      if (neu == null) return null;
      return neu == text ? op.fieldsJson : jsonEncode({...f, feld: neu});
    }
    final wire = await k.nachrichtVersiegeln(konversationId: konversationId, nachrichtId: op.entityId, klartext: text.substring(kPraefixLokal.length), antwortAuf: antwortAuf, art: art);
    if (wire == null) return null;
    return jsonEncode({...f, feld: wire});
  }
}

final chatKryptoProvider = NotifierProvider<ChatKryptoController, int>(ChatKryptoController.new);

/// Nimmt der Server Wraps mit Schlüsselversion an (`GET /version`, `features.wrapKeyVersion`)? Nur dann bietet die App "Verlauf freigeben" an; ein älterer Server meldet es
/// nicht (nichts ändert sich). Ein Fehler (offline) wirft; der Controller wertet ihn als "nein" und fragt beim nächsten Mal erneut.
final serverKannVerlaufFreigebenProvider = FutureProvider<bool>((ref) async => (await ref.read(apiProvider).serverFaehigkeiten()).wrapKeyVersion);

/// Die Sicherheitsereignisse der eigenen Person (`GET /me/security-events`): daraus erkennt die Freigabe, ob der Zugang einer Person vor kurzem zurückgesetzt wurde
/// (Hinweis an die Familie). Ein Fehler wirft; ohne gesicherte Antwort gibt es kein Angebot.
final verlaufFreigabeEreignisseProvider = FutureProvider<List<SicherheitsEreignisDto>>((ref) => ref.read(apiProvider).sicherheitsEreignisse());

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

  @override
  DekodierterInhalt zusatz(ZusatzRef z) => _innen.zusatz(z);
}

/// Hält die Chat-Verschlüsselung am Laufen (am Wurzel-Widget beobachtet, dort wird er nie pausiert, siehe app.dart).
final chatKryptoSteuerungProvider = Provider<void>((ref) {
  final ich = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet ? s.user?.id : null));
  if (ich == null) return;
  Future.microtask(() => ref.read(chatKryptoProvider.notifier).starten());
});

class ChatKryptoController extends Notifier<int> {
  ChatKrypto? _krypto;
  Uint8List? _kEnc;
  Uint8List? _kSign;
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

  /// Neu hinzugekommene Personen je Konversation, die noch keinen Schlüssel bekommen haben und auf die Bestätigung eines Mitglieds warten.
  Map<String, Set<String>> _aufnahmen = const {};
  final Set<String> _verborgen = {};

  /// Wartende Aufnahmen (Konversation -> Personen), ohne die in dieser Sitzung zurückgestellten. Die Oberfläche fragt nach: "X wurde zu Y hinzugefügt – Schlüssel teilen?"
  Map<String, Set<String>> get aufnahmen => {
    for (final e in _aufnahmen.entries)
      if (!_verborgen.contains(e.key)) e.key: e.value,
  };

  /// Zurückstellen (bis zum nächsten Start der App).
  void aufnahmeSpaeter(String konversationId) {
    _verborgen.add(konversationId);
    _anstossen();
  }

  void _aufnahmenSetzen(Map<String, Set<String>> neu) {
    final gleich = neu.length == _aufnahmen.length && neu.entries.every((e) => _aufnahmen[e.key]?.length == e.value.length && _aufnahmen[e.key]!.containsAll(e.value));
    _aufnahmen = neu;
    if (!gleich) _anstossen();
  }

  /// Gibt den Chat-Schlüssel an die neu hinzugekommenen Personen weiter (neue Epoche). Liefert false, wenn das jetzt nicht geht.
  Future<bool> aufnahmeBestaetigen(String konversationId) async {
    final k = await krypto();
    if (k == null) return false;
    await k.aktualisieren();
    await _gateOk(); // Schalter des Servers für die Wraps des geteilten Verlaufs (Wrap-ID v2); ohne Antwort bleibt es bei der ID v1
    final konv = await (_db.select(_db.konversationen)..where((x) => x.id.equals(konversationId))).getSingleOrNull();
    if (konv == null) return false;
    try {
      final plan = await k.rotationNoetig(konversation: konv, teilnehmer: _teilnehmer(konv).toSet());
      if (plan == null || plan.neu.isEmpty) {
        _aufnahmenSetzen({..._aufnahmen}..remove(konversationId));
        return true;
      }
      final aenderungen = await k.epocheErstellen(
        konversationId: konv.id,
        mitglieder: plan.mitglieder,
        historieFuer: konv.art == 'family' ? plan.neu : const {},
        unvertrauteAuslassen: true,
      );
      await ref.read(syncStoreProvider).aendernMehrere(aenderungen);
      _rotiert[konv.id] = DateTime.now();
      _aufnahmenSetzen({..._aufnahmen}..remove(konversationId));
      ref.read(syncProvider.notifier).lokaleAenderung();
      _geplant();
      return true;
    } on SchluesselFehlt {
      return false;
    } on VerschluesselungNichtBereit {
      return false;
    } on CryptoFehler {
      return false;
    }
  }

  /// Verlauf, den dieses Gerät für Personen mit neuem Schlüssel freigeben könnte (Angebote, je Person und Schlüsselstand). Die Oberfläche fragt nach: "Ja, das ist X –
  /// Verlauf freigeben". Es geschieht nie etwas ohne diesen Tipp (kein Auto-Re-Wrap).
  List<VerlaufAngebot> _angebote = const [];
  final Set<String> _freigabeVerborgen = {};

  /// Die Angebote ohne die in dieser Sitzung zurückgestellten.
  List<VerlaufAngebot> get verlaufAngebote => [
    for (final a in _angebote)
      if (!_freigabeVerborgen.contains('${a.userId}:${a.keyVersion}')) a,
  ];

  /// Zurückstellen (bis zum nächsten Start der App).
  void verlaufSpaeter(String userId) {
    for (final a in _angebote) {
      if (a.userId == userId) _freigabeVerborgen.add('${a.userId}:${a.keyVersion}');
    }
    _anstossen();
  }

  /// Gibt den Verlauf für die Person frei (nach ihrem ausdrücklichen Tipp). Liefert null, wenn das jetzt nicht geht (der Hinweis bleibt dann stehen), sonst wie viele Wraps
  /// gesendet werden und wie viele Schlüssel noch im Angebot bleiben (höchstens [kMaxFreigabeWraps] je Tipp). Innerhalb der Wartefrist nach einem Reset der Person
  /// geht es nie (auch wenn die Oberfläche es versuchte).
  Future<VerlaufErgebnis?> verlaufFreigeben(String userId) async {
    final angebot = _angebote.where((a) => a.userId == userId).firstOrNull;
    final frist = angebot?.fruehestens;
    if (frist != null && DateTime.now().isBefore(frist)) return null;
    final k = await krypto();
    if (k == null) return null;
    try {
      await k.aktualisieren();
      final r = await k.verlaufFreigeben(userId, zuruecksetzung: angebot?.zuruecksetzung);
      if (r.gesendet == 0) return null;
      ref.read(syncProvider.notifier).lokaleAenderung();
      unawaited(_angeboteTakt(k));
      return r;
    } on CryptoFehler {
      return null;
    } on VerschluesselungNichtBereit {
      return null;
    }
  }

  bool _angebotLaeuft = false;
  bool _angebotNochmal = false;

  /// Rechnet die Angebote neu, aber nie im Weg: höchstens ein Lauf zugleich, ein Auslöser währenddessen ergibt einen weiteren Lauf. Wartet nie auf das Netz, wer es
  /// nicht abwarten will ([unawaited]).
  Future<void> _angeboteTakt(ChatKrypto k) async {
    if (_angebotLaeuft) {
      _angebotNochmal = true;
      return;
    }
    _angebotLaeuft = true;
    try {
      do {
        _angebotNochmal = false;
        await _angeboteAktualisieren(k);
      } while (_angebotNochmal && ref.mounted);
    } finally {
      _angebotLaeuft = false;
    }
  }

  /// Rechnet die Angebote neu. Das Netz (Fähigkeit des Servers, Sicherheitsereignisse) fragen wir erst, wenn es etwas anzubieten gäbe, und nur zwischengespeichert.
  Future<void> _angeboteAktualisieren(ChatKrypto k) async {
    var neu = const <VerlaufAngebot>[];
    try {
      neu = await k.verlaufAngebote();
      if (neu.isNotEmpty) {
        final ereignisse = await _gateOk() ? await _ereignisseLaden() : null;
        // ohne gesicherte Antwort (älterer Server, offline) gibt es kein Angebot; nie ein Angebot, ohne zu wissen, ob der Zugang der Person zurückgesetzt wurde
        neu = ereignisse == null ? const [] : [for (final a in neu) a.mitZuruecksetzung(_resetZeit(ereignisse, a.userId))];
      }
    } on Object {
      neu = const [];
    }
    if (!ref.mounted) return;
    _angeboteSetzen(neu);
  }

  ({bool wert, DateTime stand})? _gate;
  static const _gateFalschDauer = Duration(minutes: 5);

  /// Nimmt der Server Wraps mit Schlüsselversion an? Ein "ja" gilt für die Sitzung, ein "nein" (älterer Server oder Fehler) nur einige Minuten, danach wird erneut gefragt.
  Future<bool> _gateOk() async {
    final g = _gate;
    final jetzt = DateTime.now();
    if (g != null && (g.wert || jetzt.difference(g.stand) < _gateFalschDauer)) return g.wert;
    try {
      ref.invalidate(serverKannVerlaufFreigebenProvider);
      final v = await ref.read(serverKannVerlaufFreigebenProvider.future);
      _gate = (wert: v, stand: jetzt);
      return v;
    } on Object {
      _gate = (wert: false, stand: jetzt);
      return false;
    }
  }

  ({List<SicherheitsEreignisDto> liste, DateTime stand})? _ereignisse;
  static const _ereignisDauer = Duration(minutes: 2);

  /// Die Sicherheitsereignisse der eigenen Person (zwischengespeichert); null, wenn sie sich nicht laden lassen.
  Future<List<SicherheitsEreignisDto>?> _ereignisseLaden() async {
    final c = _ereignisse;
    final jetzt = DateTime.now();
    if (c != null && jetzt.difference(c.stand) < _ereignisDauer) return c.liste;
    final f = _ereignisFehler;
    if (f != null && jetzt.difference(f) < const Duration(minutes: 1)) return null;
    try {
      ref.invalidate(verlaufFreigabeEreignisseProvider);
      final l = await ref.read(verlaufFreigabeEreignisseProvider.future);
      _ereignisse = (liste: l, stand: jetzt);
      _ereignisFehler = null;
      return l;
    } on Object {
      _ereignisFehler = jetzt;
      return null;
    }
  }

  DateTime? _ereignisFehler;

  /// Wann wurde der Zugang dieser Person zuletzt komplett zurückgesetzt (Hinweis an die Familie, [SicherheitsArt.mitgliedZugangZurueckgesetzt]), sofern der Hinweis jünger
  /// als [kFreigabeResetFenster] ist? Der Abgleich läuft über die KONTO-ID, nie über den Anzeigenamen (ein Umbenennen umgeht die Sperre nicht). Ein Hinweis ohne Kennung
  /// (älterer Server, die betroffene Person ist nicht mehr da) lässt sich nicht zuordnen: fail-closed gilt er für JEDE Person, die Freigabe geht dann den strengen Weg.
  DateTime? _resetZeit(List<SicherheitsEreignisDto> ereignisse, String userId) {
    final grenze = DateTime.now().subtract(kFreigabeResetFenster);
    DateTime? neueste;
    for (final e in ereignisse) {
      if (e.art != SicherheitsArt.mitgliedZugangZurueckgesetzt || e.zeit.isBefore(grenze)) continue;
      final id = e.betroffenerId;
      if (id != null && id.toLowerCase() != userId.toLowerCase()) continue;
      if (neueste == null || e.zeit.isAfter(neueste)) neueste = e.zeit;
    }
    return neueste;
  }

  void _angeboteSetzen(List<VerlaufAngebot> neu) {
    bool gleich() {
      if (neu.length != _angebote.length) return false;
      for (var i = 0; i < neu.length; i++) {
        final a = neu[i], b = _angebote[i];
        if (a.userId != b.userId || a.keyVersion != b.keyVersion || a.anzahl != b.anzahl || a.chats != b.chats || a.zuruecksetzung != b.zuruecksetzung) return false;
      }
      return true;
    }

    final aenderung = !gleich();
    _angebote = neu;
    if (aenderung) _anstossen();
  }

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
    _inhalt?.leeren(); // Neuaufbau (andere Person, Abmelden): nichts Entschlüsseltes bleibt im Speicher
    _aufnahmen = const {};
    _verborgen.clear();
    _angebote = const [];
    _freigabeVerborgen.clear();
    _gate = null;
    _ereignisse = null;
    _ereignisFehler = null;
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
        if (alt?.vertrauenDefekt == true && !neu.vertrauenDefekt) _krypto?.standVergessen();
        _krypto?.vertrauenGeaendert();
        // was bisher nicht lesbar war, wird mit dem neuen Stand des Vertrauens (bestätigte Warnung, neue Mitglieder) erneut versucht
        _inhalt?.fehlschlaegeVergessen();
        _anstossen();
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
      final feld = kVerschluesselteFelder[o.entity];
      if (feld == null || o.op != 'upsert' || !o.fieldsJson.contains(kPraefixLokal)) continue;
      try {
        final f = jsonDecode(o.fieldsJson);
        if (f is Map && f[feld] is String && (f[feld] as String).startsWith(kPraefixLokal)) ids.add(o.entityId);
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
    unawaited(_gateOk()); // den Schalter des Servers (Wrap-ID v2) im Hintergrund erfragen, damit "Verlauf teilen" ihn kennt
  }

  /// Aktuelle Mitglieder und ihre Schlüssel beim Server holen (neue Schlüssel, Entfernte). Höchstens alle [kMitgliederAbstand], sofort mit [erzwingen].
  Future<void> mitgliederAktualisieren({bool erzwingen = false}) async {
    final jetzt = DateTime.now();
    final stand = _mitgliederStand;
    if (!erzwingen && stand != null && jetzt.difference(stand) < kMitgliederAbstand) return;
    _mitgliederStand = jetzt;
    try {
      await ref.read(e2eeProvider.notifier).laden();
      final e = ref.read(e2eeProvider);
      // nur ein gelungener Abruf zählt für die Erkennung entfernter Personen
      if (e.status != E2eeStatus.nichtVerfuegbar && e.mitglieder.isNotEmpty) _krypto?.mitgliederBeobachtet();
    } on Object {
      // offline: der Schlüsselbund arbeitet mit dem, was lokal da ist
    }
    _inhalt?.fehlschlaegeVergessen();
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
    // derselbe Personenschlüssel (E2eeController.laden() liest ihn jedes Mal neu ein: nach den öffentlichen Teilen vergleichen, nicht nach dem Objekt)
    if (vorhanden != null && _kVersion == version && _kBesitzer == ich && _kEnc != null && gleicheBytes(_kEnc!, pk.encOeffentlich) && gleicheBytes(_kSign!, pk.signOeffentlich)) return vorhanden;
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
      gemerkt: (u, {version}) => pruefer.gemerkterSchluessel(u, version: version),
      serverSchluessel: _serverSchluessel,
      // der Schalter des Servers (Wrap-ID v2); unbekannt gilt als nein (alter Weg). Die Frage läuft im Hintergrund und wird zwischengespeichert.
      wrapV2Erlaubt: () => _gate?.wert == true,
      absenderSchluessel: (u, v) => e2ee.absenderSchluessel(u, v),
      standLaden: (konv) async {
        final s = await pruefer.standLaden(konv);
        return s == null ? null : AkzeptierterStand(s.epochen, s.liste);
      },
      standSpeichern: (konv, s) => pruefer.standSpeichern(konv, s.epochen, s.liste),
    );
    _krypto = neu;
    _kEnc = Uint8List.fromList(pk.encOeffentlich);
    _kSign = Uint8List.fromList(pk.signOeffentlich);
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
        if (k.standDefekt && !ref.read(e2eeProvider).vertrauenDefekt) unawaited(ref.read(e2eeProvider.notifier).laden());
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

  /// Epochen pflegen: erste Epoche für Konversationen ohne, neue Epoche bei Entfernten, bestätigten Schlüsselwechseln und unlesbarer Epoche (Selbstheilung),
  /// verlorene Wraps nachreichen. Neu hinzugekommene Personen warten auf die Bestätigung ([aufnahmen]). Nur mit frischem Stand der Mitglieder vom Server.
  Future<void> _pflegen(ChatKrypto k) async {
    final e = ref.read(e2eeProvider);
    if (e.status != E2eeStatus.bereit || e.mitglieder.isEmpty) {
      _angeboteSetzen(const []);
      return;
    }
    unawaited(_angeboteTakt(k)); // nie im Weg: das Netz (Fähigkeit, Ereignisse) hält die Pflege der Epochen nicht auf
    final jetzt = DateTime.now();
    final aufnahmen = <String, Set<String>>{};
    final kandidaten = <Konversation>[];
    for (final konv in await _db.select(_db.konversationen).get()) {
      if (konv.encVersion != 'e1' || konv.rev == 0) continue;
      final teilnehmer = _teilnehmer(konv).toSet();
      final erste = await k.ersteEpocheNoetig(konversation: konv, teilnehmer: teilnehmer);
      final rot = erste == null ? await k.rotationNoetig(konversation: konv, teilnehmer: teilnehmer) : null;
      if (rot != null && rot.neu.isNotEmpty) aufnahmen[konv.id] = rot.neu;
      if (erste == null && !(rot?.automatisch ?? false)) {
        await _wrapsNachreichen(k, konv.id);
        continue;
      }
      final letzte = _rotiert[konv.id];
      if (letzte != null && jetzt.difference(letzte) < const Duration(seconds: 30)) continue;
      kandidaten.add(konv);
    }
    _aufnahmenSetzen(aufnahmen);
    if (kandidaten.isEmpty) return;
    // nicht alle Geräte gleichzeitig: EINMAL je Lauf kurz warten und neu prüfen (der erste Schreiber gewinnt, die anderen übernehmen seine Epoche)
    await Future<void>.delayed(ref.read(chatKryptoVersatzProvider)());
    if (!ref.mounted) return;
    for (final konv in kandidaten) {
      final frisch = await (_db.select(_db.konversationen)..where((t) => t.id.equals(konv.id))).getSingleOrNull();
      if (frisch == null) continue;
      final teil = _teilnehmer(frisch).toSet();
      final erste = await k.ersteEpocheNoetig(konversation: frisch, teilnehmer: teil);
      final rot = erste == null ? await k.rotationNoetig(konversation: frisch, teilnehmer: teil) : null;
      if (erste == null && !(rot?.automatisch ?? false)) continue;
      try {
        final aenderungen = await k.epocheErstellen(
          konversationId: konv.id,
          // automatisch nie an Neue: sie warten auf die Bestätigung
          mitglieder: erste ?? rot!.automatischeMitglieder,
          unvertrauteAuslassen: true,
        );
        await ref.read(syncStoreProvider).aendernMehrere(aenderungen);
        _rotiert[konv.id] = DateTime.now();
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

  /// Wraps der eigenen Epoche, die lokal fehlen (abgelehnt, verloren), nach einer Wartezeit erneut erzeugen.
  Future<void> _wrapsNachreichen(ChatKrypto k, String konversationId) async {
    try {
      final fehlend = await k.fehlendeWraps(konversationId);
      if (fehlend.isEmpty) return;
      final aenderungen = await k.wrapsNachreichen(konversationId, fehlend);
      if (aenderungen.isEmpty) return;
      await ref.read(syncStoreProvider).aendernMehrere(aenderungen);
      ref.read(syncProvider.notifier).lokaleAenderung();
    } on CryptoFehler {
      // nichts nachreichen
    }
  }
}
