// Chat-Suche (nur lokal, nur Arbeitsspeicher): Logik des ChatSucher (Treffer, nicht durchsuchbare Nachrichten, Fenster, Umfragen, Verwerfen) und Oberfläche (Leiste im
// Verlauf, Seite über alle Chats, Sprung zur Nachricht, Hinweis auf nicht durchsuchbare Nachrichten, Layout 360 px / Textskala 1.5 und 2.0).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart' show kDesktopBreakpoint;
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_zusatz_inhalt.dart';
import 'package:lx_fampad/data/chat/nachrichten_inhalt.dart';
import 'package:lx_fampad/data/suche/chat_suche.dart';
import 'package:lx_fampad/features/chat/chat_suche_ui.dart';

import 'support/chat_ui_aufbau.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _famChat = '44444444-4444-4444-8444-444444444444';

Nachricht _n(String id, String konv, String wire, int minuten, {String? autor}) =>
    Nachricht(id: id, konversationId: konv, autorId: autor, inhalt: wire, antwortAuf: null, bearbeitetAt: null, createdAt: DateTime.utc(2026, 10, 1, 12).add(Duration(minutes: minuten)), rev: 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('ChatSucher', () {
    // Wire = Klartext mit Präfix: "ok:" lesbar, "no:" nicht entschlüsselbar, "wait:" noch offen (wird beim zweiten Durchgang lesbar)
    final offene = <String>{};
    DekodierterInhalt inhalt(Nachricht n) {
      final w = n.inhalt;
      if (w.startsWith('ok:')) return DekodierterInhalt(w.substring(3), InhaltStatus.bereit);
      if (w.startsWith('no:')) return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'warte auf Schlüssel');
      if (offene.remove(n.id)) return DekodierterInhalt(w.substring(5), InhaltStatus.bereit);
      offene.add(n.id);
      return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
    }

    setUp(offene.clear);

    test('Treffer neueste zuerst, Teilwörter, Umlaute; nicht lesbare werden gezählt und nie durchsucht', () {
      final s = ChatSucher(inhalt: inhalt);
      final liste = [
        _n('1', 'c1', 'ok:Wer holt die Kinder ab?', 1),
        _n('2', 'c1', 'ok:Kinderarzt um 15 Uhr', 2),
        _n('3', 'c2', 'no:Kinder verschlüsselt', 3),
        _n('4', 'c2', 'ok:Käsekuchen', 4),
      ];
      expect(s.aktualisieren(liste), isFalse);
      final st = s.suche('kinder');
      expect(st.treffer.map((t) => t.nachrichtId), ['2', '1']);
      expect(st.trefferGesamt, 2);
      expect(st.nichtDurchsuchbar, 1);
      expect(st.durchsuchbar, 3);
      expect(s.suche('kaese').treffer.single.nachrichtId, '4');
      expect(s.suche('k').treffer, isEmpty); // zu kurz
      expect(s.suche('').treffer, isEmpty);
    });

    test('Offene Nachrichten: erst "läuft", beim nächsten Durchgang durchsuchbar', () {
      final s = ChatSucher(inhalt: inhalt);
      final liste = [_n('1', 'c1', 'wait:Gartenfest am Samstag', 1)];
      expect(s.aktualisieren(liste), isTrue);
      expect(s.suche('garten').laeuft, isTrue);
      expect(s.suche('garten').treffer, isEmpty);
      expect(s.aktualisieren(liste), isFalse);
      expect(s.suche('garten').treffer.single.nachrichtId, '1');
    });

    test('Fenster: höchstens $kChatSucheFenster Nachrichten gleichzeitig angefordert', () {
      var angefordert = 0;
      final s = ChatSucher(inhalt: (n) {
        angefordert++;
        return const DekodierterInhalt('', InhaltStatus.wirdEntschluesselt);
      });
      final liste = [for (var i = 0; i < 400; i++) _n('m$i', 'c1', 'x', i)];
      expect(s.aktualisieren(liste), isTrue);
      expect(angefordert, kChatSucheFenster);
      expect(s.suche('xx').offen, 400);
    });

    test('Nur die jüngsten $kChatSucheMaxNachrichten je Chat', () {
      final s = ChatSucher(inhalt: (n) => DekodierterInhalt(n.inhalt, InhaltStatus.bereit));
      final liste = [for (var i = 0; i < kChatSucheMaxNachrichten + 50; i++) _n('m$i', 'c1', i < 50 ? 'uralt$i' : 'neu$i', i)];
      s.aktualisieren(liste);
      expect(s.suche('uralt').trefferGesamt, 0);
      expect(s.suche('neu').trefferGesamt, kChatSucheMaxNachrichten);
      expect(s.suche('neu').treffer, hasLength(kChatSucheMaxTreffer));
      expect(s.suche('neu').treffer.first.nachrichtId, 'm${kChatSucheMaxNachrichten + 49}');
    });

    test('Umfragen: Frage und Antworten sind durchsuchbar', () {
      final umfrage = umfrageKodieren(frage: 'Wohin am Wochenende?', optionen: ['Zoo', 'Schwimmbad'], mehrfach: false);
      final s = ChatSucher(inhalt: (n) => DekodierterInhalt(n.inhalt, InhaltStatus.bereit));
      s.aktualisieren([_n('1', 'c1', umfrage, 1)]);
      expect(s.suche('schwimmbad').treffer.single.nachrichtId, '1');
      expect(s.suche('wochenende').treffer, hasLength(1));
    });

    test('Bearbeitete Nachricht wird neu gelesen, gelöschte verschwindet; verwerfen leert alles', () {
      final s = ChatSucher(inhalt: inhalt);
      s.aktualisieren([_n('1', 'c1', 'ok:alter Text', 1)]);
      expect(s.suche('alter').trefferGesamt, 1);
      s.aktualisieren([_n('1', 'c1', 'ok:neuer Text', 1)]);
      expect(s.suche('alter').trefferGesamt, 0);
      expect(s.suche('neuer').trefferGesamt, 1);
      s.aktualisieren(const []);
      expect(s.suche('neuer').trefferGesamt, 0);
      s.aktualisieren([_n('2', 'c1', 'ok:bleibt nicht', 1)]);
      s.verwerfen();
      expect(s.suche('bleibt').trefferGesamt, 0);
      expect(s.suche('bleibt').durchsuchbar, 0);
    });
  });

  test('Statuszeile: feste Texte, Zahl der nicht durchsuchbaren Nachrichten', () {
    expect(chatSuchStatus(const ChatSuchStand(), gueltig: false), 'Gib mindestens zwei Zeichen ein.');
    expect(chatSuchStatus(const ChatSuchStand(), gueltig: true), 'Keine Treffer.');
    expect(chatSuchStatus(const ChatSuchStand(offen: 3), gueltig: true), 'Suche läuft …');
    expect(chatSuchStatus(const ChatSuchStand(nichtDurchsuchbar: 2), gueltig: true), contains('2 Nachrichten nicht durchsuchbar'));
    expect(chatSuchStatus(const ChatSuchStand(nichtDurchsuchbar: 1), gueltig: true), contains('1 Nachricht nicht durchsuchbar'));
  });

  group('Oberfläche', () {
    String vor(int minuten) {
      final jetzt = DateTime.now();
      return DateTime(jetzt.year, jetzt.month, jetzt.day, 12).toUtc().subtract(Duration(minutes: minuten)).toIso8601String();
    }

    Future<void> grundstand(TestUmgebung env, ChatUiAufbau a, {bool kaputt = false}) async {
      env.server.json('GET /members', {
        'members': [
          userJson(),
          userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
          userJson(id: coraId, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
        ],
      });
      env.sync.andereAendert('konversation', _famChat, {'art': 'family', 'encVersion': 'e1', 'titel': '', 'teilnehmer': <String>[], 'ownerId': null, 'createdAt': vor(600)});
      await a.epoche(_famChat, [a.anna, a.ben, a.cora], art: 'family');
      await a.nachricht(_famChat, 'a0000000-0000-4000-8000-000000000001', a.ben, 'Wer holt heute die Kinder ab?', vor(30));
      await a.nachricht(_famChat, 'a0000000-0000-4000-8000-000000000002', a.cora, 'Ich kann das machen', vor(20));
      final dm = direktChatId(fixIdAdmin, fixIdKind);
      env.sync.andereAendert('konversation', dm, {'art': 'direct', 'encVersion': 'e1', 'titel': '', 'teilnehmer': [fixIdAdmin, fixIdKind]..sort(), 'ownerId': fixIdKind, 'createdAt': vor(300)});
      await a.epoche(dm, [a.anna, a.ben]);
      await a.nachricht(dm, 'a0000000-0000-4000-8000-000000000003', a.ben, 'Kommst du zum Training?', vor(10));
      if (kaputt) {
        env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000009', {'konversationId': dm, 'text': 'e1:AAAA', 'autorId': fixIdKind, 'createdAt': vor(5)});
      }
    }

    Future<TestUmgebung> start(WidgetTester tester, {double skala = 1.0, Size groesse = const Size(360, 800), bool kaputt = false}) async {
      final env = await angemeldeteUmgebung();
      final a = ChatUiAufbau(env);
      env.extraOverrides.addAll(a.overrides);
      await grundstand(env, a, kaputt: kaputt);
      final container = await starteApp(tester, env, skala: skala, groesse: groesse);
      if (groesse.width >= kDesktopBreakpoint) {
        container.read(shellTabProvider.notifier).waehlen(kChatTab);
      } else {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
      }
      await warte(tester);
      return env;
    }

    Future<void> tippeSuche(WidgetTester tester, Finder feld, String text) async {
      await tester.enterText(feld, text);
      await tester.pump(const Duration(milliseconds: 400));
      await warte(tester, 10);
    }

    Finder suchknopf() => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'In allen Chats suchen');
    Finder seitenFeld() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Nachrichten durchsuchen …');
    Finder chatFeld() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'In diesem Chat suchen …');

    testWidgets('Seite über alle Chats: Treffer mit Chat und Absender, Tippen öffnet den Chat an der Nachricht', (tester) async {
      await start(tester);
      await tippe(tester, suchknopf());
      expect(find.text('In Chats suchen'), findsOneWidget);
      expect(find.text('Gib mindestens zwei Zeichen ein.'), findsOneWidget);
      await tippeSuche(tester, seitenFeld(), 'training');
      expect(find.text('1 Treffer.'), findsOneWidget);
      expect(find.textContaining('Ben · Ben'), findsOneWidget); // Chat "Ben", Absender "Ben"
      pruefeLayout(tester, 'Chat-Suche mit Treffer');
      await tippe(tester, find.textContaining('Ben · Ben'));
      // der Direktchat ist offen, die Nachricht steht im Verlauf
      expect(find.byType(ChatSuchSeite), findsNothing);
      expect(find.text('Kommst du zum Training?'), findsOneWidget);
      // die angesteuerte Nachricht ist hervorgehoben (kräftiger Rand, für Screenreader "Suchtreffer")
      expect(find.byWidgetPredicate((w) => w is Semantics && (w.properties.label ?? '').contains('Suchtreffer')), findsOneWidget);
      pruefeLayout(tester, 'Chat nach Sprung');
    });

    testWidgets('Familienchat: Treffer über Chats hinweg, keine Treffer ehrlich gemeldet', (tester) async {
      await start(tester);
      await tippe(tester, suchknopf());
      await tippeSuche(tester, seitenFeld(), 'kinder');
      expect(find.text('1 Treffer.'), findsOneWidget);
      expect(find.textContaining('Familie · Ben'), findsOneWidget);
      await tippeSuche(tester, seitenFeld(), 'gibtesnicht');
      expect(find.text('Keine Treffer.'), findsWidgets);
      expect(find.text('Nichts gefunden'), findsOneWidget);
    });

    testWidgets('Nicht entschlüsselbare Nachrichten bleiben außen vor und werden gezählt', (tester) async {
      await start(tester, kaputt: true);
      await tippe(tester, suchknopf());
      await tippeSuche(tester, seitenFeld(), 'training');
      expect(find.textContaining('1 Nachricht nicht durchsuchbar'), findsOneWidget);
      expect(find.textContaining('1 Treffer.'), findsOneWidget);
    });

    testWidgets('Leiste im Verlauf: Treffer-Zähler, Navigation, Schließen', (tester) async {
      await start(tester);
      await tippeText(tester, 'Cora: Ich kann das machen');
      await tippe(tester, find.byTooltip('Im Chat suchen'));
      expect(chatFeld(), findsOneWidget);
      await tippeSuche(tester, chatFeld(), 'ich');
      // "ich" steckt in "Ich kann das machen" und in "heute die Kinder..."? nur in der ersten Nachricht ("Wer holt ... ab?" enthält kein "ich")
      expect(find.textContaining('Treffer 1 von 1'), findsOneWidget);
      pruefeLayout(tester, 'Suchleiste mit Treffer');
      await tippeSuche(tester, chatFeld(), 'kinder');
      expect(find.textContaining('Treffer 1 von 1'), findsOneWidget);
      await tippe(tester, find.byTooltip('Suche schließen'));
      expect(chatFeld(), findsNothing);
      expect(find.byTooltip('Im Chat suchen'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Layout bei 360 px und Textskala $skala (Liste, Seite, Verlauf mit Leiste)', (tester) async {
        await start(tester, skala: skala, kaputt: true);
        pruefeLayout(tester, 'Chat-Liste $skala');
        await tippe(tester, suchknopf());
        await tippeSuche(tester, seitenFeld(), 'kinder');
        pruefeLayout(tester, 'Suchseite $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippeText(tester, 'Cora: Ich kann das machen');
        await tippe(tester, find.byTooltip('Im Chat suchen'));
        await tippeSuche(tester, chatFeld(), 'kinder');
        pruefeLayout(tester, 'Suchleiste $skala');
      });
    }

    testWidgets('Desktop-Zweispalter: Treffer wählt den Chat in der rechten Spalte', (tester) async {
      await start(tester, groesse: const Size(1200, 800));
      await tippe(tester, suchknopf());
      await tippeSuche(tester, seitenFeld(), 'training');
      await tippe(tester, find.textContaining('Ben · Ben'));
      expect(find.byType(ChatSuchSeite), findsNothing);
      // Vorschau in der Liste links und Blase im Verlauf rechts
      expect(find.text('Kommst du zum Training?'), findsNWidgets(2));
    });
  });

}
