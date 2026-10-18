// Lädt die APK in den App-Cache und prüft die SHA-256-Prüfsumme. Die Dart-IO-Variante liegt in
// apk_downloader_io.dart; im Web (kein dart:io) gibt es nur einen Stub, der nie benutzt wird.
export 'apk_downloader_stub.dart' if (dart.library.io) 'apk_downloader_io.dart';

typedef FortschrittCallback = void Function(double anteil);
