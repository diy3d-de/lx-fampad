// ICS lesen abseits des UI-Threads (Android, Desktop): ein Isolate parst die Datei. Die Zeitzonen-Daten werden pro Isolate neu geladen
// (der Zustand des Pakets timezone gilt nur im eigenen Isolate); die Bytes kommen aus dem Asset und werden mitgegeben.
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:timezone/timezone.dart' as tz;

import 'ics_parser.dart';
import 'zeitzonen.dart';

Future<IcsErgebnis> icsLesenImHintergrund(Uint8List bytes, {void Function(double)? fortschritt, Uint8List? zonenDaten}) async {
  final daten = zonenDaten ?? (await rootBundle.load(kZeitzonenAsset)).buffer.asUint8List();
  fortschritt?.call(0.1);
  return Isolate.run(() {
    tz.initializeDatabase(daten);
    return icsLesen(bytes);
  });
}
