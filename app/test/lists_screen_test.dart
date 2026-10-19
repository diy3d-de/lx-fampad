// Listen-Tab und Startseite mit echten (lokalen) Daten: anlegen, abhaken, bearbeiten, zuweisen, löschen, Rollen, Offline, Hinweise,
// Pull-to-refresh, Layout bei 360 px und Textskala 1.5.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/lists/list_repository.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/features/lists/list_dialogs.dart';
import 'package:lx_fampad/ui/widgets.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _l1 = '11111111-1111-4111-8111-111111111111';
const _l2 = '11111111-1111-4111-8111-222222222222';
const _i1 = '22222222-2222-4222-8222-222222222222';

Future<void> zumListenTab(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Listen')));
  await warte(tester);
}

Finder eingabe(String hinweis) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hinweis);

Future<void> eintragSchreiben(WidgetTester tester, String text, {String hinweis = 'Was fehlt?'}) async {
  await tester.enterText(eingabe(hinweis), text);
  await tester.pump();
  await tippe(tester, find.byTooltip('Hinzufügen'));
  await warte(tester);
}

Future<void> listeAnlegen(WidgetTester tester, String name) async {
  await tippeText(tester, find.byTooltip('Neue Liste').evaluate().isNotEmpty ? 'Neue Liste' : 'Liste anlegen');
  await eingeben(tester, 'Name der Liste', name);
  await tippeText(tester, 'Anlegen');
  await warte(tester, 10);
}

