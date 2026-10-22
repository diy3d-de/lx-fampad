// Web: Download des Notfallblatts über einen eigenen Anker. Die Adresse des Blobs wird erst nach 30 Sekunden widerrufen (sofortiges Widerrufen kann den Download in manchen Browsern
// abbrechen); die Bytes bleiben so lange im Arbeitsspeicher des Browsers und werden danach freigegeben. Der Browser meldet weder Ziel noch Abbruch: true heißt nur "Download angestoßen".
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<bool> notfallblattHerunterladen(String name, Uint8List bytes) async {
  try {
    // eigene Kopie: der Aufrufer überschreibt seine Bytes gleich nach dem Aufruf
    final kopie = Uint8List.fromList(bytes);
    final blob = web.Blob([kopie.toJS].toJS, web.BlobPropertyBag(type: 'application/pdf'));
    final url = web.URL.createObjectURL(blob);
    final anker = web.HTMLAnchorElement()
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body?.append(anker);
    anker.click();
    anker.remove();
    Timer(const Duration(seconds: 30), () {
      web.URL.revokeObjectURL(url);
      kopie.fillRange(0, kopie.length, 0);
    });
    return true;
  } on Object {
    return false;
  }
}
