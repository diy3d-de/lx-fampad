// Eingeschränkte NFKC-Normalisierung für Passwörter (Dart kann es nicht von Haus aus; ein neues Paket ist nicht gewollt). Ziel: Dasselbe Passwort,
// auf verschiedenen Geräten und Tastaturen eingetippt, ergibt dieselben Bytes: 'é' zusammengesetzt (U+00E9) oder zerlegt (e + U+0301), geschützte
// Leerzeichen, Voll-/Halbbreitenzeichen, Ligaturen. Abgedeckt (Tabellen in nfkc_tabelle.dart, erzeugt von tools/gen-nfkc.mjs): Latin
// (U+00A0-U+024F, U+1E00-U+1EFF), Leerzeichen/Interpunktion (U+2000-U+2070), Ligaturen (U+FB00-U+FB06), Voll-/Halbbreite (U+FF00-U+FFEF).
// Nicht abgedeckt: andere Schriften (Griechisch, Kyrillisch, CJK, Hangul) bleiben unverändert, die Reihenfolge mehrerer Akzentzeichen
// (kanonische Umordnung) wird nicht angepasst. Die Tabellen und dieses Verhalten gehören zum Profil `kdf1` und dürfen sich nie ändern, sonst
// ergibt dasselbe Passwort einen anderen Schlüssel (neue Tabelle = neues Profil).
import 'dart:typed_data';

import 'bytes.dart';
import 'nfkc_tabelle.dart';

bool _akzent(int c) => c >= 0x300 && c <= 0x36f;

/// Normalisiert [text] (NFKC im oben beschriebenen Umfang) und gibt die Codepunkte zurück.
List<int> nfkcCodepunkte(String text) {
  // 1. Zerlegen (Kompatibilität und kanonisch); die Tabelle ist schon vollständig zerlegt (NFKD).
  final zerlegt = <int>[];
  for (final c in text.runes) {
    final z = kNfkdZerlegung[c];
    if (z == null) {
      zerlegt.add(c);
    } else {
      zerlegt.addAll(z);
    }
  }
  // 2. Zusammensetzen: ein Akzentzeichen verbindet sich mit dem unmittelbar davor stehenden Zeichen, wenn es dafür eine Komposition gibt.
  final aus = <int>[];
  for (final c in zerlegt) {
    if (_akzent(c) && aus.isNotEmpty) {
      final k = kNfcKomposition[(aus.last << 16) | c];
      if (k != null) {
        aus[aus.length - 1] = k;
        continue;
      }
    }
    aus.add(c);
  }
  return aus;
}

/// Passwort nach der Normalisierung als Text.
String passwortNormalisiert(String passwort) => String.fromCharCodes(nfkcCodepunkte(passwort));

/// Passwort als UTF-8-Bytes nach der Normalisierung. Kein Trimmen: Leerzeichen am Rand gehören zum Passwort.
Uint8List passwortBytes(String passwort) => utf8Bytes(passwortNormalisiert(passwort));
