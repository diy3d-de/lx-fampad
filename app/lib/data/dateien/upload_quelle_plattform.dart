// Plattformweiche der Upload-Quellen (bedingter Import: dart:io nur auf Android/Desktop, package:web nur im Browser).
export 'upload_quelle_stub.dart' if (dart.library.js_interop) 'upload_quelle_web.dart' if (dart.library.io) 'upload_quelle_io.dart';
