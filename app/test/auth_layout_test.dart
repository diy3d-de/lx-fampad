// Mobilansicht der neuen Screens: 360 px Breite bei Textskalierung 1.0 und 1.5. Alle Screens (Anmeldung, Einladung,
// Codes, Warten, Profil, Passkeys, Geräte, Admin, Dialoge, Sheets) ohne Layoutfehler und mit Touch-Zielen >= 44 px.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart' show schluesselSpeicherProvider;
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart' show MemorySchluesselSpeicher;

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _lookupMitFreigabe = {
  'invite': {
    'role': 'child',
    'pinRequired': true,
    'requireApproval': true,
    'familyName': 'Familie Beispiel mit einem ziemlich langen Namen',
    'reset': false,
    'expiresAt': '2099-10-19T12:00:00.000Z',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = 'Textskala $skala';

    testWidgets('360 px, $s: Anmeldung, Einladung, Registrierung, Codes, Warten', (tester) async {
      final server = FakeServer()
        ..json('POST /auth/invites/lookup', _lookupMitFreigabe)
        ..json('POST /auth/invites/passkey/options', {'challengeId': 'c-9', 'options': webauthnOptionen()})
        ..json('POST /auth/invites/password/start', {
          'challengeId': 'c-10',
          'totpSecret': 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
          'totpUri': 'otpauth://totp/lx-familyhub:ben%40beispiel.de?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=lx-familyhub',
        })
        ..json('POST /auth/invites/password/complete', {
          'member': userJson(role: 'child', status: 'pending', name: 'Oma'),
          'status': 'pending',
          'recoveryCodes': codes(),
        });
      final env = TestUmgebung(server);
      env.passkeys.da = false;
      await starteApp(tester, env, skala: skala);

      // Anmeldung
      pruefeLayout(tester, 'Login');
      await tippeText(tester, 'Weiter');
      pruefeLayout(tester, 'Login mit Fehler');
      await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
      await eingeben(tester, 'Passwort', 'geheimes-passwort');
      await tippeText(tester, 'Weiter');
      pruefeLayout(tester, 'Login Schritt 2');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      pruefeLayout(tester, 'Login Schritt 2 mit Fehler');
      await tippeText(tester, 'Wiederherstellungscode nutzen');
      pruefeLayout(tester, 'Login Schritt 2 mit Wiederherstellungscode');
      await tippeText(tester, 'zurück');
      await tippeText(tester, 'Passwort verloren? Mit Wiederherstellungscode anmelden');
      pruefeLayout(tester, 'Login nur Wiederherstellungscode');
      await tippe(tester, find.widgetWithText(FilledButton, 'Anmelden'));
      pruefeLayout(tester, 'Login nur Wiederherstellungscode mit Fehler');
      await tippeText(tester, 'zurück');

      // Einladung
      await tippeText(tester, 'Einladung per QR-Code annehmen');
      pruefeLayout(tester, 'Einladung: Link eingeben');
      await tippeText(tester, 'Einladung prüfen');
      pruefeLayout(tester, 'Einladung: ungültiger Link');
      await eingeben(tester, 'Einladungslink', 'https://familie.lx-labs.dev/#/einladung/$fixToken');
      await tippeText(tester, 'Einladung prüfen');
      pruefeLayout(tester, 'Einladung: Formular Passkey');
      await tippeText(tester, 'Passkey anlegen');
      pruefeLayout(tester, 'Einladung: Formular mit Fehler');
      await tippeText(tester, 'Passwort');
      pruefeLayout(tester, 'Einladung: Formular Passwort');
      await eingeben(tester, 'PIN der Einladung', '654321');
      await eingeben(tester, 'Anzeigename', 'Oma');
      await eingeben(tester, 'E-Mail', 'oma@beispiel.de');
      await eingeben(tester, 'Passwort (mind. 12 Zeichen)', 'ein-langes-passwort-1');
      await eingeben(tester, 'Passwort wiederholen', 'ein-langes-passwort-1');
      await tippeText(tester, 'Weiter zum Authenticator');
      pruefeLayout(tester, 'Einladung: Authenticator einrichten');
      await tippeText(tester, 'Bestätigen und Konto anlegen');
      pruefeLayout(tester, 'Einladung: Authenticator mit Fehler');
      await eingeben(tester, 'Code aus der Authenticator-App', '123456');
      await tippeText(tester, 'Bestätigen und Konto anlegen');
      pruefeLayout(tester, 'Wiederherstellungscodes');
      await tippeText(tester, 'Ich habe die Codes sicher gespeichert.');
      pruefeLayout(tester, 'Wiederherstellungscodes bestätigt');
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      pruefeLayout(tester, 'Warten auf Freigabe');
      expect(find.textContaining('Fast geschafft'), findsOneWidget);
    });

    testWidgets('360 px, $s: Verbindungsfehler beim Start', (tester) async {
      final server = FakeServer()..on('GET /me', (_) => fehler(503, 'server_busy', retryAfter: 5));
      final env = TestUmgebung(server);
      await env.angemeldet();
      await starteApp(tester, env, skala: skala);
      pruefeLayout(tester, 'Verbindungsfehler');
    });

    testWidgets('360 px, $s: Profil, Passkeys, Geräte, Step-up, Abmelden-Dialog', (tester) async {
      final env = await angemeldeteUmgebung();
      env.server.on('POST /me/recovery-codes', (_) => fehler(403, 'step_up_required'));
      env.extraOverrides.add(schluesselSpeicherProvider.overrideWithValue(MemorySchluesselSpeicher())); // kein Personenschlüssel: einfache Abmelde-Rückfrage
      await starteApp(tester, env, skala: skala);

      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      pruefeLayout(tester, 'Profil');
      await tippeText(tester, 'Wiederherstellungscodes');
      pruefeLayout(tester, 'Rückfrage neue Codes');
      await tippe(tester, find.widgetWithText(TextButton, 'Neue Codes erzeugen'));
      pruefeLayout(tester, 'Step-up-Dialog');
      await tippeText(tester, 'Wiederherstellungscode nutzen');
      pruefeLayout(tester, 'Step-up-Dialog mit Wiederherstellungscode');
      await tippeText(tester, 'Mit Code bestätigen');
      pruefeLayout(tester, 'Step-up-Dialog mit Fehler');
      await tippeText(tester, 'Abbrechen');

      await tippeText(tester, 'Abmelden');
      pruefeLayout(tester, 'Abmelden-Dialog');
      await tippeText(tester, 'Abbrechen');

      await tippeText(tester, 'Passkeys');
      pruefeLayout(tester, 'Passkeys');
      await tippe(tester, find.byTooltip('Passkey Pixel 9 entfernen'));
      pruefeLayout(tester, 'Passkey entfernen');
      await tippeText(tester, 'Abbrechen');
      await tippe(tester, find.byTooltip('Zurück'));

      await tippeText(tester, 'Angemeldete Geräte');
      pruefeLayout(tester, 'Geräte');
      await tippe(tester, find.byTooltip('Pixel 9 abmelden'));
      pruefeLayout(tester, 'Gerät abmelden');
    });

    testWidgets('360 px, $s: Admin (Mitglieder, Einladungen, Sheets, Ergebnis)', (tester) async {
      final server = standardServer()..json('POST /invites', neueEinladungJson())..json('POST /members/$fixIdKind/reset', neueEinladungJson());
      final env = await angemeldeteUmgebung(server: server);
      await starteApp(tester, env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      pruefeLayout(tester, 'Mitglieder');

      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      pruefeLayout(tester, 'Mitglieder-Menü');
      await tippeText(tester, 'Rolle ändern');
      pruefeLayout(tester, 'Rolle ändern');
      await tester.tapAt(const Offset(5, 5)); // Dialog schließen
      await warte(tester);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Zugang zurücksetzen');
      pruefeLayout(tester, 'Zurücksetzen-Dialog');
      await tippe(tester, find.widgetWithText(TextButton, 'Zurücksetzen'));
      pruefeLayout(tester, 'Zurücksetzen-Ergebnis');
      await tippeText(tester, 'Fertig');
      await tippe(tester, find.byTooltip('Aktionen für Oma'));
      pruefeLayout(tester, 'Menü wartendes Mitglied');
      await tester.tapAt(const Offset(5, 5));
      await warte(tester);

      await tippeText(tester, 'Einladungen');
      pruefeLayout(tester, 'Einladungen');
      await tippe(tester, find.byTooltip('Aktionen für die Kind-Einladung'));
      pruefeLayout(tester, 'Einladungs-Menü');
      await tester.tapAt(const Offset(5, 5));
      await warte(tester);
      await tippeText(tester, 'Neue Einladung');
      pruefeLayout(tester, 'Neue Einladung (Sheet)');
      await tippe(tester, find.widgetWithText(ChoiceChip, 'Admin'));
      pruefeLayout(tester, 'Neue Einladung (Admin)');
      await tippeText(tester, 'Einladung erstellen');
      pruefeLayout(tester, 'Einladung erstellt');
    });

    testWidgets('360 px, $s: Eltern sehen die Einladungen', (tester) async {
      final env = await angemeldeteUmgebung(role: 'parent');
      await starteApp(tester, env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      pruefeLayout(tester, 'Profil (Eltern)');
      await tippe(tester, find.text('Einladungen'));
      pruefeLayout(tester, 'Einladungen (Eltern)');
      await tippeText(tester, 'Neue Einladung');
      pruefeLayout(tester, 'Neue Einladung (Eltern)');
    });
  }
}
