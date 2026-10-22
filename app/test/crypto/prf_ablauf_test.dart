// Passkey-Sicherung (WebAuthn-PRF) gegen einen In-Memory-Server: Anlegen mit zweifacher Probe (lokal + Round-Trip mit zweiter Auswertung), Fehlerpfade (nichts wird
// übernommen, bisherige Wege bleiben), PRF nicht unterstützt, Verbinden eines zweiten Geräts mit dem Passkey, automatisches Verbinden nach der Anmeldung (alle Fälle, in
// denen NICHTS geschehen darf), veraltete Sicherung nach Schlüsselwechsel, Marke "eigener Abruf". Läuft gegen den Fake und, wo verfügbar, gegen libsodium.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/auth/eigener_abruf.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/prf_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/database_provider.dart';
import 'package:lx_fampad/data/passkey_service.dart';

import '../support/fake_crypto.dart';
import '../support/fake_e2ee_server.dart';
import '../support/fake_server.dart';
import '../support/test_app.dart';

const _anna = '11111111-1111-4111-8111-111111111111';
const _mail = 'anna@beispiel.de';

Uint8List _prf(int start) => Uint8List.fromList(List.generate(32, (i) => (start + i) & 255 | 1));

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user, me: MeDto.fromJson(meJson(passkeys: 1)));
}

