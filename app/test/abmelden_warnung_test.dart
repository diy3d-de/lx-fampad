// Rückfrage vor dem Abmelden mit Personenschlüssel auf dem Gerät (Profil > Abmelden, Geräteliste "dieses Gerät"): Text je nach Sicherungslage,
// "Trotzdem abmelden", "Abbrechen", "Passwort-Sicherung anlegen". Ohne Schlüssel bleibt die einfache Rückfrage. 360 px, Textskala 1.0 und 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/features/profile/pw_sicherung_screen.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.speicher);
}

Future<_Aufbau> _aufbau({bool pwServer = false, bool pwVermerk = false}) async {
  final server = standardServer()
    ..json('POST /auth/logout', {'ok': true})
    ..json('DELETE /devices/$fixDevice', {'ok': true});
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna');
  srv.pwSchalter = pwServer;
  final env = TestUmgebung(server);
  await env.angemeldet();
  final speicher = MemorySchluesselSpeicher();
  if (pwVermerk) {
    await speicher.schreiben('e2ee.kv.pw.$fixIdAdmin', utf8Bytes('1'));
  }
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
    schluesselSpeicherProvider.overrideWithValue(speicher),
  ]);
  return _Aufbau(env, srv, speicher);
}

/// Einrichtung ohne Sicherung des Wiederherstellungsschlüssels, danach zurück im Profil.
Future<void> _einrichten(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Verschlüsselung');
  await tippeText(tester, 'Verschlüsselung einrichten');
  await tippeText(tester, 'Später sichern');
  await tippeText(tester, 'Später');
  await tippe(tester, find.byTooltip('Zurück'));
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    testWidgets(
      'ohne Schlüssel: einfache Rückfrage, Abmelden wie bisher ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: true);
        await starteApp(tester, a.env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Abmelden');
        expect(find.text('Abmelden?'), findsOneWidget);
        expect(find.textContaining('Schlüssel'), findsNothing);
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1);
        expect(find.text('Willkommen zurück'), findsOneWidget);
      },
    );

    testWidgets(
      'Schlüssel ohne bestätigte Passwort-Sicherung: Warnung, "Trotzdem abmelden" löscht wie bisher ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: true);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining(
            'Beim Abmelden wird dein Schlüssel von diesem Gerät gelöscht',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('nur, wenn du ihn noch hast'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Du hast keine bestätigte Passwort-Sicherung. Lege sie vorher an: Profil › Verschlüsselung.',
          ),
          findsOneWidget,
        );
        expect(find.text('Passwort-Sicherung anlegen'), findsOneWidget);
        expect(find.text('Trotzdem abmelden'), findsOneWidget);
        pruefeLayout(tester, 'Abmelden-Warnung ohne Passwort-Sicherung');
        await tippeText(tester, 'Trotzdem abmelden');
        expect(a.env.geloescht, 1);
        expect(find.text('Willkommen zurück'), findsOneWidget);
      },
    );

    testWidgets('"Abbrechen" lässt alles unberührt ($s)', (tester) async {
      final a = await _aufbau(pwServer: true);
      await starteApp(tester, a.env, skala: skala);
      await _einrichten(tester);
      await tippeText(tester, 'Abmelden');
      await tippeText(tester, 'Abbrechen');
      expect(find.byType(AlertDialog), findsNothing);
      expect(a.env.geloescht, 0);
      expect(a.srv.server.anfragen('POST /auth/logout'), isEmpty);
      expect(await a.env.store.readTokens(), isNotNull);
      expect(find.text('Profil & Sicherheit'), findsOneWidget);
    });

    testWidgets(
      '"Passwort-Sicherung anlegen" öffnet den Ablauf und meldet nicht ab ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: true);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Abmelden');
        await tippeText(tester, 'Passwort-Sicherung anlegen');
        expect(find.byType(PwSicherungScreen), findsOneWidget);
        expect(a.env.geloescht, 0);
        expect(a.srv.server.anfragen('POST /auth/logout'), isEmpty);
      },
    );

    testWidgets(
      'Schlüssel mit bestätigter Passwort-Sicherung: ruhiger Hinweis ohne Warnung ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: true, pwVermerk: true);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining('Passwort der Passwort-Sicherung'),
          findsOneWidget,
        );
        expect(
          find.textContaining('nur, wenn du ihn noch hast'),
          findsOneWidget,
        );
        expect(find.textContaining('keine bestätigte'), findsNothing);
        expect(find.text('Passwort-Sicherung anlegen'), findsNothing);
        expect(find.text('Trotzdem abmelden'), findsNothing);
        pruefeLayout(tester, 'Abmelden-Hinweis mit Passwort-Sicherung');
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1);
      },
    );

    testWidgets(
      'Geräteliste, dieses Gerät: dieselbe Warnung, anderes Gerät ohne ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: true);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Angemeldete Geräte');
        await tippe(tester, find.byTooltip('Firefox auf Windows abmelden'));
        expect(
          find.textContaining('Schlüssel'),
          findsNothing,
          reason: 'ein anderes Gerät löscht hier keinen Schlüssel',
        );
        await tippeText(tester, 'Abbrechen');
        await tippe(tester, find.byTooltip('Pixel 9 abmelden'));
        expect(
          find.textContaining('Du hast keine bestätigte Passwort-Sicherung'),
          findsOneWidget,
        );
        pruefeLayout(tester, 'Geräteliste mit Schlüsselwarnung');
        await tippeText(tester, 'Abbrechen');
        expect(a.env.geloescht, 0);
        await tippe(tester, find.byTooltip('Pixel 9 abmelden'));
        await tippeText(tester, 'Trotzdem abmelden');
        expect(a.env.geloescht, 1);
      },
    );
  }
}
