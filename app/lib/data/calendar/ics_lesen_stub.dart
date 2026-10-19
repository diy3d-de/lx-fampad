// ICS lesen im Web: es gibt keine Isolates, deshalb in Etappen mit Fortschritt (die Oberfläche bleibt bedienbar).
import 'dart:typed_data';

import 'ics_parser.dart';

Future<IcsErgebnis> icsLesenImHintergrund(Uint8List bytes, {void Function(double)? fortschritt, Uint8List? zonenDaten}) =>
    icsLesenEtappen(bytes, fortschritt: fortschritt);
