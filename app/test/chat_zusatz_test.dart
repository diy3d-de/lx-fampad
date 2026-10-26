// Chat-Erweiterungen: Reaktionen, Umfragen (Stimmen) und Pins. Teil 1: Klartext-Formate und Auswertung (rein). Teil 2: Ende-zu-Ende mit echten lokalen Datenbanken je Gerät,
// echtem Store und Ausgang-Vorbereiter gegen den Fake-Server: der Server sieht nur e1-Hüllen, nie ein Emoji oder eine Stimme.
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/chat/chat_zusatz_inhalt.dart';
import 'package:lx_fampad/data/chat/chat_zusatz_repository.dart';
import 'package:lx_fampad/data/api/models.dart' show Role;
import 'package:lx_fampad/data/chat/chat_repository.dart' show ChatArt;
import 'package:lx_fampad/data/sync/sync_entities.dart';
import 'package:lx_fampad/data/sync/sync_store.dart';
import 'package:lx_fampad/features/chat/chat_anzeige.dart';

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';

const _anna = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _ben = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _cora = 'cccccccc-0000-4000-8000-00000000000c';

Reaktion _r(String id, String nachricht, String user, String klar, {DateTime? zeit}) =>
    Reaktion(id: id, konversationId: 'k', nachrichtId: nachricht, userId: user, inhalt: klar, createdAt: zeit ?? DateTime.utc(2026, 10, 20), rev: 1);

