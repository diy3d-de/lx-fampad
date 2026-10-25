// Dateiablage, Datenschicht: DateiRepository gegen den Fake-Server mit den Regeln des echten (Freigabe-Invariante, Tiefe, Zyklus, Löschen nur leer, Rechte nach Rolle). Geprüft: Stapel in der richtigen
// Reihenfolge (Kinder zuerst umstellen, von unten nach oben löschen: der Server lehnt nichts ab), Verschieben mit Zyklus- und Tiefenprüfung, Kinder dürfen nur Eigenes, zwei Geräte gleichen ab.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/dateien/datei_modelle.dart';

import 'support/datei_geraet.dart';
import 'support/datei_welt.dart';
import 'support/fake_server.dart';
import 'support/fake_sync_server.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeServer server;
  late FakeSyncServer sync;
  late FakeDateien welt;
  late DateiGeraet mama; // Elternteil
  late DateiGeraet papa; // Admin, zweites Gerät
  late DateiGeraet emil; // Kind

  setUp(() async {
    server = FakeServer();
    sync = FakeSyncServer();
    welt = FakeDateien(server, sync);
    mama = await DateiGeraet.neu(server, welt, person: 'mama', rolle: Role.parent);
    papa = await DateiGeraet.neu(server, welt, person: 'papa', rolle: Role.admin);
    emil = await DateiGeraet.neu(server, welt, person: 'emil', rolle: Role.child);
  });

  Future<void> alleAbgleichen() async {
    for (var i = 0; i < 2; i++) {
      for (final g in [mama, papa, emil]) {
        await g.abgleich();
      }
    }
  }

  /// Legt eine Datei samt Fassung mit einem schon fertigen Blob an (der Upload ist hier nicht das Thema): der Fake-Server beansprucht ihn.
  Future<String> datei(DateiGeraet g, String name, {String? ordnerId, String audience = 'family', int groesse = 10}) async {
    final up = welt.blobs.length + 1;
    final blobId = '${up.toString().padLeft(8, '0')}-aaaa-4000-8000-000000000000';
    welt.blobs[blobId] = FakeBlob(blobId, 'server', 'datei', null, groesse, g.person)
      ..zustand = 'ready'
      ..sha256 = 'abcd'
      ..daten.add(List.filled(groesse, 1));
    final dateiId = '${blobId.substring(0, 8)}-bbbb-4000-8000-000000000000';
    final versionId = '${blobId.substring(0, 8)}-cccc-4000-8000-000000000000';
    await g.repo.dateiMitFassungAnlegen(dateiId: dateiId, versionId: versionId, name: name, ordnerId: ordnerId, audience: audience, blobId: blobId, groesse: groesse, mime: 'text/plain');
    return dateiId;
  }

  group('Ordner', () {
    test('anlegen, umbenennen, Unterordner; ein zweites Gerät sieht alles, der Besitzer ist die anlegende Person', () async {
      final a = await mama.repo.ordnerAnlegen(name: '  Urlaub  ');
      final b = await mama.repo.ordnerAnlegen(name: 'Italien', parentId: a);
      await mama.repo.ordnerUmbenennen(b, 'Toskana');
      expect((await mama.o(a))!.name, 'Urlaub');
      expect((await mama.o(a))!.ownerId, mama.person);
      expect((await mama.o(a))!.rev, 0); // noch nicht bestätigt
      await alleAbgleichen();
      expect((await papa.o(b))!.name, 'Toskana');
      expect((await papa.o(b))!.parentId, a);
      expect((await papa.o(a))!.ownerId, mama.person);
      expect((await papa.o(a))!.rev, greaterThan(0));
      expect(mama.geaendert, 3);
    });

    test('ungültige Namen und zu tiefe Ordner werden nie geschrieben', () async {
      await expectLater(mama.repo.ordnerAnlegen(name: 'a/b'), throwsA(DateiFehler.nameUngueltig));
      await expectLater(mama.repo.ordnerAnlegen(name: '..'), throwsA(DateiFehler.nameUngueltig));
      expect(await mama.ausgang(), isEmpty);
      String? eltern;
      for (var i = 1; i <= 6; i++) {
        eltern = await mama.repo.ordnerAnlegen(name: 'E$i', parentId: eltern);
      }
      await expectLater(mama.repo.ordnerAnlegen(name: 'E7', parentId: eltern), throwsA(DateiFehler.zuTief));
      expect((await mama.ordner()), hasLength(6));
      await mama.abgleich(); // der Server nimmt die sechs Ebenen an
    });

    test('ein für alle sichtbarer Ordner liegt nicht in einem Ordner nur für Eltern', () async {
      final e = await mama.repo.ordnerAnlegen(name: 'Eltern', audience: kStufeEltern);
      await expectLater(mama.repo.ordnerAnlegen(name: 'Alle', parentId: e), throwsA(DateiFehler.stufeFamilieNurInFamilie));
      final ok = await mama.repo.ordnerAnlegen(name: 'Nur Eltern innen', parentId: e, audience: kStufeEltern);
      await alleAbgleichen();
      expect((await papa.o(ok)), isNotNull);
    });

    test('Verschieben: nie in sich selbst oder einen Unterordner, nie tiefer als 6 Ebenen', () async {
      final a = await mama.repo.ordnerAnlegen(name: 'A');
      final b = await mama.repo.ordnerAnlegen(name: 'B', parentId: a);
      final c = await mama.repo.ordnerAnlegen(name: 'C', parentId: b);
      await expectLater(mama.repo.ordnerVerschieben(a, a), throwsA(DateiFehler.zyklus));
      await expectLater(mama.repo.ordnerVerschieben(a, c), throwsA(DateiFehler.zyklus));
      await expectLater(mama.repo.ordnerVerschieben(b, c), throwsA(DateiFehler.zyklus));
      // tief: eine Kette aus 5 Ebenen, A (mit B und C darunter = Höhe 2) darunter hängen ergibt 5 + 3 = 8
      String? t;
      for (var i = 0; i < 5; i++) {
        t = await mama.repo.ordnerAnlegen(name: 'T$i', parentId: t);
      }
      await expectLater(mama.repo.ordnerVerschieben(a, t), throwsA(DateiFehler.zuTief));
      // flach geht es: C nach oben, B nach C
      await mama.repo.ordnerVerschieben(c, null);
      await mama.repo.ordnerVerschieben(b, c);
      expect((await mama.o(b))!.parentId, c);
      expect((await mama.o(c))!.parentId, isNull);
      await mama.abgleich();
    });

    test('Verschieben nach oben ist immer erlaubt, ein Ordner für alle nicht in einen für Eltern', () async {
      final e = await mama.repo.ordnerAnlegen(name: 'Eltern', audience: kStufeEltern);
      final a = await mama.repo.ordnerAnlegen(name: 'A');
      await expectLater(mama.repo.ordnerVerschieben(a, e), throwsA(DateiFehler.stufeFamilieNurInFamilie));
      final inE = await mama.repo.ordnerAnlegen(name: 'Innen', parentId: e, audience: kStufeEltern);
      await mama.repo.ordnerVerschieben(inE, null); // nach oben
      expect((await mama.o(inE))!.parentId, isNull);
      await alleAbgleichen();
    });
  });

  group('Freigabestufe: Kinder zuerst umstellen', () {
    test('ein Ordner auf `parents`: der Stapel stellt zuerst alles darunter um, der Server lehnt nichts ab', () async {
      final a = await mama.repo.ordnerAnlegen(name: 'A');
      final b = await mama.repo.ordnerAnlegen(name: 'B', parentId: a);
      final c = await mama.repo.ordnerAnlegen(name: 'C', parentId: b, audience: kStufeEltern);
      final f1 = await datei(mama, 'f1.txt', ordnerId: b);
      final f2 = await datei(mama, 'f2.txt', ordnerId: a);
      final f3 = await datei(mama, 'f3.txt', ordnerId: c, audience: kStufeEltern);
      await mama.abgleich();
      expect(welt.sync.zeilen.values.where((z) => z.entity == 'ordner' && z.fields['audience'] == 'family'), hasLength(2));
      final vorher = (await mama.ausgang()).length;
      await mama.repo.ordnerStufeAendern(a, kStufeEltern);
      final neu = (await mama.ausgang()).skip(vorher).toList();
      // Reihenfolge: zuerst die Dateien und Unterordner von unten, der Ordner selbst zuletzt
      final ids = [for (final o in neu) o.entityId];
      expect(ids.last, a);
      expect(ids.indexOf(f1), lessThan(ids.indexOf(b)));
      expect(ids.indexOf(b), lessThan(ids.indexOf(a)));
      expect(ids.indexOf(f2), lessThan(ids.indexOf(a)));
      expect(ids, isNot(contains(c))); // schon `parents`
      expect(ids, isNot(contains(f3)));
      await mama.abgleich(); // der Fake-Server (Invariante wie der echte) lehnt keinen Schritt ab
      for (final id in [a, b, c]) {
        expect(welt.sync.zeilen['ordner/$id']!.fields['audience'], 'parents');
      }
      for (final id in [f1, f2, f3]) {
        expect(welt.sync.zeilen['datei/$id']!.fields['audience'], 'parents');
      }
      // das Kind sieht danach nichts mehr (lokale Sicht): die Zeilen sind `parents`
      await emil.abgleich();
      final sichtbar = await emil.repo.alleOrdner().first;
      expect(sichtbar.where((o) => o.audience == 'parents'), isEmpty);
    });

    test('die Gegenprobe: ohne Umstellen der Kinder lehnt der Server das Setzen auf `parents` ab (so wie der echte)', () async {
      final a = await mama.repo.ordnerAnlegen(name: 'A');
      await datei(mama, 'f.txt', ordnerId: a);
      await mama.abgleich();
      await mama.store.aendern('ordner', a, {'audience': kStufeEltern}); // am Repository vorbei
      final r = await mama.engine.abgleichen();
      expect(r.hinweise, isNotEmpty);
      expect(welt.sync.zeilen['ordner/$a']!.fields['audience'], 'family');
    });

    test('auf `family` nur oben oder in einem `family`-Ordner', () async {
      final e = await mama.repo.ordnerAnlegen(name: 'Eltern', audience: kStufeEltern);
      final innen = await mama.repo.ordnerAnlegen(name: 'Innen', parentId: e, audience: kStufeEltern);
      await expectLater(mama.repo.ordnerStufeAendern(innen, kStufeFamilie), throwsA(DateiFehler.stufeFamilieNurInFamilie));
      await mama.repo.ordnerStufeAendern(e, kStufeFamilie); // oben: ok
      await mama.repo.ordnerStufeAendern(innen, kStufeFamilie); // jetzt in einem family-Ordner: ok
      expect((await mama.o(innen))!.audience, kStufeFamilie);
      await mama.abgleich();
    });

    test('Dateien: auf `family` nur oben oder in einem `family`-Ordner; Kinder ändern die Stufe nie', () async {
      final e = await mama.repo.ordnerAnlegen(name: 'Eltern', audience: kStufeEltern);
      final f = await datei(mama, 'geheim.txt', ordnerId: e, audience: kStufeEltern);
      await expectLater(mama.repo.dateiStufeAendern(f, kStufeFamilie), throwsA(DateiFehler.stufeFamilieNurInFamilie));
      await mama.repo.dateiVerschieben(f, null);
      await mama.repo.dateiStufeAendern(f, kStufeFamilie);
      expect((await mama.d(f))!.audience, kStufeFamilie);
      await alleAbgleichen();
      await expectLater(emil.repo.dateiStufeAendern(f, kStufeEltern), throwsA(DateiFehler.nichtErlaubt));
    });

    test('Dateien verschieben: Ziel muss sichtbar sein und zur Stufe passen', () async {
      final e = await mama.repo.ordnerAnlegen(name: 'Eltern', audience: kStufeEltern);
      final fam = await mama.repo.ordnerAnlegen(name: 'Alle');
      final f = await datei(mama, 'a.txt');
      await expectLater(mama.repo.dateiVerschieben(f, e), throwsA(DateiFehler.stufeFamilieNurInFamilie));
      await mama.repo.dateiVerschieben(f, fam);
      expect((await mama.d(f))!.ordnerId, fam);
      await expectLater(mama.repo.dateiVerschieben(f, 'gibt-es-nicht'), throwsA(DateiFehler.nichtGefunden));
      await alleAbgleichen();
    });
  });

  group('Löschen: von unten nach oben', () {
    test('ein nicht leerer Ordner lässt sich nicht einfach löschen, ein leerer schon', () async {
      final a = await mama.repo.ordnerAnlegen(name: 'A');
      final b = await mama.repo.ordnerAnlegen(name: 'B', parentId: a);
      await expectLater(mama.repo.ordnerLoeschen(a), throwsA(DateiFehler.nichtLeer));
      await mama.repo.ordnerLoeschen(b);
      await mama.repo.ordnerLoeschen(a);
      expect(await mama.ordner(), isEmpty);
      await alleAbgleichen();
      expect(await papa.ordner(), isEmpty);
    });

    test('Ordner mit Inhalt: Dateien, Unterordner, Ordner in dieser Reihenfolge; der Server (Löschen nur leer) lehnt nichts ab', () async {
      final a = await mama.repo.ordnerAnlegen(name: 'A');
      final b = await mama.repo.ordnerAnlegen(name: 'B', parentId: a);
      final c = await mama.repo.ordnerAnlegen(name: 'C', parentId: b);
      final f1 = await datei(mama, 'f1.txt', ordnerId: a);
      final f2 = await datei(mama, 'f2.txt', ordnerId: c);
      await mama.abgleich();
      final vorher = (await mama.ausgang()).length;
      final n = await mama.repo.ordnerMitInhaltLoeschen(a);
      expect(n, 5);
      final ops = (await mama.ausgang()).skip(vorher).toList();
      expect(ops.every((o) => o.op == 'delete'), isTrue);
      final ids = [for (final o in ops) o.entityId];
      expect(ids.indexOf(f2), lessThan(ids.indexOf(c)));
      expect(ids.indexOf(c), lessThan(ids.indexOf(b)));
      expect(ids.indexOf(b), lessThan(ids.indexOf(a)));
      expect(ids.indexOf(f1), lessThan(ids.indexOf(a)));
      expect(await mama.ordner(), isEmpty);
      expect(await mama.dateien(), isEmpty);
      expect(await mama.versionen(), isEmpty); // Kaskade: die Fassungen verschwinden mit der Datei
      final r = await mama.engine.abgleichen();
      expect(r.hinweise, isEmpty);
      expect(welt.sync.zeilen.values.where((z) => !z.geloescht && const {'ordner', 'datei', 'datei_version'}.contains(z.entity)), isEmpty);
      await papa.abgleich();
      expect(await papa.ordner(), isEmpty);
      expect(await papa.dateien(), isEmpty);
    });

    test('Datei löschen: lokal sofort samt Fassungen, auf dem zweiten Gerät nach dem Abgleich', () async {
      final f = await datei(mama, 'a.txt');
      await alleAbgleichen();
      expect(await papa.versionen(), hasLength(1));
      await mama.repo.dateiLoeschen(f);
      expect(await mama.dateien(), isEmpty);
      expect(await mama.versionen(), isEmpty);
      await alleAbgleichen();
      expect(await papa.dateien(), isEmpty);
      expect(await papa.versionen(), isEmpty);
    });

    test('eine nie bestätigte Datei verschwindet spurlos (ohne Löschauftrag)', () async {
      final f = await datei(mama, 'a.txt');
      await mama.repo.dateiLoeschen(f);
      expect((await mama.ausgang()).where((o) => o.op == 'delete'), isEmpty);
      expect((await mama.ausgang()).where((o) => o.op == 'upsert'), isEmpty);
    });
  });

  group('Datei mit Fassung, Fassungen, Lesen', () {
    test('Datei und erste Fassung kommen in EINEM Stapel in der Reihenfolge Datei, Fassung; Größe, Typ und Prüfsumme setzt der Server', () async {
      final f = await datei(mama, 'Rechnung.txt', groesse: 1234);
      final ops = await mama.ausgang();
      expect([for (final o in ops) o.entity], ['datei', 'datei_version']);
      expect(ops[1].fieldsJson, contains('"nr":1'));
      expect(ops[1].fieldsJson, isNot(contains('size'))); // lokal gesetzt, nicht gesendet
      await mama.abgleich();
      final v = (await mama.versionen()).single;
      expect(v.size, 1234);
      expect(v.sha256, 'abcd');
      expect(v.rev, greaterThan(0));
      expect((await mama.repo.eintrag(f))!.groesse, 1234);
    });

    test('neue Fassung: nächste Nummer, die neueste bestimmt Größe und Typ', () async {
      final f = await datei(mama, 'a.txt', groesse: 5);
      await alleAbgleichen();
      final blob = '00000099-aaaa-4000-8000-000000000000';
      welt.blobs[blob] = FakeBlob(blob, 'server', 'datei', 'text/plain', 7, mama.person)
        ..zustand = 'ready'
        ..sha256 = 'ef'
        ..daten.add(List.filled(7, 2));
      final nr = await mama.repo.fassungAnlegen(dateiId: f, versionId: '00000099-cccc-4000-8000-000000000000', blobId: blob, groesse: 7, mime: 'text/plain');
      expect(nr, 2);
      await alleAbgleichen();
      final e = (await papa.repo.eintrag(f))!;
      expect(e.fassungen, 2);
      expect(e.neueste!.nr, 2);
      expect(e.groesse, 7);
      final liste = await papa.repo.versionen(f).first;
      expect(liste.map((v) => v.nr), [2, 1]);
    });

    test('dateienIn: nach Namen, mit neuester Fassung, nur die Dateien dieses Ordners', () async {
      final o = await mama.repo.ordnerAnlegen(name: 'O');
      await datei(mama, 'b.txt', ordnerId: o);
      await datei(mama, 'a.txt', ordnerId: o);
      await datei(mama, 'oben.txt');
      expect((await mama.repo.dateienIn(o).first).map((e) => e.name), ['a.txt', 'b.txt']);
      expect((await mama.repo.dateienIn(null).first).map((e) => e.name), ['oben.txt']);
      expect((await mama.repo.ordnerIn(null).first).map((x) => x.name), ['O']);
    });

    test('Datei ohne Fassung (Upload fehlgeschlagen) erscheint als solche und lässt sich entfernen; mit Fassung bleibt sie', () async {
      await mama.store.aendern('datei', 'x1', {'ordnerId': null, 'name': 'leer.txt', 'audience': 'family'}, nurLokal: {'createdAt': '2026-10-24T09:00:00.000Z', 'ownerId': mama.person});
      expect((await mama.repo.eintrag('x1'))!.ohneFassung, isTrue);
      expect(await mama.repo.verwaisteDateiEntfernen('x1'), isTrue);
      expect(await mama.dateien(), isEmpty);
      final f = await datei(mama, 'ok.txt');
      expect(await mama.repo.verwaisteDateiEntfernen(f), isFalse);
      expect(await mama.dateien(), hasLength(1));
    });

    test('mehr als 100 Fassungen werden abgelehnt', () async {
      final f = await datei(mama, 'a.txt');
      for (var i = 2; i <= 100; i++) {
        await mama.store.aendern('datei_version', 'v$i', {'dateiId': f, 'nr': i, 'blobId': 'b$i', 'thumbBlobId': null}, nurLokal: {'createdAt': '2026-10-24T09:00:00.000Z'});
      }
      await expectLater(mama.repo.fassungAnlegen(dateiId: f, versionId: 'v101', blobId: 'b101', groesse: 1), throwsA(DateiFehler.zuVieleFassungen));
    });
  });

  group('Kinder', () {
    test('ein Kind sieht nur `family`, legt nur `family` an und ändert und löscht nur Eigenes', () async {
      final eltern = await mama.repo.ordnerAnlegen(name: 'Steuer', audience: kStufeEltern);
      final alle = await mama.repo.ordnerAnlegen(name: 'Familie');
      final fremd = await datei(mama, 'mama.txt', ordnerId: alle);
      await alleAbgleichen();
      // Sicht: der Parents-Ordner ist für das Kind unsichtbar (lokal gefiltert, auch wenn er in der Datenbank wäre)
      final sicht = await emil.repo.alleOrdner().first;
      expect(sicht.map((o) => o.id), isNot(contains(eltern)));
      await expectLater(emil.repo.ordnerAnlegen(name: 'Heimlich', audience: kStufeEltern), throwsA(DateiFehler.nichtErlaubt));
      final eigen = await emil.repo.ordnerAnlegen(name: 'Meine Bilder', parentId: alle);
      await emil.repo.ordnerUmbenennen(eigen, 'Bilder');
      await expectLater(emil.repo.ordnerUmbenennen(alle, 'Meins'), throwsA(DateiFehler.nichtErlaubt));
      await expectLater(emil.repo.dateiUmbenennen(fremd, 'x.txt'), throwsA(DateiFehler.nichtErlaubt));
      await expectLater(emil.repo.dateiLoeschen(fremd), throwsA(DateiFehler.nichtErlaubt));
      await expectLater(emil.repo.ordnerLoeschen(alle), throwsA(DateiFehler.nichtErlaubt));
      await expectLater(emil.repo.ordnerStufeAendern(eigen, kStufeEltern), throwsA(DateiFehler.nichtErlaubt));
      await expectLater(emil.repo.ordnerMitInhaltLoeschen(eigen), throwsA(DateiFehler.nichtErlaubt));
      final eigenDatei = await datei(emil, 'emil.txt', ordnerId: eigen);
      await alleAbgleichen();
      expect((await mama.o(eigen))!.name, 'Bilder'); // der Server hat es angenommen
      expect((await mama.d(eigenDatei))!.ownerId, emil.person);
      await emil.repo.dateiLoeschen(eigenDatei);
      await emil.repo.ordnerLoeschen(eigen);
      await alleAbgleichen();
      expect(await mama.o(eigen), isNull);
    });

    test('ein Kind legt Fassungen nur für eigene Dateien an', () async {
      final fremd = await datei(mama, 'mama.txt');
      final eigen = await datei(emil, 'emil.txt');
      await alleAbgleichen();
      await expectLater(emil.repo.fassungAnlegen(dateiId: fremd, versionId: 'v-x', blobId: 'b', groesse: 1), throwsA(DateiFehler.nichtErlaubt));
      final nr = await emil.repo.fassungAnlegen(dateiId: eigen, versionId: '00000077-cccc-4000-8000-000000000000', blobId: '00000077-aaaa-4000-8000-000000000000', groesse: 1);
      expect(nr, 2);
    });

    test('ein Kind legt keine Datei der Stufe `parents` an', () async {
      await expectLater(datei(emil, 'x.txt', audience: kStufeEltern), throwsA(DateiFehler.nichtErlaubt));
      expect(await emil.dateien(), isEmpty);
    });
  });

  group('Registrierung der Entitäten', () {
    test('Entitäten im Register des Clients', () {
      final g = mama;
      expect(g.store.entitaeten.keys, containsAll(['ordner', 'datei', 'datei_version', 'tresor_anhang']));
      expect(g.store.entitaeten['datei']!.kinder.single.entity, 'datei_version');
      expect(g.store.entitaeten['konversation']!.kinder.map((k) => k.entity), contains('tresor_anhang'));
    });
  });
}
