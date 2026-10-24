// Android/Desktop: Quelle aus einer Datei, abschnittsweise per RandomAccessFile gelesen (nie die ganze Datei im Speicher).
import 'dart:io';
import 'dart:typed_data';

import 'upload_quelle.dart';

class DateiQuelle implements UploadQuelle {
  final RandomAccessFile _f;
  @override
  final int laenge;
  DateiQuelle._(this._f, this.laenge);

  static Future<DateiQuelle?> oeffnen(String pfad) async {
    try {
      final datei = File(pfad);
      if (!await datei.exists()) return null;
      final f = await datei.open();
      return DateiQuelle._(f, await f.length());
    } on Object {
      return null;
    }
  }

  @override
  Future<Uint8List> lies(int von, int bis) async {
    final b = bis > laenge ? laenge : bis;
    if (von < 0 || von > b) throw RangeError('Bereich außerhalb der Datei');
    await _f.setPosition(von);
    return _f.read(b - von);
  }

  @override
  Future<void> schliessen() async {
    try {
      await _f.close();
    } on Object {
      // schon zu
    }
  }
}

Future<UploadQuelle?> quelleAusPfad(String pfad) => DateiQuelle.oeffnen(pfad);

UploadQuelle? quelleAusWebDatei(Object datei) => null;
