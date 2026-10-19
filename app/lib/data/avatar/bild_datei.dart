// Bildauswahl für das Benutzerbild. Wie beim ICS-Import: System-Picker (file_picker; Android ohne Speicherberechtigung, Web: Browser-Dialog),
// gelesen wird über einen Byte-Strom, nie über dart:io. Die Größe von höchstens 10 MB wird VOR dem Laden geprüft und beim Lesen erzwungen.
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bild_aufbereiten.dart';

/// Eine ausgewählte Bilddatei: Name, Größe (wenn ohne Lesen bekannt) und Inhalt als Strom.
class BildDatei {
  final String name;
  final int? laenge;
  final Stream<Uint8List> bytes;
  const BildDatei({required this.name, this.laenge, required this.bytes});
}

/// Lässt die Person ein Bild wählen (null = abgebrochen). Für Tests überschreibbar.
typedef BildDateiWaehler = Future<BildDatei?> Function();

Future<BildDatei?> _systemPicker() async {
  final f = await FilePicker.pickFile(type: FileType.image, dialogTitle: 'Foto wählen');
  if (f == null) return null;
  int? laenge;
  try {
    laenge = f.lengthSync() ?? await f.length();
  } catch (_) {
    laenge = null; // der Strom wird beim Lesen ohnehin bei 10 MB abgebrochen
  }
  return BildDatei(name: f.name, laenge: laenge, bytes: f.readAsByteStream());
}

final bildDateiWaehlerProvider = Provider<BildDateiWaehler>((ref) => _systemPicker);

/// Liest die Datei; ist sie größer als 10 MB, bricht es mit [BildFehler] ab, bevor sie ganz im Speicher liegt.
Future<Uint8List> bildDateiLesen(BildDatei d, {int max = kAvatarQuelleMaxBytes}) async {
  const zuGross = BildFehler('Das Bild ist größer als 10 MB. Wähle ein kleineres Foto.');
  if (d.laenge != null && d.laenge! > max) throw zuGross;
  final b = BytesBuilder(copy: false);
  var summe = 0;
  await for (final teil in d.bytes) {
    summe += teil.length;
    if (summe > max) throw zuGross;
    b.add(teil);
  }
  return b.takeBytes();
}
