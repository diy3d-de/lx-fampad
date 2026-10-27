// Vorsorge und Impfungen Ende-zu-Ende (Abschnitt 6p): echte lokale Datenbanken je Gerät, echter Store und Ausgang-Vorbereiter gegen den Fake-Server, der die Regeln des echten Servers nachbildet
// (Sicht nach Teilnehmern der Medikamenten-Konversation, feste ID des Profils, Hülle e1). Geprüft: Sichtregeln (Erwachsene sehen nie die eines anderen Erwachsenen, Eltern sehen die Kinder,
// Kinder nur die eigenen), der Server sieht nie Klartext, Profil mit fester ID, Erledigt eintragen und zurücknehmen, Löschen, Fehlerfälle.
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/medikamente/medikament_repository.dart' show MedikamentRepository;
import 'package:lx_fampad/data/vorsorge/vorsorge_modelle.dart';
import 'package:lx_fampad/data/vorsorge/vorsorge_repository.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';

const _mama = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _papa = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _emil = 'cccccccc-0000-4000-8000-00000000000c';
const _anna = 'dddddddd-0000-4000-8000-00000000000d';

UserDto _u(String id, Role r) => UserDto(id: id, email: null, displayName: id, colorIndex: 0, role: r, status: MemberStatus.active);

const _profil = VorsorgeProfilInhalt(geburt: '2015-03-12', geschlecht: VorsorgeGeschlecht.weiblich);
VorsorgeEintragInhalt _eintrag({String name = 'Geheim-Augenarzt', String notiz = 'Geheimnotiz'}) => VorsorgeEintragInhalt(name: name, art: VorsorgeArt.sonstiges, notiz: notiz, intervallMonate: 12);

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tzdata.initializeTimeZones();

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Vorsorge Ende-zu-Ende ($name)', () {
      late ChatWelt welt;
      late TestPerson mama, papa, emil, anna;
      late Geraet gm, gp, ge, ga;
      late List<UserDto> mitglieder;
      final geraete = <Geraet>[];
      late VorsorgeRepository rm, rp, re, ra;

      VorsorgeRepository rep(Geraet g) {
        final med = MedikamentRepository(db: g.db, store: g.store, krypto: () async => g.bereit ? g.krypto : null, ich: () => g.person.id, mitglieder: () async => mitglieder, beiAenderung: () {}, jetzt: () => g.jetzt);
        return VorsorgeRepository(
          db: g.db,
          store: g.store,
          krypto: () async => g.bereit ? g.krypto : null,
          ich: () => g.person.id,
          mitglieder: () async => mitglieder,
          konversationSicherstellen: med.konversationSicherstellen,
          beiAenderung: () {},
          jetzt: () => g.jetzt,
        );
      }

      setUp(() async {
        for (final g in geraete) {
          await g.schliessen();
        }
        welt = ChatWelt(crypto);
        mama = TestPerson(_mama, 'Mama', crypto);
        papa = TestPerson(_papa, 'Papa', crypto);
        emil = TestPerson(_emil, 'Emil', crypto);
        anna = TestPerson(_anna, 'Anna', crypto);
        final rollen = {_mama: Role.parent, _papa: Role.admin, _emil: Role.child, _anna: Role.child};
        welt.aktiveMitglieder = rollen.keys.toList();
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
        for (final g in geraete) {
          g.mitgliederLernen([mama, papa, emil, anna]);
        }
        rm = rep(gm);
        rp = rep(gp);
        re = rep(ge);
        ra = rep(ga);
      });
      tearDown(() async {
        for (final g in geraete) {
          await g.schliessen();
        }
      });

      Future<void> alle({int runden = 3}) async {
        for (var i = 0; i < runden; i++) {
          for (final g in [ge, gm, gp, ga]) {
            await welt.abgleichen(g);
          }
        }
      }

      Future<List<VorsorgeAnsicht>> lesen(VorsorgeRepository r, String subjekt) async => r.lesen(subjekt, await r.zeilen(subjekt).first);

      String serverGesehen() => jsonEncode(welt.gesehen) + jsonEncode([for (final e in ['konversation', 'vorsorge_profil', 'vorsorge_eintrag']) for (final z in welt.alle(e)) z.fields]);

      test('Kind legt Profil und Eintrag an, Eltern lesen sie; der Server sieht nur e1-Hüllen, die feste Profil-ID und nie Name, Datum oder Notiz', () async {
        await re.profilSetzen(_emil, _profil);
        final id = await re.anlegen(_emil, _eintrag());
        await alle();
        for (final r in [rm, rp, re]) {
          final l = await lesen(r, _emil);
          expect(l, hasLength(1));
          expect(l.single.id, id);
          expect(l.single.inhalt!.name, 'Geheim-Augenarzt');
          expect(l.single.inhalt!.notiz, 'Geheimnotiz');
          expect(l.single.lokalNeu, isFalse);
          expect(await r.profilLesen(_emil), _profil);
        }
        // eine Konversation (dieselbe wie bei den Medikamenten), Profil mit fester ID
        final k = welt.alle('konversation').single;
        expect(k.id, medsChatId(_emil));
        expect(k.fields['art'], 'meds');
        final p = welt.alle('vorsorge_profil').single;
        expect(p.id, vorsorgeProfilId(medsChatId(_emil)));
        expect(p.fields['inhalt'], startsWith('e1:'));
        expect(p.fields['bearbeiterId'], _emil);
        final z = welt.alle('vorsorge_eintrag').single;
        expect(z.fields['inhalt'], startsWith('e1:'));
        final gesehen = serverGesehen();
        for (final w in ['Geheim', 'Augenarzt', '2015', 'weiblich', 'vp1:', 've1:', 'l1:', 'geburt', 'intervall', 'erledigt', 'notiz']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
        // Schwester und anderer Erwachsener ohne Teilnahme bekommen nichts
        expect(welt.sichtbarFuer(_anna, 'vorsorge_eintrag'), isEmpty);
        expect(welt.sichtbarFuer(_anna, 'vorsorge_profil'), isEmpty);
        expect(await lesen(ra, _emil), isEmpty);
      });

      test('Sicht: Erwachsene sehen nie die Daten eines anderen Erwachsenen (auch Admins nicht), Kinder nur die eigenen; fremde Personen werden nicht angelegt', () async {
        await rm.anlegen(_mama, _eintrag(name: 'Mama-Eintrag'));
        await rp.anlegen(_papa, _eintrag(name: 'Papa-Eintrag'));
        await re.anlegen(_emil, _eintrag(name: 'Emil-Eintrag'));
        await ra.anlegen(_anna, _eintrag(name: 'Anna-Eintrag'));
        await alle();
        expect([for (final m in await lesen(rm, _mama)) m.inhalt!.name], ['Mama-Eintrag']);
        expect(welt.sichtbarFuer(_mama, 'vorsorge_eintrag').length, 3, reason: 'eigener plus Emil und Anna');
        expect(welt.sichtbarFuer(_papa, 'vorsorge_eintrag').length, 3);
        expect(welt.sichtbarFuer(_emil, 'vorsorge_eintrag').length, 1);
        expect(welt.sichtbarFuer(_anna, 'vorsorge_eintrag').length, 1);
        expect(await lesen(rm, _papa), isEmpty);
        expect(await lesen(rp, _mama), isEmpty);
        expect(await lesen(re, _anna), isEmpty);
        expect(await lesen(ra, _emil), isEmpty);
        await expectLater(rm.anlegen(_papa, _eintrag()), throwsA(isA<VorsorgeNichtErlaubt>()));
        await expectLater(rp.anlegen(_mama, _eintrag()), throwsA(isA<VorsorgeNichtErlaubt>()));
        await expectLater(re.anlegen(_anna, _eintrag()), throwsA(isA<VorsorgeNichtErlaubt>()));
        await expectLater(ra.profilSetzen(_mama, _profil), throwsA(isA<VorsorgeNichtErlaubt>()));
        // Eltern dürfen für ihre Kinder anlegen
        await rm.anlegen(_anna, _eintrag(name: 'Anna-Zweiter'));
        await alle();
        expect([for (final m in await lesen(ra, _anna)) m.inhalt!.name]..sort(), ['Anna-Eintrag', 'Anna-Zweiter']);
      });

      test('Profil: je Person eines (feste ID), eine zweite Eingabe ändert es, ein Datum in der Zukunft wird abgelehnt', () async {
        await rm.profilSetzen(_emil, _profil);
        await rm.profilSetzen(_emil, const VorsorgeProfilInhalt(geburt: '2014-01-02'));
        await alle();
        expect(welt.alle('vorsorge_profil'), hasLength(1));
        expect((await re.profilLesen(_emil))!.geburt, '2014-01-02');
        await expectLater(rm.profilSetzen(_emil, const VorsorgeProfilInhalt(geburt: '2099-01-01')), throwsA(isA<VorsorgeUngueltig>()));
        await expectLater(rm.profilSetzen(_emil, const VorsorgeProfilInhalt(geburt: 'gestern')), throwsArgumentError);
      });

      test('Erledigt eintragen, zurücknehmen, ändern und löschen; Zukunft und ungültige Inhalte werden nie geschrieben', () async {
        final id = await rm.anlegen(_emil, VorsorgeEintragInhalt(vorlage: 'mmr', art: VorsorgeArt.impfung, naechstes: '2026-10-25'));
        await alle();
        gm.jetzt = DateTime.utc(2026, 10, 27, 10);
        await rm.erledigtEintragen(id, tag: DateTime.utc(2026, 10, 26), notiz: 'Praxis Meier');
        await rm.erledigtEintragen(id, tag: DateTime.utc(2026, 10, 26)); // doppelt: nichts ändert sich
        await rm.erledigtEintragen(id, tag: DateTime.utc(2026, 4, 1));
        await alle();
        var e = (await lesen(re, _emil)).single.inhalt!;
        expect(e.erledigt, ['2026-04-01', '2026-10-26']);
        expect(e.naechstes, isNull, reason: 'das erreichte Handdatum entfällt');
        expect(e.notiz, 'Praxis Meier');
        await expectLater(rm.erledigtEintragen(id, tag: DateTime.utc(2026, 12, 1)), throwsA(isA<VorsorgeUngueltig>()));
        await expectLater(rm.aendern(id, const VorsorgeEintragInhalt(art: VorsorgeArt.sonstiges)), throwsArgumentError);
        await rm.erledigtZuruecknehmen(id, '2026-04-01');
        await alle();
        e = (await lesen(rp, _emil)).single.inhalt!;
        expect(e.erledigt, ['2026-10-26']);
        ge.jetzt = gm.jetzt;
        // Kind ändert den Vorlauf (der Bearbeiter ist, wer zuletzt schrieb)
        await re.aendern(id, e.kopie(vorlauf: 30));
        await alle();
        expect((await lesen(rm, _emil)).single.inhalt!.vorlauf, 30);
        expect(welt.alle('vorsorge_eintrag').single.fields['bearbeiterId'], _emil);
        await rm.loeschen(id);
        await alle();
        expect(await lesen(re, _emil), isEmpty);
        expect(welt.alle('vorsorge_eintrag'), isEmpty);
        // eine fremde Person kann nichts ändern oder löschen
        final id2 = await rm.anlegen(_mama, _eintrag());
        await alle();
        await expectLater(rp.loeschen(id2), throwsA(isA<VorsorgeFehler>()));
      });
    });
  }
}
