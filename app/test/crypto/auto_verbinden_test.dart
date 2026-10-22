// P1 "Ein Passwort für Anmeldung und Sicherung": Nach der Anmeldung mit Passwort verbindet sich ein Gerät ohne Schlüssel von selbst mit der Passwort-Sicherung
// (kein zweites Passwort). Geprüft werden der Erfolg und alle Fälle, in denen NICHTS geschehen darf: vorhandener oder abweichender lokaler Schlüssel (nie
// überschreiben), Person ohne Schlüssel (nie von selbst einen anlegen), veraltete oder fehlende Sicherung (kein unnötiger, protokollierter Abruf), falsches Passwort,
// Step-up und Netzfehler, manipulierter Schlüssel des Servers. Läuft gegen den Fake und, wo verfügbar, gegen libsodium.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/auto_verbinden.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import '../support/fake_crypto.dart';
import '../support/fake_e2ee_server.dart';
import '../support/fake_server.dart';
import '../support/test_app.dart';

const _anna = '11111111-1111-4111-8111-111111111111';
const _mail = 'anna@beispiel.de';
const _pw = 'Zebra-Kamin-Orbit-Fluss-Lampe';

/// Ein gültig geformter öffentlicher Schlüssel (32 Byte), der zu keinem lokalen Schlüssel gehört.
String _fremd(int b) => base64urlKodieren(List.filled(32, b));

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

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Hinweistexte', () {
    test('nur die Fälle, die der Person etwas sagen müssen, haben einen Text', () {
      expect(autoVerbindenText(AutoVerbinden.nichtNoetig), isNull);
      expect(autoVerbindenText(AutoVerbinden.keineSicherung), isNull);
      for (final r in [AutoVerbinden.verbunden, AutoVerbinden.veraltet, AutoVerbinden.passwortPasstNicht, AutoVerbinden.fehlgeschlagen]) {
        final t = autoVerbindenText(r)!;
        expect(t, isNotEmpty);
        expect(t.contains(_pw), isFalse);
      }
      // keine Angst machen, kein Servertext: bei einem Fehler steht ausdrücklich, dass nichts verändert wurde
      expect(autoVerbindenText(AutoVerbinden.fehlgeschlagen), contains('nichts verändert'));
    });
  });

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Automatisch verbinden ($name)', () {
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

      /// Erstes Gerät: Schlüssel eingerichtet und Passwort-Sicherung angelegt und bestätigt.
      Future<_Geraet> mitSicherung() async {
        final g = await geraet();
        await g.ctrl.einrichten();
        final e = await g.ctrl.pwSicherungVorbereiten(_pw);
        await g.ctrl.pwSicherungAblegen(e, _pw);
        return g;
      }

      int abrufe() => fake.anfragen('GET /me/key-backup-pw').length;

      setUp(() {
        fake = FakeServer();
        srv = FakeE2eeServer(fake)
          ..person(_anna, 'Anna', email: _mail)
          ..pwSchalter = true;
      });

      test('Zweites Gerät ohne Schlüssel: das Anmelde-Passwort verbindet es, ohne zweites Passwort', () async {
        final g = await mitSicherung();
        final b = await geraet();
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        final vorher = abrufe();
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.verbunden);
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel!.exportieren(), g.ctrl.lokalerSchluessel!.exportieren());
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNotNull);
        // genau ein Abruf der Sicherung, der alte Weg bleibt unberührt
        expect(abrufe() - vorher, 1);
        expect(fake.anfragen('PUT /me/keys'), isEmpty);
        expect(fake.anfragen('POST /me/keys'), hasLength(1), reason: 'nur die Einrichtung des ersten Geräts');
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Gerät mit Schlüssel: nichts geschieht, kein Abruf, Schlüssel unverändert', () async {
        final g = await mitSicherung();
        final vorher = g.ctrl.lokalerSchluessel!.exportieren();
        final davor = abrufe();
        expect(await g.ctrl.automatischVerbinden(_pw), AutoVerbinden.nichtNoetig);
        expect(g.ctrl.lokalerSchluessel!.exportieren(), vorher);
        expect(abrufe(), davor);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Lokaler Schlüssel weicht vom Server ab: nie überschrieben (die Person entscheidet unter Profil > Verschlüsselung)', () async {
        final g = await mitSicherung();
        srv.setzeSchluessel(_anna, enc: _fremd(7), sign: _fremd(8), version: 2);
        await g.ctrl.laden();
        expect(g.s.status, E2eeStatus.abweichend);
        final vorher = g.ctrl.lokalerSchluessel!.exportieren();
        expect(await g.ctrl.automatischVerbinden(_pw), AutoVerbinden.nichtNoetig);
        expect(g.ctrl.lokalerSchluessel!.exportieren(), vorher);
        expect(g.s.status, E2eeStatus.abweichend);
        expect(await g.speicher.namenMitPraefix(quarantaenePraefix(_anna)), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Person ohne Schlüssel: nie von selbst einen anlegen', () async {
        final g = await geraet();
        expect(g.s.status, E2eeStatus.keinSchluessel);
        expect(await g.ctrl.automatischVerbinden(_pw), AutoVerbinden.nichtNoetig);
        expect(fake.anfragen('POST /me/keys'), isEmpty);
        expect(await g.speicher.lesen(personenschluesselName(_anna)), isNull);
      });

      test('Keine Passwort-Sicherung (nur Wiederherstellungsschlüssel): keine Abfrage der Sicherung, kein Schlüssel', () async {
        final g = await geraet();
        await g.ctrl.sicherungAblegen(await g.ctrl.einrichten());
        final b = await geraet();
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.keineSicherung);
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(fake.anfragen('GET /me/key-backup-pw'), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Nach einem Passwort-Reset (Sicherung veraltet): "veraltet", die Sicherung wird nicht einmal abgerufen', () async {
        await mitSicherung();
        srv.passwortZurueckgesetzt(_anna);
        final b = await geraet();
        final davor = abrufe();
        expect(await b.ctrl.automatischVerbinden('Neues-Passwort-Wolke-Tisch-Baum-Vogel'), AutoVerbinden.veraltet);
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(abrufe(), davor);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Das Anmelde-Passwort ist ein anderes als das der Sicherung: "passt nicht", nichts übernommen', () async {
        await mitSicherung();
        final b = await geraet();
        expect(await b.ctrl.automatischVerbinden('Anderes-Passwort-Wolke-Tisch-Vogel'), AutoVerbinden.passwortPasstNicht);
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        // mit dem richtigen Passwort danach geht es
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.verbunden);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Step-up verlangt oder Netzfehler: "fehlgeschlagen", nichts verändert; Wiederholung klappt', () async {
        await mitSicherung();
        final b = await geraet();
        srv.stepUpNoetig = true;
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.fehlgeschlagen);
        srv.stepUpNoetig = false;
        srv.verliereAntwort.add('GET /me/key-backup-pw');
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.fehlgeschlagen);
        srv.verliereAntwort.clear();
        expect(b.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.verbunden);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Der Server nennt einen anderen öffentlichen Schlüssel als die Sicherung ergibt: nichts übernommen', () async {
        await mitSicherung();
        final b = await geraet();
        srv.setzeSchluessel(_anna, enc: _fremd(7), sign: _fremd(8), version: 1);
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.fehlgeschlagen);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNull);
        expect(b.ctrl.lokalerSchluessel, isNull);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Überlappende Ladeläufe (Seite, Chat-Schlüsselbund) überschreiben das Verbinden nicht: am Ende ist das Gerät bereit, auch für den, der auf den älteren Lauf wartet', () async {
        await mitSicherung();
        final b = await geraet();
        // mehrere Läufe laufen gleichzeitig mit dem Verbinden; keiner darf den eben übernommenen Schlüssel mit einem älteren Stand (ohne Schlüssel) überschreiben
        final laeufe = [b.ctrl.laden(), b.ctrl.laden()];
        final r = b.ctrl.automatischVerbinden(_pw);
        laeufe.add(b.ctrl.laden());
        expect(await r, AutoVerbinden.verbunden);
        await Future.wait(laeufe);
        expect(b.s.status, E2eeStatus.bereit);
        expect(b.ctrl.lokalerSchluessel, isNotNull);
        expect(await b.speicher.lesen(personenschluesselName(_anna)), isNotNull);
        // wer einen abgelösten Lauf abwartet, sieht danach den neuesten Stand
        final alt = b.ctrl.laden();
        await b.ctrl.laden();
        await alt;
        expect(b.s.status, E2eeStatus.bereit);
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('Server ohne Passwort-Sicherung (Schalter aus): nichts zu tun', () async {
        final b = await geraet();
        srv.pwSchalter = false;
        expect(await b.ctrl.automatischVerbinden(_pw), AutoVerbinden.nichtNoetig);
        expect(fake.anfragen('GET /me/key-backup-pw'), isEmpty);
      });

      test('Der Hinweis wird gesetzt (Erfolg) und enthält nie das Passwort', () async {
        await mitSicherung();
        final b = await geraet();
        final hinweis = b.c.read(autoVerbindenHinweisProvider.notifier);
        expect(await automatischVerbinden(b.ctrl, hinweis, _pw), AutoVerbinden.verbunden);
        final h = b.c.read(autoVerbindenHinweisProvider)!;
        expect(h.text, contains('verbunden'));
        expect(h.text.contains(_pw), isFalse);
        expect(h.abgebenAnbieten, isTrue, reason: 'nach dem Verbinden: Weg zurück (Gerät abgeben) anbieten');
        // ein fehlgeschlagener Versuch bietet es nicht an
        hinweis.setzen(null);
        await automatischVerbinden(b.ctrl, hinweis, 'Falsches-Passwort-Wolke-Tisch-Vogel-1');
        expect(b.c.read(autoVerbindenHinweisProvider), isNull, reason: 'Gerät ist schon verbunden: nichts zu tun, kein Hinweis');
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  }
}
