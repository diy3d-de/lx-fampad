// Kleiner Speicher für nicht geheime Vermerke, die im Web einen Neustart des Tabs überleben sollen (localStorage; auf Android stehen sie im Keystore-Speicher
// des TokenStore). Nie Token, Passwörter oder Schlüssel hier ablegen. Jeder Fehler (privates Fenster, gesperrte Website-Daten) ist kein Fehler der App:
// Lesen ergibt null, Schreiben wird ausgelassen.
export 'kleiner_speicher_stub.dart' if (dart.library.js_interop) 'kleiner_speicher_web.dart';
