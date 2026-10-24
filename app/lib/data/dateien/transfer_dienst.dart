// Warteschlange der Übertragungen (Abschnitt 6n): Uploads (tus, fortsetzbar) und Downloads (Range, fortsetzbar) mit Zustand, Fortschritt und Fehlercode in der lokalen Tabelle `transfers`.
//
// Upload: Quelle prüfen (Größe vorab gegen `GET /files/usage`), tus-Upload anlegen und in Abschnitten von 4 MiB senden, bei Bildern ein Vorschaubild (clientseitig, ohne EXIF/GPS) als zweiter
// Upload der Art `thumb`; danach legt das Repository Datei und Fassung mit der Upload-ID in EINEM Sync-Stapel an (der Server beansprucht den Blob atomar, "Claim"). Lehnt der Server das
// Anlegen ab (`invalid_reference`: Upload nicht mehr gültig; `nr_belegt`: ein anderes Gerät war mit derselben Nummer schneller), steht der Transfer wieder auf `fehler` (`SyncEntity.nachAblehnung`):
// "Wiederholen" legt die Fassung neu an bzw. lädt neu hoch.
//
// Fortsetzen: nach einem Abbruch (Netz weg, App beendet) fragt der Dienst per HEAD den Stand des Servers ab und macht dort weiter. Android hält den Pfad der Datei (Quelle bleibt lesbar); im Web ist
// die Datei nach dem Neuladen weg: der Transfer steht auf `datei_noetig`, die Person wählt sie erneut ([quelleLiefern]). Verschlüsselte Anhänge (`anhang`) sind nach einem Neustart nicht fortsetzbar
// (der Zufallsschlüssel der Datei lebt nur im Arbeitsspeicher): dort heißt es "neu wählen".
//
// Parallelität: höchstens [maxParallel] (3) Übertragungen gleichzeitig; nach dem Start der App setzt der Dienst die liegengebliebenen Übertragungen nur EINE nach der anderen fort (Vordergrund-Fortsetzung).
// Fehler: Netz, Überlast, 429, 423 und 503 werden mit Wartezeit (Retry-After, sonst exponentiell bis 5 Minuten) bis zu [maxVersuche] Mal wiederholt; Speicher voll, zu groß und ungültige Dateien
// sofort endgültig. Token-Erneuerung läuft nur über den serialisierten Weg des ApiClient. Nie Dateiinhalt, Dateiname oder Pfad ins Log.
import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../avatar/bild_aufbereiten.dart';
import '../database_provider.dart';
import '../sync/sync_store.dart' show neueUuid;
import 'datei_cache_dienst.dart';
import 'datei_logik.dart';
import 'datei_modelle.dart';
import 'datei_ort.dart';
import 'datei_repository.dart';
import 'transfer_modelle.dart';
import 'tus_client.dart';
import 'upload_quelle.dart';

/// Erzeugt aus den Bytes eines Bildes ein Vorschaubild (PNG, höchstens 256 KiB, ohne EXIF/GPS); null, wenn es nicht geht (die Datei wird dann ohne Vorschau hochgeladen).
typedef ThumbErzeuger = Future<Uint8List?> Function(Uint8List quelle);

/// Legt den Datensatz eines verschlüsselten Anhangs an, sobald der Chiffretext oben ist ([blobId]); lebt nur im Arbeitsspeicher (der Dateischlüssel steckt darin).
typedef AnhangAbschluss = Future<void> Function(String blobId, String? sha256);

/// Standard: das vorhandene `bildAufbereiten` (quadratisch zugeschnitten auf etwa 512 Pixel, als PNG neu kodiert: damit fallen EXIF und GPS weg).
Future<Uint8List?> standardThumbErzeuger(Uint8List quelle) async {
  try {
    return (await bildAufbereiten(quelle, kante: kThumbKante, zielBytes: kThumbZielBytes)).bytes;
  } on Object {
    return null;
  }
}

/// Ab so vielen Byte (Rest aller aktiven Übertragungen) oder so vielen Übertragungen verlangt der Dienst den Vordergrunddienst.
const int kHintergrundAbBytes = 20 * 1024 * 1024;
const int kHintergrundAbAnzahl = 3;

class TransferDienst {
  final AppDatabase db;
  final DateiRepository repo;
  final TusClient tus;
  final FampadApi api;
  final DateiCacheDienst cache;
  final TransferHintergrundPort hintergrund;
  final ThumbErzeuger _thumb;
  final DateTime Function() _jetzt;
  final String Function() _neueId;
  final Duration Function(int versuche) _backoff;
  final int maxParallel;
  final int maxVersuche;

