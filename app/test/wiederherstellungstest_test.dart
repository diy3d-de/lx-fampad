// Wiederherstellungstest und Erinnerung alle 90 Tage: reine Rechnung (wann fällig), der Test mit Wiederherstellungsschlüssel, Passwort und Passkey (verändert NICHTS, übernimmt nie einen
// Schlüssel, besteht nur gegen den aktuellen Schlüssel des Servers), lokale Ablage von Zeitpunkt und Schalter, Oberfläche (360 px, Textskala 1.0 und 1.5).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/prf_state.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/wiederherstellung.dart';
import 'package:lx_fampad/data/crypto/wiederherstellungstest.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _anna = '11111111-1111-4111-8111-111111111111';
const _mail = 'anna@beispiel.de';
const _pw = 'Zebra-Kamin-Orbit-Fluss-Lampe';

Uint8List _prf() => Uint8List.fromList(List.generate(32, (i) => i + 9));
Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user, me: MeDto.fromJson(meJson(passkeys: 1)));
}

E2eeState _zustand({DateTime? rec, DateTime? pw, DateTime? prf, E2eeStatus status = E2eeStatus.bereit, bool pwVeraltet = false}) => E2eeState(
  status: status,
  hatSicherung: rec != null,
  wiederherstellungAm: rec,
  pwBestaetigtAm: pw,
  pwSicherungVeraltet: pwVeraltet,
  prfBestaetigtAm: prf,
  prfCredentialIds: prf == null ? const [] : const ['cred-1'],
);

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Rechnung: wann ist der Test fällig', () {
    final jetzt = DateTime.utc(2026, 11, 1, 12);
    final alt = jetzt.subtract(const Duration(days: 100));

    test('ohne bestätigte Sicherung gibt es nichts zu testen (nie fällig, kein Bezug)', () {
      expect(testBezug(_zustand(), const TestStand()), isNull);
      expect(testFaellig(_zustand(), const TestStand(), jetzt), isFalse);
    });

    test('Bezug = älteste bestätigte Sicherung, solange nie getestet wurde; 89 Tage nein, 90 Tage ja', () {
      final s89 = _zustand(rec: jetzt.subtract(const Duration(days: 89, hours: 23)));
      final s90 = _zustand(rec: jetzt.subtract(const Duration(days: 90)));
      expect(testFaellig(s89, const TestStand(), jetzt), isFalse);
      expect(testFaellig(s90, const TestStand(), jetzt), isTrue);
      // die älteste zählt (mehrere Wege)
      final mehr = _zustand(rec: jetzt.subtract(const Duration(days: 10)), pw: alt, prf: jetzt.subtract(const Duration(days: 20)));
      expect(testBezug(mehr, const TestStand()), alt);
    });

    test('ein Test setzt den Zähler zurück; ein Test VOR der Sicherung zählt nicht; Schalter aus = nie fällig', () {
      final s = _zustand(rec: alt);
      expect(testFaellig(s, const TestStand(), jetzt), isTrue);
      expect(testFaellig(s, TestStand(zuletzt: jetzt.subtract(const Duration(days: 5)), weg: PruefWeg.passwort), jetzt), isFalse);
      expect(testFaellig(s, TestStand(zuletzt: jetzt.subtract(const Duration(days: 95))), jetzt), isTrue);
      expect(testBezug(s, TestStand(zuletzt: alt.subtract(const Duration(days: 30)))), alt, reason: 'ein Test vor der Sicherung gilt nicht für sie');
      expect(testFaellig(s, const TestStand(erinnerungAn: false), jetzt), isFalse);
    });

    test('nur auf einem Gerät mit Schlüssel; veraltete Passwort-Sicherung zählt nicht', () {
      expect(testFaellig(_zustand(rec: alt, status: E2eeStatus.geraetNichtVerbunden), const TestStand(), jetzt), isFalse);
      expect(testBezug(_zustand(pw: alt, pwVeraltet: true), const TestStand()), isNull);
    });
  });

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Test der Sicherung ($name)', () {
      late FakeServer fake;
      late FakeE2eeServer srv;

      Future<({ProviderContainer c, TestUmgebung env, MemorySchluesselSpeicher sp})> geraet({MemorySchluesselSpeicher? speicher}) async {
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
        env.passkeys.prfAusgabe = _prf();
        env.extraOverrides.addAll([
          cryptoProviderProvider.overrideWith((ref) async => crypto),
          schluesselSpeicherProvider.overrideWithValue(sp),
          authProvider.overrideWith(() => _FesterAuth(UserDto.fromJson(userJson(id: _anna, name: 'Anna', email: _mail)))),
        ]);
        final c = env.container();
        addTearDown(c.dispose);
        addTearDown(env.db.close);
        c.read(authProvider);
        await c.read(e2eeProvider.notifier).laden();
        return (c: c, env: env, sp: sp);
      }

      /// Gerät mit Schlüssel und allen drei Sicherungen; gibt den Wiederherstellungsschlüssel (Anzeige) zurück.
      Future<(String, ProviderContainer, MemorySchluesselSpeicher, TestUmgebung)> alles() async {
        final g = await geraet();
        final ctrl = g.c.read(e2eeProvider.notifier);
        final e = await ctrl.einrichten();
        final anzeige = Wiederherstellung.anzeigen(Uint8List.fromList(e.wiederherstellungsschluessel));
        await ctrl.sicherungAblegen(e);
        final entwurf = await ctrl.pwSicherungVorbereiten(_pw);
        await ctrl.pwSicherungAblegen(entwurf, _pw);
        await g.c.read(prfSteuerungProvider).sicherungAnlegen();
        return (anzeige, g.c, g.sp, g.env);
      }

      setUp(() {
        fake = FakeServer();
        srv = FakeE2eeServer(fake)
          ..person(_anna, 'Anna', email: _mail)
          ..pwSchalter = true
          ..prfSchalter = true;
      });

      test('Wiederherstellungsschlüssel: besteht, ändert nichts (kein Schreiben beim Server, Schlüssel unverändert), merkt Zeitpunkt und Weg nur lokal', () async {
        final (anzeige, c, sp, _) = await alles();
        final p = c.read(wiederherstellungsPruefungProvider);
        expect((await p.lesen()).zuletzt, isNull);
        final lokalVorher = c.read(e2eeProvider.notifier).lokalerSchluessel!.exportieren();
        final schreibend = ['PUT /me/keys', 'POST /me/keys', 'PUT /me/key-backup', 'PUT /me/key-backup-pw', 'PUT /me/key-backup-prf'].map((r) => fake.anfragen(r).length).toList();
        await p.mitWiederherstellungsschluessel(anzeige);
        expect(['PUT /me/keys', 'POST /me/keys', 'PUT /me/key-backup', 'PUT /me/key-backup-pw', 'PUT /me/key-backup-prf'].map((r) => fake.anfragen(r).length).toList(), schreibend);
        expect(c.read(e2eeProvider.notifier).lokalerSchluessel!.exportieren(), lokalVorher);
        final stand = await p.lesen();
        expect(stand.zuletzt, isNotNull);
        expect(DateTime.now().toUtc().difference(stand.zuletzt!.toUtc()).inSeconds.abs(), lessThan(30));
        expect(stand.weg, PruefWeg.wiederherstellungsschluessel);
        // rein lokal: der Vermerk liegt im Schlüsselspeicher, nirgends beim Server
        expect(await sp.lesen(testVermerkName(_anna)), isNotNull);
        expect(srv.gespeichert(_anna).contains('wiederherstellungsschluessel'), isFalse);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Falscher Wiederherstellungsschlüssel und Schlüssel einer älteren Version: kein Vermerk', () async {
        final (anzeige, c, sp, _) = await alles();
        final p = c.read(wiederherstellungsPruefungProvider);
        final fremd = Wiederherstellung.anzeigen(Wiederherstellung.neuerSchluessel(crypto));
        await expectLater(p.mitWiederherstellungsschluessel(fremd), _fehler(CryptoFehlerArt.entschluesselung));
        await expectLater(p.mitWiederherstellungsschluessel('AAAA-BBBB'), throwsA(isA<CryptoFehler>()));
        expect(await sp.lesen(testVermerkName(_anna)), isNull);
        // der Server führt inzwischen einen anderen Schlüssel: die Sicherung lässt sich öffnen, gehört aber nicht mehr dazu
        srv.setzeSchluessel(_anna, enc: base64urlKodieren(List.filled(32, 5)), sign: base64urlKodieren(List.filled(32, 6)), version: 1);
        await expectLater(p.mitWiederherstellungsschluessel(anzeige), _fehler(CryptoFehlerArt.schluessel));
        expect(await sp.lesen(testVermerkName(_anna)), isNull);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Passwort der Passwort-Sicherung: richtig besteht, falsch nicht; Marke "eigener Abruf" wird gesetzt', () async {
        final (_, c, sp, _) = await alles();
        final p = c.read(wiederherstellungsPruefungProvider);
        await expectLater(p.mitPasswort('Falsch-Falsch-Falsch-Falsch'), _fehler(CryptoFehlerArt.entschluesselung));
        expect(await sp.lesen(testVermerkName(_anna)), isNull);
        await p.mitPasswort(_pw);
        expect((await p.lesen()).weg, PruefWeg.passwort);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Veraltete Passwort-Sicherung (nach Passwort-Reset) besteht den Test nicht', () async {
        final (_, c, sp, _) = await alles();
        srv.passwortZurueckgesetzt(_anna);
        await expectLater(c.read(wiederherstellungsPruefungProvider).mitPasswort(_pw), _fehler(CryptoFehlerArt.schluessel));
        expect(await sp.lesen(testVermerkName(_anna)), isNull);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Passkey: besteht mit der richtigen Ausgabe, scheitert mit der falschen, "nicht unterstützt" ohne Wirkung', () async {
        final (_, c, sp, env0) = await alles();
        final env = env0.passkeys;
        final p = c.read(wiederherstellungsPruefungProvider);
        env.prfAusgabe = Uint8List.fromList(List.generate(32, (i) => 200 - i));
        await expectLater(p.mitPasskey(), _fehler(CryptoFehlerArt.entschluesselung));
        expect(await sp.lesen(testVermerkName(_anna)), isNull);
        env.prfAusgabe = null;
        expect(await p.mitPasskey(), isFalse);
        expect(await sp.lesen(testVermerkName(_anna)), isNull);
        env.prfAusgabe = _prf();
        expect(await p.mitPasskey(), isTrue);
        expect((await p.lesen()).weg, PruefWeg.passkey);
      }, timeout: const Timeout(Duration(minutes: 3)));

      test('Erinnerung: Schalter und Zeitpunkt bleiben lokal erhalten (auch nach Neustart der App-Teile)', () async {
        final (anzeige, c, sp, _) = await alles();
        final p = c.read(wiederherstellungsPruefungProvider);
        expect((await p.lesen()).erinnerungAn, isTrue, reason: 'Standard an');
        await p.erinnerungSetzen(false);
        expect((await p.lesen()).erinnerungAn, isFalse);
        await p.mitWiederherstellungsschluessel(anzeige);
        // neuer Container, derselbe Schlüsselspeicher (Neustart): nichts ging verloren
        final g2 = await geraet(speicher: sp);
        final stand = await g2.c.read(wiederherstellungsPruefungProvider).lesen();
        expect(stand.erinnerungAn, isFalse);
        expect(stand.zuletzt, isNotNull);
        await g2.c.read(wiederherstellungsPruefungProvider).erinnerungSetzen(true);
        expect((await g2.c.read(wiederherstellungsPruefungProvider).lesen()).erinnerungAn, isTrue);
        // ein unlesbarer Vermerk ergibt den Standard, nie einen Fehler
        await sp.schreiben(testVermerkName(_anna), Uint8List.fromList([1, 2, 3]));
        expect((await g2.c.read(wiederherstellungsPruefungProvider).lesen()).zuletzt, isNull);
      }, timeout: const Timeout(Duration(minutes: 3)));
    });
  }

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    Future<({TestUmgebung env, FakeE2eeServer srv, MemorySchluesselSpeicher sp, String anzeige})> aufbau({required DateTime sicherungSeit}) async {
      final server = standardServer();
      server.json('GET /me', meJson(passkeys: 1, password: true, totp: true));
      final srv = FakeE2eeServer(server, standardId: fixIdAdmin)..person(fixIdAdmin, 'Anna', email: 'anna@beispiel.de');
      final env = TestUmgebung(server);
      await env.angemeldet();
      final sp = MemorySchluesselSpeicher();
      final crypto = FakeCryptoProvider();
      env.extraOverrides.addAll([cryptoProviderProvider.overrideWith((ref) async => crypto), schluesselSpeicherProvider.overrideWithValue(sp)]);
      // Stand wie nach der Einrichtung: Schlüssel auf dem Gerät und beim Server, Sicherung mit Wiederherstellungsschlüssel
      final seeds = Uint8List.fromList(List.generate(64, (i) => i + 1));
      await sp.schreiben(personenschluesselName(fixIdAdmin), seeds);
      final box = crypto.boxPaarAusSeed(seeds.sublist(0, 32));
      final sign = crypto.signPaarAusSeed(seeds.sublist(32));
      srv.setzeSchluessel(fixIdAdmin, enc: base64urlKodieren(Uint8List.fromList(box.oeffentlich)), sign: base64urlKodieren(Uint8List.fromList(sign.oeffentlich)), version: 1);
      final wk = Wiederherstellung.neuerSchluessel(crypto);
      final blob = Wiederherstellung.sicherungErstellen(crypto, schluessel: Personenschluessel.ausBytes(crypto, seeds), wiederherstellungsschluessel: wk, userId: fixIdAdmin, keyVersion: 1);
      srv.sicherungMitBlob(fixIdAdmin, blob);
      srv.jetzt = sicherungSeit;
      return (env: env, srv: srv, sp: sp, anzeige: Wiederherstellung.anzeigen(wk));
    }

    testWidgets('Neue Sicherung: keine Erinnerung, Zeile "noch nie getestet"; Test mit Schlüssel besteht und die Zeile zeigt das Datum ($s)', (tester) async {
      final a = await aufbau(sicherungSeit: DateTime.now().toUtc());
      await starteApp(tester, a.env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Verschlüsselung');
      expect(find.text('Wiederherstellung testen'), findsOneWidget);
      expect(find.text('noch nie getestet'), findsOneWidget);
      expect(find.textContaining('Es ist über 90 Tage her'), findsNothing);
      pruefeLayout(tester, 'Verschlüsselung mit Testzeile');
      await tippeText(tester, 'Wiederherstellung testen');
      expect(find.text('Mit Wiederherstellungsschlüssel testen'), findsOneWidget);
      pruefeLayout(tester, 'Wiederherstellung testen');

      // falscher Schlüssel
      await eingeben(tester, 'Wiederherstellungsschlüssel', 'AAAA-BBBB');
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Wiederherstellungsschlüssel testen'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Test bestanden'), findsNothing);
      pruefeLayout(tester, 'Test: falscher Schlüssel');

      await eingeben(tester, 'Wiederherstellungsschlüssel', a.anzeige);
      await tippe(tester, find.widgetWithText(FilledButton, 'Mit Wiederherstellungsschlüssel testen'));
      await tester.pump(const Duration(milliseconds: 200));
      await warte(tester);
      expect(find.textContaining('Test bestanden: Dein Wiederherstellungsschlüssel öffnet die Sicherung'), findsOneWidget);
      expect(find.textContaining('zuletzt getestet am'), findsOneWidget);
      expect(await a.sp.lesen(testVermerkName(fixIdAdmin)), isNotNull);
      pruefeLayout(tester, 'Test bestanden');
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.textContaining('zuletzt getestet am'), findsOneWidget);
    });

    testWidgets('Sicherung älter als 90 Tage und nie getestet: ruhige Erinnerung oben und "fällig" an der Zeile; Schalter aus blendet sie aus ($s)', (tester) async {
      final a = await aufbau(sicherungSeit: DateTime.now().toUtc().subtract(const Duration(days: 120)));
      await starteApp(tester, a.env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Verschlüsselung');
      expect(find.textContaining('Es ist über 90 Tage her'), findsOneWidget);
      expect(find.text('fällig'), findsOneWidget);
      pruefeLayout(tester, 'Erinnerung fällig');
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Wiederherstellung testen'));
      expect(find.text('Alle 90 Tage an den Test erinnern'), findsOneWidget);
      await tippe(tester, find.byType(Switch));
      await warte(tester);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      pruefeLayout(tester, 'Test-Seite mit Schalter aus');
      await tippe(tester, find.byTooltip('Zurück'));
      expect(find.textContaining('Es ist über 90 Tage her'), findsNothing);
      expect(find.text('fällig'), findsNothing);
      // nichts davon geht an den Server
      expect(a.env.server.anfragen('PUT /me/key-backup'), isEmpty);
    });
  }
}
