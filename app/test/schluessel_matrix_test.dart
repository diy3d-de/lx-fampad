// QM-Verlustmatrix (App), Ergänzung zu kein_datenverlust_test.dart, crypto/e2ee_controller_test.dart und loeschauftrag_test.dart.
// Was hier zusätzlich festgenagelt wird:
//  1. Wächter über den Quelltext: Wo darf die App einen Personenschlüssel überhaupt löschen? Jede neue Löschstelle fällt hier auf und braucht eine bewusste Entscheidung.
//  2. Abmelden und Anmelden mit leerer lokaler Datenbank: der Verlauf (auch über mehrere Epochen) ist mit demselben Personenschlüssel wieder lesbar; ohne ihn nicht.
//  3. Der Schlüsselspeicher wird geleert, während die App läuft (Browser: Websitedaten gelöscht, Android: Keystore zurückgesetzt): "Gerät nicht verbunden",
//     nie ein stiller neuer Schlüssel, der Server-Schlüssel bleibt unberührt, Verbinden mit dem Wiederherstellungsschlüssel gelingt.
//  4. Geschlossene Lücken L-1 (Android-Plugin löschte selbst), L-2 (Sackgasse bei dauerhaft unlesbarer Ablage) und L-7 (Bibliotheksfehler schob gesunden Schlüssel in die
//     Quarantäne): die Tests beschreiben das gewünschte Verhalten.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/wiederherstellung.dart';

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/test_app.dart';

const _anna = '11111111-1111-4111-8111-111111111111';
const _ben = '22222222-2222-4222-8222-222222222222';

// ------------------------------------------------------------------------------------------------------------- 1. Wächter

String _lies(String pfad) => File(pfad).readAsStringSync();

List<File> _libDateien() => [
  for (final f in Directory('lib').listSync(recursive: true))
    if (f is File && f.path.endsWith('.dart')) f,
];

