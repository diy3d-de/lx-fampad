// Abläufe der Screens gegen den Fake-Server: Anmeldung, Einladung annehmen, Wiederherstellungscodes, Warten auf Freigabe,
// Profil/Sicherheit, Geräte, Passkeys, Admin (Mitglieder, Einladungen) und Step-up.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passkeys/exceptions.dart' as pk;
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/features/auth/invite_intake.dart';
import 'package:lx_fampad/features/auth/qr_anzeige.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _lookupOk = {
  'invite': {
    'role': 'child',
    'pinRequired': false,
    'requireApproval': false,
    'familyName': 'Familie Beispiel',
    'reset': false,
    'expiresAt': '2099-10-19T12:00:00.000Z',
  },
};

/// Routen für die Passkey-Anmeldung.
void _passkeyLogin(FakeServer s) {
  s.json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc', 'rpId': 'familie.lx-labs.dev'}});
  s.json('POST /auth/login/passkey/verify', {'user': userJson(), 'session': appSession()});
  s.json('GET /me', meJson());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Anmeldung', () {
    testWidgets('Passkey-Knopf meldet an und öffnet die App', (tester) async {
      final server = FakeServer();
      _passkeyLogin(server);
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      expect(find.text('Willkommen zurück'), findsOneWidget);
      await tippeText(tester, 'Mit Passkey anmelden');
      expect(env.passkeys.bestaetigt, 1);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('Passkey abgebrochen: freundlicher Hinweis, Weg zu Passwort bleibt', (tester) async {
      final server = FakeServer()..json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc'}});
      final env = TestUmgebung(server);
      env.passkeys.fehler = const PasskeyException(PasskeyFehler.abgebrochen, 'Abgebrochen. Du kannst es erneut versuchen.');
      await starteApp(tester, env);
      await tippeText(tester, 'Mit Passkey anmelden');
      expect(find.textContaining('Abgebrochen'), findsOneWidget);
      expect(find.text('oder mit passwort'.toUpperCase()), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('Kein Passkey-Support: Hinweis mit Weg zu Passwort und Code', (tester) async {
      final env = TestUmgebung(FakeServer());
      env.passkeys.da = false;
      env.passkeys.fehler = const PasskeyException(PasskeyFehler.nichtUnterstuetzt, 'Dieses Gerät oder dieser Browser unterstützt keine Passkeys. Du kannst stattdessen Passwort mit Code nutzen.');
      env.server.json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc'}});
      await starteApp(tester, env);
      expect(find.textContaining('nicht unterstützt'), findsOneWidget);
      await tippeText(tester, 'Mit Passkey anmelden');
      expect(find.textContaining('Passwort mit Code'), findsWidgets);
    });

    testWidgets('Fehlende Google-Dienste: klare Meldung', (tester) async {
      final env = TestUmgebung(FakeServer());
      env.passkeys.fehler = passkeyFehlerAbbilden(pk.MissingGoogleSignInException());
      env.server.json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc'}});
      await starteApp(tester, env);
      await tippeText(tester, 'Mit Passkey anmelden');
      expect(find.textContaining('Google Play-Dienste'), findsOneWidget);
    });

    testWidgets('Passwort in zwei Schritten: erst E-Mail/Passwort, dann Code; Anmeldung sendet alles zusammen', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/login/password', {'user': userJson(), 'session': appSession()})
        ..json('GET /me', meJson());
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await tippeText(tester, 'Weiter');
      expect(find.text('Bitte gib E-Mail und Passwort ein.'), findsOneWidget);

      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Passwort', 'geheimes-passwort');
      await tippeText(tester, 'Weiter');
      expect(find.text('schritt 2 von 2'), findsOneWidget);
      expect(find.text('Bestätigungscode'), findsOneWidget);
      expect(server.anfragen('POST /auth/login/password'), isEmpty, reason: 'erst nach dem Code wird gesendet');

      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      expect(find.text('Bitte gib den 6-stelligen Code ein.'), findsOneWidget);
      await eingeben(tester, 'Code aus der Authenticator-App', '481234');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      final a = server.anfragen('POST /auth/login/password').single.json;
      expect((a['email'], a['password'], a['totp']), ('anna@beispiel.de', 'geheimes-passwort', '481234'));
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('falscher Code: verständliche Meldung statt Servertext, Eingaben bleiben', (tester) async {
      final server = FakeServer()..on('POST /auth/login/password', (_) => fehler(401, 'invalid_credentials', message: 'SERVER-INTERN'));
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Passwort', 'x');
      await tippeText(tester, 'Weiter');
      await eingeben(tester, 'Code aus der Authenticator-App', '000000');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      expect(find.textContaining('Die Anmeldung hat nicht geklappt'), findsOneWidget);
      expect(find.textContaining('SERVER-INTERN'), findsNothing);
      expect(find.text('Bestätigungscode'), findsOneWidget);
    });

    testWidgets('429: Wartehinweis mit Sekunden', (tester) async {
      final server = FakeServer()..on('POST /auth/login/password', (_) => fehler(429, 'too_many_attempts', retryAfter: 30));
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Passwort', 'x');
      await tippeText(tester, 'Weiter');
      await eingeben(tester, 'Code aus der Authenticator-App', '000000');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      expect(find.textContaining('Bitte warte 30 Sekunden'), findsOneWidget);
    });

    testWidgets('503 server_busy: Hinweis auf Auslastung', (tester) async {
      final server = FakeServer()..on('POST /auth/login/password', (_) => fehler(503, 'server_busy', retryAfter: 5));
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Passwort', 'x');
      await tippeText(tester, 'Weiter');
      await eingeben(tester, 'Code aus der Authenticator-App', '000000');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      expect(find.textContaining('ausgelastet'), findsOneWidget);
    });

    testWidgets('Schritt 2: Wiederherstellungscode statt TOTP-Code', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/login/password', {'user': userJson(), 'session': appSession()})
        ..json('GET /me', meJson());
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Passwort', 'pw');
      await tippeText(tester, 'Weiter');
      await tippeText(tester, 'Wiederherstellungscode nutzen');
      await eingeben(tester, 'Wiederherstellungscode', 'AAAA-BBBB-CCCC-DDDD');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      final a = server.anfragen('POST /auth/login/password').single.json;
      expect(a['recoveryCode'], 'AAAA-BBBB-CCCC-DDDD');
      expect(a.containsKey('totp'), isFalse);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('Wiederherstellungscode-Weg ohne Passwort (Konto verloren)', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/login/recovery', {'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 7})
        ..json('GET /me', meJson());
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await tippeText(tester, 'Passwort verloren? Mit Wiederherstellungscode anmelden');
      expect(find.text('Mit Wiederherstellungscode anmelden'), findsOneWidget);
      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Wiederherstellungscode', 'AAAA-BBBB-CCCC-DDDD');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      expect(server.anfragen('POST /auth/login/recovery').single.json['code'], 'AAAA-BBBB-CCCC-DDDD');
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('noch nicht freigegebenes Konto: Warte-Bildschirm', (tester) async {
      final server = FakeServer()..on('POST /auth/login/passkey/verify', (_) => fehler(403, 'account_pending'));
      server.json('POST /auth/login/passkey/options', {'challengeId': 'c-1', 'options': {'challenge': 'abc'}});
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await tippeText(tester, 'Mit Passkey anmelden');
      expect(find.textContaining('Fast geschafft'), findsOneWidget);
      expect(find.text('Zur Anmeldung'), findsOneWidget);
      await tippeText(tester, 'Zur Anmeldung');
      expect(find.text('Willkommen zurück'), findsOneWidget);
    });

    testWidgets('abgelaufene Sitzung beim Start: Hinweis auf der Anmeldeseite', (tester) async {
      final server = FakeServer()..on('GET /me', (_) => fehler(401, 'unauthenticated'));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      expect(find.textContaining('Sitzung ist abgelaufen'), findsOneWidget);
    });
  });

  group('Einladung annehmen', () {
    Future<TestUmgebung> zurEinladung(WidgetTester tester, FakeServer server) async {
      final env = TestUmgebung(server);
      await starteApp(tester, env);
      await tippeText(tester, 'Einladung per QR-Code annehmen');
      return env;
    }

    String link([String t = fixToken]) => 'https://familie.lx-labs.dev/#/einladung/$t';

    testWidgets('ungültiger Link: Hinweis, kein Serveraufruf', (tester) async {
      final server = FakeServer();
      await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', 'https://boese.example/#/einladung/$fixToken');
      await tippeText(tester, 'Einladung prüfen');
      expect(find.textContaining('kein gültiger Einladungslink'), findsOneWidget);
      expect(server.anfragen('POST /auth/invites/lookup'), isEmpty);
    });

    testWidgets('Server lehnt die Einladung ab: eine Meldung für alle Fälle', (tester) async {
      final server = FakeServer()..on('POST /auth/invites/lookup', (_) => fehler(400, 'invite_invalid'));
      await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');
      expect(find.textContaining('ungültig oder abgelaufen'), findsOneWidget);
    });

    testWidgets('Link einfügen: Token geht nur im POST-Body zum Server, nie in der URL', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');
      final r = server.anfragen('POST /auth/invites/lookup').single;
      expect(r.json, {'token': fixToken});
      expect(r.path, isNot(contains(fixToken)));
      expect(find.text('Familie Beispiel'), findsOneWidget);
      expect(find.textContaining(fixToken), findsNothing, reason: 'der Link steht nach der Prüfung nicht mehr im Feld');
    });

    testWidgets('Passkey-Registrierung: Optionen -> Passkey -> Codes (einmalig, Bestätigung nötig) -> App', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', _lookupOk)
        ..json('POST /auth/invites/passkey/options', {'challengeId': 'c-9', 'options': webauthnOptionen()})
        ..json('POST /auth/invites/passkey/complete', {'member': userJson(role: 'child', name: 'Ben'), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()})
        ..json('GET /me', meJson(role: 'child'));
      final env = await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');

      await tippeText(tester, 'Passkey anlegen');
      expect(find.text('Bitte gib deinen Anzeigenamen ein.'), findsOneWidget);
      await eingeben(tester, 'Anzeigename', 'Ben');
      await eingeben(tester, 'E-Mail', 'ben@beispiel.de');
      await tippeText(tester, 'Passkey anlegen');

      final start = server.anfragen('POST /auth/invites/passkey/options').single.json;
      expect(start, {'token': fixToken, 'email': 'ben@beispiel.de', 'displayName': 'Ben'});
      expect(env.passkeys.erstellt, 1);
      expect(env.passkeys.letzteOptionen!['rp'], {'name': 'lx-familyhub', 'id': 'familie.lx-labs.dev'});
      final fertig = server.anfragen('POST /auth/invites/passkey/complete').single.json;
      expect(fertig['challengeId'], 'c-9');
      expect(fertig['client'], 'app');
      expect((fertig['device'] as Map)['platform'], 'android');
      expect(fertig['label'], 'Pixel 9');

      // Codes werden angezeigt, die Sitzung ist noch NICHT übernommen
      expect(find.text('Wiederherstellungscodes'), findsOneWidget);
      for (final c in codes()) {
        expect(find.text(c), findsOneWidget);
      }
      expect(find.byType(NavigationBar), findsNothing);
      expect(await env.store.readTokens(), isNull);
      // FLAG_SECURE ist an, solange die Codes sichtbar sind
      expect(kanalAufrufe.where((c) => c.method == 'setSecure').last.arguments, {'secure': true});

      // Weiter erst nach Bestätigung
      final weiter = find.widgetWithText(FilledButton, 'Weiter zur App');
      expect(tester.widget<FilledButton>(weiter).onPressed, isNull);
      await tippeText(tester, 'Ich habe die Codes sicher gespeichert.');
      expect(tester.widget<FilledButton>(weiter).onPressed, isNotNull);
      await tippe(tester, weiter);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(await env.store.readTokens(), isNotNull);
      expect(kanalAufrufe.where((c) => c.method == 'setSecure').last.arguments, {'secure': false});
    });

    testWidgets('Codes werden nicht automatisch kopiert, erst auf Klick', (tester) async {
      final zwischenablage = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') zwischenablage.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', _lookupOk)
        ..json('POST /auth/invites/passkey/options', {'challengeId': 'c-9', 'options': webauthnOptionen()})
        ..json('POST /auth/invites/passkey/complete', {'member': userJson(), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()})
        ..json('GET /me', meJson());
      await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');
      await eingeben(tester, 'Anzeigename', 'Ben');
      await eingeben(tester, 'E-Mail', 'ben@beispiel.de');
      await tippeText(tester, 'Passkey anlegen');
      expect(zwischenablage, isEmpty);
      await tippeText(tester, 'Alle Codes kopieren');
      expect(zwischenablage.single, codes().join('\n'));
    });

    testWidgets('Einladung mit Freigabe und PIN: pending -> Warte-Bildschirm, keine Token', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', {
          'invite': {..._lookupOk['invite']! as Map<String, dynamic>, 'role': 'child', 'pinRequired': true, 'requireApproval': true},
        })
        ..json('POST /auth/invites/passkey/options', {'challengeId': 'c-9', 'options': webauthnOptionen()})
        ..json('POST /auth/invites/passkey/complete', {'member': userJson(role: 'child', status: 'pending', name: 'Oma'), 'status': 'pending', 'recoveryCodes': codes()});
      final env = await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');
      expect(find.textContaining('gibt ein Admin dein Konto frei'), findsOneWidget);
      await eingeben(tester, 'Anzeigename', 'Oma');
      await eingeben(tester, 'E-Mail', 'oma@beispiel.de');
      await tippeText(tester, 'Passkey anlegen');
      expect(find.text('Bitte gib die 6-stellige PIN ein, die du getrennt zur Einladung bekommen hast.'), findsOneWidget);
      await eingeben(tester, 'PIN der Einladung', '654321');
      await tippeText(tester, 'Passkey anlegen');
      expect(server.anfragen('POST /auth/invites/passkey/options').single.json['pin'], '654321');
      await tippeText(tester, 'Ich habe die Codes sicher gespeichert.');
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(find.textContaining('Fast geschafft, Oma'), findsOneWidget);
      expect(await env.store.readTokens(), isNull);
    });

    testWidgets('Passkey nicht möglich: Meldung, Passwort + TOTP als Ausweg (Secret, QR, Bestätigung)', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', _lookupOk)
        ..json('POST /auth/invites/passkey/options', {'challengeId': 'c-9', 'options': webauthnOptionen()})
        ..json('POST /auth/invites/password/start', {
          'challengeId': 'c-10',
          'totpSecret': 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
          'totpUri': 'otpauth://totp/lx-familyhub:ben%40beispiel.de?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=lx-familyhub',
        });
      final env = await zurEinladung(tester, server);
      env.passkeys.fehler = const PasskeyException(PasskeyFehler.nichtUnterstuetzt, 'Dieses Gerät oder dieser Browser unterstützt keine Passkeys. Du kannst stattdessen Passwort mit Code nutzen.');
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');
      await eingeben(tester, 'Anzeigename', 'Ben');
      await eingeben(tester, 'E-Mail', 'ben@beispiel.de');
      await tippeText(tester, 'Passkey anlegen');
      expect(find.textContaining('unterstützt keine Passkeys'), findsOneWidget);

      await tippeText(tester, 'Passwort');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(find.text('Das Passwort braucht mindestens 12 Zeichen.'), findsOneWidget);
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'kurz');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(find.text('Das Passwort braucht mindestens 12 Zeichen.'), findsOneWidget);
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-langes-passwort-1');
      await eingeben(tester, 'Passwort wiederholen', 'ein-anderes-passwort');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(find.text('Die beiden Passwörter sind nicht gleich.'), findsOneWidget);
      await eingeben(tester, 'Passwort wiederholen', 'ein-langes-passwort-1');
      await tippeText(tester, 'Weiter zum Authenticator');

      final start = server.anfragen('POST /auth/invites/password/start').single.json;
      expect(start['password'], 'ein-langes-passwort-1');
      expect(start['email'], 'ben@beispiel.de');
      // Secret in Gruppen und QR-Code des otpauth-URI
      expect(find.text('JBSW Y3DP EHPK 3PXP JBSW Y3DP EHPK 3PXP'), findsOneWidget);
      expect(tester.widget<QrAnzeige>(find.byType(QrAnzeige)).daten, startsWith('otpauth://totp/'));
      expect(kanalAufrufe.where((c) => c.method == 'setSecure').last.arguments, {'secure': true});

      // falscher Code
      server.on('POST /auth/invites/password/complete', (_) => fehler(400, 'invalid_code'));
      await eingeben(tester, 'Code aus der Authenticator-App', '111111');
      await tippeText(tester, 'Bestätigen und Konto anlegen');
      expect(find.textContaining('Der Code stimmt nicht'), findsOneWidget);

      // richtiger Code
      server
        ..json('POST /auth/invites/password/complete', {'member': userJson(), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()})
        ..json('GET /me', meJson());
      await eingeben(tester, 'Code aus der Authenticator-App', '222222');
      await tippeText(tester, 'Bestätigen und Konto anlegen');
      expect(server.anfragen('POST /auth/invites/password/complete').last.json['code'], '222222');
      expect(find.text('Wiederherstellungscodes'), findsOneWidget);
    });

    testWidgets('Einladung zum Zurücksetzen: weder Name noch E-Mail abgefragt', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', {
          'invite': {..._lookupOk['invite']! as Map<String, dynamic>, 'reset': true, 'displayName': 'Ben'},
        })
        ..json('POST /auth/invites/passkey/options', {'challengeId': 'c-9', 'options': webauthnOptionen()})
        ..json('POST /auth/invites/passkey/complete', {'member': userJson(), 'status': 'active', 'recoveryCodes': codes(), 'session': appSession()});
      await zurEinladung(tester, server);
      await eingeben(tester, 'Einladungslink', link());
      await tippeText(tester, 'Einladung prüfen');
      expect(find.widgetWithText(TextField, 'E-Mail'), findsNothing);
      expect(find.widgetWithText(TextField, 'Anzeigename'), findsNothing);
      expect(find.textContaining('Neuer Zugang für Ben'), findsOneWidget);
      await tippeText(tester, 'Passkey anlegen');
      expect(server.anfragen('POST /auth/invites/passkey/options').single.json, {'token': fixToken});
    });

    testWidgets('Link von außen (Intent): öffnet die Einladung direkt mit dem Token', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      final env = TestUmgebung(server);
      final container = await starteApp(tester, env);
      container.read(inviteIntakeProvider.notifier).eingegangen(fixToken);
      await warte(tester);
      expect(server.anfragen('POST /auth/invites/lookup').single.json, {'token': fixToken});
      expect(find.text('Familie Beispiel'), findsOneWidget);
      expect(container.read(inviteIntakeProvider), isNull, reason: 'Token ist verbraucht');
    });

    testWidgets('Ungültiger Link von außen: Hinweis statt Absturz', (tester) async {
      final env = TestUmgebung(FakeServer());
      final container = await starteApp(tester, env);
      container.read(inviteIntakeProvider.notifier).eingegangen(null);
      await warte(tester);
      expect(find.text('Der Einladungslink ist ungültig.'), findsOneWidget);
    });

    testWidgets('Angemeldet und Link eingegangen: keine Einladung, freundlicher Hinweis', (tester) async {
      final env = await angemeldeteUmgebung();
      final container = await starteApp(tester, env);
      container.read(inviteIntakeProvider.notifier).eingegangen(fixToken);
      await warte(tester);
      expect(find.textContaining('Du bist schon angemeldet'), findsOneWidget);
      expect(env.server.anfragen('POST /auth/invites/lookup'), isEmpty);
    });
  });

  group('Profil, Geräte, Passkeys', () {
    Future<TestUmgebung> zumProfil(WidgetTester tester, {String role = 'admin', FakeServer? server}) async {
      final env = await angemeldeteUmgebung(role: role, server: server);
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      return env;
    }

    testWidgets('zeigt Name, Rolle, Zugänge und Codes', (tester) async {
      await zumProfil(tester);
      expect(find.text('Profil & Sicherheit'), findsOneWidget);
      expect(find.text('Anna'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('1 aktiv'), findsOneWidget);
      expect(find.textContaining('8 übrig'), findsOneWidget);
    });

    testWidgets('Abmelden: Rückfrage, Token und lokale Daten weg, Anmeldeseite', (tester) async {
      final server = standardServer()..json('POST /auth/logout', {'ok': true});
      final env = await zumProfil(tester, server: server);
      await tippeText(tester, 'Abmelden');
      expect(find.text('Abmelden?'), findsOneWidget);
      await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
      expect(server.anfragen('POST /auth/logout'), hasLength(1));
      expect(await env.store.readTokens(), isNull);
      expect(env.geloescht, 1);
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(find.text('Profil & Sicherheit'), findsNothing, reason: 'Unterseiten sind geschlossen');
    });

    testWidgets('Überall abmelden ruft logout-all', (tester) async {
      final server = standardServer()..json('POST /auth/logout-all', {'ok': true});
      final env = await zumProfil(tester, server: server);
      await tippeText(tester, 'Überall abmelden');
      await tippe(tester, find.widgetWithText(TextButton, 'Überall abmelden'));
      expect(server.anfragen('POST /auth/logout-all'), hasLength(1));
      expect(env.geloescht, 1);
      expect(find.text('Willkommen zurück'), findsOneWidget);
    });

    testWidgets('Geräteliste: eigenes Gerät markiert, anderes Gerät einzeln abmelden', (tester) async {
      final server = standardServer()..json('DELETE /devices/dddddddd-0000-4000-8000-000000000002', {'ok': true});
      await zumProfil(tester, server: server);
      await tippeText(tester, 'Angemeldete Geräte');
      expect(find.text('Pixel 9'), findsOneWidget);
      expect(find.text('dieses gerät'), findsOneWidget);
      await tippe(tester, find.byTooltip('Firefox auf Windows abmelden'));
      await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
      expect(server.anfragen('DELETE /devices/dddddddd-0000-4000-8000-000000000002'), hasLength(1));
    });

    testWidgets('Neue Wiederherstellungscodes: Rückfrage, Step-up per Code, einmalige Anzeige', (tester) async {
      var versuche = 0;
      final server = standardServer()
        ..on('POST /me/recovery-codes', (_) {
          versuche++;
          return versuche == 1 ? fehler(403, 'step_up_required') : jsonAntwort({'recoveryCodes': codes()});
        })
        ..json('POST /auth/step-up/code', {'stepUpAt': DateTime.now().toUtc().toIso8601String()});
      await zumProfil(tester, server: server);
      await tippeText(tester, 'Wiederherstellungscodes');
      expect(find.text('Neue Wiederherstellungscodes?'), findsOneWidget);
      await tippe(tester, find.widgetWithText(TextButton, 'Neue Codes erzeugen'));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await eingeben(tester, 'Code aus der Authenticator-App', '123456');
      await tippeText(tester, 'Mit Code bestätigen');
      expect(server.anfragen('POST /auth/step-up/code').single.json, {'totp': '123456'});
      expect(versuche, 2);
      expect(find.text('Wiederherstellungscodes'), findsOneWidget);
      expect(find.text(codes().first), findsOneWidget);
    });

    testWidgets('Passkeys: Liste, hinzufügen mit Step-up per Passkey, entfernen', (tester) async {
      var optionen = 0;
      final server = standardServer()
        ..on('POST /me/passkeys/options', (_) {
          optionen++;
          return optionen == 1 ? fehler(403, 'step_up_required') : jsonAntwort({'challengeId': 'c-5', 'options': webauthnOptionen()});
        })
        ..json('POST /auth/step-up/passkey/options', {'challengeId': 'c-6', 'options': {'challenge': 'abc', 'rpId': 'familie.lx-labs.dev'}})
        ..json('POST /auth/step-up/passkey/verify', {'stepUpAt': DateTime.now().toUtc().toIso8601String()})
        ..json('POST /me/passkeys/verify', {'id': 'c2'})
        ..json('DELETE /me/passkeys/c1', {'ok': true});
      final env = await zumProfil(tester, server: server);
      await tippeText(tester, 'Passkeys');
      expect(find.text('Pixel 9'), findsOneWidget);

      await tippeText(tester, 'Passkey hinzufügen');
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await tippeText(tester, 'Mit Passkey bestätigen');
      expect(env.passkeys.bestaetigt, 1);
      expect(env.passkeys.erstellt, 1);
      expect(server.anfragen('POST /me/passkeys/verify').single.json['challengeId'], 'c-5');
      expect(server.anfragen('POST /me/passkeys/verify').single.json['label'], 'Pixel 9');

      await tippe(tester, find.byTooltip('Passkey Pixel 9 entfernen'));
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(server.anfragen('DELETE /me/passkeys/c1'), hasLength(1));
    });

    testWidgets('letzter Zugang: Server lehnt ab, Meldung ohne Interna', (tester) async {
      final server = standardServer()..on('DELETE /me/passkeys/c1', (_) => fehler(409, 'last_credential'));
      await zumProfil(tester, server: server);
      await tippeText(tester, 'Passkeys');
      await tippe(tester, find.byTooltip('Passkey Pixel 9 entfernen'));
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(find.textContaining('letzter Zugang'), findsOneWidget);
    });

    testWidgets('Step-up abgebrochen: Aktion wird nicht ausgeführt', (tester) async {
      final server = standardServer()..on('POST /me/recovery-codes', (_) => fehler(403, 'step_up_required'));
      await zumProfil(tester, server: server);
      await tippeText(tester, 'Wiederherstellungscodes');
      await tippe(tester, find.widgetWithText(TextButton, 'Neue Codes erzeugen'));
      await tippeText(tester, 'Abbrechen');
      expect(server.anfragen('POST /me/recovery-codes'), hasLength(1));
      expect(find.text('Profil & Sicherheit'), findsOneWidget);
    });
  });

  group('Admin', () {
    Future<TestUmgebung> zumAdmin(WidgetTester tester, {String role = 'admin', FakeServer? server}) async {
      final env = await angemeldeteUmgebung(role: role, server: server);
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text(role == 'admin' ? 'Mitglieder und Einladungen' : 'Einladungen'));
      return env;
    }

    testWidgets('Mitglieder: Liste mit Rollen, wartende getrennt, eigener Eintrag ohne Aktionen', (tester) async {
      await zumAdmin(tester);
      expect(find.text('Anna (du)'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Oma'), findsOneWidget);
      expect(find.text('// wartet auf freigabe'.toUpperCase()), findsOneWidget);
      expect(find.byTooltip('Aktionen für Anna'), findsNothing);
      expect(find.byTooltip('Aktionen für Ben'), findsOneWidget);
    });

    testWidgets('Freigeben und Ablehnen', (tester) async {
      final server = standardServer()
        ..json('POST /members/22222222-3333-4444-8555-666666666666/approve', {'ok': true})
        ..json('POST /members/22222222-3333-4444-8555-666666666666/reject', {'ok': true});
      await zumAdmin(tester, server: server);
      await tippe(tester, find.byTooltip('Aktionen für Oma'));
      await tippeText(tester, 'Freigeben');
      expect(server.anfragen('POST /members/22222222-3333-4444-8555-666666666666/approve'), hasLength(1));
      await tippe(tester, find.byTooltip('Aktionen für Oma'));
      await tippeText(tester, 'Ablehnen');
      await tippe(tester, find.widgetWithText(TextButton, 'Ablehnen'));
      expect(server.anfragen('POST /members/22222222-3333-4444-8555-666666666666/reject'), hasLength(1));
    });

    testWidgets('Rolle ändern verlangt Step-up: Dialog, Code, danach wird wiederholt', (tester) async {
      var patch = 0;
      final server = standardServer()
        ..on('PATCH /members/$fixIdKind/role', (r) {
          patch++;
          return patch == 1 ? fehler(403, 'step_up_required') : jsonAntwort({'ok': true});
        })
        ..json('POST /auth/step-up/code', {'stepUpAt': DateTime.now().toUtc().toIso8601String()});
      await zumAdmin(tester, server: server);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Rolle ändern');
      await tippe(tester, find.descendant(of: find.byType(SimpleDialog), matching: find.text('Elternteil')));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await eingeben(tester, 'Code aus der Authenticator-App', '654321');
      await tippeText(tester, 'Mit Code bestätigen');
      expect(server.anfragen('PATCH /members/$fixIdKind/role').map((r) => r.json), [
        {'role': 'parent'},
        {'role': 'parent'},
      ]);
      expect(find.text('Rolle geändert.'), findsOneWidget);
    });

    testWidgets('Mitglied entfernen: Rückfrage, DELETE', (tester) async {
      final server = standardServer()..json('DELETE /members/$fixIdKind', {'ok': true});
      await zumAdmin(tester, server: server);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Entfernen');
      expect(find.text('Mitglied entfernen?'), findsOneWidget);
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(server.anfragen('DELETE /members/$fixIdKind'), hasLength(1));
    });

    testWidgets('Zurücksetzen: Gültigkeit und PIN wählen, Ergebnis mit QR, Link und PIN', (tester) async {
      final server = standardServer()..json('POST /members/$fixIdKind/reset', neueEinladungJson());
      await zumAdmin(tester, server: server);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Zugang zurücksetzen');
      await tippeText(tester, '3 Tage');
      await tippe(tester, find.byType(Switch));
      await tippe(tester, find.widgetWithText(TextButton, 'Zurücksetzen'));
      expect(server.anfragen('POST /members/$fixIdKind/reset').single.json, {'hours': 72, 'pin': true});
      expect(find.text('Zurücksetzen für Ben'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('123456'), findsOneWidget);
    });

    testWidgets('Einladungen: Liste, erstellen (Elternteil mit PIN und Freigabe), QR + Link + PIN nur einmal, Zwischenablage nur auf Klick', (tester) async {
      final zwischenablage = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') zwischenablage.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final server = standardServer()..json('POST /invites', neueEinladungJson());
      await zumAdmin(tester, server: server);
      await tippeText(tester, 'Einladungen');
      expect(find.text('// einladungen (3)'.toUpperCase()), findsOneWidget);

      await tippeText(tester, 'Neue Einladung');
      await tippe(tester, find.widgetWithText(ChoiceChip, 'Elternteil'));
      await tippe(tester, find.widgetWithText(ChoiceChip, '6 Stunden'));
      await tippe(tester, find.widgetWithText(SwitchListTile, 'PIN verlangen'));
      await tippe(tester, find.widgetWithText(SwitchListTile, 'Freigabe durch Admin'));
      await tippeText(tester, 'Einladung erstellen');
      final body = server.anfragen('POST /invites').single.json;
      expect(body, {'role': 'parent', 'hours': 6, 'pin': true, 'requireApproval': true});

      expect(find.text('Einladung erstellt'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(tester.widget<QrAnzeige>(find.byType(QrAnzeige)).daten, 'https://familie.lx-labs.dev/#/einladung/$fixToken');
      expect(find.text('123456'), findsOneWidget);
      expect(zwischenablage, isEmpty);
      await tippeText(tester, 'Link kopieren');
      expect(zwischenablage.single, 'https://familie.lx-labs.dev/#/einladung/$fixToken');
      await tester.pump(const Duration(seconds: 5)); // Hinweis "Link kopiert" verschwindet
      await tester.pump(const Duration(seconds: 1));
      await tippeText(tester, 'Fertig');
      expect(find.text('Neue Einladung'), findsOneWidget);
    });

    testWidgets('Admin-Einladung verlangt Step-up', (tester) async {
      var n = 0;
      final server = standardServer()
        ..on('POST /invites', (_) => ++n == 1 ? fehler(403, 'step_up_required') : jsonAntwort(neueEinladungJson(pin: false)))
        ..json('POST /auth/step-up/code', {'stepUpAt': DateTime.now().toUtc().toIso8601String()});
      await zumAdmin(tester, server: server);
      await tippeText(tester, 'Einladungen');
      await tippeText(tester, 'Neue Einladung');
      await tippe(tester, find.widgetWithText(ChoiceChip, 'Admin'));
      expect(find.textContaining('musst du dich noch einmal bestätigen'), findsOneWidget);
      await tippeText(tester, 'Einladung erstellen');
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await eingeben(tester, 'Code aus der Authenticator-App', '123456');
      await tippeText(tester, 'Mit Code bestätigen');
      expect(find.text('Einladung erstellt'), findsOneWidget);
    });

    testWidgets('Einladung widerrufen und verlängern', (tester) async {
      final server = standardServer()
        ..json('POST /invites/i1/revoke', {'ok': true})
        ..json('POST /invites/i2/extend', {'expiresAt': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String()});
      await zumAdmin(tester, server: server);
      await tippeText(tester, 'Einladungen');
      await tippe(tester, find.byTooltip('Aktionen für die Kind-Einladung'));
      await tippeText(tester, 'Widerrufen');
      await tippe(tester, find.widgetWithText(TextButton, 'Widerrufen'));
      expect(server.anfragen('POST /invites/i1/revoke'), hasLength(1));

      await tippe(tester, find.byTooltip('Aktionen für die Elternteil-Einladung'));
      await tippeText(tester, 'Verlängern');
      await tippeText(tester, 'Noch 3 Tage gültig');
      expect(server.anfragen('POST /invites/i2/extend').single.json, {'hours': 72});
    });

    testWidgets('Eltern: nur Einladungen für Kinder (kein Gast), keine Mitglieder-Verwaltung', (tester) async {
      final server = standardServer(role: 'parent');
      await zumAdmin(tester, role: 'parent', server: server);
      expect(find.byType(TabBar), findsNothing);
      expect(server.anfragen('GET /members'), isEmpty);
      await tippeText(tester, 'Neue Einladung');
      expect(find.widgetWithText(ChoiceChip, 'Kind'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Gast'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Admin'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Elternteil'), findsNothing);
      // Freigabe nur auf Wunsch: ohne Schalter wird sie nicht gesendet
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Freigabe durch Admin')).value, isFalse);
      await tippeText(tester, 'Einladung erstellen');
      expect(server.anfragen('POST /invites').single.json, {'role': 'child', 'hours': 24, 'pin': false});
    });

    testWidgets('Kinder sehen keinen Bereich "Familie"', (tester) async {
      final env = await angemeldeteUmgebung(role: 'child');
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      expect(find.text('Mitglieder und Einladungen'), findsNothing);
      expect(find.text('Einladungen'), findsNothing);
    });
  });
}
