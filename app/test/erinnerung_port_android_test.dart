// Android-Port der Erinnerungen gegen einen Fake des Systemkanals (MainActivity.kt): Zustände der Erlaubnis (nie gefragt, einmal abgelehnt,
// dauerhaft verweigert, erlaubt, Kanal aus), Merken der Anfrage, Aufruf der Systemeinstellungen, Rückfall bei Fehlern.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_port.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_port_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const kanal = MethodChannel(kSystemChannel);
  late List<String> aufrufe;
  late Map<String, Object?> status;
  late Object? oeffnenAntwort;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    aufrufe = [];
    status = {'enabled': false, 'canAsk': true, 'channelImportance': 4};
    oeffnenAntwort = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (call) async {
      aufrufe.add(call.method);
      switch (call.method) {
        case 'notificationStatus':
          return status;
        case 'openNotificationSettings':
        case 'openExactAlarmSettings':
          if (oeffnenAntwort is Exception) throw PlatformException(code: 'x');
          return oeffnenAntwort;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, null);
  });

  test('nie gefragt oder einmal abgelehnt: fragbar', () async {
    expect(await AndroidErinnerungPort().benachrichtigungsStatus(), BenachrichtigungsStatus.fragbar);
  });

  test('dauerhaft verweigert: gesperrt, nur der Weg in die Einstellungen', () async {
    status = {'enabled': false, 'canAsk': false, 'channelImportance': 4};
    final p = AndroidErinnerungPort();
    expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.gesperrt);
    expect(await p.benachrichtigungenErlaubt(), isFalse);
  });

  test('erlaubt wird live gelesen (jeder Aufruf fragt das System, kein gespeicherter Wert)', () async {
    final p = AndroidErinnerungPort();
    expect(await p.benachrichtigungenErlaubt(), isFalse);
    status = {'enabled': true, 'canAsk': false, 'channelImportance': 4};
    expect(await p.benachrichtigungenErlaubt(), isTrue);
    expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.erlaubt);
    expect(aufrufe.where((a) => a == 'notificationStatus').length, 3);
  });

  test('Anfrage merkt sich den Versuch und liefert den neuen Zustand', () async {
    final p = AndroidErinnerungPort();
    status = {'enabled': false, 'canAsk': false, 'channelImportance': 4};
    expect(await p.benachrichtigungenAnfragen(), isFalse);
    expect(aufrufe, contains('notificationAsked'));
  });

  test('bereits erlaubt: keine Anfrage', () async {
    status = {'enabled': true, 'canAsk': false, 'channelImportance': 4};
    expect(await AndroidErinnerungPort().benachrichtigungenAnfragen(), isTrue);
    expect(aufrufe, isNot(contains('notificationAsked')));
  });

  test('Systemeinstellungen: Aufruf des eigenen Kanals, Erfolg und Misserfolg', () async {
    final p = AndroidErinnerungPort();
    expect(await p.systemEinstellungenOeffnen(), isTrue);
    expect(aufrufe, contains('openNotificationSettings'));
    oeffnenAntwort = false;
    expect(await p.systemEinstellungenOeffnen(), isFalse);
    oeffnenAntwort = Exception('x');
    expect(await p.systemEinstellungenOeffnen(), isFalse);
  });

  test('Alarme & Erinnerungen: eigener Aufruf', () async {
    expect(await AndroidErinnerungPort().alarmEinstellungenOeffnen(), isTrue);
    expect(aufrufe, contains('openExactAlarmSettings'));
  });

  test('Diagnose enthält nur Zustände und die Kanal-Wichtigkeit', () async {
    status = {'enabled': false, 'canAsk': false, 'channelImportance': 0};
    final d = await AndroidErinnerungPort().diagnose();
    expect(d.erlaubt, isFalse);
    expect(d.kanal, 0);
  });

  test('Systemaufruf scheitert und Plugin liefert nichts: unbekannt, nie "verweigert"', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (call) async {
      throw PlatformException(code: 'kaputt');
    });
    final p = AndroidErinnerungPort();
    expect(await p.benachrichtigungsStatus(), BenachrichtigungsStatus.unbekannt);
    expect((await p.diagnose()).fehler, isNotNull);
  });

  test('Alarm-Einstellungen scheitern: Rückfall auf die Benachrichtigungseinstellungen', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(kanal, (call) async {
      aufrufe.add(call.method);
      return call.method == 'openExactAlarmSettings' ? false : true;
    });
    expect(await AndroidErinnerungPort().alarmEinstellungenOeffnen(), isTrue);
    expect(aufrufe, ['openExactAlarmSettings', 'openNotificationSettings']);
  });
}