class _Geraet {
  final ProviderContainer c;
  final MemorySchluesselSpeicher speicher;
  final TestUmgebung env;
  _Geraet(this.c, this.speicher, this.env);
  E2eeController get ctrl => c.read(e2eeProvider.notifier);
  E2eeState get s => c.read(e2eeProvider);
  PrfSteuerung get prf => c.read(prfSteuerungProvider);
  FakePasskeys get passkeys => env.passkeys;
}

Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Passkey-Sicherung ($name)', () {
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
        final g = _Geraet(c, sp, env);
        await g.ctrl.laden();
        return g;
      }

      /// Gerät mit eingerichtetem Schlüssel und einem Passkey, der PRF kann.
      Future<_Geraet> mitSchluessel({Uint8List? prf}) async {
        final g = await geraet();
        g.passkeys.prfAusgabe = prf ?? _prf(1);
        await g.ctrl.einrichten();
        return g;
      }

      setUp(() {
        fake = FakeServer();
        srv = FakeE2eeServer(fake)
          ..person(_anna, 'Anna', email: _mail)
          ..prfSchalter = true;
      });

      test('Anlegen: zwei Passkey-Gesten, zweifach geprüft, beim Server bestätigt; PRF-Ausgabe und Schlüssel liegen nie beim Server', () async {
        final g = await mitSchluessel();
        expect(g.s.prfSicherungVerfuegbar, isTrue);
        expect(g.s.prfCredentialIds, isEmpty);
        expect(await g.prf.sicherungAnlegen(), PrfAnlegen.angelegt);
        expect(g.passkeys.mitPrfBestaetigt, 2, reason: 'eine Geste zum Anlegen, eine unabhängige zur Prüfung');
        expect(srv.stepUps, 2);
        final stand = srv.prfStand(_anna, 'cred-1');
        expect(stand.verifiziert, isTrue);
        expect(stand.stale, isFalse);
        expect(stand.pendingBlob, isNull);
        // der Zustand kennt die Sicherung jetzt (ehrlich: vom Server bestätigt)
        expect(g.s.prfCredentialIds, ['cred-1']);
        expect(g.s.prfBestaetigtAm, isNotNull);
        expect(g.s.prfSynchronisiert, isTrue, reason: 'der Server meldet den Passkey als synchronisiert');
        expect(g.s.sicherungBestaetigt, isFalse, reason: 'die Passkey-Sicherung zählt nie für "Gerät abgeben" (ein Passkey kann gerätegebunden sein)');
        // ein gerätegebundener Passkey: die Sicherung liegt beim Server, zählt aber nicht als synchronisiert
        srv.prfSynced = false;
        await g.ctrl.laden();
        expect(g.s.prfCredentialIds, ['cred-1']);
        expect(g.s.prfSynchronisiert, isFalse);
        srv.prfSynced = true;
        await g.ctrl.laden();
        // kein Klartext beim Server: weder die PRF-Ausgabe noch die Seeds des Schlüssels
        final server = srv.gespeichert(_anna);
        expect(server.contains(base64urlKodieren(_prf(1))), isFalse);
        expect(server.contains(base64urlKodieren(g.ctrl.lokalerSchluessel!.exportieren())), isFalse);
        // der alte Weg bleibt unberührt
        expect(fake.anfragen('PUT /me/keys'), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('PRF nicht unterstützt: nichts wird gesendet, nichts verändert, kein zweiter Versuch', () async {
        final g = await mitSchluessel();
        g.passkeys.prfAusgabe = null;
        final vorher = fake.anfragen('PUT /me/key-backup-prf').length;
        expect(await g.prf.sicherungAnlegen(), PrfAnlegen.nichtUnterstuetzt);
        expect(fake.anfragen('PUT /me/key-backup-prf').length, vorher);
        expect(g.passkeys.mitPrfBestaetigt, 1);
        expect(g.s.prfCredentialIds, isEmpty);
      });

      test('Eine Ausgabe nur aus Nullen oder mit falscher Länge zählt als "nicht unterstützt"', () async {
        final g = await mitSchluessel();
        g.passkeys.prfAusgabe = Uint8List(32);
        expect(await g.prf.sicherungAnlegen(), PrfAnlegen.nichtUnterstuetzt);
        g.passkeys.prfAusgabe = Uint8List.fromList([1, 2, 3]);
        expect(await g.prf.sicherungAnlegen(), PrfAnlegen.nichtUnterstuetzt);
        expect(fake.anfragen('PUT /me/key-backup-prf'), isEmpty);
      });

      test('Ohne lokalen Schlüssel: Fehler, nichts wird gesendet', () async {
        final g = await geraet();
        g.passkeys.prfAusgabe = _prf(1);
        await expectLater(g.prf.sicherungAnlegen(), _fehler(CryptoFehlerArt.schluessel));
        expect(fake.anfragen('PUT /me/key-backup-prf'), isEmpty);
        expect(g.passkeys.mitPrfBestaetigt, 0);
      });

      test('Zweite Auswertung liefert eine andere Ausgabe: Prüfung scheitert, die Sicherung bleibt unbestätigt', () async {
        final g = await mitSchluessel();
        g.passkeys.prfWarteschlange.addAll([_prf(1), _prf(77)]);
        await expectLater(g.prf.sicherungAnlegen(), _fehler(CryptoFehlerArt.schluessel));
        final stand = srv.prfStand(_anna, 'cred-1');
        expect(stand.verifiziert, isFalse, reason: 'nie bestätigt');
        expect(stand.pendingBlob, isNotNull);
        expect(g.s.prfCredentialIds, isEmpty);
        expect(g.s.sicherungBestaetigt, isFalse);
        expect(fake.anfragen('POST /me/key-backup-prf/verified'), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Zweite Auswertung ohne Ausgabe: nichts wird bestätigt; die Prüfung fordert genau den Passkey des Anlegens an', () async {
        final g = await mitSchluessel();
        g.passkeys.prfWarteschlange.addAll([_prf(1), null]);
        await expectLater(g.prf.sicherungAnlegen(), _fehler(CryptoFehlerArt.schluessel));
        expect(srv.prfStand(_anna, 'cred-1').verifiziert, isFalse);
        expect(g.passkeys.letzteNurCredentialId, 'cred-1', reason: 'die zweite Geste bietet nur den Passkey des Anlegens an');
        expect(fake.anfragen('POST /me/key-backup-prf/verified'), isEmpty);
      });

      test('Verfälschter Blob beim Round-Trip: Prüfung scheitert, nichts wird bestätigt', () async {
        final g = await mitSchluessel();
        srv.prfAbrufVerfaelschen = (b) => '${b.substring(0, b.length - 3)}AAA';
        await expectLater(g.prf.sicherungAnlegen(), _fehler(CryptoFehlerArt.schluessel));
        expect(srv.prfStand(_anna, 'cred-1').verifiziert, isFalse);
        expect(fake.anfragen('POST /me/key-backup-prf/verified'), isEmpty);
      });

      test('Abbruch des Passkey-Dialogs: PasskeyException, nichts gesendet', () async {
        final g = await mitSchluessel();
        g.passkeys.fehler = const PasskeyException(PasskeyFehler.abgebrochen, 'Abgebrochen.');
        await expectLater(g.prf.sicherungAnlegen(), throwsA(isA<PasskeyException>()));
        expect(fake.anfragen('PUT /me/key-backup-prf'), isEmpty);
      });

      test('Zweites Gerät ohne Schlüssel: der Passkey verbindet es (eine Geste), Marke "eigener Abruf" steht', () async {
        final a = await mitSchluessel();
        await a.prf.sicherungAnlegen();
        final b = await geraet();
        b.passkeys.prfAusgabe = _prf(1);
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.c.read(appDatabaseProvider).metaLesen(kEigenerPwAbrufSchluessel), isNull);
        expect(await b.prf.mitPasskeyVerbinden(), PrfVerbinden.verbunden);
        expect(DateTime.tryParse(await b.c.read(appDatabaseProvider).metaLesen(kEigenerPwAbrufSchluessel) ?? ''), isNotNull);
        expect(b.passkeys.mitPrfBestaetigt, 1);
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel!.exportieren(), a.ctrl.lokalerSchluessel!.exportieren());
        expect(fake.anfragen('POST /me/keys'), hasLength(1), reason: 'nie ein neuer Schlüssel');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Verbinden: falscher Passkey (andere Ausgabe), keine Sicherung, PRF nicht unterstützt', () async {
        final a = await mitSchluessel();
        await a.prf.sicherungAnlegen();
        final b = await geraet();
        b.passkeys.prfAusgabe = _prf(99);
        expect(await b.prf.mitPasskeyVerbinden(), PrfVerbinden.passtNicht);
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        b.passkeys.prfAusgabe = null;
        expect(await b.prf.mitPasskeyVerbinden(), PrfVerbinden.nichtUnterstuetzt);
        // anderer Passkey ohne Sicherung
        srv.aktivePasskeys.add('cred-2');
        b.passkeys
          ..prfAusgabe = _prf(1)
          ..prfCredentialId = 'cred-2';
        expect(await b.prf.mitPasskeyVerbinden(), PrfVerbinden.keineSicherung);
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Verbinden mit einem vom Server untergeschobenen Schlüssel: nie übernommen', () async {
        final a = await mitSchluessel();
        await a.prf.sicherungAnlegen();
        final b = await geraet();
        b.passkeys.prfAusgabe = _prf(1);
        srv.setzeSchluessel(_anna, enc: base64urlKodieren(List.filled(32, 7)), sign: base64urlKodieren(List.filled(32, 8)), version: 1);
        await expectLater(b.prf.mitPasskeyVerbinden(), throwsA(anything));
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
      }, timeout: const Timeout(Duration(minutes: 2)));

      group('automatisches Verbinden nach der Anmeldung mit Passkey', () {
        Future<_Geraet> mitSicherung() async {
          final a = await mitSchluessel();
          await a.prf.sicherungAnlegen();
          return a;
        }

        test('Gerät ohne Schlüssel: die PRF-Ausgabe der Anmeldung öffnet die Sicherung, ohne weitere Geste', () async {
          await mitSicherung();
          final b = await geraet();
          final davor = b.passkeys.mitPrfBestaetigt;
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.verbunden);
          expect(b.passkeys.mitPrfBestaetigt, davor, reason: 'keine zweite Geste');
          expect(b.s.status, E2eeStatus.bereit);
          expect(fake.anfragen('POST /me/keys'), hasLength(1));
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('Gerät mit Schlüssel: nichts geschieht, kein Abruf', () async {
          final a = await mitSicherung();
          final vorher = a.ctrl.lokalerSchluessel!.exportieren();
          final davor = fake.anfragen('GET /me/key-backup-prf').length;
          expect(await a.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.nichtNoetig);
          expect(a.ctrl.lokalerSchluessel!.exportieren(), vorher);
          expect(fake.anfragen('GET /me/key-backup-prf').length, davor);
        });

        test('Abweichender lokaler Schlüssel wird nie überschrieben', () async {
          final a = await mitSicherung();
          srv.setzeSchluessel(_anna, enc: base64urlKodieren(List.filled(32, 7)), sign: base64urlKodieren(List.filled(32, 8)), version: 2);
          await a.ctrl.laden();
          final vorher = a.ctrl.lokalerSchluessel!.exportieren();
          expect(await a.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.nichtNoetig);
          expect(a.ctrl.lokalerSchluessel!.exportieren(), vorher);
        });

        test('Person ohne Schlüssel: nie von selbst einen anlegen', () async {
          final b = await geraet();
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.nichtNoetig);
          expect(fake.anfragen('POST /me/keys'), isEmpty);
        });

        test('Keine bestätigte Sicherung zu diesem Passkey: stumm, ohne protokollierten Abruf', () async {
          await mitSicherung();
          final b = await geraet();
          final davor = fake.anfragen('GET /me/key-backup-prf').length;
          srv.aktivePasskeys.add('cred-2');
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-2', prfAusgabe: _prf(1)), AutoVerbinden.keineSicherung);
          expect(fake.anfragen('GET /me/key-backup-prf').length, davor);
          expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        });

        test('Falsche Ausgabe: der Passkey passt nicht, nichts wird übernommen', () async {
          await mitSicherung();
          final b = await geraet();
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(50)), AutoVerbinden.passkeyPasstNicht);
          expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        }, timeout: const Timeout(Duration(minutes: 2)));

        test('Unbrauchbare Ausgabe (Nullen) und Server ohne Schalter: nichtNoetig, kein Abruf', () async {
          await mitSicherung();
          final b = await geraet();
          final davor = fake.anfragen('GET /me/key-backup-prf').length;
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: Uint8List(32)), AutoVerbinden.nichtNoetig);
          srv.prfSchalter = false;
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.nichtNoetig);
          expect(fake.anfragen('GET /me/key-backup-prf').length, davor);
        });

        test('Netzfehler beim Abruf: fehlgeschlagen, nichts verändert, kein Schlüssel angelegt', () async {
          await mitSicherung();
          final b = await geraet();
          srv.verliereAntwort.add('GET /me/key-backup-prf');
          expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.fehlgeschlagen);
          expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
          expect(fake.anfragen('POST /me/keys'), hasLength(1));
        });
      });

      test('Schlüsselwechsel macht die Sicherung veraltet (nie gelöscht, zählt nicht mehr); neue Sicherung bestätigt', () async {
        final g = await mitSchluessel();
        await g.prf.sicherungAnlegen();
        expect(g.s.prfCredentialIds, ['cred-1']);
        await g.ctrl.schluesselWechseln();
        await g.ctrl.laden();
        expect(g.s.prfSicherungVeraltet, isTrue);
        expect(g.s.prfCredentialIds, isEmpty);
        expect(g.s.prfBestaetigtAm, isNull);
        expect(srv.prfStand(_anna, 'cred-1').stale, isTrue);
        expect(srv.prfStand(_anna, 'cred-1').blob, isNotNull, reason: 'nie gelöscht');
        // Verbinden mit der veralteten Sicherung: nicht mehr möglich (gehört zum alten Schlüssel)
        final b = await geraet();
        b.passkeys.prfAusgabe = _prf(1);
        expect(await b.prf.automatischVerbinden(credentialId: 'cred-1', prfAusgabe: _prf(1)), AutoVerbinden.keineSicherung);
        // erneuern
        expect(await g.prf.sicherungAnlegen(), PrfAnlegen.angelegt);
        expect(g.s.prfCredentialIds, ['cred-1']);
        expect(g.s.prfSicherungVeraltet, isFalse);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Ohne Server-Schalter ist die Funktion unsichtbar', () async {
        srv.prfSchalter = false;
        final g = await mitSchluessel();
        expect(g.s.prfSicherungVerfuegbar, isFalse);
        expect(g.s.prfCredentialIds, isEmpty);
      });

      test('Älterer Server (Felder fehlen): nie "gesichert"', () async {
        srv.prfSchalter = true;
        srv.neueFelder = false;
        final g = await mitSchluessel();
        expect(g.s.prfBestaetigtAm, isNull);
        expect(g.s.sicherungBestaetigt, isFalse);
      });
    });
  }
}
