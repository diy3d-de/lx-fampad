// Profil > Über: Version und Build, Server und Protokoll, Kopieren, Update-Prüfung; Layout bei 360 px, Textskala 1.0/1.5.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/profile/ueber_screen.dart';
import 'package:lx_fampad/features/update/update_service.dart';

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  const android = UeberInfo(
    version: '0.2.0',
    build: 1002,
    plattform: 'Android',
    geraet: 'Pixel 9',
    server: ServerVersion(version: '0.1.4', protocolVersion: 1, minProtocolVersion: 1, minAppVersion: '0.1.0', webVersion: null),
  );
  const web = UeberInfo(version: 'dev', plattform: 'Web');

  Future<void> oeffnen(WidgetTester tester, UeberInfo info, {double skala = 1.0}) async {
    final env = await angemeldeteUmgebung();
    env.extraOverrides.add(ueberInfoProvider.overrideWith((ref) async => info));
    await starteApp(tester, env, skala: skala);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippeText(tester, 'Über $kUeberAppName');
    await warte(tester);
  }

  for (final skala in [1.0, 1.5]) {
    testWidgets('Textskala $skala: Angaben sichtbar, kein Überlauf, Touch-Ziele mindestens 44 px', (tester) async {
      await oeffnen(tester, android, skala: skala);
      expect(find.text('$kUeberAppName 0.2.0'), findsOneWidget);
      expect(find.text('build 1002 · Android'), findsOneWidget);
      expect(find.text('Server 0.1.4 · Protokoll 1'), findsOneWidget);
      expect(find.text('Pixel 9'), findsOneWidget);
      expect(find.text('Nach Update suchen'), findsOneWidget);
      pruefeLayout(tester, 'Über');
    });
  }

  testWidgets('Tipp auf die Versionszeile kopiert die Kurzangabe', (tester) async {
    String? kopiert;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') kopiert = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await oeffnen(tester, android);
    expect(kopiert, isNull, reason: 'nur auf Klick');
    await tippeText(tester, '$kUeberAppName 0.2.0');
    expect(kopiert, 'lx-familyhub 0.2.0 (1002) · Android');
    expect(find.text('Versionsangabe kopiert'), findsOneWidget);
  });

  testWidgets('Web: Kennung "dev" ohne Build-Nummer, Server unbekannt', (tester) async {
    await oeffnen(tester, web);
    expect(find.text('$kUeberAppName dev'), findsOneWidget);
    expect(find.text('Web'), findsOneWidget);
    expect(find.text('nicht erreichbar'), findsOneWidget);
    expect(web.kurz, 'lx-familyhub dev · Web');
  });

  testWidgets('Nach Update suchen: Prüfung läuft ohne Absturz und meldet Ergebnis', (tester) async {
    await oeffnen(tester, android);
    await tippeText(tester, 'Nach Update suchen');
    await warte(tester, 10);
    expect(find.text('Update'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
