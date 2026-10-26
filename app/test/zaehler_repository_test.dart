// Zähler Ende-zu-Ende (Abschnitt 6l): echte lokale Datenbanken je Gerät, echter Store und Ausgang-Vorbereiter gegen den Fake-Server, der die Regeln des echten Servers nachbildet
// (Sicht nach Teilnehmern, nur Erwachsene, feste ID der Konversation, Hülle e1). Geprüft: Kinder bekommen nie Daten und können nichts anlegen, der Server sieht nie Klartext,
// Klartext (l1:) verlässt das Gerät nie, zwei Geräte gleichen ab, Zählerwechsel, Wasser-Gruppe, Plausibilität, Teilnehmerpflege bei Rollenwechsel, Verlauf nur auf Tipp.
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart' show ZaehlerCompanion;
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/ingest/ingest_dienst.dart' show RepoIngestZaehler;
import 'package:lx_fampad/data/sync/sync_store.dart' show SyncAenderung;
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart';
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_monate.dart' show MonatswertHinweis;
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart';
import 'package:lx_fampad/data/zaehler/zaehler_teilnehmer.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';

const _mama = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _papa = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _emil = 'cccccccc-0000-4000-8000-00000000000c';
const _anna = 'dddddddd-0000-4000-8000-00000000000d';

UserDto _u(String id, Role r) => UserDto(id: id, email: null, displayName: id, colorIndex: 0, role: r, status: MemberStatus.active);

DateTime _d(String s) => DateTime.parse('${s}T00:00:00Z');

ZaehlerInhalt _strom({String name = 'Hauptzähler Keller-Geheim'}) => ZaehlerInhalt(
  art: ZaehlerArt.strom,
  name: name,
  nummer: 'ABC-4711',
  notiz: 'Geheimnotiz',
  periodeMonat: 3,
  preise: const [Preis(ab: '2026-01-01', arbeitspreis: 3456, grundgebuehrJahr: 12000, zaehlergebuehrJahr: 1500)],
  abschlag: 8500,
);

