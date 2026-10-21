// Rückfrage vor dem Abmelden mit Personenschlüssel auf dem Gerät (Profil > Abmelden, Überall abmelden, Geräteliste "dieses Gerät"): Text je nach
// Sicherungslage, "Trotzdem abmelden", "Abbrechen", "Passwort-Sicherung anlegen", unbekannter Stand (Schlüsselspeicher nicht lesbar, Server offline).
// Ohne Schlüssel bleibt die einfache Rückfrage. 360 px, Textskala 1.0 und 1.5 (ganze App); 2.0 nur für den Dialog allein (die Startseite läuft bei 2.0 über, unabhängig von dieser Änderung).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/features/profile/abmelden_pruefung.dart';
import 'package:lx_fampad/features/profile/pw_sicherung_screen.dart';
import 'package:lx_fampad/features/profile/verschluesselung_screen.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

/// Schlüsselspeicher, dessen Lesen sich ausschalten lässt (wie ein vorübergehend nicht lesbarer Keystore).
class _KaputterSpeicher extends MemorySchluesselSpeicher {
  bool kaputt = false;

  @override
  Future<Uint8List?> lesen(String name) async {
    if (kaputt) {
      throw const SchluesselSpeicherFehler('nicht lesbar', dauerhaft: false);
    }
    return super.lesen(name);
  }
}

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final _KaputterSpeicher speicher;
  _Aufbau(this.env, this.srv, this.speicher);
}

Future<_Aufbau> _aufbau({bool pwServer = true}) async {
  final server = standardServer()
    ..json('POST /auth/logout', {'ok': true})
    ..json('POST /auth/logout-all', {'ok': true})
    ..json('DELETE /devices/$fixDevice', {'ok': true});
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna');
  srv.pwSchalter = pwServer;
  final env = TestUmgebung(server);
  await env.angemeldet();
  final speicher = _KaputterSpeicher();
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
  await tippe(tester, find.widgetWithText(TextButton, 'Später'));
  await tippe(tester, find.byTooltip('Zurück'));
}

/// Vermerk "Passwort-Sicherung auf diesem Gerät bestätigt" für [version] (Standard: die aktuelle Schlüsselversion des Servers).
Future<void> _vermerk(_Aufbau a, {int? version}) => a.speicher.schreiben(
  'e2ee.kv.pw.$fixIdAdmin',
  utf8Bytes('${version ?? a.srv.schluesselVersion(fixIdAdmin)}'),
);

/// Zustand fest vorgegeben (nur für den Dialog allein).
class _FesterZustand extends E2eeController {
  final E2eeState fest;
  _FesterZustand(this.fest);

  @override
  E2eeState build() => fest;

  @override
  Future<void> laden() async {}
}

