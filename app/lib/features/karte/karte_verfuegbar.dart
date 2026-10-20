// Gibt es die Kartendatei auf dem Server, und welchen Bereich deckt sie ab? Ohne sie (noch nicht eingerichtet, Datei fehlt) fällt die Standort-Seite auf die
// Liste zurück. Geprüft wird mit einer Range-Anfrage auf den Kopf der Datei (127 Byte): Status 206, PMTiles-Kennung und Version 3. Eine einfache
// Existenzprüfung genügt nicht: die Web-App beantwortet unbekannte Pfade mit index.html (Status 200), das wäre sonst fälschlich "vorhanden".
// Der Bereich (min/max Länge und Breite, je als Ganzzahl in Zehnmillionstel Grad) steht im Kopf: so passt sich die App einer größeren Datei von selbst an.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'karte_config.dart';

const int kPmtilesKopfLaenge = 127;

/// Liest den Kopf einer PMTiles-Datei (Version 3); null, wenn es keiner ist. Ein unsinniger Bereich (alles 0) gilt als "ganze Welt".
KartenBereich? pmtilesBereich(Uint8List kopf) {
  if (kopf.length < kPmtilesKopfLaenge || String.fromCharCodes(kopf.take(7)) != 'PMTiles' || kopf[7] != 3) return null;
  final d = ByteData.sublistView(kopf);
  double e7(int offset) => d.getInt32(offset, Endian.little) / 1e7;
  final west = e7(102), sued = e7(106), ost = e7(110), nord = e7(114);
  if (west >= ost || sued >= nord || west < -180 || ost > 180 || sued < -90 || nord > 90) return const KartenBereich(west: -180, ost: 180, sued: -90, nord: 90);
  return KartenBereich(west: west, ost: ost, sued: sued, nord: nord);
}

/// Der Bereich der Kartendatei auf dem Server, null = keine (brauchbare) Datei. Einmal je App-Lauf; "Erneut prüfen" ruft `ref.invalidate` auf.
/// Fehler und Zeitüberschreitung zählen als "nicht vorhanden".
final karteDateiProvider = FutureProvider<KartenBereich?>((ref) async {
  final client = ref.read(httpClientProvider);
  try {
    final antwort = await client
        .get(Uri.parse('${karteOrigin()}$kKarteKachelPfad'), headers: {'Range': 'bytes=0-${kPmtilesKopfLaenge - 1}'})
        .timeout(const Duration(seconds: 8));
    if (antwort.statusCode != 206) return null;
    return pmtilesBereich(antwort.bodyBytes);
  } catch (_) {
    return null;
  }
});
