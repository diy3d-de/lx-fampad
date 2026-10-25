// Web: die gewählte Datei liegt als `blob:`-Adresse vor; ein Abruf dieser Adresse liefert das Blob des Browsers (ohne die Datei in den Arbeitsspeicher zu laden), aus dem die Quelle
// abschnittsweise per `Blob.slice` liest.
import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:web/web.dart' as web;

import 'upload_quelle.dart';

Future<UploadQuelle?> quelleAusAuswahl(PlatformFile f) async {
  try {
    final antwort = await web.window.fetch(f.uri.toString().toJS).toDart;
    final blob = await antwort.blob().toDart;
    return UploadQuelle.ausWebDatei(blob);
  } on Object {
    return null;
  }
}
