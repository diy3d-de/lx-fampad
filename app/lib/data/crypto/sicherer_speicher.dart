// Gemeinsame Einstellung für ALLE Zugriffe auf flutter_secure_storage (Anmeldung, Schlüsselspeicher, Erinnerungen).
// flutter_secure_storage 11.2.0 löscht auf Android bei einem Lesefehler standardmäßig selbst (AndroidOptions.resetOnError: true: bei `read` den Eintrag,
// bei Fehlern der Algorithmus-Migration oder von `readAll` ALLES samt Keystore-Schlüsseln) und liefert danach null = "nicht vorhanden". Für den Personenschlüssel wäre
// das Datenverlust ohne Rückfrage; mit `resetOnError: false` kommt der Fehler stattdessen als Ausnahme an (Schlüsselspeicher: SchluesselSpeicherFehler,
// Quarantäne statt Löschen). Das Speicherformat ändert die Option nicht; bestehende Einträge bleiben lesbar.
//
// Der Preis: Ist der Keystore-Schlüssel dauerhaft verloren, heilt sich der Speicher nicht mehr selbst; Lesen, Schreiben und Löschen scheitern. Für diesen Fall gibt es EINE
// bewusste Reparatur ([GeraeteSpeicher.zuruecksetzen]): nur auf ausdrücklichen Klick und nach Rückfrage, nie automatisch.
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Der einzige erlaubte Weg zum Alltagszugriff auf ein [FlutterSecureStorage] (ein Wächtertest in schluessel_matrix_test.dart prüft das).
const FlutterSecureStorage kSicherSpeicher = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false));

/// NUR für die bewusste Reparatur ([PluginGeraeteSpeicher.zuruecksetzen]): resetOnError: true lässt das Plugin bei kaputtem Keystore-Schlüssel alles samt Schlüsseln löschen.
const FlutterSecureStorage _kReparaturSpeicher = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: true));

/// Meldungen, die auf einen DAUERHAFT unbrauchbaren Eintrag oder Schlüssel hinweisen (Entschlüsseln scheitert, Keystore-Schlüssel ungültig oder verloren).
/// Alles andere (gesperrter Keystore, E/A) gilt als vorübergehend.
final _dauerhaftMuster = RegExp(
  'BadPadding|AEADBadTag|BadTag|IllegalBlockSize|MAC verification|Signature/MAC|InvalidKey|Key mismatch|KeyPermanentlyInvalidated|UnrecoverableKey|Failed to unwrap',
  caseSensitive: false,
);

/// Sieht [e] nach einem dauerhaft unbrauchbaren Speicher aus (nicht nach einem vorübergehenden Aussetzer)?
bool speicherFehlerDauerhaft(Object e) {
  final text = e is PlatformException ? '${e.code} ${e.message} ${e.details}' : e.toString();
  return _dauerhaftMuster.hasMatch(text);
}

/// Text der Fehlermeldung, wenn der Gerätespeicher defekt ist; die Oberfläche zeigt darunter den Knopf "Gerätespeicher zurücksetzen" (MeldungsBox).
const kGeraeteSpeicherDefektText =
    'Gerätespeicher defekt: Die App kann auf diesem Gerät nichts mehr sicher ablegen (der Android-Schlüsselspeicher ist nicht nutzbar). '
    'Versuche es noch einmal; hilft das nicht, kannst du den Gerätespeicher unten bewusst zurücksetzen.';

/// Der sichere Speicher dieses Geräts lässt sich nicht beschreiben (Schreiben scheitert mit einem Plattformfehler).
class GeraeteSpeicherDefekt implements Exception {
  const GeraeteSpeicherDefekt();
  String get meldung => kGeraeteSpeicherDefektText;

  @override
  String toString() => 'GeraeteSpeicherDefekt';
}

/// Prüfung und bewusste Reparatur des sicheren Speichers dieses Geräts (Android).
abstract class GeraeteSpeicher {
  /// Probe: Prüfeintrag schreiben, lesen, löschen und bereits vorhandene Einträge lesen; bei einem Fehler wird nach einer Pause wiederholt (insgesamt drei Versuche).
  /// true nur, wenn ALLE Versuche scheitern UND mindestens ein Fehler nach einem dauerhaften Defekt aussieht ([speicherFehlerDauerhaft]: Schlüssel ungültig, nicht
  /// entschlüsselbar). Reine E/A-Fehler, voller Speicher oder ein Aussetzer zählen nicht als Defekt.
  Future<bool> nachweislichDefekt();

  /// Löscht alles, was die App im sicheren Speicher hält, und lässt das Plugin dabei kaputte Schlüssel verwerfen. Nur nach Rückfrage und nach [nachweislichDefekt] aufrufen.
  Future<void> zuruecksetzen();
}

class PluginGeraeteSpeicher implements GeraeteSpeicher {
  final FlutterSecureStorage _alltag;
  final FlutterSecureStorage _reparatur;
  final Duration pause;
  PluginGeraeteSpeicher({FlutterSecureStorage? alltag, FlutterSecureStorage? reparatur, this.pause = const Duration(seconds: 1)})
    : _alltag = alltag ?? kSicherSpeicher,
      _reparatur = reparatur ?? _kReparaturSpeicher;

  static const _probe = 'lx_fampad_probe';

  /// Bereits vorhandene Einträge der App (Anmeldung, Index des Schlüsselspeichers): Ist einer davon dauerhaft nicht entschlüsselbar, zeigt das den Defekt am deutlichsten.
  static const _vorhandene = ['lx_fampad_tokens', 'lx_fampad___index'];

  /// Ein Versuch: null, wenn alles klappt; sonst der erste Fehler (bei einem unerwarteten Lesewert ein [StateError]).
  Future<Object?> _versuch() async {
    try {
      await _alltag.write(key: _probe, value: '1');
      final v = await _alltag.read(key: _probe);
      await _alltag.delete(key: _probe);
      if (v != '1') return StateError('Prüfeintrag nicht lesbar');
      for (final k in _vorhandene) {
        await _alltag.read(key: k);
      }
      return null;
    } on Object catch (e) {
      return e;
    }
  }

  @override
  Future<bool> nachweislichDefekt() async {
    var dauerhaft = false;
    for (var i = 0; i < 3; i++) {
      if (i > 0) await Future<void>.delayed(pause);
      final fehler = await _versuch();
      if (fehler == null) return false; // ein Versuch gelingt: ein Aussetzer, kein Defekt
      if (speicherFehlerDauerhaft(fehler)) dauerhaft = true;
    }
    return dauerhaft;
  }

  @override
  Future<void> zuruecksetzen() => _reparatur.deleteAll();
}

final geraeteSpeicherProvider = Provider<GeraeteSpeicher>((ref) => PluginGeraeteSpeicher());
