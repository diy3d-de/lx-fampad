// Passwort zurücksetzen (PR 4b): "Passwort vergessen?" mit Wiederherstellungscode und Passkey, Link des Admins einlösen, Admin-Aktion, Sicherheitsereignisse,
// automatische neue Passwort-Sicherung nach dem Reset, Sicherheitshinweis. Layout bei 360 px und Textskala 1.0/1.5. Nie geht das Passwort an den Server.
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
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
    Future<_PruefAufbau> bauen({bool refresh = true, DateTime? accessBis, DateTime Function()? jetzt}) async {
      final server = FakeServer();
      final store = MemoryTokenStore();
      await store.writeTokens(
        StoredTokens(
          accessToken: 'access-1',
          accessExpiresAt: accessBis ?? DateTime.now().add(const Duration(minutes: 15)),
          refreshToken: 'refresh-1',
          refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
          deviceId: fixDevice,
        ),
      );
      final client = ApiClient(client: server.client, store: store, base: 'https://familie.test', refreshErlaubt: refresh);
      final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      addTearDown(db.close);
      final anzeige = _FakeAnzeige();
      final p = SicherheitsPruefer(api: FampadApi(client, geraet: () async => null), db: db, anzeige: anzeige, store: store, jetzt: jetzt);
      return _PruefAufbau(p, server, db, anzeige);
    }

    Map<String, dynamic> ereignis(String id, DateTime zeit, {String kind = 'password_reset_requested'}) =>
        {'id': id, 'kind': kind, 'via': 'admin', 'actorName': 'Anna', 'byAdmin': true, 'createdAt': zeit.toUtc().toIso8601String()};

    test('erster Lauf meldet nichts (Bestand), spätere neue Ereignisse schon; danach nichts mehr', () async {
      final a = await bauen();
      final t0 = DateTime.utc(2026, 10, 20, 8);
      a.server.json('GET /me/security-events', {'events': [ereignis('e1', t0)]});
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, isEmpty);
      a.server.json('GET /me/security-events', {'events': [ereignis('e2', t0.add(const Duration(hours: 1)), kind: 'password_reset_done'), ereignis('e1', t0)]});
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, hasLength(1));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, hasLength(1), reason: 'schon gemeldet');
    });

    test('erster Lauf ohne Bestand: das erste spätere Ereignis zählt', () async {
      final a = await bauen();
      a.server.json('GET /me/security-events', {'events': <Object>[]});
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      a.server.json('GET /me/security-events', {'events': [ereignis('e1', DateTime.now())]});
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, hasLength(1));
    });

    test('Vordergrund: Hinweis in der Oberfläche; Hintergrund: feste Benachrichtigung auf dem eigenen Kanal ohne Einzelheiten', () async {
      final a = await bauen();
      a.server.json('GET /me/security-events', {'events': <Object>[]});
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      a.server.json('GET /me/security-events', {'events': [ereignis('e1', DateTime.now().add(const Duration(minutes: 1)))]});
      String? gesetzt;
      await a.pruefer.pruefenUndMelden(vordergrund: true, hinweis: _MerkHinweis((t) => gesetzt = t));
      expect(gesetzt, startsWith('Sicherheitshinweis:'));
      expect(a.anzeige.sicherheit, isEmpty);
      await a.db.metaSchreiben(kSicherheitSeitSchluessel, DateTime.utc(2020).toIso8601String());
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, hasLength(1));
      expect(a.anzeige.gezeigt, isEmpty, reason: 'nie der Chat-Kanal');
      final z = a.anzeige.sicherheit.single;
      expect(z.id, kSicherheitBenachrichtigungsId);
      expect('${z.titel} ${z.text}', isNot(contains('Anna')), reason: 'nie Namen oder Einzelheiten');
    });

    test('Anzeige nicht möglich (keine Erlaubnis): der Stand bleibt, der Start der App holt es nach', () async {
      final a = await bauen();
      a.server.json('GET /me/security-events', {'events': <Object>[]});
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      final vorher = await a.db.metaLesen(kSicherheitSeitSchluessel);
      a.server.json('GET /me/security-events', {'events': [ereignis('e1', DateTime.now().add(const Duration(minutes: 1)))]});
      a.anzeige.erlaubt = false;
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(await a.db.metaLesen(kSicherheitSeitSchluessel), vorher);
      // Plugin meldet "nicht angezeigt" trotz Erlaubnis
      a.anzeige
        ..erlaubt = true
        ..sicherheitGelingt = false;
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(await a.db.metaLesen(kSicherheitSeitSchluessel), vorher);
      // der nächste Start im Vordergrund holt es nach
      String? gesetzt;
      await a.pruefer.pruefenUndMelden(vordergrund: true, hinweis: _MerkHinweis((t) => gesetzt = t));
      expect(gesetzt, isNotNull);
      expect(await a.db.metaLesen(kSicherheitSeitSchluessel), isNot(vorher));
    });

    test('Weckrufe prüfen höchstens alle fünf Minuten, der Start der App immer', () async {
      var jetzt = DateTime.utc(2026, 10, 21, 10);
      final a = await bauen(jetzt: () => jetzt);
      a.server.json('GET /me/security-events', {'events': <Object>[]});
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kSicherheitMindestabstand);
      expect(a.server.anfragen('GET /me/security-events'), hasLength(1));
      jetzt = jetzt.add(const Duration(minutes: 2));
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kSicherheitMindestabstand);
      expect(a.server.anfragen('GET /me/security-events'), hasLength(1), reason: 'zu früh');
      await a.pruefer.pruefenUndMelden(vordergrund: true);
      expect(a.server.anfragen('GET /me/security-events'), hasLength(2), reason: 'der Start der App prüft immer');
      jetzt = jetzt.add(const Duration(minutes: 6));
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kSicherheitMindestabstand);
      expect(a.server.anfragen('GET /me/security-events'), hasLength(3));
    });

    test('Sitzung widerrufen (401 trotz gültigem Zugangstoken): feste Meldung "Du wurdest abgemeldet" und Hinweis für das nächste Anmelden', () async {
      final a = await bauen(refresh: false);
      a.server.on('GET /me/security-events', (_) => fehler(401, 'invalid_token'));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, hasLength(1));
      final z = a.anzeige.sicherheit.single;
      expect(z.id, kSicherheitAbgemeldetBenachrichtigungsId);
      expect(z.titel, 'Du wurdest abgemeldet');
      expect(z.text, contains('Dein Passwort wurde zurückgesetzt'));
      expect(z.text, contains('Wiederherstellungscode'));
      expect(await a.db.metaLesen(kSicherheitAbgemeldetSchluessel), '1');
      // die Person setzt selbst zurück: der Hinweis ist dann nichts Neues
      await a.pruefer.hinweisAbgemeldetLoeschen();
      expect(await a.db.metaLesen(kSicherheitAbgemeldetSchluessel), isNull);
    });

    test('abgelaufenes Zugangstoken im Hintergrund ist KEIN Widerruf: keine Meldung, kein Hinweis', () async {
      final a = await bauen(refresh: false, accessBis: DateTime.now().subtract(const Duration(minutes: 1)));
      a.server.on('GET /me/security-events', (_) => fehler(401, 'invalid_token'));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, isEmpty);
      expect(await a.db.metaLesen(kSicherheitAbgemeldetSchluessel), isNull);
      expect(a.server.anfragen('GET /me/security-events'), isEmpty, reason: 'die Anfrage ging nie hinaus');
    });

    test('Serverfehler ist kein Widerruf', () async {
      final a = await bauen(refresh: false);
      a.server.on('GET /me/security-events', (_) => fehler(503, 'server_busy'));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.sicherheit, isEmpty);
      expect(await a.db.metaLesen(kSicherheitAbgemeldetSchluessel), isNull);
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
        // ehrlich: kein pauschales "bleibt erhalten"
        expect(find.textContaining('Dein Verlauf bleibt erhalten, wenn du ein Gerät mit deinem Schlüssel oder deinen Wiederherstellungsschlüssel hast'), findsOneWidget);
        expect(find.textContaining('Dein Chat-Verlauf bleibt erhalten'), findsNothing);
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
        // ehrlich: der Verlauf bleibt nicht pauschal, sondern nur mit einem Gerät mit dem Schlüssel oder dem Wiederherstellungsschlüssel
        expect(find.textContaining('Der Chat-Verlauf bleibt nur erhalten, wenn Ben ein Gerät mit dem eigenen Schlüssel oder den Wiederherstellungsschlüssel hat'), findsOneWidget);
        expect(find.textContaining('Wiederherstellungscodes und der Chat-Verlauf bleiben'), findsNothing);
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

    group('Veraltete Sicherung, Hinweise ($s)', () {
      /// Angemeldete App; Anna hat eine Passwort-Sicherung, die ein Reset veraltet hat.
      Future<_Aufbau> veraltet({bool schluessel = true}) async {
        final a = await _aufbau(schluessel: schluessel);
        await a.env.angemeldet();
        a.srv.passwortZurueckgesetzt(fixIdAdmin);
        return a;
      }

      Future<void> zurVerschluesselung(WidgetTester tester) async {
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Verschlüsselung');
      }

      testWidgets('mit Schlüssel auf dem Gerät: "Sicherung erneuern" wird angeboten, erklärt den Grund und legt mit einem Passwort neu an', (tester) async {
        final a = await veraltet();
        await starteApp(tester, a.env, skala: skala);
        await zurVerschluesselung(tester);
        expect(find.textContaining('veraltet nach Passwort-Reset · Sicherung erneuern'), findsOneWidget);
        pruefeLayout(tester, 'Verschlüsselung: Sicherung erneuern');
        await tippeText(tester, 'Passwort-Sicherung');
        expect(find.textContaining('Dein Passwort wurde zurückgesetzt, deshalb ist die bisherige Passwort-Sicherung veraltet'), findsOneWidget);
        await eingeben(tester, 'Passwort (mind. 12 Zeichen)', _pwNeu);
        await eingeben(tester, 'Passwort wiederholen', _pwNeu);
        await tippe(tester, find.widgetWithText(FilledButton, 'Sicherung anlegen und prüfen'));
        await tester.pump(const Duration(milliseconds: 200));
        await warte(tester, 10);
        expect(a.srv.pwStand(fixIdAdmin).stale, isFalse);
        expect(a.srv.pwStand(fixIdAdmin).verifiziert, isTrue);
        expect(a.server.anfragen('POST /me/keys'), isEmpty);
        expect(a.alleAnfragen, isNot(contains(_pwNeu)));
      });

      testWidgets('ohne Schlüssel auf dem Gerät gibt es kein "Sicherung erneuern"; "Mit Passwort verbinden" erklärt die alte Sicherung statt eines "früheren Schlüssels"', (tester) async {
        final a = await veraltet(schluessel: false);
        await starteApp(tester, a.env, skala: skala);
        await zurVerschluesselung(tester);
        expect(find.textContaining('Sicherung erneuern'), findsNothing);
        await tippeText(tester, 'Mit Passwort verbinden');
        await eingeben(tester, 'Passwort der Sicherung', _pwNeu);
        await tippe(tester, find.widgetWithText(FilledButton, 'Verbinden'));
        await warte(tester, 10);
        expect(find.textContaining('Deine alte Passwort-Sicherung funktioniert noch'), findsOneWidget);
        expect(find.textContaining('früheren Schlüssel'), findsNothing);
        expect(await a.speicher.lesen(personenschluesselName(fixIdAdmin)), isNull);
        pruefeLayout(tester, 'Mit Passwort verbinden: veraltet nach Reset');
      });

      testWidgets('Anmeldeseite: der dauerhafte Hinweis "abgemeldet" bleibt, bis er bestätigt ist', (tester) async {
        final a = await _aufbau();
        await a.env.db.metaSchreiben(kSicherheitAbgemeldetSchluessel, '1');
        await starteApp(tester, a.env, skala: skala);
        expect(find.textContaining('Du wurdest abgemeldet, weil dein Passwort zurückgesetzt wurde'), findsOneWidget);
        pruefeLayout(tester, 'Anmeldeseite mit Hinweis');
        await tippeText(tester, 'Verstanden');
        expect(find.textContaining('Du wurdest abgemeldet'), findsNothing);
        expect(await a.env.db.metaLesen(kSicherheitAbgemeldetSchluessel), isNull);
      });

      testWidgets('nach dem Anmelden: ein Dialog (kein flüchtiger Hinweis), der bis zur Bestätigung stehen bleibt', (tester) async {
        final a = await _aufbau();
        await a.env.angemeldet();
        await a.env.db.metaSchreiben(kSicherheitAbgemeldetSchluessel, '1');
        await starteApp(tester, a.env, skala: skala);
        await warte(tester, 10);
        expect(find.text('Dein Passwort wurde zurückgesetzt'), findsOneWidget);
        await tester.pump(const Duration(seconds: 30));
        expect(find.text('Dein Passwort wurde zurückgesetzt'), findsOneWidget, reason: 'bleibt stehen');
        pruefeLayout(tester, 'Dialog nach dem Anmelden');
        await tippeText(tester, 'Verstanden');
        expect(find.text('Dein Passwort wurde zurückgesetzt'), findsNothing);
        expect(await a.env.db.metaLesen(kSicherheitAbgemeldetSchluessel), isNull);
      });

      testWidgets('Einladungsliste: Link "neues passwort" trägt eine eigene Pille', (tester) async {
        final server = standardServer();
        server.json('GET /invites', {
          'invites': [
            {...einladungJson(id: 'i9', role: 'parent', reset: true), 'kind': 'password_reset'},
            einladungJson(id: 'i8', role: 'parent', reset: true),
          ],
        });
        final env = TestUmgebung(server);
        await env.angemeldet();
        await starteApp(tester, env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Mitglieder und Einladungen');
        await tippeText(tester, 'Einladungen');
        expect(find.text('neues passwort'), findsOneWidget);
        expect(find.text('zurücksetzen'), findsOneWidget);
        pruefeLayout(tester, 'Einladungsliste');
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

class _PruefAufbau {
  final SicherheitsPruefer pruefer;
  final FakeServer server;
  final AppDatabase db;
  final _FakeAnzeige anzeige;
  _PruefAufbau(this.pruefer, this.server, this.db, this.anzeige);
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
  final sicherheit = <_Gezeigt>[];
  bool erlaubt = true;
  bool sicherheitGelingt = true;

  @override
  Future<bool> initialisieren() async => erlaubt;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async {
    gezeigt.add(_Gezeigt(id, titel, text, sperrbildschirmTitel));
    return true;
  }

  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text}) async {
    if (!sicherheitGelingt) return false;
    sicherheit.add(_Gezeigt(id, titel, text, false));
    return true;
  }

  @override
  Future<void> entfernen(int id) async {}
}
