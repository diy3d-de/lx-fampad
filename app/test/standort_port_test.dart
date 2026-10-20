// Android-Anschluss fürs Standort teilen: Kanalaufrufe und Ereignisse (die Kotlin-Seite ist hier ein Mock).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/standort/standort_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const kanal = MethodChannel('dev.lx_labs.fampad/standort');
  final aufrufe = <MethodCall>[];
  Object? antwort;

  setUp(() {
    aufrufe.clear();
    antwort = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (call) async {
      aufrufe.add(call);
      return antwort;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, null));

  const port = AndroidStandortPort();

  test('Akkuoptimierung: true, false oder unbekannt (Fehler im Kanal)', () async {
    antwort = true;
    expect(await port.akkuUneingeschraenkt(), isTrue);
    antwort = false;
    expect(await port.akkuUneingeschraenkt(), isFalse);
    expect(aufrufe.map((c) => c.method), ['akkuUneingeschraenkt', 'akkuUneingeschraenkt']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (call) async => throw PlatformException(code: 'x'));
    expect(await port.akkuUneingeschraenkt(), isNull);
    expect(await port.akkuAnfragen(), isFalse);
  });

  test('Akku-Systemdialog anfordern', () async {
    antwort = true;
    expect(await port.akkuAnfragen(), isTrue);
    expect(aufrufe.single.method, 'akkuAnfragen');
  });

  test('Start: Endzeit als Millisekunden; Fehlergründe der Kotlin-Seite werden übersetzt', () async {
    antwort = {'ok': true};
    final ende = DateTime.utc(2026, 10, 20, 12);
    expect(await port.starten(ende), isNull);
    expect(aufrufe.single.arguments, {'ende': ende.millisecondsSinceEpoch, 'intervall': 5000});
    antwort = {'ok': false, 'grund': 'benachrichtigungen_aus'};
    expect(await port.starten(ende), StartFehler.benachrichtigungenAus);
    antwort = {'ok': false, 'grund': 'keine_berechtigung'};
    expect(await port.starten(ende), StartFehler.keineBerechtigung);
    antwort = null;
    expect(await port.starten(ende), StartFehler.dienstStart);
  });

  test('Herzschlag: laeuft und stopAngefordert', () async {
    antwort = {'laeuft': true, 'stopAngefordert': true};
    expect(await port.herzschlag(), (laeuft: true, stopAngefordert: true));
    antwort = null;
    expect(await port.herzschlag(), (laeuft: false, stopAngefordert: false));
  });
}