  TransferDienst({
    required this.db,
    required this.repo,
    required this.tus,
    required this.api,
    required this.cache,
    this.hintergrund = const KeinTransferHintergrund(),
    ThumbErzeuger? thumb,
    DateTime Function()? jetzt,
    String Function()? neueId,
    Duration Function(int versuche)? backoff,
    this.maxParallel = kMaxParalleleUploads,
    this.maxVersuche = 8,
  }) : _thumb = thumb ?? standardThumbErzeuger,
       _jetzt = jetzt ?? DateTime.now,
       _neueId = neueId ?? neueUuid,
       _backoff = backoff ?? _standardBackoff;

  /// 2, 4, 8 … Sekunden, höchstens 5 Minuten.
  static Duration _standardBackoff(int versuche) => Duration(seconds: math.min(300, 2 * math.pow(2, math.max(0, versuche - 1)).toInt()));

  final Map<String, UploadQuelle> _quellen = {};
  final Map<String, AnhangAbschluss> _abschluesse = {};
  final Map<String, AbbruchToken> _tokens = {};
  final Set<String> _laufend = {};

  /// Übertragungen, die beim Start liegengeblieben waren: sie laufen nur eine nach der anderen (Vordergrund-Fortsetzung).
  final Set<String> _fortsetzung = {};
  Timer? _timer;
  bool _beendet = false;
  bool _scannt = false;
  bool _nochmal = false;
  bool _hgAktiv = false;
  final Map<String, int> _netzVersuche = {};

  // ------------------------------------------------------------------ Lesen

