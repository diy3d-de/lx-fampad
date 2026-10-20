// Gibt es die Kartendatei auf dem Server, und welchen Bereich deckt sie ab? Ohne sie (noch nicht eingerichtet, Datei fehlt) fällt die Standort-Seite auf die
// Liste zurück. Geprüft wird mit einer Range-Anfrage auf den Kopf der Datei (127 Byte): Status 206, PMTiles-Kennung und Version 3. Eine einfache
// Existenzprüfung genügt nicht: die Web-App beantwortet unbekannte Pfade mit index.html (Status 200), das wäre sonst fälschlich "vorhanden".
// Der Bereich (min/max Länge und Breite, je als Ganzzahl in Zehnmillionstel Grad) steht im Kopf: so passt sich die App einer größeren Datei von selbst an.
import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'karte_config.dart';

const int kPmtilesKopfLaenge = 127;

/// Liest den Kopf einer PMTiles-Datei (Version 3); null, wenn es keiner ist. Ein unsinniger Bereich (Ost nicht östlich von West, Werte außerhalb der Erde, alles 0) gilt als ungültig: dann gibt es keine Karte (Rückfall auf die Liste), statt der Kamera einen beliebigen Bereich zu erlauben.
KartenBereich? pmtilesBereich(Uint8List kopf) {
  if (kopf.length < kPmtilesKopfLaenge || String.fromCharCodes(kopf.take(7)) != 'PMTiles' || kopf[7] != 3) return null;
  final d = ByteData.sublistView(kopf);
  double e7(int offset) => d.getInt32(offset, Endian.little) / 1e7;
  final west = e7(102), sued = e7(106), ost = e7(110), nord = e7(114);
  if (west >= ost || sued >= nord || west < -180 || ost > 180 || sued < -90 || nord > 90) return null;
  return KartenBereich(west: west, ost: ost, sued: sued, nord: nord);
}

/// Der Bereich der Kartendatei auf dem Server; **null = es gibt (noch) keine brauchbare Datei** (404, Rechte, kein PMTiles-Kopf, unsinniger Bereich).
/// Ein **Fehler** (Netz, Zeitüberschreitung, Serverfehler) ist ein Fehlerzustand und kein "nicht vorhanden": die Seite sagt dann "Karte nicht erreichbar"
/// und versucht es von selbst wieder (Rückkehr in die App, Verbindung steht wieder) oder auf "Erneut prüfen". Einmal je App-Lauf gemerkt, sonst `ref.invalidate`.
final karteDateiProvider = FutureProvider<KartenBereich?>(
  (ref) async {
    final client = ref.read(httpClientProvider);
    return _kopfLesen(client).timeout(const Duration(seconds: 8));
  },
  // Riverpod wiederholt fehlgeschlagene Provider von selbst; hier entscheiden die Seite (Rückkehr, Verbindung, "Erneut prüfen") und die Person
  retry: (_, _) => null,
);

/// Liest nur den Kopf: Die Antwort wird als Strom gelesen und nach [kPmtilesKopfLaenge] Byte abgebrochen, eine andere Antwort als 206 sofort verworfen.
/// Antwortet ein Proxy oder Server trotz Range-Anfrage mit 200 und der ganzen Datei (hier über 1 GB), landet sie nie im Arbeitsspeicher
/// (`client.get` hätte den ganzen Körper gepuffert).
Future<KartenBereich?> _kopfLesen(http.Client client) async {
  final anfrage = http.Request('GET', Uri.parse('${karteOrigin()}$kKarteKachelPfad'))..headers['Range'] = 'bytes=0-${kPmtilesKopfLaenge - 1}';
  final antwort = await client.send(anfrage);
  // 206 mit einem unsinnig großen Körper (mehr als der angeforderte Kopf) ist ebenfalls keine brauchbare Antwort
  if (antwort.statusCode >= 500) {
    await antwort.stream.listen(null).cancel();
    throw http.ClientException('Kartenserver: ${antwort.statusCode}');
  }
  if (antwort.statusCode != 206 || (antwort.contentLength != null && antwort.contentLength! > kPmtilesKopfLaenge)) {
    await antwort.stream.listen(null).cancel();
    return null;
  }
  final kopf = BytesBuilder(copy: false);
  await for (final stueck in antwort.stream) {
    kopf.add(stueck);
    if (kopf.length >= kPmtilesKopfLaenge) break; // beendet das Lesen und schließt die Verbindung
  }
  return pmtilesBereich(kopf.takeBytes());
}
