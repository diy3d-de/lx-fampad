// Begrüßung mit Namen auf dem Start-Tab und Profil > Passwort & Zwei-Faktor (einrichten, ändern, entfernen), 360 px, Textskala 1.0/1.5.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/home/home_screen.dart';
import 'package:lx_fampad/features/profile/password_screen.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _geheimnis = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';

Map<String, dynamic> _startAntwort() => {
  'challengeId': 'c-pw',
  'totpSecret': _geheimnis,
  'totpUri': 'otpauth://totp/lx-fampad:anna%40beispiel.de?secret=$_geheimnis&issuer=lx-fampad',
};

/// Server, bei dem /me den aktuellen Stand der Zugänge liefert (ändert sich nach Einrichten/Entfernen).
FakeServer _server({bool password = false, int passkeys = 1}) {
  final s = standardServer();
  var hatPasswort = password;
  s.on('GET /me', (_) => jsonAntwort(meJson(passkeys: passkeys, password: hatPasswort, totp: hatPasswort)));
  s.on('POST /me/password/start', (_) => jsonAntwort(_startAntwort()));
  s.on('POST /me/password/complete', (_) {
    hatPasswort = true;
    return jsonAntwort({'ok': true});
  });
  s.on('POST /me/password/change', (_) => jsonAntwort({'ok': true}));
  s.on('DELETE /me/password', (_) {
    hatPasswort = false;
    return jsonAntwort({'ok': true});
  });
  return s;
}

