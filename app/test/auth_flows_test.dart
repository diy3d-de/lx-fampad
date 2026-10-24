// Abläufe der Überarbeitung nach Review (Phase 1b): Einladungslinks von außen, Abmelden mit Serverfehler, Passkey-Abbruch,
// Step-up-Dialog, Neuladen nach Erfolg, Passwortmanager-Gruppen, lange Überschriften, vertrauliche Zwischenablage.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart' show schluesselSpeicherProvider;
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart' show MemorySchluesselSpeicher;
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/features/auth/invite_intake.dart';
import 'package:lx_fampad/features/auth/invite_screen.dart';
import 'package:lx_fampad/features/auth/recovery_codes_screen.dart';
import 'package:lx_fampad/ui/theme.dart';

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

/// Simuliert einen Aufruf der Android-Seite an die App (MainActivity -> Dart), z. B. einen Einladungslink.
Future<void> _vonAndroid(WidgetTester tester, String methode, Object? argument) async {
  final daten = const StandardMethodCodec().encodeMethodCall(MethodCall(methode, argument));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(kSystemChannel, daten, (_) {});
  await warte(tester);
}

/// Simuliert die Meldung der Web-Engine, wenn der Browser einen neuen Pfad meldet (popstate nach dem Einfügen eines Links).
Future<void> _browserPfad(WidgetTester tester, String pfad) async {
  final daten = const JSONMethodCodec().encodeMethodCall(MethodCall('pushRouteInformation', {'location': pfad, 'state': null}));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/navigation', daten, (_) {});
  await warte(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Einladungslink von außen', () {
    testWidgets('Link ohne Einladungs-Fragment (z. B. nur die Startseite) wird ignoriert: kein Hinweis, keine Einladung', (tester) async {
      final server = FakeServer();
      await starteApp(tester, TestUmgebung(server));
      await _vonAndroid(tester, 'link', 'https://familyhub.lx-labs.dev/');
      expect(find.textContaining('ungültig'), findsNothing);
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(server.anfragen('POST /auth/invites/lookup'), isEmpty);
    });

    testWidgets('Link mit Einladungs-Fragment öffnet die Einladung', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      await starteApp(tester, TestUmgebung(server));
      await _vonAndroid(tester, 'link', 'https://familyhub.lx-labs.dev/#/einladung/$fixToken');
      expect(server.anfragen('POST /auth/invites/lookup').single.json, {'token': fixToken});
      expect(find.text('Familie Beispiel'), findsOneWidget);
    });

    testWidgets('Einladungs-Fragment mit kaputtem Token: Hinweis "ungültig"', (tester) async {
      await starteApp(tester, TestUmgebung(FakeServer()));
      await _vonAndroid(tester, 'link', 'https://familyhub.lx-labs.dev/#/einladung/zu-kurz');
      expect(find.text('Der Einladungslink ist ungültig.'), findsOneWidget);
    });

    testWidgets('Konto wartet auf Freigabe: die Einladung öffnet sich, KEIN "Du bist schon angemeldet"', (tester) async {
      final server = FakeServer()
        ..json('GET /me', meJson(role: 'child', status: 'pending'))
        ..json('POST /auth/invites/lookup', _lookupOk);
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env);
      expect(find.textContaining('Fast geschafft'), findsOneWidget);
      await _vonAndroid(tester, 'link', 'https://familyhub.lx-labs.dev/#/einladung/$fixToken');
      expect(find.textContaining('Du bist schon angemeldet'), findsNothing);
      expect(find.text('Familie Beispiel'), findsOneWidget);
    });

    testWidgets('Pfadmeldung des Browsers (Link wurde schon aus der Adresszeile entfernt): Token geht in den Speicher, es entsteht keine Route mit Namen', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      await starteApp(tester, TestUmgebung(server));
      await _browserPfad(tester, '/einladung/$fixToken');
      expect(tester.takeException(), isNull);
      expect(find.byType(InviteScreen), findsOneWidget);
      expect(server.anfragen('POST /auth/invites/lookup').single.json, {'token': fixToken});
      // keine benannte Route: der Navigator kennt das Token nicht
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      var gesehen = <String?>[];
      navigator.popUntil((r) {
        gesehen.add(r.settings.name);
        return true;
      });
      expect(gesehen.every((n) => n == null || !n.contains(fixToken)), isTrue);
    });

    testWidgets('Dieselbe Meldung zweimal (Adresszeile und Browser-Route): die Einladung wird nur einmal geöffnet', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      final container = await starteApp(tester, TestUmgebung(server));
      container.read(inviteIntakeProvider.notifier).eingegangen(fixToken); // hashchange/popstate-Listener
      await _browserPfad(tester, '/einladung/$fixToken'); // Routenmeldung derselben Eingabe
      expect(find.byType(InviteScreen), findsOneWidget);
      expect(server.anfragen('POST /auth/invites/lookup'), hasLength(1));
    });

    testWidgets('Anderer Pfad des Browsers: keine Route, kein Absturz', (tester) async {
      await starteApp(tester, TestUmgebung(FakeServer()));
      await _browserPfad(tester, '/irgendwas/anderes');
      expect(tester.takeException(), isNull);
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(find.byType(InviteScreen), findsNothing);
    });

    testWidgets('Zwei Einladungen hintereinander: die zweite ersetzt die erste, nichts bleibt hängen', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      final container = await starteApp(tester, TestUmgebung(server));
      container.read(inviteIntakeProvider.notifier).eingegangen(fixToken);
      await warte(tester);
      expect(find.byType(InviteScreen), findsOneWidget);
      container.read(inviteIntakeProvider.notifier).eingegangen('${fixToken}x');
      await warte(tester);
      expect(find.byType(InviteScreen), findsOneWidget);
      expect(server.anfragen('POST /auth/invites/lookup'), hasLength(2));
    });
  });

  group('Abmelden in der Oberfläche', () {
    Future<void> zumProfil(WidgetTester tester, TestUmgebung env) async {
      // Schlüsselspeicher im Arbeitsspeicher und leer: kein Personenschlüssel, also die einfache Rückfrage beim Abmelden
      env.extraOverrides.add(schluesselSpeicherProvider.overrideWithValue(MemorySchluesselSpeicher()));
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    }

    testWidgets('Web, Serverfehler: bleibt angemeldet, Fehler + "Erneut versuchen" + "Trotzdem nur lokal abmelden" mit Warnung', (tester) async {
      var kaputt = true;
      final server = standardServer()
        ..json('GET /me', meJson(csrf: 'csrf-1', passkeys: 1, password: true, totp: true))
        ..on('POST /auth/logout', (_) => kaputt ? fehler(500, 'internal_error') : jsonAntwort({'ok': true}));
      final env = TestUmgebung(server, web: true);
      await zumProfil(tester, env);
      await tippeText(tester, 'Abmelden');
      await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
      expect(find.text('Profil'), findsOneWidget, reason: 'nicht als abgemeldet anzeigen');
      expect(find.textContaining('Du bist noch angemeldet'), findsOneWidget);
      expect(find.textContaining('bis zum Ablauf gültig'), findsOneWidget);
      expect(env.geloescht, 0);

      kaputt = false;
      await tippeText(tester, 'Erneut versuchen');
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(env.geloescht, 1);
    });

    testWidgets('Web, Serverfehler: "Trotzdem nur lokal abmelden" ruft den Server nicht erneut', (tester) async {
      final server = standardServer()
        ..json('GET /me', meJson(csrf: 'csrf-1', passkeys: 1, password: true, totp: true))
        ..on('POST /auth/logout', (_) async => throw TimeoutException('t'));
      final env = TestUmgebung(server, web: true);
      await zumProfil(tester, env);
      await tippeText(tester, 'Abmelden');
      await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
      await tippeText(tester, 'Trotzdem nur lokal abmelden');
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(server.anfragen('POST /auth/logout'), hasLength(1));
      expect(env.geloescht, 1);
    });

    testWidgets('Android, offline: abgemeldet, Person wird informiert (Sitzung bleibt auf dem Server gültig)', (tester) async {
      final server = standardServer()..on('POST /auth/logout', (_) async => throw TimeoutException('t'));
      final env = await angemeldeteUmgebung(server: server);
      await zumProfil(tester, env);
      await tippeText(tester, 'Abmelden');
      await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(find.textContaining('nur auf diesem Gerät abgemeldet'), findsOneWidget);
      expect(await env.store.readTokens(), isNull);
      expect(env.geloescht, 1);
    });

    testWidgets('Wiper wirft: trotzdem abgemeldet, Hinweis auf nicht gelöschte Daten', (tester) async {
      final server = standardServer()..json('POST /auth/logout', {'ok': true});
      final env = await angemeldeteUmgebung(server: server);
      env.wiperFehler = true;
      await zumProfil(tester, env);
      await tippeText(tester, 'Abmelden');
      await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(find.textContaining('nicht vollständig gelöscht'), findsOneWidget);
    });
  });

  group('Passkey-Abbruch und Step-up', () {
    testWidgets('Step-up: Passkey-Dialog abgebrochen ist kein roter Fehler, nur ein Hinweis', (tester) async {
      final server = standardServer()..on('POST /me/recovery-codes', (_) => fehler(403, 'step_up_required'))..json('POST /auth/step-up/passkey/options', {'challengeId': 'c-6', 'options': {'challenge': 'abc'}});
      final env = await angemeldeteUmgebung(server: server);
      env.passkeys.fehler = const PasskeyException(PasskeyFehler.abgebrochen, 'Abgebrochen. Du kannst es erneut versuchen.');
      await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Wiederherstellungscodes');
      await tippe(tester, find.widgetWithText(TextButton, 'Neue Codes erzeugen'));
      await tippeText(tester, 'Mit Passkey bestätigen');
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing, reason: 'kein roter Fehlerkasten');
      expect(find.textContaining('Abgebrochen'), findsOneWidget);
    });

    testWidgets('Step-up-Dialog lässt sich nicht per Tipp neben den Dialog schließen', (tester) async {
      final server = standardServer()..on('POST /me/recovery-codes', (_) => fehler(403, 'step_up_required'));
      await starteApp(tester, await angemeldeteUmgebung(server: server));
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Wiederherstellungscodes');
      await tippe(tester, find.widgetWithText(TextButton, 'Neue Codes erzeugen'));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await warte(tester);
      expect(find.text('Bitte bestätigen'), findsOneWidget, reason: 'barrierDismissible ist aus');
      await tippeText(tester, 'Abbrechen');
      expect(find.text('Bitte bestätigen'), findsNothing);
    });

    testWidgets('Step-up-Dialog: Zurück-Taste ist gesperrt, solange der Passkey-Dialog läuft', (tester) async {
      final laeuft = Completer<void>();
      final server = standardServer()
        ..on('POST /me/recovery-codes', (_) => fehler(403, 'step_up_required'))
        ..on('POST /auth/step-up/passkey/options', (_) async {
          await laeuft.future;
          return jsonAntwort({'challengeId': 'c-6', 'options': {'challenge': 'abc'}});
        });
      await starteApp(tester, await angemeldeteUmgebung(server: server));
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Wiederherstellungscodes');
      await tippe(tester, find.widgetWithText(TextButton, 'Neue Codes erzeugen'));
      await tester.tap(find.text('Mit Passkey bestätigen').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.binding.handlePopRoute();
      await warte(tester);
      expect(find.text('Bitte bestätigen'), findsOneWidget, reason: 'während die Aktion läuft, schließt Zurück den Dialog nicht');
      laeuft.complete();
      await warte(tester);
    });
  });

  group('Neuladen nach Erfolg', () {
    testWidgets('Einladung erstellt, aber die Liste lässt sich nicht neu laden: kein Fehlerkasten, nur Hinweis', (tester) async {
      var listeKaputt = false;
      final server = standardServer()
        ..on('GET /invites', (_) => listeKaputt ? fehler(500, 'internal_error') : jsonAntwort({'invites': [einladungJson()]}))
        ..json('POST /invites', neueEinladungJson());
      await starteApp(tester, await angemeldeteUmgebung(server: server));
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      await tippeText(tester, 'Einladungen');
      await tippeText(tester, 'Neue Einladung');
      await tippeText(tester, 'Einladung erstellen');
      expect(find.text('Einladung erstellt'), findsOneWidget);
      listeKaputt = true;
      await tippeText(tester, 'Fertig');
      expect(find.textContaining('Auf dem Server ist ein Fehler'), findsNothing, reason: 'die Einladung wurde erstellt');
      expect(find.textContaining('Die Liste konnte nicht aktualisiert werden'), findsOneWidget);
      expect(server.anfragen('POST /invites'), hasLength(1));
    });

    testWidgets('Mitglied entfernt, Liste lässt sich nicht neu laden: Erfolg bleibt Erfolg', (tester) async {
      var listeKaputt = false;
      final basis = standardServer();
      final server = FakeServer()
        ..routes.addAll(basis.routes)
        ..on('GET /members', (_) => listeKaputt ? fehler(503, 'server_busy') : basis.routes['GET /members']!(Req('GET', '/members', {}, null)))
        ..json('DELETE /members/$fixIdKind', {'ok': true});
      await starteApp(tester, await angemeldeteUmgebung(server: server));
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      listeKaputt = true;
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Entfernen');
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(find.textContaining('Mitglied entfernt.'), findsOneWidget);
      expect(find.textContaining('Die Liste konnte nicht aktualisiert werden'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('Liste mit unbekannter Rolle: nur dieser Eintrag fehlt, die anderen werden angezeigt', (tester) async {
      final server = standardServer()
        ..json('GET /members', {
          'members': [userJson(), userJson(id: fixIdKind, role: 'robot', name: 'Zukunft'), userJson(id: 'ccccccc1-3333-4444-8555-666666666666', role: 'child', name: 'Ben')],
        });
      await starteApp(tester, await angemeldeteUmgebung(server: server));
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      expect(find.text('Anna (du)'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Zukunft'), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });
  });

  group('Formulare, Überschriften, Zwischenablage', () {
    testWidgets('Anmeldefelder liegen in einer AutofillGroup mit passenden Hinweisen für Passwortmanager', (tester) async {
      await starteApp(tester, TestUmgebung(FakeServer()));
      expect(find.byType(AutofillGroup), findsWidgets);
      final felder = tester.widgetList<TextField>(find.byType(TextField)).toList();
      final hinweise = [for (final f in felder) ...?f.autofillHints];
      expect(hinweise, containsAll([AutofillHints.username, AutofillHints.password]));
      // beide Felder teilen sich dieselbe Gruppe
      final gruppe = find.ancestor(of: find.widgetWithText(TextField, 'Passwort'), matching: find.byType(AutofillGroup));
      expect(gruppe, findsWidgets);
      expect(find.descendant(of: gruppe.first, matching: find.widgetWithText(TextField, 'E-Mail')), findsOneWidget);
    });

    testWidgets('Einladung: neues Passwort steht mit der E-Mail in einer AutofillGroup (new-password)', (tester) async {
      final server = FakeServer()..json('POST /auth/invites/lookup', _lookupOk);
      final container = await starteApp(tester, TestUmgebung(server));
      container.read(inviteIntakeProvider.notifier).eingegangen(fixToken);
      await warte(tester);
      await tippeText(tester, 'Passwort');
      final pw = tester.widget<TextField>(find.widgetWithText(TextField, 'Passwort (mind. 12 Zeichen)'));
      expect(pw.autofillHints, contains(AutofillHints.newPassword));
      final gruppe = find.ancestor(of: find.widgetWithText(TextField, 'Passwort (mind. 12 Zeichen)'), matching: find.byType(AutofillGroup));
      expect(find.descendant(of: gruppe.first, matching: find.widgetWithText(TextField, 'E-Mail')), findsOneWidget);
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('"Wiederherstellungscodes" bricht bei 360 px (Textskala $skala) nicht mitten im Wort um', (tester) async {
        final env = TestUmgebung(FakeServer());
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = skala;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        kanalMocken();
        final container = env.container();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: buildTheme(), home: RecoveryCodesScreen(codes: codes(), onFertig: () async {})),
          ),
        );
        await warte(tester);
        final text = find.text('Wiederherstellungscodes');
        expect(text, findsOneWidget);
        final absatz = tester.renderObject<RenderParagraph>(text);
        final stil = tester.widget<Text>(text).style!;
        // Textskala 1.0: eine Zeile. Bei 1.5 passt das Wort auch in 18 px nicht mehr in 312 px: dann gilt die Mindestgröße
        if (skala == 1.0) expect(absatz.size.height, lessThan(stil.fontSize! * skala * 1.9), reason: 'einzeilig');
        expect(stil.fontSize, lessThan(26), reason: 'Schrift wurde für das lange Wort verkleinert');
        expect(stil.fontSize, greaterThanOrEqualTo(18));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Kurze Überschriften behalten die volle Größe', (tester) async {
      await starteApp(tester, await angemeldeteUmgebung());
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      final stil = tester.widget<Text>(find.text('Profil')).style!;
      expect(stil.fontSize, 26);
    });

    testWidgets('Anmeldeseite: Kennzeile zeigt den konfigurierten Host', (tester) async {
      await starteApp(tester, TestUmgebung(FakeServer()));
      expect(find.text(serverKennzeile()), findsOneWidget);
    });

    testWidgets('TOTP-Schlüssel hat ein Semantics-Label für Screenreader', (tester) async {
      final handle = tester.ensureSemantics();
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', _lookupOk)
        ..json('POST /auth/invites/password/start', {'challengeId': 'c-1', 'totpSecret': 'JBSWY3DPEHPK3PXP', 'totpUri': 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP'});
      final container = await starteApp(tester, TestUmgebung(server));
      container.read(inviteIntakeProvider.notifier).eingegangen(fixToken);
      await warte(tester);
      await tippeText(tester, 'Passwort');
      await eingeben(tester, 'Anzeigename', 'Ben');
      await eingeben(tester, 'E-Mail', 'ben@beispiel.de');
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-langes-passwort-1');
      await eingeben(tester, 'Passwort wiederholen', 'ein-langes-passwort-1');
      await tippeText(tester, 'Weiter zum Authenticator');
      expect(find.bySemanticsLabel(RegExp('Schlüssel für die Authenticator-App')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Geheimnisse werden als vertraulich kopiert (EXTRA_IS_SENSITIVE über den Kanal); ohne Kanal fällt die App zurück', (tester) async {
      final zwischenablage = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') zwischenablage.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final env = TestUmgebung(FakeServer());
      Future<void> zeigeCodes() async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        kanalMocken();
        final container = env.container();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(theme: buildTheme(), home: RecoveryCodesScreen(codes: codes(), onFertig: () async {})),
          ),
        );
        await warte(tester);
      }

      await zeigeCodes();
      kanalGeheimOk = true;
      await tippeText(tester, 'Alle Codes kopieren');
      final sens = kanalAufrufe.where((c) => c.method == 'copySensitive').single;
      expect((sens.arguments as Map)['text'], codes().join('\n'));
      expect(zwischenablage, isEmpty, reason: 'normale Zwischenablage wird nicht zusätzlich benutzt');

      kanalGeheimOk = false; // Kanal nicht verfügbar (z. B. ältere Android-Version)
      await tester.pump(const Duration(seconds: 5));
      await tippeText(tester, 'Alle Codes kopieren');
      expect(zwischenablage.single, codes().join('\n'));
    });
  });

}
