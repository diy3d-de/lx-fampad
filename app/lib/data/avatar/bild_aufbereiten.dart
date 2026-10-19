// Foto für das Benutzerbild vorbereiten: quadratisch zuschneiden, auf höchstens 512 x 512 Pixel verkleinern und als PNG neu kodieren.
// Durch das Neu-Kodieren fallen EXIF-Daten (Standort, Kamera, Zeitpunkt) weg; hochgeladen wird nur das kleine Ergebnis.
// Nur dart:ui (läuft auf Android und im Web), kein zusätzliches Paket. dart:ui kann nur PNG schreiben: Ist das Ergebnis größer als das
// Byte-Ziel (Fotos mit viel Detail), wird die Kantenlänge schrittweise verkleinert.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Größte Quelldatei, die die App überhaupt lädt.
const kAvatarQuelleMaxBytes = 10 * 1024 * 1024;

/// Zielkante des Benutzerbilds und Byte-Obergrenze des Ergebnisses (der Server lehnt über 512 KB ab).
const kAvatarKante = 512;
const kAvatarZielBytes = 460 * 1024;
const _kleinsteKante = 192;
const _dekodierBreite = 1024;

class BildFehler implements Exception {
  final String meldung;
  const BildFehler(this.meldung);
  @override
  String toString() => meldung;
}

class AufbereitetesBild {
  final Uint8List bytes;
  final int kante;
  const AufbereitetesBild(this.bytes, this.kante);
  String get mime => 'image/png';
}

/// Bereitet [quelle] auf; wirft [BildFehler] mit verständlicher Meldung (zu groß, kein lesbares Bild, zu groß nach dem Verkleinern).
Future<AufbereitetesBild> bildAufbereiten(Uint8List quelle, {int kante = kAvatarKante, int zielBytes = kAvatarZielBytes}) async {
  if (quelle.length > kAvatarQuelleMaxBytes) throw const BildFehler('Das Bild ist größer als 10 MB. Wähle ein kleineres Foto.');
  if (quelle.isEmpty) throw const BildFehler('Die Datei ist leer.');
  ui.Codec? codec;
  ui.Image? bild;
  try {
    // Auf höchstens 1024 Pixel Breite herunterrechnen (Seitenverhältnis bleibt, kleinere Bilder werden nicht vergrößert): spart bei großen
    // Fotos Speicher. ImageDescriptor.width gibt es im Web nicht, deshalb die Maße erst vom dekodierten Bild lesen.
    codec = await ui.instantiateImageCodec(quelle, targetWidth: _dekodierBreite, allowUpscaling: false);
    bild = (await codec.getNextFrame()).image;
    final kurz = bild.width < bild.height ? bild.width : bild.height;
    if (kurz < 1) throw const BildFehler('Das Bild konnte nicht gelesen werden.');
    var k = kurz < kante ? kurz : kante; // nie größer als die kürzere Seite
    while (true) {
      final png = await _quadratAlsPng(bild, k);
      if (png.length <= zielBytes) return AufbereitetesBild(png, k);
      if (k <= _kleinsteKante) throw const BildFehler('Das Bild lässt sich nicht klein genug machen. Wähle ein anderes Foto.');
      k = (k * 0.8).floor();
      if (k < _kleinsteKante) k = _kleinsteKante;
    }
  } on BildFehler {
    rethrow;
  } catch (_) {
    throw const BildFehler('Das Bild konnte nicht gelesen werden. Wähle ein Foto als JPEG, PNG oder WebP.');
  } finally {
    bild?.dispose();
    codec?.dispose();
  }
}

/// Schneidet die Bildmitte quadratisch aus und zeichnet sie auf eine [kante] x [kante] große Fläche.
Future<Uint8List> _quadratAlsPng(ui.Image bild, int kante) async {
  final seite = bild.width < bild.height ? bild.width : bild.height;
  final quelle = ui.Rect.fromLTWH((bild.width - seite) / 2, (bild.height - seite) / 2, seite.toDouble(), seite.toDouble());
  final rekorder = ui.PictureRecorder();
  final canvas = ui.Canvas(rekorder);
  canvas.drawImageRect(bild, quelle, ui.Rect.fromLTWH(0, 0, kante.toDouble(), kante.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
  final ergebnis = await rekorder.endRecording().toImage(kante, kante);
  try {
    final daten = await ergebnis.toByteData(format: ui.ImageByteFormat.png);
    if (daten == null) throw const BildFehler('Das Bild konnte nicht verarbeitet werden.');
    return daten.buffer.asUint8List(daten.offsetInBytes, daten.lengthInBytes);
  } finally {
    ergebnis.dispose();
  }
}
