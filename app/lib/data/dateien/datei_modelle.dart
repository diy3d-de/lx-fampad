// Dateiablage (Abschnitt 6n), Datenschicht: Konstanten, Fehler und die Zahlen des Servers (`GET /files/usage`). Noch ohne Oberfläche.
//
// Grenzen (gültig, Memory „Tresor und Dateien“): 10 GB je Familie, 100 MB je Datei, Abschnitte (PATCH) höchstens 4 MiB, Vorschaubilder 256 KiB. Der Server nennt sie über `GET /files/usage`;
// die Werte hier sind nur der Standard, solange die Zahlen des Servers (noch) nicht da sind.
import '../api/models.dart' show Json;

/// Freigabestufen (wie der Server): `parents` = nur Eltern und Admins, `family` = alle.
const String kStufeEltern = 'parents';
const String kStufeFamilie = 'family';

/// Ordner liegen höchstens so tief (ein Ordner oben hat die Tiefe 1), wie der Server es erzwingt.
const int kMaxOrdnerTiefe = 6;

/// Größe eines Abschnitts beim Upload (tus PATCH): 4 MiB, mehr nimmt der Server nicht an.
const int kTusAbschnittBytes = 4194304;

/// Standardgrenzen, solange der Server (noch) keine Zahlen geliefert hat: 100 MB je Datei, 10 GB je Familie, im Modus `e2ee` 1 MiB Overhead dazu.
const int kStandardMaxDateiBytes = 104857600;
const int kStandardKontingentBytes = 10737418240;
const int kStandardMaxE2eeBytes = 105906176;

/// Vorschaubilder: höchstens 256 KiB (der Server lehnt mehr ab); die App rechnet auf etwa 512 Pixel herunter und bleibt darunter.
const int kMaxThumbBytes = 262144;
const int kThumbKante = 512;
const int kThumbZielBytes = 250 * 1024;

/// Quellbilder für Vorschaubilder: größere werden hochgeladen, aber ohne Vorschau (das Dekodieren wäre zu teuer, siehe `bildAufbereiten`).
const int kThumbQuelleMaxBytes = 10 * 1024 * 1024;

/// Höchstens so viele Übertragungen laufen gleichzeitig (der Server erlaubt 3 laufende Uploads je Person); im Vordergrund-Fortsetzen nur eine.
const int kMaxParalleleUploads = 3;

/// Standardgröße der Offline-Kopien (Android): 2 GB, danach fliegt die am längsten nicht benutzte Kopie zuerst heraus.
const int kStandardCacheBytes = 2147483648;

/// Fehler der Dateiablage mit einer verständlichen Meldung (nie ein Dateiinhalt oder -name im Text).
class DateiFehler implements Exception {
  final String code;
  final String meldung;
  const DateiFehler(this.code, this.meldung);

  @override
  String toString() => meldung;

  static const nichtErlaubt = DateiFehler('nicht_erlaubt', 'Dazu fehlt dir die Berechtigung.');
  static const nichtGefunden = DateiFehler('nicht_gefunden', 'Das gibt es nicht mehr.');
  static const nameUngueltig = DateiFehler('name_ungueltig', 'Dieser Name ist nicht möglich. Er darf nicht leer sein, kein / oder \\ enthalten, nicht mit einem Punkt enden und höchstens 200 Zeichen lang sein.');
  static const zuTief = DateiFehler('zu_tief', 'So tief lassen sich Ordner nicht schachteln (höchstens 6 Ebenen).');
  static const zyklus = DateiFehler('zyklus', 'Ein Ordner lässt sich nicht in sich selbst oder in einen seiner Unterordner verschieben.');
  static const nichtLeer = DateiFehler('nicht_leer', 'Der Ordner ist nicht leer.');
  static const stufeFamilieNurInFamilie = DateiFehler('stufe_ordner', 'Für alle sichtbare Einträge liegen nur in Ordnern, die für alle sichtbar sind (oder ganz oben).');
  static const zuVieleFassungen = DateiFehler('zu_viele_fassungen', 'Die Datei hat schon sehr viele Fassungen.');
  static const zuGross = DateiFehler('zu_gross', 'Die Datei ist größer als erlaubt.');
  static const speicherVoll = DateiFehler('speicher_voll', 'Der Speicher der Familie ist voll.');
  static const leer = DateiFehler('leer', 'Die Datei ist leer.');
  static const zuVieleAnhaenge = DateiFehler('zu_viele_anhaenge', 'Der Tresor hat schon sehr viele Anhänge.');
  static const nichtVerfuegbar = DateiFehler('nicht_verfuegbar', 'Die Dateiablage ist auf dem Server nicht eingeschaltet.');
}

/// Zahlen des Servers aus `GET /files/usage` (nur Zahlen). Fehlende oder ungültige Werte bleiben beim Standard.
class DateiNutzung {
  final int belegtBytes;
  final int reserviertBytes;
  final int kontingentBytes;
  final int maxDateiBytes;
  final int maxE2eeBytes;
  final int abschnittBytes;
  const DateiNutzung({
    this.belegtBytes = 0,
    this.reserviertBytes = 0,
    this.kontingentBytes = kStandardKontingentBytes,
    this.maxDateiBytes = kStandardMaxDateiBytes,
    this.maxE2eeBytes = kStandardMaxE2eeBytes,
    this.abschnittBytes = kTusAbschnittBytes,
  });

  static const standard = DateiNutzung();

  factory DateiNutzung.fromJson(Json j) {
    int zahl(Object? v, int standard, {int min = 0}) => v is int && v >= min ? v : standard;
    return DateiNutzung(
      belegtBytes: zahl(j['usedBytes'], 0),
      reserviertBytes: zahl(j['reservedBytes'], 0),
      kontingentBytes: zahl(j['quotaBytes'], kStandardKontingentBytes, min: 1),
      maxDateiBytes: zahl(j['maxFileBytes'], kStandardMaxDateiBytes, min: 1),
      maxE2eeBytes: zahl(j['maxE2eeBytes'], kStandardMaxE2eeBytes, min: 1),
      abschnittBytes: zahl(j['chunkBytes'], kTusAbschnittBytes, min: 1),
    );
  }

  /// Noch frei (belegt und die angekündigte Größe laufender Uploads abgezogen), nie negativ.
  int get freiBytes {
    final f = kontingentBytes - belegtBytes - reserviertBytes;
    return f < 0 ? 0 : f;
  }
}
