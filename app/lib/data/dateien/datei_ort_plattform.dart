// Plattformweiche des Datei-Ortes (bedingter Import: dart:io nur auf Android/Desktop, nie im Web).
export 'datei_ort_stub.dart' if (dart.library.io) 'datei_ort_io.dart';
