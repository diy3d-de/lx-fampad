// Ablage des Personenschlüssels (und der gemerkten öffentlichen Schlüssel) auf dem Gerät.
//   Android: flutter_secure_storage (Android Keystore).
//   Web:     AES-GCM-Wrapper-Schlüssel (WebCrypto, nicht exportierbar) in IndexedDB; die Schlüsselbytes liegen nur verschlüsselt dort.
//            Ehrlich: Das schützt vor dem Auslesen des Speichers (Profilordner, Sicherung), NICHT vor Schadcode in der Seite (XSS) - der
//            kann den Wrapper-Schlüssel benutzen. Dagegen hilft nur die strikte CSP (deploy/Caddyfile: script-src 'self').
import 'dart:typed_data';

export 'schluessel_speicher_stub.dart' if (dart.library.js_interop) 'schluessel_speicher_web.dart' if (dart.library.io) 'schluessel_speicher_io.dart';

/// Schlüssel-Wert-Ablage für kleine Geheimnisse. Lesen liefert null, wenn der Eintrag fehlt oder nicht lesbar ist.
abstract interface class SchluesselSpeicher {
  Future<Uint8List?> lesen(String name);
  Future<void> schreiben(String name, Uint8List bytes);
  Future<void> loeschen(String name);

  /// Löscht alle Einträge dieser App, deren Name mit [praefix] beginnt (beim Abmelden).
  Future<void> loescheMitPraefix(String praefix);
}

/// Nur im Arbeitsspeicher (Tests, Plattformen ohne sichere Ablage).
class MemorySchluesselSpeicher implements SchluesselSpeicher {
  final Map<String, Uint8List> _daten = {};

  @override
  Future<Uint8List?> lesen(String name) async {
    final v = _daten[name];
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<void> schreiben(String name, Uint8List bytes) async => _daten[name] = Uint8List.fromList(bytes);

  @override
  Future<void> loeschen(String name) async => _daten.remove(name);

  @override
  Future<void> loescheMitPraefix(String praefix) async => _daten.removeWhere((k, _) => k.startsWith(praefix));
}
