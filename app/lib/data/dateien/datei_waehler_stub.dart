// Android/Desktop: Quelle aus dem Pfad der gewählten Datei (null, wenn es keinen Pfad gibt oder die Datei nicht lesbar ist).
import 'package:file_picker/file_picker.dart';

import 'upload_quelle.dart';

Future<UploadQuelle?> quelleAusAuswahl(PlatformFile f) async {
  final p = f.path;
  return p == null ? null : UploadQuelle.ausPfad(p);
}
