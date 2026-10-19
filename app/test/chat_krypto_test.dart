// Ende-zu-Ende-Verschlüsselung des Chats (E2EE Phase 2) auf Logikebene: echte lokale Datenbanken je Gerät, echter SyncStore und echter Ausgang-Vorbereiter, ein
// Fake-Server mit den Regeln des echten (Sicht, nur der Empfänger liest seinen Wrap, der erste Schreiber einer Epoche gewinnt, e1 statt Klartext).
// Läuft mit dem Fake-Krypto und, wo libsodium verfügbar ist, zusätzlich mit den echten Bausteinen.
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/chat/chat_krypto_state.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/chat/nachrichten_inhalt.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/epochen.dart';
import 'package:lx_fampad/data/crypto/huelle.dart';

import 'support/chat_welt.dart';
import 'support/fake_crypto.dart';

const _anna = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _ben = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _cora = 'cccccccc-0000-4000-8000-00000000000c';
const _dora = 'dddddddd-0000-4000-8000-00000000000d';

Future<void> main() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true; // je Gerät eine eigene In-Memory-Datenbank
  for (final (name, crypto) in await kryptoVarianten()) {
    group('Chat-Verschlüsselung ($name)', () {
      late ChatWelt welt;
      late TestPerson anna, ben, cora, dora;
      late List<TestPerson> alle;
      late Geraet a, b, c, d;
      final geraete = <Geraet>[];

      Geraet neuesGeraet(TestPerson p, {String? name}) {
        final g = Geraet.neu(welt, p, name: name)..mitgliederLernen(alle);
        geraete.add(g);
        return g;
      }

      setUp(() {
        welt = ChatWelt(crypto);
        anna = TestPerson(_anna, 'Anna', crypto);
        ben = TestPerson(_ben, 'Ben', crypto);
        cora = TestPerson(_cora, 'Cora', crypto);
        dora = TestPerson(_dora, 'Dora', crypto);
        alle = [anna, ben, cora, dora];
        welt.aktiveMitglieder = [for (final p in alle) p.id];
        geraete.clear();
        a = neuesGeraet(anna);
        b = neuesGeraet(ben);
        c = neuesGeraet(cora);
        d = neuesGeraet(dora);
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

      Future<String> gruppe(Geraet von, List<Geraet> mit, {List<Geraet>? alleAbgleichen}) async {
        final id = await von.repo.gruppeAnlegen([for (final g in mit) g.person.id], name: 'Wochenende');
        await abgleich(alleAbgleichen ?? [von, ...mit]);
        return id;
      }

      Future<String> text(Geraet g, String konv, String id) async {
        final n = (await g.nachrichten(konv)).firstWhere((x) => x.id == id);
        return g.lesen(n);
      }

      Future<List<String>> lesbar(Geraet g, String konv) async => [for (final n in await g.nachrichten(konv)) await g.lesen(n)];

      Future<String> senden(Geraet g, String konv, String t, {List<Geraet>? abgleichen}) async {
        final id = (await g.repo.senden(konv, t))!;
        await abgleich(abgleichen ?? [g]);
        return id;
      }

      test('Direktchat: Roundtrip, der Server sieht nur Chiffretext und Wraps, keinen Klartext', () async {
        final id = await a.repo.direktChat(ben.id);
        await abgleich([a, b]);
        await senden(a, id, 'Hallo Ben, das ist geheim', abgleichen: [a, b]);
        await senden(b, id, 'Hallo Anna 🎉', abgleichen: [b, a]);
        expect(await lesbar(a, id), ['Hallo Ben, das ist geheim', 'Hallo Anna 🎉']);
        expect(await lesbar(b, id), ['Hallo Ben, das ist geheim', 'Hallo Anna 🎉']);
        // der Server hat nur e1-Hüllen gesehen
        for (final z in welt.alle('nachricht')) {
          expect(z.fields['text'], startsWith('e1:'));
          expect(z.fields['text'], isNot(contains('geheim')));
          expect(z.fields['text'], isNot(contains('Hallo')));
        }
        final gesehen = jsonEncode(welt.gesehen);
        expect(gesehen, isNot(contains('geheim')));
        expect(gesehen, isNot(contains('l1:')));
        // Epoche 1 mit zwei Wraps, nichts Weiteres
        expect(welt.alle('epoche'), hasLength(1));
        expect(welt.alle('epoche_wrap'), hasLength(2));
        expect(a.krypto.epochenMitSchluessel(id), [1]);
      });

      test('Der Klartext verlässt das Gerät nie: ohne Schlüssel bleibt die Nachricht im Ausgang (l1:), nichts geht im Klartext raus', () async {
        final id = await a.repo.direktChat(ben.id);
        // Epoche noch nicht bestätigt: die Nachricht wartet
        final n = (await a.repo.senden(id, 'wartet'))!;
        await a.store.naechsteOps(50, vorbereiter: a.vorbereiter); // nichts sendbar, die Epoche ist noch nicht bestätigt
        expect((await a.ausgang()).where((o) => o.entity == 'nachricht').single.fieldsJson, contains('l1:wartet'));
        await abgleich([a, b]);
        expect(await text(a, id, n), 'wartet');
        expect(welt.alle('nachricht').single.fields['text'], startsWith('e1:'));
        // ohne eigene Verschlüsselung (Gerät nicht bereit) bleibt alles im Ausgang
        a.bereit = false;
        await a.repo.senden(id, 'nur lokal');
        await welt.abgleichen(a);
        expect(welt.alle('nachricht'), hasLength(1));
        expect((await a.ausgang()).single.fieldsJson, contains('l1:nur lokal'));
        a.bereit = true;
        await abgleich([a, b]);
        expect(welt.alle('nachricht'), hasLength(2));
      });

      test('zwei Geräte derselben Person bekommen dieselben Epochenschlüssel und lesen den ganzen Verlauf', () async {
        final id = await a.repo.direktChat(ben.id);
        await abgleich([a, b]);
        await senden(a, id, 'Eins', abgleichen: [a, b]);
        final b2 = neuesGeraet(ben, name: 'Ben-Tablet');
        await abgleich([b2]);
        expect(await lesbar(b2, id), ['Eins']);
        final k1 = b.krypto.schluessel(id, 1)!;
        final k2 = b2.krypto.schluessel(id, 1)!;
        expect(gleicheBytes(k1, k2), isTrue);
        await senden(b2, id, 'Zwei vom Tablet', abgleichen: [b2, b, a]);
        expect(await lesbar(a, id), ['Eins', 'Zwei vom Tablet']);
        // App-Neustart: der Schlüsselbund wird aus den Wraps wieder aufgebaut (nichts steht auf der Platte)
        b.neuStarten();
        expect(b.krypto.schluessel(id, 1), isNull);
        await b.krypto.aktualisieren();
        expect(gleicheBytes(b.krypto.schluessel(id, 1)!, k1), isTrue);
      });

      test('ein Nichtteilnehmer (z. B. der Admin) bekommt weder Epoche noch Wrap noch Nachricht und kann nichts lesen', () async {
        final id = await a.repo.direktChat(ben.id);
        await senden(a, id, 'privat', abgleichen: [a, b]);
        await abgleich([c]); // Cora ist kein Teilnehmer
        expect(await c.nachrichten(id), isEmpty);
        expect(await c.db.select(c.db.konversationEpochen).get(), isEmpty);
        expect(await c.db.select(c.db.epocheWraps).get(), isEmpty);
        final n = (await a.nachrichten(id)).single;
        final d1 = await c.krypto.nachrichtOeffnen(konversationId: id, nachrichtId: n.id, autorId: n.autorId, wire: n.inhalt);
        expect(d1.lesbar, isFalse);
        expect(d1.hinweis, 'warte auf Schlüssel');
      });

      test('Wraps sind nur für den Empfänger sichtbar: der Server liefert jeder Person genau ihren eigenen, auch dem Verteiler', () async {
        await gruppe(a, [b, c]);
        for (final g in [a, b, c]) {
          final wraps = welt.sichtbarFuer(g.person.id, 'epoche_wrap');
          expect({for (final w in wraps) w.fields['empfaengerId']}, {g.person.id}, reason: g.name);
        }
        // Epoche (Mitgliederliste) sehen alle drei, Dora (kein Teilnehmer) nichts
        expect(welt.sichtbarFuer(anna.id, 'epoche'), hasLength(1));
        expect(welt.sichtbarFuer(dora.id, 'epoche'), isEmpty);
        expect(welt.sichtbarFuer(dora.id, 'epoche_wrap'), isEmpty);
      });

      test('Gruppe: Entfernen rotiert, die neue Epoche gibt es nur für die Verbleibenden, der Entfernte liest Neues nicht', () async {
        final id = await gruppe(a, [b, c]);
        final alt = await senden(a, id, 'vor dem Entfernen', abgleichen: [a, b, c]);
        expect(await text(c, id, alt), 'vor dem Entfernen');
        await a.repo.teilnehmerAendern(id, weg: {cora.id});
        await abgleich([a, b, c]);
        expect(welt.alle('epoche'), hasLength(2));
        final wraps2 = welt.alle('epoche_wrap').where((w) => w.fields['epoche'] == 2).map((w) => w.fields['empfaengerId']).toSet();
        expect(wraps2, {anna.id, ben.id});
        final neu = await senden(a, id, 'nach dem Entfernen', abgleichen: [a, b]);
        expect(await text(b, id, neu), 'nach dem Entfernen');
        // Cora hat noch den alten Schlüssel (Epoche 1) und sieht nichts mehr vom Server; mit der Hülle in der Hand liest sie Neues nicht
        final n = (await a.nachrichten(id)).firstWhere((x) => x.id == neu);
        final d1 = await c.krypto.nachrichtOeffnen(konversationId: id, nachrichtId: n.id, autorId: n.autorId, wire: n.inhalt);
        expect(d1.lesbar, isFalse);
        expect(c.krypto.epochenMitSchluessel(id), [1]);
        // die alte Nachricht (Epoche 1) bleibt für sie lesbar: sie war damals Mitglied
        expect(await text(c, id, alt), 'vor dem Entfernen');
      });

      test('Neues Mitglied ohne "Verlauf teilen": liest neue Nachrichten, den alten Verlauf nicht', () async {
        final id = await gruppe(a, [b]);
        final alt = await senden(a, id, 'altes Geheimnis', abgleichen: [a, b]);
        await a.repo.teilnehmerAendern(id, hinzu: {cora.id});
        await abgleich([a, b, c]);
        final neu = await senden(a, id, 'für alle drei', abgleichen: [a, b, c]);
        expect(await text(c, id, neu), 'für alle drei');
        expect(await text(c, id, alt), '<warte auf Schlüssel>');
        expect(c.krypto.epochenMitSchluessel(id), [2]);
        // der Server hat für Cora keinen Wrap der Epoche 1
        expect(welt.alle('epoche_wrap').where((w) => w.fields['empfaengerId'] == cora.id).map((w) => w.fields['epoche']), [2]);
      });

      test('Neues Mitglied mit "Verlauf teilen": bekommt auch die älteren Epochen (Bürge ist die aktuelle, geprüfte Liste)', () async {
        final id = await gruppe(a, [b]);
        final alt = await senden(a, id, 'altes Geheimnis', abgleichen: [a, b]);
        await a.repo.teilnehmerAendern(id, hinzu: {cora.id});
        await abgleich([a, b]);
        await a.repo.teilnehmerAendern(id, hinzu: {dora.id}, verlaufTeilen: true);
        await abgleich([a, b, c, d]);
        expect(await text(d, id, alt), 'altes Geheimnis');
        expect(d.krypto.epochenMitSchluessel(id), [1, 2, 3]);
        // Cora kam ohne Verlauf dazu (Epoche 2 ohne Epoche 1); Dora kennt sie noch nicht: Epoche 3 wartet auf ihre Bestätigung
        expect(c.krypto.epochenMitSchluessel(id), [2]);
        expect((await c.krypto.sendeEpoche(id)).wartet, isTrue);
        final konv = await (c.db.select(c.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        final plan = await c.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id, cora.id, dora.id});
        expect(plan!.neu, {dora.id});
        await c.store.aendernMehrere(await c.krypto.epocheErstellen(konversationId: id, mitglieder: plan.mitglieder));
        await abgleich([a, b, c, d]);
        // mit der Bestätigung ist die zurückgestellte Epoche 3 nachträglich gültig
        expect(c.krypto.epochenMitSchluessel(id), [2, 3, 4]);
        expect((await c.krypto.sendeEpoche(id)).wartet, isFalse);
      });

      test('eingeschleuste unbestätigte Person: eine Epoche mit ihr wird nicht geöffnet, nicht benutzt; Heilung nach der Frist ersetzt sie ohne sie', () async {
        final id = await gruppe(a, [b]);
        await senden(a, id, 'vorher', abgleichen: [a, b]);
        // Anna (oder wer ihr Gerät hat) legt Epoche 2 mit Dora an, die Ben nie bestätigt hat
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, ben.id, dora.id}));
        await abgleich([a, b]);
        expect(b.krypto.schluessel(id, 2), isNull);
        expect(b.krypto.problem(id, 2), isNotNull);
        expect((await b.krypto.sendeEpoche(id)).wartet, isTrue, reason: 'nicht an eine Liste mit einer unbestätigten Person senden');
        expect(await b.krypto.nachrichtVersiegeln(konversationId: id, nachrichtId: 'x', klartext: 'geheim'), isNull);
        final konv = await (b.db.select(b.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        // Dora ist keine Teilnehmerin: nach der Frist ersetzt Ben die Epoche durch eine ohne sie
        expect(await b.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id}), isNull, reason: 'erst nach der Frist');
        // wäre Dora Teilnehmerin, käme die Aufnahme-Abfrage
        final mitDora = await b.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id, dora.id});
        expect(mitDora!.neu, {dora.id});
        expect(mitDora.automatisch, isFalse);
        b.jetzt = b.jetzt.add(ChatKrypto.heilungsFrist + const Duration(seconds: 1));
        final plan = await b.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id, dora.id});
        expect(plan!.heilung, isTrue);
        expect(plan.automatischeMitglieder, {anna.id, ben.id}, reason: 'automatisch nie an die Unbestätigte');
        await b.store.aendernMehrere(await b.krypto.epocheErstellen(konversationId: id, mitglieder: plan.automatischeMitglieder));
        await abgleich([b, a]);
        final neu = await senden(b, id, 'danach', abgleichen: [b, a]);
        expect(await text(a, id, neu), 'danach');
      });

      test('Heilung auch, wenn die höchste Epoche mich gar nicht nennt: nach der Frist legt ein Gerät mit früheren Schlüsseln eine neue an', () async {
        final id = await gruppe(a, [b, c]);
        await senden(a, id, 'vorher', abgleichen: [a, b, c]);
        // Cora legt Epoche 2 nur für sich und Anna an: Ben fehlt in der Liste
        await c.store.aendernMehrere(await c.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, cora.id}));
        await abgleich([c, a, b]);
        expect(b.krypto.schluessel(id, 2), isNull);
        final konv = await (b.db.select(b.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        final alle3 = {anna.id, ben.id, cora.id};
        expect(await b.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3), isNull, reason: 'erst nach der Frist');
        b.jetzt = b.jetzt.add(ChatKrypto.heilungsFrist + const Duration(seconds: 1));
        final plan = await b.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3);
        expect(plan!.heilung, isTrue);
        await b.store.aendernMehrere(await b.krypto.epocheErstellen(konversationId: id, mitglieder: plan.automatischeMitglieder));
        await abgleich([b, a, c]);
        final neu = await senden(b, id, 'geheilt', abgleichen: [b, a, c]);
        expect(await text(c, id, neu), 'geheilt');
      });

      test('Wrap und Mitgliederliste: Server schiebt einen Wrap aus einer anderen Konversation unter: nicht übernommen, nicht lesbar', () async {
        final g1 = await gruppe(a, [b]);
        final g2 = await gruppe(a, [b]);
        await abgleich([a, b]);
        final fremd = welt.alle('epoche_wrap').firstWhere((w) => w.fields['konversationId'] == g2 && w.fields['empfaengerId'] == ben.id).fields['wrap'];
        final ziel = welt.alle('epoche_wrap').firstWhere((w) => w.fields['konversationId'] == g1 && w.fields['empfaengerId'] == ben.id);
        final echt = ziel.fields['wrap'];
        // frisches Gerät von Ben, dem der Server den falschen Wrap liefert
        final b2 = neuesGeraet(ben, name: 'Ben-Neu');
        ziel.fields['wrap'] = fremd;
        await abgleich([b2]);
        expect(b2.krypto.schluessel(g1, 1), isNull);
        expect(b2.krypto.problem(g1, 1), isNotNull);
        expect(b2.krypto.schluessel(g2, 1), isNotNull, reason: 'die andere Konversation bleibt lesbar');
        // der echte Wrap funktioniert wieder
        ziel.fields['wrap'] = echt;
        final b3 = neuesGeraet(ben, name: 'Ben-Neu2');
        await abgleich([b3]);
        expect(b3.krypto.schluessel(g1, 1), isNotNull);
      });

      test('eingeschleustes Mitglied: eine vom Server umgeschriebene Mitgliederliste wird nicht übernommen', () async {
        final id = await gruppe(a, [b]);
        final liste = welt.zeile('epoche', epocheId(id, 1))!;
        final echt = liste.fields['mitglieder'] as String;
        // Server schreibt die Liste um (anderes Byte): die Signatur des Verteilers passt nicht mehr
        final bytes = base64urlDekodieren(echt);
        bytes[bytes.length - 80] ^= 1;
        liste.fields['mitglieder'] = base64urlKodieren(bytes);
        final b2 = neuesGeraet(ben, name: 'Ben-Neu');
        await abgleich([b2]);
        expect(b2.krypto.schluessel(id, 1), isNull);
        expect(b2.krypto.problem(id, 1), isNotNull);
        liste.fields['mitglieder'] = echt;
      });

      test('unbekannter Verteiler: kein Schlüssel vom Server, der Wrap wartet, bis der Verteiler gemerkt ist', () async {
        final id = await gruppe(a, [b]);
        final b2 = neuesGeraet(ben, name: 'Ben-Neu')..tofu.remove(anna.id); // Ben kennt Annas Schlüssel auf diesem Gerät noch nicht
        await abgleich([b2]);
        expect(b2.krypto.schluessel(id, 1), isNull);
        expect(b2.krypto.problem(id, 1), NichtLesbarGrund.absenderUnbekannt);
        b2.tofu[anna.id] = anna.oeffentlich;
        b2.krypto.vertrauenGeaendert();
        await b2.krypto.aktualisieren();
        expect(b2.krypto.schluessel(id, 1), isNotNull);
      });

      test('Nachricht: Absender gefälscht, Chiffretext verändert, falsche Konversation: nicht lesbar, nie als Text', () async {
        final id = await a.repo.direktChat(ben.id);
        final m = await senden(a, id, 'echt', abgleichen: [a, b]);
        final n = (await b.nachrichten(id)).firstWhere((x) => x.id == m);
        Future<DekodierterInhalt> oeffnen({String? konv, String? autor, String? wire, String? mid}) =>
            b.krypto.nachrichtOeffnen(konversationId: konv ?? id, nachrichtId: mid ?? n.id, autorId: autor ?? n.autorId, wire: wire ?? n.inhalt);
        expect((await oeffnen()).text, 'echt');
        // der Server gibt die Nachricht als von Cora aus (AAD und Signatur passen nicht)
        expect((await oeffnen(autor: cora.id)).lesbar, isFalse);
        // andere Nachrichten-ID (Umhängen in eine andere Nachricht)
        expect((await oeffnen(mid: 'ffffffff-0000-4000-8000-0000000000ff')).lesbar, isFalse);
        // verändertes Byte im Chiffretext
        final bytes = base64urlDekodieren(n.inhalt.substring(3));
        bytes[bytes.length - 1] ^= 1;
        expect((await oeffnen(wire: 'e1:${base64urlKodieren(bytes)}')).lesbar, isFalse);
        // Absender unbekannt (autorId null: Mitglied entfernt)
        final ohne = await b.krypto.nachrichtOeffnen(konversationId: id, nachrichtId: n.id, autorId: null, wire: n.inhalt);
        expect(ohne.lesbar, isFalse);
        // Klartext in einem verschlüsselten Chat öffnet nie
        final p1 = await b.krypto.nachrichtOeffnen(konversationId: id, nachrichtId: n.id, autorId: n.autorId, wire: 'p1:Klartext');
        expect(p1.lesbar, isFalse);
        expect(p1.text, isEmpty);
      });

      test('Race: zwei gleichzeitige Rotationen: der erste gewinnt, der Verlierer übernimmt die Epoche des Gewinners und sendet damit', () async {
        final id = await gruppe(a, [b, c]);
        // beide rotieren offline, ohne vom anderen zu wissen
        for (final g in [a, b]) {
          await g.store.aendernMehrere(await g.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, ben.id, cora.id}));
        }
        // Ben schreibt direkt danach (die Nachricht wartet, bis seine Epoche bestätigt ist)
        final bm = (await b.repo.senden(id, 'von Ben nach der Rotation'))!;
        await welt.abgleichen(a); // Anna gewinnt
        await abgleich([b, c, a]);
        expect(welt.alle('epoche'), hasLength(2));
        expect(welt.abgelehnt['epoche'], 1, reason: 'Bens Epoche wurde abgelehnt');
        expect(welt.abgelehnt['epoche_wrap'], greaterThanOrEqualTo(3));
        // Bens lokale Kopie ist die des Gewinners (Annas Epoche, ein Wrap von Anna), seine Nachricht ist mit DIESER Epoche verschlüsselt
        expect((await b.db.select(b.db.konversationEpochen).get()).where((e) => e.epoche == 2).single.verteilerId, anna.id);
        final wire = welt.zeile('nachricht', bm)!.fields['text'] as String;
        expect(HuellenCodec.epocheLesen(wire.substring(3)), 2);
        expect(await text(c, id, bm), 'von Ben nach der Rotation');
        expect(await text(a, id, bm), 'von Ben nach der Rotation');
        expect(gleicheBytes(b.krypto.schluessel(id, 2)!, a.krypto.schluessel(id, 2)!), isTrue);
      });

      test('Offline-Ausgang: Klartext wartet, bis der Abgleich die aktuelle Epoche kennt, und wird dann damit neu verschlüsselt', () async {
        final id = await gruppe(a, [b, c]);
        await abgleich([a, b, c]);
        // Anna schreibt offline (Klartext im Ausgang) ...
        final m = (await a.repo.senden(id, 'offline geschrieben'))!;
        // ... während Ben Cora entfernt (Epoche 2 beim Server)
        await b.repo.teilnehmerAendern(id, weg: {cora.id});
        await welt.abgleichen(b);
        // Annas Nachricht wartet länger als 20 s: der Abgleich holt zuerst den Stand (Epoche 2) und verschlüsselt erst danach
        a.jetzt = a.jetzt.add(const Duration(minutes: 2));
        await abgleich([a, b]);
        final wire = welt.zeile('nachricht', m)!.fields['text'] as String;
        expect(HuellenCodec.epocheLesen(wire.substring(3)), 2);
        expect(await text(b, id, m), 'offline geschrieben');
        // Cora (entfernt) bekommt nichts und kann es nicht lesen
        await abgleich([c]);
        expect(c.krypto.epochenMitSchluessel(id), [1]);
      });

      test('Bearbeiten ist ein neuer Chiffretext (neue Nonce), das Klartext-Original steht nie auf dem Server', () async {
        final id = await a.repo.direktChat(ben.id);
        final m = await senden(a, id, 'Version eins', abgleichen: [a, b]);
        final erste = welt.zeile('nachricht', m)!.fields['text'] as String;
        await a.repo.bearbeiten(m, 'Version zwei');
        await abgleich([a, b]);
        final zweite = welt.zeile('nachricht', m)!.fields['text'] as String;
        expect(zweite, isNot(erste));
        expect(zweite, startsWith('e1:'));
        expect(await text(b, id, m), 'Version zwei');
        expect(jsonEncode(welt.gesehen), isNot(contains('Version')));
      });

      test('Antworten: der Bezug ist nur eine ID, der zitierte Text steht nie im Klartext auf dem Server', () async {
        final id = await a.repo.direktChat(ben.id);
        final m = await senden(a, id, 'Frage: Wann?', abgleichen: [a, b]);
        final antwort = (await b.repo.senden(id, 'Um fünf', antwortAuf: m))!;
        await abgleich([b, a]);
        expect(welt.zeile('nachricht', antwort)!.fields['antwortAuf'], m);
        expect(jsonEncode(welt.gesehen), isNot(contains('Wann')));
        expect(await text(a, id, antwort), 'Um fünf');
      });

      test('Schlüsselwechsel einer Person: ohne Vertrauen kein Wrap, nach der Bestätigung eine neue Epoche für den neuen Schlüssel', () async {
        final id = await gruppe(a, [b]);
        final alt = await senden(a, id, 'vor dem Wechsel', abgleichen: [a, b]);
        // Ben wechselt seinen Schlüssel (Version 2); Anna weiß es vom Server, hat die Warnung aber noch nicht bestätigt
        ben.schluesselWechseln(welt);
        a.karte = {for (final p in alle) p.id: p.oeffentlich};
        a.krypto.vertrauenGeaendert();
        expect(await a.krypto.vertrauenswuerdig(ben.id), isNull);
        await expectLater(a.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, ben.id}), throwsA(isA<SchluesselFehlt>()));
        // ungeprüfte Änderungen lösen keine Rotation aus (sonst schaukeln sich Geräte mit verschiedenem Vertrauen hoch)
        final konv = await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        expect(await a.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id}), isNull);
        // Anna bestätigt den neuen Schlüssel
        a.tofu[ben.id] = ben.oeffentlich;
        a.krypto.vertrauenGeaendert();
        final plan = await a.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id});
        expect(plan, isNotNull);
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: id, mitglieder: plan!.mitglieder));
        await welt.abgleichen(a);
        // Bens Gerät (neuer Schlüssel) liest die neue Epoche, die alte nicht mehr
        b.neuStarten();
        b.mitgliederLernen(alle);
        b.tofu[anna.id] = anna.oeffentlich;
        await abgleich([b]);
        final neu = await senden(a, id, 'nach dem Wechsel', abgleichen: [a, b]);
        expect(await text(b, id, neu), 'nach dem Wechsel');
        expect(await text(b, id, alt), '<warte auf Schlüssel>');
      });

      test('Verteiler wechselt den Schlüssel und alle bestätigen: seine älteren Epochen bleiben nach einem Neustart lesbar (früher bestätigter Schlüssel), sonst nicht', () async {
        final id = await gruppe(b, [a, c]); // Ben verteilt die Epoche 1 mit seinem ersten Schlüssel
        final alt = await senden(b, id, 'aus der Zeit davor', abgleichen: [b, a, c]);
        final bensAlterSchluessel = ben.oeffentlich;
        ben.schluesselWechseln(welt);
        // Anna bestätigt Bens neuen Schlüssel (der alte bleibt als früher bestätigter gemerkt)
        a.frueher['${ben.id}:1'] = bensAlterSchluessel;
        a.tofu[ben.id] = ben.oeffentlich;
        a.mitgliederLernen(alle);
        a.neuStarten();
        await a.krypto.aktualisieren();
        expect(a.krypto.schluessel(id, 1), isNotNull);
        expect(await text(a, id, alt), 'aus der Zeit davor');
        // Cora hat den alten Schlüssel nicht als früher bestätigt: sie kann die Epoche nach dem Neustart nicht mehr prüfen
        c.tofu[ben.id] = ben.oeffentlich;
        c.mitgliederLernen(alle);
        c.neuStarten();
        await c.krypto.aktualisieren();
        expect(c.krypto.schluessel(id, 1), isNull);
        expect(c.krypto.problem(id, 1), isNotNull);
      });

      test('gleichzeitige Aktualisierungen stören sich nicht (der Controller, der Abgleich und die Oberfläche rufen sie unabhängig auf)', () async {
        final id = await gruppe(a, [b]);
        await senden(a, id, 'eins', abgleichen: [a, b]);
        b.neuStarten();
        final ergebnisse = await Future.wait([for (var i = 0; i < 5; i++) b.krypto.aktualisieren()]);
        expect(ergebnisse.where((x) => x), hasLength(1), reason: 'nur der erste Lauf öffnet den Schlüssel');
        expect((await lesbar(b, id)), ['eins']);
      });

      test('ein Listeneintrag, der mit l1: beginnt, geht normal hinaus; nur lokaler Klartext einer Chat-Nachricht bleibt zurück', () async {
        await a.store.aendern('list', 'l-1', {'name': 'l1:Einkauf'});
        await a.store.aendern('nachricht', 'n-1', {'konversationId': 'k', 'text': 'l1:geheim'}, nurLokal: {'createdAt': a.jetzt.toIso8601String()});
        final ops = await a.store.naechsteOps(10);
        expect([for (final o in ops) o.entity], ['list'], reason: 'die Nachricht mit lokalem Klartext hält zurück');
      });

      test('Mitglieder ohne Schlüssel: Gruppe und Direktchat verlangen ihn, der Familienchat nimmt sie später per neuer Epoche auf', () async {
        // Dora hat noch keinen Schlüssel eingerichtet
        for (final g in [a, b, c]) {
          g.mitgliederLernen(alle, ohneSchluessel: {dora.id});
        }
        await expectLater(a.repo.direktChat(dora.id), throwsA(isA<SchluesselFehlt>()));
        await expectLater(a.repo.gruppeAnlegen([ben.id, dora.id]), throwsA(isA<SchluesselFehlt>()));
        expect(await a.db.select(a.db.konversationen).get(), isEmpty, reason: 'nichts halb angelegt');
        // Familienchat: die erste Epoche geht an alle mit Schlüssel (ohne Dora)
        await a.repo.familienchatSicherstellen();
        await abgleich([a, b, c]);
        final fam = familienchatId(familieId);
        expect({for (final w in welt.alle('epoche_wrap')) w.fields['empfaengerId']}, {anna.id, ben.id, cora.id});
        // Dora richtet ihre Verschlüsselung ein: ein Teilnehmer mit Schlüssel legt die nächste Epoche an (mit Verlauf für die Neue)
        await senden(a, fam, 'Willkommen Dora', abgleichen: [a, b, c]);
        for (final g in [a, b, c]) {
          g.mitgliederLernen(alle);
        }
        final konv = await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(fam))).getSingle();
        final plan = await a.krypto.rotationNoetig(konversation: konv, teilnehmer: const {});
        expect(plan!.neu, {dora.id});
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: fam, mitglieder: plan.mitglieder, historieFuer: plan.neu));
        await abgleich([a, b, d]);
        expect((await lesbar(d, fam)), ['Willkommen Dora'], reason: 'Familienchat teilt den Verlauf mit neuen Mitgliedern');
      });

      test('Rotationsbedarf: Entfernte, Neue und neue vertrauenswürdige Schlüssel lösen aus, ein vollständiger Stand nicht', () async {
        final id = await gruppe(a, [b, c]);
        final konv = await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        final alle3 = {anna.id, ben.id, cora.id};
        expect(await a.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3), isNull);
        // jemand wurde aus der Familie entfernt: Cora ist nicht mehr aktiv
        a.karte = {for (final p in [anna, ben, dora]) p.id: p.oeffentlich};
        // ein einzelner Abruf ohne Cora löst nichts aus, erst der zweite in Folge
        expect(await a.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3), isNull);
        a.krypto.mitgliederBeobachtet();
        final r1 = await a.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3);
        expect(r1!.mitglieder, {anna.id, ben.id});
        expect(r1.entfernt, {cora.id});
        expect(r1.automatisch, isTrue);
        // ein Teilnehmer, der noch nicht in der Liste steht
        a.mitgliederLernen(alle);
        final r2 = await a.krypto.rotationNoetig(konversation: konv, teilnehmer: {...alle3, dora.id});
        expect(r2!.neu, {dora.id});
        expect(r2.automatisch, isFalse, reason: 'Neue bekommen den Schlüssel nur auf Bestätigung');
        // offline (Stand unbekannt): keine Rotation
        a.karte = null;
        expect(await a.krypto.rotationNoetig(konversation: konv, teilnehmer: {...alle3, dora.id}), isNull);
      });

      test('Ausgang ohne Deadlock: eine wartende Nachricht hält die eigene Rotation nicht auf; die Nachricht geht danach mit der neuen Epoche', () async {
        final id = await gruppe(a, [b]);
        final msg = (await a.repo.senden(id, 'wartet auf die Rotation'))!; // im Ausgang VOR der Epoche
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, ben.id}));
        final ausgang = [for (final o in await a.ausgang()) o.entity];
        expect(ausgang.indexOf('nachricht'), lessThan(ausgang.indexOf('epoche')), reason: 'die Nachricht steht vor der Epoche');
        await abgleich([a, b]);
        expect(welt.alle('epoche'), hasLength(2), reason: 'die Epoche ging trotz der wartenden Nachricht hinaus');
        final wire = welt.zeile('nachricht', msg)!.fields['text'] as String;
        expect(ChatKrypto.huellenEpoche(wire), 2, reason: 'die Nachricht wurde erst nach der Bestätigung gesendet, mit der neuen Epoche');
        expect(await text(b, id, msg), 'wartet auf die Rotation');
        expect((await a.ausgang()), isEmpty);
      });

      test('Ausgang nach Rotation neu verschlüsseln: eine schon mit der alten Epoche vorbereitete Nachricht geht mit der neuen hinaus', () async {
        final id = await gruppe(a, [b]);
        final msg = (await a.repo.senden(id, 'schon vorbereitet'))!;
        // vorbereitet (e1, Epoche 1), aber nicht abgesendet
        await a.store.naechsteOps(50, vorbereiter: a.vorbereiter);
        final vorbereitet = (await a.ausgang()).firstWhere((o) => o.entity == 'nachricht');
        expect(ChatKrypto.huellenEpoche((jsonDecode(vorbereitet.fieldsJson) as Map)['text'] as String), 1);
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, ben.id}));
        await abgleich([a, b]);
        expect(ChatKrypto.huellenEpoche(welt.zeile('nachricht', msg)!.fields['text'] as String), 2);
        expect(await text(b, id, msg), 'schon vorbereitet');
      });

      test('Neue Mitglieder: ein anderes Gerät rotiert nicht automatisch für sie (nur auf Bestätigung); Entfernen rotiert automatisch', () async {
        final id = await gruppe(a, [b]);
        // ein anderes Gerät (hier Bens) fügt Cora zur Teilnehmerliste hinzu, ohne den Schlüssel zu teilen
        await b.store.aendern('konversation', id, {'teilnehmer': [anna.id, ben.id, cora.id]});
        await abgleich([b, a, c]);
        final konv = await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        final plan = await a.krypto.rotationNoetig(konversation: konv, teilnehmer: {anna.id, ben.id, cora.id});
        expect(plan!.neu, {cora.id});
        expect(plan.automatisch, isFalse);
        expect(plan.automatischeMitglieder, {anna.id, ben.id}, reason: 'auch eine Rotation aus anderem Grund gibt den Schlüssel nicht an Neue');
        // Bestätigung: neue Epoche mit Cora
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: id, mitglieder: plan.mitglieder));
        await abgleich([a, b, c]);
        final nachher = await senden(a, id, 'jetzt mit Cora', abgleichen: [a, b, c]);
        expect(await text(c, id, nachher), 'jetzt mit Cora');
      });

      test('vergiftete Epoche: eine Epoche ohne gültige Wraps wird nach der Frist von einem Gerät mit Schlüssel durch eine neue ersetzt, der Chat heilt', () async {
        final id = await gruppe(b, [a, c]);
        await senden(b, id, 'vor der Vergiftung', abgleichen: [a, b, c]);
        // Cora (z. B. ein Kind) legt Epoche 2 an, ohne irgendeinen Wrap mitzuschicken
        final nurEpoche = [for (final x in await c.krypto.epocheErstellen(konversationId: id, mitglieder: {anna.id, ben.id, cora.id})) if (x.entity == 'epoche') x];
        await c.store.aendernMehrere(nurEpoche);
        await abgleich([c, a, b]);
        expect(a.krypto.schluessel(id, 2), isNull);
        final konv = await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        final alle3 = {anna.id, ben.id, cora.id};
        expect(await a.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3), isNull, reason: 'erst nach der Frist');
        a.jetzt = a.jetzt.add(ChatKrypto.heilungsFrist + const Duration(seconds: 1));
        final plan = await a.krypto.rotationNoetig(konversation: konv, teilnehmer: alle3);
        expect(plan!.heilung, isTrue);
        expect(plan.automatisch, isTrue);
        await a.store.aendernMehrere(await a.krypto.epocheErstellen(konversationId: id, mitglieder: plan.automatischeMitglieder));
        await abgleich([a, b, c]);
        final neu = await senden(a, id, 'geheilt', abgleichen: [a, b, c]);
        expect(await text(b, id, neu), 'geheilt');
        expect(await text(c, id, neu), 'geheilt');
        expect(a.krypto.epochenMitSchluessel(id), contains(3));
      });

      test('verlorene Wraps: der Verteiler erzeugt sie nach der Wartezeit erneut, nur einmal je Sitzung', () async {
        final id = await a.repo.direktChat(ben.id);
        // der Wrap für Ben geht verloren (z. B. abgelehnt): lokal und im Ausgang weg
        await a.db.customStatement("DELETE FROM epoche_wraps WHERE empfaenger_id = '${ben.id}'");
        await a.db.customStatement("DELETE FROM outbox WHERE entity = 'epoche_wrap' AND fields_json LIKE '%${ben.id}%'");
        await abgleich([a, b]);
        expect(await a.krypto.fehlendeWraps(id), isEmpty, reason: 'erst nach der Wartezeit');
        a.jetzt = a.jetzt.add(ChatKrypto.wrapFrist + const Duration(seconds: 1));
        final fehlt = await a.krypto.fehlendeWraps(id);
        expect(fehlt, [ben.id]);
        await a.store.aendernMehrere(await a.krypto.wrapsNachreichen(id, fehlt));
        await abgleich([a, b]);
        expect(await a.krypto.fehlendeWraps(id), isEmpty, reason: 'nur einmal je Sitzung');
        final n = await senden(a, id, 'jetzt kommt es an', abgleichen: [a, b]);
        expect(await text(b, id, n), 'jetzt kommt es an');
      });

      test('Schlüssel im Speicher gehen mit, wenn Epoche oder Wrap lokal verschwinden', () async {
        final id = await gruppe(a, [b]);
        expect(b.krypto.schluessel(id, 1), isNotNull);
        await b.db.customStatement('DELETE FROM epoche_wraps');
        await b.krypto.aktualisieren();
        expect(b.krypto.schluessel(id, 1), isNull);
      });

      test('Absender nicht bestätigt: ein Signaturschlüssel in einer Version, die dieses Gerät nie gemerkt hat, gilt nicht (kein Nachladen vom Server)', () async {
        final id = await gruppe(a, [b]);
        final m = await senden(a, id, 'echt signiert', abgleichen: [a, b]);
        // Ben kennt Annas Schlüssel nur in einer anderen Version
        b.tofu[anna.id] = anna.pk.oeffentlich(2);
        expect(await text(b, id, m), '<Absender nicht bestätigt>');
      });

      test('Anzeige: eigene, schon bestätigte Nachricht mit l1: ist "wird gesendet", nicht "unverschlüsselt"', () async {
        final inhalt = E2eeNachrichtenInhalt(krypto: () async => null, encVersion: (_) async => 'e1', ich: () => anna.id, lokaleIds: () => <String>{}, beiAenderung: () {});
        final eigene = Nachricht(id: 'n1', konversationId: 'k', autorId: anna.id, inhalt: 'l1:x', antwortAuf: null, bearbeitetAt: null, createdAt: a.jetzt, rev: 3);
        expect(inhalt.nachricht(eigene).hinweis, 'wird gesendet');
        final fremde = Nachricht(id: 'n2', konversationId: 'k', autorId: ben.id, inhalt: 'l1:x', antwortAuf: null, bearbeitetAt: null, createdAt: a.jetzt, rev: 3);
        expect(inhalt.nachricht(fremde).hinweis, 'unverschlüsselt');
      });

      test('Entschlüsselte Nachrichten im Speicher sind begrenzt; Fehlschläge werden bei neuem Vertrauen vergessen', () async {
        final inhalt = E2eeNachrichtenInhalt(krypto: () async => null, encVersion: (_) async => 'e1', ich: () => anna.id, lokaleIds: () => <String>{}, beiAenderung: () {});
        for (var i = 0; i < E2eeNachrichtenInhalt.maxCache + 100; i++) {
          inhalt.nachricht(Nachricht(id: 'n$i', konversationId: 'k', autorId: ben.id, inhalt: 'e1:AAAA$i', antwortAuf: null, bearbeitetAt: null, createdAt: a.jetzt, rev: 1));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(inhalt.cacheGroesse, lessThanOrEqualTo(E2eeNachrichtenInhalt.maxCache));
        expect(inhalt.cacheGroesse, greaterThan(0));
        inhalt.fehlschlaegeVergessen();
        expect(inhalt.cacheGroesse, 0, reason: 'alles war nicht lesbar (keine Verschlüsselung bereit): nach neuem Vertrauen wird erneut versucht');
      });

      test('erste Epoche: nur für Konversationen ohne Epoche und erst nach der Karenz', () async {
        final id = 'bbbbbbbb-0000-4000-8000-0000000000b9';
        await a.store.aendern('konversation', id, {'art': 'group', 'encVersion': 'e1', 'teilnehmer': [anna.id, ben.id]}, nurLokal: {'createdAt': a.jetzt.toIso8601String(), 'ownerId': anna.id});
        await a.db.customStatement('UPDATE konversationen SET rev = 1');
        final konv = await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(id))).getSingle();
        expect(await a.krypto.ersteEpocheNoetig(konversation: konv, teilnehmer: {anna.id, ben.id}), isNull, reason: 'der Ersteller hat noch Zeit');
        a.jetzt = a.jetzt.add(ChatKrypto.karenz + const Duration(seconds: 1));
        expect(await a.krypto.ersteEpocheNoetig(konversation: konv, teilnehmer: {anna.id, ben.id}), {anna.id, ben.id});
      });

      test('Altbestand ohne Verschlüsselung (p1): lesbar, aber nichts Neues; Klartext in e1-Chats wird nie angezeigt', () async {
        // Konversation als Klartext-Chat vom Server
        await a.store.uebernehmen(
          welt.antwortMit([
            ('konversation', 'bbbbbbbb-0000-4000-8000-0000000000aa', {'art': 'group', 'encVersion': 'p1', 'titel': '', 'teilnehmer': [anna.id, ben.id], 'ownerId': anna.id, 'createdAt': a.jetzt.toIso8601String()}),
            ('nachricht', 'a0000000-0000-4000-8000-0000000000a1', {'konversationId': 'bbbbbbbb-0000-4000-8000-0000000000aa', 'text': 'p1:alt und lesbar', 'autorId': ben.id, 'createdAt': a.jetzt.toIso8601String()}),
          ]),
          const [],
        );
        await expectLater(a.repo.senden('bbbbbbbb-0000-4000-8000-0000000000aa', 'neu'), throwsA(isA<ChatNichtVerschluesselt>()));
        final inhalt = E2eeNachrichtenInhalt(
          krypto: () async => a.krypto,
          encVersion: (id) async => (await (a.db.select(a.db.konversationen)..where((k) => k.id.equals(id))).getSingleOrNull())?.encVersion,
          ich: () => anna.id,
          lokaleIds: () => <String>{},
          beiAenderung: () {},
        );
        final n = (await a.nachrichten('bbbbbbbb-0000-4000-8000-0000000000aa')).single;
        inhalt.nachricht(n); // startet das Öffnen
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(inhalt.nachricht(n).text, 'alt und lesbar');
      });

      test('Anzeige: l1: nur für eigene Nachrichten, die der Ausgang kennt; p1: in e1-Chats nie; Entschlüsselung im Hintergrund', () async {
        final id = await a.repo.direktChat(ben.id);
        await abgleich([a, b]);
        final m = await senden(a, id, 'Hintergrund', abgleichen: [a, b]);
        var geaendert = 0;
        Set<String>? lokal = <String>{};
        final inhalt = E2eeNachrichtenInhalt(
          krypto: () async => b.krypto,
          encVersion: (k) async => 'e1',
          ich: () => ben.id,
          lokaleIds: () => lokal,
          beiAenderung: () => geaendert++,
        );
        final n = (await b.nachrichten(id)).firstWhere((x) => x.id == m);
        expect(inhalt.nachricht(n).status, InhaltStatus.wirdEntschluesselt);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(geaendert, 1);
        expect(inhalt.nachricht(n).text, 'Hintergrund');
        // Klartext l1: von einem Fremden oder ohne Eintrag im Ausgang zeigt nie Text
        final fremd = Nachricht(id: 'x', konversationId: id, autorId: anna.id, inhalt: 'l1:Fälschung', antwortAuf: null, bearbeitetAt: null, createdAt: DateTime.now(), rev: 5);
        expect(inhalt.nachricht(fremd).lesbar, isFalse);
        final eigen = Nachricht(id: 'y', konversationId: id, autorId: ben.id, inhalt: 'l1:eigen', antwortAuf: null, bearbeitetAt: null, createdAt: DateTime.now(), rev: 5);
        expect(inhalt.nachricht(eigen).lesbar, isFalse, reason: 'bestätigte Nachricht ohne Eintrag im Ausgang');
        lokal = {'y'};
        expect(inhalt.nachricht(eigen).text, 'eigen');
        lokal = null;
        expect(inhalt.nachricht(eigen).status, InhaltStatus.wirdEntschluesselt);
        final p1 = Nachricht(id: 'z', konversationId: id, autorId: anna.id, inhalt: 'p1:Klartext', antwortAuf: null, bearbeitetAt: null, createdAt: DateTime.now(), rev: 5);
        inhalt.nachricht(p1);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(inhalt.nachricht(p1).lesbar, isFalse);
        expect(inhalt.nachricht(p1).text, isEmpty);
      });

      test('Länge: mehr als 8000 Byte werden nicht gesendet (Emoji zählen mit ihren Bytes)', () async {
        final id = await a.repo.direktChat(ben.id);
        await expectLater(a.repo.senden(id, '👨‍👩‍👧‍👦' * 400), throwsA(isA<NachrichtZuLang>()));
        expect(await a.repo.senden(id, 'ä' * 3900), isNotNull);
        await abgleich([a, b]);
        // die Hülle bleibt unter der Obergrenze des Servers (16 384 Zeichen)
        expect((welt.alle('nachricht').single.fields['text'] as String).length, lessThan(16384));
      });

      test('Wrap und Liste decken Konversation, Epoche und Person ab: ein Wrap für einen anderen Empfänger öffnet nicht', () async {
        final id = await gruppe(a, [b, c]);
        // Server legt Coras Wrap in Bens Zeile
        final bens = welt.alle('epoche_wrap').firstWhere((w) => w.fields['empfaengerId'] == ben.id);
        final coras = welt.alle('epoche_wrap').firstWhere((w) => w.fields['empfaengerId'] == cora.id);
        final echt = bens.fields['wrap'];
        bens.fields['wrap'] = coras.fields['wrap'];
        final b2 = neuesGeraet(ben, name: 'Ben-Neu');
        await abgleich([b2]);
        expect(b2.krypto.schluessel(id, 1), isNull);
        bens.fields['wrap'] = echt;
      });

      test('Transportformen sind stabil: EpochenWrap und signierte Liste lassen sich lesen (Format-Regression)', () async {
        final id = await gruppe(a, [b]);
        final w = EpochenWrap.dekodieren(welt.alle('epoche_wrap').firstWhere((x) => x.fields['empfaengerId'] == ben.id).fields['wrap'] as String);
        expect(w.conversationId, id);
        expect(w.epoch, 1);
        expect(w.verteilerId, anna.id);
        final l = SignierteMitgliederListe.dekodieren(welt.zeile('epoche', epocheId(id, 1))!.fields['mitglieder'] as String);
        expect([for (final m in l.liste.mitglieder) m.userId], [anna.id, ben.id]..sort());
        expect(() => EpochenWrap.dekodieren('kaputt'), throwsA(isA<CryptoFehler>()));
      });
    });
  }
}
