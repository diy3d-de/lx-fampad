// Abläufe der Verschlüsselung gegen einen In-Memory-Server mit mehreren Personen und Geräten: Einrichtung, Wiederherstellung, Übertragung
// (Einmaligkeit, Ablauf, fremde Person), Schlüsselwechsel, Warnung bei fremdem Schlüsselwechsel, Wiper.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/sicherheitscode.dart';
import 'package:lx_fampad/data/crypto/wiederherstellung.dart';

import '../support/fake_crypto.dart';
import '../support/fake_e2ee_server.dart';
import '../support/fake_server.dart';
import '../support/test_app.dart';

const _anna = '11111111-1111-4111-8111-111111111111';
const _ben = '22222222-2222-4222-8222-222222222222';
const _cora = '33333333-3333-4333-8333-333333333333';

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user);
}

/// Ein Gerät: eigener Schlüsselspeicher, Anmeldung als [id].
class _Geraet {
  final ProviderContainer c;
  final MemorySchluesselSpeicher speicher;
  _Geraet(this.c, this.speicher);
  E2eeController get ctrl => c.read(e2eeProvider.notifier);
  E2eeState get s => c.read(e2eeProvider);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('E2EE-Abläufe ($name)', () {
      late FakeServer fake;
      late FakeE2eeServer srv;
      final geraete = <_Geraet>[];

      Future<_Geraet> geraet(String id, String anzeige, {bool ohneSodium = false, MemorySchluesselSpeicher? eigenerSpeicher}) async {
        final env = TestUmgebung(fake, store: MemoryTokenStore());
        await env.store.writeTokens(
          StoredTokens(
            accessToken: 'access-$id',
            accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
            refreshToken: 'refresh-$id',
            refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
            deviceId: fixDevice,
          ),
        );
        final speicher = eigenerSpeicher ?? MemorySchluesselSpeicher();
        env.extraOverrides.addAll([
          cryptoProviderProvider.overrideWith((ref) async => ohneSodium ? throw const CryptoFehler(CryptoFehlerArt.bibliothek, 'nicht verfügbar') : crypto),
          schluesselSpeicherProvider.overrideWithValue(speicher),
          authProvider.overrideWith(() => _FesterAuth(UserDto.fromJson(userJson(id: id, name: anzeige, email: null)))),
        ]);
        final c = env.container();
        addTearDown(c.dispose);
        addTearDown(env.db.close);
        c.read(authProvider); // Anmeldezustand bereitstellen
        final g = _Geraet(c, speicher);
        geraete.add(g);
        await g.ctrl.laden();
        return g;
      }

      setUp(() {
        fake = FakeServer();
        srv = FakeE2eeServer(fake)
          ..person(_anna, 'Anna')
          ..person(_ben, 'Ben')
          ..person(_cora, 'Cora');
        geraete.clear();
      });

      test('Einrichtung: Schlüssel entsteht auf dem Gerät, der Server sieht nur öffentliche Schlüssel und die opake Sicherung', () async {
        final a = await geraet(_anna, 'Anna');
        expect(a.s.status, E2eeStatus.keinSchluessel);
        final einr = await a.ctrl.einrichten();
        expect(a.s.status, E2eeStatus.bereit);
        expect(a.s.hatSicherung, isFalse, reason: 'erst nach Bestätigung des Wiederherstellungsschlüssels');
        expect(a.s.serverSchluessel!.version, 1);
        await a.ctrl.sicherungAblegen(einr);
        expect(a.s.hatSicherung, isTrue);

        final geheim = a.ctrl.lokalerSchluessel!.exportieren();
        final serverText = srv.gespeichert(_anna);
        for (final teil in [geheim.sublist(0, 32), geheim.sublist(32), einr.wiederherstellungsschluessel]) {
          expect(serverText.contains(base64urlKodieren(teil)), isFalse);
        }
        expect(await a.speicher.lesen(personenschluesselName(_anna)), geheim, reason: 'liegt im Schlüsselspeicher des Geräts');
      });

      test('Einrichtung scheitert am Server: nichts bleibt lokal zurück', () async {
        final a = await geraet(_anna, 'Anna');
        fake.on('POST /me/keys', (_) => fehler(500, 'internal_error'));
        await expectLater(a.ctrl.einrichten(), throwsA(isA<ApiException>()));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNull);
        expect(a.ctrl.lokalerSchluessel, isNull);
      });

      test('Wiederherstellung auf einem zweiten Gerät: richtiger Schlüssel', () async {
        final a = await geraet(_anna, 'Anna');
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        final b = await geraet(_anna, 'Anna');
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel!.exportieren(), a.ctrl.lokalerSchluessel!.exportieren());
      });

