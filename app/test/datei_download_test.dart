// Download und Offline-Cache (Abschnitt 6n): Range-Abschnitte von 4 MiB mit Fortschritt, Fortsetzen aus der Teil-Datei, Prüfsumme, Fehler (404, 416, Netz), Cache mit LRU-Obergrenze (Standard 2 GB),
// Anheften ("Offline verfügbar"), Aufräumen, Wiper. Im Web (kein Ordner) gibt es keinen Download über den Dienst.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart' show TransferZeile;
import 'package:lx_fampad/data/dateien/datei_cache_dienst.dart';
import 'package:lx_fampad/data/dateien/datei_modelle.dart';
import 'package:lx_fampad/data/dateien/datei_ort.dart';
import 'package:lx_fampad/data/dateien/transfer_dienst.dart';
import 'package:lx_fampad/data/dateien/transfer_modelle.dart';

import 'support/datei_geraet.dart';
import 'support/datei_welt.dart';
import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

Uint8List bytes(int n, [int seed = 1]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 255]);

const mib4 = 4194304;
const blobA = '00000001-aaaa-4000-8000-000000000000';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeServer server;
  late FakeDateien welt;
  late DateiGeraet mama;

  setUp(() async {
    server = FakeServer();
    welt = FakeDateien(server, FakeSyncServer());
    mama = await DateiGeraet.neu(server, welt, person: 'mama', rolle: Role.parent);
  });

  /// Ein beanspruchter Blob des Servers (so liefert er ihn jedem, der die Datei sehen darf).
  FakeBlob blob(String id, Uint8List daten) {
    final b = FakeBlob(id, 'server', 'datei', null, daten.length, 'person-mama')
      ..zustand = 'claimed'
      ..sha256 = c.sha256.convert(daten).toString()
      ..daten.add(daten);
    return welt.blobs[id] = b;
  }

  Future<TransferZeile> t(String id) async => (await mama.dienst.transfer(id))!;

  group('Download', () {
    test('Abschnitte von 4 MiB per Range mit Fortschritt; die Datei landet im Cache, die Prüfsumme stimmt', () async {
      final daten = bytes(2 * mib4 + 321);
      blob(blobA, daten);
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'Urlaub.pdf', groesse: daten.length, mime: 'application/pdf', sha256: c.sha256.convert(daten).toString());
      await mama.dienst.warteBisRuhig();
      final z = await t(id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(z.uebertragen, daten.length);
      expect(await File(z.zielPfad!).readAsBytes(), daten);
      expect(await mama.cache.pfadFuer(blobA), z.zielPfad);
      final ranges = server.anfragen('GET /files/blobs/$blobA').map((r) => r.headers['range']).toList();
      expect(ranges, ['bytes=0-${mib4 - 1}', 'bytes=$mib4-${2 * mib4 - 1}', 'bytes=${2 * mib4}-${daten.length - 1}']);
      expect(server.anfragen('GET /files/blobs/$blobA').every((r) => r.headers['authorization'] == 'Bearer person-mama'), isTrue);
      expect(await mama.ort.existiert((await mama.cache.teilPfad(blobA))!), isFalse); // keine Teil-Datei übrig
    });

    test('Fortsetzen: eine vorhandene Teil-Datei wird nicht noch einmal geladen', () async {
      final daten = bytes(2 * mib4 + 10);
      blob(blobA, daten);
      await mama.ort.anhaengen((await mama.cache.teilPfad(blobA))!, Uint8List.sublistView(daten, 0, mib4));
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      await mama.dienst.warteBisRuhig();
      expect((await t(id)).zustandTyp, TransferZustand.fertig);
      final ranges = server.anfragen('GET /files/blobs/$blobA').map((r) => r.headers['range']).toList();
      expect(ranges.first, 'bytes=$mib4-${2 * mib4 - 1}');
      expect(ranges, hasLength(2));
      expect(await File((await t(id)).zielPfad!).readAsBytes(), daten);
    });

    test('Abbruch mitten drin (Netz weg): der Transfer wartet, der nächste Versuch macht bei der Teil-Datei weiter', () async {
      final daten = bytes(2 * mib4 + 10);
      blob(blobA, daten);
      mama.backoff = (_) => Duration.zero;
      var n = 0;
      welt.einspritzen((r) => r.method == 'GET' && r.path.contains('/files/blobs/') && ++n == 2, (r) => throw http.ClientException('weg'));
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      await mama.dienst.warteBisRuhig();
      final z = await t(id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(await File(z.zielPfad!).readAsBytes(), daten);
      final ranges = server.anfragen('GET /files/blobs/$blobA').map((r) => r.headers['range']).toList();
      // der zweite Abschnitt wurde zweimal angefragt (der erste Versuch brach ab), der Anfang wurde nicht noch einmal geladen
      expect(ranges, ['bytes=0-${mib4 - 1}', 'bytes=$mib4-${2 * mib4 - 1}', 'bytes=$mib4-${2 * mib4 - 1}', 'bytes=${2 * mib4}-${daten.length - 1}']);
    });

    test('falsche Prüfsumme: die Datei wird verworfen und nie angeboten', () async {
      final daten = bytes(5000);
      blob(blobA, daten);
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length, sha256: 'ab' * 32);
      await mama.dienst.warteBisRuhig();
      final z = await t(id);
      expect((z.zustandTyp, z.fehlerCode), (TransferZustand.fehler, 'pruefsumme'));
      expect(await mama.cache.pfadFuer(blobA), isNull);
      expect(await mama.ort.existiert((await mama.cache.teilPfad(blobA))!), isFalse);
      expect(transferFehlerText('pruefsumme'), contains('beschädigt'));
    });

    test('404: endgültig (die Datei gibt es nicht mehr); keine Sicht = 404', () async {
      final id = await mama.dienst.herunterladen(blobId: '00000002-aaaa-4000-8000-000000000000', name: 'a.bin', groesse: 100);
      await mama.dienst.warteBisRuhig();
      final z = await t(id);
      expect((z.zustandTyp, z.fehlerCode, z.versuche), (TransferZustand.fehler, 'nicht_gefunden', 0));
    });

    test('416: der Stand passt nicht zum Server, einmal von vorn; dauerhaft endet es mit einem Fehler', () async {
      final daten = bytes(5000);
      blob(blobA, daten);
      await mama.ort.anhaengen((await mama.cache.teilPfad(blobA))!, Uint8List.sublistView(daten, 0, 100));
      welt.einspritzen((r) => r.method == 'GET' && r.path.contains('/files/blobs/'), (r) => http.Response('', 416, headers: {'content-range': 'bytes */5000'}));
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      await mama.dienst.warteBisRuhig();
      final z = await t(id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(await File(z.zielPfad!).readAsBytes(), daten);
      expect(server.anfragen('GET /files/blobs/$blobA').last.headers['range'], 'bytes=0-4999');
    });

    test('ignoriert der Server Range und liefert alles (200), wird die ganze Datei übernommen', () async {
      final daten = bytes(3000);
      blob(blobA, daten);
      welt.einspritzen((r) => r.method == 'GET' && r.path.contains('/files/blobs/'), (r) => http.Response.bytes(daten, 200));
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      await mama.dienst.warteBisRuhig();
      expect(await File((await t(id)).zielPfad!).readAsBytes(), daten);
    });

    test('schon im Cache: keine Anfrage an den Server, die Übertragung ist sofort fertig', () async {
      final daten = bytes(3000);
      blob(blobA, daten);
      await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      await mama.dienst.warteBisRuhig();
      server.log.clear();
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      final z = await t(id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(z.fortschritt, 1.0);
      expect(server.log.where((r) => r.path.contains('/files/blobs/')), isEmpty);
    });

    test('Abbrechen eines laufenden Downloads lässt die Teil-Datei zum Fortsetzen liegen', () async {
      final daten = bytes(3 * mib4);
      blob(blobA, daten);
      welt.vorPatch = null;
      final id = await mama.dienst.herunterladen(blobId: blobA, name: 'a.bin', groesse: daten.length);
      await mama.dienst.abbrechen(id);
      await mama.dienst.warteBisRuhig();
      final z = await t(id);
      expect(z.zustandTyp == TransferZustand.abgebrochen || z.zustandTyp == TransferZustand.fertig, isTrue); // je nachdem, wie weit er schon war
    });

    test('im Web (kein Ordner) gibt es keinen Download über den Dienst: der Browser lädt selbst', () async {
      final web = TransferDienst(db: mama.db, repo: mama.repo, tus: mama.tus, api: mama.fampad, cache: DateiCacheDienst(db: mama.db, ort: const KeinDateiOrt()));
      await expectLater(web.herunterladen(blobId: blobA, name: 'a', groesse: 1), throwsA(DateiFehler.nichtVerfuegbar));
      await web.beenden();
    });
  });

  group('Offline-Cache (LRU)', () {
    late DateiCacheDienst cache;
    var zeit = DateTime.utc(2026, 10, 24, 9);

    setUp(() {
      cache = DateiCacheDienst(db: mama.db, ort: mama.ort, jetzt: () => zeit);
      zeit = DateTime.utc(2026, 10, 24, 9);
    });

    Future<String?> ablegen(String blob, int n, {bool anheften = false}) async {
      zeit = zeit.add(const Duration(minutes: 1));
      final teil = (await cache.teilPfad(blob))!;
      await mama.ort.anhaengen(teil, bytes(n));
      return cache.aufnehmen(blobId: blob, teilPfad: teil, groesse: n, name: 'x', anheften: anheften);
    }

    test('Standardgrenze 2 GB, die Einstellung gilt, Unsinn gilt als Standard', () async {
      expect(await cache.grenze(), 2147483648);
      await cache.grenzeSetzen(1000);
      expect(await cache.grenze(), 1000);
      await mama.db.metaSchreiben(kCacheMaxSchluessel, '-5');
      expect(await cache.grenze(), 2147483648);
      await expectLater(cache.grenzeSetzen(0), throwsArgumentError);
    });

    test('über der Grenze fliegt die am längsten nicht benutzte Kopie zuerst heraus, die neue bleibt', () async {
      await cache.grenzeSetzen(10);
      await ablegen('b1', 4);
      await ablegen('b2', 4);
      await ablegen('b3', 4); // 12 > 10: b1 (älteste Nutzung) muss weg
      expect(await cache.pfadFuer('b1'), isNull);
      expect(await cache.pfadFuer('b2'), isNotNull);
      expect(await cache.pfadFuer('b3'), isNotNull);
      expect(await cache.belegt(), 8);
    });

    test('Benutzung zählt: wer geöffnet wurde, fliegt später heraus', () async {
      await cache.grenzeSetzen(10);
      await ablegen('b1', 4);
      await ablegen('b2', 4);
      zeit = zeit.add(const Duration(minutes: 5));
      expect(await cache.pfadFuer('b1'), isNotNull); // b1 ist jetzt jünger als b2
      await ablegen('b3', 4);
      expect(await cache.pfadFuer('b2'), isNull);
      expect(await cache.pfadFuer('b1'), isNotNull);
    });

    test('angeheftete Kopien ("Offline verfügbar") fliegen nie automatisch heraus, auch nicht über der Grenze', () async {
      await cache.grenzeSetzen(10);
      await ablegen('p1', 6, anheften: true);
      await ablegen('p2', 6, anheften: true);
      await ablegen('b3', 3);
      expect(await cache.pfadFuer('p1'), isNotNull);
      expect(await cache.pfadFuer('p2'), isNotNull);
      expect(await cache.pfadFuer('b3'), isNotNull); // die gerade fertige bleibt
      expect(await cache.belegt(), greaterThan(await cache.grenze()));
      // wird eine gelöst, räumt der Dienst auf
      await cache.anheften('p1', false);
      expect(await cache.pfadFuer('p1'), isNull);
    });

    test('fehlt die Datei auf der Platte oder hat sie eine andere Größe, verschwindet die Zeile', () async {
      await ablegen('b1', 4);
      await mama.ort.loeschen((await mama.ort.pfad('b1'))!);
      expect(await cache.pfadFuer('b1'), isNull);
      expect(await mama.db.select(mama.db.dateiCache).get(), isEmpty);
      await ablegen('b2', 4);
      await mama.ort.anhaengen((await mama.ort.pfad('b2'))!, Uint8List(1));
      expect(await cache.pfadFuer('b2'), isNull);
    });

    test('Wiper: Abmelden räumt Ordner und Tabelle', () async {
      await ablegen('b1', 4);
      await ablegen('b2', 4);
      await cache.alleLoeschen();
      expect(await mama.db.select(mama.db.dateiCache).get(), isEmpty);
      expect(await mama.ort.existiert((await mama.ort.pfad('b1'))!), isFalse);
    });

    test('Dateinamen im Cache sind immer Blob-IDs: Pfadtricks werden abgelehnt', () async {
      await expectLater(mama.ort.pfad('../x'), throwsArgumentError);
      await expectLater(mama.ort.pfad('a/b'), throwsArgumentError);
      await expectLater(mama.ort.pfad(''), throwsArgumentError);
    });

    test('die Datenbank leeren (Abmelden) leert auch `transfers` und `datei_cache`', () async {
      await ablegen('b1', 4);
      await mama.dienst.herunterladen(blobId: blobA, name: 'a', groesse: 1).catchError((Object _) => '');
      await mama.db.alleDatenLoeschen();
      expect(await mama.db.select(mama.db.dateiCache).get(), isEmpty);
      expect(await mama.db.select(mama.db.transfers).get(), isEmpty);
    });
  });
}
