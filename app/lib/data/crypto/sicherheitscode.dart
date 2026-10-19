// Sicherheitscode zum optionalen Vergleichen der öffentlichen Schlüssel (außerhalb der App: vorlesen oder QR zeigen).
// Familien-Code: SHA-256 über alle öffentlichen Schlüssel, sortiert nach Personen-ID; angezeigt als 6 Gruppen mit je 5 Ziffern (30 Ziffern).
// Personen-Code: derselbe Aufbau über die Schlüssel einer Person, 4 Gruppen (20 Ziffern). Beides ist unabhängig von der Kryptobibliothek (reines SHA-256)
// und ändert sich bei jedem Schlüsselwechsel einer Person (Schlüsselversion zählt nicht, nur die Schlüssel).
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'bytes.dart';
import 'schluessel.dart';

class MitgliedSchluessel {
  final String userId;
  final OeffentlicheSchluessel schluessel;
  const MitgliedSchluessel(this.userId, this.schluessel);
}

const String _zweck = 'lx-fampad|sicherheitscode|v1';

/// Ziffern aus dem Hash: je 5 Ziffern aus 5 Byte (Rest modulo 100000, vernachlässigbare Verzerrung bei 40 Bit).
String _ziffern(List<int> hash, int gruppen) {
  final out = <String>[];
  for (var i = 0; i < gruppen; i++) {
    var n = 0;
    for (var j = 0; j < 5; j++) {
      n = (n * 256) + hash[i * 5 + j];
    }
    out.add((n % 100000).toString().padLeft(5, '0'));
  }
  return out.join(' ');
}

List<int> _hash(List<MitgliedSchluessel> mitglieder) {
  final sortiert = [...mitglieder]..sort((a, b) => a.userId.compareTo(b.userId));
  final teile = <List<int>>[utf8Bytes(_zweck)];
  for (final m in sortiert) {
    teile.addAll([
      utf8Bytes(m.userId),
      const [0],
      m.schluessel.enc,
      m.schluessel.sign,
    ]);
  }
  return c.sha256.convert(Uint8List.fromList(verketten(teile))).bytes;
}

/// Code über alle Mitglieder mit Schlüsseln; leere Liste ergibt einen leeren Text.
String familienSicherheitscode(List<MitgliedSchluessel> mitglieder) => mitglieder.isEmpty ? '' : _ziffern(_hash(mitglieder), 6);

/// Code über die Schlüssel einer einzelnen Person.
String personenSicherheitscode(MitgliedSchluessel mitglied) => _ziffern(_hash([mitglied]), 4);
