// Schutz vor einem Fehler, der nur im Browser auftritt: Dart rechnet Bit-Verschiebungen im Web mit 32 Bit, `1 << 52` ergibt dort 0 (auf Android 2^52).
// So wurden Monatswerte im Web als ungültig abgewiesen, weil die Obergrenze 0 war. Große Zahlen immer als Literal schreiben (4503599627370496),
// Verschiebungen höchstens bis 31. Der Test liest den Quelltext von lib/ und schlägt bei jeder Verschiebung um 32 oder mehr Stellen an.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Kein Quelltext in lib/ verschiebt Bits um 32 oder mehr Stellen (im Web ergibt das 0)', () {
    final treffer = <String>[];
    final muster = RegExp(r'<<\s*(\d+)');
    for (final datei in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final zeilen = datei.readAsLinesSync();
      for (var i = 0; i < zeilen.length; i++) {
        final zeile = zeilen[i];
        if (zeile.trimLeft().startsWith('//') || zeile.trimLeft().startsWith('///') || zeile.contains("'<<") || zeile.contains('<< /')) continue;
        for (final m in muster.allMatches(zeile)) {
          if ((int.tryParse(m.group(1)!) ?? 0) >= 32) treffer.add('${datei.path}:${i + 1}: ${zeile.trim()}');
        }
      }
    }
    expect(treffer, isEmpty, reason: 'Im Web ergibt `1 << n` ab n = 32 den Wert 0. Große Zahlen als Literal schreiben:\n${treffer.join('\n')}');
  });
}
