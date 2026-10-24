// Plattformweiche der Dateiauswahl (bedingter Import: package:web nur im Browser).
export 'datei_waehler_stub.dart' if (dart.library.js_interop) 'datei_waehler_web.dart';