Future<void> _dialogAllein(
  WidgetTester tester,
  E2eeState zustand, {
  bool ueberall = false,
}) async {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [e2eeProvider.overrideWith(() => _FesterZustand(zustand))],
      child: MaterialApp(
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: w!,
        ),
        home: Consumer(
          builder: (c, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => abmeldenBestaetigen(
                  c,
                  ref,
                  titel: 'Abmelden?',
                  text: 'Du wirst abgemeldet.',
                  knopf: 'Abmelden',
                  ueberall: ueberall,
                  ohneSchluessel: () async => true,
                ),
                child: const Text('los'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('los'));
  await tester.pumpAndSettle();
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    testWidgets(
      'ohne Schlüssel: einfache Rückfrage, Abmelden wie bisher ($s)',
      (tester) async {
        final a = await _aufbau();
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
        final a = await _aufbau();
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
            'Auf diesem Gerät ist keine bestätigte Passwort-Sicherung vermerkt',
          ),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(FilledButton, 'Passwort-Sicherung anlegen'),
          findsOneWidget,
        );
        expect(find.text('Trotzdem abmelden'), findsOneWidget);
        pruefeLayout(tester, 'Abmelden-Warnung ohne Passwort-Sicherung');
        await tippeText(tester, 'Trotzdem abmelden');
        expect(a.env.geloescht, 1);
        expect(find.text('Willkommen zurück'), findsOneWidget);
      },
    );

    testWidgets('"Abbrechen" lässt alles unberührt ($s)', (tester) async {
      final a = await _aufbau();
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
        final a = await _aufbau();
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
      'bestätigte Passwort-Sicherung: ruhiger Hinweis ohne Warnung ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await _vermerk(a);
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
      'Vermerk für eine andere Schlüsselversion zählt nicht als bestätigt ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await _vermerk(a, version: a.srv.schluesselVersion(fixIdAdmin) + 1);
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining('keine bestätigte Passwort-Sicherung'),
          findsOneWidget,
        );
        expect(find.text('Trotzdem abmelden'), findsOneWidget);
      },
    );

    testWidgets(
      'veraltete Passwort-Sicherung (nach Passwort-Reset) zählt nicht als bestätigt ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await _vermerk(a);
        a.srv.pwEinspielen(
          fixIdAdmin,
          'blob',
          version: a.srv.schluesselVersion(fixIdAdmin),
        );
        a.srv.passwortZurueckgesetzt(fixIdAdmin);
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining('keine bestätigte Passwort-Sicherung'),
          findsOneWidget,
        );
        expect(find.text('Trotzdem abmelden'), findsOneWidget);
      },
    );

    testWidgets(
      'ohne Passwort-Sicherung am Server, Wiederherstellungsschlüssel nicht gesichert: "Erst sichern" ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: false);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining('Dein Schlüssel ist nicht gesichert'),
          findsOneWidget,
        );
        expect(find.text('Passwort-Sicherung anlegen'), findsNothing);
        pruefeLayout(
          tester,
          'Abmelden-Warnung ohne Passwort-Sicherung am Server',
        );
        await tippeText(tester, 'Erst sichern');
        expect(find.byType(VerschluesselungScreen), findsOneWidget);
        expect(a.env.geloescht, 0);
      },
    );

    testWidgets(
      'ohne Passwort-Sicherung am Server, Wiederherstellungsschlüssel gesichert: ruhiger Hinweis ($s)',
      (tester) async {
        final a = await _aufbau(pwServer: false);
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.sicherungEinspielen(fixIdAdmin);
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining('nur, wenn du ihn noch hast'),
          findsOneWidget,
        );
        expect(find.textContaining('nicht gesichert'), findsNothing);
        expect(find.text('Erst sichern'), findsNothing);
        expect(find.text('Trotzdem abmelden'), findsNothing);
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1);
      },
    );

    testWidgets(
      'Schlüsselspeicher nicht lesbar: unbekannt, nie "kein Schlüssel" ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        // frischer App-Start mit nicht lesbarem Schlüsselspeicher: der Schlüssel ist nicht im Arbeitsspeicher
        a.speicher.kaputt = true;
        await tester.pumpWidget(const SizedBox());
        await starteApp(tester, a.env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining(
            'Ob auf diesem Gerät ein Schlüssel liegt, ließ sich gerade nicht prüfen',
          ),
          findsOneWidget,
        );
        expect(find.text('Abmelden?'), findsOneWidget);
        expect(find.text('Passwort-Sicherung anlegen'), findsNothing);
        expect(find.text('Erst sichern'), findsNothing);
        expect(
          find.textContaining('Wiederherstellungsschlüssel'),
          findsNothing,
          reason: 'keine Zusage über eine Sicherung',
        );
        pruefeLayout(tester, 'Abmelden bei unbekanntem Schlüsselstand');
        await tippeText(tester, 'Trotzdem abmelden');
        expect(a.env.geloescht, 1);
      },
    );

    testWidgets(
      'Server nicht erreichbar, Schlüssel lokal da: neutraler Hinweis, kein "Erst sichern" ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.server.on('GET /me/keys', (_) => fehler(500, 'server_error'));
        await tippeText(tester, 'Abmelden');
        expect(
          find.textContaining(
            'Ob dein Schlüssel gesichert ist, ließ sich gerade nicht prüfen',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('nicht gesichert'), findsNothing);
        expect(find.text('Erst sichern'), findsNothing);
        expect(find.text('Passwort-Sicherung anlegen'), findsNothing);
        expect(find.text('Trotzdem abmelden'), findsOneWidget);
        pruefeLayout(tester, 'Abmelden bei nicht erreichbarem Server');
      },
    );

    testWidgets(
      'Überall abmelden: Hinweis auf die anderen Geräte, ruft logout-all ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await _vermerk(a);
        await tippeText(tester, 'Überall abmelden');
        expect(
          find.textContaining(
            'sie behalten den Schlüssel, solange du dich dort nicht selbst abmeldest',
          ),
          findsOneWidget,
        );
        pruefeLayout(tester, 'Überall abmelden mit Schlüssel');
        await tippe(
          tester,
          find.widgetWithText(TextButton, 'Überall abmelden'),
        );
        expect(a.srv.server.anfragen('POST /auth/logout-all'), hasLength(1));
        expect(a.env.geloescht, 1);
      },
    );

    testWidgets(
      'Geräteliste, dieses Gerät: dieselbe Warnung, anderes Gerät ohne ($s)',
      (tester) async {
        final a = await _aufbau();
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
          find.textContaining('keine bestätigte Passwort-Sicherung'),
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

  group('Textskala 2.0, nur der Dialog (360 px)', () {
    testWidgets('Warnung mit allen Knöpfen', (tester) async {
      await _dialogAllein(
        tester,
        const E2eeState(status: E2eeStatus.bereit, pwSicherungVerfuegbar: true),
        ueberall: true,
      );
      expect(find.text('Passwort-Sicherung anlegen'), findsOneWidget);
      expect(find.text('Trotzdem abmelden'), findsOneWidget);
      pruefeLayout(tester, 'Dialog 2.0 Warnung');
    });

    testWidgets('unbekannter Stand', (tester) async {
      await _dialogAllein(
        tester,
        const E2eeState(status: E2eeStatus.nichtVerfuegbar),
      );
      expect(
        find.textContaining('ließ sich gerade nicht prüfen'),
        findsOneWidget,
      );
      pruefeLayout(tester, 'Dialog 2.0 unbekannt');
    });
  });
}
