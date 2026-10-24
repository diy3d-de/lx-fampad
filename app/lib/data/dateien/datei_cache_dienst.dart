// Offline-Kopien heruntergeladener Dateien (nur Android, Abschnitt 6n): jede fertig geladene Datei liegt im privaten Ordner der App (`DateiOrt`, Dateiname = Blob-ID) und hat eine Zeile in `datei_cache`
// (nur lokal, nie synchronisiert). Die Gesamtgröße ist begrenzt (Standard 2 GB, Einstellung in `sync_meta`, `datei_cache_max`): wird sie überschritten, fliegt die am LÄNGSTEN NICHT BENUTZTE Kopie
// zuerst heraus (LRU); mit "Offline verfügbar" angeheftete Kopien bleiben und werden nie automatisch entfernt. Abmelden und Gerät abgeben räumen den Ordner und die Tabelle ([alleLoeschen], im Wiper).
// Im Web gibt es keinen Ordner (`DateiOrt.verfuegbar` = false): alles hier tut dann nichts. Nie Klartext von Tresor-Anhängen ablegen: das tut dieser Dienst nie (nur Dateien der Ablage im Modus `server`).
import 'package:drift/drift.dart';

import '../app_database.dart';
import 'datei_modelle.dart';
import 'datei_ort.dart';

const String kCacheMaxSchluessel = 'datei_cache_max';

class DateiCacheDienst {
  final AppDatabase db;
  final DateiOrt ort;
  final DateTime Function() _jetzt;

  DateiCacheDienst({required this.db, required this.ort, DateTime Function()? jetzt}) : _jetzt = jetzt ?? DateTime.now;

  bool get verfuegbar => ort.verfuegbar;

  /// Obergrenze der Offline-Kopien in Byte (Standard 2 GB; eine ungültige oder nicht positive Einstellung gilt als Standard).
  Future<int> grenze() async {
    final v = int.tryParse(await db.metaLesen(kCacheMaxSchluessel) ?? '');
    return v != null && v > 0 ? v : kStandardCacheBytes;
  }

  Future<void> grenzeSetzen(int bytes) async {
    if (bytes <= 0) throw ArgumentError('Die Grenze muss größer als 0 sein');
    await db.metaSchreiben(kCacheMaxSchluessel, '$bytes');
    await aufraeumen();
  }

  /// Gesamtgröße aller Offline-Kopien.
  Future<int> belegt() async {
    final l = await db.select(db.dateiCache).get();
    return l.fold<int>(0, (s, z) => s + z.groesse);
  }

  Stream<List<DateiCacheZeile>> kopien() => (db.select(db.dateiCache)..orderBy([(z) => OrderingTerm.desc(z.zuletztGenutzt)])).watch();

  /// Pfad der Kopie zu [blobId], wenn es sie gibt und die Datei noch da ist; zählt als Benutzung (LRU). Fehlt die Datei auf der Platte, wird die Zeile entfernt.
  Future<String?> pfadFuer(String blobId) async {
    if (!ort.verfuegbar) return null;
    final z = await (db.select(db.dateiCache)..where((t) => t.blobId.equals(blobId))).getSingleOrNull();
    if (z == null) return null;
    final p = await ort.pfad(blobId);
    if (p == null || !await ort.existiert(p) || await ort.laenge(p) != z.groesse) {
      await (db.delete(db.dateiCache)..where((t) => t.blobId.equals(blobId))).go();
      if (p != null) await ort.loeschen(p);
      return null;
    }
    await (db.update(db.dateiCache)..where((t) => t.blobId.equals(blobId))).write(DateiCacheCompanion(zuletztGenutzt: Value(_jetzt())));
    return p;
  }

  /// Pfad, unter dem ein Download in den Cache geschrieben wird (`<Blob-ID>.teil`, bis er fertig ist).
  Future<String?> teilPfad(String blobId) => ort.pfad('$blobId.teil');

  /// Nimmt eine fertig geladene Datei (Teil-Datei [teilPfad]) in den Cache auf: umbenennen, Zeile eintragen, danach LRU aufräumen. Liefert den endgültigen Pfad (null ohne Ordner).
  Future<String?> aufnehmen({required String blobId, required String teilPfad, required int groesse, required String name, String? mime, bool anheften = false}) async {
    if (!ort.verfuegbar) return null;
    final ziel = await ort.pfad(blobId);
    if (ziel == null) return null;
    await ort.umbenennen(teilPfad, ziel);
    final vorher = await (db.select(db.dateiCache)..where((t) => t.blobId.equals(blobId))).getSingleOrNull();
    await db.into(db.dateiCache).insertOnConflictUpdate(
      DateiCacheCompanion.insert(blobId: blobId, groesse: groesse, name: name, mime: Value(mime), angeheftet: Value(anheften || (vorher?.angeheftet ?? false)), zuletztGenutzt: _jetzt()),
    );
    await aufraeumen(behalte: blobId);
    return ziel;
  }

  /// Entfernt die am längsten nicht benutzten, nicht angehefteten Kopien, bis die Grenze eingehalten ist ([behalte] bleibt immer: die gerade fertige Datei). Liefert die Zahl der entfernten Kopien.
  /// Reichen die angehefteten Kopien allein über die Grenze, bleiben sie (die Oberfläche kann das anzeigen: [belegt] > [grenze]).
  Future<int> aufraeumen({String? behalte}) async {
    final max = await grenze();
    var summe = await belegt();
    if (summe <= max) return 0;
    final kandidaten = await (db.select(db.dateiCache)
          ..where((t) => t.angeheftet.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.zuletztGenutzt), (t) => OrderingTerm.asc(t.blobId)]))
        .get();
    var n = 0;
    for (final z in kandidaten) {
      if (summe <= max) break;
      if (z.blobId == behalte) continue;
      await entfernen(z.blobId);
      summe -= z.groesse;
      n++;
    }
    return n;
  }

  /// Heftet eine Kopie an ("Offline verfügbar") oder löst sie wieder (dann kann sie herausfliegen).
  Future<void> anheften(String blobId, bool an) async {
    await (db.update(db.dateiCache)..where((t) => t.blobId.equals(blobId))).write(DateiCacheCompanion(angeheftet: Value(an)));
    if (!an) await aufraeumen();
  }

  Future<void> entfernen(String blobId) async {
    final p = await ort.pfad(blobId);
    if (p != null) await ort.loeschen(p);
    await (db.delete(db.dateiCache)..where((t) => t.blobId.equals(blobId))).go();
  }

  /// Löscht alle Kopien und Teil-Dateien samt Ordner (Abmelden und Gerät abgeben). Fehler dabei dürfen nie das Abmelden verhindern: der Aufrufer fängt sie ab.
  Future<void> alleLoeschen() async {
    await ort.alleLoeschen();
    await db.delete(db.dateiCache).go();
  }
}
