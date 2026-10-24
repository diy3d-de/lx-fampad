// Dateiauswahl für die Dateiablage (Abschnitt 6n): der System-Dialog (file_picker; Android ohne Speicherberechtigung, Web: Browser-Dialog) liefert mehrere Dateien; daraus werden Upload-Quellen,
// die abschnittsweise lesen (nie die ganze Datei im Speicher): Android per Pfad (fortsetzbar nach einem Neustart), Web als `Blob` des Browsers. Nie Namen, Pfade oder Inhalte loggen.
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'datei_waehler_plattform.dart' as plattform;
import 'upload_quelle.dart';

/// Eine gewählte Datei, bereit zum Hochladen.
class GewaehlteDatei {
  final String name;
  final int laenge;
  final UploadQuelle quelle;

  /// Android: Pfad der Datei (für das Fortsetzen nach einem Neustart); im Web null.
  final String? pfad;
  const GewaehlteDatei({required this.name, required this.laenge, required this.quelle, this.pfad});
}

/// Ergebnis der Auswahl: die lesbaren Dateien und die Zahl der Dateien, die sich nicht öffnen ließen. Abgebrochen = leer und 0.
class DateiAuswahl {
  final List<GewaehlteDatei> dateien;
  final int nichtLesbar;
  const DateiAuswahl(this.dateien, [this.nichtLesbar = 0]);
}

/// Lässt die Person Dateien wählen; für Tests überschreibbar.
typedef DateiWaehler = Future<DateiAuswahl> Function({required bool nurBilder});

Future<DateiAuswahl> _systemWaehler({required bool nurBilder}) async {
  final l = await FilePicker.pickFiles(type: nurBilder ? FileType.image : FileType.any, dialogTitle: nurBilder ? 'Fotos wählen' : 'Dateien wählen');
  final ok = <GewaehlteDatei>[];
  var fehl = 0;
  for (final f in l) {
    final q = await plattform.quelleAusAuswahl(f);
    if (q == null) {
      fehl++;
      continue;
    }
    ok.add(GewaehlteDatei(name: f.name, laenge: q.laenge, quelle: q, pfad: f.path));
  }
  return DateiAuswahl(ok, fehl);
}

final dateiWaehlerProvider = Provider<DateiWaehler>((ref) => _systemWaehler);
