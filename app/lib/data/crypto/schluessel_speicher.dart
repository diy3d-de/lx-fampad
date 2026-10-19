// Ablage des Personenschlüssels (und der gemerkten öffentlichen Schlüssel) auf dem Gerät.
//   Android: flutter_secure_storage (Android Keystore).
//   Web:     AES-GCM-Wrapper-Schlüssel (WebCrypto, nicht exportierbar) in IndexedDB; die Schlüsselbytes liegen nur verschlüsselt dort.
//            Ehrlich: Das schützt vor dem Auslesen des Speichers (Profilordner, Sicherung), NICHT vor Schadcode in der Seite (XSS) - der
//            kann den Wrapper-Schlüssel benutzen. Dagegen hilft nur die strikte CSP (deploy/Caddyfile: script-src 'self').
import 'dart:typed_data';

export 'schluessel_speicher_stub.dart' if (dart.library.js_interop) 'schluessel_speicher_web.dart' if (dart.library.io) 'schluessel_speicher_io.dart';

/// Fehler des Schlüsselspeichers beim Lesen. [dauerhaft]: der Eintrag ist eindeutig und für immer unbrauchbar (Entschlüsselung scheitert,
/// z. B. Keystore-Schlüssel verloren, oder kaputte Daten); sonst vorübergehend (Keystore gesperrt, Datenbank nicht erreichbar): der Eintrag
/// darf dann NICHT gelöscht werden, ein späterer Versuch kann klappen.
class SchluesselSpeicherFehler implements Exception {
  final bool dauerhaft;
  final String meldung;
  const SchluesselSpeicherFehler(this.meldung, {required this.dauerhaft});

  @override
  String toString() => 'SchluesselSpeicherFehler(dauerhaft: $dauerhaft): $meldung';
}

/// Schlüssel-Wert-Ablage für kleine Geheimnisse. [lesen] liefert **null nur, wenn der Eintrag nicht existiert**; jeder andere Fehlschlag wirft
/// einen [SchluesselSpeicherFehler] (dauerhaft oder vorübergehend). Die Ablage löscht beim Lesen nie von sich aus.
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