/// Quelltext ohne Zeilen- und Blockkommentare (Kommentare dürfen die Namen nennen, der Wächter prüft nur Code).
/// Erkennt Zeichenketten (auch mit ${...}-Einsetzungen): ein "//" in einem String, etwa in einer URL, schneidet nichts ab.
String _ohneKommentare(String t) {
  final aus = StringBuffer();
  // leer = Code; sonst oben ein String-Rahmen (Anführungszeichen) oder ein Einsetzungs-Rahmen (Klammertiefe)
  final rahmen = <({String? anfuehrung, int tiefe})>[];
  var i = 0;
  while (i < t.length) {
    final c = t[i];
    final n = i + 1 < t.length ? t[i + 1] : '';
    final oben = rahmen.isEmpty ? null : rahmen.last;
    if (oben != null && oben.anfuehrung != null) {
      if (c == r'\') {
        aus..write(c)..write(n);
        i += 2;
        continue;
      }
      if (c == r'$' && n == '{') {
        rahmen.add((anfuehrung: null, tiefe: 0));
        aus.write(r'${');
        i += 2;
        continue;
      }
      if (c == oben.anfuehrung) rahmen.removeLast();
      aus.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < t.length && t[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      final ende = t.indexOf('*/', i + 2);
      i = ende < 0 ? t.length : ende + 2;
      continue;
    }
    if (c == "'" || c == '"') {
      rahmen.add((anfuehrung: c, tiefe: 0));
    } else if (oben != null) {
      if (c == '{') {
        rahmen[rahmen.length - 1] = (anfuehrung: null, tiefe: oben.tiefe + 1);
      } else if (c == '}') {
        if (oben.tiefe == 0) {
          rahmen.removeLast();
        } else {
          rahmen[rahmen.length - 1] = (anfuehrung: null, tiefe: oben.tiefe - 1);
        }
      }
    }
    aus.write(c);
    i++;
  }
  return aus.toString();
}

String _norm(String pfad) => pfad.replaceAll('\\', '/');

/// Argument eines Aufrufs `...loeschen(<arg>)` ab der öffnenden Klammer (mit Klammerzählung, einzeilig oder mehrzeilig).
String _argument(String text, int nachKlammer) {
  var tiefe = 1;
  for (var i = nachKlammer; i < text.length; i++) {
    final z = text[i];
    if (z == '(') tiefe++;
    if (z == ')' && --tiefe == 0) return text.substring(nachKlammer, i).replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  return text.substring(nachKlammer);
}

void _waechter() {
  group('Wächter: wo ein Personenschlüssel gelöscht werden darf', () {
    test('schluesselVomGeraetLoeschen: nur in e2ee_state.dart, nur von "Gerät abgeben" und vom Löschauftrag beim Start', () {
      final treffer = <String, int>{};
      for (final f in _libDateien()) {
        final n = RegExp(r'schluesselVomGeraetLoeschen\(').allMatches(_lies(f.path)).length;
        if (n > 0) treffer[_norm(f.path)] = n;
      }
      // Definition + Aufruf in geraetAbgeben + Aufruf in loeschauftraegeAbarbeiten
      expect(treffer, {'lib/data/crypto/e2ee_state.dart': 3}, reason: 'eine neue Aufrufstelle löscht Schlüssel: Entscheidung dokumentieren, dann diesen Wächter anpassen');
    });

    test('loescheMitPraefix wird nirgends aufgerufen (nur die Speicher definieren es)', () {
      for (final f in _libDateien()) {
        final pfad = _norm(f.path);
        final n = RegExp(r'loescheMitPraefix\(').allMatches(_lies(f.path)).length;
        if (pfad.startsWith('lib/data/crypto/schluessel_speicher')) continue;
        expect(n, 0, reason: '$pfad ruft loescheMitPraefix auf (löscht alle Schlüssel mit einem Präfix)');
      }
    });

    test('Löschstellen des Schlüsselspeichers in e2ee_state.dart: feste Liste (Anzahl und gelöschte Namen)', () {
      final text = _lies('lib/data/crypto/e2ee_state.dart');
      final namen = <String>[];
      for (final m in RegExp(r'\b_?speicher\.loeschen\(').allMatches(text)) {
        namen.add(_argument(text, m.end));
      }
      namen.sort();
      expect(namen, [
        '_pwVermerkName(uid)', // sicherungNachResetErneuern: Vermerk "auf diesem Gerät verifiziert" (öffentlich, kein Schlüssel)
        'altName', // _zwischenstandAufloesen: Zwischenstand nach dem Zurückschreiben des alten Schlüssels
        'altName', // schluesselWechseln: Rückrollen
        'loeschauftragName(userId)', // loeschauftragVerwerfen
        'marker', // geraetAbgeben: Auftrag zurücknehmen (Abmelden gescheitert)
        'marker', // geraetAbgeben: Auftrag nach erfolgreichem Löschen entfernen
        'name', // einrichten: nur ein soeben erzeugter, nie veröffentlichter Schlüssel (zurueck)
        'name', // loeschauftraegeAbarbeiten: Marker verwerfen
        'name', // loeschauftraegeAbarbeiten: Marker nach dem Löschen entfernen
        'name', // quarantaeneVerwerfen: nur Einträge mit dem Präfix der eigenen Quarantäne
        'name', // schluesselWechseln: Rückrollen, wenn es keinen bisherigen Schlüssel gab (alt == null)
        'n', // schluesselVomGeraetLoeschen: Quarantäne-Einträge dieser Person
        'n', // schluesselVomGeraetLoeschen: Vermerke der Übernahme einer Eltern-Anfrage (nur Anfrage-Vermerke dieser Person, keine Schlüssel)
        'testVermerkName(userId)', // schluesselVomGeraetLoeschen: Vermerk des Wiederherstellungstests (kein Schlüssel)
        'testAusName(userId)', // schluesselVomGeraetLoeschen: Vermerk "Test aus" (kein Schlüssel)
        'elternAnfrageName(userId)', // schluesselVomGeraetLoeschen: flüchtiges Paar einer Eltern-Anfrage (kein Personenschlüssel)
        r"'e2ee.kv.$userId'", // schluesselVomGeraetLoeschen
        r"'e2ee.kv.pw.$userId'", // schluesselVomGeraetLoeschen
        'personenschluesselAltName(userId)', // schluesselVomGeraetLoeschen
        'personenschluesselName(userId)', // schluesselVomGeraetLoeschen
        'postfachName(userId)', // schluesselVomGeraetLoeschen: Postfach-Schlüssel der Home-Assistant-Anbindung (kein Personenschlüssel)
        'postfachVerbindungenName(userId)', // schluesselVomGeraetLoeschen: gemerkte Token-IDs der eigenen Verbindungen (nichts Geheimes, keine Schlüssel)
      ]..sort(), reason: 'eine neue Löschstelle für Schlüssel braucht eine bewusste Entscheidung (Verlustmatrix, docs/TESTFAMILIE-SCHLUESSEL.md)');
    });

    test('der Wiper beim Abmelden (e2eeSitzungWiper, Verkettung in main.dart) löscht keinen Schlüssel', () {
      final e2ee = _lies('lib/data/crypto/e2ee_state.dart');
      final start = e2ee.indexOf('e2eeSitzungWiper(Ref ref)');
      expect(start, greaterThan(0));
      final ende = e2ee.indexOf('};', start);
      final rumpf = e2ee.substring(start, ende);
      expect(rumpf, isNot(contains('loeschen')));
      expect(rumpf, isNot(contains('schluesselSpeicherProvider')));
      final main = _lies('lib/main.dart');
      final zeile = main.split('\n').firstWhere((z) => z.contains('localDataWiperProvider.overrideWith'));
      expect(zeile, contains('e2eeSitzungWiper(ref)'));
      expect(zeile, isNot(contains('schluesselVomGeraetLoeschen')));
      expect(zeile, isNot(contains('quarantaene')));
      // der Datenbank-Wiper und der Anmeldezustand wissen nichts vom Schlüsselspeicher
      expect(_lies('lib/data/sync_state.dart'), isNot(contains('schluesselSpeicherProvider')));
      expect(_lies('lib/data/auth/auth_state.dart'), isNot(contains('schluesselSpeicherProvider')));
      expect(_lies('lib/data/auth/auth_state.dart'), isNot(contains('SchluesselSpeicher')));
    });

    test('Löschstellen des Schlüsselspeichers außerhalb von e2ee_state.dart: nur "Vertrauen zurücksetzen" (vertrauen.dart)', () {
      // ingest_kopplung.dart: Postfach-Schlüssel der Home-Assistant-Anbindung (kein Personenschlüssel; Löschen nur beim Trennen der letzten Verbindung oder "Gerät abgeben")
      final erlaubt = {'lib/data/crypto/vertrauen.dart', 'lib/data/ingest/ingest_kopplung.dart'};
      for (final f in _libDateien()) {
        final pfad = _norm(f.path);
        if (pfad == 'lib/data/crypto/e2ee_state.dart' || pfad.startsWith('lib/data/crypto/schluessel_speicher')) continue;
        final n = RegExp(r'[sS]peicher\.loeschen\(').allMatches(_lies(f.path)).length;
        if (erlaubt.contains(pfad)) continue;
        expect(n, 0, reason: '$pfad löscht Einträge im Schlüsselspeicher');
      }
    });
  });
}

// ---------------------------------------------------------------------------------------------- 2. Verlauf nach Abmelden/Anmelden

const _cora = 'cccccccc-0000-4000-8000-00000000000c';
const _annaC = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _benC = 'bbbbbbbb-0000-4000-8000-00000000000b';

void _verlauf(String name, CryptoProvider crypto) {
  group('Abmelden und Anmelden: Verlauf bleibt lesbar ($name)', () {
    late ChatWelt welt;
    late TestPerson anna, ben, cora;
    late List<TestPerson> alle;
    late Geraet a, b, c;

    setUp(() {
      welt = ChatWelt(crypto);
      anna = TestPerson(_annaC, 'Anna', crypto);
      ben = TestPerson(_benC, 'Ben', crypto);
      cora = TestPerson(_cora, 'Cora', crypto);
      alle = [anna, ben, cora];
      welt.aktiveMitglieder = [for (final p in alle) p.id];
      a = Geraet.neu(welt, anna)..mitgliederLernen(alle);
      b = Geraet.neu(welt, ben)..mitgliederLernen(alle);
      c = Geraet.neu(welt, cora)..mitgliederLernen(alle);
    });
    tearDown(() async {
      for (final g in [a, b, c]) {
        await g.schliessen();
      }
    });

    Future<void> abgleich(List<Geraet> gs, {int runden = 3}) async {
      for (var i = 0; i < runden; i++) {
        for (final g in gs) {
          await welt.abgleichen(g);
        }
      }
    }

    Future<List<String>> lesbar(Geraet g, String konv) async => [for (final n in await g.nachrichten(konv)) await g.lesen(n)];

    test('Gruppe mit zwei Epochen: lokale Daten leer (wie Abmelden), nach dem Abgleich ist alles wieder da; ohne den Personenschlüssel wäre es nicht lesbar', () async {
      final id = await a.repo.gruppeAnlegen([ben.id, cora.id], name: 'Wochenende');
      await abgleich([a, b, c]);
      await a.repo.senden(id, 'Eins vor dem Entfernen');
      await abgleich([a, b, c]);
      await b.repo.senden(id, 'Zwei von Ben');
      await abgleich([b, a, c]);
      await a.repo.teilnehmerAendern(id, weg: {cora.id}); // neue Epoche (Rotation)
      await abgleich([a, b, c]);
      await a.repo.senden(id, 'Drei nach der Rotation');
      await abgleich([a, b]);
      final vorher = await lesbar(a, id);
      expect(vorher, ['Eins vor dem Entfernen', 'Zwei von Ben', 'Drei nach der Rotation']);
      expect(a.krypto.epochenMitSchluessel(id), [1, 2]);

      // Abmelden: Datenbank leer (lokaleDatenWiper), Schlüsselbund im Arbeitsspeicher weg, Sync-Stand zurück auf Anfang. Der Personenschlüssel der Person bleibt
      // (e2eeSitzungWiper löscht ihn nie, siehe Wächter und e2ee_controller_test).
      await a.db.alleDatenLoeschen();
      a.sinceRev = 0;
      a.neuStarten();
      a.mitgliederLernen(alle);
      expect(await a.nachrichten(id), isEmpty);
      expect(a.krypto.epochenMitSchluessel(id), isEmpty);

      // Anmelden und Abgleichen: die Epochenschlüssel kommen aus den Wraps zurück, der Verlauf ist vollständig lesbar
      await abgleich([a]);
      expect(await lesbar(a, id), vorher);
      expect(a.krypto.epochenMitSchluessel(id), [1, 2]);

      // Gegenprobe: ein anderer (neuer) Personenschlüssel öffnet die alten Wraps nicht. Genau das passiert, wenn der Schlüssel beim Abmelden verloren ginge.
      final fremd = Geraet.neu(welt, TestPerson(_annaC, 'Anna', crypto))..mitgliederLernen(alle);
      addTearDown(fremd.schliessen);
      await abgleich([fremd]);
      expect((await lesbar(fremd, id)).where((t) => t.startsWith('<')).length, 3, reason: 'ohne den Schlüssel bleibt jede Nachricht unlesbar');
    });

    test('Direktchat: zweites Gerät derselben Person (Gerät verbinden) liest nach Abmelden/Anmelden am ersten weiter denselben Verlauf', () async {
      final id = await a.repo.direktChat(ben.id);
      await abgleich([a, b]);
      await a.repo.senden(id, 'Hallo Ben');
      await abgleich([a, b]);
      await a.db.alleDatenLoeschen();
      a.sinceRev = 0;
      a.neuStarten();
      a.mitgliederLernen(alle);
      await abgleich([a]);
      expect(await lesbar(a, id), ['Hallo Ben']);
      expect(await lesbar(b, id), ['Hallo Ben']);
    });
  });
}

// --------------------------------------------------------------------------------- 3. Speicher geleert, während die App läuft

class _Geraet {
  final ProviderContainer c;
  final MemorySchluesselSpeicher speicher;
  _Geraet(this.c, this.speicher);
  E2eeController get ctrl => c.read(e2eeProvider.notifier);
  E2eeState get s => c.read(e2eeProvider);
}

class _FesterAuth extends AuthController {
  final UserDto user;
  _FesterAuth(this.user);
  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user);
}

/// Wie die echte Bibliothek, aber das Ableiten aus den Seeds kann ausfallen (interner Fehler der Bibliothek, Art "bibliothek").
class _ZickendeKrypto extends FakeCryptoProvider {
  bool zicken = false;
  @override
  SchluesselPaar boxPaarAusSeed(Uint8List seed) {
    if (zicken) throw const CryptoFehler(CryptoFehlerArt.bibliothek, 'Die Verschlüsselung hat einen Fehler gemeldet.');
    return super.boxPaarAusSeed(seed);
  }
}

/// Ein Gerät der Person [id] mit eigenem (oder übergebenem) Schlüsselspeicher; im Test aufrufen (räumt über addTearDown auf).
Future<_Geraet> _geraetErzeugen(FakeServer fake, String id, String anzeige, CryptoProvider crypto, {MemorySchluesselSpeicher? speicher}) async {
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
  final s = speicher ?? MemorySchluesselSpeicher();
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => crypto),
    schluesselSpeicherProvider.overrideWithValue(s),
    authProvider.overrideWith(() => _FesterAuth(UserDto.fromJson(userJson(id: id, name: anzeige, email: null)))),
  ]);
  final c = env.container();
  addTearDown(c.dispose);
  addTearDown(env.db.close);
  c.read(authProvider);
  return _Geraet(c, s);
}

