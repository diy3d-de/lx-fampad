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

  /// Löscht alle Einträge dieser App, deren Name mit [praefix] beginnt. Nur für "Gerät abgeben" gedacht, nie beim Abmelden.
  Future<void> loescheMitPraefix(String praefix);

  /// Namen aller Einträge, die mit [praefix] beginnen (ohne sie zu lesen oder zu entschlüsseln).
  Future<List<String>> namenMitPraefix(String praefix);

  /// Verschiebt den Eintrag [von] nach [nach], ohne ihn zu entschlüsseln (für die Quarantäne: auch ein nicht lesbarer Eintrag bleibt so erhalten).
  /// true: verschoben; false: es gibt ihn nicht oder er ließ sich nicht verschieben (dann bleibt er unverändert unter seinem Namen).
  Future<bool> verschiebe(String von, String nach);

  /// Darf der Browser diese Daten löschen? Nur im Web von Bedeutung ([SpeicherDauer.nichtZutreffend] sonst); fordert die dauerhafte Ablage an
  /// (`navigator.storage.persist()`) und merkt sich ein "gewährt".
  Future<SpeicherDauer> dauerhaftigkeit();
}

/// Ergebnis der Anfrage nach dauerhaftem Speicher (Web).
enum SpeicherDauer {
  /// Keine Browser-Ablage (Android: Keystore).
  nichtZutreffend,

  /// Der Browser hat die dauerhafte Ablage zugesagt.
  gewaehrt,

  /// Der Browser darf die Daten bei Speicherknappheit löschen.
  verweigert,

  /// Die Anfrage ließ sich nicht klären.
  unbekannt,
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

  @override
  Future<List<String>> namenMitPraefix(String praefix) async => [
    for (final k in _daten.keys)
      if (k.startsWith(praefix)) k,
  ];

  @override
  Future<bool> verschiebe(String von, String nach) async {
    final v = _daten[von];
    if (v == null) return false;
    _daten[nach] = v;
    _daten.remove(von);
    return true;
  }

  @override
  Future<SpeicherDauer> dauerhaftigkeit() async => SpeicherDauer.nichtZutreffend;
}
