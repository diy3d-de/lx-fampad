// Anhänge im Tresor Ende-zu-Ende (Abschnitt 6n/6m), Datenschicht: echte lokale Datenbanken je Gerät, Sync und Ausgang-Vorbereiter gegen die Welt des Chats (Regeln des echten Servers für die
// Tresor-Konversation) und den Fake-Server der Dateiablage (tus, Blobs). Geprüft: Verschlüsselung auf dem Gerät mit Zufallsschlüssel, der Server sieht nur Chiffretext und e1-Hüllen (nie Name,
// Typ, Schlüssel, Klartext), das andere Elternteil liest, lädt und entschlüsselt NUR im Arbeitsspeicher, Manipulation am Server wird erkannt, Kinder nie, Größengrenzen, Zuordnung zum Eintrag.
import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/dateien/blob_lader.dart';
import 'package:lx_fampad/data/dateien/datei_cache_dienst.dart';
import 'package:lx_fampad/data/dateien/datei_modelle.dart';
import 'package:lx_fampad/data/dateien/datei_ort_io.dart';
import 'package:lx_fampad/data/dateien/datei_repository.dart';
import 'package:lx_fampad/data/dateien/e2ee_blob.dart';
import 'package:lx_fampad/data/dateien/transfer_dienst.dart';
import 'package:lx_fampad/data/dateien/transfer_modelle.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_inhalt.dart';
import 'package:lx_fampad/data/dateien/tresor_anhang_repository.dart';
import 'package:lx_fampad/data/dateien/tus_client.dart';
import 'package:lx_fampad/data/tresor/tresor_repository.dart';
import 'package:lx_fampad/data/app_database.dart' show TresorAnhaengeCompanion, TresorAnhangZeile;
import 'package:lx_fampad/data/chat/chat_ids.dart' show tresorChatId;

import 'support/chat_welt.dart';
import 'support/datei_welt.dart';
import 'support/fake_crypto.dart';
import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

const _mama = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _papa = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _emil = 'cccccccc-0000-4000-8000-00000000000c';

UserDto _u(String id, Role r) => UserDto(id: id, email: null, displayName: id, colorIndex: 0, role: r, status: MemberStatus.active);

Uint8List bytes(int n, [int seed = 5]) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 17 + seed + (i >> 9)) & 255]);

bool gleich(Uint8List a, Uint8List b) => a.length == b.length && List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