void _speicherGeleert(String name, CryptoProvider crypto) {
  group('Speicher geleert, während die App läuft ($name)', () {
    late FakeServer fake;
    late FakeE2eeServer srv;

    Future<_Geraet> geraet(String id, String anzeige) async {
      final g = await _geraetErzeugen(fake, id, anzeige, crypto);
      await g.ctrl.laden();
      return g;
    }

    setUp(() {
      fake = FakeServer();
      srv = FakeE2eeServer(fake)
        ..person(_anna, 'Anna')
        ..person(_ben, 'Ben');
      fake.json('POST /auth/logout', {'ok': true});
    });

    test('Websitedaten gelöscht / Keystore zurückgesetzt: "Gerät nicht verbunden", kein neuer Schlüssel, Server-Schlüssel unberührt; Verbinden mit dem Wiederherstellungsschlüssel stellt denselben Schlüssel her', () async {
      final a = await geraet(_anna, 'Anna');
      final einr = await a.ctrl.einrichten();
      await a.ctrl.sicherungAblegen(einr);
      final schluessel = a.ctrl.lokalerSchluessel!.exportieren();
      final serverVorher = srv.gespeichert(_anna);
      expect(a.s.status, E2eeStatus.bereit);
      expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.moeglich);

      // alles im Schlüsselspeicher ist weg (Schlüssel, Vermerke, Vertrauensablage): derselbe Speicher, App läuft weiter
      await a.speicher.loescheMitPraefix('');
      await a.ctrl.laden();
      expect(a.s.status, E2eeStatus.geraetNichtVerbunden, reason: 'der Server kennt den Schlüssel, dieses Gerät nicht mehr');
      expect(a.ctrl.lokalerSchluessel, isNull);
      expect(srv.anfragen('POST /me/keys'), 1, reason: 'laden() legt nie von selbst einen Schlüssel an');
      expect(srv.gespeichert(_anna), serverVorher, reason: 'der Server-Schlüssel und die Sicherung bleiben unberührt');
      expect(geraetAbgabeLage(a.s), GeraetAbgabeLage.nichtsZuLoeschen, reason: 'es gibt nichts zu löschen, "Gerät abgeben" wird nicht angeboten');
      expect(a.s.quarantaene, isEmpty);

      // selbst ein versehentliches einrichten() ersetzt nie den Schlüssel beim Server (409 keys_exist) und lässt lokal nichts zurück
      await expectLater(a.ctrl.einrichten(), throwsA(isA<Object>()));
      expect(srv.gespeichert(_anna), serverVorher);
      expect(await a.speicher.lesen(personenschluesselName(_anna)), isNull);
      await a.ctrl.laden();
      expect(a.s.status, E2eeStatus.geraetNichtVerbunden);

      // der Rückweg: Wiederherstellungsschlüssel (hier dasselbe Gerät, leerer Speicher)
      await a.ctrl.mitWiederherstellungVerbinden(Wiederherstellung.anzeigen(einr.wiederherstellungsschluessel));
      expect(a.s.status, E2eeStatus.bereit);
      expect(a.ctrl.lokalerSchluessel!.exportieren(), schluessel);
      expect(await a.speicher.lesen(personenschluesselName(_anna)), schluessel);
    });

    test('nur der Schlüssel fehlt, der Rest des Speichers bleibt: Quarantäne und Vermerke werden nicht angefasst', () async {
      final a = await geraet(_anna, 'Anna');
      await a.ctrl.einrichten();
      await a.speicher.schreiben('${quarantaenePraefix(_anna)}5', Uint8List.fromList([1, 2, 3]));
      await a.speicher.loeschen(personenschluesselName(_anna));
      await a.ctrl.laden();
      expect(a.s.status, E2eeStatus.geraetNichtVerbunden);
      expect(await a.speicher.lesen('${quarantaenePraefix(_anna)}5'), [1, 2, 3]);
      expect(a.s.quarantaene.map((e) => e.name), ['${quarantaenePraefix(_anna)}5']);
      // der Schlüssel in der Quarantäne zählt bei "Gerät abgeben" als etwas Eigenes, das mitgelöscht würde: nie ohne Pflicht-Haken
      expect(a.s.fruehereSchluessel, 1);
    });
  });
}

