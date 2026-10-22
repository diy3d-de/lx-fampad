// Gemeinsame Einstellung für ALLE Zugriffe auf flutter_secure_storage (Anmeldung, Schlüsselspeicher, Erinnerungen).
// flutter_secure_storage 11.2.0 löscht auf Android bei einem Lesefehler standardmäßig selbst (AndroidOptions.resetOnError: true: bei `read` den Eintrag,
// bei Fehlern der Algorithmus-Migration oder von `readAll` ALLES samt Keystore-Schlüsseln) und liefert danach null = "nicht vorhanden". Für den Personenschlüssel wäre
// das Datenverlust ohne Rückfrage; mit `resetOnError: false` kommt der Fehler stattdessen als Ausnahme an (Schlüsselspeicher: SchluesselSpeicherFehler,
// Quarantäne statt Löschen). Das Speicherformat ändert die Option nicht; bestehende Einträge bleiben lesbar.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Der einzige erlaubte Weg zu einem [FlutterSecureStorage] (ein Wächtertest in schluessel_matrix_test.dart prüft das).
const FlutterSecureStorage kSicherSpeicher = FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false));
