// Web: Quelle aus einer vom Browser gewählten Datei (`web.File`): Blob.slice liest einen Abschnitt, ohne die ganze Datei zu laden. Pfade gibt es im Web nicht.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'upload_quelle.dart';

class WebDateiQuelle implements UploadQuelle {
  final web.Blob _blob;
  @override
  final int laenge;
  WebDateiQuelle(this._blob) : laenge = _blob.size;

  @override
  Future<Uint8List> lies(int von, int bis) async {
    final b = bis > laenge ? laenge : bis;
    if (von < 0 || von > b) throw RangeError('Bereich außerhalb der Datei');
    final puffer = await _blob.slice(von, b).arrayBuffer().toDart;
    return puffer.toDart.asUint8List();
  }

  @override
  Future<void> schliessen() async {}
}

Future<UploadQuelle?> quelleAusPfad(String pfad) async => null;

UploadQuelle? quelleAusWebDatei(Object datei) {
  // Blob und File sind JS-Objekte: nur ein echtes Blob (File ist eins) kommt infrage
  try {
    final js = datei as JSAny;
    return js.isA<web.Blob>() ? WebDateiQuelle(js as web.Blob) : null;
  } on Object {
    return null;
  }
}