/// Geschlossene Lücken L-1, L-2 und L-7 (waren übersprungen, siehe docs/TESTFAMILIE-SCHLUESSEL.md, Abschnitt 3).
void _luecken() {
  group('Geschlossene Lücken', () {
    late FakeServer fake;
    late FakeE2eeServer srv;

    setUp(() {
      fake = FakeServer();
      srv = FakeE2eeServer(fake)
        ..person(_anna, 'Anna')
        ..person(_ben, 'Ben');
      fake.json('POST /auth/logout', {'ok': true});
    });

    test(
      'ein interner Fehler der Bibliothek (Art "bibliothek") darf einen gesunden Schlüssel nicht in die Quarantäne schieben',
      () async {
        final z = _ZickendeKrypto();
        final a = await _geraetErzeugen(fake, _anna, 'Anna', z);
        final speicher = a.speicher;
        await a.ctrl.laden();
        await a.ctrl.einrichten();
        final vorher = await speicher.lesen(personenschluesselName(_anna));
        expect(vorher, isNotNull);
        // neue App-Sitzung (neuer Controller), die Bibliothek meldet beim Ableiten einen internen Fehler
        a.c.invalidate(e2eeProvider);
        z.zicken = true;
        await a.ctrl.laden();
        // gewünscht: der Eintrag bleibt unter seinem Namen liegen (vorübergehender Fehler), die Seite meldet "nicht verfügbar"
        expect(await speicher.lesen(personenschluesselName(_anna)), vorher, reason: 'der gesunde Schlüssel liegt jetzt in der Quarantäne statt unter seinem Namen');
        expect(srv.anfragen('POST /me/keys'), 1);
        expect(a.s.status, E2eeStatus.nichtVerfuegbar);
        expect(a.s.quarantaene, isEmpty);
        // der Fehler ist vorbei: der nächste Versuch findet den Schlüssel wieder
        z.zicken = false;
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.bereit);
      },
    );

    test(
      'Wrapper-Schlüssel / Keystore weg, alle Einträge dauerhaft unlesbar: Schlüssel in die Quarantäne, danach "Gerät nicht verbunden" mit Weg zum Verbinden (kein Sackgassen-Zustand)',
      () async {
        final krypto = FakeCryptoProvider();
        final ben = await _geraetErzeugen(fake, _ben, 'Ben', krypto);
        await ben.ctrl.laden();
        await ben.ctrl.einrichten();
        final s = _WrapperWeg();
        final a = await _geraetErzeugen(fake, _anna, 'Anna', krypto, speicher: s);
        await a.ctrl.laden();
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        expect(await s.lesen('e2ee.vertrauen.$_anna'), isNotNull, reason: 'Bens Schlüssel ist gemerkt (die Vertrauensablage ist im Speicher)');
        // wie im Browser, wenn der Wrapper-Schlüssel fehlt, aber die Einträge noch da sind (oder Android-Keystore-Schlüssel verloren ohne Plugin-Reset)
        s.weg = true;
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.geraetNichtVerbunden, reason: 'ist ${a.s.status}: "${a.s.meldung}"; die Seite bietet dann nur "Erneut versuchen"');
        expect(a.s.quarantaene, hasLength(1));
        // klare Meldung und der Weg zum bewussten Zurücksetzen des Vertrauens (die gemerkten Schlüssel sind mit dem Speicher verloren)
        expect(a.s.vertrauenDefekt, isTrue);
        expect(a.s.meldung, contains('nicht mehr lesbar'));
        expect(a.s.hatSicherung, isTrue, reason: 'die Seite braucht das für "Mit Wiederherstellungsschlüssel verbinden"');
      },
    );

    test(
      'Android, Keystore-Schlüssel verloren: Lesen, Schreiben und Löschen scheitern dauerhaft, nichts lässt sich verschieben: "Gerät nicht verbunden" mit ehrlicher Meldung (kein "aufbewahrt")',
      () async {
        final krypto = FakeCryptoProvider();
        final s = _AndroidKaputt();
        final a = await _geraetErzeugen(fake, _anna, 'Anna', krypto, speicher: s);
        await a.ctrl.laden();
        final einr = await a.ctrl.einrichten();
        await a.ctrl.sicherungAblegen(einr);
        s.kaputt = true;
        await a.ctrl.laden();
        expect(a.s.status, E2eeStatus.geraetNichtVerbunden, reason: 'ist ${a.s.status}: "${a.s.meldung}"');
        expect(a.s.vertrauenDefekt, isTrue);
        expect(a.s.quarantaene, isEmpty, reason: 'es wurde nichts verschoben');
        expect(a.s.meldung, contains('nicht mehr lesbar'));
        expect(a.s.meldung, isNot(contains('aufbewahrt')), reason: 'auf Android wurde nichts beiseitegelegt');
        expect(a.s.meldung, contains('beim ersten Sehen neu gemerkt'));
        expect(a.s.meldung, contains('Sicherheitscodes'));
      },
    );

    test(
      'der Android-Speicher darf nie selbst löschen: FlutterSecureStorage mit resetOnError: false',
      () {
        // flutter_secure_storage setzt resetOnError standardmäßig auf true und löscht bei jedem Lesefehler den Eintrag (read) bzw. alles (readAll), bevor die App den Fehler sieht.
        // Darum erzeugt genau EINE Datei ein FlutterSecureStorage (sicherer_speicher.dart): den Alltagszugang kSicherSpeicher mit resetOnError: false und die EINE bewusste
        // Reparatur (resetOnError: true, nur über GeraeteSpeicher.zuruecksetzen nach Probe und Rückfrage). Alle anderen benutzen kSicherSpeicher.
        const erlaubt = 'lib/data/crypto/sicherer_speicher.dart';
        final quelle = _ohneKommentare(_lies(erlaubt));
        expect(RegExp(r'FlutterSecureStorage\s*\(').allMatches(quelle).length, 2, reason: 'genau der Alltagszugang und die eine Reparatur');
        expect(RegExp(r'AndroidOptions\(resetOnError: false\)').allMatches(quelle).length, 1);
        expect(RegExp(r'AndroidOptions\(resetOnError: true\)').allMatches(quelle).length, 1);
        expect(RegExp(r'_kReparaturSpeicher').allMatches(quelle).length, 2, reason: 'Definition und ein Vorgabewert in PluginGeraeteSpeicher: die Reparatur wird sonst nirgends benutzt');
        expect(RegExp(r'\.deleteAll\(').allMatches(quelle).length, 1, reason: 'deleteAll nur in der Reparatur');
        // jede Dart-Datei außerhalb von test/ (lib/ und tool/) und jede Android-Quelle: kein weiterer Zugang
        final dateien = <File>[
          ..._libDateien(),
          for (final ordner in ['tool', 'android/app/src'])
            if (Directory(ordner).existsSync())
              for (final f in Directory(ordner).listSync(recursive: true))
                if (f is File && RegExp(r'\.(dart|kt|java)$').hasMatch(f.path) && !f.path.endsWith('GeneratedPluginRegistrant.java')) f,
        ];
        for (final f in dateien) {
          final pfad = _norm(f.path);
          if (pfad == erlaubt) continue;
          final text = _ohneKommentare(_lies(f.path));
          expect(RegExp(r'FlutterSecureStorage\s*\(').hasMatch(text), isFalse, reason: '$pfad erzeugt ein FlutterSecureStorage mit den Standardoptionen (resetOnError: true): kSicherSpeicher benutzen');
          expect(RegExp(r'EncryptedSharedPreferences|resetOnError|deleteAll\(').hasMatch(text), isFalse, reason: '$pfad greift am Gerätespeicher vorbei');
        }
        for (final p in ['lib/data/crypto/schluessel_speicher_io.dart', 'lib/data/api/token_store.dart', 'lib/data/erinnerungen/erinnerung_einstellungen.dart']) {
          expect(_ohneKommentare(_lies(p)), contains('kSicherSpeicher'), reason: p);
        }
      },
    );

    test('der Kommentar-Filter lässt Zeichenketten mit "//" (URLs) und Einsetzungen unberührt', () {
      final t = _ohneKommentare("final u = 'https://x.de/a'; // FlutterSecureStorage(\nfinal v = '\${a ? 'b' : \"//c\"}'; /* deleteAll( */ final w = 1;");
      expect(t, contains("'https://x.de/a'"));
      expect(t, contains('//c'));
      expect(t, contains('final w = 1;'));
      expect(t, isNot(contains('FlutterSecureStorage')));
      expect(t, isNot(contains('deleteAll')));
    });

    test('Reparatur des Gerätespeichers: genau ein Zugriff auf den Provider und ein zuruecksetzen()-Aufruf, beide in geraetespeicher_reparatur.dart, nach der Wortbestätigung', () {
      const reparatur = 'lib/features/auth/geraetespeicher_reparatur.dart';
      const definition = 'lib/data/crypto/sicherer_speicher.dart';
      final providerStellen = <String>[];
      final aufrufe = <String>[];
      for (final f in _libDateien()) {
        final pfad = _norm(f.path);
        final text = _ohneKommentare(_lies(f.path));
        if (pfad != definition) {
          for (var i = 0; i < RegExp(r'\bgeraeteSpeicherProvider\b').allMatches(text).length; i++) {
            providerStellen.add(pfad);
          }
          expect(RegExp(r'\bPluginGeraeteSpeicher\b').hasMatch(text), isFalse, reason: '$pfad baut die Reparatur selbst zusammen');
        }
        // zuruecksetzen() auf einem GeraeteSpeicher: der Aufruf in der Reparatur; die Vertrauensablage (VertrauensPruefer.zuruecksetzen) hat ihre eigene Rückfrage
        for (final m in RegExp(r'(\w+)\.zuruecksetzen\(').allMatches(text)) {
          if (m.group(1) != 'speicher' || pfad != reparatur) {
            if (pfad == 'lib/data/crypto/e2ee_state.dart') continue; // `VertrauensPruefer(...).zuruecksetzen()`
            fail('$pfad ruft ${m.group(0)} auf');
          }
        }
        for (final _ in RegExp(r'\bspeicher\.zuruecksetzen\(').allMatches(text)) {
          aufrufe.add(pfad);
        }
      }
      expect(providerStellen, [reparatur]);
      expect(aufrufe, [reparatur]);
      final code = _ohneKommentare(_lies(reparatur));
      final wort = code.indexOf('wortBestaetigen(');
      final aufruf = code.indexOf('speicher.zuruecksetzen(');
      expect(wort, greaterThan(0));
      expect(aufruf, greaterThan(wort), reason: 'zuerst die Rückfrage mit getipptem Wort');
      final proben = [for (final m in RegExp(r'speicher\.nachweislichDefekt\(').allMatches(code)) m.start];
      expect(proben.where((p) => p < wort), isNotEmpty, reason: 'Probe vor der Rückfrage');
      expect(proben.where((p) => p > wort && p < aufruf), isNotEmpty, reason: 'Probe noch einmal direkt vor dem Löschen');
    });
  });
}

