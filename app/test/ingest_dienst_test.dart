// Home-Assistant-Anbindung: der Abhol-Dienst gegen den Fake-Server (Seiten mit `next`, Quittung nur für Erledigtes, 404 = nicht verfügbar, Fehler beim Eintragen = keine Quittung,
// ein Lauf zur Zeit) mit dem Fake der Kryptobausteine und einem aufzeichnenden Zugriff auf die Zähler. Die Entscheidungsregeln selbst prüft ingest_logik_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/crypto/bytes.dart' show utf8Bytes;
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/ingest/ingest_dienst.dart';
import 'package:lx_fampad/data/ingest/ingest_kopplung.dart';
import 'package:lx_fampad/data/ingest/ingest_logik.dart';
import 'package:lx_fampad/data/ingest/ingest_paket.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_crypto.dart';
import 'support/fake_server.dart';

const _uid = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _zStrom = 'zzzzzzzz-0000-4000-8000-000000000001';
const _zSolar = 'zzzzzzzz-0000-4000-8000-000000000002';

DateTime _t(int tag) => DateTime.utc(2026, 10, tag);

class _Zugriff implements IngestZaehlerZugriff {
  final Map<String, ZaehlerInhalt> inhalte;
  final Map<String, List<Stand>> staendeJeZaehler;
  final eingetragen = <({String id, DateTime tag, int milli})>[];

  /// Tage (Nummern), bei denen das Eintragen scheitert.
  final scheiternAn = <int>{};
  bool zaehlerFehler = false;
  _Zugriff(this.inhalte, [Map<String, List<Stand>>? staende]) : staendeJeZaehler = staende ?? {};

  @override
  Future<Map<String, ZaehlerInhalt>> zaehler() async {
    if (zaehlerFehler) throw StateError('keine Zähler');
    return inhalte;
  }

  /// Wird nach jedem Lesen der Stände aufgerufen (Nummer des Lesens, ab 1): ein anderes Gerät kann dazwischen schreiben.
  void Function(int aufruf)? nachLesen;
  var _lesen = 0;

  @override
  Future<List<Stand>> staende(String zaehlerId) async {
    final kopie = List.of(staendeJeZaehler[zaehlerId] ?? const <Stand>[]);
    nachLesen?.call(++_lesen);
    return kopie;
  }

  @override
  Future<void> eintragen(String zaehlerId, DateTime tag, int milli) async {
    if (scheiternAn.contains(tagNummer(tag))) throw StateError('Eintragen scheitert');
    eingetragen.add((id: zaehlerId, tag: tag, milli: milli));
    (staendeJeZaehler[zaehlerId] ??= []).add(Stand(tag, milli));
  }
}

ZaehlerInhalt _z(String name, String kanal, {bool pruefen = true}) => ZaehlerInhalt(art: ZaehlerArt.strom, name: name, quelle: ZaehlerQuelle(kanal: kanal, pruefen: pruefen));

