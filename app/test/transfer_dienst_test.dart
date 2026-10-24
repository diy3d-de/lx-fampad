// Transfer-Dienst (Abschnitt 6n): Warteschlange für Uploads gegen den Fake-Server mit den Regeln des echten (Claim im Sync-Stapel). Geprüft: Datei und Fassung anlegen, Vorschaubild, Hinweis vorab bei
// Größen- und Quotenfehlern, Parallelität (höchstens 3), Fortsetzen nach einem Neustart (HEAD), Datei erneut wählen (Web), Abbrechen, Wiederholen mit Backoff und Retry-After, endgültige Fehler,
// `invalid_reference` (neu hochladen), `nr_belegt` (Fassung neu anlegen), Vordergrund-Fortsetzung eine nach der anderen, Hintergrunddienst, verschlüsselte Anhänge nach einem Neustart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart' show TransferZeile, TransfersCompanion;
import 'package:lx_fampad/data/dateien/datei_modelle.dart';
import 'package:lx_fampad/data/dateien/transfer_modelle.dart';
import 'package:lx_fampad/data/dateien/upload_quelle.dart';

import 'support/datei_geraet.dart';
import 'support/datei_welt.dart';
import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

Uint8List bytes(int n, [int seed = 1]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 255]);

/// Die ersten Bytes eines PNG, danach Füllung: der Fake-Server prüft Magic-Bytes bei Bildern.
Uint8List png(int n) => Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...List.filled(n - 8, 3)]);

