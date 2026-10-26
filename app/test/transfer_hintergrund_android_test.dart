// Dart-Seite des Übertragungs-Vordergrunddienstes (Android): der Kanal bekommt nur Zahlen (nie Namen), Fehler des Kanals stören nie.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/dateien/transfer_hintergrund_android.dart';
import 'package:lx_fampad/data/dateien/transfer_modelle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const kanal = MethodChannel('dev.lx_labs.fampad/transfer');
  final aufrufe = <MethodCall>[];

  setUp(() {
    aufrufe.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (c) async {
      aufrufe.add(c);
      return true;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, null));

  test('start, update und stop gehen mit Zahlen über den Kanal; Prozent wird begrenzt', () async {
    const p = AndroidTransferHintergrund();
    await p.starten(anzahl: 2);
    await p.aktualisieren(anzahl: 2, prozent: 140);
    await p.beenden();
    expect([for (final c in aufrufe) c.method], ['start', 'update', 'stop']);
    expect(aufrufe[0].arguments, {'anzahl': 2, 'prozent': 0});
    expect(aufrufe[1].arguments, {'anzahl': 2, 'prozent': 100});
    for (final c in aufrufe) {
      final a = c.arguments;
      if (a is Map) expect(a.values.every((v) => v is int), isTrue, reason: 'nur Zahlen, nie Namen');
    }
  });

  test('ein Fehler des Kanals wird verschluckt (die Übertragung läuft weiter)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (c) async => throw PlatformException(code: 'x'));
    const p = AndroidTransferHintergrund();
    await p.starten(anzahl: 1);
    await p.aktualisieren(anzahl: 1, prozent: 5);
    await p.beenden();
  });

  test('ohne Android-Seite (kein Plugin) ebenso', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, null);
    await const AndroidTransferHintergrund().starten(anzahl: 1);
  });

  test('auf dem Test-Rechner (kein Android) ist der Standard kein Dienst', () {
    expect(transferHintergrundStandard(), isA<KeinTransferHintergrund>());
  });
}
