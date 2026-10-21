// Ablauf der Passwort-Sicherung gegen einen In-Memory-Server (PR 3 der vereinfachten Schlüsselverwaltung): Anlegen mit zweifacher Probe (lokal +
// Round-Trip), Fehlerpfade (nichts wird übernommen), Migration eines bestehenden Schlüsselstands (alter Weg bleibt unberührt), Verbinden eines
// zweiten Geräts, veraltete Sicherung nach Schlüsselwechsel, Feature-Gate. Läuft gegen den Fake und, wo verfügbar, gegen libsodium.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/wiederherstellung.dart';

import '../support/fake_crypto.dart';
import '../support/fake_e2ee_server.dart';
import '../support/fake_server.dart';
import '../support/test_app.dart';

const _anna = '11111111-1111-4111-8111-111111111111';
const _mail = 'anna@beispiel.de';
const _pw = 'Zebra-Kamin-Orbit-Fluss-Lampe';

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user);
}

class _Geraet {
  final ProviderContainer c;
  final MemorySchluesselSpeicher speicher;
  _Geraet(this.c, this.speicher);
  E2eeController get ctrl => c.read(e2eeProvider.notifier);
  E2eeState get s => c.read(e2eeProvider);
}

Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));

String _vermerk(String id) => 'e2ee.kv.pw.$id';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Passwort-Sicherung ($name)', () {
      late FakeServer fake;
      late FakeE2eeServer srv;

      Future<_Geraet> geraet({MemorySchluesselSpeicher? speicher}) async {
        final env = TestUmgebung(fake, store: MemoryTokenStore());
        await env.store.writeTokens(
          StoredTokens(
            accessToken: 'access-$_anna',
            accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
            refreshToken: 'refresh-$_anna',
            refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
            deviceId: fixDevice,
          ),
        );
        final sp = speicher ?? MemorySchluesselSpeicher();
        env.extraOverrides.addAll([
          cryptoProviderProvider.overrideWith((ref) async => crypto),
          schluesselSpeicherProvider.overrideWithValue(sp),
          authProvider.overrideWith(() => _FesterAuth(UserDto.fromJson(userJson(id: _anna, name: 'Anna', email: _mail)))),
        ]);
        final c = env.container();
        addTearDown(c.dispose);
        addTearDown(env.db.close);
        c.read(authProvider);
        final g = _Geraet(c, sp);
        await g.ctrl.laden();
        return g;
      }

      /// Bestehender Stand wie bei einer Person vor dem Update: Schlüssel, alter Wiederherstellungsschlüssel (Sicherung beim Server).
      Future<({_Geraet g, Einrichtung einr})> bestehend() async {
        final g = await geraet();
        final einr = await g.ctrl.einrichten();
        await g.ctrl.sicherungAblegen(einr);
        return (g: g, einr: einr);
      }

      Future<void> sichern(_Geraet g, [String pw = _pw]) async {
        final e = await g.ctrl.pwSicherungVorbereiten(pw);
        await g.ctrl.pwSicherungAblegen(e, pw);
      }

      setUp(() {
        fake = FakeServer();
        srv = FakeE2eeServer(fake)
          ..person(_anna, 'Anna', email: _mail)
          ..pwSchalter = true;
      });

      test('Anlegen: zweifach geprüft, beim Server verifiziert, Vermerk auf dem Gerät, der Server sieht kein Geheimnis', () async {
        final (:g, :einr) = await bestehend();
        expect(g.s.pwSicherungVerfuegbar, isTrue);
        expect(g.s.pwSicherungVersion, isNull);
        await sichern(g);
        final st = srv.pwStand(_anna);
        expect(st.verifiziert, isTrue);
        expect(st.stale, isFalse);
        expect(st.version, 1);
        expect(g.s.pwSicherungVersion, 1);
        expect(fake.anfragen('POST /me/key-backup-pw/verified'), hasLength(1));
        expect(utf8.decode(await g.speicher.lesen(_vermerk(_anna)) ?? const []), '1');

        final geheim = g.ctrl.lokalerSchluessel!.exportieren();
        final text = srv.gespeichert(_anna) + jsonEncode(fake.log.map((r) => r.json).toList());
        for (final teil in [geheim.sublist(0, 32), geheim.sublist(32), einr.wiederherstellungsschluessel, utf8Bytes(_pw)]) {
          expect(text.contains(base64urlKodieren(teil)), isFalse);
        }
        expect(text.contains(_pw), isFalse, reason: 'das Passwort geht nie an den Server');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Migration: bestehender Schlüssel, alte Sicherung und Schlüsselspeicher bleiben unverändert und gültig', () async {
        final (:g, :einr) = await bestehend();
        final vorherSchluessel = g.ctrl.lokalerSchluessel!.exportieren();
        final vorherRoh = await g.speicher.lesen(personenschluesselName(_anna));
        final vorherAltBlob = jsonDecode(srv.gespeichert(_anna))['backup'];
        final vorherOeffentlich = g.s.serverSchluessel;
        await sichern(g);

        expect(await g.speicher.lesen(personenschluesselName(_anna)), vorherRoh);
        expect(g.ctrl.lokalerSchluessel!.exportieren(), vorherSchluessel);
        expect(jsonDecode(srv.gespeichert(_anna))['backup'], vorherAltBlob, reason: 'der alte Blob liegt unverändert beim Server');
        expect(g.s.hatSicherung, isTrue);
        expect(g.s.status, E2eeStatus.bereit);
        expect(g.s.serverSchluessel!.gleichWie(vorherOeffentlich!), isTrue);
        expect(g.s.serverSchluessel!.version, vorherOeffentlich.version);
        expect(fake.anfragen('PUT /me/keys'), isEmpty, reason: 'kein Schlüsselwechsel');
        expect(fake.anfragen('PUT /me/key-backup'), hasLength(1), reason: 'die alte Sicherung wurde nur einmal (beim alten Weg) abgelegt');

        // der alte Weg funktioniert weiter: zweites Gerät per Wiederherstellungsschlüssel
        final b = await geraet();
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel!.exportieren(), vorherSchluessel);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Ohne Schalter des Servers: Funktion unsichtbar, keine Anfrage an die Routen', () async {
        srv.pwSchalter = false;
        final (:g, einr: _) = await bestehend();
        expect(g.s.pwSicherungVerfuegbar, isFalse);
        expect(g.s.pwSicherungVersion, isNull);
        expect(fake.anfragen('PUT /me/key-backup-pw'), isEmpty);
        expect(fake.anfragen('GET /me/key-backup-pw'), isEmpty);
      });

      test('Älterer Server ohne /version: Funktion unsichtbar', () async {
        fake.on('GET /version', (_) => fehler(500, 'internal_error'));
        final (:g, einr: _) = await bestehend();
        expect(g.s.pwSicherungVerfuegbar, isFalse);
      });

      test('Round-Trip scheitert (Blob beim Abruf verändert): nichts wird verifiziert oder vermerkt, alter Weg unberührt', () async {
        final (:g, :einr) = await bestehend();
        srv.pwAbrufVerfaelschen = (b) => '${b.substring(0, b.length - 3)}${b.endsWith('AAA') ? 'BBB' : 'AAA'}';
        final e = await g.ctrl.pwSicherungVorbereiten(_pw);
        await expectLater(g.ctrl.pwSicherungAblegen(e, _pw), _fehler(CryptoFehlerArt.schluessel));
        expect(srv.pwStand(_anna).verifiziert, isFalse);
        expect(fake.anfragen('POST /me/key-backup-pw/verified'), isEmpty);
        expect(await g.speicher.lesen(_vermerk(_anna)), isNull);
        expect(g.s.pwSicherungVersion, isNull);
        expect(srv.pwStand(_anna).blob, isNull, reason: 'nichts ist aktuell geworden');
        expect(g.s.hatSicherung, isTrue);
        // alter Weg
        final b = await geraet();
        await b.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
        expect(b.s.status, E2eeStatus.bereit);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Fehlgeschlagener zweiter Versuch: die frühere geprüfte Sicherung bleibt gültig, das alte Passwort öffnet sie weiter, der Vermerk bleibt', () async {
        final (:g, einr: _) = await bestehend();
        await sichern(g);
        expect(g.s.pwSicherungVersion, 1);
        final alt = srv.pwStand(_anna).blob;
        srv.pwAbrufVerfaelschen = (b) => 'x$b';
        final e = await g.ctrl.pwSicherungVorbereiten('Anderes-Passwort-Wolke-Tisch-Vogel');
        await expectLater(g.ctrl.pwSicherungAblegen(e, 'Anderes-Passwort-Wolke-Tisch-Vogel'), throwsA(anything));
        srv.pwAbrufVerfaelschen = null;
        expect(await g.speicher.lesen(_vermerk(_anna)), isNotNull);
        expect(g.s.pwSicherungVersion, 1);
        final st = srv.pwStand(_anna);
        expect(st.verifiziert, isTrue, reason: 'die bisherige Sicherung bleibt die verifizierte');
        expect(st.blob, alt);
        expect(st.pendingBlob, isNotNull, reason: 'die neue wartet unbestätigt');
        expect(fake.anfragen('POST /me/key-backup-pw/verified'), hasLength(1), reason: 'nur die erste wurde bestätigt');
        // ein neues Gerät öffnet die Sicherung weiter mit dem ALTEN Passwort, das neue gilt noch nicht
        final b = await geraet();
        await expectLater(b.ctrl.mitPasswortVerbinden('Anderes-Passwort-Wolke-Tisch-Vogel'), _fehler(CryptoFehlerArt.entschluesselung));
        await b.ctrl.mitPasswortVerbinden(_pw);
        expect(b.s.status, E2eeStatus.bereit);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Zweite Sicherung mit neuem Passwort gelingt: sie ersetzt die erste erst nach der Bestätigung', () async {
        final (:g, einr: _) = await bestehend();
        await sichern(g);
        const neu = 'Anderes-Passwort-Wolke-Tisch-Vogel';
        await sichern(g, neu);
        final st = srv.pwStand(_anna);
        expect(st.verifiziert, isTrue);
        expect(st.pendingBlob, isNull);
        final b = await geraet();
        await expectLater(b.ctrl.mitPasswortVerbinden(_pw), _fehler(CryptoFehlerArt.entschluesselung));
        await b.ctrl.mitPasswortVerbinden(neu);
        expect(b.s.status, E2eeStatus.bereit);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Lokale Probe schlägt fehl (Schlüssel dieses Geräts passt nicht zum Konto): nichts wird gesendet', () async {
        final (:g, einr: _) = await bestehend();
        final k = srv.gespeichert(_anna);
        expect(k, isNotEmpty);
        srv.setzeSchluessel(_anna, enc: base64urlKodieren(List.filled(32, 7)), sign: base64urlKodieren(List.filled(32, 8)), version: 1);
        await expectLater(g.ctrl.pwSicherungVorbereiten(_pw), _fehler(CryptoFehlerArt.schluessel));
        expect(fake.anfragen('PUT /me/key-backup-pw'), isEmpty);
        expect(srv.pwStand(_anna).blob, isNull);
      });

      test('Ohne lokalen Schlüssel: kein Anlegen', () async {
        final g = await geraet();
        await expectLater(g.ctrl.pwSicherungVorbereiten(_pw), _fehler(CryptoFehlerArt.schluessel));
        expect(fake.anfragen('POST /auth/kdf-params'), isEmpty);
      });

      test('Der Server nennt schwächere Parameter: abgelehnt, nichts gesendet', () async {
        final (:g, einr: _) = await bestehend();
        fake.on('POST /auth/kdf-params', (_) => jsonAntwort({'kdf': {'id': 'argon2id-v1', 'memKiB': 1024, 'ops': 1, 'salt': base64urlKodieren(List.filled(16, 1))}}));
        await expectLater(g.ctrl.pwSicherungVorbereiten(_pw), _fehler(CryptoFehlerArt.format));
        fake.on('POST /auth/kdf-params', (_) => jsonAntwort({'kdf': {'id': 'md5', 'memKiB': 65536, 'ops': 3, 'salt': base64urlKodieren(List.filled(16, 1))}}));
        await expectLater(g.ctrl.pwSicherungVorbereiten(_pw), _fehler(CryptoFehlerArt.version));
        expect(fake.anfragen('PUT /me/key-backup-pw'), isEmpty);
      });

      test('Netzfehler beim Ablegen: nichts vermerkt, nichts verifiziert', () async {
        final (:g, einr: _) = await bestehend();
        final e = await g.ctrl.pwSicherungVorbereiten(_pw);
        srv.verliereAntwort.add('PUT /me/key-backup-pw');
        await expectLater(g.ctrl.pwSicherungAblegen(e, _pw), throwsA(isA<ApiException>()));
        expect(await g.speicher.lesen(_vermerk(_anna)), isNull);
        expect(srv.pwStand(_anna).verifiziert, isFalse);
        expect(fake.anfragen('POST /me/key-backup-pw/verified'), isEmpty);
        // Wiederholung klappt
        srv.verliereAntwort.clear();
        await g.ctrl.pwSicherungAblegen(await g.ctrl.pwSicherungVorbereiten(_pw), _pw);
        expect(srv.pwStand(_anna).verifiziert, isTrue);
        expect(g.s.pwSicherungVersion, 1);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Step-up verlangt: kein Fehler der Sicherung, nach der Bestätigung gelingt derselbe Entwurf', () async {
        final (:g, einr: _) = await bestehend();
        final e = await g.ctrl.pwSicherungVorbereiten(_pw);
        srv.stepUpNoetig = true;
        await expectLater(g.ctrl.pwSicherungAblegen(e, _pw), throwsA(isA<ApiException>().having((x) => x.istStepUp, 'istStepUp', isTrue)));
        expect(srv.pwStand(_anna).blob, isNull);
        srv.stepUpNoetig = false;
        expect(await g.ctrl.pwSicherungAblegen(e, _pw), isTrue);
        expect(srv.pwStand(_anna).verifiziert, isTrue);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Zweites Gerät: mit Passwort verbinden; falsches Passwort scheitert ohne Spur', () async {
        final (:g, einr: _) = await bestehend();
        await sichern(g);
        final b = await geraet();
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        await expectLater(b.ctrl.mitPasswortVerbinden('Falsches-Passwort-Tisch-Wolke-Baum'), _fehler(CryptoFehlerArt.entschluesselung));
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        await b.ctrl.mitPasswortVerbinden(_pw);
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel!.exportieren(), g.ctrl.lokalerSchluessel!.exportieren());
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Nach einem Schlüsselwechsel ist die Sicherung veraltet: Vermerk passt nicht mehr, Verbinden verweigert', () async {
        final (:g, einr: _) = await bestehend();
        await sichern(g);
        await g.ctrl.schluesselWechseln();
        expect(srv.pwStand(_anna).stale, isTrue);
        expect(g.s.serverSchluessel!.version, 2);
        expect(g.s.pwSicherungVersion, 1, reason: 'der Vermerk gehört zur alten Version: die Oberfläche zeigt "veraltet"');
        final b = await geraet();
        await expectLater(b.ctrl.mitPasswortVerbinden(_pw), _fehler(CryptoFehlerArt.schluessel));
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        // neu sichern: gilt für Version 2
        await sichern(g);
        expect(g.s.pwSicherungVersion, 2);
        expect(srv.pwStand(_anna).stale, isFalse);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Abmelden (Wiper) entfernt auch den Vermerk', () async {
        final (:g, einr: _) = await bestehend();
        await sichern(g);
        expect(await g.speicher.lesen(_vermerk(_anna)), isNotNull);
        await g.c.read(Provider<Future<void> Function()>(e2eeDatenWiper))();
        expect(await g.speicher.lesen(_vermerk(_anna)), isNull);
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  }
}

