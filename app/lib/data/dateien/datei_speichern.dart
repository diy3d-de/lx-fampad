// Speichern und Herunterladen für die Person (Abschnitt 6n): Android über den Systemdialog (`file_picker.saveFile`, Storage Access Framework, ohne Speicherberechtigung), Web über den Browser.
// Große Dateien laden im Web über eine NORMALE NAVIGATION auf die Adresse des Servers (Cookie der Sitzung, `Content-Disposition: attachment`), nie über `blob:` im Arbeitsspeicher; nur kleine,
// schon entschlüsselte Bytes (Anhänge im Tresor, bis 100 MB) gehen im Web als Blob an den Browser und werden nach 30 Sekunden freigegeben. Der Browser meldet weder Ziel noch Abbruch: `true` heißt
// dort nur "Download angestoßen". Zwischenablage und Systemdialog nur auf Tipp der Person. Nie Pfade, Namen oder Inhalte loggen.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import 'datei_ort.dart';
import 'datei_speichern_browser.dart' as browser;
import 'transfer_dienst.dart';

/// Speichert [bytes] unter [name] über den Systemdialog; false = die Person hat abgebrochen. Für Tests überschreibbar.
typedef BytesSpeichern = Future<bool> Function(String name, Uint8List bytes, String? mime);

/// Löst im Browser den Download einer Adresse aus (normale Navigation); für Tests überschreibbar.
typedef BrowserLaden = bool Function(String adresse, String name);

/// Gespeichert? Im Web löst `saveFile` einen Browser-Download aus und liefert danach immer null: dort gilt der Aufruf als Erfolg. Auf Android bedeutet null: die Person hat abgebrochen.
bool speichernErfolg(Uri? ziel, {required bool web}) => web || ziel != null;

Future<bool> _systemSpeichern(String name, Uint8List bytes, String? mime) async {
  final ziel = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mime ?? 'application/octet-stream', dialogTitle: 'Datei speichern');
  return speichernErfolg(ziel, web: kIsWeb);
}

class DateiSpeichernDienst {
  final DateiOrt ort;
  final BytesSpeichern _bytes;
  final BrowserLaden _browser;
  final String Function(String blobId) _adresse;
  final bool _web;

  DateiSpeichernDienst({required this.ort, required this._adresse, BytesSpeichern? bytes, BrowserLaden? browserLaden, bool? web})
    : _web = web ?? kIsWeb,
      _bytes = bytes ?? _systemSpeichern,
      _browser = browserLaden ?? browser.browserLaden;

  /// Speichert schon vorhandene Bytes (z. B. ein entschlüsselter Tresor-Anhang) über den Systemdialog bzw. den Browser. Die Bytes liegen nur im Arbeitsspeicher. false = abgebrochen.
  Future<bool> bytes(String name, Uint8List bytes, {String? mime}) => _bytes(name, bytes, mime);

  /// Speichert eine fertig geladene Datei aus dem Cache (Android): liest sie und übergibt sie dem Systemdialog. false = abgebrochen oder die Datei fehlt.
  Future<bool> ausPfad(String pfad, String name, {String? mime}) async {
    if (!ort.verfuegbar || !await ort.existiert(pfad)) return false;
    return _bytes(name, await ort.lesen(pfad), mime);
  }

  /// Web: lädt eine Datei der Ablage (Modus `server`) über eine normale Navigation (Anhang, nie `blob:`). Auf Android false (dort lädt der Transfer-Dienst in den Cache).
  bool imBrowser(String blobId, String name) => _web && _browser(_adresse(blobId), name);
}

final dateiSpeichernProvider = Provider<DateiSpeichernDienst>((ref) => DateiSpeichernDienst(ort: ref.watch(dateiOrtProvider), adresse: (blobId) => ref.read(apiClientProvider).adresseFuer('/files/blobs/$blobId')));