/// Alles, was zu einem Gerät gehört: Chat-Gerät, Netz zum Fake-Server der Dateiablage, Transfer-Dienst und das Repository der Anhänge.
class AnhangGeraet {
  final Geraet g;
  final TresorAnhangRepository repo;
  final TransferDienst dienst;
  final ApiClient api;
  AnhangGeraet(this.g, this.repo, this.dienst, this.api);
}

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Tresor-Anhänge Ende-zu-Ende ($name)', () {
      late ChatWelt welt;
      late FakeServer server;
      late FakeDateien dateien;
      late TestPerson mama, papa, emil;
      late AnhangGeraet am, ap, ae;
      late TresorRepository tm;
      late List<UserDto> mitglieder;
      final geraete = <Geraet>[];
      final aufraeumen = <Directory>[];

      Future<AnhangGeraet> geraet(TestPerson p, Role rolle) async {
        final g = Geraet.neu(welt, p);
        geraete.add(g);
        final tokens = MemoryTokenStore();
        await tokens.writeTokens(StoredTokens(accessToken: 'person-${p.id}', accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)), refreshToken: 'r', refreshExpiresAt: DateTime.now().add(const Duration(days: 90)), deviceId: 'g-${p.id}'));
        dateien.rollen['person-${p.id}'] = rolle;
        final api = ApiClient(client: server.client, store: tokens, web: false, base: 'https://familie.test');
        final tmp = Directory.systemTemp.createTempSync('anhang_test_');
        aufraeumen.add(tmp);
        final ort = DateiOrtIo(() async => Directory('${tmp.path}/c'));
        final dateiRepo = DateiRepository(db: g.db, store: g.store, ich: () => p.id, rolle: () => rolle, beiAenderung: () {});
        final dienst = TransferDienst(
          db: g.db,
          repo: dateiRepo,
          tus: TusClient(api, schlaf: (_) async {}),
          api: FampadApi(api, geraet: () async => null),
          cache: DateiCacheDienst(db: g.db, ort: ort),
          backoff: (_) => Duration.zero,
        );
        final repo = TresorAnhangRepository(
          db: g.db,
          store: g.store,
          krypto: () async => g.bereit ? g.krypto : null,
          blob: E2eeBlobHelfer(crypto),
          lader: BlobLader(api),
          dienst: dienst,
          ich: () => p.id,
          familie: () => familieId,
          mitglieder: () async => mitglieder,
          beiAenderung: () {},
          jetzt: () => g.jetzt,
        );
        return AnhangGeraet(g, repo, dienst, api);
      }

      Future<void> alle({int runden = 3}) async {
        for (var i = 0; i < runden; i++) {
          for (final g in geraete) {
            await welt.abgleichen(g);
          }
        }
      }

      setUp(() async {
        for (final g in geraete) {
          await g.schliessen();
        }
        geraete.clear();
        welt = ChatWelt(crypto);
        server = FakeServer();
        dateien = FakeDateien(server, FakeSyncServer());
        mama = TestPerson(_mama, 'Mama', crypto);
        papa = TestPerson(_papa, 'Papa', crypto);
        emil = TestPerson(_emil, 'Emil', crypto);
        final rollen = {_mama: Role.parent, _papa: Role.admin, _emil: Role.child};
        welt.aktiveMitglieder = [...rollen.keys];
        welt.rollen
          ..clear()
          ..addAll(rollen);
        mitglieder = [for (final e in rollen.entries) _u(e.key, e.value)];
        welt.blobGroesse = (id) => dateien.blobs[id]?.laenge ?? 0;
        welt.blobAnspruch = (g, f) {
          // Claim wie der echte Server: nur der eigene, fertige, freie Upload im Modus e2ee
          final b = dateien.blobs[f['blobId']];
          if (b == null || b.zustand != 'ready' || b.besitzer != 'person-${g.person.id}' || b.modus != 'e2ee' || b.kind != 'opak') return 'invalid_reference';
          b
            ..zustand = 'claimed'
            ..claimEntity = 'tresor_anhang';
          return null;
        };
        am = await geraet(mama, Role.parent);
        ap = await geraet(papa, Role.admin);
        ae = await geraet(emil, Role.child);
        var takt = 0;
        welt.serverZeit = () => DateTime.utc(2026, 10, 24, 9).add(Duration(seconds: ++takt));
        for (final g in geraete) {
          g.mitgliederLernen([for (final p in [mama, papa, emil]) p]);
        }
        tm = TresorRepository(db: am.g.db, store: am.g.store, krypto: () async => am.g.krypto, ich: () => _mama, familie: () => familieId, mitglieder: () async => mitglieder, beiAenderung: () {});
        // die Tresor-Konversation samt erster Epoche (nur Eltern und Admins) und ein Eintrag, zu dem Anhänge gehören können
        await tm.konversationSicherstellen();
        await alle();
      });

      tearDown(() async {
        for (final g in geraete) {
          await g.schliessen();
        }
        for (final d in aufraeumen) {
          try {
            d.deleteSync(recursive: true);
          } on Object {
            // Aufräumen im Test
          }
        }
        aufraeumen.clear();
      });

      String serverGesehen() => jsonEncode(welt.gesehen) + jsonEncode([for (final z in welt.alle('tresor_anhang')) z.fields]);

      Future<String> anhaengen(AnhangGeraet a, String name, Uint8List daten, {String? mime, String? eintrag}) async {
        final id = await a.repo.hochladen(name: name, bytes: daten, mime: mime, eintragId: eintrag);
        await a.dienst.warteBisRuhig();
        return id;
      }

      test('Hochladen: der Server bekommt nur Chiffretext und e1-Hüllen; das andere Elternteil liest den Anhang und lädt ihn im Speicher herunter', () async {
        final klar = Uint8List.fromList(List.generate(200000, (i) => 'Reisepass-Kopie-GEHEIM'.codeUnitAt(i % 22)));
        final tid = await anhaengen(am, 'Reisepass-Mama.pdf', klar, mime: 'application/pdf', eintrag: 'e-1');
        expect((await am.dienst.transfer(tid))!.zustandTyp, TransferZustand.fertig);
        // vor dem Abgleich: lokal als Klartext-Hülle (l1:) im Ausgang, nie auf dem Server
        final lokal = await am.g.db.select(am.g.db.tresorAnhaenge).getSingle();
        expect(lokal.inhalt, startsWith('l1:f1:'));
        expect(lokal.rev, 0);
        expect(lokal.size, e2eeGroesse(klar.length));
        await alle();
        // Server: nur e1-Hülle, nichts Lesbares; der Blob ist Chiffretext im Modus e2ee ohne Typ
        final z = welt.alle('tresor_anhang').single;
        expect(z.fields['inhalt'], startsWith('e1:'));
        expect(z.fields['bearbeiterId'], _mama);
        expect(z.fields['size'], e2eeGroesse(klar.length));
        final blob = dateien.blobs[z.fields['blobId']]!;
        expect((blob.modus, blob.kind, blob.zustand), ('e2ee', 'opak', 'claimed'));
        expect(blob.mime, isNull);
        expect(String.fromCharCodes(blob.bytes).contains('GEHEIM'), isFalse);
        final gesehen = serverGesehen();
        for (final w in ['Reisepass', 'pdf', 'application', 'GEHEIM', 'e-1', 'f1:', 'l1:']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
        expect(server.log.where((r) => r.path.startsWith('/uploads')).map((r) => r.headers['upload-metadata'] ?? '').join(), isNot(contains(base64.encode(utf8.encode('application/pdf')))));
        // das andere Elternteil: Ansicht, Zuordnung und Entschlüsseln
        final liste = await ap.repo.lesen(await ap.repo.zeilen().first);
        expect(liste, hasLength(1));
        final a = liste.single;
        expect((a.name, a.mime, a.groesse, a.eintragId, a.lokalNeu), ('Reisepass-Mama.pdf', 'application/pdf', klar.length, 'e-1', false));
        expect(a.hinweis, isNull);
        final geladen = await ap.repo.herunterladen(a.id);
        expect(gleich(geladen, klar), isTrue);
        // Download in Abschnitten per Range (200000 Byte = ein Abschnitt)
        expect(server.anfragen('GET /files/blobs/${z.fields['blobId']}').single.headers['range'], 'bytes=0-${e2eeGroesse(klar.length) - 1}');
        // nichts blieb auf der Platte oder im Cache
        expect(await ap.g.db.select(ap.g.db.dateiCache).get(), isEmpty);
        expect(await ap.dienst.alle(), isEmpty);
      });

      test('Zuordnung: Anhänge eines Eintrags; nach dem Löschen des Eintrags die zugehörigen Anhänge löschen', () async {
        await anhaengen(am, 'a.txt', bytes(1000), eintrag: 'e-1');
        await anhaengen(am, 'b.txt', bytes(2000), eintrag: 'e-1');
        await anhaengen(am, 'c.txt', bytes(3000), eintrag: 'e-2');
        await alle();
        expect((await ap.repo.fuerEintrag('e-1')).map((a) => a.name).toSet(), {'a.txt', 'b.txt'});
        expect((await ap.repo.fuerEintrag('e-2')).map((a) => a.name), ['c.txt']);
        expect(await ap.repo.fuerEintragLoeschen('e-1'), 2);
        await alle();
        expect((await am.repo.lesen(await am.repo.zeilen().first)).map((a) => a.name), ['c.txt']);
        expect(welt.alle('tresor_anhang'), hasLength(1));
      });

      test('Manipulation am Server: veränderte, gekürzte oder vertauschte Bytes werden beim Herunterladen erkannt, nie als Datei angeboten', () async {
        final klar = bytes(300000);
        await anhaengen(am, 'a.bin', klar);
        await alle();
        final z = welt.alle('tresor_anhang').single;
        final id = z.id;
        final blob = dateien.blobs[z.fields['blobId']]!;
        final original = blob.bytes;
        Future<void> setze(Uint8List neu) async {
          blob.daten.clear();
          blob.daten.add(neu);
        }

        // ein Byte geändert (die Prüfsumme der Bytes im Inhalt schlägt an)
        await setze(Uint8List.fromList(original)..[1000] ^= 1);
        await expectLater(ap.repo.herunterladen(id), throwsA(anyOf(isA<TusFehler>(), isA<CryptoFehler>())));
        // gekürzt: der Server liefert weniger Bytes, als die Größe des Datensatzes nennt
        await setze(Uint8List.sublistView(original, 0, original.length - 100));
        await expectLater(ap.repo.herunterladen(id), throwsA(anything));
        // wieder heil: geht
        await setze(original);
        expect(gleich(await ap.repo.herunterladen(id), klar), isTrue);
      });

      test('Kinder: kein Zugriff, kein Anlegen; der Server liefert ihnen weder Datensatz noch Blob', () async {
        await anhaengen(am, 'a.txt', bytes(500));
        await alle();
        expect(await ae.g.db.select(ae.g.db.tresorAnhaenge).get(), isEmpty);
        await expectLater(ae.repo.hochladen(name: 'x.txt', bytes: bytes(10)), throwsA(isA<TresorNichtErlaubt>()));
        await expectLater(ae.repo.herunterladen('beliebig'), throwsA(isA<TresorNichtErlaubt>()));
        // auch mit der ID des Blobs: 404
        final blobId = welt.alle('tresor_anhang').single.fields['blobId'];
        final r = await ae.api.roh('GET', '/files/blobs/$blobId');
        expect(r.status, 404);
      });

      test('Größengrenzen: Klartext + Overhead muss in `maxE2eeBytes` passen; leer und zu groß werden vorab abgelehnt, nichts wird hochgeladen', () async {
        dateien.maxE2eeBytes = e2eeGroesse(1000);
        await expectLater(am.repo.hochladen(name: 'a.bin', bytes: bytes(1001)), throwsA(DateiFehler.zuGross));
        await expectLater(am.repo.hochladen(name: 'a.bin', bytes: Uint8List(0)), throwsA(DateiFehler.leer));
        expect(dateien.blobs, isEmpty);
        expect(await am.dienst.alle(), isEmpty);
        await anhaengen(am, 'a.bin', bytes(1000)); // genau an der Grenze: geht
        await alle();
        expect(welt.alle('tresor_anhang'), hasLength(1));
        expect(e2eeKlartextMax(dateien.maxE2eeBytes), 1000);
      });

      test('Name und Hülle: ein ungültiger Name wird nie hochgeladen; Namen bis 200 Zeichen und lange Typen passen in die Hülle (höchstens 4096 Zeichen)', () async {
        await expectLater(am.repo.hochladen(name: 'a/b', bytes: bytes(10)), throwsA(DateiFehler.nameUngueltig));
        expect(dateien.blobs, isEmpty);
        await anhaengen(am, 'ü' * 120, bytes(10), mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', eintrag: 'e-1');
        await alle();
        final a = (await ap.repo.lesen(await ap.repo.zeilen().first)).single;
        expect(a.name, 'ü' * 120);
        expect((welt.alle('tresor_anhang').single.fields['inhalt'] as String).length, lessThanOrEqualTo(4096));
      });

      test('der Inhalt des Anhangs: Format, tolerante Auswertung, nie ein Teilinhalt', () {
        final schluessel = Uint8List.fromList(List.filled(32, 9));
        final i = AnhangInhalt(name: 'a.pdf', mime: 'application/pdf', groesse: 12, schluessel: schluessel, sha256: 'ab' * 32, eintragId: 'e');
        final t = anhangKodieren(i);
        expect(t, startsWith('f1:{'));
        final z = anhangLesen(t)!;
        expect((z.name, z.mime, z.groesse, z.sha256, z.eintragId), ('a.pdf', 'application/pdf', 12, 'ab' * 32, 'e'));
        expect(z.schluessel, schluessel);
        z.vergessen();
        expect(z.schluessel.every((b) => b == 0), isTrue);
        for (final kaputt in ['', 'f1:', 'f1:{', 'f1:[]', 'f2:{}', 'f1:{"v":2,"n":"a","s":1,"k":"AA","h":"x"}', 'f1:{"v":1,"n":"a","s":-1,"k":"${base64Url.encode(List.filled(32, 1)).replaceAll('=', '')}","h":"${'ab' * 32}"}', 'f1:{"v":1,"n":"a","s":1,"k":"AAAA","h":"${'ab' * 32}"}', 'f1:{"v":1,"n":"","s":1,"k":"${base64Url.encode(List.filled(32, 1)).replaceAll('=', '')}","h":"${'ab' * 32}"}']) {
          expect(anhangLesen(kaputt), isNull, reason: kaputt);
        }
        expect(() => anhangKodieren(AnhangInhalt(name: 'a/b', mime: null, groesse: 1, schluessel: schluessel, sha256: 'ab' * 32, eintragId: null)), throwsA(DateiFehler.nameUngueltig));
        expect(() => anhangKodieren(AnhangInhalt(name: 'a', mime: null, groesse: 1, schluessel: Uint8List(5), sha256: 'ab' * 32, eintragId: null)), throwsA(isA<CryptoFehler>()));
      });

      test('der Server lehnt das Anlegen ab (Upload nicht mehr gültig): der Transfer steht auf Fehler, der Anhang erscheint nie; neu wählen', () async {
        final tid = await am.repo.hochladen(name: 'a.txt', bytes: bytes(500));
        await am.dienst.warteBisRuhig();
        final blobId = (await am.dienst.transfer(tid))!.blobId!;
        dateien.blobs.remove(blobId); // der Server hat den Upload verworfen
        await alle();
        final z = (await am.dienst.transfer(tid))!;
        expect((z.zustandTyp, z.fehlerCode), (TransferZustand.fehler, 'invalid_reference'));
        expect(welt.alle('tresor_anhang'), isEmpty);
        expect(await am.g.db.select(am.g.db.tresorAnhaenge).get(), isEmpty);
        // der Schlüssel der Datei ist überschrieben: ein erneuter Versuch geht nur mit neuer Wahl der Datei
        await am.dienst.wiederholen(tid, quelle: null);
        expect((await am.dienst.transfer(tid))!.fehlerCode, 'anhang_neu');
        expect(transferFehlerText('anhang_neu'), contains('neu gewählt'));
      });

      test('mehr als 200 Anhänge nimmt der Tresor nicht an; Anhang löschen: auf dem anderen Gerät weg', () async {
        final id = await anhaengen(am, 'a.txt', bytes(100));
        await alle();
        final a = (await ap.repo.lesen(await ap.repo.zeilen().first)).single;
        await ap.repo.loeschen(a.id);
        await alle();
        expect(await am.g.db.select(am.g.db.tresorAnhaenge).get(), isEmpty);
        expect(welt.alle('tresor_anhang'), isEmpty);
        await expectLater(ap.repo.loeschen('gibt-es-nicht'), throwsA(DateiFehler.nichtGefunden));
        // Obergrenze: 200 lokale Zeilen (am Fake-Server vorbei) genügen für die Ablehnung vorab
        for (var i = 0; i < kMaxTresorAnhaenge; i++) {
          await am.g.db.into(am.g.db.tresorAnhaenge).insert(TresorAnhaengeCompanion.insert(id: 'x$i', konversationId: tresorChatId(familieId), blobId: 'b$i', inhalt: 'e1:x', createdAt: DateTime.utc(2026)));
        }
        await expectLater(am.repo.hochladen(name: 'z.txt', bytes: bytes(10)), throwsA(DateiFehler.zuVieleAnhaenge));
        expect(id, isNotEmpty);
      });

      test('ohne Verschlüsselung (kein Schlüssel) wird nichts hochgeladen', () async {
        am.g.bereit = false;
        await expectLater(am.repo.hochladen(name: 'a.txt', bytes: bytes(10)), throwsA(anything));
        expect(dateien.blobs, isEmpty);
      });

      test('bei einem unlesbaren Anhang (fremder Absender, kein Schlüssel) kommt ein Hinweis statt des Inhalts', () async {
        await anhaengen(am, 'a.txt', bytes(100));
        await alle();
        final roh = (await ap.g.db.select(ap.g.db.tresorAnhaenge).get()).single;
        final ohneAbsender = TresorAnhangZeile(id: roh.id, konversationId: roh.konversationId, blobId: roh.blobId, inhalt: roh.inhalt, size: roh.size, bearbeiterId: null, createdAt: roh.createdAt, rev: roh.rev);
        final a = (await ap.repo.lesen([ohneAbsender])).single;
        expect(a.lesbar, isFalse);
        expect(a.hinweis, contains('nicht mehr in der Familie'));
        final l1Fremd = TresorAnhangZeile(id: roh.id, konversationId: roh.konversationId, blobId: roh.blobId, inhalt: 'l1:f1:{}', size: 0, bearbeiterId: _mama, createdAt: roh.createdAt, rev: 0);
        expect((await ap.repo.lesen([l1Fremd])).single.lesbar, isFalse); // lokaler Klartext gilt nur für eigene Zeilen
      });
    });
  }
}

