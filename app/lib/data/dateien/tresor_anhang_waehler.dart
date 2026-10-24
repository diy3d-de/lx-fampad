// Dateiauswahl für Anhänge im Tresor (Abschnitt 6m/6n). Wie bei Benutzerbild und ICS-Import: System-Picker (`file_picker`; Android ohne Speicherberechtigung, Web: Browser-Dialog), gelesen wird
// über einen Byte-Strom, nie über dart:io. Die Größe wird VOR dem Laden geprüft und beim Lesen erzwungen; die Bytes liegen nur im Arbeitsspeicher und gehören dem Aufrufer, der sie nach der
// Benutzung überschreibt. Hier steht bewusst alles, was `file_picker` braucht, damit die Oberfläche des Tresors das Paket nie selbst einbindet. Nie Namen oder Inhalte loggen.
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'datei_modelle.dart' show DateiFehler;

/// Eine gewählte Datei: Name, Größe (wenn ohne Lesen bekannt) und Inhalt als Strom.
class AnhangWahl {
  final String name;
  final int? laenge;
  final Stream<Uint8List> bytes;
  const AnhangWahl({required this.name, this.laenge, required this.bytes});
}

/// Lässt die Person eine Datei wählen (null = abgebrochen). Für Tests überschreibbar.
typedef AnhangWaehler = Future<AnhangWahl?> Function();

Future<AnhangWahl?> _systemPicker() async {
  final f = await FilePicker.pickFile(dialogTitle: 'Dokument wählen');
  if (f == null) return null;
  int? laenge;
  try {
    laenge = f.lengthSync() ?? await f.length();
  } on Object {
    laenge = null; // der Strom wird beim Lesen ohnehin an der Obergrenze abgebrochen
  }
  return AnhangWahl(name: f.name, laenge: laenge, bytes: f.readAsByteStream());
}

final tresorAnhangWaehlerProvider = Provider<AnhangWaehler>((ref) => _systemPicker);

/// Liest die Datei bis höchstens [max] Byte; ist sie größer, bricht es mit [DateiFehler.zuGross] ab, bevor sie ganz im Speicher liegt.
Future<Uint8List> anhangWahlLesen(AnhangWahl w, {required int max}) async {
  if (w.laenge != null && w.laenge! > max) throw DateiFehler.zuGross;
  final b = BytesBuilder(copy: false);
  var summe = 0;
  await for (final teil in w.bytes) {
    summe += teil.length;
    if (summe > max) throw DateiFehler.zuGross;
    b.add(teil);
  }
  return b.takeBytes();
}
