// Datei speichern für den ICS-Export. Der System-Dialog von file_picker (schon für den Import im Einsatz) speichert auf Android über das
// Storage Access Framework (ohne Speicherberechtigung) und löst im Web einen Download im Browser aus; kein dart:io, kein dart:html.
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Speichert [bytes] unter [name]; false = die Person hat abgebrochen. Für Tests überschreibbar.
typedef IcsSpeichern = Future<bool> Function(String name, Uint8List bytes);

/// Gespeichert? Im Web löst `saveFile` einen Browser-Download aus und liefert danach immer null (der Browser meldet weder Ziel noch Abbruch):
/// dort gilt der Aufruf als Erfolg. Auf Android bedeutet null: die Person hat abgebrochen.
bool icsSpeichernErfolg(Uri? ziel, {required bool web}) => web || ziel != null;

Future<bool> _systemSpeichern(String name, Uint8List bytes) async {
  final ziel = await FilePicker.saveFile(
    fileName: name,
    bytes: bytes,
    mimeType: 'text/calendar',
    dialogTitle: 'Kalender speichern',
    type: FileType.custom,
    allowedExtensions: const ['ics'],
  );
  return icsSpeichernErfolg(ziel, web: kIsWeb);
}

final icsSpeichernProvider = Provider<IcsSpeichern>((ref) => _systemSpeichern);