Future<List<Listeneintrag>> eintraege(TestUmgebung env) => env.db.select(env.db.listenEintraege).get();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', void Function(TestUmgebung env)? vorher, double skala = 1.0}) async {
    final env = await angemeldeteUmgebung(role: role);
    vorher?.call(env);
    await starteApp(tester, env, skala: skala);
    await zumListenTab(tester);
    return env;
  }

  Future<void> eigeneListe(TestUmgebung env, {String id = _l1, String name = 'Einkauf', String kind = 'shopping', String audience = 'family'}) async {
    env.sync.andereAendert('list', id, {'name': name, 'kind': kind, 'audience': audience});
  }

  /// Beschriftung des Elements, das gerade den Tastaturfokus hat (Feld, Auswahl-Knopf oder Dialog-Knopf).
  String? fokusBezeichnung() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return null;
    String? gefunden;
    ctx.visitAncestorElements((e) {
      final w = e.widget;
      if (w is AuswahlKnopf) {
        gefunden = 'auswahl:${w.text}';
        return false;
      }
      if (w is TextField) {
        gefunden = 'feld:${w.decoration?.labelText}';
        return false;
      }
      if (w is ButtonStyleButton) {
        final t = find.descendant(of: find.byWidget(w), matching: find.byType(Text)).evaluate().map((x) => (x.widget as Text).data).firstOrNull;
        gefunden = 'knopf:$t';
        return false;
      }
      return true;
    });
    return gefunden;
  }

  testWidgets('Dialog „Neue Liste“: Fokus im Namensfeld, Tab läuft Name, Art, Freigabe, Abbrechen, Anlegen; Leertaste wählt, Enter legt an', (tester) async {
    final env = await start(tester);
    await tippeText(tester, 'Liste anlegen');
    await warte(tester);
    expect(fokusBezeichnung(), 'feld:Name der Liste', reason: 'Cursor steht sofort im Namensfeld');
    final erwartet = [
      'auswahl:Einkauf',
      'auswahl:Packliste',
      'auswahl:Eigene Liste',
      // Admin darf die Freigabe wählen
      for (final s in ['Nur Eltern', 'Familie']) 'auswahl:$s',
      'knopf:Abbrechen',
      'knopf:Anlegen',
    ];
    final tatsaechlich = <String?>[];
    for (var i = 0; i < erwartet.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      tatsaechlich.add(fokusBezeichnung());
    }
    expect(tatsaechlich, erwartet);
    // Umschalt+Tab geht zurück
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(fokusBezeichnung(), 'knopf:Abbrechen');
    // zurück zum Namen, schreiben, mit Enter anlegen
    await tester.enterText(find.byType(TextField), 'Mit Tastatur');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await warte(tester, 10);
    expect((await env.db.select(env.db.listen).get()).single.name, 'Mit Tastatur');
  });

  testWidgets('Dialog „Neue Liste“: per Tab zu „Packliste“, Leertaste wählt, der Fokus ist sichtbar, Enter im Namensfeld legt an', (tester) async {
    final env = await start(tester);
    await tippeText(tester, 'Liste anlegen');
    await warte(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(fokusBezeichnung(), 'auswahl:Packliste');
    final rahmen = tester.widget<Container>(find.descendant(of: find.widgetWithText(AuswahlKnopf, 'Packliste'), matching: find.byType(Container)).first);
    expect(((rahmen.decoration as BoxDecoration).border as Border).top.width, 2, reason: 'sichtbarer Fokus');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Koffer');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await warte(tester, 10);
    final l = (await env.db.select(env.db.listen).get()).single;
    expect([l.name, l.kind], ['Koffer', 'packing']);
  });

  testWidgets('Lesefehler der Einträge: Hinweis statt einer scheinbar leeren Liste', (tester) async {
    await start(tester, vorher: (e) {
      eigeneListe(e);
      e.extraOverrides.add(eintraegeProvider(_l1).overrideWith((ref) => Stream<List<Listeneintrag>>.error(StateError('kaputt'))));
    });
    await tester.tap(find.text('Einkauf').first);
    await warte(tester, 8);
    expect(find.text('Einträge nicht lesbar'), findsOneWidget);
    expect(find.text('Noch nichts drauf'), findsNothing);
  });

  testWidgets('Leerzustand: Hinweis und Knopf zum Anlegen', (tester) async {
    await start(tester);
    expect(find.text('Noch keine Liste'), findsOneWidget);
    expect(find.text('Liste anlegen'), findsOneWidget);
    pruefeLayout(tester, 'Listen leer');
  });

  testWidgets('Liste anlegen: erscheint sofort, Eintrag hinzufügen, abhaken (erledigte unten, Fortschritt), Ausgang füllt sich', (tester) async {
    final env = await start(tester);
    await listeAnlegen(tester, 'Wocheneinkauf');
    expect(find.text('Wocheneinkauf'), findsWidgets);
    expect(find.text('Noch nichts drauf'), findsOneWidget);

    await eintragSchreiben(tester, 'Milch');
    await eintragSchreiben(tester, 'Brot');
    final zeilen = tester.widgetList<Text>(find.descendant(of: find.byType(ListView), matching: find.byType(Text))).map((t) => t.data).whereType<String>().toList();
    expect(zeilen.indexOf('Brot'), lessThan(zeilen.indexOf('Milch')), reason: 'neue Einträge oben');
    expect(find.text('0 von 2 erledigt'), findsOneWidget);
    expect(find.text('2 offen · 0 erledigt'), findsOneWidget);

    // Brot abhaken: wandert nach unten, Fortschritt 1 von 2
    await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
    await warte(tester, 8);
    expect(find.text('1 von 2 erledigt'), findsOneWidget);
    final reihenfolge = tester.widgetList<Text>(find.descendant(of: find.byType(ListView), matching: find.byType(Text))).map((t) => t.data).whereType<String>().toList();
    expect(reihenfolge.indexOf('Milch'), lessThan(reihenfolge.indexOf('Brot')), reason: 'erledigte unten');
    expect(find.byIcon(Icons.check_box), findsOneWidget);

    // nichts davon hat auf den Server gewartet; der Ausgang trägt die Änderungen oder wurde schon abgeglichen
    final liste = await env.db.select(env.db.listen).get();
    expect(liste.single.name, 'Wocheneinkauf');
    expect(await eintraege(env), hasLength(2));
    pruefeLayout(tester, 'Listen mit Einträgen');

    // wieder öffnen
    await tester.tap(find.byIcon(Icons.check_box).first);
    await warte(tester, 8);
    expect(find.text('0 von 2 erledigt'), findsOneWidget);
  });

  testWidgets('die Änderungen erreichen den Server: nach dem Entprellen sind Liste und Einträge dort, der Zähler geht auf 0', (tester) async {
    final env = await start(tester);
    await listeAnlegen(tester, 'Einkauf');
    await eintragSchreiben(tester, 'Milch');
    expect(find.byType(Badge), findsWidgets);
    await tester.pump(const Duration(seconds: 3));
    await warte(tester, 10);
    expect(env.sync.zeilen.values.where((z) => z.entity == 'list_item').single.fields['text'], 'Milch');
    expect(find.byTooltip('Synchron. Tippen zum Abgleichen'), findsWidgets);
  });

  testWidgets('Eintrag bearbeiten und löschen über das Blatt', (tester) async {
    final env = await start(tester, vorher: (e) {
      eigeneListe(e);
      e.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Milch', 'position': 0});
    });
    expect(find.text('Milch'), findsOneWidget);
    await tippeText(tester, 'Milch');
    await eingeben(tester, 'Eintrag', 'Hafermilch');
    await tippeText(tester, 'Speichern');
    await warte(tester, 8);
    expect(find.text('Hafermilch'), findsOneWidget);
    expect((await eintraege(env)).single.inhalt, 'Hafermilch');

    await tippeText(tester, 'Hafermilch');
    await tippe(tester, find.text('Löschen'));
    await warte(tester, 8);
    expect(find.text('Hafermilch'), findsNothing);
    expect(await eintraege(env), isEmpty);
    expect(find.text('Noch nichts drauf'), findsOneWidget);
  });

  testWidgets('Zuweisen: Person wählen (Name und Farbe), erneut ändern, auf "Niemand" zurücksetzen', (tester) async {
    final env = await start(tester, vorher: (e) {
      eigeneListe(e);
      e.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Milch', 'position': 0});
    });
    await tippe(tester, find.byTooltip('Zuweisen'));
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('Oma'), findsNothing, reason: 'wartende Mitglieder sind keine Zuständigen');
    await tippeText(tester, 'Ben');
    await warte(tester, 8);
    expect((await eintraege(env)).single.assigneeId, fixIdKind);
    final avatar = tester.widget<PersonAvatar>(find.byType(PersonAvatar).last); // der erste ist das Profilbild der Kopfzeile
    expect(avatar.name, 'Ben');
    expect(avatar.colorIndex, 3);
    expect(find.byTooltip('Zuständig: Ben. Ändern'), findsOneWidget);

    await tippe(tester, find.byTooltip('Zuständig: Ben. Ändern'));
    await tippeText(tester, 'Niemand');
    await warte(tester, 8);
    expect((await eintraege(env)).single.assigneeId, isNull);
    expect(find.byType(PersonAvatar), findsWidgets, reason: 'nur noch die Profilbilder der Kopfzeilen');
    expect(find.byTooltip('Zuweisen'), findsOneWidget);
  });

  testWidgets('Liste umbenennen, Freigabe ändern (Admin), löschen mit Rückfrage', (tester) async {
    final env = await start(tester, vorher: (e) {
      eigeneListe(e);
      e.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Milch', 'position': 0});
    });
    await tippe(tester, find.byTooltip('Liste verwalten'));
    await tippeText(tester, 'Umbenennen');
    await eingeben(tester, 'Name der Liste', 'Wocheneinkauf');
    await tippeText(tester, 'Speichern');
    await warte(tester, 8);
    expect((await env.db.select(env.db.listen).get()).single.name, 'Wocheneinkauf');

    await tippe(tester, find.byTooltip('Liste verwalten'));
    await tippeText(tester, 'Sichtbar für …');
    await tippeText(tester, 'Nur Eltern');
    await warte(tester, 8);
    expect((await env.db.select(env.db.listen).get()).single.audience, 'parents');
    expect(find.textContaining('Nur Eltern'), findsOneWidget);

    await tippe(tester, find.byTooltip('Liste verwalten'));
    await tippeText(tester, 'Liste löschen');
    expect(find.textContaining('Die Liste und ihr Eintrag werden für alle gelöscht'), findsOneWidget);
    await tippeText(tester, 'Abbrechen');
    expect(await env.db.select(env.db.listen).get(), hasLength(1));
    await tippe(tester, find.byTooltip('Liste verwalten'));
    await tippeText(tester, 'Liste löschen');
    await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
    await warte(tester, 8);
    expect(await env.db.select(env.db.listen).get(), isEmpty);
    expect(await eintraege(env), isEmpty);
    expect(find.text('Noch keine Liste'), findsOneWidget);
  });

  testWidgets('mehrere Listen: Reiter wechseln den Inhalt', (tester) async {
    await start(tester, vorher: (e) {
      eigeneListe(e, name: 'Einkauf');
      eigeneListe(e, id: _l2, name: 'Packliste', kind: 'packing');
      e.sync.andereAendert('list_item', _i1, {'listId': _l2, 'text': 'Reisepässe', 'position': 0});
    });
    expect(find.text('Reisepässe'), findsNothing);
    await tippeText(tester, 'Packliste');
    expect(find.text('Reisepässe'), findsOneWidget);
    expect(eingabe('Was muss mit?'), findsOneWidget);
  });

  testWidgets('alter Wert "all" (früher: auch Gäste) wird wie "Familie" behandelt', (tester) async {
    await start(tester, vorher: (e) {
      eigeneListe(e, audience: 'all');
      e.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Salat', 'position': 0});
    });
    expect(find.text('Salat'), findsOneWidget);
    expect(ListenSicht.von('all'), ListenSicht.family);
    expect(ListenSicht.von('unbekannt'), ListenSicht.family);
  });

  testWidgets('Kind: legt Familienlisten an (keine Freigabe-Wahl), verwaltet nur eigene Listen', (tester) async {
    await start(tester, role: 'child', vorher: (e) => eigeneListe(e, name: 'Elternliste'));
    expect(find.byTooltip('Liste verwalten'), findsNothing, reason: 'fremde Liste');
    await tippe(tester, find.byTooltip('Neue Liste'));
    expect(find.text('// sichtbar für'.toUpperCase()), findsNothing);
    await eingeben(tester, 'Name der Liste', 'Meine Liste');
    await tippeText(tester, 'Anlegen');
    await warte(tester, 10);
    expect(find.byTooltip('Liste verwalten'), findsOneWidget, reason: 'eigene Liste');
    await tippe(tester, find.byTooltip('Liste verwalten'));
    expect(find.text('Sichtbar für …'), findsNothing);
  });

  testWidgets('Eltern sehen die Freigabe-Wahl beim Anlegen', (tester) async {
    await start(tester, role: 'parent');
    await tippeText(tester, 'Liste anlegen');
    expect(find.text('NUR ELTERN'), findsNothing);
    expect(find.text('Nur Eltern'), findsOneWidget);
  });

  testWidgets('offline: Hinweisleiste, Sync-Symbol, Änderungen bleiben und werden gezählt; danach wieder synchron', (tester) async {
    final env = await start(tester, vorher: (e) {
      e.sync.offline = true;
      e.sockets.scheitern = 99; // ohne Netz gibt es auch keinen WebSocket
    });
    expect(find.textContaining('Offline – Änderungen werden später abgeglichen'), findsOneWidget);
    expect(find.byTooltip('Offline'), findsWidgets);
    await listeAnlegen(tester, 'Einkauf');
    await eintragSchreiben(tester, 'Milch');
    expect(find.byTooltip('Offline, 2 Änderungen offen'), findsWidgets);
    expect(find.textContaining('2 Änderungen werden später abgeglichen'), findsOneWidget);
    env.sync.offline = false;
    await tippe(tester, find.byTooltip('Offline, 2 Änderungen offen').first);
    await warte(tester, 10);
    expect(find.textContaining('Offline –'), findsNothing);
    expect(find.byTooltip('Synchron. Tippen zum Abgleichen'), findsWidgets);
    expect(env.sync.zeilen, hasLength(2));
  });

  testWidgets('Serverfehler: Fehlerleiste, Änderungen bleiben gespeichert', (tester) async {
    // langer Backoff: sonst gelingt der Wiederholversuch (1-3 s, mit Zufallsanteil) noch während des Wartens und löscht die Fehlerleiste
    await start(tester, vorher: (e) {
      e.zeiten = const SyncZeiten(backoffStart: Duration(minutes: 5));
      e.sync.fehlerQueue.add((500, 'internal_error'));
    });
    expect(find.textContaining('Der Abgleich hat nicht geklappt'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsWidgets);
  });

  testWidgets('Konflikt sichtbar abgefedert: Eintrag anderswo gelöscht -> Hinweis, Eintrag weg, Hinweis lässt sich schließen', (tester) async {
    final env = await start(tester, vorher: (e) {
      eigeneListe(e);
      e.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Milch', 'position': 0});
    });
    expect(find.text('Milch'), findsOneWidget);
    // lokal ändern, bevor der Abgleich läuft; währenddessen löscht ein anderes Gerät
    env.sync.offline = true;
    await tippeText(tester, 'Milch');
    await eingeben(tester, 'Eintrag', 'Hafermilch');
    await tippeText(tester, 'Speichern');
    await warte(tester, 8);
    env.sync.andereLoescht('list_item', _i1);
    env.sync.offline = false;
    await tippe(tester, find.byTooltip('1 Änderung offen').first);
    await warte(tester, 12);
    expect(find.textContaining('Eintrag „Hafermilch“ wurde auf einem anderen Gerät gelöscht'), findsOneWidget);
    expect(find.text('Hafermilch'), findsNothing);
    await tippe(tester, find.byTooltip('Hinweis schließen'));
    expect(find.textContaining('wurde auf einem anderen Gerät gelöscht'), findsNothing);
  });

  testWidgets('Pull-to-refresh gleicht ab und übernimmt Änderungen anderer Geräte', (tester) async {
    final env = await start(tester);
    final vorher = env.server.anfragen('POST /sync').length;
    eigeneListe(env, name: 'Von drüben');
    await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1500);
    await warte(tester, 12);
    expect(env.server.anfragen('POST /sync').length, greaterThan(vorher));
    expect(find.text('Von drüben'), findsWidgets);
  });

  testWidgets('Startseite: Karte "Einkaufsliste" zeigt die echten offenen Einträge; Tippen öffnet die Liste', (tester) async {
    final env = await angemeldeteUmgebung();
    env.sync.andereAendert('list', _l2, {'name': 'Packliste', 'kind': 'packing'});
    eigeneListe(env, name: 'Einkauf');
    for (var i = 0; i < 6; i++) {
      env.sync.andereAendert('list_item', '00000000-0000-4000-8000-00000000000$i', {'listId': _l1, 'text': 'Artikel $i', 'position': i});
    }
    env.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Erledigtes', 'position': 9, 'doneAt': '2026-10-19T10:00:00.000Z'});
    await starteApp(tester, env);
    await warte(tester, 10);
    expect(find.text('6 offen'), findsOneWidget);
    expect(find.text('Artikel 0'), findsOneWidget);
    expect(find.text('Artikel 3'), findsOneWidget);
    expect(find.text('Artikel 4'), findsNothing);
    expect(find.text('+ 2 weitere'), findsOneWidget);
    expect(find.text('Erledigtes'), findsNothing);
    await tester.tap(find.text('Artikel 0'));
    await warte(tester);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, kTabs.indexWhere((t) => t.label == 'Listen'));
    expect(find.text('Wocheneinkauf'), findsNothing);
  });

  testWidgets('Startseite ohne Einkaufsliste: Hinweis zum Anlegen', (tester) async {
    final env = await angemeldeteUmgebung();
    await starteApp(tester, env);
    expect(find.textContaining('Noch keine Einkaufsliste'), findsOneWidget);
  });

  for (final skala in [1.0, 1.5]) {
    testWidgets('Layout 360 px, Textskala $skala: Listen mit langen Namen, Texten, Zuständigen und Meldungen', (tester) async {
      final env = await start(
        tester,
        skala: skala,
        vorher: (e) {
          e.sync.offline = true;
          eigeneListe(e, name: 'Wocheneinkauf für die ganze Familie mit einem wirklich langen Namen');
          eigeneListe(e, id: _l2, name: 'Packliste Sommerurlaub am Meer', kind: 'packing', audience: 'parents');
          for (var i = 0; i < 4; i++) {
            e.sync.andereAendert('list_item', '00000000-0000-4000-8000-00000000000$i', {
              'listId': _l1,
              'text': 'Ein ziemlich langer Eintrag Nummer $i, der in mehrere Zeilen umbrechen muss, weil er so lang ist',
              'position': i,
              'assigneeId': i.isEven ? fixIdKind : null,
              if (i == 3) 'doneAt': '2026-10-19T10:00:00.000Z',
            });
          }
        },
      );
      // offline gestartet: die lokale Datenbank ist leer; lade den Stand per Abgleich
      env.sync.offline = false;
      await tippe(tester, find.byTooltip(RegExp('Offline')).first);
      await warte(tester, 15);
      expect(find.textContaining('Ein ziemlich langer Eintrag Nummer 0'), findsOneWidget);
      pruefeLayout(tester, 'Listen mit Daten, Skala $skala');
      await tippe(tester, find.byTooltip('Liste verwalten'));
      pruefeLayout(tester, 'Menü');
      await tester.tapAt(const Offset(5, 5));
      await warte(tester);
      await tippeText(tester, 'Ein ziemlich langer Eintrag Nummer 0, der in mehrere Zeilen umbrechen muss, weil er so lang ist');
      pruefeLayout(tester, 'Blatt Eintrag');
      await tippeText(tester, 'Speichern');
      await tippe(tester, find.byTooltip('Zuweisen').evaluate().isNotEmpty ? find.byTooltip('Zuweisen') : find.byTooltip(RegExp('Zuständig')));
      pruefeLayout(tester, 'Blatt Zuweisen');
      await tippeText(tester, 'Niemand');
      await tester.drag(find.byType(ListView).first, const Offset(0, 1200)); // nach oben, zu den Reitern
      await warte(tester);
      await tippeText(tester, 'Packliste Sommerurlaub am Meer');
      pruefeLayout(tester, 'zweite Liste');
      await tippe(tester, find.byTooltip('Neue Liste'));
      pruefeLayout(tester, 'Dialog neue Liste');
      await tippeText(tester, 'Abbrechen');
    });
  }
}