      test('Wiederherstellung: falscher Schlüssel scheitert, Tippfehler schon vor dem Netzwerk', () async {
        final a = await geraet(_anna, 'Anna');
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        final b = await geraet(_anna, 'Anna');
        final falsch = Wiederherstellung.anzeigen(Wiederherstellung.neuerSchluessel(crypto));
        await expectLater(
          b.ctrl.mitWiederherstellungVerbinden(falsch),
          throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', CryptoFehlerArt.entschluesselung)),
        );
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        final abrufeVorher = srv.anfragen('GET /me/key-backup');
        final tippfehler = Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel).replaceFirst(RegExp('[A-Z]'), 'x');
        final original = Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel);
        if (tippfehler.toUpperCase() != original) {
          await expectLater(b.ctrl.mitWiederherstellungVerbinden(tippfehler), throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', CryptoFehlerArt.pruefsumme)));
        }
        expect(srv.anfragen('GET /me/key-backup'), abrufeVorher);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
      });

      test('Abruf der Sicherung verlangt Step-up: ApiException mit Step-up-Kennzeichen, danach klappt es', () async {
        final a = await geraet(_anna, 'Anna');
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        final b = await geraet(_anna, 'Anna');
        srv.stepUpNoetig = true;
        final code = Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel);
        await expectLater(b.ctrl.mitWiederherstellungVerbinden(code), throwsA(isA<ApiException>().having((e) => e.istStepUp, 'istStepUp', isTrue)));
        srv.stepUpNoetig = false;
        await b.ctrl.mitWiederherstellungVerbinden(code);
        expect(b.s.status, E2eeStatus.bereit);
      });

      test('Übertragung per QR: neues Gerät übernimmt den Schlüssel; zweites Einlösen scheitert (einmalig)', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final b = await geraet(_anna, 'Anna');
        final anzeige = await a.ctrl.uebertragungAnbieten();
        expect(anzeige.qrText, startsWith('LXK1:'));
        await b.ctrl.uebertragungAnnehmen(anzeige.qrText);
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel!.exportieren(), a.ctrl.lokalerSchluessel!.exportieren());
        final c3 = await geraet(_anna, 'Anna');
        await expectLater(c3.ctrl.uebertragungAnnehmen(anzeige.codeText), throwsA(isA<CryptoFehler>()));
        expect(c3.s.status, E2eeStatus.geraetNichtVerbunden);
        // der Server sah weder Geheimnis noch Schlüssel
        expect(srv.gespeichert(_anna).contains(anzeige.qrText.substring(5)), isFalse);
      });

      test('Übertragung per abgetipptem Code (Kleinschreibung, Leerzeichen)', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final b = await geraet(_anna, 'Anna');
        final anzeige = await a.ctrl.uebertragungAnbieten();
        await b.ctrl.uebertragungAnnehmen(anzeige.codeText.toLowerCase().replaceAll('-', ' '));
        expect(b.s.status, E2eeStatus.bereit);
      });

      test('Übertragung läuft nach 2 Minuten ab', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final b = await geraet(_anna, 'Anna');
        final anzeige = await a.ctrl.uebertragungAnbieten();
        srv.jetzt = srv.jetzt.add(const Duration(seconds: 121));
        await expectLater(b.ctrl.uebertragungAnnehmen(anzeige.qrText), throwsA(isA<CryptoFehler>()));
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
      });

      test('Übertragung: eine fremde Person kann den Code nicht einlösen (auch nicht, wenn sie ihn kennt)', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        final bens2 = await geraet(_ben, 'Ben');
        final anzeige = await a.ctrl.uebertragungAnbieten();
        await expectLater(bens2.ctrl.uebertragungAnnehmen(anzeige.qrText), throwsA(isA<CryptoFehler>()));
        expect(bens2.s.status, E2eeStatus.geraetNichtVerbunden);
        // der Code bleibt für Anna einlösbar
        final b = await geraet(_anna, 'Anna');
        await b.ctrl.uebertragungAnnehmen(anzeige.qrText);
        expect(b.s.status, E2eeStatus.bereit);
      });

      test('Übertragung anbieten: nur mit passendem Schlüssel auf diesem Gerät', () async {
        final a = await geraet(_anna, 'Anna');
        await expectLater(a.ctrl.uebertragungAnbieten(), throwsA(isA<CryptoFehler>()));
        final b = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        await b.ctrl.laden();
        await expectLater(b.ctrl.uebertragungAnbieten(), throwsA(isA<CryptoFehler>()), reason: 'b hat den Schlüssel nicht');
      });

      test('Schlüsselwechsel: Version steigt, andere Geräte sehen "weicht ab" und müssen neu verbinden', () async {
        final a = await geraet(_anna, 'Anna');
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        final b = await geraet(_anna, 'Anna');
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
        final altOeffentlich = a.ctrl.lokalerSchluessel!.encOeffentlich;

        final neu = await a.ctrl.schluesselWechseln();
        expect(neu.keyVersion, 2);
        expect(a.s.serverSchluessel!.version, 2);
        expect(a.s.hatSicherung, isFalse, reason: 'Sicherung gehörte zum alten Schlüssel');
        expect(a.ctrl.lokalerSchluessel!.encOeffentlich, isNot(altOeffentlich));

        await b.ctrl.laden();
        expect(b.s.status, E2eeStatus.abweichend);
        await b.ctrl.lokalenSchluesselVerwerfen();
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
      });

      test('Schlüsselwechsel scheitert (Step-up fehlt): der alte Schlüssel bleibt lokal erhalten', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.exportieren();
        srv.stepUpNoetig = true;
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<ApiException>()));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), alt);
        expect(a.ctrl.lokalerSchluessel!.exportieren(), alt);
      });

      test('Warnung bei fremdem Schlüsselwechsel (TOFU): erst nach Bestätigung vertraut', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        expect(a.s.warnungen, isEmpty, reason: 'erster Schlüssel von Ben wird gemerkt');
        final codeVorher = a.s.sicherheitscode;
        expect(codeVorher, isNotEmpty);

        await ben.ctrl.schluesselWechseln();
        await a.ctrl.laden();
        expect(a.s.warnungen.map((w) => w.userId), [_ben]);
        expect(a.s.sicherheitscode, isNot(codeVorher), reason: 'Sicherheitscode ändert sich mit dem Schlüssel');
        await a.ctrl.laden();
        expect(a.s.warnungen, hasLength(1), reason: 'bleibt bestehen, bis jemand bestätigt');

        await a.ctrl.warnungAkzeptieren(_ben);
        expect(a.s.warnungen, isEmpty);
      });

      test('Mitglieder erscheinen mit öffentlichen Schlüsseln; Personen ohne Schlüssel ohne', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final mitglieder = {for (final m in a.s.mitglieder) m.displayName: m};
        expect(mitglieder['Anna']!.schluessel, isNotNull);
        expect(mitglieder['Ben']!.schluessel, isNull);
        expect(mitglieder, hasLength(3));
      });

      test('Wiper entfernt den geheimen Schlüssel, die gemerkten öffentlichen Schlüssel bleiben', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull);
        final wiper = Provider<Future<void> Function()>(e2eeDatenWiper);
        await a.c.read(wiper)();
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNull);
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull);
        expect(a.s.status, E2eeStatus.laedt, reason: 'Zustand der bisherigen Person ist verworfen');
        expect(a.ctrl.lokalerSchluessel, isNull);
      });

      test('libsodium nicht verfügbar: Status "nicht verfügbar" mit Meldung statt Absturz', () async {
        final a = await geraet(_anna, 'Anna', ohneSodium: true);
        expect(a.s.status, E2eeStatus.nichtVerfuegbar);
        expect(a.s.meldung, isNotEmpty);
        await expectLater(a.ctrl.einrichten(), throwsA(isA<CryptoFehler>()));
        expect(fake.anfragen('POST /me/keys'), isEmpty);
      });

      test('Einrichtung: Antwort geht nach dem Speichern verloren (Netzfehler): Schlüssel bleibt, Status bereit', () async {
        final a = await geraet(_anna, 'Anna');
        srv.verliereAntwort.add('POST /me/keys');
        await a.ctrl.einrichten();
        expect(a.s.status, E2eeStatus.bereit);
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNotNull);
      });

      test('Einrichtung: Netzfehler VOR dem Speichern: nichts bleibt lokal zurück', () async {
        final a = await geraet(_anna, 'Anna');
        fake.on('POST /me/keys', (_) => throw http.ClientException('weg'));
        await expectLater(a.ctrl.einrichten(), throwsA(isA<ApiException>()));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNull);
        expect(a.ctrl.lokalerSchluessel, isNull);
      });

      test('Schlüsselwechsel: sendet die frisch erfragte Version; Antwort geht verloren: der neue Schlüssel bleibt, Zwischenstand weg', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.encOeffentlich;
        srv.verliereAntwort.add('PUT /me/keys');
        final neu = await a.ctrl.schluesselWechseln();
        expect(neu.keyVersion, 2);
        expect(fake.anfragen('PUT /me/keys').single.json['expectedKeyVersion'], 1);
        expect(a.s.status, E2eeStatus.bereit);
        expect(a.ctrl.lokalerSchluessel!.encOeffentlich, isNot(alt));
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
      });

      test('Schlüsselwechsel: Netzfehler vor dem Speichern beim Server: der alte Schlüssel gilt weiter', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.exportieren();
        fake.on('PUT /me/keys', (_) => throw http.ClientException('weg'));
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<ApiException>()));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), alt);
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
        expect(a.s.status, E2eeStatus.bereit);
      });

      test('Schlüsselwechsel: Server meldet 409 (anderes Gerät war schneller): alter Schlüssel bleibt, nichts wird überschrieben', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.exportieren();
        fake.on('PUT /me/keys', (_) => fehler(409, 'key_version_mismatch'));
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 409)));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), alt);
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
      });

      test('Schlüsselwechsel mit unklarem Ausgang (auch die Nachfrage scheitert): nichts geht verloren, das nächste Laden klärt es', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.exportieren();
        final getKeys = fake.routes['GET /me/keys']!;
        // Fall A: der Server hat gespeichert, Antwort und Nachfrage gehen verloren
        srv.verliereAntwort.add('PUT /me/keys');
        // die Nachfrage nach dem Absenden scheitert (davor klappt der frische Abruf der Version)
        fake.on('GET /me/keys', (r) async {
          if (srv.anfragen('PUT /me/keys') > 0) throw http.ClientException('weg');
          return getKeys(r);
        });
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<CryptoFehler>()));
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), alt, reason: 'der alte Schlüssel bleibt als Zwischenstand');
        final neuLokal = await a.speicher.lesen(personenschluesselName(_anna));
        expect(neuLokal, isNot(alt));
        fake.routes['GET /me/keys'] = getKeys;
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.bereit, reason: 'Server hat den neuen Schlüssel: der Zwischenstand ist erledigt');
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
        expect(await a.speicher.lesen(personenschluesselName(_anna)), neuLokal);
      });

      test('Zwischenstand: Wechsel kam beim Server nie an, dann gilt beim nächsten Laden wieder der alte Schlüssel', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.exportieren();
        final getKeys = fake.routes['GET /me/keys']!;
        fake.on('PUT /me/keys', (_) => throw http.ClientException('weg'));
        var erster = true;
        fake.on('GET /me/keys', (r) async {
          if (erster) {
            erster = false;
            return getKeys(r);
          }
          throw http.ClientException('weg');
        });
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<CryptoFehler>()));
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), alt);
        fake.routes['GET /me/keys'] = getKeys;
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.bereit);
        expect(a.ctrl.lokalerSchluessel!.exportieren(), alt);
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
      });

      test('Übertragung anbieten: Version geht mit; ein anderes Gerät hat inzwischen gewechselt: kein Angebot', () async {
        final a = await geraet(_anna, 'Anna');
        final b = await geraet(_anna, 'Anna');
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
        await a.ctrl.uebertragungAnbieten();
        expect(fake.anfragen('POST /me/key-transfer').last.json['keyVersion'], 1);
        await b.ctrl.schluesselWechseln();
        final vorher = fake.anfragen('POST /me/key-transfer').length;
        await expectLater(a.ctrl.uebertragungAnbieten(), throwsA(isA<CryptoFehler>()));
        expect(fake.anfragen('POST /me/key-transfer').length, vorher);
      });

      test('Speicherfehler beim Lesen: vorübergehend lässt den Schlüssel liegen, dauerhaft entfernt ihn', () async {
        final speicher = _WackligerSpeicher();
        final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
        await a.ctrl.einrichten();
        final bytes = await speicher.lesen(personenschluesselName(_anna));
        speicher.fehler = const SchluesselSpeicherFehler('Keystore gesperrt', dauerhaft: false);
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.nichtVerfuegbar);
        speicher.fehler = null;
        expect(await speicher.lesen(personenschluesselName(_anna)), bytes, reason: 'vorübergehender Fehler: nichts gelöscht');
        speicher.fehler = const SchluesselSpeicherFehler('Entschlüsselung gescheitert', dauerhaft: true);
        await a.ctrl.laden();
        speicher.fehler = null;
        expect(a.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await speicher.lesen(personenschluesselName(_anna)), isNull, reason: 'dauerhaft unbrauchbar: entfernt');
      });

      test('TOFU-Einträge entfernter Mitglieder verschwinden beim Abgleich', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull);
        expect(utf8.decode((await a.speicher.lesen('e2ee.vertrauen.$_anna'))!), contains(_ben));
        srv.entferne(_ben);
        await a.ctrl.laden();
        expect(utf8.decode((await a.speicher.lesen('e2ee.vertrauen.$_anna'))!), isNot(contains(_ben)));
      });

      test('Sicherheitscode nur aus aktiven Mitgliedern (wartende zählen nicht)', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        final mitBen = a.s.sicherheitscode;
        srv.ausstehend.add(_ben);
        await a.ctrl.laden();
        final annasSchluessel = a.s.mitglieder.firstWhere((m) => m.id == _anna).schluessel!;
        expect(a.s.sicherheitscode, familienSicherheitscode([MitgliedSchluessel(_anna, annasSchluessel)]));
        expect(a.s.sicherheitscode, isNot(mitBen));
      });

      test('Absender-Schlüssel nach Rotation: gemerkte Version, ältere aus der Historie, neuere erst nach Bestätigung', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        final v1 = ben.ctrl.lokalerSchluessel!.oeffentlich(1);
        await a.ctrl.einrichten(); // merkt Bens Version 1
        expect((await a.ctrl.absenderSchluessel(_ben, 1)).gleichWie(v1), isTrue);
        await ben.ctrl.schluesselWechseln();
        await a.ctrl.laden(); // Warnung, Version 2 ist noch nicht akzeptiert
        await expectLater(a.ctrl.absenderSchluessel(_ben, 2), throwsA(isA<CryptoFehler>()));
        expect((await a.ctrl.absenderSchluessel(_ben, 1)).gleichWie(v1), isTrue, reason: 'alte Signaturen bleiben prüfbar');
        await a.ctrl.warnungAkzeptieren(_ben);
        final v2 = await a.ctrl.absenderSchluessel(_ben, 2);
        expect(v2.version, 2);
        final v1Historie = await a.ctrl.absenderSchluessel(_ben, 1);
        expect(v1Historie.gleichWie(v1), isTrue, reason: 'Version 1 kommt jetzt aus der Historie des Servers');
        await expectLater(a.ctrl.absenderSchluessel(_ben, 9), throwsA(isA<CryptoFehler>()), reason: 'neuer als der gemerkte Schlüssel');
        await expectLater(a.ctrl.absenderSchluessel(_cora, 1), throwsA(isA<ApiException>()), reason: 'Version unbekannt: 404 vom Server');
      });

      test('Wiper: ein Fehler des Datenbank-Wipers verhindert nie das Löschen des Schlüssels; der erste Fehler wird danach geworfen', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final schluesselWiper = a.c.read(Provider<Future<void> Function()>(e2eeDatenWiper));
        var datenLief = false;
        final verkettet = wiperVerkettet([
          () async => throw StateError('Datenbank defekt'),
          () async => datenLief = true,
          schluesselWiper,
        ]);
        await expectLater(verkettet(), throwsA(isA<StateError>()));
        expect(datenLief, isTrue);
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNull, reason: 'Schlüssel ist trotz des Fehlers weg');
      });

      test('Wiper: scheitert das Löschen des Schlüssels, laufen die anderen trotzdem, und der Zustand wird verworfen', () async {
        final speicher = _WackligerSpeicher();
        final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
        await a.ctrl.einrichten();
        speicher.loeschFehler = true;
        var datenLief = false;
        final verkettet = wiperVerkettet([a.c.read(Provider<Future<void> Function()>(e2eeDatenWiper)), () async => datenLief = true]);
        await expectLater(verkettet(), throwsA(isA<StateError>()));
        expect(datenLief, isTrue);
        expect(a.s.status, E2eeStatus.laedt, reason: 'Zustand der bisherigen Person ist verworfen');
      });

      test('kein Schlüsselmaterial in den Antworttexten der Fehler', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final geheim = base64urlKodieren(a.ctrl.lokalerSchluessel!.exportieren());
        for (final r in fake.log) {
          expect(jsonEncode(r.body ?? {}).contains(geheim), isFalse, reason: '${r.key} darf den geheimen Schlüssel nie senden');
        }
        expect(Uint8List.fromList(utf8.encode(srv.gespeichert(_anna))).length, greaterThan(0));
      });
    });
  }
}

/// Schlüsselspeicher mit steuerbaren Fehlern (Lesen, Löschen).
class _WackligerSpeicher extends MemorySchluesselSpeicher {
  SchluesselSpeicherFehler? fehler;
  bool loeschFehler = false;

  @override
  Future<Uint8List?> lesen(String name) async {
    if (fehler != null && name.startsWith('e2ee.pk.')) throw fehler!;
    return super.lesen(name);
  }

  @override
  Future<void> loescheMitPraefix(String praefix) async {
    if (loeschFehler) throw StateError('Löschen fehlgeschlagen');
    return super.loescheMitPraefix(praefix);
  }
}