void main() {
  tzdata.initializeTimeZones();
  final fake = FakeCryptoProvider(seed: 11);
  final paar = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 5)));
  final geheimnis = Uint8List.fromList(List.generate(32, (i) => 200 - i));
  late FakeServer server;
  late MemorySchluesselSpeicher speicher;
  late _Zugriff zugriff;
  late IngestDienst dienst;
  late List<Map<String, Object?>> wartende; // id, box, receivedAt
  late List<String> quittiert;
  var seitenGroesse = 200;
  var jetzt = DateTime.utc(2026, 10, 26, 10);
  var nummer = 0;

  String id() => 'pppppppp-0000-4000-8000-${(++nummer).toString().padLeft(12, '0')}';

  /// Legt ein Päckchen beim (Fake-)Server ab und gibt seine ID zurück.
  String einwerfen({String kanal = 'strom_bezug', String empfangen = '2026-10-26T00:00:00.000Z', required int tag, required String stand, String d = '', String? mac, Uint8List? macGeheimnis, int version = 1, Uint8List? an, String? tokenId}) {
    final datum = d.isNotEmpty ? d : '2026-10-${tag.toString().padLeft(2, '0')}';
    final m = mac ?? ingestMac(fake, macGeheimnis ?? geheimnis, kanal: kanal, d: datum, t: 1793059140000, stand: stand, einheit: 'kWh');
    final klar = jsonEncode({'v': version, 'kanal': kanal, 'd': datum, 't': 1793059140000, 'stand': stand, 'e': 'kWh', 'mac': m});
    final pid = id();
    wartende.add({'id': pid, 'box': base64.encode(fake.versiegeln(utf8Bytes(klar), an ?? paar.oeffentlich)), 'receivedAt': empfangen, 'tokenId': ?tokenId});
    return pid;
  }

  IngestDienst bauen({String? uid = _uid}) {
    final store = MemoryTokenStore();
    unawaited(store.writeTokens(StoredTokens(accessToken: 'a', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'r', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: 'd')));
    return IngestDienst(
      api: FampadApi(ApiClient(client: server.client, store: store, base: 'https://familie.test'), geraet: () async => null),
      krypto: () async => fake,
      postfach: PostfachSpeicher(speicher),
      zaehler: zugriff,
      ich: () => uid,
      jetzt: () => jetzt,
    );
  }

  setUp(() async {
    server = FakeServer();
    speicher = MemorySchluesselSpeicher();
    await PostfachSpeicher(speicher).schreiben(_uid, PostfachSchluessel(paar.oeffentlich, paar.geheim, geheimnis));
    wartende = [];
    quittiert = [];
    seitenGroesse = 200;
    jetzt = DateTime.utc(2026, 10, 26, 10);
    nummer = 0;
    zugriff = _Zugriff({_zStrom: _z('Strom', 'strom_bezug'), _zSolar: _z('Solar', 'solar_erzeugung')});
    server.on('GET /ingest/zaehler/pending', (req) {
      final nach = int.tryParse(req.query['after'] ?? '0') ?? 0;
      final limit = int.parse(req.query['limit'] ?? '200');
      final n = limit < seitenGroesse ? limit : seitenGroesse;
      // mit ?token= nur die Päckchen dieser Verbindung (wie der Server)
      final tok = req.query['token'];
      final liste = tok == null ? wartende : [for (final w in wartende) if (w['tokenId'] == tok) w];
      final seite = [
        for (final w in liste.skip(nach).take(n)) {for (final e in w.entries) if (e.key != 'tokenId') e.key: e.value},
      ];
      final weiter = nach + seite.length;
      return jsonAntwort({'items': seite, 'next': weiter < liste.length ? '$weiter' : null});
    });
    server.on('POST /ingest/zaehler/ack', (req) {
      final ids = (req.json['ids'] as List).cast<String>();
      quittiert.addAll(ids);
      wartende.removeWhere((w) => ids.contains(w['id']));
      return jsonAntwort({'deleted': ids.length});
    });
    dienst = bauen();
  });

  test('Trägt unauffällige Werte ein und quittiert genau diese; Päckchen über mehrere Seiten', () async {
    seitenGroesse = 2;
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000), Stand(_t(3), 1020000)];
    final p4 = einwerfen(tag: 4, stand: '1030.000');
    final p5 = einwerfen(tag: 5, stand: '1040.000');
    final s1 = einwerfen(kanal: 'solar_erzeugung', tag: 5, stand: '5.5004');
    final lauf = await dienst.abholen();
    expect(lauf.ok, isTrue);
    expect(lauf.eingetragen, 3);
    expect(lauf.wartend, 0);
    expect(zugriff.eingetragen.map((e) => '${e.id == _zStrom ? 'strom' : 'solar'}:${e.tag.day}:${e.milli}'), unorderedEquals(['strom:4:1030000', 'strom:5:1040000', 'solar:5:5500']));
    expect(quittiert, unorderedEquals([p4, p5, s1]));
    // 5 Päckchen... hier 3: bei Seite 2 sind es zwei Abrufe
    expect(server.anfragen('GET /ingest/zaehler/pending'), hasLength(2));
    expect(server.anfragen('GET /ingest/zaehler/pending').last.query['after'], '2');
  });

  test('Werte desselben Kanals in falscher Reihenfolge: nach Tag geordnet, nie fälschlich "kleiner"', () async {
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000), Stand(_t(3), 1020000)];
    einwerfen(tag: 6, stand: '1050.000');
    einwerfen(tag: 4, stand: '1030.000');
    einwerfen(tag: 5, stand: '1040.000');
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 3);
    expect(lauf.zuPruefen, isEmpty);
    expect(zugriff.eingetragen.map((e) => e.tag.day), [4, 5, 6]);
  });

  test('Schon vorhandener Tag (von Hand oder automatisch): nichts überschrieben, aber quittiert; doppelte Päckchen zählen einmal', () async {
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000)];
    final a = einwerfen(tag: 2, stand: '9999.000'); // anderer Wert, der Tag ist belegt
    final b = einwerfen(tag: 3, stand: '1020.000');
    final c = einwerfen(tag: 3, stand: '1020.000'); // zweites Token, derselbe Tag
    final lauf = await dienst.abholen();
    expect(lauf.vorhanden, 2);
    expect(lauf.eingetragen, 1);
    expect(zugriff.eingetragen, hasLength(1));
    expect(quittiert, unorderedEquals([a, b, c]));
  });

  test('Auffällige Werte bleiben OHNE Quittung beim Server und erscheinen in der Prüfliste', () async {
    zugriff.staendeJeZaehler[_zStrom] = [for (var i = 1; i <= 5; i++) Stand(_t(i), (1000 + 10 * i) * 1000)];
    final klein = einwerfen(tag: 6, stand: '12.4');
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 0);
    expect(quittiert, isEmpty);
    expect(lauf.wartend, 1);
    final e = lauf.zuPruefen.single;
    expect(e.paketId, klein);
    expect(e.grund, PruefGrund.kleiner);
    expect(e.milli, 12400);
    expect(e.zaehlerId, _zStrom);
    expect(e.davorMilli, 1050000);
    // beim nächsten Lauf liegt es wieder vor
    expect((await dienst.abholen()).zuPruefen.single.paketId, klein);
    expect(wartende, hasLength(1));
  });

  test('"Trotzdem eintragen" trägt ein und quittiert; "Verwerfen" quittiert nur; "erledigt" (nach Zählerwechsel) quittiert nur', () async {
    zugriff.staendeJeZaehler[_zStrom] = [for (var i = 1; i <= 5; i++) Stand(_t(i), (1000 + 10 * i) * 1000)];
    final p6 = einwerfen(tag: 6, stand: '12.4');
    final p7 = einwerfen(tag: 7, stand: '13.4');
    final p8 = einwerfen(tag: 8, stand: '14.4');
    final lauf = await dienst.abholen();
    expect(lauf.zuPruefen, hasLength(3));
    final e6 = lauf.zuPruefen.firstWhere((e) => e.paketId == p6);
    final e7 = lauf.zuPruefen.firstWhere((e) => e.paketId == p7);
    final e8 = lauf.zuPruefen.firstWhere((e) => e.paketId == p8);
    await dienst.pruefEintragen(e6);
    expect(zugriff.eingetragen.single.milli, 12400);
    expect(quittiert, [p6]);
    await dienst.verwerfen(e7);
    expect(zugriff.eingetragen, hasLength(1));
    expect(quittiert, [p6, p7]);
    await dienst.erledigt(e8);
    expect(zugriff.eingetragen, hasLength(1));
    expect(quittiert, [p6, p7, p8]);
  });

  test('"Trotzdem eintragen" überschreibt keinen Tag, für den inzwischen von Hand ein Stand da ist (nur quittiert)', () async {
    zugriff.staendeJeZaehler[_zStrom] = [for (var i = 1; i <= 5; i++) Stand(_t(i), (1000 + 10 * i) * 1000)];
    final p = einwerfen(tag: 6, stand: '12.4');
    final e = (await dienst.abholen()).zuPruefen.single;
    zugriff.staendeJeZaehler[_zStrom]!.add(Stand(_t(6), 1060000)); // inzwischen von Hand
    await dienst.pruefEintragen(e);
    expect(zugriff.eingetragen, isEmpty);
    expect(quittiert, [p]);
  });

  test('Der Schalter "Prüfen" des Zählers: ohne ihn wird ein Sprung eingetragen, ein kleinerer Stand nie', () async {
    zugriff.inhalte[_zStrom] = _z('Strom', 'strom_bezug', pruefen: false);
    zugriff.staendeJeZaehler[_zStrom] = [for (var i = 1; i <= 5; i++) Stand(_t(i), (1000 + 10 * i) * 1000)];
    einwerfen(tag: 6, stand: '2000.000'); // Sprung
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 1);
    einwerfen(tag: 7, stand: '5.000'); // kleiner als davor
    expect((await dienst.abholen()).zuPruefen, hasLength(1));
  });

  test('Ungültige Päckchen DIESES Postfachs (falscher MAC, kaputte Box) werden nie eingetragen, aber quittiert und gezählt', () async {
    final mac = einwerfen(tag: 1, stand: '1000.000', mac: 'f' * 64);
    final fremdesGeheimnis = einwerfen(tag: 2, stand: '1000.000', macGeheimnis: Uint8List(32));
    wartende.add({'id': id(), 'box': '%%%'});
    final lauf = await dienst.abholen();
    expect(lauf.ungueltig, 3);
    expect(lauf.fremd, 0);
    expect(lauf.eingetragen, 0);
    expect(zugriff.eingetragen, isEmpty);
    expect(quittiert, hasLength(3));
    expect(quittiert, containsAll([mac, fremdesGeheimnis]));
  });

  test('Päckchen, die sich nicht öffnen lassen (anderes Postfach) oder eine unbekannte Version haben, werden NIE quittiert: sie gehören einem anderen Gerät oder einer neueren App', () async {
    final anderes = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 9)));
    final fuerAnderes = einwerfen(tag: 1, stand: '1000.000', an: anderes.oeffentlich);
    final v2 = einwerfen(tag: 2, stand: '1000.000', version: 2);
    final eigenes = einwerfen(tag: 3, stand: '1000.000');
    final lauf = await dienst.abholen();
    expect(lauf.fremd, 2);
    expect(lauf.ungueltig, 0);
    expect(lauf.eingetragen, 1);
    expect(quittiert, [eigenes]);
    // beide liegen weiter beim Server und tauchen im nächsten Lauf wieder auf (immer noch ungeöffnet, immer noch nicht quittiert)
    expect(wartende.map((w) => w['id']), unorderedEquals([fuerAnderes, v2]));
    final noch = await dienst.abholen();
    expect(noch.fremd, 2);
    expect(noch.wartend, 2);
    expect(quittiert, [eigenes]);
  });

  test('Zwei Verbindungen: das Gerät holt nur die Päckchen seiner eigenen Verbindungen, Fremdes bleibt unberührt', () async {
    await PostfachSpeicher(speicher).verbindungenMerken(_uid, ['tok-a', 'tok-b']);
    final a = einwerfen(tag: 1, stand: '1000.000', tokenId: 'tok-a');
    final b = einwerfen(tag: 2, stand: '1010.000', tokenId: 'tok-b');
    // eine dritte Verbindung gehört einem anderen Abholgerät (anderes Postfach); selbst ein kaputtes oder fremdes Päckchen dort wird nicht einmal angefragt
    final anderes = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 9)));
    final fremd = einwerfen(tag: 3, stand: '1020.000', an: anderes.oeffentlich, tokenId: 'tok-x');
    final kaputt = id();
    wartende.add({'id': kaputt, 'box': '%%%', 'tokenId': 'tok-x'});
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 2);
    expect(lauf.fremd, 0);
    expect(lauf.ungueltig, 0);
    expect(quittiert, unorderedEquals([a, b]));
    expect(wartende.map((w) => w['id']), unorderedEquals([fremd, kaputt]));
    final anfragen = server.anfragen('GET /ingest/zaehler/pending');
    expect(anfragen.map((r) => r.query['token']), ['tok-a', 'tok-b']);
  });

  test('Ohne gemerkte Verbindungen (Gerät aus der Zeit davor): wie bisher alle Päckchen der Familie, aber Fremdes wird nie gelöscht', () async {
    final anderes = fake.boxPaarAusSeed(Uint8List.fromList(List.filled(32, 9)));
    einwerfen(tag: 1, stand: '1000.000');
    final fremd = einwerfen(tag: 2, stand: '1000.000', an: anderes.oeffentlich);
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 1);
    expect(lauf.fremd, 1);
    expect(server.anfragen('GET /ingest/zaehler/pending').single.query.containsKey('token'), isFalse);
    expect(wartende.map((w) => w['id']), [fremd]);
  });

  test('Die gemerkten Verbindungen liegen im Schlüsselspeicher, werden mit dem Schlüssel gelöscht und nehmen nur sichere Kennungen an', () async {
    final ps = PostfachSpeicher(speicher);
    expect(await ps.verbindungen(_uid), isNull);
    await ps.verbindungMerken(_uid, 'tok-a');
    await ps.verbindungMerken(_uid, 'tok-b');
    await ps.verbindungMerken(_uid, 'tok-a'); // doppelt: nur einmal, jetzt die jüngste
    await ps.verbindungMerken(_uid, '../böse');
    expect(await ps.verbindungen(_uid), ['tok-b', 'tok-a']);
    await ps.entfernen(_uid);
    expect(await ps.verbindungen(_uid), isNull);
    expect(await ps.lesen(_uid), isNull);
  });

  test('Höchstens 20 Verbindungen werden gemerkt (die jüngsten)', () async {
    final ps = PostfachSpeicher(speicher);
    await ps.verbindungenMerken(_uid, [for (var i = 0; i < 25; i++) 'tok-$i']);
    final l = (await ps.verbindungen(_uid))!;
    expect(l, hasLength(kMaxGemerkteVerbindungen));
    expect(l.last, 'tok-24');
    expect(l.first, 'tok-5');
  });

  test('Ein Tag mehr als einen Tag in der Zukunft ist ungültig (falsch gestellte Uhr), der heutige und der morgige zählen', () async {
    final heute = einwerfen(tag: 26, stand: '1000.000');
    final morgen = einwerfen(tag: 27, stand: '1000.000');
    final spaeter = einwerfen(tag: 28, stand: '1000.000');
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 2);
    expect(lauf.ungueltig, 1);
    expect(quittiert, unorderedEquals([heute, morgen, spaeter]));
  });

  test('Kanal ohne Zähler: bleibt beim Server (ohne Quittung), wird gezählt', () async {
    einwerfen(kanal: 'gas_bezug', tag: 5, stand: '10.000');
    final lauf = await dienst.abholen();
    expect(lauf.ohneZaehler, 1);
    expect(lauf.wartend, 1);
    expect(quittiert, isEmpty);
    expect(zugriff.eingetragen, isEmpty);
  });

  test('Fehler beim Eintragen: keine Quittung für dieses Päckchen, die anderen laufen weiter', () async {
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000), Stand(_t(3), 1020000)];
    zugriff.scheiternAn.add(tagNummer(_t(5)));
    final p4 = einwerfen(tag: 4, stand: '1030.000');
    final p5 = einwerfen(tag: 5, stand: '1040.000');
    final s = einwerfen(kanal: 'solar_erzeugung', tag: 6, stand: '1.000');
    final lauf = await dienst.abholen();
    expect(lauf.fehler, 1);
    expect(lauf.eingetragen, 2);
    expect(quittiert, unorderedEquals([p4, s]));
    expect(quittiert, isNot(contains(p5)));
    expect(lauf.wartend, 1);
    // beim nächsten Lauf (Fehler behoben) klappt es
    zugriff.scheiternAn.clear();
    final lauf2 = await dienst.abholen();
    expect(lauf2.eingetragen, 1);
    expect(quittiert, contains(p5));
  });

  test('404: der Server hat den Einwurf nicht eingeschaltet, kein Fehler, nichts wird angefasst', () async {
    server.on('GET /ingest/zaehler/pending', (_) => fehler(404, 'not_found'));
    einwerfen(tag: 1, stand: '1.000');
    final lauf = await dienst.abholen();
    expect(lauf.abbruch, IngestAbbruch.nichtVerfuegbar);
    expect(zugriff.eingetragen, isEmpty);
    expect(server.anfragen('POST /ingest/zaehler/ack'), isEmpty);
  });

  test('Kein Netz / Serverfehler: Abbruch "netz", nichts eingetragen, nichts quittiert', () async {
    server.on('GET /ingest/zaehler/pending', (_) => fehler(500, 'internal_error'));
    einwerfen(tag: 1, stand: '1.000');
    final lauf = await dienst.abholen();
    expect(lauf.abbruch, IngestAbbruch.netz);
    expect(server.anfragen('POST /ingest/zaehler/ack'), isEmpty);
  });

  test('Ein Fehler auf einer späteren Seite bricht den ganzen Lauf ab (nichts halb verarbeitet)', () async {
    seitenGroesse = 1;
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000)];
    einwerfen(tag: 2, stand: '1010.000');
    einwerfen(tag: 3, stand: '1020.000');
    var n = 0;
    final normal = server.routes['GET /ingest/zaehler/pending']!;
    server.on('GET /ingest/zaehler/pending', (req) => ++n == 2 ? fehler(503, 'server_busy') : normal(req));
    final lauf = await dienst.abholen();
    expect(lauf.abbruch, IngestAbbruch.netz);
    expect(zugriff.eingetragen, isEmpty);
    expect(quittiert, isEmpty);
  });

  test('Ohne Postfach-Schlüssel auf diesem Gerät: kein Abruf, ehrlicher Grund', () async {
    final leer = MemorySchluesselSpeicher();
    final d = IngestDienst(api: dienst.api, krypto: () async => fake, postfach: PostfachSpeicher(leer), zaehler: zugriff, ich: () => _uid);
    final lauf = await d.abholen();
    expect(lauf.abbruch, IngestAbbruch.keinSchluessel);
    expect(server.anfragen('GET /ingest/zaehler/pending'), isEmpty);
    expect(ingestAbbruchText(IngestAbbruch.keinSchluessel), contains('kann nicht abholen'));
  });

  test('Der Schlüssel eines anderen Kontos wird nie benutzt; ohne angemeldete Person kein Lauf', () async {
    expect((await bauen(uid: 'bbbbbbbb-0000-4000-8000-00000000000b').abholen()).abbruch, IngestAbbruch.keinSchluessel);
    expect((await bauen(uid: null).abholen()).abbruch, IngestAbbruch.nichtBereit);
    expect(server.log, isEmpty);
  });

  test('Ein beschädigter Schlüssel ist kein "kein Schlüssel"', () async {
    await speicher.schreiben(postfachName(_uid), Uint8List(3));
    expect((await dienst.abholen()).abbruch, IngestAbbruch.schluesselFehler);
  });

  test('Quittung abgelehnt: gemeldet; beim nächsten Lauf sind die Päckchen "schon vorhanden" und werden quittiert', () async {
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000), Stand(_t(3), 1020000)];
    final p = einwerfen(tag: 4, stand: '1030.000');
    server.on('POST /ingest/zaehler/ack', (_) => fehler(500, 'internal_error'));
    final lauf = await dienst.abholen();
    expect(lauf.quittungFehlgeschlagen, isTrue);
    expect(lauf.eingetragen, 1);
    expect(lauf.wartend, 1);
    server.on('POST /ingest/zaehler/ack', (req) {
      quittiert.addAll((req.json['ids'] as List).cast<String>());
      return jsonAntwort({'deleted': 1});
    });
    final lauf2 = await dienst.abholen();
    expect(lauf2.vorhanden, 1);
    expect(lauf2.eingetragen, 0);
    expect(zugriff.eingetragen, hasLength(1)); // nie doppelt
    expect(quittiert, [p]);
  });

  test('Quittiert in Stücken zu höchstens 200', () async {
    for (var i = 0; i < 450; i++) {
      wartende.add({'id': id(), 'box': '%%%'}); // ungültig = erledigt
    }
    seitenGroesse = 200;
    final lauf = await dienst.abholen();
    expect(lauf.ungueltig, 450);
    final aufrufe = server.anfragen('POST /ingest/zaehler/ack');
    expect(aufrufe.map((r) => (r.json['ids'] as List).length), [200, 200, 50]);
    expect(server.anfragen('GET /ingest/zaehler/pending'), hasLength(3));
  });

  test('Nie zwei Läufe gleichzeitig: ein zweiter Aufruf wartet auf denselben Lauf', () async {
    final tor = Completer<void>();
    final normal = server.routes['GET /ingest/zaehler/pending']!;
    server.on('GET /ingest/zaehler/pending', (req) async {
      await tor.future;
      return normal(req);
    });
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000), Stand(_t(3), 1020000)];
    einwerfen(tag: 4, stand: '1030.000');
    final a = dienst.abholen();
    final b = dienst.abholen();
    expect(dienst.laeuft, isTrue);
    tor.complete();
    final la = await a;
    final lb = await b;
    expect(identical(la, lb), isTrue);
    expect(server.anfragen('GET /ingest/zaehler/pending'), hasLength(1));
    expect(zugriff.eingetragen, hasLength(1));
    expect(dienst.laeuft, isFalse);
    // danach ist ein neuer Lauf wieder möglich
    expect(identical(await dienst.abholen(), la), isFalse);
  });

  test('Der Zugriff auf die Zähler scheitert: Abbruch, nichts quittiert (auch nichts "Ungültiges")', () async {
    einwerfen(tag: 1, stand: '1.000');
    zugriff.zaehlerFehler = true;
    final lauf = await dienst.abholen();
    expect(lauf.abbruch, IngestAbbruch.nichtBereit);
    expect(quittiert, isEmpty);
  });

  test('Vor dem Eintragen wird der Stand frisch gelesen: hat ein anderes Gerät den Tag inzwischen belegt, wird nichts doppelt eingetragen (nur quittiert)', () async {
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000), Stand(_t(2), 1010000), Stand(_t(3), 1020000)];
    final p = einwerfen(tag: 4, stand: '1030.000');
    // nach dem ersten Lesen (Entscheidung) schreibt "das andere Gerät" den Tag; erst das zweite, frische Lesen sieht ihn
    zugriff.nachLesen = (n) {
      if (n == 1) zugriff.staendeJeZaehler[_zStrom]!.add(Stand(_t(4), 1030000));
    };
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 0);
    expect(lauf.vorhanden, 1);
    expect(zugriff.eingetragen, isEmpty);
    expect(quittiert, [p]);
  });

  test('Ungültiger Stand (mehr als 10 Stellen) in einem ECHTEN Päckchen: nie still quittiert, sondern zu prüfen; Verwerfen quittiert, Eintragen geht nie', () async {
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000)];
    final p = einwerfen(tag: 2, stand: '12345678901234');
    final lauf = await dienst.abholen();
    expect(lauf.ungueltig, 0);
    expect(lauf.eingetragen, 0);
    expect(quittiert, isEmpty);
    expect(lauf.wartend, 1);
    final e = lauf.zuPruefen.single;
    expect(e.paketId, p);
    expect(e.grund, PruefGrund.ungueltig);
    expect(e.standText, '12345678901234');
    expect(e.zaehlerId, _zStrom);
    expect(e.tag.day, 2);
    // beim nächsten Lauf liegt es wieder vor
    expect((await dienst.abholen()).zuPruefen.single.paketId, p);
    await expectLater(dienst.pruefEintragen(e), throwsStateError);
    expect(zugriff.eingetragen, isEmpty);
    expect(quittiert, isEmpty);
    await dienst.verwerfen(e);
    expect(quittiert, [p]);
  });

  test('Ungültiger Stand mit falschem MAC (nichts Echtes) und Felderfehler ohne Wert bleiben quittierbar; ein langer Stand wird für die Anzeige gekürzt', () async {
    final falschesMac = einwerfen(tag: 2, stand: '12345678901234', mac: 'f' * 64);
    final lang = einwerfen(tag: 3, stand: '9' * 80);
    final lauf = await dienst.abholen();
    expect(lauf.ungueltig, 1);
    expect(quittiert, [falschesMac]);
    final e = lauf.zuPruefen.single;
    expect(e.paketId, lang);
    expect(e.standText!.length, lessThan(50));
    expect(e.standText, endsWith('…'));
  });

  test('Ungültiger Stand zu einem Kanal ohne Zähler: wird gezählt und bleibt beim Server', () async {
    einwerfen(kanal: 'gas_bezug', tag: 2, stand: '12345678901234');
    final lauf = await dienst.abholen();
    expect(lauf.ohneZaehler, 1);
    expect(lauf.zuPruefen, isEmpty);
    expect(quittiert, isEmpty);
  });

  test('Die Seitengrenze gilt je Verbindung: eine volle Verbindung hungert die anderen nicht aus', () async {
    seitenGroesse = 1;
    await PostfachSpeicher(speicher).verbindungenMerken(_uid, ['tok-a', 'tok-b']);
    for (var i = 0; i < kMaxIngestSeiten + 2; i++) {
      wartende.add({'id': id(), 'box': '%%%', 'tokenId': 'tok-a'});
    }
    zugriff.staendeJeZaehler[_zStrom] = [Stand(_t(1), 1000000)];
    final b = einwerfen(tag: 2, stand: '1010.000', tokenId: 'tok-b');
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 1);
    expect(quittiert, contains(b));
    final anfragen = server.anfragen('GET /ingest/zaehler/pending');
    expect(anfragen.where((r) => r.query['token'] == 'tok-a'), hasLength(kMaxIngestSeiten));
    expect(anfragen.where((r) => r.query['token'] == 'tok-b'), hasLength(1));
    // die zwei Päckchen von tok-a jenseits der Grenze kommen im nächsten Lauf
    expect(wartende.where((w) => w['tokenId'] == 'tok-a'), hasLength(2));
  });

  test('"Heute" ist der Tag der Familienzone, nicht der der Gerätezeit: kurz nach Mitternacht in Berlin gilt der Folgetag noch als heute', () async {
    // 26.10.2026 23:30 UTC = 27.10.2026 00:30 in Berlin (MEZ, die Sommerzeit endete am 25.10.)
    jetzt = DateTime.utc(2026, 10, 26, 23, 30);
    final morgen = einwerfen(tag: 28, stand: '1000.000'); // Berlin-heute 27. + 1
    final zuweit = einwerfen(tag: 29, stand: '1000.000');
    final lauf = await dienst.abholen();
    expect(lauf.eingetragen, 1);
    expect(lauf.ungueltig, 1);
    expect(quittiert, unorderedEquals([morgen, zuweit]));
    // und umgekehrt: 22:30 UTC am 26. ist in Berlin noch 23:30 am 26.: der 28. ist dann zwei Tage voraus
    wartende.clear();
    quittiert.clear();
    zugriff.eingetragen.clear();
    zugriff.staendeJeZaehler.clear();
    jetzt = DateTime.utc(2026, 10, 26, 22, 30);
    einwerfen(tag: 27, stand: '1000.000');
    einwerfen(tag: 28, stand: '1001.000');
    final lauf2 = await dienst.abholen();
    expect(lauf2.eingetragen, 1);
    expect(lauf2.ungueltig, 1);
  });

  test('Teilweise fehlgeschlagene Quittung: "wartend" zählt nur die tatsächlich quittierten Päckchen ab', () async {
    for (var i = 0; i < 450; i++) {
      wartende.add({'id': id(), 'box': '%%%'}); // ungültig = erledigt
    }
    var n = 0;
    server.on('POST /ingest/zaehler/ack', (req) {
      if (++n == 2) return fehler(500, 'internal_error');
      final ids = (req.json['ids'] as List).cast<String>();
      quittiert.addAll(ids);
      wartende.removeWhere((w) => ids.contains(w['id']));
      return jsonAntwort({'deleted': ids.length});
    });
    final lauf = await dienst.abholen();
    expect(lauf.quittungFehlgeschlagen, isTrue);
    expect(quittiert, hasLength(200));
    expect(lauf.wartend, 250);
    expect(server.anfragen('POST /ingest/zaehler/ack'), hasLength(2)); // nach dem Fehler keine weiteren Stücke
  });

  test('Empfangsdatum: zu prüfende Werte und der älteste Wert ohne Zähler tragen es (Grundlage des Hinweises "wird bald gelöscht")', () async {
    zugriff.staendeJeZaehler[_zStrom] = [for (var i = 1; i <= 5; i++) Stand(_t(i), (1000 + 10 * i) * 1000)];
    einwerfen(tag: 6, stand: '12.4', empfangen: '2026-10-01T08:00:00.000Z');
    einwerfen(kanal: 'gas_bezug', tag: 5, stand: '1.000', empfangen: '2026-10-10T08:00:00.000Z');
    einwerfen(kanal: 'gas_bezug', tag: 6, stand: '2.000', empfangen: '2026-09-28T08:00:00.000Z');
    final lauf = await dienst.abholen();
    expect(lauf.zuPruefen.single.empfangen, DateTime.utc(2026, 10, 1, 8));
    expect(lauf.aeltestOhneZaehler, DateTime.utc(2026, 9, 28, 8));
    // 26.10. 10:00: 25 Tage und 2 Stunden -> noch 5 Tage; der Wert vom 28.9. ist 28 Tage alt -> noch 2 Tage
    expect(paketLoeschInTagen(lauf.zuPruefen.single.empfangen, jetzt), 5);
    expect(paketLoeschInTagen(lauf.aeltestOhneZaehler, jetzt), 2);
  });

  test('Der geheime Schlüssel wird nach dem Lauf im Arbeitsspeicher überschrieben', () async {
    final s = PostfachSchluessel(Uint8List.fromList(paar.oeffentlich), Uint8List.fromList(paar.geheim), Uint8List.fromList(geheimnis));
    s.verwerfen();
    expect(s.geheim.every((b) => b == 0), isTrue);
    expect(s.geheimnis.every((b) => b == 0), isTrue);
  });
}
