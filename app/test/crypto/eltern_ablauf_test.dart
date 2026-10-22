// Eltern-Wiederherstellung durch alle Beteiligten gegen einen In-Memory-Server: Kind (altes und neues Gerät), zwei Eltern. Voller Ablauf, jede Abweichung (falscher Code,
// untergeschobener Schlüssel, Abbruch, Ablehnen, Ablauf, Schlüsselwechsel, ungeprüfte Schlüssel) und die Grundsätze: nie ein neuer Schlüssel, nie ein vorhandener lokaler
// Schlüssel ersetzt, der Server sieht nie einen Schlüssel. Läuft gegen den Fake und libsodium.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/api/eltern_modelle.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/eltern_state.dart';
import 'package:lx_fampad/data/crypto/eltern_wiederherstellung.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';

import '../support/fake_crypto.dart';
import '../support/fake_e2ee_server.dart';
import '../support/fake_server.dart';
import '../support/test_app.dart';

const _papaId = '11111111-1111-4111-8111-111111111111';
const _mamaId = '22222222-2222-4222-8222-222222222222';
const _kindId = '33333333-3333-4333-8333-333333333333';

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user, me: MeDto.fromJson(meJson(passkeys: 1)));
}

class _Geraet {
  final ProviderContainer c;
  final MemorySchluesselSpeicher speicher;
  final String userId;
  _Geraet(this.c, this.speicher, this.userId);
  E2eeController get ctrl => c.read(e2eeProvider.notifier);
  E2eeState get s => c.read(e2eeProvider);
  ElternSteuerung get eltern => c.read(elternSteuerungProvider);
}

