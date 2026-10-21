// Passwort zurücksetzen (PR 4b): "Passwort vergessen?" mit Wiederherstellungscode und Passkey, Link des Admins einlösen, Admin-Aktion, Sicherheitsereignisse,
// automatische neue Passwort-Sicherung nach dem Reset, Sicherheitshinweis. Layout bei 360 px und Textskala 1.0/1.5. Nie geht das Passwort an den Server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/reset_hinweis.dart';
import 'package:lx_fampad/data/auth/sicherheit_text.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/passkey_service.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';
import 'package:lx_fampad/data/push/sicherheits_pruefer.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _pwNeu = 'Zebra-Kamin-Orbit-Fluss-Lampe';
const _wiederherstellung = 'ABCD-EFGH-IJKL-1000';

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final FakeServer server;
  final MemorySchluesselSpeicher speicher;
  _Aufbau(this.env, this.srv, this.server, this.speicher);

  String get alleAnfragen => jsonEncode(server.log.map((r) => r.body is Map ? r.body : null).toList());
}

/// Abgemeldete App (Anmeldeseite) mit einem Server, der das Zurücksetzen anbietet; Anna hat optional eine Passwort-Sicherung und den Schlüssel auf dem Gerät.
Future<_Aufbau> _aufbau({bool schluessel = true, bool mitSicherung = true, bool angeboten = true}) async {
  final server = FakeServer();
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de')
    ..pwSchalter = angeboten
    ..authKeySchalter = angeboten;
  server
    ..json('GET /me', meJson(password: true, totp: true))
    ..json('GET /me/security-events', {'events': <Object>[]});
  final env = TestUmgebung(server);
  final speicher = MemorySchluesselSpeicher();
  env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()), schluesselSpeicherProvider.overrideWithValue(speicher)]);
  final crypto = FakeCryptoProvider();
  final pk = Uint8List.fromList(List.generate(64, (i) => i + 1));
  srv.setzeSchluessel(
    fixIdAdmin,
    enc: base64urlKodieren(Uint8List.fromList(crypto.boxPaarAusSeed(pk.sublist(0, 32)).oeffentlich)),
    sign: base64urlKodieren(Uint8List.fromList(crypto.signPaarAusSeed(pk.sublist(32)).oeffentlich)),
    version: 1,
  );
  if (schluessel) await speicher.schreiben(personenschluesselName(fixIdAdmin), pk);
  if (mitSicherung) srv.pwEinspielen(fixIdAdmin, base64urlKodieren(Uint8List.fromList(List.generate(160, (i) => i))), version: 1);
  return _Aufbau(env, srv, server, speicher);
}

Future<void> _zuPasswortVergessen(WidgetTester tester) async {
  await tippeText(tester, 'Passwort vergessen? Neues Passwort festlegen');
}

