// Gibt es die Kartendatei auf dem Server? Ohne sie (noch nicht eingerichtet, Datei fehlt) fällt die Standort-Seite auf die Liste zurück.
// Geprüft wird mit einer Range-Anfrage auf die ersten Bytes: 206 und die PMTiles-Kennung. Eine einfache Existenzprüfung genügt nicht: die Web-App
// beantwortet unbekannte Pfade mit index.html (Status 200), das wäre sonst fälschlich "vorhanden".
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'karte_config.dart';

/// Prüft die Kartendatei (einmal je App-Lauf; "Erneut prüfen" ruft `ref.invalidate` auf). Fehler und Zeitüberschreitung zählen als "nicht vorhanden".
final karteVerfuegbarProvider = FutureProvider<bool>((ref) async {
  final client = ref.read(httpClientProvider);
  try {
    final antwort = await client
        .get(Uri.parse('${karteOrigin()}$kKarteKachelPfad'), headers: {'Range': 'bytes=0-15'})
        .timeout(const Duration(seconds: 8));
    return antwort.statusCode == 206 && antwort.bodyBytes.length >= 7 && String.fromCharCodes(antwort.bodyBytes.take(7)) == 'PMTiles';
  } catch (_) {
    return false;
  }
});