Matcher _fehler(CryptoFehlerArt art) => throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art));

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Eltern-Wiederherstellung ($name)', () {
      late FakeServer fake;
      late FakeE2eeServer srv;

      Future<_Geraet> geraet(String userId, String anzeige, Role rolle, {MemorySchluesselSpeicher? speicher}) async {
        final env = TestUmgebung(fake, store: MemoryTokenStore());
        await env.store.writeTokens(
          StoredTokens(
            accessToken: 'access-$userId',
            accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
            refreshToken: 'refresh-$userId',
            refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
            deviceId: fixDevice,
          ),
        );
        final sp = speicher ?? MemorySchluesselSpeicher();
        env.extraOverrides.addAll([
          cryptoProviderProvider.overrideWith((ref) async => crypto),
          schluesselSpeicherProvider.overrideWithValue(sp),
          authProvider.overrideWith(() => _FesterAuth(UserDto.fromJson(userJson(id: userId, name: anzeige, role: rolle.wire, email: '$anzeige@beispiel.de')))),
        ]);
        final c = env.container();
        addTearDown(c.dispose);
        addTearDown(env.db.close);
        c.read(authProvider);
        final g = _Geraet(c, sp, userId);
        await g.ctrl.laden();
        return g;
      }

      /// Familie: Papa (Admin), Mama (Elternteil), Kind; alle mit Schlüssel; jedes Gerät kennt (TOFU) die Schlüssel der anderen.
      Future<({_Geraet papa, _Geraet mama, _Geraet kind})> familie() async {
        final papa = await geraet(_papaId, 'Papa', Role.admin);
        final mama = await geraet(_mamaId, 'Mama', Role.parent);
        final kind = await geraet(_kindId, 'Kind', Role.child);
        for (final g in [papa, mama, kind]) {
          await g.ctrl.einrichten();
        }
        for (final g in [papa, mama, kind]) {
          await g.ctrl.laden();
        }
        return (papa: papa, mama: mama, kind: kind);
      }

      setUp(() {
        fake = FakeServer();
        srv = FakeE2eeServer(fake)
          ..person(_papaId, 'Papa', email: 'papa@beispiel.de', rolle: 'admin')
          ..person(_mamaId, 'Mama', email: 'mama@beispiel.de', rolle: 'parent')
          ..person(_kindId, 'Kind', email: 'kind@beispiel.de', rolle: 'child')
          ..elternSchalter = true;
      });

      Future<HilfeAnfrage> anfrageVon(_Geraet eltern) async => (await eltern.eltern.uebersicht()).anfragen.single;

      /// Das Elternteil übernimmt die (einzige) Anfrage, wie die Oberfläche es tut.
      Future<void> uebernehmen(_Geraet eltern) async => eltern.eltern.uebernehmen(await anfrageVon(eltern));

      /// Bis zum Zustand "offengelegt": neues Gerät des Kindes, Anfrage, Wartefrist, Übernahme, Offenlegung. Gibt den Kurzcode zurück.
      Future<(_Geraet, String, String)> bisOffengelegt(({_Geraet papa, _Geraet mama, _Geraet kind}) f, {_Geraet? bearbeiter}) async {
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        expect(neu.s.status, E2eeStatus.geraetNichtVerbunden);
        final dto = await neu.eltern.anfrageStellen();
        srv.jetzt = srv.jetzt.add(const Duration(hours: 25));
        await uebernehmen(bearbeiter ?? f.mama);
        final ansicht = (await neu.eltern.anfrageAktualisieren())!;
        expect(ansicht.anfrage.zustand, AnfrageZustand.offengelegt);
        expect(ansicht.kurzcode, matches(RegExp(r'^\d{8}$')));
        return (neu, dto.id, ansicht.kurzcode!);
      }

      test('Voller Ablauf: Einwilligung, Anfrage, Wartefrist, Übernahme, Kurzcode, Freigabe, Übernahme des Schlüssels; der Server sieht nie einen Schlüssel', () async {
        final f = await familie();
        final seeds = f.kind.ctrl.lokalerSchluessel!.exportieren();
        final stand = await f.kind.eltern.einwilligen();
        expect(stand.hinterlegt.toSet(), {'Papa', 'Mama'});
        expect((await f.kind.eltern.stand()).aktiv, isTrue);
        expect((await f.kind.eltern.stand()).eltern.every((e) => !e.veraltet), isTrue);

        // neues Gerät des Kindes (kein Schlüssel) stellt die Anfrage; die Wartefrist läuft
        final neu = await geraet(_kindId, 'Kind', Role.child);
        expect(neu.s.status, E2eeStatus.geraetNichtVerbunden);
        final dto = await neu.eltern.anfrageStellen();
        expect(dto.zustand, AnfrageZustand.wartet);
        expect(dto.bereitAb.difference(srv.jetzt).inHours, 24);
        var a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.zustand, AnfrageZustand.wartet);
        expect(a.kurzcode, isNull);

        // Eltern sehen die Anfrage, können aber vor Ablauf der Frist nichts tun
        final hm = await f.mama.eltern.uebersicht();
        expect(hm.kinder.map((k) => k.id), [_kindId]);
        expect(hm.anfragen.single.anfrage.zustand, AnfrageZustand.wartet);
        await expectLater(uebernehmen(f.mama), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'recovery_wait')));

        srv.jetzt = srv.jetzt.add(const Duration(hours: 25));
        await uebernehmen(f.mama);
        // das Kind-Gerät legt den flüchtigen Schlüssel offen und zeigt den Kurzcode
        a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.zustand, AnfrageZustand.offengelegt);
        expect(a.anfrage.elternteilName, 'Mama');
        final code = a.kurzcode!;

        // Papa sieht nur, dass Mama dran ist, weder Zufallszahl noch Eintrag
        final papasSicht = await anfrageVon(f.papa);
        expect(papasSicht.anfrage.challenge, isNull);
        expect(papasSicht.hinterlegungBlob, isNull);
        expect(papasSicht.offenerSchluessel, isNull);

        // Mama gibt mit dem Code frei
        final mamasSicht = await anfrageVon(f.mama);
        expect(mamasSicht.hinterlegungBlob, isNotNull);
        await f.mama.eltern.freigeben(mamasSicht, code);
        expect(srv.anfrageZustaende(), ['released']);
        expect(await f.mama.speicher.namenMitPraefix('e2ee.elternuebernahme.'), isEmpty, reason: 'der Vermerk der Übernahme ist nach der Freigabe weg');

        // das Kind-Gerät holt ab und übernimmt den Schlüssel (nach Vergleich mit dem Server)
        a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.uebernommen, isTrue);
        expect(neu.s.status, E2eeStatus.bereit);
        expect(neu.ctrl.lokalerSchluessel!.exportieren(), seeds);
        expect(srv.anfrageZustaende(), ['done']);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull, reason: 'der flüchtige Schlüssel ist weg');
        // nichts Neues beim Server: derselbe Schlüssel, keine neue Version
        expect(fake.anfragen('PUT /me/keys'), isEmpty);
        expect(fake.anfragen('POST /me/keys'), hasLength(3), reason: 'nur die Einrichtung der drei Personen');
        // der Server hat nie die Seeds gesehen (weder in Hinterlegung noch in Anfrage noch in der Übergabe)
        final alles = srv.elternGespeichert() + srv.gespeichert(_kindId);
        expect(alles.contains(base64urlKodieren(seeds)), isFalse);
        expect(alles.contains(base64urlKodieren(seeds.sublist(0, 32))), isFalse);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Falscher Kurzcode: die Anfrage wird abgelehnt, es wird nichts freigegeben', () async {
        final f = await familie();
        final (neu, _, code) = await bisOffengelegt(f);
        final falsch = code == '00000000' ? '00000001' : '00000000';
        // zwei Fehlversuche lassen die Anfrage offen, der dritte lehnt sie ab
        for (var i = 0; i < kMaxCodeVersuche - 1; i++) {
          await expectLater(f.mama.eltern.freigeben(await anfrageVon(f.mama), falsch), _fehler(CryptoFehlerArt.signatur));
          expect(srv.anfrageZustaende(), ['revealed']);
        }
        await expectLater(f.mama.eltern.freigeben(await anfrageVon(f.mama), falsch), _fehler(CryptoFehlerArt.signatur));
        expect(srv.anfrageZustaende(), ['declined']);
        final a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.zustand, AnfrageZustand.abgelehnt);
        expect(neu.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await neu.speicher.lesen(personenschluesselName(_kindId)), isNull);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Ein Server, der den flüchtigen Schlüssel austauscht: das Elternteil lehnt ab (Verpflichtung passt nicht)', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        await neu.eltern.anfrageStellen();
        srv.jetzt = srv.jetzt.add(const Duration(hours: 25));
        await uebernehmen(f.mama);
        // der Server legt statt des Schlüssels des Kindes einen eigenen offen (Fake: direkt im Zustand)
        final eigenes = ElternFalschspieler.fremdesPaar(crypto);
        srv.anfragenListe.single
          ..state = 'revealed'
          ..pub = base64urlKodieren(eigenes.$1)
          ..nonce = base64urlKodieren(eigenes.$2);
        await expectLater(f.mama.eltern.freigeben(await anfrageVon(f.mama), '12345678'), _fehler(CryptoFehlerArt.signatur));
        expect(srv.anfrageZustaende(), ['declined']);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Manipulierte Übergabe (Blob vertauscht): das Kind übernimmt nichts, die Anfrage lässt sich abbrechen', () async {
        final f = await familie();
        final (neu, id, code) = await bisOffengelegt(f);
        await f.mama.eltern.freigeben(await anfrageVon(f.mama), code);
        final a0 = srv.anfragenListe.single;
        final b = a0.freigabeBlob!;
        a0.freigabeBlob = '${b.substring(0, b.length - 4)}AAAA';
        await expectLater(neu.eltern.anfrageAktualisieren(), throwsA(isA<CryptoFehler>()));
        expect(neu.s.status, E2eeStatus.geraetNichtVerbunden);
        expect(await neu.speicher.lesen(personenschluesselName(_kindId)), isNull);
        await neu.eltern.anfrageAbbrechen(id);
        expect(srv.anfrageZustaende(), ['cancelled']);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Das Kind-Gerät kennt den Schlüssel des Elternteils nicht (nicht gemerkt): es übernimmt nichts', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        await neu.eltern.anfrageStellen();
        srv.jetzt = srv.jetzt.add(const Duration(hours: 25));
        await uebernehmen(f.mama);
        await neu.eltern.anfrageAktualisieren();
        await f.mama.eltern.freigeben(await anfrageVon(f.mama), (await neu.eltern.anfrageAktualisieren())!.kurzcode!);
        // Mamas gemerkter Schlüssel geht auf diesem Gerät verloren (z. B. "Vertrauen zurücksetzen" und seither nicht neu gesehen)
        await neu.speicher.loescheMitPraefix('e2ee.vertrauen.');
        await expectLater(neu.eltern.anfrageAktualisieren(), _fehler(CryptoFehlerArt.schluessel));
        expect(neu.s.status, E2eeStatus.geraetNichtVerbunden);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Das Elternteil kennt den Schlüssel des Kindes nicht (nicht gemerkt) oder hat einen anderen Schlüssel: keine Freigabe', () async {
        final f = await familie();
        final (_, _, code) = await bisOffengelegt(f);
        final sicht = await anfrageVon(f.mama);
        await f.mama.speicher.loescheMitPraefix('e2ee.vertrauen.');
        await expectLater(f.mama.eltern.freigeben(sicht, code), _fehler(CryptoFehlerArt.schluessel));
        expect(srv.anfrageZustaende(), ['revealed'], reason: 'nichts freigegeben, nichts abgelehnt: das Elternteil kann den Schlüssel prüfen und es erneut versuchen');
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Hinterlegung nur für Eltern mit Schlüssel, dem das Kind-Gerät vertraut; ohne Schlüssel oder ohne Vertrauen: kein Eintrag, klare Meldung', () async {
        final papa = await geraet(_papaId, 'Papa', Role.admin);
        final kind = await geraet(_kindId, 'Kind', Role.child);
        await kind.ctrl.einrichten();
        await kind.ctrl.laden();
        // Papa hat noch keinen Schlüssel: niemand kann hinterlegt werden
        await expectLater(kind.eltern.einwilligen(), _fehler(CryptoFehlerArt.schluessel));
        expect(srv.hinterlegungen, isEmpty);
        await papa.ctrl.einrichten();
        // Papa hat jetzt einen Schlüssel, das Kind-Gerät hat ihn aber noch nicht gesehen (nicht gemerkt): nicht vertraut
        await expectLater(kind.eltern.einwilligen(), _fehler(CryptoFehlerArt.schluessel));
        await kind.ctrl.laden();
        final r = await kind.eltern.einwilligen();
        expect(r.hinterlegt, ['Papa']);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Einwilligung nur auf einem Gerät mit passendem Schlüssel; Erwachsene dürfen nicht (Server 403)', () async {
        final f = await familie();
        final ohne = await geraet(_kindId, 'Kind', Role.child);
        await expectLater(ohne.eltern.einwilligen(), _fehler(CryptoFehlerArt.schluessel));
        await expectLater(f.mama.eltern.einwilligen(), throwsA(anything));
        expect(srv.hinterlegungen, isEmpty);
        expect((await f.mama.eltern.stand()).berechtigt, isFalse);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Zurücknehmen löscht die Einträge, beendet eine offene Anfrage und räumt den flüchtigen Schlüssel ab; danach keine Anfrage mehr', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        await neu.eltern.anfrageStellen();
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNotNull);
        await neu.eltern.zuruecknehmen();
        expect(srv.hinterlegungen[_kindId] ?? {}, isEmpty);
        expect(srv.anfrageZustaende(), ['cancelled']);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull);
        expect((await neu.eltern.stand()).aktiv, isFalse);
        await expectLater(neu.eltern.anfrageStellen(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'no_escrow')));
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull, reason: 'bei einem Fehler bleibt nichts liegen');
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Schlüsselwechsel eines Elternteils: die Hinterlegung ist veraltet; Aktualisieren stellt sie wieder her', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        await f.mama.ctrl.schluesselWechseln();
        await f.mama.ctrl.laden();
        await f.kind.ctrl.laden();
        var stand = await f.kind.eltern.stand();
        expect(stand.eltern.firstWhere((e) => e.id == _mamaId).veraltet, isTrue);
        expect(stand.eltern.firstWhere((e) => e.id == _papaId).veraltet, isFalse);
        // der Wechsel von Mama ist dem Kind-Gerät eine Warnung (TOFU): erst nach "akzeptieren" gilt der neue Schlüssel; bis dahin wird Mama übersprungen
        final r1 = await f.kind.eltern.einwilligen();
        expect(r1.uebersprungen, ['Mama']);
        expect(r1.hinterlegt, ['Papa']);
        expect((await f.kind.eltern.stand()).eltern.map((e) => e.id), [_papaId]);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Ablehnen durch ein Elternteil und Abbrechen durch das Kind beenden die Anfrage; eine neue ist danach möglich', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        final d1 = await neu.eltern.anfrageStellen();
        await expectLater(neu.eltern.anfrageStellen(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'recovery_open')));
        await f.papa.eltern.ablehnen(d1.id);
        expect((await neu.eltern.anfrageAktualisieren())!.anfrage.zustand, AnfrageZustand.abgelehnt);
        final d2 = await neu.eltern.anfrageStellen();
        expect(d2.id, isNot(d1.id));
        await neu.eltern.anfrageAbbrechen(d2.id);
        expect((await neu.eltern.anfrageAktualisieren())!.anfrage.zustand, AnfrageZustand.abgebrochen);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull);
        // ein Kind-Gerät, das den flüchtigen Schlüssel nicht hat (anderes Gerät), zeigt die Anfrage nur an
        final d3 = await neu.eltern.anfrageStellen();
        final anderes = await geraet(_kindId, 'Kind', Role.child);
        final a = (await anderes.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.id, d3.id);
        expect(a.kurzcode, isNull);
        await anderes.eltern.anfrageAbbrechen(d3.id); // abbrechen geht von jedem Gerät
        expect(srv.anfrageZustaende().last, 'cancelled');
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Server ändert die Zufallszahl nach dem Offenlegen: das Kind bricht ab (Anfrage abgebrochen), es wird nichts freigegeben', () async {
        final f = await familie();
        final (neu, _, _) = await bisOffengelegt(f);
        srv.anfragenListe.single.challenge = base64urlKodieren(Uint8List(16)..[0] = 9);
        await expectLater(neu.eltern.anfrageAktualisieren(), _fehler(CryptoFehlerArt.signatur));
        expect(srv.anfrageZustaende(), ['cancelled']);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull);
        expect(neu.s.status, E2eeStatus.geraetNichtVerbunden);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Adaptiver Tausch: Verpflichtung, Schlüssel und Nonce werden nach der Übernahme gemeinsam getauscht: das Elternteil bricht ab und lehnt ab', () async {
        final f = await familie();
        final (_, _, code) = await bisOffengelegt(f);
        final fremd = ElternKrypto.fluechtigesPaar(crypto);
        srv.anfragenListe.single
          ..commit = ElternKrypto.verpflichtung(crypto, fremd.oeffentlich, fremd.nonce)
          ..pub = base64urlKodieren(fremd.oeffentlich)
          ..nonce = base64urlKodieren(fremd.nonce);
        // selbst mit dem richtigen Code des echten Kindes: gültig sind nur die beim Übernehmen festgehaltenen Werte
        await expectLater(f.mama.eltern.freigeben(await anfrageVon(f.mama), code), _fehler(CryptoFehlerArt.signatur));
        expect(srv.anfrageZustaende(), ['declined']);
        expect(await f.mama.speicher.namenMitPraefix('e2ee.elternuebernahme.'), isEmpty);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Server ändert die Zufallszahl nach der Übernahme: das Elternteil lehnt ab', () async {
        final f = await familie();
        final (_, _, code) = await bisOffengelegt(f);
        srv.anfragenListe.single.challenge = base64urlKodieren(Uint8List(16)..[0] = 7);
        await expectLater(f.mama.eltern.freigeben(await anfrageVon(f.mama), code), _fehler(CryptoFehlerArt.signatur));
        expect(srv.anfrageZustaende(), ['declined']);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Übernahme auf einem anderen Gerät des Elternteils: dieses Gerät gibt nichts frei und lehnt nichts ab', () async {
        final f = await familie();
        final (_, _, code) = await bisOffengelegt(f);
        final mama2 = await geraet(_mamaId, 'Mama', Role.parent);
        await expectLater(mama2.eltern.freigeben(await anfrageVon(mama2), code), throwsA(isA<CryptoFehler>()));
        expect(srv.anfrageZustaende(), ['revealed']);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Antwort der Anfrage ging verloren: das Gerät ordnet die Anfrage über die Verpflichtung wieder zu; eine fremde Anfrage wird nicht zugeordnet', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        final paar = ElternKrypto.fluechtigesPaar(crypto);
        // das Gerät hat sein Paar gespeichert, aber die Antwort des Servers nie gesehen (id fehlt)
        Future<void> paarMerken() => neu.speicher.schreiben(
          elternAnfrageName(_kindId),
          Uint8List.fromList(utf8.encode(jsonEncode({'id': null, 'pub': base64urlKodieren(paar.oeffentlich), 'geheim': base64urlKodieren(paar.geheim), 'nonce': base64urlKodieren(paar.nonce)}))),
        );
        await paarMerken();
        // eine Anfrage mit einer anderen Verpflichtung (nicht von diesem Gerät): keine Zuordnung
        final fremd = ElternKrypto.fluechtigesPaar(crypto);
        final fremdDto = await neu.c.read(apiProvider).anfrageStellen(ElternKrypto.verpflichtung(crypto, fremd.oeffentlich, fremd.nonce));
        var a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.id, fremdDto.id);
        expect(a.kurzcode, isNull);
        await neu.eltern.anfrageAbbrechen(fremdDto.id); // räumt auch das gemerkte Paar ab
        await paarMerken();
        // die eigene Anfrage, deren Antwort verloren ging
        final dto = await neu.c.read(apiProvider).anfrageStellen(ElternKrypto.verpflichtung(crypto, paar.oeffentlich, paar.nonce));
        a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.id, dto.id);
        srv.jetzt = srv.jetzt.add(const Duration(hours: 25));
        await uebernehmen(f.mama);
        a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.zustand, AnfrageZustand.offengelegt);
        expect(a.kurzcode, matches(RegExp(r'^\d{8}$')));
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Abgelaufene Anfrage: sie endet, der flüchtige Schlüssel wird abgeräumt', () async {
        final f = await familie();
        await f.kind.eltern.einwilligen();
        final neu = await geraet(_kindId, 'Kind', Role.child);
        await neu.eltern.anfrageStellen();
        srv.jetzt = srv.jetzt.add(const Duration(days: 5));
        final a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.anfrage.zustand, AnfrageZustand.abgelaufen);
        expect(await neu.speicher.lesen(elternAnfrageName(_kindId)), isNull);
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Ein Gerät mit abweichendem lokalen Schlüssel wird nie stillschweigend ersetzt (der alte Schlüssel wandert in die Quarantäne)', () async {
        final f = await familie();
        final (neu, _, code) = await bisOffengelegt(f);
        // das neue Gerät hat inzwischen einen ANDEREN lokalen Schlüssel (z. B. aus einem früheren Versuch)
        final alt = Uint8List.fromList(List.generate(64, (i) => 250 - i));
        await neu.speicher.schreiben(personenschluesselName(_kindId), alt);
        await neu.ctrl.laden();
        expect(neu.s.status, E2eeStatus.abweichend);
        await f.mama.eltern.freigeben(await anfrageVon(f.mama), code);
        final a = (await neu.eltern.anfrageAktualisieren())!;
        expect(a.uebernommen, isTrue);
        expect(neu.ctrl.lokalerSchluessel!.exportieren(), f.kind.ctrl.lokalerSchluessel!.exportieren());
        final quarantaene = await neu.speicher.namenMitPraefix('e2ee.quarantaene.');
        expect(quarantaene, hasLength(1));
        expect(await neu.speicher.lesen(quarantaene.single), alt, reason: 'nichts gelöscht, unverändert aufbewahrt');
      }, timeout: const Timeout(Duration(minutes: 4)));

      test('Ohne Server-Schalter ist die Funktion unsichtbar', () async {
        srv.elternSchalter = false;
        final k = await geraet(_kindId, 'Kind', Role.child);
        expect(k.s.elternWiederherstellungVerfuegbar, isFalse);
      });
    });
  }
}

/// Hilfe für den Test mit dem untergeschobenen Schlüssel: ein fremdes flüchtiges Paar (Schlüssel und Nonce).
class ElternFalschspieler {
  static (Uint8List, Uint8List) fremdesPaar(dynamic crypto) {
    final p = crypto.boxPaarAusSeed(crypto.zufall(32));
    return (Uint8List.fromList(p.oeffentlich as List<int>), crypto.zufall(16) as Uint8List);
  }
}
