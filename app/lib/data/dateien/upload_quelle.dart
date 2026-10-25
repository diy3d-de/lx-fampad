// Quelle der Bytes eines Uploads (Abschnitt 6n): liest abschnittsweise, damit auch große Dateien nie ganz im Speicher liegen müssen (Android: Datei per Pfad, Web: Blob.slice einer vom Browser
// gewählten Datei). Nach dem Neuladen des Browsers ist die Datei weg: die Person wählt sie erneut (der Transfer steht dann auf `dateiNoetig`). Nie Namen oder Inhalte loggen.
import 'dart:typed_data';

import 'upload_quelle_plattform.dart' as plattform;

abstract class UploadQuelle {
  /// Größe in Byte.
  int get laenge;

  /// Liest die Bytes [von, bis) (Ende exklusiv; [bis] wird auf [laenge] begrenzt).
  Future<Uint8List> lies(int von, int bis);

  /// Gibt Datei-Handles frei; danach ist die Quelle unbrauchbar.
  Future<void> schliessen();

  /// Quelle aus Bytes im Arbeitsspeicher (Tests, kleine Dateien, verschlüsselte Anhänge).
  static UploadQuelle ausBytes(Uint8List bytes) => SpeicherQuelle(bytes);

  /// Android: Datei per Pfad (null, wenn es sie nicht (mehr) gibt oder auf dieser Plattform keine Pfade gelten).
  static Future<UploadQuelle?> ausPfad(String pfad) => plattform.quelleAusPfad(pfad);

  /// Web: eine vom Browser gewählte Datei (`web.File`); null auf anderen Plattformen oder bei einem falschen Objekt.
  static UploadQuelle? ausWebDatei(Object datei) => plattform.quelleAusWebDatei(datei);
}

class SpeicherQuelle implements UploadQuelle {
  final Uint8List _bytes;
  SpeicherQuelle(this._bytes);

  @override
  int get laenge => _bytes.length;

  @override
  Future<Uint8List> lies(int von, int bis) async {
    final b = bis > _bytes.length ? _bytes.length : bis;
    if (von < 0 || von > b) throw RangeError('Bereich außerhalb der Datei');
    return Uint8List.sublistView(_bytes, von, b);
  }

  @override
  Future<void> schliessen() async {}
}
