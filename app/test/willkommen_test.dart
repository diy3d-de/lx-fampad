// App-Download: Ergebnisseite der Einladung (Download-Block, zweiter QR, kopierbarer Link), Willkommenshinweis im
// Browser (Android auffällig, Desktop dezent, in der App nichts), kein Token im Download-Link; 360 px, Textskala 1.0/1.5.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/features/admin/einladung_neu.dart';
import 'package:lx_fampad/features/auth/invite_screen.dart';
import 'package:lx_fampad/ui/theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  const token = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdE';
  final einladung = CreatedInvite(
    id: 'i1',
    token: token,
    link: 'https://familyhub.lx-labs.dev/#/einladung/$token',
    pin: '123456',
    expiresAt: DateTime.now().add(const Duration(hours: 24)),
    requireApproval: false,
  );

  Future<void> zeige(WidgetTester tester, Widget w, {double skala = 1.0}) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = skala;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    kanalMocken();
    await tester.pumpWidget(ProviderScope(child: MaterialApp(theme: buildTheme(), home: w)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('Download-Link ohne Token und Query', () {
    final u = Uri.parse(kApkDownloadUrl);
    expect(u.scheme, 'https');
    expect(u.host, kInviteHost);
    expect(u.path, '/releases/android/lx-familyhub-latest.apk');
    expect(u.hasQuery || u.hasFragment, isFalse);
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Ergebnisseite, Textskala $skala: Download-Block, zweiter QR, kein Überlauf', (tester) async {
      await zeige(tester, EinladungErstelltSeite(einladung: einladung), skala: skala);
      final liste = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Download-Link kopieren'), 200, scrollable: liste);
      expect(find.text('// APP INSTALLIEREN'), findsOneWidget);
      expect(find.byType(QrImageView), findsNWidgets(2));
      expect(find.text(kApkDownloadUrl), findsOneWidget);
      expect(find.textContaining('Installation aus dieser Quelle erlauben'), findsOneWidget);
      expect(find.textContaining('Automatische Sperre (Samsung)'), findsOneWidget);
      expect(find.text('Oder öffne den Einladungslink einfach im Browser.'), findsOneWidget);
      pruefeLayout(tester, 'Ergebnisseite');
    });
  }

  testWidgets('Download-Link kopieren: nur auf Klick, ohne Token', (tester) async {
    String? kopiert;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') kopiert = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await zeige(tester, EinladungErstelltSeite(einladung: einladung));
    expect(kopiert, isNull);
    await tester.scrollUntilVisible(find.text('Download-Link kopieren'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Download-Link kopieren'));
    await tester.pump();
    expect(kopiert, kApkDownloadUrl);
    expect(kopiert, isNot(contains(token)));
    expect(find.text('Download-Link kopiert.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Willkommen Web-Android, Textskala $skala: Hinweisfeld mit Download', (tester) async {
      await zeige(tester, const InviteScreen(webBrowser: true, webAndroid: true), skala: skala);
      expect(find.text('Lieber die App? $kAppName für Android herunterladen'), findsOneWidget);
      expect(find.text('App herunterladen'), findsOneWidget);
      pruefeLayout(tester, 'Willkommen Android');
    });
  }

  testWidgets('Willkommen Desktop-Browser: nur dezenter Text, kein Knopf', (tester) async {
    await zeige(tester, const InviteScreen(webBrowser: true, webAndroid: false));
    expect(find.textContaining('auch als Android-App'), findsOneWidget);
    expect(find.text('App herunterladen'), findsNothing);
    pruefeLayout(tester, 'Willkommen Desktop');
  });

  testWidgets('Willkommen in der App (kein Browser): kein Hinweis', (tester) async {
    await zeige(tester, const InviteScreen(webBrowser: false, webAndroid: true));
    expect(find.textContaining('Lieber die App?'), findsNothing);
    expect(find.textContaining('Android-App'), findsNothing);
  });
}
