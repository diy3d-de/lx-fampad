// Lädt die Wortliste für Passwort-Vorschläge (Asset, selbst gehostet; Quelle und Lizenz im Kopf der Datei).
import 'package:flutter/services.dart';

const String kWortlistePfad = 'assets/crypto/wortliste.txt';

/// Wörter ohne Kommentarzeilen (#) und Leerzeilen.
List<String> wortlisteParsen(String inhalt) => [
  for (final z in inhalt.split('\n'))
    if (z.trim().isNotEmpty && !z.startsWith('#')) z.trim(),
];

Future<List<String>> ladeWortliste([AssetBundle? bundle]) async => wortlisteParsen(await (bundle ?? rootBundle).loadString(kWortlistePfad));