  /// Alle Übertragungen, neueste zuerst.
  Stream<List<TransferZeile>> transfers() => (db.select(db.transfers)..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.id)])).watch();

  Future<TransferZeile?> transfer(String id) => (db.select(db.transfers)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<TransferZeile>> alle() => (db.select(db.transfers)..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)])).get();

  /// Zahlen des Servers; ohne Antwort (offline) die Standardgrenzen (der Server prüft ohnehin selbst).
  Future<DateiNutzung> nutzung() async {
    try {
      return await api.dateiNutzung();
    } on ApiException {
      return DateiNutzung.standard;
    }
  }

  /// Passt eine Datei der Größe [groesse] in die Grenzen? Liefert den Grund oder null (Hinweis vorab bei Größen- und Quotenfehlern, bevor ein Upload anfängt).
  Future<DateiFehler?> vorabPruefen(int groesse, {bool e2ee = false}) async => groessePruefen(groesse, await nutzung(), e2ee: e2ee);

  // ------------------------------------------------------------------ Upload einreihen

  Future<TransferZeile> _anlegen({
    required TransferArt art,
    required String name,
    required UploadQuelle quelle,
    String? quellePfad,
    String? mime,
    String? ordnerId,
    String? dateiId,
    String? versionId,
    String? audience,
    String? konversationId,
  }) async {
    final id = _neueId();
    final jetzt = _jetzt();
    await db.into(db.transfers).insert(
      TransfersCompanion.insert(
        id: id,
        richtung: art.hoch ? 'hoch' : 'runter',
        art: art.wire,
        zustand: TransferZustand.wartet.wire,
        name: name,
        mime: Value(mime),
        groesse: Value(quelle.laenge),
        ordnerId: Value(ordnerId),
        dateiId: Value(dateiId),
        versionId: Value(versionId),
        audience: Value(audience),
        konversationId: Value(konversationId),
        quellePfad: Value(quellePfad),
        createdAt: jetzt,
        aktualisiertAt: jetzt,
      ),
    );
    _quellen[id] = quelle;
    unawaited(_anstossen());
    return (await transfer(id))!;
  }

  Future<String?> _kopfMime(UploadQuelle q, String name) async {
    try {
      return mimeFuerUpload(name, await q.lies(0, 16));
    } on Object {
      return null;
    }
  }

  /// Reiht eine NEUE Datei zum Hochladen ein (Modus `server`). Prüft vorab Name, Rechte, Zielordner und Größe; wirft [DateiFehler]. [quellePfad] (Android) erlaubt das Fortsetzen nach einem
  /// Neustart der App. Liefert die ID der Übertragung.
  Future<String> hochladenDatei({required String name, required UploadQuelle quelle, String? quellePfad, String? ordnerId, String audience = kStufeFamilie}) async {
    final n = await repo.neueDateiPruefen(name: name, ordnerId: ordnerId, audience: audience);
    final fehler = await vorabPruefen(quelle.laenge);
    if (fehler != null) throw fehler;
    final z = await _anlegen(
      art: TransferArt.datei,
      name: n,
      quelle: quelle,
      quellePfad: quellePfad,
      mime: await _kopfMime(quelle, n),
      ordnerId: ordnerId,
      dateiId: _neueId(),
      versionId: _neueId(),
      audience: audience,
    );
    return z.id;
  }

  /// Reiht eine neue FASSUNG einer vorhandenen Datei ein (Kinder nur für eigene Dateien).
  Future<String> hochladenFassung({required String dateiId, required UploadQuelle quelle, String? quellePfad}) async {
    final d = await repo.neueFassungPruefen(dateiId);
    final fehler = await vorabPruefen(quelle.laenge);
    if (fehler != null) throw fehler;
    final z = await _anlegen(art: TransferArt.fassung, name: d.name, quelle: quelle, quellePfad: quellePfad, mime: await _kopfMime(quelle, d.name), dateiId: dateiId, versionId: _neueId());
    return z.id;
  }

  /// Reiht den Upload eines VERSCHLÜSSELTEN Anhangs ein (Modus `e2ee`): [quelle] sind die Chiffretext-Bytes, [abschluss] legt den Datensatz an (Anzeigename nur für die Liste der Übertragungen).
  /// Beides lebt nur im Arbeitsspeicher: nach einem Neustart ist der Transfer nicht fortsetzbar.
  Future<String> hochladenAnhang({required String anhangId, required String konversationId, required String anzeigeName, required UploadQuelle quelle, required AnhangAbschluss abschluss}) async {
    final fehler = await vorabPruefen(quelle.laenge, e2ee: true);
    if (fehler != null) throw fehler;
    final z = await _anlegen(art: TransferArt.anhang, name: anzeigeName, quelle: quelle, versionId: anhangId, konversationId: konversationId);
    _abschluesse[z.id] = abschluss;
    return z.id;
  }

  /// Reiht einen Download ein (Android: ins Cache-Verzeichnis, fortsetzbar über Range). [groesse] und optional [sha256] (Klartext, aus der Fassung) prüft der Dienst nach dem Laden.
  /// Gibt es die Datei schon im Cache, liefert [herunterladen] eine fertige Übertragung ohne Netzzugriff.
  Future<String> herunterladen({required String blobId, required String name, required int groesse, String? mime, String? sha256, String? dateiId, String? versionId}) async {
    if (!cache.verfuegbar) throw DateiFehler.nichtVerfuegbar;
    final id = _neueId();
    final jetzt = _jetzt();
    final vorhanden = await cache.pfadFuer(blobId);
    await db.into(db.transfers).insert(
      TransfersCompanion.insert(
        id: id,
        richtung: 'runter',
        art: TransferArt.runter.wire,
        zustand: (vorhanden != null ? TransferZustand.fertig : TransferZustand.wartet).wire,
        name: name,
        mime: Value(mime),
        groesse: Value(groesse),
        uebertragen: Value(vorhanden != null ? groesse : 0),
        blobId: Value(blobId),
        sha256: Value(sha256),
        dateiId: Value(dateiId),
        versionId: Value(versionId),
        zielPfad: Value(vorhanden),
        createdAt: jetzt,
        aktualisiertAt: jetzt,
      ),
    );
    unawaited(_anstossen());
    return id;
  }

  // ------------------------------------------------------------------ Steuern

  /// Bricht eine Übertragung ab (läuft sie, endet sie zwischen zwei Abschnitten; der angefangene Upload wird beim Server verworfen).
  Future<void> abbrechen(String id) async {
    final t = _tokens[id];
    if (t != null) {
      t.abbrechen();
      return;
    }
    final z = await transfer(id);
    if (z == null || !z.zustandTyp.aktiv && z.zustandTyp != TransferZustand.dateiNoetig && z.zustandTyp != TransferZustand.fehler) return;
    await _setze(id, const TransfersCompanion(zustand: Value('abgebrochen')));
    await _verwerfe(z);
    await _aufraeumenQuelle(id);
    _hintergrundPflegen();
  }

  /// Versucht eine fehlgeschlagene, abgebrochene oder auf die Datei wartende Übertragung erneut. [quelle] ersetzt eine fehlende Quelle (Web nach dem Neuladen: die Person wählt die Datei erneut).
  /// `invalid_reference`: neu hochladen (eine dabei hinterlassene Datei ohne Fassung wird entfernt); `nr_belegt`: nur die Fassung mit neuer Nummer anlegen.
  Future<void> wiederholen(String id, {UploadQuelle? quelle}) async {
    final z = await transfer(id);
    if (z == null || z.zustandTyp.aktiv && z.zustandTyp != TransferZustand.wartet) return;
    if (z.zustandTyp == TransferZustand.fertig) return;
    if (quelle != null) {
      if (quelle.laenge != z.groesse && z.uebertragen < z.groesse) {
        await _setze(id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('datei_geaendert')));
        return;
      }
      _quellen[id] = quelle;
    }
    if (z.artTyp == TransferArt.anhang && !_abschluesse.containsKey(id)) {
      await _setze(id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('anhang_neu')));
      return;
    }
    var c = const TransfersCompanion(zustand: Value('wartet'), fehlerCode: Value(null), versuche: Value(0), naechsterVersuch: Value(null));
    if (z.fehlerCode == 'invalid_reference' && z.artTyp.hoch) {
      // der Upload ist beim Server nicht mehr gültig: neu hochladen; die Datei, die der abgelehnte Stapel hinterlassen hat, entfällt
      if (z.artTyp == TransferArt.datei && z.dateiId != null) await repo.verwaisteDateiEntfernen(z.dateiId!);
      c = c.copyWith(
        blobId: const Value(null),
        thumbBlobId: const Value(null),
        uebertragen: const Value(0),
        versionId: Value(z.artTyp == TransferArt.anhang ? z.versionId : _neueId()),
        dateiId: Value(z.artTyp == TransferArt.datei ? _neueId() : z.dateiId),
      );
    }
    await _setze(id, c);
    unawaited(_anstossen());
  }

  /// Liefert die Quelle einer Übertragung, die auf die Datei wartet (Web nach dem Neuladen; Android, wenn der Pfad nicht mehr gilt).
  Future<void> quelleLiefern(String id, UploadQuelle quelle) => wiederholen(id, quelle: quelle);

  /// Entfernt eine beendete Übertragung (fertig, fehlgeschlagen, abgebrochen) aus der Liste; laufende nie.
  Future<void> entfernen(String id) async {
    final z = await transfer(id);
    if (z == null || z.zustandTyp == TransferZustand.laeuft || z.zustandTyp == TransferZustand.wartet) return;
    if (z.zustandTyp == TransferZustand.fehler || z.zustandTyp == TransferZustand.dateiNoetig) await _verwerfe(z);
    await (db.delete(db.transfers)..where((t) => t.id.equals(id))).go();
    await _aufraeumenQuelle(id);
  }

  /// Entfernt alle erledigten Übertragungen ("Erledigte entfernen").
  Future<void> erledigteEntfernen() => (db.delete(db.transfers)..where((t) => t.zustand.isIn([TransferZustand.fertig.wire, TransferZustand.abgebrochen.wire]))).go();

  /// Nach dem Start der App: liegengebliebene Übertragungen (laufend oder beim Abschließen unterbrochen) kommen wieder in die Schlange und werden EINE nach der anderen fortgesetzt.
  /// Übertragungen ohne lesbare Quelle (Web) stehen danach auf `datei_noetig`, verschlüsselte Anhänge auf `fehler` (`anhang_neu`).
  Future<void> wiederaufnehmen() async {
    final offen = await (db.select(db.transfers)..where((t) => t.zustand.isIn(['laeuft', 'abschliessen', 'wartet']))).get();
    for (final z in offen) {
      if (_laufend.contains(z.id)) continue;
      _fortsetzung.add(z.id);
      if (z.zustandTyp != TransferZustand.wartet) await _setze(z.id, const TransfersCompanion(zustand: Value('wartet')));
    }
    await _anstossen();
  }

  /// Hält alles an und räumt auf (Abmelden): laufende Übertragungen enden, Quellen werden geschlossen; die Tabelle leert der Wiper. Danach ist der Dienst unbrauchbar.
  Future<void> beenden() async {
    _beendet = true;
    _timer?.cancel();
    for (final t in _tokens.values) {
      t.abbrechen();
    }
    for (final id in [..._quellen.keys]) {
      await _aufraeumenQuelle(id);
    }
    _abschluesse.clear();
    if (_hgAktiv) {
      _hgAktiv = false;
      try {
        await hintergrund.beenden();
      } on Object {
        // der Dienst selbst endet mit dem Prozess
      }
    }
  }

  /// Für Tests: wartet, bis nichts mehr läuft und nichts mehr fällig ist (Wartende mit späterem Versuch zählen nicht).
  Future<void> warteBisRuhig() async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < const Duration(seconds: 20)) {
      await _anstossen();
      if (_laufend.isEmpty && !_scannt && (await _naechste()).isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  // ------------------------------------------------------------------ Schlange

  Future<void> _setze(String id, TransfersCompanion c) => (db.update(db.transfers)..where((t) => t.id.equals(id))).write(c.copyWith(aktualisiertAt: Value(_jetzt())));

  /// Fällige Übertragungen in der Reihenfolge ihrer Anlage.
  Future<List<TransferZeile>> _naechste() async {
    final jetzt = _jetzt();
    final l = await (db.select(db.transfers)
          ..where((t) => t.zustand.equals('wartet'))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)]))
        .get();
    return [
      for (final z in l)
        if (!_laufend.contains(z.id) && (z.naechsterVersuch == null || !z.naechsterVersuch!.isAfter(jetzt))) z,
    ];
  }

  /// Startet, was dran ist und Platz hat; plant einen Timer für den nächsten Versuch. Nie zwei Scans gleichzeitig.
  Future<void> _anstossen() async {
    if (_beendet) return;
    if (_scannt) {
      _nochmal = true;
      return;
    }
    _scannt = true;
    try {
      do {
        _nochmal = false;
        for (final z in await _naechste()) {
          if (_laufend.length >= maxParallel) break;
          // Vordergrund-Fortsetzung: liegengebliebene Übertragungen höchstens eine zugleich
          if (_fortsetzung.contains(z.id) && _laufend.any(_fortsetzung.contains)) continue;
          _laufend.add(z.id);
          unawaited(_lauf(z.id));
        }
      } while (_nochmal && !_beendet);
      await _timerPlanen();
      _hintergrundPflegen();
    } finally {
      _scannt = false;
    }
  }

  Future<void> _timerPlanen() async {
    _timer?.cancel();
    _timer = null;
    final l = await (db.select(db.transfers)..where((t) => t.zustand.equals('wartet') & t.naechsterVersuch.isNotNull())).get();
    DateTime? fruehestens;
    for (final z in l) {
      final v = z.naechsterVersuch!;
      if (fruehestens == null || v.isBefore(fruehestens)) fruehestens = v;
    }
    if (fruehestens == null || _beendet) return;
    final warte = fruehestens.difference(_jetzt());
    _timer = Timer(warte.isNegative ? Duration.zero : warte, () => unawaited(_anstossen()));
  }

  /// Vordergrunddienst für größere Stapel: ab [kHintergrundAbBytes] Restgröße oder [kHintergrundAbAnzahl] aktiven Übertragungen; beendet, wenn nichts mehr aktiv ist.
  void _hintergrundPflegen() {
    unawaited(() async {
      try {
        final l = await (db.select(db.transfers)..where((t) => t.zustand.isIn(['wartet', 'laeuft', 'abschliessen']))).get();
        final rest = l.fold<int>(0, (s, z) => s + (z.groesse - z.uebertragen));
        final gesamt = l.fold<int>(0, (s, z) => s + z.groesse);
        if (l.isEmpty) {
          if (_hgAktiv) {
            _hgAktiv = false;
            await hintergrund.beenden();
          }
          return;
        }
        if (!_hgAktiv && !_beendet && (rest >= kHintergrundAbBytes || l.length >= kHintergrundAbAnzahl)) {
          _hgAktiv = true;
          await hintergrund.starten(anzahl: l.length);
        }
        if (_hgAktiv) await hintergrund.aktualisieren(anzahl: l.length, prozent: gesamt <= 0 ? 0 : (100 - (rest * 100 ~/ gesamt)).clamp(0, 100));
      } on Object {
        // die Anzeige des Hintergrunddienstes darf eine Übertragung nie stören
      }
    }());
  }

  // ------------------------------------------------------------------ Ein Lauf

  Future<void> _lauf(String id) async {
    final abbruch = AbbruchToken();
    _tokens[id] = abbruch;
    try {
      final z = await transfer(id);
      if (z == null || z.zustandTyp != TransferZustand.wartet) return;
      await _setze(id, const TransfersCompanion(zustand: Value('laeuft'), fehlerCode: Value(null)));
      if (z.artTyp == TransferArt.runter) {
        await _laufRunter(z, abbruch);
      } else {
        await _laufHoch(z, abbruch);
      }
    } on TusAbgebrochen {
      final z = await transfer(id);
      await _setze(id, const TransfersCompanion(zustand: Value('abgebrochen')));
      if (z != null) await _verwerfe(z);
      await _aufraeumenQuelle(id);
    } on TusFehler catch (e) {
      await _fehlerBehandeln(id, e);
    } on DateiFehler catch (e) {
      // Rechte, Name oder Zielordner haben sich seit dem Einreihen geändert: endgültig
      await _setze(id, TransfersCompanion(zustand: const Value('fehler'), fehlerCode: Value(e.code)));
    } on ApiException catch (e) {
      // keine Verbindung oder abgelaufene Sitzung: später erneut, ohne den Zähler zu belasten (die Sitzung kommt mit der nächsten Anmeldung zurück)
      await _spaeter(id, e.code.isEmpty ? 'network' : e.code, null, zaehlen: !(e.kind == ApiErrorKind.nichtAngemeldet || e.kind == ApiErrorKind.netzwerk));
    } on Object {
      // lokaler Fehler (Platte voll, Datei nicht lesbar): nie den Inhalt melden
      await _setze(id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('lokal')));
    } finally {
      _tokens.remove(id);
      _laufend.remove(id);
      _fortsetzung.remove(id);
      unawaited(_anstossen());
    }
  }

  Future<void> _fehlerBehandeln(String id, TusFehler e) async {
    switch (e.folge) {
      case TusFolge.aufgeben:
        await _setze(id, TransfersCompanion(zustand: const Value('fehler'), fehlerCode: Value(e.code)));
        await _verwerfeServerseitig(id);
      case TusFolge.neuBeginnen:
        // der Server kennt den Upload nicht mehr (24 Stunden): von vorn, höchstens ein paar Mal
        final z = await transfer(id);
        if (z == null) return;
        if (z.versuche + 1 >= maxVersuche) {
          await _setze(id, TransfersCompanion(zustand: const Value('fehler'), fehlerCode: Value(e.code)));
          return;
        }
        await _setze(id, TransfersCompanion(zustand: const Value('wartet'), blobId: const Value(null), thumbBlobId: const Value(null), uebertragen: const Value(0), versuche: Value(z.versuche + 1), fehlerCode: Value(e.code)));
      case TusFolge.spaeter:
        await _spaeter(id, e.code, e.warte, zaehlen: e.code != 'network' && e.code != 'timeout' && e.code != 'maintenance' && e.code != 'unauthenticated');
    }
  }

  /// Wartet auf den nächsten Versuch. Mit [zaehlen] steigt der Zähler (nach [maxVersuche] ist Schluss: `fehler`); Netz- und Wartungsfehler zählen nicht (es geht weiter, sobald es wieder geht).
  Future<void> _spaeter(String id, String code, Duration? warte, {required bool zaehlen}) async {
    final z = await transfer(id);
    if (z == null) return;
    final versuche = zaehlen ? z.versuche + 1 : z.versuche;
    if (zaehlen && versuche >= maxVersuche) {
      await _setze(id, TransfersCompanion(zustand: const Value('fehler'), fehlerCode: Value(code), versuche: Value(versuche)));
      return;
    }
    // Netzfehler zählen nicht gegen [maxVersuche], die Wartezeit wächst aber trotzdem (eigener Zähler im Arbeitsspeicher)
    final n = zaehlen ? versuche : (_netzVersuche[id] = (_netzVersuche[id] ?? 0) + 1);
    var pause = _backoff(n);
    if (warte != null && warte > pause) pause = warte;
    await _setze(id, TransfersCompanion(zustand: const Value('wartet'), fehlerCode: Value(code), versuche: Value(versuche), naechsterVersuch: Value(_jetzt().add(pause))));
  }

  // ------------------------------------------------------------------ Upload

  Future<UploadQuelle?> _quelleFuer(TransferZeile z) async {
    final im = _quellen[z.id];
    if (im != null) return im;
    final pfad = z.quellePfad;
    if (pfad == null) return null;
    final q = await UploadQuelle.ausPfad(pfad);
    if (q != null) _quellen[z.id] = q;
    return q;
  }

  Map<String, String> _metadaten(TransferZeile z) {
    if (z.artTyp == TransferArt.anhang) return const {'modus': 'e2ee', 'kind': 'opak'};
    return {'modus': 'server', 'kind': 'datei', if (z.mime != null) 'mime': z.mime!};
  }

  Future<void> _laufHoch(TransferZeile z0, AbbruchToken abbruch) async {
    var z = z0;
    final fertigOben = z.blobId != null && z.groesse > 0 && z.uebertragen >= z.groesse;
    if (!fertigOben) {
      final quelle = await _quelleFuer(z);
      if (quelle == null) {
        // Web nach dem Neuladen oder die Datei ist weg: die Person wählt sie noch einmal
        await _setze(z.id, TransfersCompanion(zustand: const Value('datei_noetig'), fehlerCode: Value(z.quellePfad != null ? 'quelle_fehlt' : null)));
        return;
      }
      if (quelle.laenge != z.groesse) {
        await _setze(z.id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('datei_geaendert')));
        return;
      }
      var blobId = z.blobId;
      var ab = 0;
      if (blobId != null) {
        final s = await tus.status(blobId); // 404 -> TusFehler (neuBeginnen): der Aufrufer beginnt von vorn
        ab = s.offset;
      } else {
        blobId = await tus.anlegen(laenge: quelle.laenge, metadaten: _metadaten(z));
        await _setze(z.id, TransfersCompanion(blobId: Value(blobId), uebertragen: const Value(0)));
      }
      final id = z.id;
      final ergebnis = await tus.hochladen(
        blobId,
        quelle,
        ab: ab,
        abbruch: abbruch,
        fortschritt: (o) => unawaited(_setze(id, TransfersCompanion(uebertragen: Value(o)))),
      );
      await _setze(id, TransfersCompanion(blobId: Value(ergebnis.blobId), uebertragen: Value(quelle.laenge), sha256: Value(ergebnis.sha256)));
      z = (await transfer(id))!;
      if (abbruch.abgebrochen) throw const TusAbgebrochen();
      // Vorschaubild für Bilder: nie ein Grund zu scheitern
      if ((z.artTyp == TransferArt.datei || z.artTyp == TransferArt.fassung) && z.thumbBlobId == null) {
        final thumbId = await _thumbHochladen(quelle, z);
        if (thumbId != null) await _setze(id, TransfersCompanion(thumbBlobId: Value(thumbId)));
        z = (await transfer(id))!;
      }
    }
    await _abschliessen(z);
  }

  Future<String?> _thumbHochladen(UploadQuelle quelle, TransferZeile z) async {
    if (!kannVorschaubild(z.mime) || quelle.laenge > kThumbQuelleMaxBytes) return null;
    try {
      final bytes = await quelle.lies(0, quelle.laenge);
      final thumb = await _thumb(bytes);
      if (thumb == null || thumb.isEmpty || thumb.length > kMaxThumbBytes) return null;
      final id = await tus.anlegen(laenge: thumb.length, metadaten: const {'modus': 'server', 'kind': 'thumb', 'mime': 'image/png'});
      final r = await tus.hochladen(id, SpeicherQuelle(thumb));
      return r.blobId;
    } on Object {
      return null; // ohne Vorschau weiter
    }
  }

  /// Alle Bytes sind oben: Datensatz anlegen (Claim im Sync-Stapel). Idempotent (Neustart zwischen Anlegen und `fertig`).
  Future<void> _abschliessen(TransferZeile z) async {
    await _setze(z.id, const TransfersCompanion(zustand: Value('abschliessen')));
    final blobId = z.blobId!;
    switch (z.artTyp) {
      case TransferArt.datei:
        final d = await (db.select(db.dateien)..where((t) => t.id.equals(z.dateiId!))).getSingleOrNull();
        final v = await (db.select(db.dateiVersionen)..where((t) => t.id.equals(z.versionId!))).getSingleOrNull();
        if (d == null) {
          await repo.dateiMitFassungAnlegen(
            dateiId: z.dateiId!,
            versionId: z.versionId!,
            name: z.name,
            ordnerId: z.ordnerId,
            audience: z.audience ?? kStufeFamilie,
            blobId: blobId,
            thumbBlobId: z.thumbBlobId,
            groesse: z.groesse,
            mime: z.mime,
            sha256: z.sha256,
          );
        } else if (v == null) {
          await repo.fassungAnlegen(dateiId: z.dateiId!, versionId: z.versionId!, blobId: blobId, thumbBlobId: z.thumbBlobId, groesse: z.groesse, mime: z.mime, sha256: z.sha256);
        }
      case TransferArt.fassung:
        final v = await (db.select(db.dateiVersionen)..where((t) => t.id.equals(z.versionId!))).getSingleOrNull();
        if (v == null) await repo.fassungAnlegen(dateiId: z.dateiId!, versionId: z.versionId!, blobId: blobId, thumbBlobId: z.thumbBlobId, groesse: z.groesse, mime: z.mime, sha256: z.sha256);
      case TransferArt.anhang:
        final abschluss = _abschluesse[z.id];
        if (abschluss == null) {
          await _setze(z.id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('anhang_neu')));
          return;
        }
        await abschluss(blobId, z.sha256);
      case TransferArt.runter:
        return;
    }
    await _setze(z.id, const TransfersCompanion(zustand: Value('fertig'), fehlerCode: Value(null), versuche: Value(0), naechsterVersuch: Value(null)));
    _netzVersuche.remove(z.id);
    await _aufraeumenQuelle(z.id);
    _abschluesse.remove(z.id);
  }

  // ------------------------------------------------------------------ Download

  Future<void> _laufRunter(TransferZeile z, AbbruchToken abbruch) async {
    final blobId = z.blobId!;
    final teil = await cache.teilPfad(blobId);
    if (teil == null) {
      // Web: kein Ordner, die Oberfläche lädt über den Browser (datei_speichern.dart)
      await _setze(z.id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('lokal')));
      return;
    }
    final ort = cache.ort;
    var offset = await ort.laenge(teil);
    if (offset > z.groesse) {
      await ort.loeschen(teil);
      offset = 0;
    }
    var neuAnfaenge = 0;
    while (offset < z.groesse) {
      if (abbruch.abgebrochen) throw const TusAbgebrochen();
      final ende = math.min(offset + kTusAbschnittBytes, z.groesse) - 1;
      final a = await _rohLesen(blobId, offset, ende);
      if (a.status == 206) {
        final cr = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(a.kopfzeile('content-range') ?? '');
        if (cr == null || int.parse(cr.group(1)!) != offset || a.bytes.isEmpty) throw const TusFehler('protocol', 'Die Antwort des Servers war unerwartet.', TusFolge.spaeter);
        await ort.anhaengen(teil, a.bytes);
        offset += a.bytes.length;
      } else if (a.status == 200 && offset == 0 && a.bytes.length == z.groesse) {
        await ort.anhaengen(teil, a.bytes); // der Server hat Range ignoriert: ganze Datei
        offset = a.bytes.length;
      } else if (a.status == 416) {
        // der Stand passt nicht zum Server (Datei geändert?): einmal von vorn
        await ort.loeschen(teil);
        offset = 0;
        if (++neuAnfaenge > 2) throw const TusFehler('range', 'Die Datei lässt sich nicht laden.', TusFolge.aufgeben);
      } else if (a.status == 404) {
        throw const TusFehler('nicht_gefunden', 'Die Datei gibt es nicht mehr.', TusFolge.aufgeben, status: 404);
      } else {
        throw TusFehler.vonAntwort(a);
      }
      await _setze(z.id, TransfersCompanion(uebertragen: Value(offset)));
    }
    // Prüfsumme der Datei (Klartext im Modus `server`), wenn bekannt: eine beschädigte Datei wird nie angeboten
    final erwartet = z.sha256;
    if (erwartet != null && erwartet.isNotEmpty && (await ort.sha256(teil)).toLowerCase() != erwartet.toLowerCase()) {
      await ort.loeschen(teil);
      await _setze(z.id, const TransfersCompanion(zustand: Value('fehler'), fehlerCode: Value('pruefsumme'), uebertragen: Value(0)));
      return;
    }
    final pfad = await cache.aufnehmen(blobId: blobId, teilPfad: teil, groesse: z.groesse, name: z.name, mime: z.mime);
    await _setze(z.id, TransfersCompanion(zustand: const Value('fertig'), zielPfad: Value(pfad), fehlerCode: const Value(null), versuche: const Value(0), naechsterVersuch: const Value(null)));
  }

  Future<RohAntwort> _rohLesen(String blobId, int von, int bis) async {
    try {
      return await api.client.roh('GET', '/files/blobs/$blobId', kopf: {'range': 'bytes=$von-$bis', 'accept': '*/*'}, zeitlimit: const Duration(minutes: 2));
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.nichtAngemeldet) rethrow;
      throw TusFehler.netz(e);
    }
  }

  // ------------------------------------------------------------------ Aufräumen

  Future<void> _aufraeumenQuelle(String id) async {
    final q = _quellen.remove(id);
    if (q != null) {
      try {
        await q.schliessen();
      } on Object {
        // schon zu
      }
    }
  }

  /// Verwirft den angefangenen Upload beim Server (best effort, ein Fehler dabei ist egal: der Server räumt nach 24 Stunden selbst auf).
  Future<void> _verwerfe(TransferZeile z) async {
    final id = z.blobId;
    if (id == null || !z.artTyp.hoch || z.uebertragen >= z.groesse && z.zustandTyp == TransferZustand.fertig) return;
    try {
      await tus.abbrechen(id);
    } on Object {
      // best effort
    }
    if (z.thumbBlobId != null) {
      try {
        await tus.abbrechen(z.thumbBlobId!);
      } on Object {
        // best effort
      }
    }
  }

  Future<void> _verwerfeServerseitig(String id) async {
    final z = await transfer(id);
    if (z != null) await _verwerfe(z);
  }
}

