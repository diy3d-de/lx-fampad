// Medikamenten-Plan Ende-zu-Ende (Abschnitt 6k): echte lokale Datenbanken je Gerät, echter Store und Ausgang-Vorbereiter gegen den Fake-Server, der die Regeln des echten
// Servers nachbildet (Sicht nach Teilnehmern, Rollen-Regel der Medikamenten-Konversation, Hülle e1). Geprüft: Sichtregeln (Erwachsene sehen nie die eines anderen Erwachsenen,
// Eltern sehen die Kinder, Kinder nur die eigenen), der Server sieht nie Klartext, Teilnehmer-Pflege bei Rollen-/Mitgliederwechsel mit Rotation, Einnahmen, Vorrat, Fehlerfälle.
import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/app_database.dart' show EinnahmenCompanion;
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/medikamente/medikament_logik.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:lx_fampad/data/medikamente/medikament_repository.dart';
import 'package:lx_fampad/data/medikamente/medikament_subjekte.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';

const _mama = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _papa = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _emil = 'cccccccc-0000-4000-8000-00000000000c';
const _anna = 'dddddddd-0000-4000-8000-00000000000d';

UserDto _u(String id, Role r) => UserDto(id: id, email: null, displayName: id, colorIndex: 0, role: r, status: MemberStatus.active);

