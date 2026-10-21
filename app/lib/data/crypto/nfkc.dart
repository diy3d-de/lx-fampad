// Vollständige Unicode-Normalisierung NFKC für Passwörter (Dart hat keine eingebaute; ein neues Paket ist nicht gewollt). Dasselbe Passwort ergibt auf jedem
// Gerät (Android, Web, andere Tastatur) dieselben Bytes: zusammengesetzt/zerlegt (é, й, Hangul), Kompatibilitätszeichen (Voll-/Halbbreite, Ligaturen,
// Leerzeichen), Umordnung mehrerer Akzentzeichen nach ihrer Kombinationsklasse.
// Umsetzung nach Unicode Standard Annex #15 mit den Tabellen aus nfkc_tabelle.dart (erzeugt von app/tool/gen_nfkc.mjs aus der UCD 16.0.0). Geprüft gegen die
// offizielle NormalizationTest.txt (alle Zeilen, test/crypto/nfkc_test.dart). Die Tabellen und dieses Verhalten gehören zum Passwort-Profil `kdf1` und dürfen
// sich nie ändern: Ändert sich das Ergebnis für irgendein Passwort, kann die Person ihre Sicherung nicht mehr öffnen. Eine neue Unicode-Version = neues Profil.
// Ungültiges UTF-16 (einzelne Surrogate) wird abgelehnt statt durch U+FFFD ersetzt (sonst würden verschiedene Eingaben dasselbe ergeben).
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'nfkc_tabelle.dart';

const int _sBase = 0xac00, _lBase = 0x1100, _vBase = 0x1161, _tBase = 0x11a7;
const int _lCount = 19, _vCount = 21, _tCount = 28, _nCount = _vCount * _tCount, _sCount = _lCount * _nCount;

/// Das Passwort enthält ungültige Zeichen (einzelne Surrogate); [CryptoFehlerArt.format].
const CryptoFehler kPasswortUngueltigeZeichen = CryptoFehler(CryptoFehlerArt.format, 'Das Passwort enthält ungültige Zeichen.');

void _zerlegen(int c, List<int> aus) {
  if (c >= _sBase && c < _sBase + _sCount) {
    final s = c - _sBase;
    aus.add(_lBase + s ~/ _nCount);
    aus.add(_vBase + (s % _nCount) ~/ _tCount);
    final t = s % _tCount;
    if (t != 0) aus.add(_tBase + t);
    return;
  }
  final z = kNfkdZerlegung[c];
  if (z == null) {
    aus.add(c);
    return;
  }
  for (final x in z) {
    if (x >= _sBase && x < _sBase + _sCount) {
      _zerlegen(x, aus);
    } else {
      aus.add(x);
    }
  }
}

int? _komponieren(int a, int b) {
  if (a >= _lBase && a < _lBase + _lCount && b >= _vBase && b < _vBase + _vCount) {
    return _sBase + ((a - _lBase) * _vCount + (b - _vBase)) * _tCount;
  }
  if (a >= _sBase && a < _sBase + _sCount && (a - _sBase) % _tCount == 0 && b > _tBase && b < _tBase + _tCount) return a + (b - _tBase);
  return kNfcKomposition[a * 2097152 + b];
}

/// NFKC von [text] als Codepunkte. Wirft [kPasswortUngueltigeZeichen] bei einzelnen Surrogaten.
List<int> nfkcCodepunkte(String text) {
  // 1. Kompatibilitätszerlegung
  final z = <int>[];
  for (var i = 0; i < text.length; i++) {
    var c = text.codeUnitAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      final n = i + 1 < text.length ? text.codeUnitAt(i + 1) : 0;
      if (n < 0xdc00 || n > 0xdfff) throw kPasswortUngueltigeZeichen;
      c = 0x10000 + ((c - 0xd800) << 10) + (n - 0xdc00);
      i++;
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      throw kPasswortUngueltigeZeichen;
    }
    _zerlegen(c, z);
  }
  // 2. kanonische Umordnung: Folgen von Zeichen mit Klasse != 0 stabil nach Klasse sortieren
  var i = 0;
  while (i < z.length) {
    if ((kKombinationsklasse[z[i]] ?? 0) == 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < z.length && (kKombinationsklasse[z[j]] ?? 0) != 0) {
      j++;
    }
    final lauf = z.sublist(i, j);
    // stabil: Einfügesortierung
    for (var a = 1; a < lauf.length; a++) {
      final x = lauf[a];
      final k = kKombinationsklasse[x]!;
      var b = a - 1;
      while (b >= 0 && kKombinationsklasse[lauf[b]]! > k) {
        lauf[b + 1] = lauf[b];
        b--;
      }
      lauf[b + 1] = x;
    }
    z.setRange(i, j, lauf);
    i = j;
  }
  // 3. kanonische Komposition
  if (z.isEmpty) return z;
  final aus = <int>[z[0]];
  var starter = (kKombinationsklasse[z[0]] ?? 0) == 0 ? 0 : -1; // Index des letzten Starters in [aus]
  var letzteKlasse = starter == 0 ? 0 : 256;
  for (var p = 1; p < z.length; p++) {
    final c = z[p];
    final k = kKombinationsklasse[c] ?? 0;
    if (starter >= 0) {
      final blockiert = aus.length - 1 != starter && (letzteKlasse >= k || letzteKlasse == 0);
      if (!blockiert) {
        final v = _komponieren(aus[starter], c);
        if (v != null) {
          aus[starter] = v;
          continue;
        }
      }
    }
    if (k == 0) {
      starter = aus.length;
      letzteKlasse = 0;
    } else {
      letzteKlasse = k;
    }
    aus.add(c);
  }
  return aus;
}

/// Passwort nach der Normalisierung als Text.
String passwortNormalisiert(String passwort) => String.fromCharCodes(nfkcCodepunkte(passwort));

/// Passwort als UTF-8-Bytes nach der Normalisierung. Kein Trimmen: Leerzeichen am Rand gehören zum Passwort.
Uint8List passwortBytes(String passwort) => utf8Bytes(passwortNormalisiert(passwort));