const mib4 = 4194304;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeServer server;
  late FakeSyncServer sync;
  late FakeDateien welt;
  late DateiGeraet mama;
  late DateiGeraet papa;

  setUp(() async {
    server = FakeServer();
    sync = FakeSyncServer();
    welt = FakeDateien(server, sync);
    mama = await DateiGeraet.neu(server, welt, person: 'mama', rolle: Role.parent);
    papa = await DateiGeraet.neu(server, welt, person: 'papa', rolle: Role.admin);
  });

  Future<TransferZeile> t(DateiGeraet g, String id) async => (await g.dienst.transfer(id))!;

  group('Hochladen: Datei und Fassung', () {
    test('Upload, dann Datei und Fassung in EINEM Stapel (Claim); das zweite Gerät sieht die Datei', () async {
      final daten = bytes(2 * mib4 + 77);
      final id = await mama.dienst.hochladenDatei(name: 'Rechnung.txt', quelle: UploadQuelle.ausBytes(daten));
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(z.uebertragen, daten.length);
      expect(z.fortschritt, 1.0);
      expect(welt.patchLaengen, [mib4, mib4, 77]);
      // Datensätze lokal und im Ausgang: Datei zuerst, dann Fassung mit der Upload-ID
      final ops = await mama.ausgang();
      expect([for (final o in ops) o.entity], ['datei', 'datei_version']);
      expect(jsonDecode(ops[1].fieldsJson)['blobId'], z.blobId);
      await mama.abgleich();
      await papa.abgleich();
      final e = (await papa.repo.dateienIn(null).first).single;
      expect(e.name, 'Rechnung.txt');
      expect(e.groesse, daten.length);
      expect(e.neueste!.blobId, z.blobId);
      expect(welt.blobs[z.blobId]!.zustand, 'claimed');
      expect(welt.blobs[z.blobId]!.mime, 'text/plain'); // aus der Endung, weil die Bytes nichts belegen
    });

    test('Bild: ein Vorschaubild geht als zweiter Upload der Art `thumb` mit, die Fassung nennt es; das Bild selbst trägt den erkannten Typ', () async {
      final id = await mama.dienst.hochladenDatei(name: 'urlaub.jpg', quelle: UploadQuelle.ausBytes(png(5000))); // falsche Endung: die Bytes entscheiden
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(z.mime, 'image/png');
      expect(z.thumbBlobId, isNotNull);
      final thumb = welt.blobs[z.thumbBlobId]!;
      expect((thumb.kind, thumb.modus, thumb.mime), ('thumb', 'server', 'image/png'));
      await mama.abgleich();
      expect(welt.blobs[z.thumbBlobId]!.zustand, 'claimed');
      expect((await mama.versionen()).single.thumbBlobId, z.thumbBlobId);
    });

    test('Vorschau scheitert oder fehlt: die Datei wird trotzdem hochgeladen (ohne Vorschau)', () async {
      mama.thumb = (_) async => null;
      final id = await mama.dienst.hochladenDatei(name: 'a.png', quelle: UploadQuelle.ausBytes(png(4000)));
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(z.thumbBlobId, isNull);
      mama.thumb = (_) async => throw StateError('kaputt');
      final id2 = await mama.dienst.hochladenDatei(name: 'b.png', quelle: UploadQuelle.ausBytes(png(4000)));
      await mama.dienst.warteBisRuhig();
      expect((await t(mama, id2)).zustandTyp, TransferZustand.fertig);
    });

    test('kein Vorschaubild für andere Typen und für zu große Bilder', () async {
      var aufrufe = 0;
      mama.thumb = (b) async {
        aufrufe++;
        return Uint8List(10)..fillRange(0, 10, 1);
      };
      await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.hochladenDatei(name: 'gross.png', quelle: UploadQuelle.ausBytes(png(10 * 1024 * 1024 + 1)));
      await mama.dienst.warteBisRuhig();
      expect(aufrufe, 0);
    });

    test('neue Fassung einer vorhandenen Datei', () async {
      final id = await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      final dateiId = (await t(mama, id)).dateiId!;
      await mama.abgleich();
      final id2 = await mama.dienst.hochladenFassung(dateiId: dateiId, quelle: UploadQuelle.ausBytes(bytes(250, 9)));
      await mama.dienst.warteBisRuhig();
      expect((await t(mama, id2)).zustandTyp, TransferZustand.fertig);
      await mama.abgleich();
      await papa.abgleich();
      final e = (await papa.repo.eintrag(dateiId))!;
      expect((e.fassungen, e.neueste!.nr, e.groesse), (2, 2, 250));
    });

    test('Name, Rechte und Zielordner werden VOR dem Upload geprüft', () async {
      await expectLater(mama.dienst.hochladenDatei(name: 'a/b', quelle: UploadQuelle.ausBytes(bytes(10))), throwsA(DateiFehler.nameUngueltig));
      await expectLater(mama.dienst.hochladenDatei(name: 'x', quelle: UploadQuelle.ausBytes(bytes(10)), ordnerId: 'gibt-es-nicht'), throwsA(DateiFehler.nichtGefunden));
      final emil = await DateiGeraet.neu(server, welt, person: 'emil', rolle: Role.child);
      await expectLater(emil.dienst.hochladenDatei(name: 'x', quelle: UploadQuelle.ausBytes(bytes(10)), audience: kStufeEltern), throwsA(DateiFehler.nichtErlaubt));
      expect(await mama.dienst.alle(), isEmpty);
      expect(welt.blobs, isEmpty);
    });
  });

  group('Hinweis vorab bei Größen- und Quotenfehlern', () {
    test('zu groß und leer: Fehler vorab, kein Upload, keine Zeile', () async {
      await expectLater(mama.dienst.hochladenDatei(name: 'riesig.bin', quelle: UploadQuelle.ausBytes(Uint8List(0))), throwsA(DateiFehler.leer));
      welt.maxDateiBytes = 1000;
      await expectLater(mama.dienst.hochladenDatei(name: 'riesig.bin', quelle: UploadQuelle.ausBytes(bytes(1001))), throwsA(DateiFehler.zuGross));
      expect(server.anfragen('POST /uploads'), isEmpty);
      expect(await mama.dienst.alle(), isEmpty);
    });

    test('Speicher voll laut `GET /files/usage`: Fehler vorab', () async {
      welt.kontingent = 5000;
      await expectLater(mama.dienst.hochladenDatei(name: 'a.bin', quelle: UploadQuelle.ausBytes(bytes(6000))), throwsA(DateiFehler.speicherVoll));
      expect(await mama.dienst.vorabPruefen(4000), isNull);
      expect(await mama.dienst.vorabPruefen(6000), DateiFehler.speicherVoll);
      final n = await mama.dienst.nutzung();
      expect((n.kontingentBytes, n.freiBytes), (5000, 5000));
    });

    test('ohne Antwort auf `usage` (offline) gelten die Standardgrenzen, der Server prüft ohnehin selbst', () async {
      welt.einspritzen((r) => r.path == '/files/usage', (r) => throw http.ClientException('offline'));
      expect(await mama.dienst.vorabPruefen(1000), isNull);
      welt.einspritzen((r) => r.path == '/files/usage', (r) => throw http.ClientException('offline'));
      expect(await mama.dienst.vorabPruefen(kStandardMaxDateiBytes + 1), DateiFehler.zuGross);
    });
  });

  group('Parallelität', () {
    test('höchstens drei Übertragungen gleichzeitig, die übrigen warten und kommen danach dran', () async {
      var aktiv = 0;
      var hoechstens = 0;
      final tor = Completer<void>();
      welt.vorPatch = (r) async {
        aktiv++;
        if (aktiv > hoechstens) hoechstens = aktiv;
        await tor.future;
        aktiv--;
      };
      final ids = [for (var i = 0; i < 6; i++) await mama.dienst.hochladenDatei(name: 'f$i.txt', quelle: UploadQuelle.ausBytes(bytes(100 + i)))];
      for (var i = 0; i < 100 && aktiv < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(aktiv, 3);
      final laufend = (await mama.dienst.alle()).where((z) => z.zustandTyp == TransferZustand.laeuft).length;
      expect(laufend, 3);
      expect((await mama.dienst.alle()).where((z) => z.zustandTyp == TransferZustand.wartet).length, 3);
      tor.complete();
      await mama.dienst.warteBisRuhig();
      expect(hoechstens, 3);
      for (final id in ids) {
        expect((await t(mama, id)).zustandTyp, TransferZustand.fertig, reason: id);
      }
    });
  });

  group('Fortsetzen', () {
    test('nach einem Neustart der App macht der Upload dort weiter, wo der Server steht (Pfad der Datei bleibt lesbar)', () async {
      final daten = bytes(2 * mib4 + 500);
      final pfad = mama.datei('gross.bin', daten);
      final quelle = (await UploadQuelle.ausPfad(pfad))!;
      mama.backoff = (_) => const Duration(hours: 1); // der Wiederholungsversuch wartet, der Neustart kommt dazwischen
      var n = 0;
      welt.einspritzen((r) => r.method == 'PATCH' && ++n == 2, (r) => throw http.ClientException('Netz weg'));
      final id = await mama.dienst.hochladenDatei(name: 'gross.bin', quelle: quelle, quellePfad: pfad);
      await mama.dienst.warteBisRuhig();
      var z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.wartet);
      expect(z.fehlerCode, 'network');
      expect(z.naechsterVersuch, isNotNull);
      expect(welt.blobs[z.blobId]!.offset, mib4);
      await mama.dienst.beenden();
      // "Neustart": neuer Dienst, die Quelle gibt es nur noch als Pfad
      mama.backoff = (_) => Duration.zero;
      final neu = mama.dienstNeu();
      // der Wiederholungsversuch war auf in einer Stunde verschoben: nach dem Neustart zählt das nicht mehr
      await versucheFaellig(mama);
      await neu.wiederaufnehmen();
      await neu.warteBisRuhig();
      z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(welt.blobs[z.blobId]!.bytes, daten);
      expect(welt.patchLaengen, [mib4, mib4, 500]); // nichts doppelt gesendet
      expect(server.anfragen('HEAD /uploads/${z.blobId}'), hasLength(1));
    });

    test('Web: nach dem Neuladen fehlt die Quelle, der Transfer wartet auf die Datei und macht nach der erneuten Wahl weiter', () async {
      final daten = bytes(mib4 + 100);
      var n = 0;
      welt.einspritzen((r) => r.method == 'PATCH' && ++n == 2, (r) => throw http.ClientException('weg'));
      mama.backoff = (_) => const Duration(hours: 1);
      final id = await mama.dienst.hochladenDatei(name: 'a.bin', quelle: UploadQuelle.ausBytes(daten));
      await mama.dienst.warteBisRuhig();
      await mama.dienst.beenden();
      final neu = mama.dienstNeu();
      mama.backoff = (_) => Duration.zero;
      await versucheFaellig(mama);
      await neu.wiederaufnehmen();
      await neu.warteBisRuhig();
      expect((await t(mama, id)).zustandTyp, TransferZustand.dateiNoetig);
      // eine andere Datei mit anderer Länge wird abgelehnt
      await neu.quelleLiefern(id, UploadQuelle.ausBytes(bytes(10)));
      expect((await t(mama, id)).fehlerCode, 'datei_geaendert');
      await neu.quelleLiefern(id, UploadQuelle.ausBytes(daten));
      await neu.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(welt.blobs[z.blobId]!.bytes, daten);
    });

    test('Vordergrund-Fortsetzung: liegengebliebene Übertragungen laufen nach dem Start nur eine nach der anderen', () async {
      final gate = Completer<void>();
      var aktiv = 0;
      var hoechstens = 0;
      // alle drei scheitern zuerst mit einem Netzfehler und warten
      mama.backoff = (_) => const Duration(hours: 1);
      welt.einspritzen((r) => r.method == 'PATCH', (r) => throw http.ClientException('weg'), mal: 3);
      final ids = [for (var i = 0; i < 3; i++) await mama.dienst.hochladenDatei(name: 'f$i.txt', quelle: UploadQuelle.ausBytes(bytes(100 + i)), quellePfad: mama.datei('f$i.txt', bytes(100 + i)))];
      await mama.dienst.warteBisRuhig();
      await mama.dienst.beenden();
      final neu = mama.dienstNeu();
      mama.backoff = (_) => Duration.zero;
      await versucheFaellig(mama);
      welt.vorPatch = (r) async {
        aktiv++;
        if (aktiv > hoechstens) hoechstens = aktiv;
        await gate.future;
        aktiv--;
      };
      await neu.wiederaufnehmen();
      for (var i = 0; i < 100 && aktiv < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(aktiv, 1); // nur eine
      gate.complete();
      await neu.warteBisRuhig();
      expect(hoechstens, 1);
      for (final id in ids) {
        expect((await t(mama, id)).zustandTyp, TransferZustand.fertig);
      }
    });

    test('ein Transfer, den der Server nicht mehr kennt (24 Stunden), beginnt von vorn', () async {
      final daten = bytes(mib4 + 100);
      var n = 0;
      welt.einspritzen((r) => r.method == 'PATCH' && ++n == 2, (r) => throw http.ClientException('weg'));
      mama.backoff = (_) => Duration.zero;
      final id = await mama.dienst.hochladenDatei(name: 'a.bin', quelle: UploadQuelle.ausBytes(daten));
      // nach dem Netzfehler läuft der zweite Versuch sofort: der Server vergisst den Upload dazwischen
      welt.einspritzen((r) => r.method == 'HEAD', (r) {
        welt.blobs.clear();
        return http.Response(jsonEncode({'error': 'not_found'}), 404);
      });
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(welt.blobs[z.blobId]!.bytes, daten);
    });
  });

  group('Abbrechen, Wiederholen, Fehler', () {
    test('laufende Übertragung abbrechen: Zustand `abgebrochen`, der Upload verschwindet beim Server', () async {
      final daten = bytes(3 * mib4);
      final tor = Completer<void>();
      welt.vorPatch = (r) => tor.future;
      final id = await mama.dienst.hochladenDatei(name: 'a.bin', quelle: UploadQuelle.ausBytes(daten));
      for (var i = 0; i < 100 && welt.blobs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await mama.dienst.abbrechen(id);
      tor.complete();
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.abgebrochen);
      expect(welt.blobs, isEmpty);
      expect(await mama.dateien(), isEmpty);
    });

    test('Wartende abbrechen', () async {
      mama.backoff = (_) => const Duration(hours: 1);
      welt.einspritzen((r) => r.method == 'PATCH', (r) => throw http.ClientException('weg'));
      final id = await mama.dienst.hochladenDatei(name: 'a.bin', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      expect((await t(mama, id)).zustandTyp, TransferZustand.wartet);
      await mama.dienst.abbrechen(id);
      expect((await t(mama, id)).zustandTyp, TransferZustand.abgebrochen);
      expect(welt.blobs, isEmpty);
    });

    test('Störung (503) mit Retry-After: der nächste Versuch wartet mindestens so lange, danach klappt es', () async {
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'server_busy'}), 503, headers: {'retry-after': '120'}));
      mama.backoff = (_) => const Duration(seconds: 1);
      final vor = DateTime.now();
      final id = await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      var z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.wartet);
      expect(z.fehlerCode, 'server_busy');
      expect(z.versuche, 1);
      expect(z.naechsterVersuch!.difference(vor).inSeconds, greaterThanOrEqualTo(119));
      // von Hand wiederholen (z. B. "Jetzt versuchen"): die Zeit des Wartens entfällt
      await mama.dienst.wiederholen(id);
      await mama.dienst.warteBisRuhig();
      z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(z.versuche, 0);
    });

    test('nach maxVersuche echten Störungen ist Schluss (`fehler`), Netzfehler zählen nie', () async {
      mama.maxVersuche = 3;
      mama.dienstNeu();
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'server_busy'}), 503), mal: 50);
      final id = await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect((z.zustandTyp, z.fehlerCode, z.versuche), (TransferZustand.fehler, 'server_busy', 3));
      // Netzfehler: beliebig oft, bleibt `wartet`
      welt.einspritzen((r) => r.method == 'POST', (r) => throw http.ClientException('weg'), mal: 30);
      var n = 0;
      mama.backoff = (_) {
        n++;
        return const Duration(hours: 1);
      };
      final id2 = await mama.dienst.hochladenDatei(name: 'b.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      expect((await t(mama, id2)).zustandTyp, TransferZustand.wartet);
      expect(n, 1);
    });

    test('Speicher voll beim Anlegen: endgültig, ohne Wiederholung; nach Platz schaffen klappt "Wiederholen"', () async {
      final id = await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      // der Server meldet erst beim Anlegen, dass es voll ist (Vorabprüfung hatte noch freie Zahlen)
      await mama.dienst.warteBisRuhig();
      expect((await t(mama, id)).zustandTyp, TransferZustand.fertig);
      welt.kontingent = 10;
      final id2 = await mama.dienst.hochladenDatei(name: 'b.txt', quelle: UploadQuelle.ausBytes(bytes(50))).catchError((Object _) => '');
      expect(id2, isEmpty); // schon vorab abgelehnt
      welt.kontingent = 1000;
      welt.einspritzen((r) => r.method == 'POST', (r) => http.Response(jsonEncode({'error': 'quota_exceeded'}), 413));
      final id3 = await mama.dienst.hochladenDatei(name: 'c.txt', quelle: UploadQuelle.ausBytes(bytes(50)));
      await mama.dienst.warteBisRuhig();
      var z = await t(mama, id3);
      expect((z.zustandTyp, z.fehlerCode, z.versuche), (TransferZustand.fehler, 'quota_exceeded', 0));
      expect(transferFehlerText(z.fehlerCode), contains('Speicher'));
      await mama.dienst.wiederholen(id3);
      await mama.dienst.warteBisRuhig();
      z = await t(mama, id3);
      expect(z.zustandTyp, TransferZustand.fertig);
    });

    test('der Server lehnt die Datei ab (422): endgültig, nichts bleibt liegen, kein Datensatz', () async {
      final id = await mama.dienst.hochladenDatei(name: 'x.bin', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      expect((await t(mama, id)).zustandTyp, TransferZustand.fertig); // Kontrollfall: .bin ohne Typ geht durch
      welt.einspritzen((r) => r.method == 'PATCH', (r) => http.Response(jsonEncode({'error': 'invalid_file'}), 422));
      final id2 = await mama.dienst.hochladenDatei(name: 'y.bin', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id2);
      expect((z.zustandTyp, z.fehlerCode), (TransferZustand.fehler, 'invalid_file'));
      expect(await mama.dateien(), hasLength(1));
    });

    test('Fehlercodes haben feste Texte (nie ein Servertext, nie ein Name)', () {
      for (final code in ['quota_exceeded', 'file_too_large', 'insufficient_storage', 'invalid_file', 'invalid_reference', 'nr_belegt', 'network', 'maintenance', 'rate_limited', 'datei_geaendert', 'quelle_fehlt', 'anhang_neu', 'pruefsumme', 'nicht_gefunden', 'nicht_erlaubt', 'irgendwas']) {
        expect(transferFehlerText(code), isNotEmpty, reason: code);
      }
      expect(transferFehlerText(null), '');
    });
  });

  group('Der Server lehnt das Anlegen der Datensätze ab', () {
    test('invalid_reference: der Upload ist nicht mehr gültig; Wiederholen lädt neu hoch und räumt die Datei ohne Fassung weg', () async {
      final id = await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      var z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      welt.blobs.remove(z.blobId); // der Server hat den Upload inzwischen verworfen
      final r = await mama.engine.abgleichen();
      expect(r.hinweise.map((h) => h.text).join(' '), contains('Der hochgeladene Inhalt ist nicht mehr gültig'));
      z = await t(mama, id);
      expect((z.zustandTyp, z.fehlerCode), (TransferZustand.fehler, 'invalid_reference'));
      expect(transferFehlerText(z.fehlerCode), contains('neu hochgeladen'));
      expect(await mama.versionen(), isEmpty);
      // die Datei ohne Fassung ist noch da, "Wiederholen" räumt sie auf und lädt neu hoch
      expect(await mama.dateien(), hasLength(1));
      await mama.dienst.wiederholen(id, quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      await mama.abgleich();
      await papa.abgleich();
      expect(await papa.dateien(), hasLength(1));
      expect(await papa.versionen(), hasLength(1));
      expect(welt.sync.zeilen.values.where((x) => x.entity == 'datei' && !x.geloescht), hasLength(1));
    });

    test('nr_belegt: ein anderes Gerät war mit derselben Nummer schneller; Wiederholen legt die Fassung mit neuer Nummer an', () async {
      final id = await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      final dateiId = (await t(mama, id)).dateiId!;
      await mama.abgleich();
      await papa.abgleich();
      // beide laden "gleichzeitig" eine neue Fassung hoch (beide lokal Nummer 2)
      final a = await mama.dienst.hochladenFassung(dateiId: dateiId, quelle: UploadQuelle.ausBytes(bytes(10, 2)));
      final b = await papa.dienst.hochladenFassung(dateiId: dateiId, quelle: UploadQuelle.ausBytes(bytes(20, 3)));
      await mama.dienst.warteBisRuhig();
      await papa.dienst.warteBisRuhig();
      await mama.abgleich(); // mama gewinnt: Nummer 2
      final r = await papa.engine.abgleichen();
      expect(r.ok, isTrue);
      final zb = await t(papa, b);
      expect((zb.zustandTyp, zb.fehlerCode), (TransferZustand.fehler, 'nr_belegt'));
      expect((await t(mama, a)).zustandTyp, TransferZustand.fertig);
      await papa.abgleich(); // papa kennt jetzt die Fassung 2 von mama
      await papa.dienst.wiederholen(b);
      await papa.dienst.warteBisRuhig();
      await papa.abgleich();
      await mama.abgleich();
      final e = (await mama.repo.eintrag(dateiId))!;
      expect(e.fassungen, 3);
      expect(e.neueste!.nr, 3);
      expect(e.groesse, 20);
    });
  });

  group('Hintergrunddienst', () {
    test('ab drei aktiven Übertragungen (oder 20 MB) startet er, ohne Namen; am Ende ist er beendet', () async {
      final tor = Completer<void>();
      welt.vorPatch = (r) => tor.future;
      for (var i = 0; i < 3; i++) {
        await mama.dienst.hochladenDatei(name: 'secret$i.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      }
      for (var i = 0; i < 100 && !mama.hintergrund.aktiv; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(mama.hintergrund.aktiv, isTrue);
      expect(mama.hintergrund.ereignisse.first, 'start 3');
      tor.complete();
      await mama.dienst.warteBisRuhig();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mama.hintergrund.aktiv, isFalse);
      expect(mama.hintergrund.ereignisse.last, 'ende');
    });

    test('eine einzelne kleine Datei braucht keinen Vordergrunddienst', () async {
      await mama.dienst.hochladenDatei(name: 'a.txt', quelle: UploadQuelle.ausBytes(bytes(100)));
      await mama.dienst.warteBisRuhig();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mama.hintergrund.ereignisse, isEmpty);
    });

    test('eine große Datei (ab 20 MB) startet ihn allein', () async {
      final tor = Completer<void>();
      welt.vorPatch = (r) => tor.future;
      await mama.dienst.hochladenDatei(name: 'gross.bin', quelle: UploadQuelle.ausBytes(bytes(21 * 1024 * 1024)));
      for (var i = 0; i < 100 && !mama.hintergrund.aktiv; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(mama.hintergrund.aktiv, isTrue);
      tor.complete();
      await mama.dienst.warteBisRuhig();
    });
  });

  group('Verschlüsselte Anhänge', () {
    test('Abschluss-Rückruf bekommt die Blob-ID; nach einem Neustart ist der Transfer nicht fortsetzbar (neu wählen)', () async {
      String? gesehen;
      final id = await mama.dienst.hochladenAnhang(
        anhangId: '00000000-0000-4000-8000-0000000000aa',
        konversationId: 'k',
        anzeigeName: 'Anhang',
        quelle: UploadQuelle.ausBytes(bytes(2000)),
        abschluss: (blobId, sha) async => gesehen = blobId,
      );
      await mama.dienst.warteBisRuhig();
      final z = await t(mama, id);
      expect(z.zustandTyp, TransferZustand.fertig);
      expect(gesehen, z.blobId);
      expect(welt.blobs[z.blobId]!.modus, 'e2ee');
      expect(welt.blobs[z.blobId]!.kind, 'opak');
      expect(welt.blobs[z.blobId]!.mime, isNull); // nie ein Typ für verschlüsselte Blobs
      // zweiter Anhang: Netz weg, App-Neustart
      mama.backoff = (_) => const Duration(hours: 1);
      welt.einspritzen((r) => r.method == 'PATCH', (r) => throw http.ClientException('weg'));
      final id2 = await mama.dienst.hochladenAnhang(anhangId: '00000000-0000-4000-8000-0000000000bb', konversationId: 'k', anzeigeName: 'Anhang', quelle: UploadQuelle.ausBytes(bytes(2000)), abschluss: (b, s) async {});
      await mama.dienst.warteBisRuhig();
      await mama.dienst.beenden();
      final neu = mama.dienstNeu();
      await versucheFaellig(mama);
      await neu.wiederaufnehmen();
      await neu.warteBisRuhig();
      final z2 = await t(mama, id2);
      // ohne Schlüssel und Rückruf (nur im Arbeitsspeicher): weder Quelle noch Abschluss -> die Datei muss neu gewählt werden
      expect(z2.zustandTyp, TransferZustand.dateiNoetig);
      await neu.wiederholen(id2, quelle: UploadQuelle.ausBytes(bytes(2000)));
      expect((await t(mama, id2)).fehlerCode, 'anhang_neu');
    });
  });
}

/// Setzt `naechsterVersuch` aller Übertragungen zurück (der Neustart kommt nach der Wartezeit des Wiederholungsversuchs).
Future<void> versucheFaellig(DateiGeraet g) => g.db.update(g.db.transfers).write(const TransfersCompanion(naechsterVersuch: Value(null)));
