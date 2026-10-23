// Einkaufsliste in der Oberfläche: Gruppen nach Gang, Kategorie beim Anlegen und im Blatt, "Zuletzt gekauft", Vorlagen, Layout 360 px/Textskala 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/features/lists/list_dialogs.dart';

import 'support/harness.dart';
import 'support/test_app.dart';

const _l1 = '11111111-1111-4111-8111-111111111111';
const _l2 = '11111111-1111-4111-8111-222222222222';

Finder eingabe(String hinweis) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hinweis);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  var n = 0;
  // Der Stand kommt vom Fake-Server (wie bei den Listen-Tests): so kennt der Server die Datensätze und lehnt Änderungen der Oberfläche nicht ab.
  Future<void> liste(TestUmgebung env, String id, String name, {String kind = 'shopping'}) async {
    env.sync.andereAendert('list', id, {'name': name, 'kind': kind, 'audience': 'family'});
  }

  Future<void> eintrag(TestUmgebung env, String listId, String text, {String? kategorie, DateTime? erledigt, double position = 0}) async {
    env.sync.andereAendert('list_item', '33333333-3333-4333-8333-${(++n).toString().padLeft(12, '0')}', {
      'listId': listId,
      'text': text,
      'position': position,
      'category': kategorie,
      'doneAt': erledigt?.toUtc().toIso8601String(),
    });
  }

  Future<TestUmgebung> start(WidgetTester tester, {double skala = 1.0, String role = 'admin', Future<void> Function(TestUmgebung env)? vorher}) async {
    final env = await angemeldeteUmgebung(role: role);
    await vorher?.call(env);
    await starteApp(tester, env, skala: skala);
    await zumBereich(tester, 'Listen');
    return env;
  }

  double oben(WidgetTester tester, Finder f) => tester.getTopLeft(f.first).dy;

  testWidgets('Einkaufsliste: offene Einträge stehen unter ihrer Kategorie in Gang-Reihenfolge, Erledigte darunter; eigene Listen bleiben ungruppiert', (tester) async {
    await start(
      tester,
      vorher: (env) async {
        await liste(env, _l1, 'Einkauf');
        await liste(env, _l2, 'Notizen', kind: 'custom');
        await eintrag(env, _l1, 'Wasser', kategorie: 'getraenke');
        await eintrag(env, _l1, 'Zeitung');
        await eintrag(env, _l1, 'Äpfel', kategorie: 'obst_gemuese');
        await eintrag(env, _l1, 'Eis', kategorie: 'tiefkuehl', erledigt: DateTime(2026, 10, 18));
        await eintrag(env, _l2, 'Etwas', kategorie: 'obst_gemuese');
      },
    );
    await warte(tester);
    final obst = oben(tester, find.text('OBST UND GEMÜSE'));
    final getraenke = oben(tester, find.text('GETRÄNKE'));
    final sonstiges = oben(tester, find.text('SONSTIGES'));
    final erledigt = oben(tester, find.text('ERLEDIGT'));
    expect(obst, lessThan(getraenke));
    expect(getraenke, lessThan(sonstiges));
    expect(sonstiges, lessThan(erledigt));
    expect(oben(tester, find.text('Äpfel')), greaterThan(obst));
    expect(oben(tester, find.text('Äpfel')), lessThan(getraenke));
    expect(oben(tester, find.text('Eis')), greaterThan(erledigt));
    expect(find.text('TIEFKÜHL'), findsNothing, reason: 'Kategorien ohne offene Einträge entfallen');
    // die eigene Liste bleibt unverändert
    await tippe(tester, find.text('Notizen'));
    await warte(tester);
    expect(find.text('Etwas'), findsOneWidget);
    expect(find.text('OBST UND GEMÜSE'), findsNothing);
  });

  testWidgets('Neuer Eintrag bekommt die Kategorie aus dem Namen; ohne Treffer bleibt sie leer', (tester) async {
    final env = await start(tester, vorher: (env) => liste(env, _l1, 'Einkauf'));
    for (final t in ['Vollmilch', 'Geschenkpapier']) {
      await tester.enterText(eingabe('Was fehlt?'), t);
      await tester.pump();
      await tippe(tester, find.byTooltip('Hinzufügen'));
      await warte(tester);
    }
    final e = {for (final x in await env.db.select(env.db.listenEintraege).get()) x.inhalt: x.category};
    expect(e, {'Vollmilch': 'milch_kuehlregal', 'Geschenkpapier': null});
    expect(find.text('MILCH UND KÜHLREGAL'), findsOneWidget);
    expect(find.text('SONSTIGES'), findsOneWidget);
  });

  testWidgets('Zuletzt gekauft: Vorschläge beim Tippen aus abgehakten Einträgen, Tipp übernimmt Name und Kategorie', (tester) async {
    final env = await start(
      tester,
      vorher: (env) async {
        await liste(env, _l1, 'Einkauf');
        await eintrag(env, _l1, 'Haferdrink', kategorie: 'getraenke', erledigt: DateTime(2026, 10, 10));
        await eintrag(env, _l1, 'Haferflocken', kategorie: 'vorrat_konserven', erledigt: DateTime(2026, 10, 11));
        await eintrag(env, _l1, 'Hafermilch offen', kategorie: 'milch_kuehlregal');
      },
    );
    expect(find.text('// ZULETZT GEKAUFT'), findsNothing, reason: 'ohne Eingabe keine Vorschläge');
    await tester.enterText(eingabe('Was fehlt?'), 'hafer');
    await tester.pump();
    expect(find.text('// ZULETZT GEKAUFT'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Haferdrink'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Haferflocken'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Hafermilch offen'), findsNothing, reason: 'nur abgehakte');
    await tippe(tester, find.widgetWithText(ActionChip, 'Haferdrink'));
    await warte(tester);
    final neu = (await env.db.select(env.db.listenEintraege).get()).where((e) => e.inhalt == 'Haferdrink' && e.doneAt == null).single;
    expect(neu.category, 'getraenke');
    expect(find.widgetWithText(ActionChip, 'Haferdrink'), findsNothing, reason: 'Eingabe geleert');
  });

  testWidgets('Kategorie am Eintrag ändern über das Blatt (Auswahl), auch zurück auf Sonstiges', (tester) async {
    final env = await start(
      tester,
      vorher: (env) async {
        await liste(env, _l1, 'Einkauf');
        await eintrag(env, _l1, 'Tomaten', kategorie: 'obst_gemuese');
      },
    );
    await tippeText(tester, 'Tomaten');
    expect(find.byType(AuswahlKnopf), findsNWidgets(9));
    await tippe(tester, find.widgetWithText(AuswahlKnopf, 'Getränke'));
    await tippeText(tester, 'Speichern');
    await warte(tester);
    expect((await env.db.select(env.db.listenEintraege).get()).single.category, 'getraenke');
    await tippeText(tester, 'Tomaten');
    await tippe(tester, find.widgetWithText(AuswahlKnopf, 'Sonstiges'));
    await tippeText(tester, 'Speichern');
    await warte(tester);
    expect((await env.db.select(env.db.listenEintraege).get()).single.category, isNull);
  });

  testWidgets('Vorlagen: Liste als Vorlage speichern, in eine andere Liste übernehmen', (tester) async {
    final env = await start(
      tester,
      vorher: (env) async {
        await liste(env, _l1, 'Wocheneinkauf');
        await eintrag(env, _l1, 'Milch', kategorie: 'milch_kuehlregal');
        await eintrag(env, _l1, 'Brot', kategorie: 'brot_backwaren', erledigt: DateTime(2026, 10, 18));
        await liste(env, _l2, 'Nächste Woche');
      },
    );
    await tippe(tester, find.byTooltip('Liste verwalten'));
    await tippeText(tester, 'Als Vorlage speichern');
    await warte(tester);
    await eingeben(tester, 'Name der Vorlage', 'Standard-Einkauf');
    await tippeText(tester, 'Speichern');
    await warte(tester, 10);
    expect(find.text('Vorlage „Standard-Einkauf“ gespeichert.'), findsOneWidget);
    final alle = await env.db.select(env.db.listen).get();
    final vorlage = alle.singleWhere((l) => l.kind == 'template');
    expect(vorlage.name, 'Standard-Einkauf');
    final inhalt = await (env.db.select(env.db.listenEintraege)..where((e) => e.listId.equals(vorlage.id))).get();
    expect(inhalt.map((e) => e.inhalt).toSet(), {'Milch', 'Brot'});
    expect(inhalt.every((e) => e.doneAt == null), isTrue);

    await tippe(tester, find.text('Nächste Woche'));
    await warte(tester);
    await tippe(tester, find.byTooltip('Liste verwalten'));
    await tippeText(tester, 'Aus Vorlage übernehmen');
    await warte(tester);
    await tippe(tester, find.widgetWithText(ListTile, 'Standard-Einkauf'));
    await warte(tester, 10);
    expect(find.text('2 Einträge aus der Vorlage übernommen.'), findsOneWidget);
    final ziel = await (env.db.select(env.db.listenEintraege)..where((e) => e.listId.equals(_l2))).get();
    expect({for (final e in ziel) e.inhalt: e.category}, {'Milch': 'milch_kuehlregal', 'Brot': 'brot_backwaren'});
  });

  for (final skala in [1.0, 1.5, 2.0]) {
    testWidgets('Layout 360 px, Textskala $skala: gruppierte Liste, Vorschläge, Blatt mit Kategorien', (tester) async {
      await start(
        tester,
        skala: skala,
        vorher: (env) async {
          await liste(env, _l1, 'Wocheneinkauf für die ganze Familie mit einem wirklich langen Namen');
          for (var i = 0; i < 4; i++) {
            await eintrag(env, _l1, 'Ein ziemlich langer Artikel Nummer $i mit Zusatz, der umbrechen muss', kategorie: i.isEven ? 'obst_gemuese' : 'haushalt_drogerie');
          }
          await eintrag(env, _l1, 'Ein ziemlich langer, schon gekaufter Artikel mit sehr langem Namen', kategorie: 'tiefkuehl', erledigt: DateTime(2026, 10, 18));
        },
      );
      await warte(tester);
      pruefeLayout(tester, 'gruppierte Liste, Skala $skala');
      await tester.enterText(eingabe('Was fehlt?'), 'artikel');
      await tester.pump();
      expect(find.byType(ActionChip), findsOneWidget);
      pruefeLayout(tester, 'Vorschläge, Skala $skala');
      await tester.enterText(eingabe('Was fehlt?'), '');
      await tester.pump();
      await tippeText(tester, 'Ein ziemlich langer Artikel Nummer 0 mit Zusatz, der umbrechen muss');
      pruefeLayout(tester, 'Blatt mit Kategorien, Skala $skala');
    });
  }
}