Future<void> _vergessenAusfuellen(WidgetTester tester, {String code = _wiederherstellung, String pw = _pwNeu, String? pw2}) async {
  await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
  await eingeben(tester, 'Wiederherstellungscode', code);
  await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', pw);
  await eingeben(tester, 'Passwort wiederholen', pw2 ?? pw);
  await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
  await tester.pump(const Duration(milliseconds: 200));
  await warte(tester, 10);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modelle', () {
    test('Einladung: kind password_reset wird erkannt, Unbekanntes gilt als standard', () {
      Map<String, dynamic> lookup(Object? kind) => {
        'role': 'parent',
        'pinRequired': false,
        'requireApproval': false,
        'familyName': 'F',
        'reset': true,
        'kind': ?kind,
        'displayName': 'Anna',
        'expiresAt': '2026-10-22T10:00:00.000Z',
      };
      expect(InviteLookup.fromJson(lookup('password_reset')).art, EinladungsArt.passwordReset);
      expect(InviteLookup.fromJson(lookup('standard')).art, EinladungsArt.standard);
      expect(InviteLookup.fromJson(lookup('zukunft')).art, EinladungsArt.standard);
      expect(InviteLookup.fromJson(lookup(null)).art, EinladungsArt.standard, reason: 'älterer Server ohne kind');
      expect(InviteDto.fromJson({...einladungJson(), 'kind': 'password_reset'}).art, EinladungsArt.passwordReset);
      expect(InviteDto.fromJson(einladungJson()).art, EinladungsArt.standard);
    });

    test('Sicherheitsereignisse: Art, Weg, Name; unbekannte Arten bleiben lesbar', () {
      final e = SicherheitsEreignisDto.fromJson({'id': 'e1', 'kind': 'password_reset_done', 'via': 'recovery_code', 'actorName': null, 'byAdmin': false, 'createdAt': '2026-10-21T10:00:00.000Z'});
      expect(e.art, SicherheitsArt.passwortZurueckgesetzt);
      expect(e.weg, SicherheitsWeg.wiederherstellungscode);
      expect(e.akteur, isNull);
      expect(sicherheitsEreignisText(e), contains('Wiederherstellungscode'));
      final a = SicherheitsEreignisDto.fromJson({'id': 'e2', 'kind': 'password_reset_requested', 'via': 'admin', 'actorName': 'Anna', 'byAdmin': true, 'createdAt': '2026-10-21T10:00:00.000Z'});
      expect(sicherheitsEreignisText(a), startsWith('Anna hat einen Link'));
      final neu = SicherheitsEreignisDto.fromJson({'id': 'e3', 'kind': 'zukunft', 'via': 'x', 'actorName': null, 'byAdmin': false, 'createdAt': '2026-10-21T10:00:00.000Z'});
      expect(neu.art, SicherheitsArt.andere);
      expect(sicherheitsEreignisText(neu), isNotEmpty);
      expect(() => SicherheitsEreignisDto.fromJson({'kind': 'x'}), throwsA(anything));
    });
  });

  group('SicherheitsPruefer', () {
    Future<(SicherheitsPruefer, FakeServer, AppDatabase, _FakeAnzeige)> bauen() async {
      final server = FakeServer();
      final (client, _) = await angemeldeterClient(server);
      final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      addTearDown(db.close);
      final anzeige = _FakeAnzeige();
      return (SicherheitsPruefer(api: FampadApi(client, geraet: () async => null), db: db, anzeige: anzeige), server, db, anzeige);
    }

    Map<String, dynamic> ereignis(String id, DateTime zeit, {String kind = 'password_reset_requested'}) =>
        {'id': id, 'kind': kind, 'via': 'admin', 'actorName': 'Anna', 'byAdmin': true, 'createdAt': zeit.toUtc().toIso8601String()};

    test('erster Lauf meldet nichts (Bestand), spätere neue Ereignisse schon; danach nichts mehr', () async {
      final (p, server, _, _) = await bauen();
      final t0 = DateTime.utc(2026, 10, 20, 8);
      server.json('GET /me/security-events', {'events': [ereignis('e1', t0)]});
      expect(await p.neue(), isEmpty);
      expect(await p.neue(), isEmpty);
      server.json('GET /me/security-events', {'events': [ereignis('e2', t0.add(const Duration(hours: 1)), kind: 'password_reset_done'), ereignis('e1', t0)]});
      final neu = await p.neue();
      expect(neu.map((e) => e.id), ['e2']);
      expect(await p.neue(), isEmpty);
    });

    test('erster Lauf ohne Bestand: das erste spätere Ereignis zählt', () async {
      final (p, server, _, _) = await bauen();
      server.json('GET /me/security-events', {'events': <Object>[]});
      expect(await p.neue(), isEmpty);
      server.json('GET /me/security-events', {'events': [ereignis('e1', DateTime.now())]});
      expect((await p.neue()).map((e) => e.id), ['e1']);
    });

    test('im Vordergrund ein Hinweis in der Oberfläche, im Hintergrund eine feste Benachrichtigung ohne Einzelheiten', () async {
      final (p, server, db, anzeige) = await bauen();
      server.json('GET /me/security-events', {'events': <Object>[]});
      await p.neue();
      server.json('GET /me/security-events', {'events': [ereignis('e1', DateTime.now().add(const Duration(minutes: 1)))]});
      String? gesetzt;
      await p.pruefenUndMelden(vordergrund: true, hinweis: _MerkHinweis((t) => gesetzt = t));
      expect(gesetzt, startsWith('Sicherheitshinweis:'));
      expect(anzeige.gezeigt, isEmpty);
      // zurücksetzen, damit das Ereignis noch einmal neu ist
      await db.metaSchreiben(kSicherheitSeitSchluessel, DateTime.utc(2020).toIso8601String());
      await p.pruefenUndMelden(vordergrund: false);
      expect(anzeige.gezeigt, hasLength(1));
      final z = anzeige.gezeigt.single;
      expect(z.id, kSicherheitBenachrichtigungsId);
      expect('${z.titel} ${z.text}', isNot(contains('Anna')), reason: 'nie Namen oder Einzelheiten');
      expect(z.sperrbildschirmTitel, isFalse);
    });

    test('Fehler beim Abruf sind kein Fehler der App', () async {
      final (p, server, _, anzeige) = await bauen();
      server.on('GET /me/security-events', (_) => fehler(503, 'server_busy'));
      await p.pruefenUndMelden(vordergrund: false);
      expect(anzeige.gezeigt, isEmpty);
    });
  });

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    group('Passwort vergessen ($s)', () {
      testWidgets('der Link erscheint nur, wenn der Server das Zurücksetzen anbietet', (tester) async {
        final a = await _aufbau(angeboten: false);
        await starteApp(tester, a.env, skala: skala);
        expect(find.text('Passwort vergessen? Neues Passwort festlegen'), findsNothing);
        expect(find.textContaining('Passwort verloren? Mit Wiederherstellungscode anmelden'), findsOneWidget, reason: 'der alte Weg bleibt');
      });

      testWidgets('mit Wiederherstellungscode: nur der authKey geht hinaus, neue Passwort-Sicherung wird angelegt und geprüft, Hinweis erscheint', (tester) async {
        final a = await _aufbau();
        a.server.on('POST /auth/password-reset/recovery', (r) {
          a.srv.passwortZurueckgesetzt(fixIdAdmin);
          return jsonAntwort({'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 9});
        });
        await starteApp(tester, a.env, skala: skala);
        expect(find.text('Passwort vergessen? Neues Passwort festlegen'), findsOneWidget);
        await _zuPasswortVergessen(tester);
        pruefeLayout(tester, 'Passwort vergessen: Formular');
        // der alte Stand der Passwort-Sicherung, damit der Austausch sichtbar wird
        final alterBlob = a.srv.pwStand(fixIdAdmin).blob;
        await _vergessenAusfuellen(tester);
        final anfrage = a.server.anfragen('POST /auth/password-reset/recovery').single.json;
        expect(anfrage.keys.toSet(), {'email', 'code', 'authKey', 'client', 'device'});
        expect(anfrage['authKey'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(anfrage['code'], _wiederherstellung);
        expect(a.alleAnfragen, isNot(contains(_pwNeu)), reason: 'das Passwort verlässt das Gerät nie');
        // angemeldet, Oberfläche steht
        expect(find.byType(NavigationBar), findsOneWidget);
        // neue Sicherung: abgelegt, bestätigt, nicht mehr stale, anderer Blob als zuvor
        final stand = a.srv.pwStand(fixIdAdmin);
        expect(stand.stale, isFalse);
        expect(stand.verifiziert, isTrue);
        expect(stand.blob, isNot(alterBlob));
        expect(a.server.anfragen('PUT /me/key-backup-pw'), hasLength(1));
        expect(a.server.anfragen('POST /me/key-backup-pw/verified'), hasLength(1));
        expect(a.server.anfragen('POST /me/keys'), isEmpty, reason: 'nie ein neuer Personenschlüssel');
        expect(find.textContaining('Passwort-Sicherung ist mit dem neuen Passwort neu angelegt'), findsOneWidget);
        pruefeLayout(tester, 'nach dem Reset');
      });

      testWidgets('ohne Schlüssel auf dem Gerät: keine Sicherung, kein neuer Schlüssel, der Hinweis erklärt den Verlauf', (tester) async {
        final a = await _aufbau(schluessel: false);
        a.server.on('POST /auth/password-reset/recovery', (r) {
          a.srv.passwortZurueckgesetzt(fixIdAdmin);
          return jsonAntwort({'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 2});
        });
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await _vergessenAusfuellen(tester);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(a.server.anfragen('PUT /me/key-backup-pw'), isEmpty);
        expect(a.server.anfragen('POST /me/keys'), isEmpty);
        expect(a.server.anfragen('PUT /me/keys'), isEmpty);
        expect(a.srv.pwStand(fixIdAdmin).stale, isTrue, reason: 'die veraltete Sicherung bleibt (nie gelöscht)');
        expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull, reason: 'kein Schlüssel von selbst');
        expect(find.textContaining('Auf diesem Gerät fehlt dein Schlüssel'), findsOneWidget);
        expect(find.textContaining('von deinen Chat-Partnern freigegeben'), findsOneWidget);
        pruefeLayout(tester, 'ohne Schlüssel');
      });

      testWidgets('ohne frühere Sicherung: nichts wird angelegt, kein Hinweis zur Sicherung', (tester) async {
        final a = await _aufbau(mitSicherung: false);
        a.server.on('POST /auth/password-reset/recovery', (r) => jsonAntwort({'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 9}));
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await _vergessenAusfuellen(tester);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(a.server.anfragen('PUT /me/key-backup-pw'), isEmpty);
        expect(find.textContaining('Passwort-Sicherung'), findsNothing);
      });

      testWidgets('Anlegen der neuen Sicherung scheitert: der Reset gilt trotzdem, der Hinweis nennt den Weg zur Neuanlage', (tester) async {
        final a = await _aufbau();
        a.srv.pwAbrufVerfaelschen = (b) => 'x$b';
        a.server.on('POST /auth/password-reset/recovery', (r) {
          a.srv.passwortZurueckgesetzt(fixIdAdmin);
          return jsonAntwort({'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 9});
        });
        // beim Vorbereiten sind die verfälschten Antworten nur für pending/current relevant: stale wird dennoch erkannt
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await _vergessenAusfuellen(tester);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(a.srv.pwStand(fixIdAdmin).verifiziert, isTrue);
        expect(find.textContaining('konnte nicht angelegt werden'), findsOneWidget);
        expect(a.server.anfragen('POST /me/key-backup-pw/verified'), isEmpty, reason: 'ungeprüfte Sicherung wird nie bestätigt');
      });

      testWidgets('Eingaben werden vor dem Senden geprüft: zu kurz, ungleich, kein Code, schwach', (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await _vergessenAusfuellen(tester, pw: 'kurz1234', pw2: 'kurz1234');
        expect(find.textContaining('mindestens 12 Zeichen'), findsOneWidget);
        await _vergessenAusfuellen(tester, pw2: 'etwas-ganz-anderes-123');
        expect(find.textContaining('nicht gleich'), findsOneWidget);
        await _vergessenAusfuellen(tester, code: '');
        expect(find.textContaining('Wiederherstellungscode ein'), findsWidgets);
        await _vergessenAusfuellen(tester, pw: 'passwortpasswort');
        expect(find.textContaining('zu leicht zu erraten'), findsOneWidget);
        expect(a.server.anfragen('POST /auth/password-reset/recovery'), isEmpty);
        pruefeLayout(tester, 'Eingabefehler');
      });

      testWidgets('falscher Code: die übliche Meldung, nichts ändert sich', (tester) async {
        final a = await _aufbau();
        a.server.on('POST /auth/password-reset/recovery', (_) => fehler(401, 'invalid_credentials', message: 'SERVER-INTERN'));
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await _vergessenAusfuellen(tester);
        expect(find.textContaining('Die Anmeldung hat nicht geklappt'), findsOneWidget);
        expect(find.textContaining('SERVER-INTERN'), findsNothing);
        expect(find.byType(NavigationBar), findsNothing);
        expect(a.server.anfragen('PUT /me/key-backup-pw'), isEmpty);
        pruefeLayout(tester, 'falscher Code');
      });

      testWidgets('mit Passkey: Challenge, Antwort und authKey gehen an den Server', (tester) async {
        final a = await _aufbau();
        a.server
          ..on('POST /auth/login/passkey/options', (_) => jsonAntwort({'challengeId': 'c-1', 'options': webauthnOptionen()}))
          ..on('POST /auth/password-reset/passkey', (r) {
            a.srv.passwortZurueckgesetzt(fixIdAdmin);
            return jsonAntwort({'user': userJson(), 'session': appSession(), 'recoveryCodesRemaining': 10});
          });
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
        await tippeText(tester, 'Passkey');
        await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', _pwNeu);
        await eingeben(tester, 'Passwort wiederholen', _pwNeu);
        await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
        await tester.pump(const Duration(milliseconds: 200));
        await warte(tester, 10);
        final anfrage = a.server.anfragen('POST /auth/password-reset/passkey').single.json;
        expect(anfrage['challengeId'], 'c-1');
        expect(anfrage['email'], 'anna@beispiel.de');
        expect(anfrage['authKey'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect((anfrage['response'] as Map)['id'], 'cred-1');
        expect(anfrage.containsKey('code'), isFalse);
        expect(a.env.passkeys.bestaetigt, 1);
        expect(a.alleAnfragen, isNot(contains(_pwNeu)));
        expect(find.byType(NavigationBar), findsOneWidget);
      });

      testWidgets('Passkey abgebrochen: kein Reset, kein roter Kasten', (tester) async {
        final a = await _aufbau();
        a.env.passkeys.fehler = const PasskeyException(PasskeyFehler.abgebrochen, 'Du hast abgebrochen.');
        a.server.on('POST /auth/login/passkey/options', (_) => jsonAntwort({'challengeId': 'c-1', 'options': webauthnOptionen()}));
        await starteApp(tester, a.env, skala: skala);
        await _zuPasswortVergessen(tester);
        await eingeben(tester, 'E-Mail', 'anna@beispiel.de');
        await tippeText(tester, 'Passkey');
        await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', _pwNeu);
        await eingeben(tester, 'Passwort wiederholen', _pwNeu);
        await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
        await warte(tester, 10);
        expect(a.server.anfragen('POST /auth/password-reset/passkey'), isEmpty);
        expect(find.byType(NavigationBar), findsNothing);
      });
    });

    group('Link des Admins einlösen ($s)', () {
      Map<String, dynamic> lookup({bool pin = false}) => {
        'invite': {
          'role': 'admin',
          'pinRequired': pin,
          'requireApproval': false,
          'familyName': 'Familie Test',
          'reset': true,
          'kind': 'password_reset',
          'displayName': 'Anna',
          'email': 'anna@beispiel.de',
          'expiresAt': DateTime.now().add(const Duration(hours: 20)).toUtc().toIso8601String(),
        },
      };

      Future<void> linkEingeben(WidgetTester tester) async {
        await tippeText(tester, 'Einladung per QR-Code annehmen');
        await eingeben(tester, 'Einladungslink', 'https://familie.lx-labs.dev/#/einladung/$fixToken');
        await tippeText(tester, 'Einladung prüfen');
      }

      testWidgets('Formular ohne Passkey-Auswahl; PIN, Passwort und Authenticator-Code; nur der authKey geht hinaus; neue Sicherung danach', (tester) async {
        final a = await _aufbau();
        a.server
          ..json('POST /auth/invites/lookup', lookup(pin: true))
          ..on('POST /auth/invites/password-reset/start', (_) => jsonAntwort({'challengeId': 'ch-1'}))
          ..on('POST /auth/invites/password-reset/complete', (_) {
            a.srv.passwortZurueckgesetzt(fixIdAdmin);
            return jsonAntwort({'member': userJson(), 'status': 'active', 'recoveryCodes': <String>[], 'session': appSession()});
          });
        await starteApp(tester, a.env, skala: skala);
        await linkEingeben(tester);
        expect(find.text('Neues Passwort für Anna'), findsOneWidget);
        expect(find.text('Passkey'), findsNothing);
        expect(find.textContaining('Code aus deiner Authenticator-App'), findsWidgets);
        pruefeLayout(tester, 'Link: Formular');
        await eingeben(tester, 'PIN der Einladung', '123456');
        await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', _pwNeu);
        await eingeben(tester, 'Passwort wiederholen', _pwNeu);
        await eingeben(tester, 'Code aus der Authenticator-App', '481234');
        await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
        await tester.pump(const Duration(milliseconds: 200));
        await warte(tester, 10);
        final start = a.server.anfragen('POST /auth/invites/password-reset/start').single.json;
        expect(start.keys.toSet(), {'token', 'authKey', 'pin'});
        expect(start['token'], fixToken);
        expect(start['pin'], '123456');
        final fertig = a.server.anfragen('POST /auth/invites/password-reset/complete').single.json;
        expect(fertig['challengeId'], 'ch-1');
        expect(fertig['code'], '481234');
        expect(a.alleAnfragen, isNot(contains(_pwNeu)));
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(a.srv.pwStand(fixIdAdmin).stale, isFalse);
        expect(a.srv.pwStand(fixIdAdmin).verifiziert, isTrue);
        expect(a.server.anfragen('POST /me/keys'), isEmpty);
        expect(find.textContaining('Passwort-Sicherung ist mit dem neuen Passwort neu angelegt'), findsOneWidget);
      });

      testWidgets('falscher Code: Meldung, nichts wird übernommen; ohne gültigen Code geht nichts hinaus', (tester) async {
        final a = await _aufbau();
        a.server
          ..json('POST /auth/invites/lookup', lookup())
          ..on('POST /auth/invites/password-reset/start', (_) => jsonAntwort({'challengeId': 'ch-1'}))
          ..on('POST /auth/invites/password-reset/complete', (_) => fehler(400, 'invalid_code'));
        await starteApp(tester, a.env, skala: skala);
        await linkEingeben(tester);
        await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', _pwNeu);
        await eingeben(tester, 'Passwort wiederholen', _pwNeu);
        await eingeben(tester, 'Code aus der Authenticator-App', '12');
        await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
        expect(find.textContaining('6-stelligen Code'), findsOneWidget);
        expect(a.server.anfragen('POST /auth/invites/password-reset/start'), isEmpty);
        await eingeben(tester, 'Code aus der Authenticator-App', '000000');
        await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
        await warte(tester, 10);
        expect(find.textContaining('Der Code stimmt nicht'), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        pruefeLayout(tester, 'Link: falscher Code');
      });

      testWidgets('Server ohne Angebot (Link kommt ohne E-Mail): verständliche Meldung statt Klartext', (tester) async {
        final a = await _aufbau();
        final l = lookup();
        (l['invite'] as Map).remove('email');
        a.server.json('POST /auth/invites/lookup', l);
        await starteApp(tester, a.env, skala: skala);
        await linkEingeben(tester);
        await eingeben(tester, 'Neues Passwort (mind. 12 Zeichen)', _pwNeu);
        await eingeben(tester, 'Passwort wiederholen', _pwNeu);
        await eingeben(tester, 'Code aus der Authenticator-App', '481234');
        await tippe(tester, find.widgetWithText(FilledButton, 'Neues Passwort festlegen'));
        expect(find.textContaining('gerade nicht eingelöst werden'), findsOneWidget);
        expect(a.server.anfragen('POST /auth/invites/password-reset/start'), isEmpty);
      });
    });

    group('Admin: Passwort zurücksetzen ($s)', () {
      Future<void> zurMitgliederListe(WidgetTester tester) async {
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Mitglieder und Einladungen');
      }

      testWidgets('Aktion im Menü, Erklärung, Link und Hinweis zum Authenticator; Step-up wird verlangt und wiederholt', (tester) async {
        final server = standardServer();
        server.json('GET /version', {'features': {'pwBackup': true, 'authKey': true, 'legacyPasswordLogin': true}});
        var stepUp = false;
        server.on('POST /auth/step-up/code', (_) {
          stepUp = true;
          return jsonAntwort({'stepUpAt': DateTime.now().toUtc().toIso8601String()});
        });
        server.on('POST /members/$fixIdKind/password-reset', (r) => stepUp ? jsonAntwort(neueEinladungJson(pin: false)) : fehler(403, 'step_up_required'));
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await zurMitgliederListe(tester);
        await tippe(tester, find.byTooltip('Aktionen für Ben'));
        expect(find.text('Passwort zurücksetzen'), findsOneWidget);
        expect(find.text('Zugang zurücksetzen'), findsOneWidget, reason: 'der Komplett-Reset bleibt');
        await tippeText(tester, 'Passwort zurücksetzen');
        expect(find.textContaining('Authenticator'), findsWidgets);
        expect(find.textContaining('Du selbst kannst das Konto damit nicht übernehmen'), findsOneWidget);
        pruefeLayout(tester, 'Passwort zurücksetzen: Dialog');
        await tippeText(tester, 'Link erstellen');
        // das Step-up-Fenster: Code eingeben
        await eingeben(tester, 'Code aus der Authenticator-App', '481234');
        await tippeText(tester, 'Mit Code bestätigen');
        await warte(tester, 10);
        expect(server.anfragen('POST /members/$fixIdKind/password-reset'), hasLength(2));
        expect(server.anfragen('POST /members/$fixIdKind/password-reset').last.json, {'hours': 24, 'pin': false});
        expect(find.text('Neues Passwort für Ben'), findsOneWidget);
        expect(find.textContaining('Ohne diesen Code funktioniert der Link nicht'), findsOneWidget);
        pruefeLayout(tester, 'Passwort zurücksetzen: Ergebnis');
      });

      testWidgets('ohne Angebot des Servers fehlt die Aktion, der Komplett-Reset bleibt; Warnung dort nur mit Angebot', (tester) async {
        final env = TestUmgebung(standardServer());
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await zurMitgliederListe(tester);
        await tippe(tester, find.byTooltip('Aktionen für Ben'));
        expect(find.text('Passwort zurücksetzen'), findsNothing);
        expect(find.text('Zugang zurücksetzen'), findsOneWidget);
      });

      testWidgets('für sich selbst gibt es keine Aktion', (tester) async {
        final server = standardServer();
        server.json('GET /version', {'features': {'pwBackup': true, 'authKey': true, 'legacyPasswordLogin': true}});
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await zurMitgliederListe(tester);
        expect(find.byTooltip('Aktionen für Anna'), findsNothing);
      });
    });

    group('Sicherheitsereignisse ($s)', () {
      testWidgets('Liste mit Texten und Zeit, leerer Zustand, Fehler', (tester) async {
        final server = standardServer();
        server.json('GET /me/security-events', {
          'events': [
            {'id': 'e1', 'kind': 'password_reset_done', 'via': 'admin', 'actorName': null, 'byAdmin': true, 'createdAt': '2026-10-21T10:00:00.000Z'},
            {'id': 'e2', 'kind': 'password_reset_requested', 'via': 'admin', 'actorName': 'Anna', 'byAdmin': true, 'createdAt': '2026-10-21T09:00:00.000Z'},
            {'id': 'e3', 'kind': 'password_reset_done', 'via': 'recovery_code', 'actorName': null, 'byAdmin': false, 'createdAt': '2026-10-20T09:00:00.000Z'},
          ],
        });
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Sicherheitsereignisse');
        expect(find.textContaining('mit dem Link eines Admins zurückgesetzt'), findsOneWidget);
        expect(find.textContaining('Anna hat einen Link zum Zurücksetzen deines Passworts erstellt'), findsOneWidget);
        expect(find.textContaining('mit einem Wiederherstellungscode zurückgesetzt'), findsOneWidget);
        pruefeLayout(tester, 'Sicherheitsereignisse');
      });

      testWidgets('leer: freundlicher Hinweis', (tester) async {
        final server = standardServer()..json('GET /me/security-events', {'events': <Object>[]});
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Sicherheitsereignisse');
        expect(find.text('Keine Ereignisse'), findsOneWidget);
        pruefeLayout(tester, 'Sicherheitsereignisse leer');
      });
    });
  }
}

class _MerkHinweis extends ResetHinweisController {
  final void Function(String?) beiSetzen;
  _MerkHinweis(this.beiSetzen);

  @override
  void setzen(String? text) => beiSetzen(text);
}

class _Gezeigt {
  final int id;
  final String titel;
  final String text;
  final bool sperrbildschirmTitel;
  _Gezeigt(this.id, this.titel, this.text, this.sperrbildschirmTitel);
}

class _FakeAnzeige implements ChatAnzeigePort {
  final gezeigt = <_Gezeigt>[];

  @override
  Future<bool> initialisieren() async => true;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async {
    gezeigt.add(_Gezeigt(id, titel, text, sperrbildschirmTitel));
    return true;
  }

  @override
  Future<void> entfernen(int id) async {}
}
