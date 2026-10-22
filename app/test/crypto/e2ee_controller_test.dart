// Abläufe der Verschlüsselung gegen einen In-Memory-Server mit mehreren Personen und Geräten: Einrichtung, Wiederherstellung, Übertragung
// (Einmaligkeit, Ablauf, fremde Person), Schlüsselwechsel, Warnung bei fremdem Schlüsselwechsel, Wiper.
import 'dart:async';
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

/// Wie [_FesterAuth], aber das Abmelden scheitert (Web: Serverfehler; die Sitzung gilt weiter).
class _AuthAbmeldenScheitert extends _FesterAuth {
  _AuthAbmeldenScheitert(super.user);
  @override
  Future<AbmeldeErgebnis> abmelden({bool ueberall = false, bool nurLokal = false}) async =>
      throw const ApiException(kind: ApiErrorKind.netzwerk, status: 0, code: 'netzwerk', message: 'Keine Verbindung');
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

      Future<_Geraet> geraet(String id, String anzeige, {bool ohneSodium = false, MemorySchluesselSpeicher? eigenerSpeicher, bool abmeldenScheitert = false, bool wiperFehler = false}) async {
        final env = TestUmgebung(fake, store: MemoryTokenStore())..wiperFehler = wiperFehler;
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
          authProvider.overrideWith(() {
            final u = UserDto.fromJson(userJson(id: id, name: anzeige, email: null));
            return abmeldenScheitert ? _AuthAbmeldenScheitert(u) : _FesterAuth(u);
          }),
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
        fake.json('POST /auth/logout', {'ok': true});
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
        final bAlt = b.ctrl.lokalerSchluessel!.exportieren();
        await b.ctrl.lokalenSchluesselVerwerfen();
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        // der abweichende Schlüssel ist NICHT gelöscht, sondern in der Quarantäne aufbewahrt
        expect(b.s.quarantaene, hasLength(1));
        expect(await b.speicher.lesen(b.s.quarantaene.single.name), bAlt, reason: 'unverändert aufbewahrt');
        expect(b.s.quarantaene.single.seit, isNotNull);
        expect(await b.speicher.lesen(personenschluesselAltName(_anna)), isNull);
      });

      test('Schlüsselwechsel: der bisherige Schlüssel wird aufbewahrt (Quarantäne), nicht gelöscht', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final alt = a.ctrl.lokalerSchluessel!.exportieren();
        await a.ctrl.schluesselWechseln();
        expect(a.s.quarantaene, hasLength(1));
        expect(await a.speicher.lesen(a.s.quarantaene.single.name), alt);
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
        expect(a.ctrl.lokalerSchluessel!.exportieren(), isNot(alt));
      });

      test('Verbinden auf einem Gerät mit einem anderen (abweichenden) Schlüssel überschreibt ihn nicht, er wandert in die Quarantäne', () async {
        final a = await geraet(_anna, 'Anna');
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        final b = await geraet(_anna, 'Anna');
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
        final bAlt = b.ctrl.lokalerSchluessel!.exportieren();
        await a.ctrl.schluesselWechseln();
        final einr2 = await a.ctrl.neuerWiederherstellungsschluessel();
        await a.ctrl.sicherungAblegen(einr2);
        await b.ctrl.laden();
        expect(b.s.status, E2eeStatus.abweichend);
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr2.wiederherstellungsschluessel));
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.s.quarantaene, hasLength(1));
        expect(await b.speicher.lesen(b.s.quarantaene.single.name), bAlt);
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

      test('Abmelden (Wiper) behält den Schlüssel im Speicher und verwirft nur den Zustand; die Neuanmeldung derselben Person nutzt ihn weiter', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        final schluessel = a.ctrl.lokalerSchluessel!.exportieren();
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull);
        final wiper = Provider<Future<void> Function()>(e2eeSitzungWiper);
        await a.c.read(wiper)();
        expect(await a.speicher.lesen(personenschluesselName(_anna)), schluessel, reason: 'Abmelden löscht nie einen Schlüssel');
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull);
        expect(await a.speicher.lesen('e2ee.kv.$_anna'), isNotNull, reason: 'auch die Vermerke bleiben');
        expect(a.s.status, E2eeStatus.laedt, reason: 'Zustand der bisherigen Person ist verworfen');
        expect(a.ctrl.lokalerSchluessel, isNull, reason: 'der Schlüssel im Arbeitsspeicher ist weg');
        // nächste Anmeldung derselben Person am selben Gerät: derselbe Speicher, sofort wieder bereit, kein neuer Schlüssel nötig
        final wieder = await geraet(_anna, 'Anna', eigenerSpeicher: a.speicher);
        expect(wieder.s.status, E2eeStatus.bereit);
        expect(wieder.ctrl.lokalerSchluessel!.exportieren(), schluessel);
      });

      test('Personenwechsel am selben Gerät: der Schlüssel der Vorperson bleibt liegen und wird für die neue Person nie benutzt', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final annaSchluessel = a.ctrl.lokalerSchluessel!.exportieren();
        await a.c.read(Provider<Future<void> Function()>(e2eeSitzungWiper))(); // Abmelden von Anna
        // Ben meldet sich am selben Gerät an (derselbe Schlüsselspeicher)
        final ben = await geraet(_ben, 'Ben', eigenerSpeicher: a.speicher);
        expect(ben.s.status, E2eeStatus.keinSchluessel, reason: 'Ben hat noch keinen Schlüssel');
        expect(ben.ctrl.lokalerSchluessel, isNull, reason: 'Annas Schlüssel wird nie für Ben verwendet');
        expect(await a.speicher.lesen(personenschluesselName(_anna)), annaSchluessel, reason: 'Annas Schlüssel bleibt unberührt liegen');
        await ben.ctrl.einrichten();
        final bensSchluessel = ben.ctrl.lokalerSchluessel!.exportieren();
        expect(bensSchluessel, isNot(annaSchluessel));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), annaSchluessel);
        expect(await a.speicher.lesen(personenschluesselName(_ben)), bensSchluessel);
        // "Gerät abgeben" von Ben löscht Annas Schlüssel nie
        await schluesselVomGeraetLoeschen(a.speicher, _ben);
        expect(await a.speicher.lesen(personenschluesselName(_ben)), isNull);
        expect(await a.speicher.lesen(personenschluesselName(_anna)), annaSchluessel);
      });

      test('Wiper: ein Fehler eines anderen Wipers verhindert nie das Verwerfen des Zustands; der erste Fehler wird danach geworfen; kein Schlüssel wird gelöscht', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final schluessel = a.ctrl.lokalerSchluessel!.exportieren();
        final sitzungsWiper = a.c.read(Provider<Future<void> Function()>(e2eeSitzungWiper));
        var datenLief = false;
        final verkettet = wiperVerkettet([
          () async => throw StateError('Datenbank defekt'),
          () async => datenLief = true,
          sitzungsWiper,
        ]);
        await expectLater(verkettet(), throwsA(isA<StateError>()));
        expect(datenLief, isTrue);
        expect(a.s.status, E2eeStatus.laedt, reason: 'Zustand der bisherigen Person ist verworfen');
        expect(await a.speicher.lesen(personenschluesselName(_anna)), schluessel);
      });

      test('beschädigte Vertrauensablage: klare Meldung, nichts wird überschrieben; bewusstes Zurücksetzen heilt', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        await a.speicher.schreiben('e2ee.vertrauen.$_anna', Uint8List.fromList(utf8.encode('{kaputt')));
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.nichtVerfuegbar);
        expect(a.s.vertrauenDefekt, isTrue);
        expect(a.s.meldung, contains('beschädigt'));
        expect(utf8.decode((await a.speicher.lesen('e2ee.vertrauen.$_anna'))!), '{kaputt', reason: 'nicht still überschrieben');
        await a.ctrl.vertrauenZuruecksetzen();
        expect(a.s.vertrauenDefekt, isFalse);
        expect(a.s.status, E2eeStatus.bereit);
        expect(a.s.warnungen, isEmpty, reason: 'Schlüssel werden wieder beim ersten Sehen gemerkt');
      });

      test('beschädigter Stand der Chat-Mitglieder (Gesamtblob oder ein Eintrag): gemeldet, Zurücksetzen löscht ihn mit', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        for (final kaputt in ['{kaputt', '{"chat1":{"e":{"1":"h"},"b":{"x":"nicht-int"}}}', '{"chat1":{"e":[1],"b":{}}}']) {
          await a.speicher.schreiben('e2ee.akzeptiert.$_anna', Uint8List.fromList(utf8.encode(kaputt)));
          await a.ctrl.laden();
          expect(a.s.vertrauenDefekt, isTrue, reason: kaputt);
          await a.ctrl.vertrauenZuruecksetzen();
          expect(a.s.vertrauenDefekt, isFalse);
          expect(await a.speicher.lesen('e2ee.akzeptiert.$_anna'), isNull, reason: 'der Stand wird mit zurückgesetzt');
        }
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
        expect(await speicher.lesen(personenschluesselName(_anna)), isNull, reason: 'dauerhaft unbrauchbar: nicht mehr in Gebrauch');
        // ... aber NICHT gelöscht: unverändert in der Quarantäne
        expect(a.s.quarantaene, hasLength(1));
        expect(await speicher.lesen(a.s.quarantaene.single.name), bytes);
      });

      test('Unbrauchbare Schlüsselbytes (Format kaputt): in die Quarantäne, nicht löschen', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        final kaputt = Uint8List.fromList([9, 9, 9]);
        await a.speicher.schreiben(personenschluesselName(_anna), kaputt);
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(a.s.quarantaene, hasLength(1));
        expect(await a.speicher.lesen(a.s.quarantaene.single.name), kaputt);
      });

      test('Quarantäne verwerfen: nur eigene Einträge, nur ausdrücklich', () async {
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        await a.speicher.schreiben('${quarantaenePraefix(_anna)}5', Uint8List.fromList([1]));
        await a.speicher.schreiben('${quarantaenePraefix(_ben)}6', Uint8List.fromList([2]));
        await a.ctrl.laden();
        expect(a.s.quarantaene.map((e) => e.name), ['${quarantaenePraefix(_anna)}5'], reason: 'nur die eigenen sind sichtbar');
        await expectLater(a.ctrl.quarantaeneVerwerfen('${quarantaenePraefix(_ben)}6'), throwsA(isA<CryptoFehler>()));
        expect(await a.speicher.lesen('${quarantaenePraefix(_ben)}6'), isNotNull);
        await a.ctrl.quarantaeneVerwerfen('${quarantaenePraefix(_anna)}5');
        expect(a.s.quarantaene, isEmpty);
        expect(await a.speicher.lesen('${quarantaenePraefix(_anna)}5'), isNull);
      });

      test('TOFU-Einträge entfernter Mitglieder bleiben (als entfernt) für die Prüfung alter Signaturen', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull);
        expect(utf8.decode((await a.speicher.lesen('e2ee.vertrauen.$_anna'))!), contains(_ben));
        srv.entferne(_ben);
        await a.ctrl.laden();
        expect(utf8.decode((await a.speicher.lesen('e2ee.vertrauen.$_anna'))!), contains(_ben), reason: 'nicht gelöscht, nur als entfernt markiert');
        expect((await a.ctrl.absenderSchluessel(_ben, 1)).version, 1, reason: 'alte Signaturen des entfernten Mitglieds bleiben prüfbar');
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
        expect(v1Historie.gleichWie(v1), isTrue, reason: 'Version 1 kommt aus der vom Gerät gemerkten Historie');
        await expectLater(a.ctrl.absenderSchluessel(_ben, 9), throwsA(isA<CryptoFehler>()), reason: 'neuer als der gemerkte Schlüssel');
        await expectLater(a.ctrl.absenderSchluessel(_cora, 1), throwsA(isA<CryptoFehler>()), reason: 'nie bestätigt: kein Nachladen vom Server');
      });

      test('Gerät abgeben löscht alle Schlüssel dieser Person (Schlüssel, Zwischenstand, Vermerke, Quarantäne), andere Personen und das gemerkte Vertrauen bleiben', () async {
        final a = await geraet(_anna, 'Anna');
        final ben = await geraet(_ben, 'Ben');
        await ben.ctrl.einrichten();
        await a.ctrl.einrichten();
        await a.speicher.schreiben(personenschluesselAltName(_anna), Uint8List.fromList([1]));
        await a.speicher.schreiben('e2ee.kv.pw.$_anna', Uint8List.fromList([49]));
        await a.speicher.schreiben('${quarantaenePraefix(_anna)}123', Uint8List.fromList([2]));
        await a.speicher.schreiben('${quarantaenePraefix(_ben)}124', Uint8List.fromList([3]));
        await a.speicher.schreiben(personenschluesselName(_ben), Uint8List.fromList([4]));
        // Vermerke der Wiederherstellungstests und der Eltern-Wiederherstellung (auch die von Ben bleiben)
        for (final n in ['e2ee.kv.test.$_anna', 'e2ee.kv.testaus.$_anna', 'e2ee.elternanfrage.$_anna', 'e2ee.elternuebernahme.$_anna.anfrage-1', 'e2ee.elternuebernahme.$_anna.anfrage-2']) {
          await a.speicher.schreiben(n, Uint8List.fromList([5]));
        }
        await a.speicher.schreiben('e2ee.elternanfrage.$_ben', Uint8List.fromList([6]));
        await schluesselVomGeraetLoeschen(a.speicher, _anna);
        expect(await a.speicher.namenMitPraefix('e2ee.elternuebernahme.$_anna.'), isEmpty);
        expect(await a.speicher.namenMitPraefix('e2ee.kv.test'), isEmpty);
        expect(await a.speicher.lesen('e2ee.elternanfrage.$_anna'), isNull);
        expect(await a.speicher.lesen('e2ee.elternanfrage.$_ben'), isNotNull, reason: 'Bens Vermerk bleibt');
        expect(await a.speicher.namenMitPraefix('e2ee.pk.$_anna'), isEmpty);
        expect(await a.speicher.namenMitPraefix('e2ee.kv.$_anna'), isEmpty);
        expect(await a.speicher.lesen('e2ee.kv.pw.$_anna'), isNull);
        expect(await a.speicher.namenMitPraefix(quarantaenePraefix(_anna)), isEmpty);
        expect(await a.speicher.lesen('${quarantaenePraefix(_ben)}124'), isNotNull, reason: 'Bens Eintrag bleibt');
        expect(await a.speicher.lesen(personenschluesselName(_ben)), isNotNull, reason: 'Bens Schlüssel bleibt');
        expect(await a.speicher.lesen('e2ee.vertrauen.$_anna'), isNotNull, reason: 'gemerkte öffentliche Schlüssel bleiben');
      });

      test('Gerät abgeben: scheitert ein Schritt, laufen die anderen trotzdem, und der erste Fehler wird geworfen', () async {
        final speicher = _WackligerSpeicher();
        final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
        await a.ctrl.einrichten();
        await speicher.schreiben('e2ee.kv.pw.$_anna', Uint8List.fromList([49]));
        speicher.loeschFehler = true;
        await expectLater(schluesselVomGeraetLoeschen(speicher, _anna), throwsA(isA<StateError>()));
        expect(await speicher.lesen('e2ee.kv.pw.$_anna'), isNull, reason: 'die anderen Schritte liefen trotzdem');
        expect(await speicher.lesen(personenschluesselName(_anna)), isNotNull, reason: 'der fehlgeschlagene Schritt hat nichts verändert');
      });

      group('Gerät abgeben (nur mit bestätigter Sicherung beim Server)', () {
        test('ohne Sicherung: gesperrt, nichts wird gelöscht, nicht abgemeldet', () async {
          final a = await geraet(_anna, 'Anna');
          await a.ctrl.einrichten();
          final schluessel = a.ctrl.lokalerSchluessel!.exportieren();
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.keineBestaetigteSicherung);
          await expectLater(a.ctrl.geraetAbgeben(), throwsA(isA<CryptoFehler>()));
          expect(await a.speicher.lesen(personenschluesselName(_anna)), schluessel);
          expect(fake.anfragen('POST /auth/logout'), isEmpty);
        });

        test('mit Sicherung des Wiederherstellungsschlüssels: abgemeldet, Schlüssel und Vermerke weg, die Sicherung beim Server bleibt', () async {
          final a = await geraet(_anna, 'Anna');
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          await a.speicher.schreiben('${quarantaenePraefix(_anna)}7', Uint8List.fromList([1]));
          expect(a.s.sicherungBestaetigt, isTrue);
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.moeglich);
          final ergebnis = await a.ctrl.geraetAbgeben();
          expect(ergebnis.serverAbgemeldet, isTrue);
          expect(ergebnis.schluesselGeloescht, isTrue);
          expect(ergebnis.datenSauber, isTrue);
          expect(await a.speicher.namenMitPraefix('e2ee.loeschauftrag.'), isEmpty, reason: 'der Löschauftrag ist erledigt');
          expect(fake.anfragen('POST /auth/logout'), hasLength(1));
          expect(await a.speicher.namenMitPraefix('e2ee.pk.$_anna'), isEmpty);
          expect(await a.speicher.namenMitPraefix('e2ee.kv.$_anna'), isEmpty);
          expect(await a.speicher.namenMitPraefix(quarantaenePraefix(_anna)), isEmpty);
          expect(srv.gespeichert(_anna), contains('"backup":"'), reason: 'die Sicherung beim Server bleibt');
        });

        test('Server meldet die neuen Felder nicht (älterer Server): auch mit hasBackup nie "gesichert", gesperrt', () async {
          srv.neueFelder = false;
          final a = await geraet(_anna, 'Anna');
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          expect(a.s.hatSicherung, isTrue);
          expect(a.s.sicherungBestaetigt, isFalse, reason: 'unbekannt ist nie gesichert');
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.keineBestaetigteSicherung);
          await expectLater(a.ctrl.geraetAbgeben(), throwsA(isA<CryptoFehler>()));
          expect(await a.speicher.lesen(personenschluesselName(_anna)), isNotNull);
        });

        test('bestätigte Passwort-Sicherung zählt, eine veraltete (nach Passwort-Reset) nicht', () async {
          srv.pwSchalter = true;
          final a = await geraet(_anna, 'Anna');
          await a.ctrl.einrichten();
          srv.pwEinspielen(_anna, 'blob', version: 1);
          await a.ctrl.laden();
          expect(a.s.pwBestaetigtAm, isNotNull);
          expect(a.s.hatSicherung, isFalse, reason: 'kein Wiederherstellungsschlüssel');
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.moeglich);
          srv.passwortZurueckgesetzt(_anna);
          await a.ctrl.laden();
          expect(a.s.pwSicherungVeraltet, isTrue);
          expect(a.s.sicherungBestaetigt, isFalse);
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.keineBestaetigteSicherung);
        });

        test('Stand beim Server nicht ladbar: gesperrt (nie "gesichert"), nichts wird gelöscht', () async {
          final a = await geraet(_anna, 'Anna');
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          fake.on('GET /me/keys', (_) => fehler(500, 'server_error'));
          await expectLater(a.ctrl.geraetAbgeben(), throwsA(isA<CryptoFehler>()));
          expect(a.s.status, E2eeStatus.nichtVerfuegbar);
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.standUnbekannt);
          expect(await a.speicher.lesen(personenschluesselName(_anna)), isNotNull);
          expect(fake.anfragen('POST /auth/logout'), isEmpty);
        });

        test('Löschen scheitert: abgemeldet, aber ehrlich "Schlüssel nicht gelöscht"; der Löschauftrag bleibt und wird beim nächsten Start abgearbeitet', () async {
          final speicher = _WackligerSpeicher();
          final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          speicher.loeschFehler = true;
          final ergebnis = await a.ctrl.geraetAbgeben();
          expect(ergebnis.serverAbgemeldet, isTrue);
          expect(ergebnis.schluesselGeloescht, isFalse);
          expect(await speicher.lesen(personenschluesselName(_anna)), isNotNull, reason: 'der Schlüssel liegt noch da');
          expect(await speicher.namenMitPraefix('e2ee.loeschauftrag.'), [loeschauftragName(_anna)]);
          // nächster Start: das Löschen klappt jetzt
          speicher.loeschFehler = false;
          await loeschauftraegeAbarbeiten(speicher);
          expect(await speicher.namenMitPraefix('e2ee.pk.$_anna'), isEmpty);
          expect(await speicher.namenMitPraefix('e2ee.loeschauftrag.'), isEmpty);
        });

        test('Löschauftrag beim Start: scheitert es erneut, bleibt er; andere Personen bleiben unberührt', () async {
          final speicher = _WackligerSpeicher();
          await speicher.schreiben(personenschluesselName(_anna), Uint8List.fromList([1]));
          await speicher.schreiben(personenschluesselName(_ben), Uint8List.fromList([2]));
          await speicher.schreiben(loeschauftragName(_anna), utf8Bytes('${DateTime.now().millisecondsSinceEpoch}'));
          speicher.loeschFehler = true;
          await loeschauftraegeAbarbeiten(speicher); // wirft nie
          expect(await speicher.namenMitPraefix('e2ee.loeschauftrag.'), [loeschauftragName(_anna)]);
          speicher.loeschFehler = false;
          await loeschauftraegeAbarbeiten(speicher);
          expect(await speicher.lesen(personenschluesselName(_anna)), isNull);
          expect(await speicher.lesen(personenschluesselName(_ben)), isNotNull, reason: 'nur die Person aus dem Auftrag');
          expect(await speicher.namenMitPraefix('e2ee.loeschauftrag.'), isEmpty);
        });

        test('lokale Daten ließen sich nicht entfernen (lokalSauber=false): das Ergebnis sagt es', () async {
          final a = await geraet(_anna, 'Anna', wiperFehler: true);
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          final ergebnis = await a.ctrl.geraetAbgeben();
          expect(ergebnis.datenSauber, isFalse);
          expect(ergebnis.schluesselGeloescht, isTrue);
        });

        test('Web: Abmelden scheitert (Serverfehler): nichts wird gelöscht, kein Löschauftrag bleibt, die Sitzung gilt weiter', () async {
          final a = await geraet(_anna, 'Anna', abmeldenScheitert: true);
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          final schluessel = a.ctrl.lokalerSchluessel!.exportieren();
          await expectLater(a.ctrl.geraetAbgeben(), throwsA(isA<ApiException>()));
          expect(await a.speicher.lesen(personenschluesselName(_anna)), schluessel);
          expect(await a.speicher.namenMitPraefix('e2ee.loeschauftrag.'), isEmpty);
        });

        test('Schlüsselspeicher nicht beschreibbar (Löschauftrag lässt sich nicht ablegen): es beginnt nichts', () async {
          final a = await geraet(_anna, 'Anna');
          final einr = await a.ctrl.einrichten();
          await a.ctrl.sicherungAblegen(einr);
          // ein Speicher, der nur den Löschauftrag ablehnt
          final speicher = _WackligerSpeicher();
          final b = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
          await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
          speicher.schreibFehlerPraefix = 'e2ee.loeschauftrag.';
          await expectLater(b.ctrl.geraetAbgeben(), throwsA(isA<CryptoFehler>()));
          expect(await speicher.lesen(personenschluesselName(_anna)), isNotNull);
          expect(fake.anfragen('POST /auth/logout'), isEmpty);
        });

        test('Lokaler Schlüssel, den der Server nicht kennt (z. B. nach Admin-Reset): nie "nichts zu löschen", gesperrt ohne Sicherung', () async {
          final a = await geraet(_anna, 'Anna');
          await a.ctrl.einrichten();
          srv.entferne(_anna);
          srv.person(_anna, 'Anna'); // der Server kennt keinen Schlüssel mehr
          await a.ctrl.laden();
          expect(a.s.status, E2eeStatus.keinSchluessel);
          expect(a.s.lokalVorhanden, isTrue);
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.keineBestaetigteSicherung);
        });

        test('Frühere Schlüssel: Anzahl für den Pflicht-Haken (Quarantäne und abweichender Schlüssel)', () async {
          final a = await geraet(_anna, 'Anna');
          await a.ctrl.einrichten();
          expect(a.s.fruehereSchluessel, 0);
          await a.speicher.schreiben('${quarantaenePraefix(_anna)}5', Uint8List.fromList([1]));
          await a.speicher.schreiben('${quarantaenePraefix(_anna)}6', Uint8List.fromList([2]));
          await a.ctrl.laden();
          expect(a.s.fruehereSchluessel, 2);
          const abw = E2eeState(status: E2eeStatus.abweichend, quarantaene: [QuarantaeneEintrag('x', null)]);
          expect(abw.fruehereSchluessel, 2, reason: 'der abweichende lokale Schlüssel zählt mit');
        });

        test('Gerät ohne Schlüssel und ohne Quarantäne: nichts zu löschen', () async {
          final a = await geraet(_anna, 'Anna');
          expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.nichtsZuLoeschen);
          final b = await geraet(_anna, 'Anna');
          await a.ctrl.einrichten();
          await b.ctrl.laden();
          expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
          expect(geraetAbgabeLage(b.s), GeraetAbgabeLage.nichtsZuLoeschen);
        });

        test('Lage-Tabelle: unbekannte Zustände sind nie "möglich"', () {
          final t = DateTime(2026, 10, 21);
          for (final status in [E2eeStatus.laedt, E2eeStatus.nichtVerfuegbar]) {
            expect(geraetAbgabeLage(E2eeState(status: status, hatSicherung: true, wiederherstellungAm: t, pwBestaetigtAm: t)), GeraetAbgabeLage.standUnbekannt);
          }
          expect(geraetAbgabeLage(E2eeState(status: E2eeStatus.bereit, hatSicherung: true, wiederherstellungAm: t)), GeraetAbgabeLage.moeglich);
          expect(geraetAbgabeLage(E2eeState(status: E2eeStatus.abweichend, pwBestaetigtAm: t)), GeraetAbgabeLage.moeglich);
          expect(geraetAbgabeLage(const E2eeState(status: E2eeStatus.bereit, hatSicherung: true)), GeraetAbgabeLage.keineBestaetigteSicherung, reason: 'hasBackup allein genügt nicht');
          expect(geraetAbgabeLage(E2eeState(status: E2eeStatus.bereit, wiederherstellungAm: t)), GeraetAbgabeLage.keineBestaetigteSicherung, reason: 'ein Datum ohne hasBackup genügt nicht');
          expect(geraetAbgabeLage(E2eeState(status: E2eeStatus.bereit, pwBestaetigtAm: t, pwSicherungVeraltet: true)), GeraetAbgabeLage.keineBestaetigteSicherung);
          expect(geraetAbgabeLage(const E2eeState(status: E2eeStatus.keinSchluessel)), GeraetAbgabeLage.nichtsZuLoeschen);
          expect(
            geraetAbgabeLage(E2eeState(status: E2eeStatus.geraetNichtVerbunden, quarantaene: const [QuarantaeneEintrag('x', null)])),
            GeraetAbgabeLage.keineBestaetigteSicherung,
            reason: 'ein aufbewahrter alter Schlüssel zählt als etwas zu Löschendes',
          );
        });
      });

      test('GET /me/keys: die neuen Felder sind tolerant (fehlend oder falsch geformt = unbekannt, nie ein Fehler)', () {
        EigeneSchluesselDto dto(Map<String, dynamic> extra) => EigeneSchluesselDto.fromJson({'keys': null, 'hasBackup': true, ...extra});
        final leer = dto({});
        expect(leer.pwSicherungBestaetigtAm, isNull);
        expect(leer.wiederherstellungsSicherungAm, isNull);
        expect(leer.archivAnzahl, isNull);
        final voll = dto({'pwBackupVerifiedAt': '2026-10-20T10:00:00.000Z', 'recoveryBackupAt': '2026-10-19T10:00:00.000Z', 'archiveCount': 2});
        expect(voll.pwSicherungBestaetigtAm, DateTime.utc(2026, 10, 20, 10));
        expect(voll.wiederherstellungsSicherungAm, DateTime.utc(2026, 10, 19, 10));
        expect(voll.archivAnzahl, 2);
        final falsch = dto({'pwBackupVerifiedAt': 5, 'recoveryBackupAt': 'gestern', 'archiveCount': 'viele'});
        expect(falsch.pwSicherungBestaetigtAm, isNull);
        expect(falsch.wiederherstellungsSicherungAm, isNull);
        expect(falsch.archivAnzahl, isNull);
        expect(dto({'archiveCount': -1}).archivAnzahl, isNull);
      });

      test('Fehlercode destructive_locked: verständliche Meldung, mit Dauer ("frühestens in …"), wenn der Server sie nennt', () {
        final ohne = ApiException.vonAntwort(status: 423, code: 'destructive_locked');
        expect(ohne.message, contains('gesperrt'));
        expect(ohne.message, contains('später noch einmal'));
        expect(ohne.message, isNot(contains('destructive')));
        String msg(int sek) => ApiException.vonAntwort(status: 423, code: 'destructive_locked', retryAfterSekunden: sek).message;
        expect(msg(20), contains('frühestens in einer Minute'));
        expect(msg(300), contains('frühestens in 5 Minuten'));
        expect(msg(3600), contains('frühestens in einer Stunde'));
        expect(msg(3 * 3600 + 1), contains('frühestens in 4 Stunden'));
        expect(msg(86400), contains('frühestens in 24 Stunden'));
      });

      test('Vertrag mit dem Server (docs/API.md): GET /me/keys im Format von main und 403 destructive_locked mit retryAfterSec', () async {
        // genau die Antwort von server/src/auth/keys.ts (getOwnKeys)
        final dto = EigeneSchluesselDto.fromJson({
          'keys': {'publicEncKey': base64urlKodieren(Uint8List(32)), 'publicSignKey': base64urlKodieren(Uint8List(32)), 'keyVersion': 3},
          'hasBackup': true,
          'pwBackupStale': true,
          'pwBackupVerifiedAt': '2026-10-21T08:15:30.123Z',
          'recoveryBackupAt': null,
          'archiveCount': 4,
        });
        expect(dto.hatSicherung, isTrue);
        expect(dto.pwSicherungVeraltet, isTrue);
        expect(dto.pwSicherungBestaetigtAm, DateTime.utc(2026, 10, 21, 8, 15, 30, 123));
        expect(dto.wiederherstellungsSicherungAm, isNull, reason: 'null = keine Wiederherstellungssicherung zur aktuellen Version');
        expect(dto.archivAnzahl, 4);
        // 403 mit retryAfterSec im Antworttext (und ohne Header): die Dauer kommt an
        final a = await geraet(_anna, 'Anna');
        await a.ctrl.einrichten();
        fake.on('PUT /me/keys', (_) => jsonAntwort({'error': 'destructive_locked', 'message': 'x', 'retryAfterSec': 7200}, status: 403));
        await expectLater(
          a.ctrl.schluesselWechseln(),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', 'destructive_locked').having((e) => e.message, 'message', contains('frühestens in 2 Stunden'))),
        );
        // mit Header Retry-After (wie der echte Server, beides gesetzt)
        fake.on('PUT /me/keys', (_) => jsonAntwort({'error': 'destructive_locked', 'message': 'x', 'retryAfterSec': 5400}, status: 403, headers: {'retry-after': '5400'}));
        await expectLater(a.ctrl.schluesselWechseln(), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('frühestens in 2 Stunden'))));
        expect(await a.speicher.lesen(personenschluesselName(_anna)), isNotNull, reason: 'der Schlüssel bleibt bei der Sperre unverändert');
        expect(await a.speicher.lesen(personenschluesselAltName(_anna)), isNull);
      });

      group('Dauerhafter Browser-Speicher (nur Web, hier mit Fake)', () {
        test('Laden fragt nur ab, wartet nie lange und fordert nie an; Einrichten (Aktion der Person) fordert genau einmal an', () async {
          final speicher = _DauerSpeicher();
          final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
          expect(speicher.abfragen, greaterThan(0));
          expect(speicher.anforderungen, 0, reason: 'beim Laden nie persist()');
          expect(a.s.speicherDauer, SpeicherDauer.verweigert);
          await a.ctrl.einrichten();
          expect(speicher.anforderungen, 1);
        });

        test('Abfrage hängt (Zeitlimit): das Laden wartet nicht ewig, der Stand ist "unbekannt" (keine Tatsachenbehauptung)', () async {
          final speicher = _DauerSpeicher()..haengt = true;
          final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
          expect(a.s.status, E2eeStatus.keinSchluessel, reason: 'das Laden ist trotzdem fertig geworden');
          expect(a.s.speicherDauer, SpeicherDauer.unbekannt);
        });

        test('eigener Knopf: dauerhaftenSpeicherAnfordern fragt an und lädt neu', () async {
          final speicher = _DauerSpeicher();
          final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
          speicher.zugesagt = true;
          await a.ctrl.dauerhaftenSpeicherAnfordern();
          expect(speicher.anforderungen, 1);
          expect(a.s.speicherDauer, SpeicherDauer.gewaehrt);
        });
      });

      test('Neu verbinden: lässt sich ein Schlüssel nicht beiseitelegen, aber er ist da, wird nichts verändert (Existenz über Lesen, nicht über den Index)', () async {
        final speicher = _NichtVerschiebbarSpeicher();
        final a = await geraet(_anna, 'Anna', eigenerSpeicher: speicher);
        await a.ctrl.einrichten();
        final bytes = await speicher.lesen(personenschluesselName(_anna));
        await expectLater(a.ctrl.lokalenSchluesselVerwerfen(), throwsA(isA<CryptoFehler>()));
        expect(await speicher.lesen(personenschluesselName(_anna)), bytes);
        expect(a.ctrl.lokalerSchluessel, isNotNull);
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

/// Speicher, der das Verschieben ablehnt (wie ein Keystore, der den Eintrag nicht roh herausgibt), aber lesbar ist.
class _NichtVerschiebbarSpeicher extends MemorySchluesselSpeicher {
  @override
  Future<bool> verschiebe(String von, String nach) async => false;
}

/// Fake der Browser-Ablage: zählt Abfragen und Anforderungen, kann hängen.
class _DauerSpeicher extends MemorySchluesselSpeicher {
  int abfragen = 0;
  int anforderungen = 0;
  bool zugesagt = false;
  bool haengt = false;

  @override
  Future<SpeicherDauer> dauerhaftigkeit() async {
    abfragen++;
    if (haengt) await Completer<void>().future;
    return zugesagt ? SpeicherDauer.gewaehrt : SpeicherDauer.verweigert;
  }

  @override
  Future<SpeicherDauer> dauerhaftAnfordern() async {
    anforderungen++;
    return zugesagt ? SpeicherDauer.gewaehrt : SpeicherDauer.verweigert;
  }
}

/// Schlüsselspeicher mit steuerbaren Fehlern (Lesen, Löschen).
class _WackligerSpeicher extends MemorySchluesselSpeicher {
  SchluesselSpeicherFehler? fehler;
  bool loeschFehler = false;

  /// Schreiben unter diesem Namenspräfix schlägt fehl.
  String? schreibFehlerPraefix;

  @override
  Future<void> schreiben(String name, Uint8List bytes) async {
    if (schreibFehlerPraefix != null && name.startsWith(schreibFehlerPraefix!)) throw StateError('Schreiben fehlgeschlagen');
    return super.schreiben(name, bytes);
  }

  @override
  Future<Uint8List?> lesen(String name) async {
    if (fehler != null && name.startsWith('e2ee.pk.')) throw fehler!;
    return super.lesen(name);
  }

  @override
  Future<void> loeschen(String name) async {
    if (loeschFehler && name.startsWith('e2ee.pk.')) throw StateError('Löschen fehlgeschlagen');
    return super.loeschen(name);
  }
}