Future<void> _zurSeite(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Passwort und Zwei-Faktor (TOTP)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Begrüßung', () {
    test('Vorname aus dem Anzeigenamen, robust bei leer und lang', () {
      expect(begruessung('Anna'), 'Hallo, Anna');
      expect(begruessung('Anna Maria Beispiel'), 'Hallo, Anna');
      expect(begruessung('  Ben  '), 'Hallo, Ben');
      expect(begruessung(null), 'Hallo');
      expect(begruessung(''), 'Hallo');
      expect(begruessung('   '), 'Hallo');
      expect(begruessung('A' * 60), 'Hallo, ${'A' * 19}…');
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('Start-Tab zeigt "Hallo, Anna" (360 px, Textskala $skala)', (tester) async {
        final env = await angemeldeteUmgebung();
        await starteApp(tester, env, skala: skala);
        expect(find.descendant(of: find.byType(HomeScreen), matching: find.text('Hallo, Anna')), findsOneWidget);
        pruefeLayout(tester, 'Start');
      });

      testWidgets('Start-Tab mit sehr langem Namen ohne Layoutfehler (360 px, Textskala $skala)', (tester) async {
        final server = standardServer();
        final me = meJson();
        (me['user'] as Map<String, dynamic>)['displayName'] = 'Maximilianiusschmidtbergerhofstetter-Wolkenkuckucksheim Zweiter';
        server.json('GET /me', me);
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        expect(find.textContaining('Hallo, Maximilianius'), findsOneWidget);
        pruefeLayout(tester, 'Start langer Name');
      });
    }
  });

  group('Passwort und Zwei-Faktor', () {
    testWidgets('Zeile ist klickbar und zeigt den Stand', (tester) async {
      final env = TestUmgebung(_server());
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      expect(find.byType(PasswordScreen), findsOneWidget);
      expect(find.text('Noch nicht eingerichtet'), findsOneWidget);
      expect(find.text('Passwort einrichten'), findsOneWidget);
    });

    testWidgets('Einrichten: Prüfungen, Step-up, QR/Schlüssel, Code bestätigen, danach "an"', (tester) async {
      var stepUp = true;
      final server = _server()
        ..on('POST /me/password/start', (_) {
          if (stepUp) return fehler(403, 'step_up_required');
          return jsonAntwort(_startAntwort());
        })
        ..json('POST /auth/step-up/code', {'stepUpAt': DateTime.now().toUtc().toIso8601String()});
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      await tippeText(tester, 'Passwort einrichten');

      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'kurz');
      await eingeben(tester, 'Passwort wiederholen', 'kurz');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(find.text('Das Passwort braucht mindestens 12 Zeichen.'), findsOneWidget);
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-sehr-langes-passwort');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(find.text('Die beiden Passwörter sind nicht gleich.'), findsOneWidget);
      expect(server.anfragen('POST /me/password/start'), isEmpty);

      await eingeben(tester, 'Passwort wiederholen', 'ein-sehr-langes-passwort');
      await tippeText(tester, 'Weiter zum Authenticator');
      // Step-up-Dialog: mit Code bestätigen, dann läuft der Start erneut
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      stepUp = false;
      await tippeText(tester, 'Wiederherstellungscode nutzen');
      await eingeben(tester, 'Wiederherstellungscode', 'ABCD-EFGH-IJKL-MNOP');
      await tippeText(tester, 'Mit Code bestätigen');
      expect(server.anfragen('POST /me/password/start').last.json, {'password': 'ein-sehr-langes-passwort'});

      // Stufe 2: Schlüssel sichtbar, Bildschirmschutz an, nichts in der Zwischenablage
      expect(find.text('JBSW Y3DP EHPK 3PXP JBSW Y3DP EHPK 3PXP'), findsOneWidget);
      expect(kanalAufrufe.where((c) => c.method == 'setSecure').last.arguments, {'secure': true});
      final kopiert = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') kopiert.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      expect(kopiert, isEmpty);

      await tippeText(tester, 'Bestätigen und einrichten');
      expect(find.text('Bitte gib den 6-stelligen Code aus der Authenticator-App ein.'), findsOneWidget);
      await eingeben(tester, 'Code aus der Authenticator-App', '654321');
      await tippeText(tester, 'Bestätigen und einrichten');
      expect(server.anfragen('POST /me/password/complete').single.json, {'challengeId': 'c-pw', 'code': '654321'});
      expect(find.text('Passwort und Zwei-Faktor sind eingerichtet.'), findsOneWidget);
      expect(find.text('Passwort und Authenticator sind eingerichtet'), findsOneWidget);
      expect(find.text('Passwort ändern'), findsOneWidget);
      expect(kanalAufrufe.where((c) => c.method == 'setSecure').last.arguments, {'secure': false});
    });

    testWidgets('Schlüssel kopieren nur auf Klick', (tester) async {
      final env = TestUmgebung(_server());
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      await tippeText(tester, 'Passwort einrichten');
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-sehr-langes-passwort');
      await eingeben(tester, 'Passwort wiederholen', 'ein-sehr-langes-passwort');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(kanalAufrufe.where((c) => c.method == 'copySensitive'), isEmpty);
      await tippeText(tester, 'Schlüssel kopieren');
      expect(kanalAufrufe.where((c) => c.method == 'copySensitive').single.arguments, isNotNull);
    });

    testWidgets('falscher Code: Meldung der App (nicht des Servers), Eingabe bleibt möglich', (tester) async {
      final server = _server()..on('POST /me/password/complete', (_) => fehler(400, 'invalid_code'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      await tippeText(tester, 'Passwort einrichten');
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-sehr-langes-passwort');
      await eingeben(tester, 'Passwort wiederholen', 'ein-sehr-langes-passwort');
      await tippeText(tester, 'Weiter zum Authenticator');
      await eingeben(tester, 'Code aus der Authenticator-App', '000000');
      await tippeText(tester, 'Bestätigen und einrichten');
      expect(find.text('Der Code stimmt nicht. Prüfe ihn und versuche es noch einmal.'), findsOneWidget);
      expect(find.textContaining('Meldung des Servers'), findsNothing);
      expect(find.text('Bestätigen und einrichten'), findsOneWidget);
    });

    testWidgets('Ändern: Passwort senden, Hinweis', (tester) async {
      final server = _server(password: true);
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      expect(find.text('Passwort und Authenticator sind eingerichtet'), findsOneWidget);
      await tippeText(tester, 'Passwort ändern');
      await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', 'ein-anderes-langes-passwort');
      await eingeben(tester, 'Passwort wiederholen', 'ein-anderes-langes-passwort');
      await tippe(tester, find.widgetWithText(FilledButton, 'Passwort ändern'));
      expect(server.anfragen('POST /me/password/change').single.json, {'password': 'ein-anderes-langes-passwort'});
      expect(find.text('Passwort geändert.'), findsOneWidget);
    });

    testWidgets('Entfernen: Rückfrage, dann Server; danach "Noch nicht eingerichtet"', (tester) async {
      final server = _server(password: true);
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      await tippeText(tester, 'Passwort und Zwei-Faktor entfernen');
      await tippeText(tester, 'Abbrechen');
      expect(server.anfragen('DELETE /me/password'), isEmpty);
      await tippeText(tester, 'Passwort und Zwei-Faktor entfernen');
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(server.anfragen('DELETE /me/password'), hasLength(1));
      expect(find.text('Noch nicht eingerichtet'), findsOneWidget);
    });

    testWidgets('Entfernen ohne Passkey ist gesperrt (Hinweis), Serverfehler last_credential zeigt App-Text', (tester) async {
      final server = _server(password: true, passkeys: 0);
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      final knopf = find.ancestor(of: find.text('Passwort und Zwei-Faktor entfernen'), matching: find.byType(OutlinedButton));
      expect(tester.widget<OutlinedButton>(knopf).onPressed, isNull);
      expect(find.textContaining('Passkey eingerichtet'), findsOneWidget);
    });

    testWidgets('Serverfehler beim Entfernen (409 last_credential): Text der App', (tester) async {
      final server = _server(password: true)..on('DELETE /me/password', (_) => fehler(409, 'last_credential'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      await _zurSeite(tester);
      await tippeText(tester, 'Passwort und Zwei-Faktor entfernen');
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(find.text('Das ist dein letzter Zugang. Lege zuerst einen anderen an.'), findsOneWidget);
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('Layout 360 px, Textskala $skala: Übersicht, Eingabe, Authenticator, Ändern', (tester) async {
        final server = _server();
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await _zurSeite(tester);
        pruefeLayout(tester, 'Passwort Übersicht');
        await tippeText(tester, 'Passwort einrichten');
        pruefeLayout(tester, 'Passwort Eingabe');
        await tippeText(tester, 'Weiter zum Authenticator');
        pruefeLayout(tester, 'Passwort Eingabe mit Fehler');
        await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-sehr-langes-passwort');
        await eingeben(tester, 'Passwort wiederholen', 'ein-sehr-langes-passwort');
        await tippeText(tester, 'Weiter zum Authenticator');
        pruefeLayout(tester, 'Passwort Authenticator');
        await tippeText(tester, 'Bestätigen und einrichten');
        pruefeLayout(tester, 'Passwort Authenticator mit Fehler');
        await eingeben(tester, 'Code aus der Authenticator-App', '654321');
        await tippeText(tester, 'Bestätigen und einrichten');
        pruefeLayout(tester, 'Passwort eingerichtet');
        await tippeText(tester, 'Passwort ändern');
        pruefeLayout(tester, 'Passwort ändern');
      });
    }
  });
}
