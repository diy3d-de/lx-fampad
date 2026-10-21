// Lädt die Wortliste für Passwort-Vorschläge (Asset, selbst gehostet; Quelle und Lizenz im Kopf der Datei).
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String kWortlistePfad = 'assets/crypto/wortliste.txt';

/// Wörter ohne Kommentarzeilen (#) und Leerzeilen.
List<String> wortlisteParsen(String inhalt) => [
  for (final z in inhalt.split('\n'))
    if (z.trim().isNotEmpty && !z.startsWith('#')) z.trim(),
];

Future<List<String>> ladeWortliste([AssetBundle? bundle]) async => wortlisteParsen(await (bundle ?? rootBundle).loadString(kWortlistePfad));

/// Wortliste für den Passwort-Vorschlag (Tests ersetzen sie).
final wortlisteProvider = FutureProvider<List<String>>((ref) => ladeWortliste(), retry: (_, _) => null);