Stimme _s(String id, String user, String klar, {DateTime? erstellt, DateTime? geaendert}) =>
    Stimme(id: id, konversationId: 'k', nachrichtId: 'n', userId: user, inhalt: klar, createdAt: erstellt ?? DateTime.utc(2026, 10, 20, 10), geaendertAt: geaendert, rev: 1);

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Feste IDs (Known-Answer wie auf dem Server)', () {
    const n = '11111111-1111-4111-8111-111111111111';
    const u = '22222222-2222-4222-8222-222222222222';
    test('Reaktion, Stimme und Pin', () {
      expect(reaktionId(n, u), '1f6d9a38-b4c2-5edf-9a56-3634e15796d7');
      expect(stimmeId(n, u), 'a1a4a139-9cf0-5c6c-bb21-e656b8a3aae7');
      expect(pinId(n), '386a4ae1-93c5-5827-9be5-6f547d343bc6');
      expect(reaktionId(n.toUpperCase(), u.toUpperCase()), reaktionId(n, u));
    });
  });

  group('Reaktionen: Format und Gruppierung', () {
    test('gültige Emojis, alles andere wird verworfen', () {
      for (final e in kReaktionEmojis) {
        expect(reaktionLesen(reaktionKodieren(e)), e);
      }
      expect(reaktionLesen('r1:👨‍👩‍👧'), '👨‍👩‍👧');
      for (final schlecht in ['', 'r1:', 'r1: ', 'r1:👍 👍', 'r1:\n', 'r1:${'x' * 17}', 'x1:👍', '👍', 'r1:👍 ']) {
        expect(reaktionLesen(schlecht), isNull, reason: schlecht);
      }
    });

    test('gruppiert je Nachricht nach Emoji, meistgewählt zuerst, eigene Reaktion markiert, Unlesbares fehlt', () {
      final zeilen = [
        _r('1', 'n1', _anna, 'r1:👍', zeit: DateTime.utc(2026, 10, 20, 9)),
        _r('2', 'n1', _ben, 'r1:❤️', zeit: DateTime.utc(2026, 10, 20, 9, 1)),
        _r('3', 'n1', _cora, 'r1:❤️', zeit: DateTime.utc(2026, 10, 20, 9, 2)),
        _r('4', 'n2', _anna, 'r1:😂'),
        _r('5', 'n2', _ben, 'kaputt'),
        _r('6', 'n2', _cora, 'UNLESBAR'),
      ];
      final g = gruppiereReaktionen(zeilen, (r) => r.inhalt == 'UNLESBAR' ? null : r.inhalt, _ben);
      expect([for (final x in g['n1']!) (x.emoji, x.anzahl, x.ich)], [('❤️', 2, true), ('👍', 1, false)]);
      expect(g['n1']![0].personen, [_ben, _cora]);
      expect([for (final x in g['n2']!) x.emoji], ['😂']);
    });
  });

  group('Umfrage: Format', () {
    test('Roundtrip mit Mehrfachauswahl und Ende; die Nachricht ist für ältere Apps lesbarer Text', () {
      final ende = DateTime.fromMillisecondsSinceEpoch(1893456000000);
      final text = umfrageKodieren(frage: 'Was essen wir?', optionen: ['Pizza', ' Pasta ', '', 'Salat'], mehrfach: true, ende: ende);
      expect(text, startsWith('📊 Umfrage: Was essen wir?\n• Pizza\n• Pasta\n• Salat\nZum Abstimmen bitte die App aktualisieren.\n'));
      final u = umfrageLesen(text)!;
      expect(u.frage, 'Was essen wir?');
      expect(u.optionen, ['Pizza', 'Pasta', 'Salat']);
      expect(u.mehrfach, isTrue);
      expect(u.ende, ende);
      expect(u.beendet(ende.subtract(const Duration(seconds: 1))), isFalse);
      expect(u.beendet(ende), isTrue);
      final ohne = umfrageLesen(umfrageKodieren(frage: 'Wann Treffen?', optionen: ['Sa', 'So'], mehrfach: false))!;
      expect(ohne.ende, isNull);
      expect(ohne.mehrfach, isFalse);
    });

    test('normaler Text und kaputte Umfragen sind keine Umfrage', () {
      expect(umfrageLesen('Hallo'), isNull);
      expect(umfrageLesen('📊 Umfrage: Frage'), isNull);
      expect(umfrageLesen('📊 Umfrage: F\n• A\nZum Abstimmen bitte die App aktualisieren.\n⁣u1;m=0'), isNull); // nur eine Antwort
      expect(umfrageLesen('📊 Umfrage: F\n• A\n• B\nanderer Hinweis\n⁣u1;m=0'), isNull);
      expect(umfrageLesen('📊 Umfrage: F\n• A\nB\nZum Abstimmen bitte die App aktualisieren.\n⁣u1;m=0'), isNull);
      expect(umfrageLesen('📊 Umfrage: F\n• A\n• B\nZum Abstimmen bitte die App aktualisieren.\nu1;m=0'), isNull); // Marke ohne U+2063
      final sieben = ['📊 Umfrage: F', for (var i = 0; i < 7; i++) '• $i', 'Zum Abstimmen bitte die App aktualisieren.', '⁣u1;m=0'].join('\n');
      expect(umfrageLesen(sieben), isNull);
    });

    test('Eingabe wird geprüft und auf eine Zeile gebracht', () {
      expect(umfrageFehler('', ['a', 'b']), isNotNull);
      expect(umfrageFehler('F', ['a']), isNotNull);
      expect(umfrageFehler('F', ['a', 'A']), isNotNull);
      expect(umfrageFehler('F', ['a', 'b', 'c', 'd', 'e', 'f', 'g']), isNotNull);
      expect(umfrageFehler('F', ['a', 'x' * 61]), isNotNull);
      expect(umfrageFehler('x' * 201, ['a', 'b']), isNotNull);
      expect(umfrageFehler('F', ['a', 'b', '', '']), isNull);
      final t = umfrageKodieren(frage: 'Zwei\nZeilen⁣!', optionen: ['a\nb', 'c'], mehrfach: false);
      final u = umfrageLesen(t)!;
      expect(u.frage, 'Zwei Zeilen !');
      expect(u.optionen, ['a b', 'c']);
    });

    test('Kurztext in Listen', () {
      final u = umfrageLesen(umfrageKodieren(frage: 'Was essen wir?', optionen: ['A', 'B'], mehrfach: false))!;
      expect(umfrageKurztext(u), '📊 Was essen wir?');
    });
  });

  group('Stimmen: Format und Auswertung', () {
    test('Format: Nummern im Bereich, Einzelwahl genau eine', () {
      expect(stimmeKodieren([2, 0, 2]), 's1:0,2');
      expect(stimmeLesen('s1:0,2', 3, mehrfach: true), {0, 2});
      expect(stimmeLesen('s1:1', 3, mehrfach: false), {1});
      for (final (t, m) in [('s1:0,2', false), ('s1:3', true), ('s1:-1', true), ('s1:', true), ('s1:01', true), ('s1:a', true), ('s1:0,,1', true), ('x1:0', true), ('s1:0 ', true)]) {
        expect(stimmeLesen(t, 3, mehrfach: m), isNull, reason: t);
      }
    });

    test('Abgabezeitpunkt in der Stimme: lesbar, ohne Angabe weiterhin gültig, kaputte Zeit ungültig', () {
      final t = DateTime.fromMillisecondsSinceEpoch(1761000000000);
      expect(stimmeKodieren([1, 0], zeit: t), 's1:0,1@1761000000000');
      final g = stimmeLesenMitZeit('s1:0,1@1761000000000', 3, mehrfach: true)!;
      expect(g.auswahl, {0, 1});
      expect(g.zeit, t);
      expect(stimmeLesenMitZeit('s1:2', 3, mehrfach: false)!.zeit, isNull);
      for (final schlecht in ['s1:2@', 's1:2@abc', 's1:2@-5', 's1:@5', 's1:7@5']) {
        expect(stimmeLesenMitZeit(schlecht, 3, mehrfach: false), isNull, reason: schlecht);
      }
    });

    test('Ende: Löschen und erneutes Abstimmen nach dem Ende zählt nicht (Serverzeit ist das Spätere von Anlegen und Ändern), Behauptung einer früheren Zeit nur innerhalb der Toleranz', () {
      final ende = DateTime.utc(2026, 10, 20, 18);
      final u = Umfrage(frage: 'F', optionen: const ['A', 'B'], mehrfach: false, ende: ende);
      String? klarText(Stimme s) => s.inhalt;
      int zaehle(List<Stimme> l) => umfrageAuswerten(u, l, klarText, null).abstimmende;
      // vor dem Ende angelegt, geändert (alte Zeit), nach dem Ende gelöscht und neu angelegt: createdAt und geaendertAt sind neu
      expect(zaehle([_s('1', _anna, 's1:0', erstellt: DateTime.utc(2026, 10, 20, 18, 30), geaendert: DateTime.utc(2026, 10, 20, 17))]), 0);
      expect(zaehle([_s('1', _anna, 's1:0', erstellt: DateTime.utc(2026, 10, 20, 17, 59))]), 1);
      // offline vor dem Ende abgegeben, 5 Minuten nach dem Ende angekommen: zählt
      final t = DateTime.utc(2026, 10, 20, 17, 50).millisecondsSinceEpoch;
      expect(zaehle([_s('1', _anna, 's1:0@$t', erstellt: DateTime.utc(2026, 10, 20, 18, 5))]), 1);
      // nach der Toleranz angekommen: zählt nicht
      expect(zaehle([_s('1', _anna, 's1:0@$t', erstellt: DateTime.utc(2026, 10, 20, 18, 11))]), 0);
      // behauptete Zeit nach dem Ende: zählt nicht
      final spaet = DateTime.utc(2026, 10, 20, 18, 3).millisecondsSinceEpoch;
      expect(zaehle([_s('1', _anna, 's1:0@$spaet', erstellt: DateTime.utc(2026, 10, 20, 18, 5))]), 0);
      // behauptete Zeit in der Zukunft gegenüber dem Server: gilt nicht (hier nach dem Ende)
      final zukunft = DateTime.utc(2026, 10, 20, 17, 59).millisecondsSinceEpoch;
      expect(zaehle([_s('1', _anna, 's1:0@$zukunft', erstellt: DateTime.utc(2026, 10, 20, 17, 0))]), 1, reason: 'vor dem Ende angekommen: zählt ohnehin');
    });

    test('Chips: bei gleicher Anzahl bleibt die Reihenfolge der ersten Wahl', () {
      final zeilen = [
        for (var i = 0; i < 6; i++) _r('r$i', 'n', 'u$i', 'r1:${kReaktionEmojis[i]}', zeit: DateTime.utc(2026, 10, 20, 9, i)),
      ];
      final g = gruppiereReaktionen(zeilen, (r) => r.inhalt, null)['n']!;
      expect([for (final x in g) x.emoji], kReaktionEmojis);
    });

    test('Auswertung: gültige Stimmen je Antwort, eigene Auswahl, Ungültiges und Späteres zählen nicht', () {
      final ende = DateTime.utc(2026, 10, 20, 12);
      final u = Umfrage(frage: 'F', optionen: const ['A', 'B', 'C'], mehrfach: true, ende: ende);
      final stimmen = [
        _s('1', _anna, 's1:0,1'),
        _s('2', _ben, 's1:1', erstellt: DateTime.utc(2026, 10, 20, 10), geaendert: DateTime.utc(2026, 10, 20, 11)),
        _s('3', _cora, 's1:2', erstellt: DateTime.utc(2026, 10, 20, 10), geaendert: DateTime.utc(2026, 10, 20, 12, 0, 1)), // nach dem Ende geändert
        _s('4', 'dora', 's1:9'), // Option gibt es nicht
        _s('5', 'emil', 'KAPUTT'),
        _s('6', 'fritz', 'x'), // nicht lesbar (Inhalt null)
      ];
      final e = umfrageAuswerten(u, stimmen, (s) => s.userId == 'fritz' ? null : s.inhalt, _ben);
      expect(e.waehler, [
        [_anna],
        [_anna, _ben],
        <String>[],
      ]);
      expect(e.abstimmende, 2);
      expect(e.meine, {1});
      expect(e.stimmen(1), 2);
    });

    test('Einzelwahl: mehrere Optionen in einer Stimme sind ungültig', () {
      final u = const Umfrage(frage: 'F', optionen: ['A', 'B'], mehrfach: false);
      final e = umfrageAuswerten(u, [_s('1', _anna, 's1:0,1'), _s('2', _ben, 's1:1')], (s) => s.inhalt, null);
      expect(e.abstimmende, 1);
      expect(e.waehler[1], [_ben]);
    });
  });

  group('Rechte der Oberfläche (spiegeln den Server)', () {
    ChatPin pin(String von) => ChatPin(id: 'p', konversationId: 'k', nachrichtId: 'n', gepinntVon: von, createdAt: DateTime.utc(2026), rev: 1);
    test('Anheften: Privatchats alle, Familienchat nur Eltern und Admins', () {
      for (final r in Role.values) {
        expect(ChatRechte(r, _anna).darfPinnen(ChatArt.group), isTrue);
        expect(ChatRechte(r, _anna).darfPinnen(ChatArt.direct), isTrue);
      }
      expect(ChatRechte(Role.child, _anna).darfPinnen(ChatArt.family), isFalse);
      expect(ChatRechte(Role.parent, _anna).darfPinnen(ChatArt.family), isTrue);
      expect(ChatRechte(Role.admin, _anna).darfPinnen(ChatArt.family), isTrue);
    });
    test('Lösen: Eltern und Admins jeden Pin, Kinder nur den eigenen', () {
      expect(ChatRechte(Role.parent, _anna).darfPinLoesen(pin(_ben)), isTrue);
      expect(ChatRechte(Role.admin, _anna).darfPinLoesen(pin(_ben)), isTrue);
      expect(ChatRechte(Role.child, _anna).darfPinLoesen(pin(_ben)), isFalse);
      expect(ChatRechte(Role.child, _anna).darfPinLoesen(pin(_anna)), isTrue);
    });
  });

  for (final (name, crypto) in await kryptoVarianten()) {
    group('Ende-zu-Ende ($name)', () {
      late ChatWelt welt;
      late TestPerson anna, ben, cora;
      late List<TestPerson> alle;
      late Geraet a, b, c;
      late ChatZusatzRepository za, zb, zc;
      final geraete = <Geraet>[];

      Geraet neuesGeraet(TestPerson p) {
        final g = Geraet.neu(welt, p)..mitgliederLernen(alle);
        geraete.add(g);
        return g;
      }

      ChatZusatzRepository zusatz(Geraet g) => ChatZusatzRepository(db: g.db, store: g.store, ich: () => g.person.id, beiAenderung: () {}, jetzt: () => g.jetzt);

      setUp(() {
        welt = ChatWelt(crypto);
        anna = TestPerson(_anna, 'Anna', crypto);
        ben = TestPerson(_ben, 'Ben', crypto);
        cora = TestPerson(_cora, 'Cora', crypto);
        alle = [anna, ben, cora];
        welt.aktiveMitglieder = [for (final p in alle) p.id];
        geraete.clear();
        a = neuesGeraet(anna);
        b = neuesGeraet(ben);
        c = neuesGeraet(cora);
        za = zusatz(a);
        zb = zusatz(b);
        zc = zusatz(c);
      });
      tearDown(() async {
        for (final g in geraete) {
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

      /// Gruppe aus Anna, Ben und Cora mit einer Nachricht von Anna.
      Future<(String, String)> gruppeMitNachricht(String text) async {
        final konv = await a.repo.gruppeAnlegen([ben.id, cora.id], name: 'Wochenende');
        await abgleich([a, b, c]);
        final nid = (await a.repo.senden(konv, text))!;
        await abgleich([a, b, c]);
        return (konv, nid);
      }

      /// Klartext einer Reaktion oder Stimme auf dem Gerät [g] (wie [NachrichtenInhalt.zusatz]: Hülle öffnen, gebunden an ID, Person und Nachricht).
      Future<String> klar(Geraet g, {required String konv, required String id, required String nachricht, required String user, required String wire, String? art}) async {
        if (wire.startsWith(kPraefixLokal)) return wire.substring(kPraefixLokal.length);
        final d = await g.krypto.nachrichtOeffnen(konversationId: konv, nachrichtId: id, autorId: user, wire: wire, antwortAuf: nachricht, art: art);
        return d.lesbar ? d.text : '<${d.hinweis}>';
      }

      Future<List<String>> reaktionen(Geraet g, String nachricht) async => [
        for (final r in await (g.db.select(g.db.reaktionen)..where((t) => t.nachrichtId.equals(nachricht))).get())
          '${r.userId}:${await klar(g, konv: r.konversationId, id: r.id, nachricht: r.nachrichtId, user: r.userId, wire: r.inhalt, art: 'r')}',
      ]..sort();

      Future<Map<String, String>> stimmen(Geraet g, String nachricht) async => {
        for (final s in await (g.db.select(g.db.stimmen)..where((t) => t.nachrichtId.equals(nachricht))).get())
          s.userId: (await klar(g, konv: s.konversationId, id: s.id, nachricht: s.nachrichtId, user: s.userId, wire: s.inhalt, art: 's')).replaceFirst(RegExp(r'@\d+$'), ''),
      };

      test('Reaktion: Roundtrip, ersetzen, zurücknehmen; der Server sieht nie ein Emoji', () async {
        final (konv, nid) = await gruppeMitNachricht('Wer kommt zum Essen?');
        await zb.reagieren(konv, nid, '👍');
        await zc.reagieren(konv, nid, '❤️');
        await abgleich([b, c, a]);
        expect(await reaktionen(a, nid), ['$_ben:r1:👍', '$_cora:r1:❤️']);
        expect(await reaktionen(b, nid), ['$_ben:r1:👍', '$_cora:r1:❤️']);
        // der Server speichert nur Hüllen mit fester ID, nie Klartext
        final zeilen = welt.alle('reaktion');
        expect(zeilen, hasLength(2));
        expect(zeilen.map((z) => z.id).toSet(), {reaktionId(nid, ben.id), reaktionId(nid, cora.id)});
        for (final z in zeilen) {
          expect(z.fields['inhalt'], startsWith('e1:'));
        }
        final gesehen = jsonEncode(welt.gesehen) + jsonEncode([for (final z in zeilen) z.fields]);
        expect(gesehen, isNot(contains('👍')));
        expect(gesehen, isNot(contains('❤')));
        expect(gesehen, isNot(contains('l1:')));
        expect(gesehen, isNot(contains('r1:')));
        // ersetzen: je Person eine Reaktion
        await zb.reagieren(konv, nid, '😂');
        await abgleich([b, a, c]);
        expect(await reaktionen(c, nid), ['$_ben:r1:😂', '$_cora:r1:❤️']);
        expect(welt.alle('reaktion'), hasLength(2));
        // zurücknehmen
        await zb.reaktionEntfernen(nid);
        await abgleich([b, a, c]);
        expect(await reaktionen(a, nid), ['$_cora:r1:❤️']);
        expect(welt.alle('reaktion'), hasLength(1));
        // erneut reagieren: dieselbe feste ID
        await zb.reagieren(konv, nid, '🙏');
        await abgleich([b, a, c]);
        expect(await reaktionen(a, nid), ['$_ben:r1:🙏', '$_cora:r1:❤️']);
      });

      test('Der Klartext verlässt das Gerät nie: ohne bestätigte Epoche bleibt die Reaktion im Ausgang (l1:)', () async {
        final konv = await a.repo.gruppeAnlegen([ben.id], name: '');
        // die Konversation und ihre Epoche sind noch nicht beim Server: nichts ist sendbar, es geht auch kein Klartext hinaus
        await a.repo.senden(konv, 'hallo');
        await abgleich([a, b]);
        final nid = (await a.nachrichten(konv)).single.id;
        await za.reagieren(konv, nid, '👍');
        a.bereit = false;
        final ops = await a.store.naechsteOps(50, vorbereiter: a.vorbereiter);
        expect(ops.where((o) => o.entity == 'reaktion'), isEmpty);
        expect((await a.ausgang()).where((o) => o.entity == 'reaktion').single.fieldsJson, contains('l1:r1:👍'));
        a.bereit = true;
        await abgleich([a, b]);
        expect(welt.alle('reaktion').single.fields['inhalt'], startsWith('e1:'));
        expect(jsonEncode(welt.gesehen), isNot(contains('👍')));
      });

      test('Die Hülle ist an Nachricht, Person und eigene ID gebunden: umgehängt wird sie nicht geöffnet', () async {
        final (konv, nid) = await gruppeMitNachricht('Hallo');
        final nid2 = (await a.repo.senden(konv, 'Noch eine'))!;
        await abgleich([a, b, c]);
        await zb.reagieren(konv, nid, '👍');
        await abgleich([b, a]);
        final z = welt.alle('reaktion').single;
        final wire = z.fields['inhalt'] as String;
        // richtig geöffnet
        expect(await klar(a, konv: konv, id: z.id, nachricht: nid, user: ben.id, wire: wire, art: 'r'), 'r1:👍');
        // ohne Art oder mit der falschen Art (z. B. als Stimme gelesen) lässt sich die Hülle nicht öffnen
        expect(await klar(a, konv: konv, id: z.id, nachricht: nid, user: ben.id, wire: wire), startsWith('<'));
        expect(await klar(a, konv: konv, id: z.id, nachricht: nid, user: ben.id, wire: wire, art: 's'), startsWith('<'));
        // auf eine andere Nachricht umgehängt, als anderer Absender oder unter einer anderen ID: nicht lesbar
        expect(await klar(a, konv: konv, id: z.id, nachricht: nid2, user: ben.id, wire: wire, art: 'r'), startsWith('<'));
        expect(await klar(a, konv: konv, id: z.id, nachricht: nid, user: cora.id, wire: wire, art: 'r'), startsWith('<'));
        expect(await klar(a, konv: konv, id: reaktionId(nid, cora.id), nachricht: nid, user: ben.id, wire: wire, art: 'r'), startsWith('<'));
        // als Stimme gelesen (andere ID): ebenfalls nicht
        expect(await klar(a, konv: konv, id: stimmeId(nid, ben.id), nachricht: nid, user: ben.id, wire: wire, art: 's'), startsWith('<'));
      });

      test('Umfrage: senden, abstimmen (Einzel- und Mehrfachwahl), ändern, zurücknehmen; der Server sieht keine Umfrage und keine Stimme', () async {
        final konv = await a.repo.gruppeAnlegen([ben.id, cora.id], name: 'Wochenende');
        await abgleich([a, b, c]);
        final text = umfrageKodieren(frage: 'Wann Treffen?', optionen: ['Samstag', 'Sonntag', 'Montag'], mehrfach: true);
        final nid = (await a.repo.senden(konv, text))!;
        await abgleich([a, b, c]);
        // Ben sieht die Umfrage
        final n = (await b.nachrichten(konv)).single;
        final u = umfrageLesen(await b.lesen(n))!;
        expect(u.optionen, ['Samstag', 'Sonntag', 'Montag']);
        await zb.abstimmen(konv, nid, {0, 2});
        await zc.abstimmen(konv, nid, {2});
        await za.abstimmen(konv, nid, {1});
        await abgleich([b, c, a]);
        for (final g in [a, b, c]) {
          expect(await stimmen(g, nid), {ben.id: 's1:0,2', cora.id: 's1:2', anna.id: 's1:1'}, reason: g.name);
        }
        final klartexte = await stimmen(a, nid);
        final e = umfrageAuswerten(u, await (a.db.select(a.db.stimmen)).get(), (s) => klartexte[s.userId], anna.id);
        expect(e.abstimmende, 3);
        expect(e.waehler[2], unorderedEquals([ben.id, cora.id]));
        expect(e.meine, {1});
        // der Server kennt weder Frage noch Antworten noch Wahl im Klartext
        final gesehen = jsonEncode(welt.gesehen) + jsonEncode([for (final z in welt.alle('stimme')) z.fields]);
        for (final w in ['Wann Treffen', 'Samstag', 'Montag', 's1:', 'l1:']) {
          expect(gesehen, isNot(contains(w)), reason: w);
        }
        expect(welt.alle('stimme').map((z) => z.id).toSet(), {stimmeId(nid, ben.id), stimmeId(nid, cora.id), stimmeId(nid, anna.id)});
        // ändern und zurücknehmen
        await zb.abstimmen(konv, nid, {1});
        await zc.abstimmen(konv, nid, {});
        await abgleich([b, c, a]);
        expect(await stimmen(a, nid), {ben.id: 's1:1', anna.id: 's1:1'});
        expect(welt.alle('stimme'), hasLength(2));
      });

      test('Schnelles Tippen: Reaktionen und Stimmen schalten nach dem Stand der Datenbank um, nicht nach dem Stand der Oberfläche', () async {
        final (konv, nid) = await gruppeMitNachricht('Schnell');
        // zwei Tipps auf dasselbe Emoji, ohne dass sich die Oberfläche dazwischen aktualisiert (aktuell: null): erst setzen, dann zurücknehmen
        await Future.wait([zb.reaktionUmschalten(konv, nid, '👍'), zb.reaktionUmschalten(konv, nid, '👍')]);
        expect(await (b.db.select(b.db.reaktionen)).get(), isEmpty);
        await zb.reaktionUmschalten(konv, nid, '👍');
        await Future.wait([zb.reaktionUmschalten(konv, nid, '❤️'), zb.reaktionUmschalten(konv, nid, '❤️')]);
        expect(await (b.db.select(b.db.reaktionen)).get(), isEmpty);
        // Mehrfachumfrage: zwei verschiedene Antworten schnell nacheinander: beide bleiben gewählt
        await Future.wait([
          zb.stimmeUmschalten(konv, nid, 0, mehrfach: true, anzahl: 3),
          zb.stimmeUmschalten(konv, nid, 2, mehrfach: true, anzahl: 3),
        ]);
        final s = (await (b.db.select(b.db.stimmen)).get()).single;
        expect(stimmeLesenMitZeit(s.inhalt.substring(3), 3, mehrfach: true)!.auswahl, {0, 2});
        // dieselbe Antwort zweimal schnell: an und wieder ab
        await Future.wait([zb.stimmeUmschalten(konv, nid, 1, mehrfach: true, anzahl: 3), zb.stimmeUmschalten(konv, nid, 1, mehrfach: true, anzahl: 3)]);
        expect(stimmeLesenMitZeit((await (b.db.select(b.db.stimmen)).get()).single.inhalt.substring(3), 3, mehrfach: true)!.auswahl, {0, 2});
      });

      test('Pin: anheften, nur einmal, höchstens fünf, lösen', () async {
        final konv = await a.repo.gruppeAnlegen([ben.id], name: '');
        await abgleich([a, b]);
        final ids = <String>[];
        for (var i = 0; i < 6; i++) {
          ids.add((await a.repo.senden(konv, 'Nachricht $i'))!);
          a.jetzt = a.jetzt.add(const Duration(seconds: 1));
        }
        await abgleich([a, b]);
        for (var i = 0; i < kMaxPins; i++) {
          await za.pinnen(konv, ids[i]);
        }
        await za.pinnen(konv, ids[0]); // schon angeheftet: nichts
        await expectLater(za.pinnen(konv, ids[5]), throwsA(isA<PinGrenze>()));
        await abgleich([a, b]);
        expect((await (b.db.select(b.db.pins)).get()).map((p) => p.nachrichtId).toSet(), ids.take(kMaxPins).toSet());
        expect(welt.alle('pin').map((z) => z.id).toSet(), {for (final i in ids.take(kMaxPins)) pinId(i)});
        // Ben (Mitglied der Gruppe) löst eine Anheftung
        await zb.pinLoesen(ids[1]);
        await abgleich([b, a]);
        expect((await (a.db.select(a.db.pins)).get()).map((p) => p.nachrichtId), isNot(contains(ids[1])));
        await za.pinnen(konv, ids[5]);
        await abgleich([a, b]);
        expect(welt.alle('pin'), hasLength(kMaxPins));
      });

      test('Nachricht löschen: Reaktionen, Stimmen und Pins verschwinden lokal mit ihr', () async {
        final (konv, nid) = await gruppeMitNachricht('Weg damit');
        await zb.reagieren(konv, nid, '👍');
        await zb.abstimmen(konv, nid, {0});
        await za.pinnen(konv, nid);
        await abgleich([b, a, c]);
        expect(await (a.db.select(a.db.reaktionen)).get(), hasLength(1));
        await a.repo.loeschen(nid);
        expect(await (a.db.select(a.db.reaktionen)).get(), isEmpty);
        expect(await (a.db.select(a.db.stimmen)).get(), isEmpty);
        expect(await (a.db.select(a.db.pins)).get(), isEmpty);
        expect(await (a.db.select(a.db.nachrichten)).get(), isEmpty);
      });

      test('Alte App-Versionen: unbekannte Entitäten im Änderungsstrom werden übersprungen, der Überträgt … weiter', () async {
        final alt = {...syncEntities}..remove('reaktion')..remove('stimme')..remove('pin');
        final altStore = SyncStore(a.db, entitaeten: alt);
        final res = welt.antwortMit([
          ('reaktion', 'r1', const {'konversationId': 'x', 'nachrichtId': 'y', 'userId': 'z', 'inhalt': 'e1:abc'}),
          ('pin', 'p1', const {'konversationId': 'x', 'nachrichtId': 'y'}),
        ]);
        final bericht = await altStore.uebernehmen(res, const []);
        expect(bericht.neuLaden, isFalse);
        expect(await a.db.select(a.db.reaktionen).get(), isEmpty);
        expect(await a.db.select(a.db.pins).get(), isEmpty);
      });
    });
  }
}
