// Dateiauswahl und Lesen für den ICS-Import. Der System-Picker (file_picker) braucht auf Android keine Speicherberechtigung (Storage Access
// Framework) und läuft im Web im Browser-Dialog; gelesen wird über Bytes/Stream, nie über dart:io, damit derselbe Code im Web läuft.
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ics_parser.dart';

/// Eine ausgewählte Datei: Name, Größe (wenn ohne Lesen bekannt) und Inhalt als Strom.
class IcsDatei {
  final String name;
  final int? laenge;
  final Stream<Uint8List> bytes;
  const IcsDatei({required this.name, this.laenge, required this.bytes});
}

/// Lässt die Person eine Datei wählen (null = abgebrochen). Für Tests überschreibbar.
typedef IcsDateiWaehler = Future<IcsDatei?> Function();

Future<IcsDatei?> _systemPicker() async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['ics', 'ical', 'icalendar', 'ifb'], dialogTitle: 'ICS-Datei wählen');
  if (f == null) return null;
  return IcsDatei(name: f.name, laenge: f.lengthSync(), bytes: f.readAsByteStream());
}

final icsDateiWaehlerProvider = Provider<IcsDateiWaehler>((ref) => _systemPicker);

/// Liest den Strom und bricht ab, sobald mehr als [max] Bytes gekommen sind (die Datei wird nie ganz in den Speicher geholt).
Future<Uint8List> leseBegrenzt(Stream<Uint8List> quelle, {int max = kIcsMaxBytes}) async {
  final b = BytesBuilder(copy: false);
  var summe = 0;
  await for (final teil in quelle) {
    summe += teil.length;
    if (summe > max) throw const IcsFehler('Die Datei ist größer als 5 MB.');
    b.add(teil);
  }
  return b.takeBytes();
}
