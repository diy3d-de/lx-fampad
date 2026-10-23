// Profil-Umbau: kurze Hauptseite mit Zeilen in Sammelseiten (Sicherheit, Benachrichtigungen, Startseite und Anzeige, Kalender, Müll), Familie nur für
// Eltern/Admin, Betrieb nur für Betreiber, App (Über, Abmelden). Rollen, Plattform (Android/Web), Layout bei 360 px (Textskala 1.0/1.5), Desktop-Shell.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/admin/admin_screen.dart';
import 'package:lx_fampad/features/profile/anzeige_screen.dart';
import 'package:lx_fampad/features/profile/benachrichtigungen_screen.dart';
import 'package:lx_fampad/features/profile/erinnerungen_screen.dart';
import 'package:lx_fampad/features/profile/heute_widget_screen.dart';
import 'package:lx_fampad/features/profile/kalender_einstellungen_screen.dart';
import 'package:lx_fampad/features/profile/passkeys_screen.dart';
import 'package:lx_fampad/features/profile/profil_plattform.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';
import 'package:lx_fampad/features/profile/push_screen.dart';
import 'package:lx_fampad/features/profile/sicherheit_screen.dart';
import 'package:lx_fampad/features/profile/ueber_screen.dart';
import 'package:lx_fampad/features/muell/muell_screen.dart';
import 'package:lx_fampad/features/home/startseite_anpassen_screen.dart';

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(
    WidgetTester tester, {
    String role = 'admin',
    bool betreiber = false,
    bool web = false,
    bool muell = false,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
  }) async {
    final env = await angemeldeteUmgebung(role: role);
    env.server.json('GET /me', {...meJson(role: role, passkeys: 1, password: true, totp: true), 'operator': betreiber});
    env.extraOverrides.addAll([
      profilWebProvider.overrideWithValue(web),
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()),
    ]);
    if (muell) {
      env.server.json('GET /waste', {
        'place': 'Salz',
        'years': <Object>[],
        'events': <Object>[],
        'check': {'pending': false, 'lastCheckAt': null, 'nextCheckAt': null, 'nextRequestAt': null},
      });
    }
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width < 900) {
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    } else {
      await tippe(tester, find.byIcon(Icons.settings_outlined));
    }
    return env;
  }

  Finder zeile(String titel) => find.widgetWithText(EinstellungsZeile, titel);

  group('Hauptseite', () {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Admin (Android, Textskala $skala, 360 px): Gruppen und Zeilen, nichts läuft über, Touch-Ziele mindestens 44 px', (tester) async {
        await start(tester, skala: skala);
        expect(find.byType(ProfileScreen), findsOneWidget);
        expect(find.text('Profil'), findsOneWidget);
        expect(find.text('// EINSTELLUNGEN'), findsOneWidget);
        for (final t in ['Sicherheit', 'Benachrichtigungen', 'Startseite und Anzeige', 'Kalender']) {
          expect(zeile(t), findsOneWidget, reason: t);
        }
        expect(find.text('// FAMILIE'), findsOneWidget);
        expect(zeile('Mitglieder und Einladungen'), findsOneWidget);
        expect(find.text('// BETRIEB'), findsNothing);
        expect(find.text('// APP'), findsOneWidget);
        expect(zeile('Über lx-familyhub'), findsOneWidget);
        expect(find.text('Abmelden'), findsOneWidget);
        expect(find.text('Überall abmelden'), findsOneWidget);
        // die Einstellungen selbst liegen nicht mehr auf der Hauptseite
        for (final t in ['Passkeys', 'Wiederherstellungscodes', 'Angemeldete Geräte', 'Erinnerungen', 'Startseite anpassen', 'Wetter anzeigen', 'Widget „Heute“', 'Push']) {
          expect(find.text(t), findsNothing, reason: '$t gehört auf eine Unterseite');
        }
        // ohne Verfügbarkeit auf dem Server keine Müll-Zeile
        expect(zeile('Müll'), findsNothing);
        pruefeLayout(tester, 'Hauptseite Admin');
      });
    }

    testWidgets('Kind: weder Familie noch Betrieb', (tester) async {
      await start(tester, role: 'child');
      expect(find.text('// EINSTELLUNGEN'), findsOneWidget);
      expect(find.text('// FAMILIE'), findsNothing);
      expect(find.text('// BETRIEB'), findsNothing);
      expect(find.text('Einladungen'), findsNothing);
      expect(find.text('Mitglieder und Einladungen'), findsNothing);
      expect(zeile('Sicherheit'), findsOneWidget);
      pruefeLayout(tester, 'Hauptseite Kind');
    });

    testWidgets('Elternteil: Familie mit "Einladungen" (nicht "Mitglieder und Einladungen"), kein Betrieb', (tester) async {
      await start(tester, role: 'parent');
      expect(find.text('// FAMILIE'), findsOneWidget);
      expect(zeile('Einladungen'), findsOneWidget);
      expect(find.text('Mitglieder und Einladungen'), findsNothing);
      expect(find.text('// BETRIEB'), findsNothing);
      await tippe(tester, zeile('Einladungen'));
      expect(find.byType(AdminScreen), findsOneWidget);
    });

    testWidgets('Betreiber: Gruppe "betrieb" mit der Zeile "Betrieb"', (tester) async {
      await start(tester, betreiber: true);
      expect(find.text('// BETRIEB'), findsOneWidget);
      expect(zeile('Betrieb'), findsOneWidget);
      pruefeLayout(tester, 'Hauptseite Betreiber');
    });

    testWidgets('Müll-Zeile nur, wenn der Server die Abfuhrtermine anbietet; sie öffnet die Müll-Seite', (tester) async {
      await start(tester, muell: true);
      expect(zeile('Müll'), findsOneWidget);
      await tippe(tester, zeile('Müll'));
      expect(find.byType(MuellScreen), findsOneWidget);
    });

    testWidgets('Familienrolle bleibt wählbar, Untertitel der Zeilen nennen Push und Widget nur auf Android', (tester) async {
      await start(tester);
      expect(find.text('Familienrolle ändern (nur Anzeige)'), findsOneWidget);
      expect(find.text('erinnerungen und push'), findsOneWidget);
      expect(find.text('kacheln, wetter, widget'), findsOneWidget);
    });

    testWidgets('Web: Untertitel ohne Push und Widget', (tester) async {
      await start(tester, web: true);
      expect(find.text('erinnerungen'), findsOneWidget);
      expect(find.text('kacheln, wetter'), findsOneWidget);
    });

    testWidgets('Zeilen führen auf die Seiten: Sicherheit, Benachrichtigungen, Startseite und Anzeige, Kalender, Über', (tester) async {
      await start(tester);
      for (final (titel, typ) in <(String, Type)>[
        ('Sicherheit', SicherheitScreen),
        ('Benachrichtigungen', BenachrichtigungenScreen),
        ('Startseite und Anzeige', AnzeigeScreen),
        ('Kalender', KalenderEinstellungenScreen),
        ('Über lx-familyhub', UeberScreen),
      ]) {
        await tippe(tester, zeile(titel));
        expect(find.byType(typ), findsOneWidget, reason: titel);
        await tippe(tester, find.byTooltip('Zurück'));
        expect(find.byType(ProfileScreen), findsOneWidget, reason: 'zurück von $titel');
      }
    });
  });

  group('Sicherheit', () {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('alle bisherigen Sicherheitszeilen sind da und öffnen ihre Seite (360 px, Textskala $skala)', (tester) async {
        await start(tester, skala: skala);
        await tippe(tester, zeile('Sicherheit'));
        expect(find.byType(SicherheitScreen), findsOneWidget);
        for (final t in ['// ANMELDUNG', '// SCHLÜSSEL UND CHAT', '// GERÄTE UND EREIGNISSE']) {
          expect(find.text(t), findsOneWidget, reason: t);
        }
        for (final t in ['Passkeys', 'Passwort und Zwei-Faktor (TOTP)', 'Wiederherstellungscodes', 'Bin ich abgesichert?', 'Verschlüsselung', 'Angemeldete Geräte', 'Sicherheitsereignisse']) {
          await tester.ensureVisible(find.text(t));
          expect(find.text(t), findsOneWidget, reason: t);
        }
        expect(find.text('1 aktiv'), findsOneWidget);
        expect(find.textContaining('8 übrig'), findsOneWidget);
        pruefeLayout(tester, 'Sicherheit');
        await tippe(tester, find.text('Passkeys'));
        expect(find.byType(PasskeysScreen), findsOneWidget);
      });
    }
  });

  group('Benachrichtigungen', () {
    testWidgets('Android: Erinnerungen und Push', (tester) async {
      await start(tester);
      await tippe(tester, zeile('Benachrichtigungen'));
      expect(zeile('Erinnerungen'), findsOneWidget);
      expect(zeile('Push'), findsOneWidget);
      expect(find.text('Push gibt es nur in der Android-App.'), findsNothing);
      pruefeLayout(tester, 'Benachrichtigungen Android');
      await tippe(tester, zeile('Push'));
      expect(find.byType(PushScreen), findsOneWidget);
    });

    testWidgets('Web: Erinnerungen, Push nur als Hinweis', (tester) async {
      await start(tester, web: true);
      await tippe(tester, zeile('Benachrichtigungen'));
      expect(zeile('Erinnerungen'), findsOneWidget);
      expect(zeile('Push'), findsNothing);
      expect(find.text('Push gibt es nur in der Android-App.'), findsOneWidget);
      await tippe(tester, zeile('Erinnerungen'));
      expect(find.byType(ErinnerungenScreen), findsOneWidget);
    });

    testWidgets('360 px, Textskala 1.5', (tester) async {
      await start(tester, skala: 1.5);
      await tippe(tester, zeile('Benachrichtigungen'));
      pruefeLayout(tester, 'Benachrichtigungen 1.5');
    });
  });

  group('Startseite und Anzeige', () {
    testWidgets('Android: Startseite anpassen, Wetter-Schalter und Widget "Heute"', (tester) async {
      await start(tester);
      await tippe(tester, zeile('Startseite und Anzeige'));
      expect(zeile('Startseite anpassen'), findsOneWidget);
      expect(find.widgetWithText(SwitchListTile, 'Wetter anzeigen'), findsOneWidget);
      expect(zeile('Widget „Heute“'), findsOneWidget);
      pruefeLayout(tester, 'Anzeige Android');
      await tippe(tester, zeile('Widget „Heute“'));
      expect(find.byType(HeuteWidgetScreen), findsOneWidget);
    });

    testWidgets('Web: kein Widget "Heute"', (tester) async {
      await start(tester, web: true);
      await tippe(tester, zeile('Startseite und Anzeige'));
      expect(zeile('Startseite anpassen'), findsOneWidget);
      expect(find.widgetWithText(SwitchListTile, 'Wetter anzeigen'), findsOneWidget);
      expect(find.text('Widget „Heute“'), findsNothing);
      await tippe(tester, zeile('Startseite anpassen'));
      expect(find.byType(StartseiteAnpassenScreen), findsOneWidget);
    });

    testWidgets('360 px, Textskala 1.5', (tester) async {
      await start(tester, skala: 1.5);
      await tippe(tester, zeile('Startseite und Anzeige'));
      pruefeLayout(tester, 'Anzeige 1.5');
    });
  });

  group('Desktop-Shell (ab 900 px)', () {
    testWidgets('Sammelseite liegt im Inhaltsbereich, Seitenleiste bleibt, Zurück führt zur Hauptseite', (tester) async {
      await start(tester, groesse: const Size(1200, 800));
      expect(find.byType(ProfileScreen), findsOneWidget);
      await tippe(tester, zeile('Sicherheit'));
      expect(find.byType(SicherheitScreen), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      await tippe(tester, find.text('Passkeys'));
      expect(find.byType(PasskeysScreen), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
