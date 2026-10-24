// Plattformweiche für den Browser-Download einer Adresse (bedingter Import: package:web nur im Browser).
export 'datei_speichern_browser_stub.dart' if (dart.library.js_interop) 'datei_speichern_browser_web.dart';
