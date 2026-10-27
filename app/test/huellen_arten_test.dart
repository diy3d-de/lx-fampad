// Die Art-Buchstaben der e1-Hüllen stehen an einer Stelle (data/crypto/huellen_arten.dart) und sind alle verschieden und je ein Buchstabe.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/huellen_arten.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart' as med;
import 'package:lx_fampad/data/vorsorge/vorsorge_modelle.dart' as vor;

void main() {
  test('alle Buchstaben sind verschieden, klein und einzeln', () {
    expect(kHuellenArten.toSet().length, kHuellenArten.length);
    for (final a in kHuellenArten) {
      expect(RegExp(r'^[a-z]$').hasMatch(a), isTrue, reason: a);
    }
    expect(kHuellenArten.toSet(), {'r', 's', 'm', 'n', 'z', 'a', 't', 'f', 'p', 'v'});
  });

  test('die bisherigen Namen zeigen auf dieselben Werte (kein Verhalten geändert)', () {
    expect(med.kArtMedikament, 'm');
    expect(med.kArtEinnahme, 'n');
    expect(vor.kArtVorsorgeProfil, 'p');
    expect(vor.kArtVorsorgeEintrag, 'v');
  });

  test('im Code steht kein weiterer Art-Buchstabe als Literal (nur huellen_arten.dart vergibt sie)', () {
    final treffer = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      if (f.path.replaceAll('\\', '/').endsWith('data/crypto/huellen_arten.dart')) continue;
      final s = f.readAsStringSync();
      if (RegExp(r"\bkArt[A-Za-z]*\s*=\s*'").hasMatch(s) || RegExp(r"\bart:\s*'[a-z]'").hasMatch(s)) treffer.add(f.path);
    }
    expect(treffer, isEmpty);
  });
}
