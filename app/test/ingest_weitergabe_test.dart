// Home-Assistant-Anbindung, Mehrgeräte-Weitergabe des Postfach-Schlüssels (Abschnitt 6l): Verschlüsselung und Format (Rundlauf, AAD, Version, Länge, Merkliste), die Abläufe auf
// Abholgerät und Zielgerät gegen den Fake-Server (Code einmal einlösbar, falscher/abgelaufener Code, Abbruch, schon vorhanden, anderer Schlüssel bleibt, Speicherfehler verbrauchen den
// Code nie) und die Doppelabholung zweier Geräte (kein doppelter Eintrag nach dem Zusammenführen, beide quittieren sicher). Mit dem Fake der Kryptobausteine; die echte libsodium-Prüfung
// des Rundlaufs läuft in der CI (test/sodium_*), die Verfahren (hash, verschluesseln) sind dieselben wie bei der Geräte-Übertragung.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/crypto/uebertragung.dart';
import 'package:lx_fampad/data/ingest/ingest_dienst.dart';
import 'package:lx_fampad/data/ingest/ingest_kopplung.dart';
import 'package:lx_fampad/data/ingest/ingest_paket.dart';
import 'package:lx_fampad/data/ingest/ingest_weitergabe.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_crypto.dart';
import 'support/fake_server.dart';

const _uid = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _zStrom = 'zzzzzzzz-0000-4000-8000-000000000001';
const _t1 = 'cccccccc-0000-4000-8000-000000000001';
const _t2 = 'cccccccc-0000-4000-8000-000000000002';

/// Ein Speicher, der sich auf Wunsch verweigert.
class _Kaputt extends MemorySchluesselSpeicher {
  bool lesenFehler = false;
  bool schreibenFehler = false;

  @override
  Future<Uint8List?> lesen(String name) async {
    if (lesenFehler) throw const SchluesselSpeicherFehler('kaputt', dauerhaft: false);
    return super.lesen(name);
  }

  @override
  Future<void> schreiben(String name, Uint8List bytes) async {
    if (schreibenFehler) throw const SchluesselSpeicherFehler('kaputt', dauerhaft: false);
    return super.schreiben(name, bytes);
  }
}