MedikamentInhalt _plan({String name = 'Ventolin', List<String> zeiten = const ['08:00', '20:00'], double? bestand, DateTime? stand, double? packung}) => MedikamentInhalt(
  name: name,
  dosis: '2 Hübe',
  zeiten: zeiten,
  notiz: 'Geheimnotiz',
  bestand: bestand,
  bestandStand: bestand == null ? null : (stand ?? DateTime.utc(2026, 10, 1)),
  packung: packung,
);

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Medikamenten-Plan Ende-zu-Ende ($name)', () {
      late ChatWelt welt;
      late TestPerson mama, papa, emil, anna;
      late Geraet gm, gp, ge, ga;
      late List<UserDto> mitglieder;
      final geraete = <Geraet>[];

      MedikamentRepository rep(Geraet g) => MedikamentRepository(
        db: g.db,
        store: g.store,
        krypto: () async => g.bereit ? g.krypto : null,
        ich: () => g.person.id,
        mitglieder: () async => mitglieder,
        beiAenderung: () {},
        jetzt: () => g.jetzt,
      );

      late MedikamentRepository rm, rp, re, ra;

      List<TestPerson> personen() => [mama, papa, emil, anna];

      void lernen() {
        for (final g in geraete) {
          g.mitgliederLernen([for (final p in personen()) if (welt.aktiveMitglieder.contains(p.id)) p]);
        }
      }

      /// Baut die Welt mit den genannten aktiven Personen (die übrigen sind noch nicht in der Familie).
      Future<void> aufbau({Set<String> aktiv = const {_mama, _papa, _emil, _anna}}) async {
        for (final g in geraete) {
          await g.schliessen();
        }
        welt = ChatWelt(crypto);
        mama = TestPerson(_mama, 'Mama', crypto);
        papa = TestPerson(_papa, 'Papa', crypto);
        emil = TestPerson(_emil, 'Emil', crypto);
        anna = TestPerson(_anna, 'Anna', crypto);
        final rollen = {_mama: Role.parent, _papa: Role.admin, _emil: Role.child, _anna: Role.child};
        welt.aktiveMitglieder = [for (final id in rollen.keys) if (aktiv.contains(id)) id];
        welt.rollen
          ..clear()
          ..addAll({for (final e in rollen.entries) if (aktiv.contains(e.key)) e.key: e.value});
        mitglieder = [for (final e in welt.rollen.entries) _u(e.key, e.value)];
        geraete.clear();
        gm = Geraet.neu(welt, mama);
        gp = Geraet.neu(welt, papa);
        ge = Geraet.neu(welt, emil);
        ga = Geraet.neu(welt, anna);
        geraete.addAll([gm, gp, ge, ga]);
        lernen();
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

      Future<List<MedikamentAnsicht>> lesen(MedikamentRepository r, String subjekt) async => r.lesen(subjekt, await r.zeilen(subjekt).first);

      Future<List<EinnahmeAnsicht>> einnahmen(MedikamentRepository r, String medikament) async => r.lesenEinnahmen(await r.einnahmenZeilen(medikament).first);

      String serverGesehen() => jsonEncode(welt.gesehen) + jsonEncode([for (final e in ['konversation', 'medikament', 'einnahme']) for (final z in welt.alle(e)) z.fields]);

      test('Kind legt sein Medikament an, Eltern lesen es; der Server sieht nur e1-Hüllen und nie Name, Dosis, Uhrzeit oder Notiz', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        // Eltern lesen es
        for (final r in [rm, rp, re]) {
          final l = await lesen(r, _emil);
          expect(l, hasLength(1));
          expect(l.single.id, id);
          expect(l.single.inhalt!.name, 'Ventolin');
          expect(l.single.inhalt!.notiz, 'Geheimnotiz');
          expect(l.single.lokalNeu, isFalse);
        }
        // Server: feste ID der Konversation, Subjekt, Teilnehmer, e1-Hülle, Bearbeiter
        final k = welt.alle('konversation').single;
        expect(k.id, medsChatId(_emil));
        expect(k.fields['art'], 'meds');
        expect(k.fields['subjektId'], _emil);
        expect((k.fields['teilnehmer'] as List).cast<String>().toSet(), {_emil, _mama, _papa});
        final z = welt.alle('medikament').single;
        expect(z.fields['inhalt'], startsWith('e1:'));
        expect(z.fields['bearbeiterId'], _emil);
        final gesehen = serverGesehen();
        for (final w in ['Ventolin', 'Hübe', 'Geheimnotiz', '08:00', '20:00', 'm1:', 'n1:', 'l1:', 'rhythmus', 'zeiten']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
        // Schwester und anderer Erwachsener ohne Teilnahme bekommen nichts
        expect(welt.sichtbarFuer(_anna, 'konversation'), isEmpty);
        expect(welt.sichtbarFuer(_anna, 'medikament'), isEmpty);
        expect(await lesen(ra, _emil), isEmpty);
      });

      test('Sicht: Erwachsene sehen nie die eines anderen Erwachsenen (auch Admins nicht), Kinder nur die eigenen; fremde Subjekte werden gar nicht erst angelegt', () async {
        await rm.anlegen(_mama, _plan(name: 'Pille'));
        await rp.anlegen(_papa, _plan(name: 'Blutdruck'));
        await re.anlegen(_emil, _plan(name: 'Inhalator'));
        await ra.anlegen(_anna, _plan(name: 'Eisen'));
        await alle();
        expect([for (final m in await lesen(rm, _mama)) m.inhalt!.name], ['Pille']);
        expect([for (final m in await lesen(rp, _papa)) m.inhalt!.name], ['Blutdruck']);
        // Server: jede Person bekommt nur die eigenen Konversationen (Kinder: samt Eltern)
        expect(welt.sichtbarFuer(_mama, 'konversation').map((z) => z.id).toSet(), {medsChatId(_mama), medsChatId(_emil), medsChatId(_anna)});
        expect(welt.sichtbarFuer(_papa, 'konversation').map((z) => z.id).toSet(), {medsChatId(_papa), medsChatId(_emil), medsChatId(_anna)});
        expect(welt.sichtbarFuer(_emil, 'konversation').map((z) => z.id).toSet(), {medsChatId(_emil)});
        expect(welt.sichtbarFuer(_anna, 'konversation').map((z) => z.id).toSet(), {medsChatId(_anna)});
        // lokal: Mama hat die Medikamente von Papa nie bekommen, Papa die von Mama nicht, Emil nichts von Anna
        expect(await lesen(rm, _papa), isEmpty);
        expect(await lesen(rp, _mama), isEmpty);
        expect(await lesen(re, _anna), isEmpty);
        expect(await lesen(ra, _emil), isEmpty);
        // und anlegen darf niemand für einen anderen Erwachsenen oder ein Geschwister
        await expectLater(rm.anlegen(_papa, _plan()), throwsA(isA<MedikamentNichtErlaubt>()));
        await expectLater(rp.anlegen(_mama, _plan()), throwsA(isA<MedikamentNichtErlaubt>()));
        await expectLater(re.anlegen(_anna, _plan()), throwsA(isA<MedikamentNichtErlaubt>()));
        await expectLater(ra.anlegen(_mama, _plan()), throwsA(isA<MedikamentNichtErlaubt>()));
        await expectLater(re.konversationSicherstellen(_mama), throwsA(isA<MedikamentNichtErlaubt>()));
        // Eltern dürfen für ihre Kinder anlegen
        await rm.anlegen(_anna, _plan(name: 'Vitamin'));
        await alle();
        expect([for (final m in await lesen(ra, _anna)) m.inhalt!.name]..sort(), ['Eisen', 'Vitamin']);
      });

      test('Eltern legen für ein Kind an: das Kind liest es, die Konversation hat die Eltern und das Kind als Teilnehmer', () async {
        await rm.anlegen(_emil, _plan(name: 'Antibiotikum'));
        await alle();
        expect([for (final m in await lesen(re, _emil)) m.inhalt!.name], ['Antibiotikum']);
        expect([for (final m in await lesen(rp, _emil)) m.inhalt!.name], ['Antibiotikum']);
        expect(welt.alle('medikament').single.fields['bearbeiterId'], _mama);
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_emil, _mama, _papa]));
      });

      test('Ändern durch ein Elternteil: der Bearbeiter wechselt, das Kind liest den neuen Stand; Pausieren, Beenden, Fortsetzen, Löschen', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        await rm.aendern(id, _plan(name: 'Ventolin forte', zeiten: const ['07:00']));
        await alle();
        expect((await lesen(re, _emil)).single.inhalt!.name, 'Ventolin forte');
        expect(welt.alle('medikament').single.fields['bearbeiterId'], _mama);
        expect((await lesen(rp, _emil)).single.inhalt!.zeiten, ['07:00']);
        // pausieren (ab heute bis einschließlich 25.10.), fortsetzen, beenden
        gm.jetzt = DateTime.utc(2026, 10, 23, 8);
        await rm.pausieren(id, bis: DateTime.utc(2026, 10, 25));
        await alle();
        var m = (await lesen(re, _emil)).single.inhalt!;
        expect([m.zustand, m.zustandAb, m.pauseBis], [MedikamentZustand.pausiert, '2026-10-23', '2026-10-25']);
        expect(slotsAmTag(m, tagLesen('2026-10-24')!), isEmpty);
        expect(slotsAmTag(m, tagLesen('2026-10-26')!), hasLength(1));
        await rm.fortsetzen(id);
        await alle();
        m = (await lesen(re, _emil)).single.inhalt!;
        expect([m.zustand, m.zustandAb, m.pauseBis], [MedikamentZustand.aktiv, null, null]);
        await rm.beenden(id);
        await alle();
        m = (await lesen(re, _emil)).single.inhalt!;
        expect([m.zustand, m.zustandAb], [MedikamentZustand.beendet, '2026-10-23']);
        expect(slotsAmTag(m, tagLesen('2026-10-24')!), isEmpty);
        // Löschen entfernt es samt Einnahmen überall
        ge.jetzt = DateTime.utc(2026, 10, 23, 8);
        final e = await re.einnahmeErfassen(id, slot: const Slot('2026-10-22', '07:00'), um: DateTime.utc(2026, 10, 22, 5));
        await alle();
        expect(welt.alle('einnahme'), hasLength(1));
        await rp.loeschen(id);
        await alle();
        expect(welt.alle('medikament'), isEmpty);
        expect(welt.alle('einnahme'), isEmpty);
        expect(await lesen(re, _emil), isEmpty);
        expect(await ge.db.select(ge.db.einnahmen).get(), isEmpty);
        expect(e, isNotEmpty);
      });

      test('Der Klartext verlässt das Gerät nie: ohne Schlüssel bleibt alles im Ausgang (l1:), der Server bekommt nur e1', () async {
        ge.bereit = false;
        await expectLater(re.anlegen(_emil, _plan()), throwsA(isA<VerschluesselungNichtBereit>()));
        ge.bereit = true;
        final id = await re.anlegen(_emil, _plan());
        // noch nichts abgeglichen: lokal liegt Klartext mit l1: im Ausgang, lesbar nur für den Autor dieses Geräts
        expect((await ge.ausgang()).any((o) => o.entity == 'medikament' && o.fieldsJson.contains('l1:m1:')), isTrue);
        expect((await lesen(re, _emil)).single.inhalt!.name, 'Ventolin');
        expect((await lesen(re, _emil)).single.lokalNeu, isTrue);
        // das Gerät ist gerade nicht bereit: nichts geht hinaus
        ge.bereit = false;
        final ops = await ge.store.naechsteOps(50, vorbereiter: ge.vorbereiter);
        expect(ops.where((o) => o.entity == 'medikament'), isEmpty);
        expect(jsonEncode(welt.gesehen), isNot(contains('Ventolin')));
        ge.bereit = true;
        await alle();
        expect(welt.alle('medikament').single.fields['inhalt'], startsWith('e1:'));
        expect(serverGesehen(), isNot(contains('Ventolin')));
        expect(serverGesehen(), isNot(contains('l1:')));
        expect((await lesen(rm, _emil)).single.id, id);
      });

      test('Die Hülle ist an Art, Konversation, eigene ID, Bezug und Bearbeiter gebunden: umgehängt wird sie nicht geöffnet', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        final e = await re.einnahmeErfassen(id, slot: const Slot('2026-10-19', '08:00'), um: DateTime.utc(2026, 10, 19, 6));
        await alle();
        final mz = welt.alle('medikament').single;
        final ez = welt.alle('einnahme').single;
        final konv = medsChatId(_emil);
        final g = gm;
        Future<bool> geht(String wire, {required String id, required String autor, String? bezug, String? art, String? konversation}) async =>
            (await g.krypto.nachrichtOeffnen(konversationId: konversation ?? konv, nachrichtId: id, autorId: autor, wire: wire, antwortAuf: bezug, art: art)).lesbar;
        // richtig geöffnet
        expect(await geht(mz.fields['inhalt'] as String, id: mz.id, autor: _emil, art: kArtMedikament), isTrue);
        expect(await geht(ez.fields['inhalt'] as String, id: ez.id, autor: _emil, bezug: id, art: kArtEinnahme), isTrue);
        // falsche Art, kein oder falscher Bezug, fremde ID, anderer Bearbeiter, andere Konversation
        expect(await geht(mz.fields['inhalt'] as String, id: mz.id, autor: _emil), isFalse);
        expect(await geht(mz.fields['inhalt'] as String, id: mz.id, autor: _emil, art: kArtEinnahme, bezug: id), isFalse);
        expect(await geht(mz.fields['inhalt'] as String, id: ez.id, autor: _emil, art: kArtMedikament), isFalse);
        expect(await geht(mz.fields['inhalt'] as String, id: mz.id, autor: _mama, art: kArtMedikament), isFalse);
        expect(await geht(mz.fields['inhalt'] as String, id: mz.id, autor: _emil, art: kArtMedikament, konversation: medsChatId(_anna)), isFalse);
        expect(await geht(ez.fields['inhalt'] as String, id: ez.id, autor: _emil, art: kArtEinnahme), isFalse); // ohne Bezug
        expect(await geht(ez.fields['inhalt'] as String, id: ez.id, autor: _emil, art: kArtEinnahme, bezug: 'anderes-medikament'), isFalse);
        expect(await geht(ez.fields['inhalt'] as String, id: ez.id, autor: _emil, art: kArtMedikament, bezug: id), isFalse);
        expect(e, ez.id);
      });

      test('Eltern kommen später dazu: die Teilnehmer-Pflege nimmt sie mit Verlauf auf (neue Epoche), vorher sehen sie nichts', () async {
        // Papa ist noch nicht in der Familie
        await aufbau(aktiv: {_mama, _emil, _anna});
        await rm.anlegen(_emil, _plan(name: 'Ventolin'));
        await re.anlegen(_emil, _plan(name: 'Eisen'));
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_emil, _mama]));
        // Papa wird Admin
        welt.aktiveMitglieder = [..._welt(welt), _papa];
        welt.rollen[_papa] = Role.admin;
        mitglieder = [...mitglieder, _u(_papa, Role.admin)];
        lernen();
        expect(await rm.teilnehmerPflegen(_emil), isTrue);
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_emil, _mama, _papa]));
        await pflegen(ge);
        await alle();
        // Papa liest den Verlauf (die ältere Epoche kam mit)
        expect([for (final m in await lesen(rp, _emil)) m.inhalt!.name]..sort(), ['Eisen', 'Ventolin']);
        // nichts mehr zu tun: erneut ändert nichts
        expect(await rm.teilnehmerPflegen(_emil), isFalse);
        expect(await re.teilnehmerPflegen(_emil), isFalse);
        // wer nicht Teilnehmer ist (Schwester, die keine Konversation von Emil kennt), ändert nichts
        expect(await ra.teilnehmerPflegen(_emil), isFalse);
      });

      test('Eltern ohne eingerichtete Verschlüsselung: sie kommen erst dazu, wenn sie einen Schlüssel haben; niemand wird deswegen entfernt', () async {
        await rm.anlegen(_emil, _plan());
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_emil, _mama, _papa]));
        // eine neue Mutter ohne Schlüssel (Mitglied ohne Personenschlüssel)
        final oma = TestPerson('eeeeeeee-0000-4000-8000-00000000000e', 'Oma', crypto);
        welt.aktiveMitglieder = [..._welt(welt), oma.id];
        welt.rollen[oma.id] = Role.parent;
        mitglieder = [...mitglieder, _u(oma.id, Role.parent)];
        for (final g in geraete) {
          g.mitgliederLernen([mama, papa, emil, anna, oma], ohneSchluessel: {oma.id});
        }
        expect(await rm.teilnehmerPflegen(_emil), isFalse); // niemand fehlt, der einen Schlüssel hätte; keiner geht
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_emil, _mama, _papa]));
      });

      test('Kind wird Erwachsener: der Server wirft die Eltern aus seiner Liste, es rotiert den Schlüssel; die Eltern lesen Neues nicht mehr', () async {
        final id = await re.anlegen(_emil, _plan(name: 'Ventolin'));
        await alle();
        expect([for (final m in await lesen(rm, _emil)) m.inhalt!.name], ['Ventolin']);
        // Emil wird erwachsen
        welt.rollenwechsel(_emil, Role.parent);
        mitglieder = [for (final m in mitglieder) m.id == _emil ? _u(_emil, Role.parent) : m];
        expect(welt.alle('konversation').single.fields['teilnehmer'], [_emil]);
        await alle();
        await pflegen(ge); // die Schlüsselpflege der App legt eine Epoche ohne die Eltern an
        await alle();
        // Eltern bekommen die Konversation nicht mehr geliefert; Emil schreibt mit dem neuen Schlüssel
        expect(welt.sichtbarFuer(_mama, 'konversation'), isEmpty);
        expect(welt.sichtbarFuer(_papa, 'medikament'), isEmpty);
        final neu = await re.anlegen(_emil, _plan(name: 'Neues Mittel'));
        await alle();
        final z = welt.zeile('medikament', neu)!;
        for (final eltern in [gm, gp]) {
          final r = await eltern.krypto.nachrichtOeffnen(konversationId: medsChatId(_emil), nachrichtId: neu, autorId: _emil, wire: z.fields['inhalt'] as String, art: kArtMedikament);
          expect(r.lesbar, isFalse, reason: 'Eltern lesen Neues nicht');
        }
        expect((await lesen(re, _emil)).map((m) => m.inhalt?.name).toSet(), {'Ventolin', 'Neues Mittel'});
        expect(id, isNotEmpty);
        // Emil sieht jetzt als Erwachsener nur noch seine eigenen (keine Kinder: Anna ist nicht sein Kind, nur Eltern/Admins sehen Kinder, Emil ist nun auch Elternteil)
        expect(erlaubteSubjekte(ich: _emil, mitglieder: mitglieder).map((u) => u.id), [_emil, _anna]);
        // die Eltern können die Konversation nicht mehr pflegen oder ändern
        expect(await rm.teilnehmerPflegen(_emil), isFalse);
      });

      test('Elternteil wird Kind: es fliegt aus den Listen fremder Kinder und sieht nur noch seine eigenen Medikamente', () async {
        await re.anlegen(_emil, _plan());
        await rp.anlegen(_papa, _plan(name: 'Papas Mittel'));
        await alle();
        welt.rollenwechsel(_papa, Role.child);
        mitglieder = [for (final m in mitglieder) m.id == _papa ? _u(_papa, Role.child) : m];
        expect((welt.zeile('konversation', medsChatId(_emil))!.fields['teilnehmer'] as List).cast<String>().toSet(), {_emil, _mama});
        expect(welt.zeile('konversation', medsChatId(_papa))!.fields['teilnehmer'], [_papa]);
        expect(erlaubteSubjekte(ich: _papa, mitglieder: mitglieder).map((u) => u.id), [_papa]);
        await expectLater(rp.anlegen(_emil, _plan(name: 'Zusatz')), throwsA(isA<MedikamentNichtErlaubt>()));
        // Mama sieht Papas Konversation weiter nicht (der Server zieht Listen nie von sich aus auf neue Eltern hoch; das tut ein Teilnehmer mit der Teilnehmer-Pflege)
        expect(welt.sichtbarFuer(_mama, 'konversation').map((z) => z.id).toSet(), {medsChatId(_emil)});
      });

      test('Einnahmen: erfassen, übersprungen, nachtragen, doppelt auf zwei Geräten, zurücknehmen; der Server sieht keinen Zeitpunkt und keinen Status', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        ge.jetzt = DateTime.utc(2026, 10, 23, 6, 10); // 08:10 MESZ
        final s8 = const Slot('2026-10-23', '08:00');
        final s20 = const Slot('2026-10-23', '20:00');
        final e8 = await re.einnahmeErfassen(id, slot: s8);
        await re.einnahmeErfassen(id, slot: const Slot('2026-10-22', '20:00'), status: EinnahmeStatus.uebersprungen, um: DateTime.utc(2026, 10, 22, 18));
        await alle();
        var l = await einnahmen(rm, id);
        expect(l, hasLength(2));
        expect(l.map((x) => x.inhalt!.status).toSet(), {EinnahmeStatus.genommen, EinnahmeStatus.uebersprungen});
        // der Server weiß nur DASS es Einträge gibt
        final gesehen = serverGesehen();
        for (final w in ['2026-10-23', '08:00', 'genommen', '"g"', 'uebersprungen', 'n1:', 'l1:']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
        for (final z in welt.alle('einnahme')) {
          expect(z.fields['inhalt'], startsWith('e1:'));
          expect(z.fields['bearbeiterId'], _emil);
          expect(z.fields['medikamentId'], id);
        }
        // Stand der Slots aus den Einträgen
        ge.jetzt = DateTime.utc(2026, 10, 23, 7);
        final plan = tagesplan((await lesen(rm, _emil)).single.inhalt!, l, tagLesen('2026-10-23')!, ge.jetzt);
        expect([for (final t in plan) t.status], [SlotStatus.genommen, SlotStatus.offen]);
        // nachtragen durch ein Elternteil (der Slot am Abend), ein bereits genommener Slot bleibt unverändert (keine Verdopplung)
        gm.jetzt = DateTime.utc(2026, 10, 23, 19);
        final e20 = await rm.einnahmeErfassen(id, slot: s20, um: DateTime.utc(2026, 10, 23, 18, 5));
        expect(await rm.einnahmeErfassen(id, slot: s20), e20);
        await alle();
        expect(welt.alle('einnahme'), hasLength(3));
        expect((await einnahmen(re, id)).firstWhere((x) => x.id == e20).inhalt!.um, DateTime.utc(2026, 10, 23, 18, 5));
        expect(welt.zeile('einnahme', e20)!.fields['bearbeiterId'], _mama);
        // übersprungen -> später doch genommen: derselbe Eintrag wird ersetzt
        final alt = (await einnahmen(re, id)).firstWhere((x) => x.inhalt!.geplant == '2026-10-22T20:00');
        ge.jetzt = DateTime.utc(2026, 10, 23, 8);
        expect(await re.einnahmeErfassen(id, slot: const Slot('2026-10-22', '20:00'), um: DateTime.utc(2026, 10, 23, 7)), alt.id);
        await alle();
        expect(welt.alle('einnahme'), hasLength(3));
        expect((await einnahmen(rp, id)).firstWhere((x) => x.id == alt.id).inhalt!.status, EinnahmeStatus.genommen);
        // zurücknehmen
        await re.einnahmeZuruecknehmen(e8);
        await alle();
        expect(welt.alle('einnahme'), hasLength(2));
        expect((await einnahmen(rm, id)).map((x) => x.id), isNot(contains(e8)));
        // "bei Bedarf": ohne Slot, mehrfach möglich
        ge.jetzt = DateTime.utc(2026, 10, 23, 12);
        final b1 = await re.einnahmeErfassen(id, um: DateTime.utc(2026, 10, 23, 10));
        final b2 = await re.einnahmeErfassen(id, um: DateTime.utc(2026, 10, 23, 11));
        expect(b1, isNot(b2));
        await alle();
        expect(welt.alle('einnahme'), hasLength(4));
      });

      test('Zwei Geräte erfassen denselben Slot gleichzeitig: beide Einträge bleiben, die Anzeige fasst sie zusammen, "Zurücknehmen des Slots" löscht beide', () async {
        final tablet = Geraet.neu(welt, emil, name: 'Tablet', opPraefix: 'T-op-')..mitgliederLernen(personen());
        geraete.add(tablet);
        final rt = rep(tablet);
        final id = await re.anlegen(_emil, _plan());
        await abgleich([ge, tablet, gm]);
        final slot = const Slot('2026-10-23', '08:00');
        ge.jetzt = DateTime.utc(2026, 10, 23, 6, 5);
        tablet.jetzt = DateTime.utc(2026, 10, 23, 6, 7);
        await re.einnahmeErfassen(id, slot: slot);
        await rt.einnahmeErfassen(id, slot: slot);
        await abgleich([ge, tablet, gm]);
        final l = await einnahmen(rm, id);
        expect(l, hasLength(2));
        expect(einnahmeFuerSlot(l, slot), isNotNull);
        final m = (await lesen(rm, _emil)).single.inhalt!.kopie(bestand: () => 10, bestandStand: () => DateTime.utc(2026, 10, 1));
        expect(bestandJetzt(m, l), 9); // nur einmal verbraucht
        await rm.slotZuruecknehmen(id, slot);
        await abgleich([gm, ge, tablet]);
        expect(welt.alle('einnahme'), isEmpty);
      });

      test('Einnahme-Zeitpunkte: nie in der Zukunft, höchstens 120 Tage zurück; ungültiger Inhalt wird nie geschrieben', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        ge.jetzt = DateTime.utc(2026, 10, 23, 12);
        await expectLater(re.einnahmeErfassen(id, um: DateTime.utc(2026, 10, 23, 13)), throwsA(isA<EinnahmeUngueltig>()));
        await expectLater(re.einnahmeErfassen(id, um: DateTime.utc(2026, 6, 20)), throwsA(isA<EinnahmeUngueltig>()));
        await re.einnahmeErfassen(id, um: DateTime.utc(2026, 6, 26)); // knapp innerhalb der 120 Tage
        await expectLater(re.einnahmeErfassen(id, slot: const Slot('2026-13-40', '08:00')), throwsArgumentError);
        expect(await ge.db.select(ge.db.einnahmen).get(), hasLength(1));
        await expectLater(re.anlegen(_emil, MedikamentInhalt(name: '')), throwsArgumentError);
        await expectLater(re.aendern(id, _plan(zeiten: const [])), throwsArgumentError);
        expect(await ge.db.select(ge.db.medikamente).get(), hasLength(1));
      });

      test('Unlesbare Medikamente lassen sich nicht blind überschreiben (kein Schlüssel / Gerät nicht bereit); fehlende Medikamente: Fehler statt Absturz', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        gp.bereit = false;
        final l = await lesen(rp, _emil);
        expect(l.single.lesbar, isFalse);
        expect(l.single.hinweis, isNotNull);
        expect(l.single.hinweis, isNot(contains('Ventolin')));
        await expectLater(rp.aendern(id, _plan(name: 'x')), throwsA(isA<MedikamentNichtLesbar>()));
        await expectLater(rp.pausieren(id), throwsA(isA<MedikamentNichtLesbar>()));
        await expectLater(rp.einnahmeErfassen(id), throwsA(isA<MedikamentNichtLesbar>()));
        gp.bereit = true;
        await expectLater(rp.aendern('gibt-es-nicht', _plan()), throwsA(isA<MedikamentFehler>()));
        await expectLater(rp.loeschen('gibt-es-nicht'), throwsA(isA<MedikamentFehler>()));
        await rp.einnahmeZuruecknehmen('gibt-es-nicht'); // nichts zu tun, kein Fehler
      });

      test('Ohne Rechte geht nichts: Schwester kann Emils Medikament weder ändern noch Einnahmen erfassen noch löschen', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        // Annas Gerät kennt die Zeile gar nicht; selbst wenn sie lokal vorhanden wäre, verhindert die Rollen-Regel jede Änderung
        await ga.db.into(ga.db.konversationen).insertOnConflictUpdate(await (ge.db.select(ge.db.konversationen)).getSingle().then((k) => k.toCompanion(true)));
        await ga.db.into(ga.db.medikamente).insertOnConflictUpdate(await (ge.db.select(ge.db.medikamente)).getSingle().then((z) => z.toCompanion(true)));
        await expectLater(ra.aendern(id, _plan(name: 'x')), throwsA(isA<MedikamentNichtErlaubt>()));
        await expectLater(ra.einnahmeErfassen(id), throwsA(isA<MedikamentNichtErlaubt>()));
        await expectLater(ra.loeschen(id), throwsA(isA<MedikamentNichtErlaubt>()));
        expect(await ga.db.select(ga.db.outbox).get(), isEmpty);
      });

      test('Vorrat: aus den Einnahmen berechnet, Auffüllen setzt den Stichtag neu; reicht noch N Tage', () async {
        final id = await re.anlegen(_emil, _plan(zeiten: const ['08:00'], bestand: 5, stand: DateTime.utc(2026, 10, 20), packung: 30));
        await alle();
        ge.jetzt = DateTime.utc(2026, 10, 23, 5);
        await re.einnahmeErfassen(id, slot: const Slot('2026-10-21', '08:00'), um: DateTime.utc(2026, 10, 21, 6));
        await re.einnahmeErfassen(id, slot: const Slot('2026-10-22', '08:00'), um: DateTime.utc(2026, 10, 22, 6));
        await alle();
        var m = (await lesen(rm, _emil)).single.inhalt!;
        var ein = await einnahmen(rm, id);
        expect(bestandJetzt(m, ein), 3);
        final p = vorratPrognose(m, ein, DateTime.utc(2026, 10, 23, 5));
        expect([p.tage, p.leerAm], [3, '2026-10-26']);
        // Packung nachkaufen (durch ein Elternteil)
        gm.jetzt = DateTime.utc(2026, 10, 23, 9);
        await rm.vorratAuffuellen(id, packungen: 1);
        await alle();
        m = (await lesen(re, _emil)).single.inhalt!;
        ein = await einnahmen(re, id);
        expect(m.bestand, 33);
        expect(m.bestandStand, DateTime.utc(2026, 10, 23, 9));
        expect(bestandJetzt(m, ein), 33); // frühere Einnahmen zählen nach dem neuen Stichtag nicht mehr
        // ohne Packungsgröße geht nur Stück
        final id2 = await rm.anlegen(_emil, _plan(name: 'Zweites', zeiten: const ['08:00']));
        await alle();
        await expectLater(rm.vorratAuffuellen(id2, packungen: 1), throwsArgumentError);
        await rm.vorratAuffuellen(id2, stueck: 12);
        await alle();
        expect((await lesen(re, _emil)).firstWhere((x) => x.id == id2).inhalt!.bestand, 12);
      });

      test('Chatliste, Ungelesen-Zähler und Familienchat kennen die Medikamenten-Konversation nie', () async {
        await re.anlegen(_emil, _plan());
        await alle();
        for (final g in [ge, gm, gp]) {
          expect((await g.db.select(g.db.konversationen).get()).where((k) => k.art == 'meds'), hasLength(1));
          final liste = await g.repo.uebersicht(g.person.id).first;
          expect(liste.where((e) => e.konversation.art == 'meds'), isEmpty);
          expect(liste.every((e) => e.id != medsChatId(_emil)), isTrue);
        }
        // eine Nachricht in dieser Konversation lehnt der Server ab; sie bleibt als Fehler stehen und taucht nirgends auf
        final nid = await gm.repo.senden(medsChatId(_emil), 'hallo');
        await alle();
        expect(welt.alle('nachricht'), isEmpty);
        expect(welt.abgelehnt['nachricht'], greaterThan(0));
        expect(nid, isNotNull);
      });

      test('Aufräumen: lokale Einnahmen über 120 Tage (vom Server bestätigt) verschwinden, neuere und noch nicht bestätigte bleiben', () async {
        final id = await re.anlegen(_emil, _plan());
        await alle();
        ge.jetzt = DateTime.utc(2026, 10, 23, 12);
        final alt = await re.einnahmeErfassen(id, um: DateTime.utc(2026, 10, 23, 1));
        final neu = await re.einnahmeErfassen(id, um: DateTime.utc(2026, 10, 23, 2));
        await alle();
        final unbestaetigt = await re.einnahmeErfassen(id, um: DateTime.utc(2026, 10, 23, 3)); // noch nicht beim Server (Revision 0)
        // das createdAt setzt der Server; hier wie nach vielen Wochen: 140, 60 und 140 Tage alt
        Future<void> setze(String eid, DateTime t) => (ge.db.update(ge.db.einnahmen)..where((e) => e.id.equals(eid))).write(EinnahmenCompanion(createdAt: Value(t)));
        await setze(alt, DateTime.utc(2026, 6, 5));
        await setze(neu, DateTime.utc(2026, 8, 24));
        await setze(unbestaetigt, DateTime.utc(2026, 6, 5));
        expect(await re.aelteEinnahmenEntfernen(), 1);
        expect((await ge.db.select(ge.db.einnahmen).get()).map((e) => e.id).toSet(), {neu, unbestaetigt});
        expect(await re.aelteEinnahmenEntfernen(), 0);
      });
    });
  }
}

List<String> _welt(ChatWelt w) => w.aktiveMitglieder;
