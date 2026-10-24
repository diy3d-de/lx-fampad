// Tresor Ende-zu-Ende (Abschnitt 6m), Datenschicht: echte lokale Datenbanken je Gerät, echter Store und Ausgang-Vorbereiter gegen den Fake-Server, der die Regeln des echten Servers
// nachbildet (Sicht nach Teilnehmern, nur Erwachsene, feste ID der Konversation, Hülle e1). Geprüft: ein gemeinsamer Tresor für alle Eltern, Kinder bekommen nie Daten und können nichts
// anlegen, der Server sieht nie Klartext, Klartext (l1:) verlässt das Gerät nie, zwei Geräte gleichen ab, Teilnehmerpflege bei Rollenwechsel, Verlauf für neue Eltern, Grenzen.
import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/sync/sync_store.dart' show SyncAenderung;
import 'package:lx_fampad/data/tresor/tresor_logik.dart' show TresorProblem;
import 'package:lx_fampad/data/tresor/tresor_modelle.dart';
import 'package:lx_fampad/data/tresor/tresor_repository.dart';
import 'package:lx_fampad/data/tresor/tresor_teilnehmer.dart';

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';

const _mama = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _papa = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _emil = 'cccccccc-0000-4000-8000-00000000000c';
const _anna = 'dddddddd-0000-4000-8000-00000000000d';

UserDto _u(String id, Role r) => UserDto(id: id, email: null, displayName: id, colorIndex: 0, role: r, status: MemberStatus.active);

