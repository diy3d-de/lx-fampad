// Dateiauswahl und Lesen für den ICS-Import. Der System-Picker (file_picker) braucht auf Android keine Speicherberechtigung (Storage Access
// Framework) und läuft im Web im Browser-Dialog; gelesen wird über Bytes/Stream, nie über dart:io, damit derselbe Code im Web läuft.
// Laden über einen Link gibt es nur in der Android-App: im Web erlaubt die CSP (connect-src 'self') keine fremden Adressen, und ein
// Abruf über den eigenen Server wäre ein offener Abrufdienst (SSRF).
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers.dart';

import 'ics_lesen_stub.dart' if (dart.library.io) 'ics_lesen_io.dart';
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
  int? laenge;
  try {
    laenge = f.lengthSync() ?? await f.length(); // im Web kennt der Browser die Größe der Datei, ohne sie zu lesen
  } catch (_) {
    laenge = null; // der Strom wird beim Lesen ohnehin bei 5 MB abgebrochen
  }
  return IcsDatei(name: f.name, laenge: laenge, bytes: f.readAsByteStream());
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

/// Schlüssel in `sync_meta`: der zuletzt geladene Kalender-Link (nur auf diesem Gerät, `lokaleDatenWiper` löscht ihn mit).
const kIcsLinkSchluessel = 'ics_import_link';

/// Prüft einen eingegebenen Kalender-Link: nur https (`webcal://` wird zu `https://`), ohne Zugangsdaten vor dem Host. null = ungültig.
Uri? icsLinkPruefen(String eingabe) {
  var s = eingabe.trim();
  if (s.isEmpty || s.length > 2000) return null;
  if (s.toLowerCase().startsWith('webcal://')) s = 'https://${s.substring(9)}';
  final u = Uri.tryParse(s);
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
  return u;
}

/// Lädt eine ICS-Datei über einen Link. Für Tests überschreibbar.
typedef IcsLinkLader = Future<Uint8List> Function(Uri link);

/// Lädt höchstens 5 MB, folgt höchstens 5 Weiterleitungen und nur auf https. Fehlermeldungen nennen nie den Link (er enthält oft einen
/// geheimen Schlüssel des Kalenders).
Future<Uint8List> icsLinkLaden(http.Client client, Uri link) async {
  const nichtErreichbar = IcsFehler('Der Kalender konnte nicht geladen werden. Prüfe den Link und die Verbindung.');
  var ziel = link;
  for (var i = 0; i <= 5; i++) {
    final http.StreamedResponse antwort;
    try {
      antwort = await client.send(http.Request('GET', ziel)..followRedirects = false).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw nichtErreichbar;
    }
    final code = antwort.statusCode;
    if (code == 200) {
      if ((antwort.contentLength ?? 0) > kIcsMaxBytes) throw const IcsFehler('Die Datei ist größer als 5 MB.');
      // Fehler im Strom (Pause über 20 s, mehr als 60 s gesamt) beenden das `await for` in leseBegrenzt und damit die Verbindung
      const zuLangsam = IcsFehler('Der Kalender lädt zu langsam. Versuche es später noch einmal.');
      final ende = DateTime.now().add(const Duration(seconds: 60));
      final strom = antwort.stream.timeout(const Duration(seconds: 20), onTimeout: (s) => s.addError(zuLangsam)).map((b) {
        if (DateTime.now().isAfter(ende)) throw zuLangsam;
        return b is Uint8List ? b : Uint8List.fromList(b);
      });
      try {
        return await leseBegrenzt(strom);
      } on IcsFehler {
        rethrow;
      } catch (_) {
        throw nichtErreichbar;
      }
    }
    unawaited(antwort.stream.listen(null).cancel());
    if (const [301, 302, 303, 307, 308].contains(code)) {
      final ort = antwort.headers['location'];
      final weiter = ort == null ? null : icsLinkPruefen(Uri.tryParse(ort) == null ? '' : ziel.resolve(ort).toString());
      if (weiter == null) throw const IcsFehler('Der Link leitet auf eine Adresse ohne https weiter.');
      ziel = weiter;
      continue;
    }
    throw IcsFehler('Der Kalender konnte nicht geladen werden (Antwort $code).');
  }
  throw const IcsFehler('Der Link leitet zu oft weiter.');
}

final icsLinkLaderProvider = Provider<IcsLinkLader>((ref) => (link) => icsLinkLaden(ref.read(httpClientProvider), link));

/// Liest die ICS-Datei abseits des UI-Threads (Android: Isolate, Web: Etappen). Für Tests überschreibbar.
typedef IcsLeser = Future<IcsErgebnis> Function(Uint8List bytes, void Function(double)? fortschritt);

final icsLeserProvider = Provider<IcsLeser>((ref) => (bytes, fortschritt) => icsLesenImHintergrund(bytes, fortschritt: fortschritt));