/// Speicher, dessen Einträge auf Wunsch dauerhaft unlesbar werden (Web: Wrapper-Schlüssel fehlt). Verschieben (Quarantäne) geht weiter, wie im Browser.
class _WrapperWeg extends MemorySchluesselSpeicher {
  bool weg = false;
  @override
  Future<Uint8List?> lesen(String name) async {
    final roh = await super.lesen(name);
    if (weg && roh != null) throw const SchluesselSpeicherFehler('Schlüsseleintrag nicht entschlüsselbar', dauerhaft: true);
    return roh;
  }
}

/// Android mit verlorenem Keystore-Schlüssel (resetOnError: false, der Speicher heilt sich nicht): Lesen, Schreiben und Löschen scheitern dauerhaft, Verschieben geht nicht,
/// der Index gilt als leer (wie in SecureSchluesselSpeicher).
class _AndroidKaputt extends MemorySchluesselSpeicher {
  bool kaputt = false;
  static const _f = SchluesselSpeicherFehler('Schlüsselspeicher nicht lesbar', dauerhaft: true);

  @override
  Future<Uint8List?> lesen(String name) async => kaputt ? throw _f : super.lesen(name);
  @override
  Future<void> schreiben(String name, Uint8List bytes) async => kaputt ? throw _f : super.schreiben(name, bytes);
  @override
  Future<void> loeschen(String name) async => kaputt ? throw _f : super.loeschen(name);
  @override
  Future<bool> verschiebe(String von, String nach) async => kaputt ? false : super.verschiebe(von, nach);
  @override
  Future<List<String>> namenMitPraefix(String praefix) async => kaputt ? [] : super.namenMitPraefix(praefix);
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true; // je Gerät eine eigene In-Memory-Datenbank
  _waechter();
  _luecken();
  for (final (name, crypto) in await kryptoVarianten()) {
    _verlauf(name, crypto);
    _speicherGeleert(name, crypto);
  }
}