// ---------------------------------------------------------------------------------------------------- Provider

final tusClientProvider = Provider<TusClient>((ref) => TusClient(ref.watch(apiProvider).client));

final dateiOrtProvider = Provider<DateiOrt>((ref) => DateiOrt.standard());

final dateiCacheDienstProvider = Provider<DateiCacheDienst>((ref) => DateiCacheDienst(db: ref.watch(appDatabaseProvider), ort: ref.watch(dateiOrtProvider)));

/// Hintergrunddienst (Android-Vordergrunddienst): standardmäßig keiner; die Android-Seite überschreibt ihn.
final transferHintergrundProvider = Provider<TransferHintergrundPort>((ref) => const KeinTransferHintergrund());

final transferDienstProvider = Provider<TransferDienst>((ref) {
  final dienst = TransferDienst(
    db: ref.watch(appDatabaseProvider),
    repo: ref.watch(dateiRepositoryProvider),
    tus: ref.watch(tusClientProvider),
    api: ref.watch(apiProvider),
    cache: ref.watch(dateiCacheDienstProvider),
    hintergrund: ref.watch(transferHintergrundProvider),
  );
  ref.onDispose(() => unawaited(dienst.beenden()));
  return dienst;
});

/// Alle Übertragungen für die Liste der Oberfläche.
final transferListeProvider = StreamProvider<List<TransferZeile>>((ref) => ref.watch(transferDienstProvider).transfers());