ZaehlerInhalt _wasser(ZaehlerArt art, String name, {String gruppe = ''}) => ZaehlerInhalt(art: art, name: name, gruppe: gruppe);

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Zähler Ende-zu-Ende ($name)', () {
      late ChatWelt welt;
      late TestPerson mama, papa, emil, anna;
      late Geraet gm, gp, ge, ga;
      late List<UserDto> mitglieder;
      final geraete = <Geraet>[];
      late ZaehlerRepository rm, rp, re, ra;

      ZaehlerRepository rep(Geraet g) => ZaehlerRepository(
        db: g.db,
        store: g.store,
        krypto: () async => g.bereit ? g.krypto : null,
        ich: () => g.person.id,
        familie: () => familieId,
        mitglieder: () async => mitglieder,
        beiAenderung: () {},
        jetzt: () => g.jetzt,
      );

      List<TestPerson> personen() => [mama, papa, emil, anna];

      void lernen() {
        for (final g in geraete) {
          g.mitgliederLernen([for (final p in personen()) if (welt.aktiveMitglieder.contains(p.id)) p]);
        }
      }

      Future<void> aufbau() async {
        for (final g in geraete) {
          await g.schliessen();
        }
        welt = ChatWelt(crypto);
        mama = TestPerson(_mama, 'Mama', crypto);
        papa = TestPerson(_papa, 'Papa', crypto);
        emil = TestPerson(_emil, 'Emil', crypto);
        anna = TestPerson(_anna, 'Anna', crypto);
        final rollen = {_mama: Role.parent, _papa: Role.admin, _emil: Role.child, _anna: Role.child};
        welt.aktiveMitglieder = [...rollen.keys];
        welt.rollen
          ..clear()
          ..addAll(rollen);
        mitglieder = [for (final e in rollen.entries) _u(e.key, e.value)];
        geraete.clear();
        gm = Geraet.neu(welt, mama);
        gp = Geraet.neu(welt, papa);
        ge = Geraet.neu(welt, emil);
        ga = Geraet.neu(welt, anna);
        geraete.addAll([gm, gp, ge, ga]);
        lernen();
        // der Server vergibt aufsteigende Anlagezeiten (wie der echte): bei zwei Ständen am selben Tag gilt der später angelegte
        var takt = 0;
        welt.serverZeit = () => DateTime.utc(2026, 10, 19, 9).add(Duration(seconds: ++takt));
        rm = rep(gm);
        rp = rep(gp);
        re = rep(ge);
        ra = rep(ga);
      }

      setUp(aufbau);
      tearDown(() async {
        for (final g in geraete) {
          await g.schliessen();
        }
      });

      /// Wie die Schlüsselpflege der App (ChatKryptoController._pflegen): erste Epoche und automatische Rotation für alle Konversationen.
      Future<void> pflegen(Geraet g) async {
        for (final konv in await g.db.select(g.db.konversationen).get()) {
          if (konv.encVersion != 'e1' || konv.rev == 0) continue;
          final teil = (jsonDecode(konv.teilnehmerJson) as List).cast<String>().toSet();
          final erste = await g.krypto.ersteEpocheNoetig(konversation: konv, teilnehmer: teil);
          final rot = erste == null ? await g.krypto.rotationNoetig(konversation: konv, teilnehmer: teil) : null;
          if (erste == null && !(rot?.automatisch ?? false)) continue;
          final aenderungen = await g.krypto.epocheErstellen(konversationId: konv.id, mitglieder: erste ?? rot!.automatischeMitglieder, unvertrauteAuslassen: true);
          await g.store.aendernMehrere(aenderungen);
        }
      }

      Future<void> abgleich(List<Geraet> gs, {int runden = 3}) async {
        for (var i = 0; i < runden; i++) {
          for (final g in gs) {
            await welt.abgleichen(g);
          }
        }
      }

      Future<void> alle({int runden = 3}) => abgleich([ge, gm, gp, ga], runden: runden);

      Future<List<ZaehlerAnsicht>> lesen(ZaehlerRepository r) async => r.lesen(await r.zeilen().first);
      Future<List<StandAnsicht>> staendeLesen(ZaehlerRepository r, String zaehler) async => r.lesenStaende(await r.standZeilen(zaehler).first);

      String serverGesehen() => jsonEncode(welt.gesehen) + jsonEncode([for (final e in ['konversation', 'zaehler', 'zaehlerstand']) for (final z in welt.alle(e)) z.fields]);

      Future<String> strom(ZaehlerRepository r, {String name = 'Hauptzähler Keller-Geheim'}) => r.anlegen(_strom(name: name));

      test('Eltern legen einen Zähler an, beide lesen ihn; der Server sieht nur e1-Hüllen, nie Name, Nummer, Preis, Stand oder Datum', () async {
        final id = await strom(rm);
        await rm.standErfassen(id, datum: _d('2026-10-01'), milli: 12345678, notiz: 'Geheim-Ablesung');
        await alle();
        for (final r in [rm, rp]) {
          final l = await lesen(r);
          expect(l, hasLength(1));
          expect(l.single.id, id);
          expect(l.single.inhalt!.name, 'Hauptzähler Keller-Geheim');
          expect(l.single.inhalt!.preise.single.arbeitspreis, 3456);
          expect(l.single.lokalNeu, isFalse);
          final s = await staendeLesen(r, id);
          expect(s.single.inhalt!.milli, 12345678);
          expect(s.single.inhalt!.notiz, 'Geheim-Ablesung');
        }
        // Server: feste ID der Konversation, Art, nur die beiden Erwachsenen, e1-Hülle, Bearbeiter
        final k = welt.alle('konversation').single;
        expect(k.id, zaehlerChatId(familieId));
        expect(k.fields['art'], 'zaehler');
        expect(k.fields['subjektId'], isNull);
        expect((k.fields['teilnehmer'] as List).cast<String>().toSet(), {_mama, _papa});
        expect(welt.alle('zaehler').single.fields['inhalt'], startsWith('e1:'));
        expect(welt.alle('zaehlerstand').single.fields['inhalt'], startsWith('e1:'));
        expect(welt.alle('zaehler').single.fields['bearbeiterId'], _mama);
        final gesehen = serverGesehen();
        for (final w in ['Hauptzähler', 'Keller-Geheim', 'ABC-4711', 'Geheimnotiz', 'Geheim-Ablesung', '12345678', '2026-10-01', '3456', 'preise', 'kosten', 'abschlag', 'z1:', 'a1:', 'l1:', 'kWh']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
      });

      test('Kinder: bekommen nie Daten, können nichts anlegen und stehen nie in der Teilnehmerliste', () async {
        final id = await strom(rm);
        await rm.standErfassen(id, datum: _d('2026-10-01'), milli: 1000);
        await alle();
        // der Server liefert Kindern nichts
        for (final p in [_emil, _anna]) {
          expect(welt.sichtbarFuer(p, 'konversation'), isEmpty);
          expect(welt.sichtbarFuer(p, 'zaehler'), isEmpty);
          expect(welt.sichtbarFuer(p, 'zaehlerstand'), isEmpty);
        }
        // lokal: nichts, auch nicht als hidden-Spur mit Inhalt
        expect(await lesen(re), isEmpty);
        expect(await lesen(ra), isEmpty);
        expect(await ge.db.select(ge.db.zaehler).get(), isEmpty);
        expect(await ge.db.select(ge.db.zaehlerstaende).get(), isEmpty);
        expect(await ge.db.select(ge.db.konversationen).get(), isEmpty);
        // die Repositories verweigern jede Handlung
        for (final r in [re, ra]) {
          await expectLater(r.anlegen(_strom()), throwsA(isA<ZaehlerNichtErlaubt>()));
          await expectLater(r.konversationSicherstellen(), throwsA(isA<ZaehlerNichtErlaubt>()));
          await expectLater(r.standErfassen(id, datum: _d('2026-10-01'), milli: 1), throwsA(isA<ZaehlerNichtErlaubt>()));
          await expectLater(r.aendern(id, _strom()), throwsA(isA<ZaehlerNichtErlaubt>()));
          await expectLater(r.loeschen(id), throwsA(isA<ZaehlerNichtErlaubt>()));
          expect(await r.teilnehmerPflegen(), isFalse);
          expect(await r.verlaufTeilen({_mama}), isFalse);
        }
      });

      test('Auch bei Umgehung der App lehnt der Server ein Kind ab: es kann weder die Konversation anlegen noch sich hineinschreiben oder Zähler anlegen', () async {
        final id = await strom(rm);
        await alle();
        final konv = zaehlerChatId(familieId);
        // Kind legt eine eigene Konversation mit sich als Teilnehmer an (feste ID ist belegt, die Liste mit Kind ist ungültig)
        await ge.store.aendernMehrere([
          SyncAenderung('konversation', konv, {'art': 'zaehler', 'encVersion': 'e1', 'teilnehmer': [_emil]}),
        ]);
        await alle();
        expect(welt.abgelehnt['konversation'], 1);
        expect((welt.zeile('konversation', konv)!.fields['teilnehmer'] as List).cast<String>().toSet(), {_mama, _papa});
        // Kind schreibt sich in die Liste
        await ge.store.aendern('konversation', konv, {'teilnehmer': [_emil, _mama, _papa]});
        // Kind legt in der fremden Konversation einen Zähler an (Hülle von Hand, ohne Verschlüsselung durch die App)
        await ge.store.aendern('zaehler', 'dddddddd-0000-4000-8000-00000000dddd', {'konversationId': konv, 'inhalt': 'e1:${'A' * 160}'});
        await alle();
        expect((welt.zeile('konversation', konv)!.fields['teilnehmer'] as List).cast<String>().toSet(), {_mama, _papa});
        expect(welt.alle('zaehler').map((z) => z.id), [id]);
        expect(welt.sichtbarFuer(_emil, 'zaehler'), isEmpty);
      });

      test('Ändern durch das andere Elternteil: der Bearbeiter wechselt; Archivieren, Reaktivieren, Gruppe, Löschen samt Ständen überall', () async {
        final id = await strom(rm);
        await rm.standErfassen(id, datum: _d('2026-10-01'), milli: 5000);
        await alle();
        await rp.aendern(id, (await lesen(rp)).single.inhalt!.kopie(name: 'Strom Haus', abschlag: () => 9000));
        await alle();
        var z = (await lesen(rm)).single.inhalt!;
        expect([z.name, z.abschlag], ['Strom Haus', 9000]);
        expect(welt.alle('zaehler').single.fields['bearbeiterId'], _papa);
        // archivieren: ab heute, Stände bleiben
        gm.jetzt = DateTime.utc(2026, 10, 23, 8);
        await rm.archivieren(id);
        await alle();
        z = (await lesen(rp)).single.inhalt!;
        expect([z.archiviert, z.archiviertAb], [true, '2026-10-23']);
        expect(await staendeLesen(rp, id), hasLength(1));
        await rm.reaktivieren(id);
        await rm.gruppeSetzen(id, '  Haus  ');
        await alle();
        z = (await lesen(rp)).single.inhalt!;
        expect([z.archiviert, z.gruppe], [false, 'Haus']);
        // Löschen entfernt Zähler und Stände überall (Gerät, Server)
        await rp.loeschen(id);
        await alle();
        expect(welt.alle('zaehler'), isEmpty);
        expect(welt.alle('zaehlerstand'), isEmpty);
        expect(await lesen(rm), isEmpty);
        expect(await gm.db.select(gm.db.zaehlerstaende).get(), isEmpty);
      });

      test('Der Klartext verlässt das Gerät nie: ohne Schlüssel bleibt alles im Ausgang (l1:), der Server bekommt nur e1', () async {
        gm.bereit = false;
        await expectLater(rm.anlegen(_strom()), throwsA(isA<VerschluesselungNichtBereit>()));
        gm.bereit = true;
        final id = await strom(rm);
        final s = await rm.standErfassen(id, datum: _d('2026-10-01'), milli: 777000);
        expect((await gm.ausgang()).any((o) => o.entity == 'zaehler' && o.fieldsJson.contains('l1:z1:')), isTrue);
        expect((await gm.ausgang()).any((o) => o.entity == 'zaehlerstand' && o.fieldsJson.contains('l1:a1:')), isTrue);
        expect((await lesen(rm)).single.inhalt!.name, 'Hauptzähler Keller-Geheim');
        expect((await lesen(rm)).single.lokalNeu, isTrue);
        // das Gerät ist gerade nicht bereit: nichts geht hinaus
        gm.bereit = false;
        final ops = await gm.store.naechsteOps(50, vorbereiter: gm.vorbereiter);
        expect(ops.where((o) => o.entity == 'zaehler' || o.entity == 'zaehlerstand'), isEmpty);
        expect(jsonEncode(welt.gesehen), isNot(contains('Keller-Geheim')));
        gm.bereit = true;
        await alle();
        expect(welt.alle('zaehler').single.fields['inhalt'], startsWith('e1:'));
        expect(serverGesehen(), isNot(contains('Keller-Geheim')));
        expect(serverGesehen(), isNot(contains('l1:')));
        expect((await staendeLesen(rp, id)).single.id, s);
      });

      test('Die Hülle ist an Art, Konversation, eigene ID, Bezug und Bearbeiter gebunden: umgehängt wird sie nicht geöffnet', () async {
        final id = await strom(rm);
        final sid = await rm.standErfassen(id, datum: _d('2026-10-01'), milli: 1000);
        await alle();
        final z = welt.alle('zaehler').single;
        final s = welt.alle('zaehlerstand').single;
        final konv = zaehlerChatId(familieId);
        Future<bool> geht(String wire, {required String id, required String autor, String? bezug, String? art, String? konversation}) async =>
            (await gp.krypto.nachrichtOeffnen(konversationId: konversation ?? konv, nachrichtId: id, autorId: autor, wire: wire, antwortAuf: bezug, art: art)).lesbar;
        expect(await geht(z.fields['inhalt'] as String, id: z.id, autor: _mama, art: kArtZaehler), isTrue);
        expect(await geht(s.fields['inhalt'] as String, id: s.id, autor: _mama, bezug: id, art: kArtStand), isTrue);
        // falsche Art, falscher Bezug, fremde ID, anderer Bearbeiter, andere Konversation
        expect(await geht(z.fields['inhalt'] as String, id: z.id, autor: _mama), isFalse);
        expect(await geht(z.fields['inhalt'] as String, id: z.id, autor: _mama, art: kArtStand, bezug: id), isFalse);
        expect(await geht(z.fields['inhalt'] as String, id: s.id, autor: _mama, art: kArtZaehler), isFalse);
        expect(await geht(z.fields['inhalt'] as String, id: z.id, autor: _papa, art: kArtZaehler), isFalse);
        expect(await geht(z.fields['inhalt'] as String, id: z.id, autor: _mama, art: kArtZaehler, konversation: zaehlerChatId('22222222-2222-4222-8222-222222222222')), isFalse);
        expect(await geht(s.fields['inhalt'] as String, id: s.id, autor: _mama, art: kArtStand), isFalse); // ohne Bezug
        expect(await geht(s.fields['inhalt'] as String, id: s.id, autor: _mama, art: kArtStand, bezug: 'anderer-zaehler'), isFalse);
        expect(sid, s.id);
      });

      test('Stände: erfassen, ändern durch das andere Elternteil, löschen; zwei Geräte rechnen mit demselben Ergebnis, auch bei zwei Ständen am selben Tag', () async {
        final id = await strom(rm);
        gm.jetzt = gp.jetzt = DateTime.utc(2026, 10, 19, 9);
        final a = await rm.standErfassen(id, datum: _d('2026-01-01'), milli: 100000);
        await rm.standErfassen(id, datum: _d('2026-04-01'), milli: 190000);
        await alle();
        // Papa trägt am selben Tag einen anderen Stand ein (zwei Geräte lesen am selben Tag ab)
        await rp.standErfassen(id, datum: _d('2026-04-01'), milli: 200000);
        await alle();
        final stm = await rm.staende(id);
        final stp = await rp.staende(id);
        expect(stm.map((s) => '${tagNummer(s.tag)}:${s.milli}'), stp.map((s) => '${tagNummer(s.tag)}:${s.milli}'));
        expect(Verbrauchskurve.aus(stm).verbrauch(_d('2026-01-01'), _d('2026-04-01')).milli, Verbrauchskurve.aus(stp).verbrauch(_d('2026-01-01'), _d('2026-04-01')).milli);
        // ändern durch Papa (Wert, Datum, Notiz), der Bearbeiter wechselt
        await rp.standAendern(a, milli: 110000, notiz: 'korrigiert');
        await alle();
        final k = (await staendeLesen(rm, id)).firstWhere((s) => s.id == a).inhalt!;
        expect([k.milli, k.notiz, k.datum], [110000, 'korrigiert', '2026-01-01']);
        expect(welt.zeile('zaehlerstand', a)!.fields['bearbeiterId'], _papa);
        await rp.standAendern(a, datum: _d('2026-01-02'));
        await alle();
        expect((await staendeLesen(rp, id)).firstWhere((s) => s.id == a).inhalt!.datum, '2026-01-02');
        // löschen
        await rm.standLoeschen(a);
        await alle();
        expect(welt.alle('zaehlerstand'), hasLength(2));
        expect(await staendeLesen(rp, id), hasLength(2));
      });

      test('Home Assistant, zwei Abholgeräte: derselbe Zähler und Tag zweimal automatisch eingetragen ergibt nach dem Abgleich EINEN Stand (der zuletzt geschriebene), auf beiden Geräten gleich', () async {
        final id = await rm.anlegen(_strom().kopie(quelle: () => const ZaehlerQuelle(kanal: 'strom_bezug', pruefen: false)));
        gm.jetzt = gp.jetzt = DateTime.utc(2026, 10, 19, 9);
        await alle();
        await RepoIngestZaehler(rm).eintragen(id, _d('2026-10-18'), 1012000);
        gp.jetzt = DateTime.utc(2026, 10, 19, 9, 5); // das zweite Gerät schreibt später
        await RepoIngestZaehler(rp).eintragen(id, _d('2026-10-18'), 1012500);
        await alle();
        for (final r in [rm, rp]) {
          final s = await RepoIngestZaehler(r).staende(id);
          expect(s, hasLength(1));
          expect(s.single.milli, 1012500);
          expect(await staendeLesen(r, id), hasLength(2)); // beide Einträge liegen in der Datenbank, nur gerechnet wird mit einem
        }
      });

      test('Home Assistant: die Quelle steht verschlüsselt im Zähler, ein automatischer Stand ist ein normaler Stand mit Herkunftsvermerk; der Server sieht nie Kanal, Quelle oder Wert', () async {
        final id = await rm.anlegen(_strom().kopie(quelle: () => const ZaehlerQuelle(kanal: 'strom_bezug_geheim', pruefen: false)));
        gm.jetzt = gp.jetzt = DateTime.utc(2026, 10, 19, 9);
        await rm.standErfassen(id, datum: _d('2026-10-17'), milli: 1000000, notiz: 'von Hand');
        await RepoIngestZaehler(rm).eintragen(id, _d('2026-10-18'), 1012345);
        await alle();
        for (final r in [rm, rp]) {
          final z = (await lesen(r)).single.inhalt!;
          expect(z.quelle, const ZaehlerQuelle(kanal: 'strom_bezug_geheim', pruefen: false));
          expect(z.automatisch, isTrue);
          final s = (await staendeLesen(r, id)).map((a) => a.inhalt!).toList();
          expect(s.map((e) => e.automatisch), [false, true]);
          expect(s.map((e) => e.milli), [1000000, 1012345]);
          expect([for (final x in await r.staende(id)) '${tagNummer(x.tag)}:${x.milli}'], hasLength(2));
          // der Zugriff des Dienstes sieht dieselben lesbaren Zähler und Stände
          final zugriff = RepoIngestZaehler(r);
          expect((await zugriff.zaehler()).keys, [id]);
          expect(await zugriff.staende(id), hasLength(2));
        }
        final gesehen = serverGesehen();
        for (final w in ['strom_bezug_geheim', 'quelle', 'kanal', '"q"', '1012345', 'pruefen']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
        // ein Tag mit Stand: der Dienst schreibt hier nichts mehr hinein (Entscheidung "schon vorhanden" liegt bei ingest_logik); der Zähler bleibt ein Zähler mit Standsrhythmus
        await expectLater(RepoIngestZaehler(rm).eintragen(id, _d('2026-10-20'), 1), throwsA(isA<StandUngueltig>())); // Zukunft (heute ist der 19.)
      });

      test('Ungültige Stände: Zukunft, unmögliche Werte; Plausibilität (niedriger, Sprung, doppelter Tag) wird gemeldet, aber nicht verboten', () async {
        final id = await strom(rm);
        await rm.standErfassen(id, datum: _d('2026-01-01'), milli: 100000);
        await rm.standErfassen(id, datum: _d('2026-02-01'), milli: 130000);
        await expectLater(rm.standErfassen(id, datum: _d('2026-10-20'), milli: 1), throwsA(isA<StandUngueltig>())); // heute ist der 19.
        await expectLater(rm.standErfassen(id, datum: _d('2026-03-01'), milli: -5), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.standErfassen(id, datum: _d('2026-03-01'), milli: kMaxStandMilli + 1), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.standAendern((await gm.db.select(gm.db.zaehlerstaende).get()).first.id, datum: _d('2027-01-01')), throwsA(isA<StandUngueltig>()));
        expect((await rm.standPruefen(id, datum: _d('2026-03-01'), milli: 160000)).ok, isTrue);
        expect((await rm.standPruefen(id, datum: _d('2026-03-01'), milli: 100000)).wechselVerdacht, isTrue);
        expect((await rm.standPruefen(id, datum: _d('2026-03-01'), milli: 1300000)).hinweise, contains(StandHinweis.sprung));
        expect((await rm.standPruefen(id, datum: _d('2026-02-01'), milli: 131000)).hinweise, contains(StandHinweis.datumDoppelt));
        expect((await rm.standPruefen(id, datum: _d('2026-10-20'), milli: 131000)).blockiert, isTrue);
        // ein Hinweis verbietet nichts: ein niedrigerer Stand lässt sich eintragen
        await rm.standErfassen(id, datum: _d('2026-03-01'), milli: 100000);
        expect(await rm.staende(id), hasLength(3));
        // ein zu ändernder Stand zählt bei der Prüfung nicht mit
        final zeilen = await gm.db.select(gm.db.zaehlerstaende).get();
        final feb = (await rm.lesenStaende(zeilen)).firstWhere((s) => s.inhalt!.datum == '2026-02-01');
        expect((await rm.standPruefen(id, datum: _d('2026-02-01'), milli: 100000, ausser: feb.id)).ok, isTrue);
      });

      test('Zählerwechsel: Endstand und Startstand, Kette alter -> neuer Zähler, der Verbrauch läuft nahtlos weiter; alles auf beiden Geräten', () async {
        final alt = await strom(rm);
        await rm.standErfassen(alt, datum: _d('2026-01-01'), milli: 1000000);
        await rm.standErfassen(alt, datum: _d('2026-06-01'), milli: 1151000);
        await alle();
        // Endstand darf nicht kleiner sein als der letzte Stand, und nicht in der Zukunft
        await expectLater(rm.zaehlerWechseln(alt, datum: _d('2026-10-01'), endstandMilli: 1000, startstandMilli: 0), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.zaehlerWechseln(alt, datum: _d('2026-11-01'), endstandMilli: 1300000, startstandMilli: 0), throwsA(isA<StandUngueltig>()));
        expect(await rm.staende(alt), hasLength(2));
        expect(welt.alle('zaehler'), hasLength(1));
        final neu = await rm.zaehlerWechseln(alt, datum: _d('2026-10-01'), endstandMilli: 1300000, startstandMilli: 0);
        await rm.standErfassen(neu, datum: _d('2026-10-19'), milli: 18000);
        await alle();
        // beide Zähler, der alte archiviert, der neue mit Vorgänger, ohne Zählernummer, mit denselben Preisen
        final ansichten = {for (final a in await lesen(rp)) a.id: a.inhalt!};
        expect(ansichten.keys.toSet(), {alt, neu});
        expect(ansichten[alt]!.archiviertAb, '2026-10-01');
        expect(ansichten[neu]!.vorgaenger, alt);
        expect(ansichten[neu]!.archiviert, isFalse);
        expect(ansichten[neu]!.nummer, '');
        expect(ansichten[neu]!.preise, ansichten[alt]!.preise);
        expect(kette(neu, ansichten), [alt, neu]);
        expect(juengsterDerKette(alt, ansichten), neu);
        // Marken beim Wechsel
        final ende = normalisiere(await rp.staende(alt)).last;
        final start = normalisiere(await rp.staende(neu)).first;
        expect([ende.marke, ende.milli], [StandMarke.ende, 1300000]);
        expect([start.marke, start.milli], [StandMarke.start, 0]);
        // der Verbrauch läuft über den Wechsel hinweg nahtlos
        final r = Verbrauchskurve.verkettet([Verbrauchskurve.aus(await rp.staende(alt)), Verbrauchskurve.aus(await rp.staende(neu))]);
        expect(r.luecken, 0);
        final v = r.kurve.verbrauch(_d('2026-01-01'), _d('2026-10-19'));
        expect(v.milli, 300000 + 18000);
        expect(v.vollstaendig, isTrue);
        // der Server weiß nichts davon, dass es ein Wechsel war
        for (final w in ['vor', 'wechsel', 'ende', 'start', 'arch']) {
          expect(serverGesehen(), isNot(contains('"$w"')), reason: w);
        }
      });

      test('Wasser: mehrere Zähler als Gruppe mit Summe (Warmwasser Etage, Kaltwasser Etage, Kaltwasser Waschkeller)', () async {
        final kEtage = await rm.anlegen(_wasser(ZaehlerArt.kaltwasser, 'Kaltwasser Etage', gruppe: 'Haus'));
        final kKeller = await rm.anlegen(_wasser(ZaehlerArt.kaltwasser, 'Kaltwasser Waschkeller', gruppe: 'haus'));
        final wEtage = await rm.anlegen(_wasser(ZaehlerArt.warmwasser, 'Warmwasser Etage', gruppe: 'Haus'));
        for (final (id, a, b) in [(kEtage, 100000, 131000), (kKeller, 50000, 62000), (wEtage, 20000, 29000)]) {
          await rm.standErfassen(id, datum: _d('2026-01-01'), milli: a);
          await rm.standErfassen(id, datum: _d('2026-02-01'), milli: b);
        }
        await alle();
        final alleZ = {for (final a in await lesen(rp)) a.id: a.inhalt!};
        expect(alleZ[kEtage]!.kosten, isFalse); // Wasser ohne Kosten
        expect(gruppenMitglieder(kEtage, alleZ), unorderedEquals([kEtage, kKeller]));
        expect(gruppenMitglieder(wEtage, alleZ), [wEtage]);
        final summe = gruppenSumme([for (final id in gruppenMitglieder(kEtage, alleZ)) Verbrauchskurve.aus(await rp.staende(id)).verbrauch(_d('2026-01-01'), _d('2026-02-01'))]);
        expect(summe.milli, 31000 + 12000);
        expect(summe.vollstaendig, isTrue);
      });

      test('Obergrenze: höchstens 50 Zähler (auch beim Zählerwechsel)', () async {
        final id = await strom(rm);
        await rm.standErfassen(id, datum: _d('2026-01-01'), milli: 1);
        final k = zaehlerChatId(familieId);
        for (var i = 0; i < kMaxZaehler - 1; i++) {
          await gm.db.into(gm.db.zaehler).insert(ZaehlerCompanion.insert(id: 'x$i', konversationId: k, inhalt: 'e1:x', createdAt: DateTime.utc(2026)));
        }
        await expectLater(rm.anlegen(_strom(name: 'noch einer')), throwsA(isA<ZaehlerFehler>()));
        await expectLater(rm.zaehlerWechseln(id, datum: _d('2026-02-01'), endstandMilli: 5, startstandMilli: 0), throwsA(isA<ZaehlerFehler>()));
      });

      test('Eltern kommen später dazu: die Teilnehmerpflege nimmt sie auf (neue Epoche), aber OHNE Verlauf; der Verlauf nur auf ausdrücklichen Tipp', () async {
        // nur Mama ist Elternteil und legt an; Papa ist noch kein Mitglied
        await aufbau();
        welt.aktiveMitglieder = [_mama, _emil, _anna];
        welt.rollen.remove(_papa);
        mitglieder = [for (final m in mitglieder) if (m.id != _papa) m];
        lernen();
        final id = await strom(rm);
        await rm.standErfassen(id, datum: _d('2026-10-01'), milli: 4242000);
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], [_mama]);
        // Papa wird Admin
        welt.aktiveMitglieder = [...welt.aktiveMitglieder, _papa];
        welt.rollen[_papa] = Role.admin;
        mitglieder = [...mitglieder, _u(_papa, Role.admin)];
        lernen();
        expect(await rm.teilnehmerPflegen(), isTrue);
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa]));
        await pflegen(gm);
        await alle();
        // Papa sieht die Zeilen, kann den alten Inhalt aber nicht lesen (kein Verlauf)
        final davor = await lesen(rp);
        expect(davor.single.inhalt, isNull);
        expect(davor.single.hinweis, isNotNull);
        // neue Einträge nach der Aufnahme liest er
        final neu = await rm.anlegen(_strom(name: 'Neuer Zähler'));
        await alle();
        expect((await lesen(rp)).firstWhere((a) => a.id == neu).inhalt!.name, 'Neuer Zähler');
        // Verlauf teilen auf Tipp
        expect(await rm.verlaufTeilen({_papa}), isTrue);
        await alle();
        expect((await lesen(rp)).firstWhere((a) => a.id == id).inhalt!.name, 'Hauptzähler Keller-Geheim');
        expect((await staendeLesen(rp, id)).single.inhalt!.milli, 4242000);
        // niemand sonst bekommt etwas; ein Kind nie, auch nicht auf Anfrage
        expect(await rm.verlaufTeilen({_emil}), isFalse);
        expect(await rm.verlaufTeilen({}), isFalse);
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa]));
        // nichts mehr zu tun
        expect(await rm.teilnehmerPflegen(), isFalse);
        expect(await rp.teilnehmerPflegen(), isFalse);
      });

      test('Mit ausdrücklichem Verlauf-teilen-Schalter bekommt die neue Person den Verlauf mit der Aufnahme', () async {
        await aufbau();
        welt.aktiveMitglieder = [_mama, _emil, _anna];
        welt.rollen.remove(_papa);
        mitglieder = [for (final m in mitglieder) if (m.id != _papa) m];
        lernen();
        final id = await strom(rm);
        await alle();
        welt.aktiveMitglieder = [...welt.aktiveMitglieder, _papa];
        welt.rollen[_papa] = Role.admin;
        mitglieder = [...mitglieder, _u(_papa, Role.admin)];
        lernen();
        expect(await rm.teilnehmerPflegen(verlaufTeilen: true), isTrue);
        await alle();
        expect((await lesen(rp)).firstWhere((a) => a.id == id).inhalt!.name, 'Hauptzähler Keller-Geheim');
      });

      test('Eltern ohne eingerichtete Verschlüsselung kommen erst mit Schlüssel dazu; niemand wird deswegen entfernt', () async {
        await strom(rm);
        await alle();
        final oma = TestPerson('eeeeeeee-0000-4000-8000-00000000000e', 'Oma', crypto);
        welt.aktiveMitglieder = [...welt.aktiveMitglieder, oma.id];
        welt.rollen[oma.id] = Role.parent;
        mitglieder = [...mitglieder, _u(oma.id, Role.parent)];
        for (final g in geraete) {
          g.mitgliederLernen([mama, papa, emil, anna, oma], ohneSchluessel: {oma.id});
        }
        expect(await rm.teilnehmerPflegen(), isFalse);
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa]));
      });

      test('Kind wird Elternteil: der Server nimmt es nicht von selbst auf; die Pflege tut es, ohne Verlauf', () async {
        final id = await strom(rm);
        await alle();
        welt.rollenwechsel(_emil, Role.parent);
        mitglieder = [for (final m in mitglieder) m.id == _emil ? _u(_emil, Role.parent) : m];
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa])); // nicht von selbst
        expect(darfZaehlerSehen(ich: _emil, mitglieder: mitglieder), isTrue);
        expect(await rm.teilnehmerPflegen(), isTrue);
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa, _emil]));
        // ohne Verlauf: der alte Inhalt bleibt ihm verschlossen
        expect((await lesen(re)).single.inhalt, isNull);
        expect(await rm.verlaufTeilen({_emil}), isTrue);
        await alle();
        expect((await lesen(re)).firstWhere((a) => a.id == id).inhalt!.name, 'Hauptzähler Keller-Geheim');
        // Anna (weiter Kind) sieht nichts
        expect(welt.sichtbarFuer(_anna, 'zaehler'), isEmpty);
      });

      test('Elternteil wird Kind: der Server wirft es sofort aus der Liste (hidden), es rotiert den Schlüssel; es liest Neues nicht mehr und sieht nichts mehr', () async {
        final id = await strom(rm);
        await alle();
        expect((await lesen(rp)).single.inhalt!.name, 'Hauptzähler Keller-Geheim');
        welt.rollenwechsel(_papa, Role.child);
        mitglieder = [for (final m in mitglieder) m.id == _papa ? _u(_papa, Role.child) : m];
        expect(welt.alle('konversation').single.fields['teilnehmer'], [_mama]);
        await alle();
        await pflegen(gm); // die Schlüsselpflege der Verbleibenden legt eine Epoche ohne Papa an
        await alle();
        // Papa: keine Konversation mehr (hidden-Tombstone), nichts mehr lokal
        expect(welt.sichtbarFuer(_papa, 'konversation'), isEmpty);
        expect(await lesen(rp), isEmpty);
        expect(await gp.db.select(gp.db.konversationen).get(), isEmpty);
        // Neues liest er nicht mehr, selbst wenn er die Hülle bekäme
        final neu = await rm.anlegen(_strom(name: 'Neuer Zähler'));
        await alle();
        final z = welt.zeile('zaehler', neu)!;
        final r = await gp.krypto.nachrichtOeffnen(konversationId: zaehlerChatId(familieId), nachrichtId: neu, autorId: _mama, wire: z.fields['inhalt'] as String, art: kArtZaehler);
        expect(r.lesbar, isFalse);
        // er darf nichts mehr anlegen oder pflegen
        await expectLater(rp.anlegen(_strom()), throwsA(isA<ZaehlerNichtErlaubt>()));
        expect(await rp.teilnehmerPflegen(), isFalse);
        expect(id, isNotEmpty);
        // und die Mama darf ihn nicht wieder aufnehmen (er ist ein Kind)
        expect(await rm.teilnehmerPflegen(), isFalse);
      });

      test('Monatswerte: eintragen, ersetzen (ein Monat nur einmal), zwei Geräte gleichzeitig ergeben einen Wert, Löschen, der Server sieht nie Klartext', () async {
        final id = await rm.anlegen(ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Balkon-Geheim', modus: ZaehlerModus.monat));
        gm.jetzt = gp.jetzt = DateTime.utc(2026, 10, 19, 9);
        await alle();
        final e1 = await rm.monatswertErfassen(id, jahr: 2026, monat: 9, milli: 123456, notiz: 'Anker-Geheim');
        await alle();
        // Ersetzen: derselbe Eintrag, nicht doppelt
        final e2 = await rp.monatswertErfassen(id, jahr: 2026, monat: 9, milli: 130000);
        expect(e2, e1);
        await alle();
        expect(welt.alle('zaehlerstand'), hasLength(1));
        expect((await rm.monatswerte(id)).single.milli, 130000);
        // zwei Geräte tragen offline denselben Monat ein: nach dem Abgleich zwei Zeilen, aber EIN Wert (der zuletzt geschriebene), auf beiden Geräten gleich
        gm.jetzt = DateTime.utc(2026, 10, 19, 10);
        gp.jetzt = DateTime.utc(2026, 10, 19, 11);
        await rm.monatswertErfassen(id, jahr: 2026, monat: 8, milli: 50000);
        await rp.monatswertErfassen(id, jahr: 2026, monat: 8, milli: 60000);
        await alle();
        expect(welt.alle('zaehlerstand'), hasLength(3));
        expect((await rm.monatswerte(id)).map((w) => '${w.monat}:${w.milli}'), ['8:60000', '9:130000']);
        expect((await rp.monatswerte(id)).map((w) => '${w.monat}:${w.milli}'), ['8:60000', '9:130000']);
        // das nächste Eintragen räumt das Doppelte auf
        await rm.monatswertErfassen(id, jahr: 2026, monat: 8, milli: 61000);
        await alle();
        expect(welt.alle('zaehlerstand'), hasLength(2));
        expect((await rp.monatswerte(id)).first.milli, 61000);
        // Löschen
        await rp.monatswertLoeschen(id, jahr: 2026, monat: 8);
        await alle();
        expect((await rm.monatswerte(id)).map((w) => w.monat), [9]);
        // der Server sieht weder Name noch Monat noch Wert noch Notiz
        final gesehen = serverGesehen();
        for (final geheim in ['Balkon-Geheim', 'Anker-Geheim', '2026-09', '123456', '130000', '"monat"']) {
          expect(gesehen, isNot(contains(geheim)));
        }
      });

      test('Monatswerte: Grenzen (nie negativ, höchstens 100 000, nie die Zukunft), laufender Monat erlaubt; Stände und Zählerwechsel gibt es dort nicht, und umgekehrt', () async {
        final id = await rm.anlegen(ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Balkon', modus: ZaehlerModus.monat));
        gm.jetzt = DateTime.utc(2026, 10, 19, 9);
        await expectLater(rm.monatswertErfassen(id, jahr: 2026, monat: 9, milli: -1), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.monatswertErfassen(id, jahr: 2026, monat: 9, milli: kMaxMonatswertMilli + 1), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.monatswertErfassen(id, jahr: 2026, monat: 11, milli: 1000), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.monatswertErfassen(id, jahr: 2027, monat: 1, milli: 1000), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.monatswertErfassen(id, jahr: 2026, monat: 13, milli: 1000), throwsA(isA<StandUngueltig>()));
        await rm.monatswertErfassen(id, jahr: 2026, monat: 10, milli: 1000); // laufender Monat = Zwischenstand
        await rm.monatswertErfassen(id, jahr: 2026, monat: 9, milli: kMaxMonatswertMilli);
        await expectLater(rm.standErfassen(id, datum: _d('2026-10-01'), milli: 1000), throwsA(isA<StandUngueltig>()));
        await expectLater(rm.zaehlerWechseln(id, datum: _d('2026-10-01'), endstandMilli: 1, startstandMilli: 0), throwsA(isA<StandUngueltig>()));
        final hinweis = await rm.monatswertPruefen(id, jahr: 2026, monat: 9, milli: 1);
        expect(hinweis.hinweise, contains(MonatswertHinweis.ersetzt));
        // ein Zähler im Modus Zählerstand nimmt keine Monatswerte
        final stromId = await strom(rm);
        await expectLater(rm.monatswertErfassen(stromId, jahr: 2026, monat: 9, milli: 1000), throwsA(isA<StandUngueltig>()));
      });

      test('Kinder: Monatswerte gibt es für sie nie', () async {
        final id = await rm.anlegen(ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Balkon', modus: ZaehlerModus.monat));
        await alle();
        await expectLater(re.monatswertErfassen(id, jahr: 2026, monat: 9, milli: 1000), throwsA(isA<ZaehlerNichtErlaubt>()));
        await expectLater(re.monatswertLoeschen(id, jahr: 2026, monat: 9), throwsA(isA<ZaehlerNichtErlaubt>()));
      });

      test('Das Betreiber-Flag und die Familienrolle ändern nichts: nur die Rolle zählt', () async {
        // ein Kind mit Familienrolle Vater (Anzeige) bleibt ein Kind
        final kind = UserDto(id: _emil, email: null, displayName: 'Emil', colorIndex: 0, role: Role.child, status: MemberStatus.active, familyRole: FamilyRole.vater);
        mitglieder = [for (final m in mitglieder) m.id == _emil ? kind : m];
        await expectLater(re.anlegen(_strom()), throwsA(isA<ZaehlerNichtErlaubt>()));
      });
    });
  }
}