TresorInhalt _wlan({String titel = 'WLAN Keller-Geheim', String passwort = 'Sonne-Mond-4711!'}) => TresorInhalt(
  kategorie: TresorKategorie.haushalt,
  titel: titel,
  felder: [
    const TresorFeld(bezeichnung: 'Netzname', wert: 'FamilieNetz-Geheim'),
    TresorFeld(bezeichnung: 'Passwort', wert: passwort, geheim: true),
    const TresorFeld(bezeichnung: 'Router-Adresse', wert: '192.168.178.1'),
  ],
  notiz: 'Gästenetz: gast / Notiz-Geheim',
  vorlage: TresorVorlage.wlan,
);

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Tresor Ende-zu-Ende ($name)', () {
      late ChatWelt welt;
      late TestPerson mama, papa, emil, anna;
      late Geraet gm, gp, ge, ga;
      late List<UserDto> mitglieder;
      final geraete = <Geraet>[];
      late TresorRepository rm, rp, re, ra;

      TresorRepository rep(Geraet g) => TresorRepository(
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

      Future<List<TresorAnsicht>> lesen(TresorRepository r) async => r.lesen(await r.zeilen().first);

      String serverGesehen() => jsonEncode(welt.gesehen) + jsonEncode([for (final e in ['konversation', 'tresor_eintrag']) for (final z in welt.alle(e)) z.fields]);

      test('Eltern legen einen Eintrag an, beide lesen ihn; der Server sieht nur e1-Hüllen, nie Kategorie, Titel, Feld, Wert oder Notiz', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        for (final r in [rm, rp]) {
          final l = await lesen(r);
          expect(l, hasLength(1));
          expect(l.single.id, id);
          expect(l.single.inhalt!.titel, 'WLAN Keller-Geheim');
          expect(l.single.inhalt!.kategorie, TresorKategorie.haushalt);
          expect(l.single.inhalt!.felder.map((f) => f.bezeichnung), ['Netzname', 'Passwort', 'Router-Adresse']);
          expect(l.single.inhalt!.felder[1].wert, 'Sonne-Mond-4711!');
          expect(l.single.inhalt!.felder[1].geheim, isTrue);
          expect(l.single.inhalt!.notiz, contains('Notiz-Geheim'));
          expect(l.single.inhalt!.geaendert, gm.jetzt.toUtc().millisecondsSinceEpoch);
          expect(l.single.lokalNeu, isFalse);
        }
        // Server: feste ID der Konversation, Art, nur die beiden Erwachsenen, e1-Hülle, Bearbeiter
        final k = welt.alle('konversation').single;
        expect(k.id, tresorChatId(familieId));
        expect(k.fields['art'], 'tresor');
        expect(k.fields['subjektId'], isNull);
        expect((k.fields['teilnehmer'] as List).cast<String>().toSet(), {_mama, _papa});
        expect(welt.alle('tresor_eintrag').single.fields['inhalt'], startsWith('e1:'));
        expect(welt.alle('tresor_eintrag').single.fields['bearbeiterId'], _mama);
        final gesehen = serverGesehen();
        for (final w in ['WLAN', 'Keller-Geheim', 'FamilieNetz', 'Sonne-Mond', 'Router', '192.168', 'Notiz-Geheim', 'Passwort', 'haushalt', 'Haushalt', 'geheim', 't1:', 'l1:']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
      });

      test('Klartext (l1:) verlässt das Gerät nie: vor dem Abgleich liegt er nur lokal, danach steht in Tabelle und Antwort die e1-Hülle', () async {
        final id = await rm.anlegen(_wlan());
        final roh = await (gm.db.select(gm.db.tresorEintraege)..where((t) => t.id.equals(id))).getSingle();
        expect(roh.inhalt, startsWith('l1:t1:'));
        expect(roh.rev, 0);
        // lokal ist er für die eigene Person lesbar (Eintrag im Ausgang), für andere nie
        expect((await lesen(rm)).single.inhalt!.titel, 'WLAN Keller-Geheim');
        expect((await lesen(rm)).single.lokalNeu, isTrue);
        await alle();
        expect(serverGesehen(), isNot(contains('l1:')));
        final nach = await (gm.db.select(gm.db.tresorEintraege)..where((t) => t.id.equals(id))).getSingle();
        expect(nach.inhalt, startsWith('e1:'));
        // der Ausgang ist leer: nichts bleibt zurück
        expect(await gm.db.select(gm.db.outbox).get(), isEmpty);
        // ein fremdes l1: (nicht vom eigenen Gerät) gilt nie als lesbar
        final fremd = roh.copyWith(id: 'fremd', bearbeiterId: const Value(_papa));
        expect((await rm.lesen([fremd])).single.inhalt, isNull);
      });

      test('Ändern durch das andere Elternteil: der gemeinsame Tresor, der Bearbeiter wechselt; Feld verschieben, Löschen überall', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        final alt = (await lesen(rp)).single.inhalt!;
        gp.jetzt = gm.jetzt.add(const Duration(days: 1));
        await rp.aendern(id, alt.kopie(titel: 'WLAN Haus', notiz: 'neu'));
        await alle();
        var z = (await lesen(rm)).single.inhalt!;
        expect([z.titel, z.notiz], ['WLAN Haus', 'neu']);
        expect(z.geaendert, gp.jetzt.toUtc().millisecondsSinceEpoch);
        expect(welt.alle('tresor_eintrag').single.fields['bearbeiterId'], _papa);
        // Felder umordnen
        await rm.feldVerschieben(id, 2, 0);
        await alle();
        expect((await lesen(rp)).single.inhalt!.felder.map((f) => f.bezeichnung), ['Router-Adresse', 'Netzname', 'Passwort']);
        // Löschen durch Papa: überall weg
        await rp.loeschen(id);
        await alle();
        expect(await lesen(rm), isEmpty);
        expect(welt.alle('tresor_eintrag'), isEmpty);
      });

      test('Kinder: bekommen nie Daten, können nichts anlegen und stehen nie in der Teilnehmerliste', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        for (final p in [_emil, _anna]) {
          expect(welt.sichtbarFuer(p, 'konversation'), isEmpty);
          expect(welt.sichtbarFuer(p, 'tresor_eintrag'), isEmpty);
        }
        // lokal: nichts, auch nicht als hidden-Spur mit Inhalt
        expect(await lesen(re), isEmpty);
        expect(await lesen(ra), isEmpty);
        expect(await ge.db.select(ge.db.tresorEintraege).get(), isEmpty);
        expect(await ge.db.select(ge.db.konversationen).get(), isEmpty);
        // die Repositories verweigern jede Handlung
        for (final r in [re, ra]) {
          await expectLater(r.anlegen(_wlan()), throwsA(isA<TresorNichtErlaubt>()));
          await expectLater(r.konversationSicherstellen(), throwsA(isA<TresorNichtErlaubt>()));
          await expectLater(r.aendern(id, _wlan()), throwsA(isA<TresorNichtErlaubt>()));
          await expectLater(r.feldVerschieben(id, 0, 1), throwsA(isA<TresorNichtErlaubt>()));
          await expectLater(r.loeschen(id), throwsA(isA<TresorNichtErlaubt>()));
          expect(await r.teilnehmerPflegen(), isFalse);
          expect(await r.verlaufFreigeben({_mama}), isFalse);
        }
      });

      test('Auch bei Umgehung der App lehnt der Server ein Kind ab: es kann weder die Konversation anlegen noch sich hineinschreiben oder Einträge anlegen', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        final konv = tresorChatId(familieId);
        await ge.store.aendernMehrere([
          SyncAenderung('konversation', konv, {'art': 'tresor', 'encVersion': 'e1', 'teilnehmer': [_emil]}),
        ]);
        await alle();
        expect(welt.abgelehnt['konversation'], 1);
        expect((welt.zeile('konversation', konv)!.fields['teilnehmer'] as List).cast<String>().toSet(), {_mama, _papa});
        await ge.store.aendern('konversation', konv, {'teilnehmer': [_emil, _mama, _papa]});
        await ge.store.aendern('tresor_eintrag', 'dddddddd-0000-4000-8000-00000000dddd', {'konversationId': konv, 'inhalt': 'e1:${'A' * 160}'});
        await alle();
        expect((welt.zeile('konversation', konv)!.fields['teilnehmer'] as List).cast<String>().toSet(), {_mama, _papa});
        expect(welt.alle('tresor_eintrag').map((z) => z.id), [id]);
        expect(welt.sichtbarFuer(_emil, 'tresor_eintrag'), isEmpty);
      });

      test('Notfall-Info eines Kindes ist ein normaler Eintrag (Kategorie Notfall, Feld Person); das Kind selbst sieht ihn nie', () async {
        final id = await rm.anlegen(const TresorInhalt(
          kategorie: TresorKategorie.notfall,
          titel: 'Allergien Emil',
          felder: [TresorFeld(bezeichnung: 'Person', wert: 'Emil'), TresorFeld(bezeichnung: 'Allergien', wert: 'Nüsse-Geheim')],
        ));
        await alle();
        expect((await lesen(rp)).single.inhalt!.felder.first.wert, 'Emil');
        expect(await lesen(re), isEmpty);
        expect(serverGesehen(), isNot(contains('Nüsse-Geheim')));
        expect(id, isNotEmpty);
      });

      test('Der Tresor ist kein Chat: nichts in der Chatliste, keine Nachrichten', () async {
        await rm.anlegen(_wlan());
        await alle();
        expect(welt.alle('nachricht'), isEmpty);
        final konv = (await gm.db.select(gm.db.konversationen).get()).single;
        expect(konv.art, 'tresor');
      });

      test('Ungültige Eingaben werden nie geschrieben: Titel fehlt, zu viele Felder, zu groß; nichts im Ausgang', () async {
        await expectLater(rm.anlegen(const TresorInhalt(kategorie: TresorKategorie.zugang, titel: '')), throwsA(isA<TresorEingabeFehler>().having((e) => e.probleme, 'probleme', [TresorProblem.titelFehlt])));
        await expectLater(rm.anlegen(TresorInhalt(kategorie: TresorKategorie.zugang, titel: 'x', felder: [for (var i = 0; i < 21; i++) TresorFeld(bezeichnung: 'F$i')])), throwsA(isA<TresorEingabeFehler>()));
        await expectLater(
          rm.anlegen(TresorInhalt(kategorie: TresorKategorie.zugang, titel: 'x', notiz: '€' * 4000, felder: [for (var i = 0; i < 6; i++) TresorFeld(bezeichnung: 'F$i', wert: '€' * 1000)])),
          throwsA(isA<TresorEingabeFehler>().having((e) => e.meldung, 'meldung', contains('zu groß'))),
        );
        expect(await gm.db.select(gm.db.outbox).get(), isEmpty);
        expect(await gm.db.select(gm.db.tresorEintraege).get(), isEmpty);
        expect(await gm.db.select(gm.db.konversationen).get(), isEmpty);
      });

      test('Ein 16-KB-Eintrag (Obergrenze) wird verschlüsselt, gesendet und von der anderen Person gelesen', () async {
        // so groß wie erlaubt: knapp unter 16000 Byte Klartext
        var inhalt = TresorInhalt(kategorie: TresorKategorie.dokumente, titel: 'Groß', notiz: 'n' * kMaxTresorNotiz, felder: [for (var i = 0; i < 11; i++) TresorFeld(bezeichnung: 'F$i', wert: 'w' * kMaxTresorWert)]);
        inhalt = inhalt.kopie(felder: [...inhalt.felder, TresorFeld(bezeichnung: 'Rest', wert: '€' * 100)]);
        final id = await rm.anlegen(inhalt);
        await alle();
        expect(welt.alle('tresor_eintrag').single.fields['inhalt'], startsWith('e1:'));
        expect((welt.alle('tresor_eintrag').single.fields['inhalt'] as String).length, lessThanOrEqualTo(24576));
        final l = (await lesen(rp)).single;
        expect(l.id, id);
        expect(l.inhalt!.felder, hasLength(12));
        expect(l.inhalt!.notiz.length, kMaxTresorNotiz);
      });

      test('Mehr als 500 Einträge gibt es nicht (die App legt keinen weiteren an)', () async {
        final k = await rm.konversationSicherstellen();
        await gm.db.batch((b) {
          for (var i = 0; i < kMaxTresorEintraege; i++) {
            b.customStatement('INSERT INTO tresor_eintraege (id, konversation_id, inhalt, created_at, rev) VALUES (?, ?, ?, ?, ?)', ['e$i', k, 'e1:x', 1, 1]);
          }
        });
        await expectLater(rm.anlegen(_wlan()), throwsA(isA<TresorFehler>().having((e) => e.meldung, 'meldung', contains('zu viele'))));
      });

      test('Unlesbarer Eintrag (kein Schlüssel) wird nicht blind überschrieben', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        // Papa hat den Schlüssel: liest. Ein Gerät ohne Schlüsselbereitschaft liest nichts und ändert nichts
        gp.bereit = false;
        final l = await lesen(rp);
        expect(l.single.inhalt, isNull);
        expect(l.single.hinweis, isNotNull);
        await expectLater(rp.aendern(id, _wlan(titel: 'Neu')), throwsA(isA<TresorNichtLesbar>()));
        gp.bereit = true;
        expect((await lesen(rp)).single.inhalt!.titel, 'WLAN Keller-Geheim');
      });

      test('Neues Elternteil (Papa wird Admin): Aufnahme durch die Pflege; ohne Verlauf liest er Altes nicht, mit Verlauf-Schalter und über verlaufFreigeben schon; Kind bekommt nie etwas', () async {
        await aufbau();
        welt.aktiveMitglieder = [_mama, _emil, _anna];
        welt.rollen.remove(_papa);
        mitglieder = [for (final m in mitglieder) if (m.id != _papa) m];
        lernen();
        final id = await rm.anlegen(_wlan());
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], [_mama]);
        welt.aktiveMitglieder = [...welt.aktiveMitglieder, _papa];
        welt.rollen[_papa] = Role.admin;
        mitglieder = [...mitglieder, _u(_papa, Role.admin)];
        lernen();
        expect(await rm.teilnehmerPflegen(), isTrue);
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa]));
        await pflegen(gm);
        await alle();
        final davor = await lesen(rp);
        expect(davor.single.inhalt, isNull);
        expect(davor.single.hinweis, isNotNull);
        final neu = await rm.anlegen(_wlan(titel: 'Neuer Eintrag'));
        await alle();
        expect((await lesen(rp)).firstWhere((a) => a.id == neu).inhalt!.titel, 'Neuer Eintrag');
        expect(await rm.verlaufFreigeben({_papa}), isTrue);
        await alle();
        expect((await lesen(rp)).firstWhere((a) => a.id == id).inhalt!.titel, 'WLAN Keller-Geheim');
        expect(await rm.verlaufFreigeben({_emil}), isFalse);
        expect(await rm.verlaufFreigeben({}), isFalse);
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa]));
        expect(await rm.teilnehmerPflegen(), isFalse);
        expect(await rp.teilnehmerPflegen(), isFalse);
      });

      test('Mit dem Verlauf-Schalter (wie die App-Steuerung) bekommt das neue Elternteil den Verlauf automatisch mit der Aufnahme', () async {
        await aufbau();
        welt.aktiveMitglieder = [_mama, _emil, _anna];
        welt.rollen.remove(_papa);
        mitglieder = [for (final m in mitglieder) if (m.id != _papa) m];
        lernen();
        final id = await rm.anlegen(_wlan());
        await alle();
        welt.aktiveMitglieder = [...welt.aktiveMitglieder, _papa];
        welt.rollen[_papa] = Role.admin;
        mitglieder = [...mitglieder, _u(_papa, Role.admin)];
        lernen();
        expect(await rm.teilnehmerPflegen(verlaufTeilen: true), isTrue);
        await alle();
        expect((await lesen(rp)).firstWhere((a) => a.id == id).inhalt!.titel, 'WLAN Keller-Geheim');
      });

      test('Eltern ohne eingerichtete Verschlüsselung kommen erst mit Schlüssel dazu; niemand wird deswegen entfernt', () async {
        await rm.anlegen(_wlan());
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

      test('Kind wird Elternteil: der Server nimmt es nicht von selbst auf; die Pflege tut es, ohne Verlauf; Anna (weiter Kind) sieht nichts', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        welt.rollenwechsel(_emil, Role.parent);
        mitglieder = [for (final m in mitglieder) m.id == _emil ? _u(_emil, Role.parent) : m];
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa])); // nicht von selbst
        expect(darfTresorSehen(ich: _emil, mitglieder: mitglieder), isTrue);
        expect(await rm.teilnehmerPflegen(), isTrue);
        await alle();
        expect(welt.alle('konversation').single.fields['teilnehmer'], unorderedEquals([_mama, _papa, _emil]));
        expect((await lesen(re)).single.inhalt, isNull); // ohne Verlauf bleibt der alte Inhalt verschlossen
        expect(await rm.verlaufFreigeben({_emil}), isTrue);
        await alle();
        expect((await lesen(re)).firstWhere((a) => a.id == id).inhalt!.titel, 'WLAN Keller-Geheim');
        expect(welt.sichtbarFuer(_anna, 'tresor_eintrag'), isEmpty);
      });

      test('Elternteil wird Kind: der Server wirft es sofort aus der Liste (hidden), es rotiert den Schlüssel; es liest Neues nicht mehr und sieht nichts mehr', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        expect((await lesen(rp)).single.inhalt!.titel, 'WLAN Keller-Geheim');
        welt.rollenwechsel(_papa, Role.child);
        mitglieder = [for (final m in mitglieder) m.id == _papa ? _u(_papa, Role.child) : m];
        expect(welt.alle('konversation').single.fields['teilnehmer'], [_mama]);
        await alle();
        await pflegen(gm); // die Schlüsselpflege der Verbleibenden legt eine Epoche ohne Papa an
        await alle();
        expect(welt.sichtbarFuer(_papa, 'konversation'), isEmpty);
        expect(await lesen(rp), isEmpty);
        expect(await gp.db.select(gp.db.konversationen).get(), isEmpty);
        expect(await gp.db.select(gp.db.tresorEintraege).get(), isEmpty);
        // Neues liest er nicht mehr, selbst wenn er die Hülle bekäme
        final neu = await rm.anlegen(_wlan(titel: 'Neuer Eintrag'));
        await alle();
        final z = welt.zeile('tresor_eintrag', neu)!;
        final r = await gp.krypto.nachrichtOeffnen(konversationId: tresorChatId(familieId), nachrichtId: neu, autorId: _mama, wire: z.fields['inhalt'] as String, art: kArtTresor);
        expect(r.lesbar, isFalse);
        await expectLater(rp.anlegen(_wlan()), throwsA(isA<TresorNichtErlaubt>()));
        expect(await rp.teilnehmerPflegen(), isFalse);
        expect(id, isNotEmpty);
        expect(await rm.teilnehmerPflegen(), isFalse); // und die Mama darf ihn nicht wieder aufnehmen (er ist ein Kind)
      });

      test('Zwei Geräte ändern denselben Eintrag: der Server entscheidet (letzter gewinnt), beide landen beim selben Stand', () async {
        final id = await rm.anlegen(_wlan());
        await alle();
        final i = (await lesen(rm)).single.inhalt!;
        await rm.aendern(id, i.kopie(titel: 'Von Mama'));
        await rp.aendern(id, i.kopie(titel: 'Von Papa'));
        await alle(runden: 4);
        final a = (await lesen(rm)).single.inhalt!.titel;
        final b = (await lesen(rp)).single.inhalt!.titel;
        expect(a, b);
        expect(['Von Mama', 'Von Papa'], contains(a));
      });
    });
  }
}
