// Chat-Oberfläche: Konversationsliste, Verlauf (Senden offline-first, Antworten, Bearbeiten, Löschen, Lesestand), Neuer Chat, Ungelesen-Zeichen
// am Tab, nicht lesbare Nachrichten, Layout bei 360 px / Textskala 1.5, Desktop-Zweispalter und Chat-Karte der Startseite.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/sync_state.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _fam = 'fa000000-0000-4000-8000-000000000001';
const _cora = '33333333-3333-4333-8333-333333333333';
const _famChat = '44444444-4444-4444-8444-444444444444';

String vor(int minuten) => DateTime.now().toUtc().subtract(Duration(minutes: minuten)).toIso8601String();

Future<void> zumChatTab(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
  await warte(tester);
}

Finder eingabe() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Nachricht');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  /// Familienchat mit zwei Nachrichten von Ben, Direktchat Anna/Ben mit einer Nachricht, Gruppe mit Namen ohne Nachrichten.
  void grundstand(TestUmgebung env, {bool gruppe = true}) {
    env.server.json('GET /members', {
      'members': [
        userJson(),
        userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
        userJson(id: _cora, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
      ],
    });
    env.sync.andereAendert('konversation', _famChat, {'art': 'family', 'titel': '', 'teilnehmer': <String>[], 'ownerId': null, 'createdAt': vor(600)});
    env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000001', {
      'konversationId': _famChat,
      'text': 'p1:Wer holt heute die Kinder ab?',
      'autorId': fixIdKind,
      'createdAt': vor(30),
    });
    env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000002', {
      'konversationId': _famChat,
      'text': 'p1:Ich kann das machen',
      'autorId': _cora,
      'createdAt': vor(20),
    });
    final dm = direktChatId(fixIdAdmin, fixIdKind);
    env.sync.andereAendert('konversation', dm, {'art': 'direct', 'titel': '', 'teilnehmer': [fixIdAdmin, fixIdKind]..sort(), 'ownerId': fixIdKind, 'createdAt': vor(300)});
    env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000003', {
      'konversationId': dm,
      'text': 'p1:Kommst du zum Training?',
      'autorId': fixIdKind,
      'createdAt': vor(10),
    });
    if (gruppe) {
      env.sync.andereAendert('konversation', 'bbbbbbbb-0000-4000-8000-0000000000b1', {
        'art': 'group',
        'titel': 'p1:Wochenendausflug',
        'teilnehmer': [fixIdAdmin, fixIdKind, _cora]..sort(),
        'ownerId': fixIdKind,
        'createdAt': vor(200),
      });
    }
  }

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', double skala = 1.0, Size groesse = const Size(360, 800), void Function(TestUmgebung env)? vorher, bool chat = true}) async {
    final env = await angemeldeteUmgebung(role: role);
    vorher?.call(env);
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (chat) await zumChatTab(tester);
    return env;
  }

  Future<List<Nachricht>> alleNachrichten(TestUmgebung env) => env.db.select(env.db.nachrichten).get();

  testWidgets('Liste: Familienchat oben, Direktchat mit Namen der Person, Gruppe mit Namen; Vorschau, Absender und Ungelesen-Zähler', (tester) async {
    await start(tester, vorher: grundstand);
    expect(find.text('Familie'), findsWidgets);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('Wochenendausflug'), findsOneWidget);
    // Familienchat: Absender in der Vorschau, Direktchat ohne Absender
    expect(find.text('Cora: Ich kann das machen'), findsOneWidget);
    expect(find.text('Kommst du zum Training?'), findsOneWidget);
    expect(find.text('Noch keine Nachrichten'), findsOneWidget);
    // Reihenfolge: Familie vor Direkt vor Gruppen
    double y(String t) => tester.getTopLeft(find.text(t).first).dy;
    expect(y('Cora: Ich kann das machen'), lessThan(y('Kommst du zum Training?')));
    expect(y('Kommst du zum Training?'), lessThan(y('Wochenendausflug')));
    // Ungelesen: Familie 2, Direkt 1 -> am Tab 3
    expect(find.text('2'), findsWidgets);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('3')), findsOneWidget);
    pruefeLayout(tester, 'Chatliste');
  });

  testWidgets('Verlauf öffnen: Blasen, Datumstrenner, Namen über Folgen; Lesestand wird gesetzt und der Zähler verschwindet', (tester) async {
    final env = await start(tester, vorher: grundstand);
    await tippeText(tester, 'Cora: Ich kann das machen');
    expect(find.text('Wer holt heute die Kinder ab?'), findsOneWidget);
    expect(find.text('Ich kann das machen'), findsOneWidget);
    expect(find.text('HEUTE'), findsOneWidget);
    expect(find.text('Ben'), findsOneWidget); // Name über der ersten Nachricht
    expect(find.text('Cora Berger'), findsOneWidget);
    // Lesestand lokal gesetzt und zum Server unterwegs
    await tester.pump(const Duration(seconds: 40));
    await warte(tester, 10);
    final ls = await env.db.select(env.db.lesestaende).get();
    expect(ls.single.konversationId, _famChat);
    expect(ls.single.id, lesestandId(_famChat, fixIdAdmin));
    expect(env.sync.zeilen.keys.where((k) => k.startsWith('lesestand/')), hasLength(1));
    // zurück zur Liste: Familie ist gelesen, am Tab bleibt 1 (Direktchat)
    await tester.tap(find.byTooltip('Zurück zur Chatliste'));
    await warte(tester);
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('1')), findsOneWidget);
    pruefeLayout(tester, 'Chatliste nach Lesen');
  });

  testWidgets('Senden ist offline-first: "wird gesendet" ohne Netz, nach dem Abgleich bestätigt und mit Serverzeit', (tester) async {
    final env = await start(tester, vorher: grundstand);
    await tippeText(tester, 'Kommst du zum Training?');
    env.sync.offline = true;
    await tester.enterText(eingabe(), 'Klar, bin dabei 🎉');
    await tester.pump();
    await tippe(tester, find.byTooltip('Senden'));
    await warte(tester, 10);
    expect(find.text('Klar, bin dabei 🎉'), findsOneWidget);
    expect(find.text('wird gesendet'), findsOneWidget);
    final n = (await alleNachrichten(env)).firstWhere((n) => n.inhalt == 'p1:Klar, bin dabei 🎉');
    expect(n.rev, 0);
    expect(n.autorId, fixIdAdmin);
    expect(tester.widget<TextField>(eingabe()).controller!.text, isEmpty);
    // wieder Netz: der Server bekommt die Nachricht mit der Hülle
    env.sync.offline = false;
    await tester.pump(const Duration(seconds: 40));
    await warte(tester, 10);
    expect(env.sync.zeilen.values.where((z) => z.entity == 'nachricht' && z.fields['text'] == 'p1:Klar, bin dabei 🎉'), hasLength(1));
    expect(find.text('wird gesendet'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Antworten, Bearbeiten und Löschen über das Menü der Nachricht; fremde Nachrichten nur Antworten (Admin im Direktchat nicht löschen)', (tester) async {
    final env = await start(tester, vorher: grundstand);
    await tippeText(tester, 'Kommst du zum Training?');
    // fremde Nachricht im Direktchat: antworten, kopieren, nicht bearbeiten/löschen
    await tippeText(tester, 'Kommst du zum Training?');
    expect(find.text('Antworten'), findsOneWidget);
    expect(find.text('Text kopieren'), findsOneWidget);
    expect(find.text('Bearbeiten'), findsNothing);
    expect(find.text('Löschen'), findsNothing);
    await tippeText(tester, 'Antworten');
    expect(find.text('ANTWORT AN BEN'), findsOneWidget);
    await tester.enterText(eingabe(), 'Ja, um 17 Uhr');
    await tester.pump();
    await tippe(tester, find.byTooltip('Senden'));
    await warte(tester, 10);
    final antwort = (await alleNachrichten(env)).firstWhere((n) => n.inhalt == 'p1:Ja, um 17 Uhr');
    expect(antwort.antwortAuf, 'a0000000-0000-4000-8000-000000000003');
    // Zitat sichtbar
    expect(find.text('Kommst du zum Training?'), findsNWidgets(2));
    // eigene Nachricht bearbeiten
    await tippeText(tester, 'Ja, um 17 Uhr');
    await tippeText(tester, 'Bearbeiten');
    expect(find.text('NACHRICHT BEARBEITEN'), findsOneWidget);
    expect(tester.widget<TextField>(eingabe()).controller!.text, 'Ja, um 17 Uhr');
    await tester.enterText(eingabe(), 'Ja, um 18 Uhr');
    await tester.pump();
    await tippe(tester, find.byTooltip('Senden'));
    await warte(tester, 10);
    expect(find.text('Ja, um 18 Uhr'), findsOneWidget);
    expect(find.text('bearbeitet'), findsOneWidget);
    expect((await alleNachrichten(env)).where((n) => n.inhalt == 'p1:Ja, um 18 Uhr'), hasLength(1));
    // eigene Nachricht löschen
    await tippeText(tester, 'Ja, um 18 Uhr');
    await tippeText(tester, 'Löschen');
    await tippeText(tester, 'Löschen'); // Bestätigen
    await warte(tester, 10);
    expect(find.text('Ja, um 18 Uhr'), findsNothing);
    expect((await alleNachrichten(env)).where((n) => n.inhalt.contains('18 Uhr')), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Admin darf im Familienchat fremde Nachrichten löschen, Eltern nicht', (tester) async {
    await start(tester, vorher: grundstand);
    await tippeText(tester, 'Cora: Ich kann das machen');
    await tippeText(tester, 'Ich kann das machen');
    expect(find.text('Löschen'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // Menü schließen
    await warte(tester);
  });

  testWidgets('Eltern: im Familienchat kein Löschen fremder Nachrichten', (tester) async {
    await start(tester, role: 'parent', vorher: grundstand);
    await tippeText(tester, 'Cora: Ich kann das machen');
    await tippeText(tester, 'Ich kann das machen');
    expect(find.text('Antworten'), findsOneWidget);
    expect(find.text('Löschen'), findsNothing);
  });

  testWidgets('nicht lesbare Nachrichten (verschlüsselt/unbekannte Hülle): kein Klartext, Hinweis "warte auf Schlüssel"', (tester) async {
    await start(tester, vorher: (env) {
      grundstand(env);
      env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000009', {'konversationId': _famChat, 'text': 'e1:Z2VoZWlt', 'autorId': fixIdKind, 'createdAt': vor(1)});
    });
    expect(find.text('Ben: Nachricht nicht lesbar'), findsOneWidget);
    expect(find.textContaining('Z2VoZWlt'), findsNothing);
    await tippeText(tester, 'Ben: Nachricht nicht lesbar');
    expect(find.text('Nachricht nicht lesbar – warte auf Schlüssel'), findsOneWidget);
    expect(find.textContaining('Z2VoZWlt'), findsNothing);
    // Menü: nicht lesbar -> nicht kopieren, nicht bearbeiten
    await tippeText(tester, 'Nachricht nicht lesbar – warte auf Schlüssel');
    expect(find.text('Text kopieren'), findsNothing);
    expect(find.text('Bearbeiten'), findsNothing);
  });

  testWidgets('Neuer Chat: eine Person ergibt einen Direktchat (feste ID, kein zweiter bei erneutem Wählen)', (tester) async {
    final env = await start(tester, vorher: (e) => grundstand(e, gruppe: false));
    await tippeText(tester, 'Neuer Chat');
    await tippeText(tester, 'Cora Berger');
    expect(find.text('Chat starten'), findsOneWidget);
    await tippeText(tester, 'Chat starten');
    await warte(tester, 10);
    final dm = direktChatId(fixIdAdmin, _cora);
    expect((await env.db.select(env.db.konversationen).get()).where((k) => k.id == dm), hasLength(1));
    expect(find.text('Noch keine Nachrichten'), findsOneWidget); // Verlauf des neuen Chats
    expect(find.text('Cora'), findsNothing);
    // erneut: derselbe Chat, nichts Neues
    await tester.tap(find.byTooltip('Zurück zur Chatliste'));
    await warte(tester);
    await tippeText(tester, 'Neuer Chat');
    await tippeText(tester, 'Cora Berger');
    await tippeText(tester, 'Chat starten');
    await warte(tester, 10);
    expect((await env.db.select(env.db.konversationen).get()).where((k) => k.art == 'direct'), hasLength(2));
  });

  testWidgets('Neuer Chat: mehrere Personen ergeben eine Gruppe mit optionalem Namen; die eigene Person ist dabei', (tester) async {
    final env = await start(tester, vorher: (e) => grundstand(e, gruppe: false));
    await tippeText(tester, 'Neuer Chat');
    await tippeText(tester, 'Ben');
    await tippeText(tester, 'Cora Berger');
    expect(find.text('Gruppe anlegen'), findsOneWidget);
    await eingeben(tester, 'Gruppenname (optional)', 'Skiurlaub');
    await tippeText(tester, 'Gruppe anlegen');
    await warte(tester, 10);
    final g = (await env.db.select(env.db.konversationen).get()).firstWhere((k) => k.art == 'group');
    expect(g.titel, 'p1:Skiurlaub');
    expect(teilnehmerIds(g), [fixIdAdmin, fixIdKind, _cora]..sort());
    expect(find.text('Skiurlaub'), findsOneWidget); // Kopf des Verlaufs
    expect(find.text('3 teilnehmer'), findsOneWidget);
  });

  testWidgets('Neuer Chat ohne weitere Mitglieder: Hinweis statt leerer Liste', (tester) async {
    await start(tester, vorher: (env) {
      env.server.json('GET /members', {
        'members': [userJson()],
      });
    });
    await tippeText(tester, 'Neuer Chat');
    expect(find.text('Keine weiteren Mitglieder'), findsOneWidget);
  });

  testWidgets('Gruppe verlassen: Teilnehmerliste ohne mich; bei zwei Personen nicht möglich', (tester) async {
    final env = await start(tester, vorher: grundstand);
    await tippeText(tester, 'Wochenendausflug');
    await tester.tap(find.byTooltip('Gruppe verwalten'));
    await warte(tester);
    await tippeText(tester, 'Gruppe verlassen');
    await tippeText(tester, 'Verlassen');
    await warte(tester, 10);
    final g = await (env.db.select(env.db.konversationen)..where((k) => k.id.equals('bbbbbbbb-0000-4000-8000-0000000000b1'))).getSingleOrNull();
    // lokal ohne mich (der Server schickt danach den hidden-Tombstone); die Seite ist geschlossen
    if (g != null) expect(teilnehmerIds(g), isNot(contains(fixIdAdmin)));
    expect(find.text('Chat'), findsWidgets);
  });

  testWidgets('Familienchat wird beim Öffnen des Chat-Bereichs einmal angelegt, wenn es keinen gibt', (tester) async {
    final env = await start(tester);
    await tester.pump(const Duration(seconds: 40));
    await warte(tester, 10);
    final k = await env.db.select(env.db.konversationen).get();
    expect(k.map((e) => e.id), [familienchatId(_fam)]);
    expect(k.single.art, 'family');
    expect(env.sync.zeilen.keys.where((x) => x.startsWith('konversation/')), hasLength(1));
    expect(find.text('Familie'), findsWidgets);
  });

  testWidgets('andere Bereiche lösen keinen Familienchat aus (nur der Chat-Bereich)', (tester) async {
    final env = await start(tester, chat: false);
    await warte(tester, 10);
    expect(await env.db.select(env.db.konversationen).get(), isEmpty);
  });

  testWidgets('Layout 360 px, Textskala 1.5: Liste, Verlauf mit Menü, Neuer Chat; Touch-Ziele mindestens 44 px', (tester) async {
    await start(tester, skala: 1.5, vorher: grundstand);
    pruefeLayout(tester, 'Chatliste 1.5');
    await tippeText(tester, 'Cora: Ich kann das machen');
    pruefeLayout(tester, 'Verlauf 1.5');
    await tippeText(tester, 'Ich kann das machen');
    pruefeLayout(tester, 'Nachrichten-Menü 1.5');
    await tester.tapAt(const Offset(10, 10));
    await warte(tester);
    await tester.tap(find.byTooltip('Zurück zur Chatliste'));
    await warte(tester);
    await tippeText(tester, 'Neuer Chat');
    pruefeLayout(tester, 'Neuer Chat 1.5');
    await tippeText(tester, 'Ben');
    await tippeText(tester, 'Cora Berger');
    pruefeLayout(tester, 'Neue Gruppe 1.5');
  });

  testWidgets('Layout 360 px: lange Nachricht ohne Leerzeichen und langer Gruppenname laufen nicht über', (tester) async {
    await start(tester, skala: 1.5, vorher: (env) {
      grundstand(env);
      env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-0000000000aa', {
        'konversationId': _famChat,
        'text': 'p1:${'Wort ' * 80}${'x' * 120}',
        'autorId': fixIdKind,
        'createdAt': vor(2),
      });
      env.sync.andereAendert('konversation', 'bbbbbbbb-0000-4000-8000-0000000000b2', {
        'art': 'group',
        'titel': 'p1:Ein sehr langer Gruppenname der nicht in eine Zeile passt',
        'teilnehmer': [fixIdAdmin, fixIdKind]..sort(),
        'ownerId': fixIdKind,
        'createdAt': vor(100),
      });
    });
    pruefeLayout(tester, 'Liste mit langen Texten');
    await tippeText(tester, 'Ein sehr langer Gruppenname der nicht in eine Zeile passt');
    pruefeLayout(tester, 'Verlauf lang');
  });

  testWidgets('Gruppe: Teilnehmer ändern warnt, dass Neue den bisherigen Verlauf sehen; erst nach Bestätigung wird gespeichert', (tester) async {
    final env = await start(tester, vorher: grundstand);
    await tippeText(tester, 'Wochenendausflug');
    await tester.tap(find.byTooltip('Gruppe verwalten'));
    await warte(tester);
    await tippeText(tester, 'Teilnehmer ändern');
    // die Gruppe hat Anna (ich), Ben und Cora; Cora wird abgewählt, dann wieder dazu
    await tippeText(tester, 'Cora Berger');
    await tippeText(tester, 'Übernehmen');
    await warte(tester, 10);
    var g = await (env.db.select(env.db.konversationen)..where((k) => k.id.equals('bbbbbbbb-0000-4000-8000-0000000000b1'))).getSingle();
    expect(teilnehmerIds(g), [fixIdAdmin, fixIdKind]..sort(), reason: 'Entfernen braucht keine Warnung');
    await tester.tap(find.byTooltip('Gruppe verwalten'));
    await warte(tester);
    await tippeText(tester, 'Teilnehmer ändern');
    await tippeText(tester, 'Cora Berger');
    await tippeText(tester, 'Übernehmen');
    expect(find.text('Neue Mitglieder sehen den bisherigen Verlauf der Gruppe.'), findsOneWidget);
    await tippeText(tester, 'Abbrechen');
    g = await (env.db.select(env.db.konversationen)..where((k) => k.id.equals('bbbbbbbb-0000-4000-8000-0000000000b1'))).getSingle();
    expect(teilnehmerIds(g), isNot(contains(_cora)));
    await tester.tap(find.byTooltip('Gruppe verwalten'));
    await warte(tester);
    await tippeText(tester, 'Teilnehmer ändern');
    await tippeText(tester, 'Cora Berger');
    await tippeText(tester, 'Übernehmen');
    await tippeText(tester, 'Hinzufügen');
    await warte(tester, 10);
    g = await (env.db.select(env.db.konversationen)..where((k) => k.id.equals('bbbbbbbb-0000-4000-8000-0000000000b1'))).getSingle();
    expect(teilnehmerIds(g), contains(_cora));
  });

  testWidgets('Bildschirmschutz (FLAG_SECURE): private Chats ja, der Familienchat nein', (tester) async {
    await start(tester, vorher: grundstand);
    int schutz() => kanalAufrufe.where((c) => c.method == 'setSecure' && (c.arguments as Map)['secure'] == true).length;
    await tippeText(tester, 'Cora: Ich kann das machen');
    expect(schutz(), 0, reason: 'Familienchat: frei');
    await tester.tap(find.byTooltip('Zurück zur Chatliste'));
    await warte(tester);
    await tippeText(tester, 'Kommst du zum Training?');
    expect(schutz(), 1, reason: 'Direktchat: geschützt');
    await tester.tap(find.byTooltip('Zurück zur Chatliste'));
    await warte(tester);
    expect(kanalAufrufe.where((c) => c.method == 'setSecure').last.arguments, {'secure': false});
  });

  testWidgets('Zitat: eine Antwort auf eine Nachricht einer anderen Konversation zeigt den Text nicht', (tester) async {
    await start(tester, vorher: (env) {
      grundstand(env);
      env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-0000000000cc', {
        'konversationId': _famChat,
        'text': 'p1:Bezug auf fremden Chat',
        'autorId': fixIdKind,
        'antwortAuf': 'a0000000-0000-4000-8000-000000000003', // Nachricht des Direktchats
        'createdAt': vor(1),
      });
    });
    await tippeText(tester, 'Ben: Bezug auf fremden Chat');
    expect(find.text('Nachricht nicht verfügbar'), findsOneWidget);
    expect(find.text('Kommst du zum Training?'), findsNothing);
  });

  testWidgets('Desktop: Lesestand nur bei sichtbarem Chat-Bereich; beim Zurückwechseln wird nachgeholt', (tester) async {
    final env = await angemeldeteUmgebung();
    grundstand(env);
    final container = await starteApp(tester, env, groesse: const Size(1280, 800));
    final nav = find.bySemanticsLabel(RegExp('^Navigation'));
    await tester.tap(find.descendant(of: nav, matching: find.text('Chat')));
    await warte(tester);
    await tippeText(tester, 'Kommst du zum Training?');
    await warte(tester, 10);
    final repo = container.read(chatRepositoryProvider);
    expect(await repo.ungelesenGesamt(fixIdAdmin).first, 2, reason: 'nur der Direktchat ist gelesen, die 2 im Familienchat nicht');
    // in einen anderen Bereich wechseln; eine neue Nachricht im offenen Verlauf kommt an, ohne dass jemand sie sieht
    await tester.tap(find.descendant(of: nav, matching: find.text('Start')));
    await warte(tester);
    final dm = direktChatId(fixIdAdmin, fixIdKind);
    env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-0000000000dd', {'konversationId': dm, 'text': 'p1:Bist du da?', 'autorId': fixIdKind, 'createdAt': vor(0)});
    await container.read(syncProvider.notifier).synchronisieren(manuell: true);
    await warte(tester, 10);
    expect((await env.db.select(env.db.nachrichten).get()).length, 4, reason: 'neue Nachricht angekommen');
    expect(await repo.ungelesenGesamt(fixIdAdmin).first, 3, reason: 'nicht als gelesen markiert, solange der Chat nicht zu sehen ist');
    await tester.tap(find.descendant(of: nav, matching: find.text('Chat')));
    await warte(tester, 10);
    expect(await repo.ungelesenGesamt(fixIdAdmin).first, 2, reason: 'beim Zurückwechseln gelesen');
  });

  group('Desktop', () {
    const gross = Size(1280, 800);

    testWidgets('Zwei Spalten ab 900 px: Liste links, Verlauf rechts; Wahl in der Liste öffnet den Verlauf, Zeichen in der Seitenleiste', (tester) async {
      await start(tester, groesse: gross, chat: false, vorher: grundstand);
      // Seitenleiste zeigt den Zähler am Chat-Eintrag (3 ungelesen)
      expect(find.descendant(of: find.bySemanticsLabel(RegExp('^Navigation')), matching: find.text('3')), findsOneWidget);
      await tester.tap(find.descendant(of: find.bySemanticsLabel(RegExp('^Navigation')), matching: find.text('Chat')));
      await warte(tester);
      expect(find.text('Wähle einen Chat'), findsOneWidget);
      await tippeText(tester, 'Kommst du zum Training?');
      expect(find.text('Wähle einen Chat'), findsNothing);
      expect(find.byTooltip('Senden'), findsOneWidget);
      // Liste und Verlauf stehen nebeneinander
      expect(tester.getTopLeft(find.text('Kommst du zum Training?').first).dx, lessThan(400));
      expect(find.byTooltip('Zurück zur Chatliste'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Enter sendet, Umschalt+Enter macht eine neue Zeile (Desktop)', (tester) async {
      final env = await start(tester, groesse: gross, chat: false, vorher: grundstand);
      await tester.tap(find.descendant(of: find.bySemanticsLabel(RegExp('^Navigation')), matching: find.text('Chat')));
      await warte(tester);
      await tippeText(tester, 'Kommst du zum Training?');
      await tester.enterText(eingabe(), 'Erste Zeile');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await warte(tester, 10);
      expect((await alleNachrichten(env)).where((n) => n.inhalt == 'p1:Erste Zeile'), hasLength(1));
    });

    testWidgets('Startseite: Chat-Karte zeigt die letzten echten Nachrichten der sichtbaren Chats (neueste zuerst)', (tester) async {
      await start(tester, groesse: gross, chat: false, vorher: grundstand);
      expect(find.text('// CHAT · FAMILIE'), findsOneWidget);
      expect(find.text('Kommst du zum Training?'), findsOneWidget);
      expect(find.text('Cora: Ich kann das machen'), findsOneWidget);
      expect(find.text('Noch keine Nachrichten'), findsNothing);
      double y(String t) => tester.getTopLeft(find.text(t).first).dy;
      expect(y('Kommst du zum Training?'), lessThan(y('Cora: Ich kann das machen')));
      expect(find.text('3 neu'), findsOneWidget);
    });

    testWidgets('Startseite: Chat-Karte ohne Nachrichten zeigt den Leerzustand', (tester) async {
      await start(tester, groesse: gross, chat: false);
      expect(find.text('Noch keine Nachrichten'), findsOneWidget);
    });
  });
}
