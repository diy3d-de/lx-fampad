// Ort der heruntergeladenen Dateien auf dem Gerät (nur Android; im Web gibt es keinen Ordner: dort lädt der Browser selbst, siehe `datei_speichern.dart`). Eine kleine Schnittstelle über dart:io, damit
// der Rest der Datenschicht im Web ohne dart:io übersetzt und in Tests ein Wegwerf-Ordner eingesetzt werden kann. Alle Dateien liegen im Cache-Ordner der App (privat, nie öffentlich); Dateinamen
// sind Blob-IDs (nie ein Name der Person). Nie Pfade, Namen oder Inhalte loggen.
import 'dart:typed_data';

import 'datei_ort_plattform.dart' as plattform;

abstract class DateiOrt {
  /// Gibt es auf dieser Plattform einen Ordner für Dateien (Android: ja, Web: nein)?
  bool get verfuegbar;

  /// Pfad der Datei zu [name] im Cache-Ordner (legt den Ordner an); null ohne Ordner.
  Future<String?> pfad(String name);

  Future<bool> existiert(String pfad);

  /// Größe in Byte; 0, wenn es die Datei nicht gibt.
  Future<int> laenge(String pfad);

  /// Hängt Bytes an (legt die Datei an, wenn sie fehlt).
  Future<void> anhaengen(String pfad, Uint8List bytes);

  Future<Uint8List> lesen(String pfad);

  Future<void> umbenennen(String von, String nach);

  Future<void> loeschen(String pfad);

  /// SHA-256 der Datei als Hex-Text, abschnittsweise gelesen (nie die ganze Datei im Speicher).
  Future<String> sha256(String pfad);

  /// Löscht den ganzen Cache-Ordner samt Inhalt (Abmelden, Gerät abgeben).
  Future<void> alleLoeschen();

  /// Der Ort dieser Plattform (Android: der Cache-Ordner der App, Web: keiner).
  static DateiOrt standard() => plattform.dateiOrtErzeugen();
}

/// Ohne Ordner (Web und Fallback).
class KeinDateiOrt implements DateiOrt {
  const KeinDateiOrt();
  @override
  bool get verfuegbar => false;
  @override
  Future<String?> pfad(String name) async => null;
  @override
  Future<bool> existiert(String pfad) async => false;
  @override
  Future<int> laenge(String pfad) async => 0;
  @override
  Future<void> anhaengen(String pfad, Uint8List bytes) async => throw UnsupportedError('Kein Dateiordner im Web');
  @override
  Future<Uint8List> lesen(String pfad) async => throw UnsupportedError('Kein Dateiordner im Web');
  @override
  Future<void> umbenennen(String von, String nach) async {}
  @override
  Future<void> loeschen(String pfad) async {}
  @override
  Future<String> sha256(String pfad) async => throw UnsupportedError('Kein Dateiordner im Web');
  @override
  Future<void> alleLoeschen() async {}
}