class _Zugriff implements IngestZaehlerZugriff {
  final inhalte = <String, ZaehlerInhalt>{_zStrom: ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom', quelle: const ZaehlerQuelle(kanal: 'strom_bezug', pruefen: false))};
  final stand = <Stand>[];

  @override
  Future<Map<String, ZaehlerInhalt>> zaehler() async => inhalte;

  @override
  Future<List<Stand>> staende(String zaehlerId) async => List.of(stand);

  @override
  Future<void> eintragen(String zaehlerId, DateTime tag, int milli) async => stand.add(Stand(tag, milli));
}

void main() {
  tzdata.initializeTimeZones();
  final fake = FakeCryptoProvider(seed: 21);
  final paar = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 7)));
  final geheimnisMac = Uint8List.fromList(List.generate(32, (i) => 100 + i));
  PostfachSchluessel schluessel() => PostfachSchluessel(Uint8List.fromList(paar.oeffentlich), Uint8List.fromList(paar.geheim), Uint8List.fromList(geheimnisMac));

  ApiClient client(FakeServer s) {
    final store = MemoryTokenStore();
    unawaited(store.writeTokens(StoredTokens(accessToken: 'a', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'r', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: 'd')));
    return ApiClient(client: s.client, store: store, base: 'https://familie.test');
  }

  IngestWeitergabe dienst(FakeServer s, MemorySchluesselSpeicher speicher, {String? uid = _uid}) =>
      IngestWeitergabe(api: FampadApi(client(s), geraet: () async => null), krypto: () async => fake, postfach: PostfachSpeicher(speicher), ich: () => uid);

  group('Format und Verschlüsselung', () {
    test('Rundlauf: Schlüssel und Merkliste kommen unverändert an, QR und abgetippter Code führen zum selben Geheimnis', () {
      final a = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: [_t1, _t2], userId: _uid);
      expect(PostfachWeitergabe.qrText(a.geheimnis), startsWith('LXP1:'));
      for (final eingabe in [PostfachWeitergabe.qrText(a.geheimnis), PostfachWeitergabe.codeText(a.geheimnis), PostfachWeitergabe.codeText(a.geheimnis).toLowerCase().replaceAll('-', ' ')]) {
        final g = PostfachWeitergabe.geheimnisLesen(eingabe);
        expect(g, a.geheimnis);
        expect(PostfachWeitergabe.suchkennung(fake, g), a.suchkennung);
      }
      final i = PostfachWeitergabe.oeffnen(fake, blob: a.blob, geheimnis: a.geheimnis, userId: _uid);
      expect(i.schluessel.toBytes(), schluessel().toBytes());
      expect(i.verbindungen, [_t1, _t2]);
      // der Blob passt in die Grenze des Servers (1024 Zeichen), auch mit der vollen Merkliste
      final voll = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: [for (var i = 0; i < 20; i++) 'cccccccc-0000-4000-8000-${i.toString().padLeft(12, '0')}'], userId: _uid);
      expect(voll.blob.length, lessThan(1024));
      expect(voll.blob.length, greaterThan(32));
      expect(base64urlDekodieren(a.suchkennung), hasLength(32));
    });

    test('Die Suchkennung verrät das Geheimnis nicht und ist nicht die der Geräte-Übertragung', () {
      final a = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: const [], userId: _uid);
      expect(a.suchkennung, isNot(base64urlKodieren(a.geheimnis)));
      expect(a.suchkennung, isNot(Uebertragung.suchkennung(fake, a.geheimnis)));
    });

    test('Ein Code für den Personenschlüssel (LXK1) und dieser Code gelten nur für ihren Zweck (Prüfsumme)', () {
      final a = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: const [], userId: _uid);
      expect(() => Uebertragung.geheimnisLesen(PostfachWeitergabe.codeText(a.geheimnis)), throwsA(isA<CryptoFehler>()));
      expect(() => PostfachWeitergabe.geheimnisLesen(Uebertragung.codeText(a.geheimnis)), throwsA(isA<CryptoFehler>()));
      expect(() => PostfachWeitergabe.geheimnisLesen('LXP1:ABCD'), throwsA(isA<CryptoFehler>()));
      expect(() => PostfachWeitergabe.geheimnisLesen(''), throwsA(isA<CryptoFehler>()));
    });

    test('Falsche Person (AAD), falsches Geheimnis, veränderter Blob, unbekannte Version und kaputte Länge werden abgelehnt', () {
      final a = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: [_t1], userId: _uid);
      void lehntAb(String blob, Uint8List g, String uid, CryptoFehlerArt art) => expect(() => PostfachWeitergabe.oeffnen(fake, blob: blob, geheimnis: g, userId: uid), throwsA(isA<CryptoFehler>().having((e) => e.art, 'art', art)));
      lehntAb(a.blob, a.geheimnis, 'bbbbbbbb-0000-4000-8000-00000000000b', CryptoFehlerArt.entschluesselung);
      lehntAb(a.blob, fake.zufall(32), _uid, CryptoFehlerArt.entschluesselung);
      final b = base64urlDekodieren(a.blob);
      final kaputt = Uint8List.fromList(b)..[b.length - 1] ^= 1;
      lehntAb(base64urlKodieren(kaputt), a.geheimnis, _uid, CryptoFehlerArt.entschluesselung);
      final v2 = Uint8List.fromList(b)..[0] = 2;
      lehntAb(base64urlKodieren(v2), a.geheimnis, _uid, CryptoFehlerArt.version);
      lehntAb(base64urlKodieren(b.sublist(0, 40)), a.geheimnis, _uid, CryptoFehlerArt.format);
      lehntAb('nicht base64!', a.geheimnis, _uid, CryptoFehlerArt.format);
    });

    test('Merkliste: nur gültige UUIDs, höchstens 20 (die jüngsten), leer = keine Liste', () {
      final viele = [for (var i = 0; i < 25; i++) 'cccccccc-0000-4000-8000-${i.toString().padLeft(12, '0')}'];
      final a = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: ['../böse', 'tok-a', ...viele], userId: _uid);
      final i = PostfachWeitergabe.oeffnen(fake, blob: a.blob, geheimnis: a.geheimnis, userId: _uid);
      expect(i.verbindungen, viele.sublist(5));
      final leer = PostfachWeitergabe.anbieten(fake, schluessel: schluessel(), verbindungen: const ['tok-a'], userId: _uid);
      expect(PostfachWeitergabe.oeffnen(fake, blob: leer.blob, geheimnis: leer.geheimnis, userId: _uid).verbindungen, isEmpty);
    });
  });

  group('Ablauf zwischen zwei Geräten', () {
    late FakeServer server;
    late MemorySchluesselSpeicher quelle;
    late _Kaputt ziel;
    String? abgelegt; // Blob beim Server
    String? suchHash;
    var abgelaufen = false;

    setUp(() async {
      server = FakeServer();
      quelle = MemorySchluesselSpeicher();
      ziel = _Kaputt();
      abgelegt = null;
      suchHash = null;
      abgelaufen = false;
      await PostfachSpeicher(quelle).schreiben(_uid, schluessel());
      await PostfachSpeicher(quelle).verbindungenMerken(_uid, [_t1, _t2]);
      server.on('POST /ingest/postfach-transfer', (req) {
        abgelegt = req.json['blob'] as String;
        suchHash = req.json['lookup'] as String;
        return jsonAntwort({'expiresAt': DateTime.now().toUtc().add(const Duration(minutes: 2)).toIso8601String(), 'ttlSec': 120});
      });
      server.on('POST /ingest/postfach-transfer/claim', (req) {
        if (abgelegt == null || abgelaufen || req.json['lookup'] != suchHash) return fehler(404, 'not_found');
        final b = abgelegt!;
        abgelegt = null; // genau einmal
        return jsonAntwort({'blob': b});
      });
    });

    test('Abholgerät bietet an, Zielgerät übernimmt: Schlüssel und Merkliste liegen im Speicher des Zielgeräts, die Quelle bleibt unverändert, der Server sieht kein Geheimnis', () async {
      final anzeige = await dienst(server, quelle).anbieten();
      expect(anzeige.qrText, startsWith('LXP1:'));
      expect(anzeige.gueltigBis.isAfter(DateTime.now()), isTrue);
      // an den Server geht nur Suchkennung und Blob, nie das Geheimnis oder der Schlüssel
      final gesendet = jsonEncode(server.anfragen('POST /ingest/postfach-transfer').single.body);
      final g = PostfachWeitergabe.geheimnisLesen(anzeige.codeText);
      expect(gesendet, isNot(contains(base64urlKodieren(g))));
      expect(gesendet, isNot(contains(base64.encode(paar.geheim))));
      expect(gesendet, isNot(contains(base64urlKodieren(paar.geheim))));
      expect(gesendet, isNot(contains(anzeige.codeText.replaceAll('-', ''))));

      final r = await dienst(server, ziel).annehmen(anzeige.qrText);
      expect(r, WeitergabeErgebnis.uebernommen);
      final ps = PostfachSpeicher(ziel);
      expect((await ps.lesen(_uid))!.toBytes(), schluessel().toBytes());
      expect(await ps.verbindungen(_uid), [_t1, _t2]);
      expect((await PostfachSpeicher(quelle).lesen(_uid))!.toBytes(), schluessel().toBytes());
    });

    test('Der Code gilt nur einmal: ein zweites Einlösen (anderes Gerät, Mitleser) scheitert mit "abgelaufen"', () async {
      final anzeige = await dienst(server, quelle).anbieten();
      await dienst(server, ziel).annehmen(anzeige.codeText);
      final zweites = _Kaputt();
      await expectLater(dienst(server, zweites).annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.abgelaufen)));
      expect(await PostfachSpeicher(zweites).lesen(_uid), isNull);
    });

    test('Abgelaufener oder falscher Code: "abgelaufen", nichts wird geschrieben', () async {
      final anzeige = await dienst(server, quelle).anbieten();
      abgelaufen = true;
      await expectLater(dienst(server, ziel).annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.abgelaufen)));
      expect(await PostfachSpeicher(ziel).lesen(_uid), isNull);
      expect(await PostfachSpeicher(ziel).verbindungen(_uid), isNull);
      // ein anderes, gültig geformtes Geheimnis passt nicht zur abgelegten Suchkennung
      abgelaufen = false;
      final fremd = PostfachWeitergabe.codeText(fake.zufall(32));
      await expectLater(dienst(server, ziel).annehmen(fremd), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.abgelaufen)));
    });

    test('Tippfehler und fremde Codes: "Code ungültig" ohne Aufruf beim Server', () async {
      final anzeige = await dienst(server, quelle).anbieten();
      for (final e in ['', 'XXXX', 'LXP1:ABCD', anzeige.codeText.replaceFirst(RegExp('[A-Z2-7]'), anzeige.codeText[0] == 'A' ? 'B' : 'A'), Uebertragung.codeText(fake.zufall(32))]) {
        await expectLater(dienst(server, ziel).annehmen(e), throwsA(isA<WeitergabeFehler>().having((x) => x.art, 'art', WeitergabeFehlerArt.codeUngueltig)), reason: e);
      }
      expect(server.anfragen('POST /ingest/postfach-transfer/claim'), isEmpty);
    });

    test('Zielgerät hat schon genau diesen Schlüssel: "schon da", die Merkliste wird ergänzt', () async {
      await PostfachSpeicher(ziel).schreiben(_uid, schluessel());
      await PostfachSpeicher(ziel).verbindungenMerken(_uid, [_t1]);
      final anzeige = await dienst(server, quelle).anbieten();
      expect(await dienst(server, ziel).annehmen(anzeige.codeText), WeitergabeErgebnis.schonDa);
      expect(await PostfachSpeicher(ziel).verbindungen(_uid), [_t1, _t2]);
    });

    test('Zielgerät hat einen ANDEREN Schlüssel (eigene Verbindung): nichts wird überschrieben', () async {
      final anderes = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 9)));
      final eigen = PostfachSchluessel(anderes.oeffentlich, anderes.geheim, Uint8List.fromList(List.filled(32, 3)));
      await PostfachSpeicher(ziel).schreiben(_uid, eigen);
      await PostfachSpeicher(ziel).verbindungenMerken(_uid, [_t1]);
      final anzeige = await dienst(server, quelle).anbieten();
      await expectLater(dienst(server, ziel).annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.schonAnderes)));
      expect((await PostfachSpeicher(ziel).lesen(_uid))!.toBytes(), eigen.toBytes());
      expect(await PostfachSpeicher(ziel).verbindungen(_uid), [_t1]);
    });

    test('Nicht lesbarer Schlüsselspeicher auf dem Zielgerät: Fehler "Speicher", der Code wird NICHT verbraucht; Schreibfehler bleibt ohne Schlüssel', () async {
      final anzeige = await dienst(server, quelle).anbieten();
      ziel.lesenFehler = true;
      await expectLater(dienst(server, ziel).annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.speicher)));
      expect(server.anfragen('POST /ingest/postfach-transfer/claim'), isEmpty);
      expect(abgelegt, isNotNull); // der Code gilt weiter
      ziel.lesenFehler = false;
      ziel.schreibenFehler = true;
      await expectLater(dienst(server, ziel).annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.speicher)));
      ziel.schreibenFehler = false;
      expect(await PostfachSpeicher(ziel).lesen(_uid), isNull);
    });

    test('Beschädigter oder fremder Blob (anderes Konto): "beschädigt", nichts wird geschrieben', () async {
      final anzeige = await dienst(server, quelle).anbieten();
      // das Zielgerät ist als andere Person angemeldet: die AAD passt nicht
      await expectLater(dienst(server, ziel, uid: 'bbbbbbbb-0000-4000-8000-00000000000b').annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.beschaedigt)));
      expect(await PostfachSpeicher(ziel).lesen('bbbbbbbb-0000-4000-8000-00000000000b'), isNull);
    });

    test('Abholgerät ohne Schlüssel kann nichts anbieten; Speicherfehler und Server ohne Einwurf werden sauber gemeldet; ohne Anmeldung nichts', () async {
      await expectLater(dienst(server, MemorySchluesselSpeicher()).anbieten(), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.keinPostfach)));
      expect(server.anfragen('POST /ingest/postfach-transfer'), isEmpty);
      final kaputt = _Kaputt()..lesenFehler = true;
      await expectLater(dienst(server, kaputt).anbieten(), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.speicher)));
      server.on('POST /ingest/postfach-transfer', (_) => fehler(404, 'not_found'));
      await expectLater(dienst(server, quelle).anbieten(), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.nichtVerfuegbar)));
      server.on('POST /ingest/postfach-transfer', (_) => fehler(500, 'internal'));
      await expectLater(dienst(server, quelle).anbieten(), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.netz)));
      await expectLater(dienst(server, quelle, uid: null).anbieten(), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.nichtBereit)));
      await expectLater(dienst(server, ziel, uid: null).annehmen('x'), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.nichtBereit)));
    });

    test('Kind oder Person ohne Berechtigung: der Server antwortet 404/403, die App meldet "nicht möglich" bzw. "nicht verfügbar" und schreibt nichts', () async {
      server.on('POST /ingest/postfach-transfer/claim', (_) => fehler(403, 'forbidden'));
      final anzeige = await dienst(server, quelle).anbieten();
      await expectLater(dienst(server, ziel).annehmen(anzeige.codeText), throwsA(isA<WeitergabeFehler>().having((e) => e.art, 'art', WeitergabeFehlerArt.nichtBereit)));
      expect(await PostfachSpeicher(ziel).lesen(_uid), isNull);
    });

    test('Die Fehlertexte sind fest und nennen nie einen Code oder Schlüssel', () {
      for (final a in WeitergabeFehlerArt.values) {
        final t = WeitergabeFehler(a).text;
        expect(t, isNotEmpty);
        expect(t, isNot(contains('LXP1')));
        expect(t, isNot(contains('Exception')));
      }
    });
  });

  group('Zwei Abholgeräte', () {
    // Zwei Geräte derselben Person mit demselben Postfach-Schlüssel holen dasselbe Päckchen ab, bevor eines von ihnen quittiert hat (Gleichzeitigkeit). Jedes Gerät hat seine eigene
    // lokale Datenbank (hier: je ein _Zugriff); erst der Abgleich bringt die Stände zusammen. Der Server ist für beide derselbe Bestand.
    late List<Map<String, Object?>> wartende;
    late List<String> quittiertA;
    late List<String> quittiertB;
    var seq = 0;

    String einwerfen(String tag, String stand) {
      final mac = ingestMac(fake, geheimnisMac, kanal: 'strom_bezug', d: tag, t: 1793059140000, stand: stand, einheit: 'kWh');
      final klar = jsonEncode({'v': 1, 'kanal': 'strom_bezug', 'd': tag, 't': 1793059140000, 'stand': stand, 'e': 'kWh', 'mac': mac});
      final id = 'pppppppp-0000-4000-8000-${(++seq).toString().padLeft(12, '0')}';
      wartende.add({'id': id, 'box': base64.encode(fake.versiegeln(utf8Bytes(klar), paar.oeffentlich)), 'receivedAt': '2026-10-26T00:00:00.000Z'});
      return id;
    }

    FakeServer serverFuer(List<String> quittiert, {Completer<void>? bevorAckt}) {
      final s = FakeServer();
      s.on('GET /ingest/zaehler/pending', (req) => jsonAntwort({'items': [for (final w in wartende) Map.of(w)], 'next': null}));
      s.on('POST /ingest/zaehler/ack', (req) async {
        if (bevorAckt != null) await bevorAckt.future;
        final ids = (req.json['ids'] as List).cast<String>();
        quittiert.addAll(ids);
        final vorher = wartende.length;
        wartende.removeWhere((w) => ids.contains(w['id']));
        return jsonAntwort({'deleted': vorher - wartende.length});
      });
      return s;
    }

    IngestDienst abholer(FakeServer s, _Zugriff z, MemorySchluesselSpeicher sp) =>
        IngestDienst(api: FampadApi(client(s), geraet: () async => null), krypto: () async => fake, postfach: PostfachSpeicher(sp), zaehler: z, ich: () => _uid, jetzt: () => DateTime.utc(2026, 10, 26, 10));

    setUp(() {
      wartende = [];
      quittiertA = [];
      quittiertB = [];
      seq = 0;
    });

    Future<MemorySchluesselSpeicher> geraet() async {
      final sp = MemorySchluesselSpeicher();
      await PostfachSpeicher(sp).schreiben(_uid, schluessel());
      return sp;
    }

    test('Beide Geräte holen dasselbe Päckchen gleichzeitig: beide tragen lokal ein, beide quittieren ohne Fehler, nach dem Abgleich bleibt EIN Stand je Tag und keine Warnung "doppelt"', () async {
      final id = einwerfen('2026-10-26', '1234.500');
      // beide holen, BEVOR eines quittiert (die Quittung von A wartet, bis B geholt hat)
      final tor = Completer<void>();
      final za = _Zugriff();
      final zb = _Zugriff();
      final a = abholer(serverFuer(quittiertA, bevorAckt: tor), za, await geraet());
      final b = abholer(serverFuer(quittiertB), zb, await geraet());
      final fa = a.abholen();
      final lb = await b.abholen(); // B ist komplett durch (geholt, eingetragen, quittiert)
      tor.complete();
      final la = await fa;
      expect(la.ok && lb.ok, isTrue);
      expect(la.eingetragen, 1);
      expect(lb.eingetragen, 1);
      expect(la.fehler + lb.fehler, 0);
      expect(la.quittungFehlgeschlagen, isFalse);
      expect(lb.quittungFehlgeschlagen, isFalse);
      expect(quittiertA, [id]);
      expect(quittiertB, [id]);
      expect(wartende, isEmpty);
      // nach dem Abgleich: zwei Einträge mit gleichem Tag und Wert laufen zu einem Stand zusammen
      final zusammen = standeZusammenfuehren([StandQuelle('a', 1, za.stand.single), StandQuelle('b', 2, zb.stand.single)]);
      expect(zusammen, hasLength(1));
      expect(zusammen.single.milli, 1234500);
    });

    test('Holt das zweite Gerät erst nach der Quittung des ersten: es findet nichts (nie doppelt)', () async {
      einwerfen('2026-10-26', '1234.500');
      final za = _Zugriff();
      final zb = _Zugriff();
      final la = await abholer(serverFuer(quittiertA), za, await geraet()).abholen();
      final lb = await abholer(serverFuer(quittiertB), zb, await geraet()).abholen();
      expect(la.eingetragen, 1);
      expect(lb.eingetragen, 0);
      expect(lb.wartend, 0);
      expect(zb.stand, isEmpty);
    });

    test('Hat der Abgleich den Stand des anderen Geräts schon gebracht, ist das Päckchen "schon vorhanden": nichts eingetragen, aber quittiert', () async {
      final id = einwerfen('2026-10-26', '1234.500');
      final zb = _Zugriff()..stand.add(Stand(DateTime.utc(2026, 10, 26), 1234500));
      final lb = await abholer(serverFuer(quittiertB), zb, await geraet()).abholen();
      expect(lb.vorhanden, 1);
      expect(lb.eingetragen, 0);
      expect(quittiertB, [id]);
      expect(zb.stand, hasLength(1));
    });

    test('Ein Päckchen, das nur dieses Postfach betrifft, bleibt für ein Gerät mit anderem Schlüssel unberührt (nie quittiert)', () async {
      final id = einwerfen('2026-10-26', '1234.500');
      final fremdSp = MemorySchluesselSpeicher();
      final anderes = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 8)));
      await PostfachSpeicher(fremdSp).schreiben(_uid, PostfachSchluessel(anderes.oeffentlich, anderes.geheim, Uint8List.fromList(List.filled(32, 4))));
      final l = await abholer(serverFuer(quittiertB), _Zugriff(), fremdSp).abholen();
      expect(l.fremd, 1);
      expect(quittiertB, isEmpty);
      expect(wartende.map((w) => w['id']), [id]);
    });
  });
}
