// Chat-Oberfläche: Konversationsliste, Verlauf (Senden offline-first, Antworten, Bearbeiten, Löschen, Lesestand), Neuer Chat, Ungelesen-Zeichen
// am Tab, nicht lesbare Nachrichten, Layout bei 360 px / Textskala 1.5, Desktop-Zweispalter und Chat-Karte der Startseite.
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_repository.dart';
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/huelle.dart';
import 'package:lx_fampad/data/sync_state.dart';

import 'package:lx_fampad/ui/widgets.dart' show PersonAvatar;

import 'support/chat_ui_aufbau.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _fam = 'fa000000-0000-4000-8000-000000000001';
const _cora = coraId;
const _famChat = '44444444-4444-4444-8444-444444444444';

/// Bezugszeit der Testdaten: heute 12:00 Uhr (Ortszeit), nicht "jetzt". Mit `DateTime.now()` rutschten Nachrichten kurz nach Mitternacht auf den Vortag und der
/// Datumstrenner "HEUTE" fehlte; mit dem festen Mittag liegen alle Zeiten (bis 10 Stunden davor) am selben Kalendertag wie der Test.
String vor(int minuten) {
  final jetzt = DateTime.now();
  return DateTime(jetzt.year, jetzt.month, jetzt.day, 12).toUtc().subtract(Duration(minutes: minuten)).toIso8601String();
}

Future<void> zumChatTab(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
  await warte(tester);
}

Finder eingabe() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Nachricht');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  /// Familienchat mit zwei Nachrichten von Ben und Cora, Direktchat Anna/Ben mit einer Nachricht, Gruppe mit Namen ohne Nachrichten. Alle Chats sind verschlüsselt
  /// (Epoche 1 von Ben verteilt, Nachrichten echt verschlüsselt und signiert); Anna liest und schreibt mit ihrem Schlüssel.
  Future<void> grundstand(TestUmgebung env, ChatUiAufbau a, {bool gruppe = true}) async {
    env.server.json('GET /members', {
      'members': [
        userJson(),
        userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
        userJson(id: _cora, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
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
    if (gruppe) {
      env.sync.andereAendert('konversation', 'bbbbbbbb-0000-4000-8000-0000000000b1', {
        'art': 'group',
        'encVersion': 'e1',
        'titel': 'p1:Wochenendausflug',
        'teilnehmer': [fixIdAdmin, fixIdKind, _cora]..sort(),
        'ownerId': fixIdKind,
        'createdAt': vor(200),
      });
      await a.epoche('bbbbbbbb-0000-4000-8000-0000000000b1', [a.anna, a.ben, a.cora]);
    }
  }

  final aufbauten = <TestUmgebung, ChatUiAufbau>{};

  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', double skala = 1.0, Size groesse = const Size(360, 800), FutureOr<void> Function(TestUmgebung env, ChatUiAufbau a)? vorher, bool chat = true}) async {
    final env = await angemeldeteUmgebung(role: role);
    final a = ChatUiAufbau(env);
    aufbauten[env] = a;
    env.extraOverrides.addAll(a.overrides);
    await vorher?.call(env, a);
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (chat) await zumChatTab(tester);
    return env;
  }

  Future<List<Nachricht>> alleNachrichten(TestUmgebung env) => env.db.select(env.db.nachrichten).get();

  /// Klartext der Nachrichten dieser Person (Anna) nach dem Entschlüsseln.
  Future<List<String>> meineTexte(TestUmgebung env) async {
    final a = aufbauten[env]!;
    return [
      for (final n in await alleNachrichten(env))
        if (n.autorId == fixIdAdmin)
          n.inhalt.startsWith('l1:')
              ? n.inhalt.substring(3)
              : (await a.annasKrypto.nachrichtOeffnen(konversationId: n.konversationId, nachrichtId: n.id, autorId: n.autorId, wire: n.inhalt, antwortAuf: n.antwortAuf)).text,
    ];
  }

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
    final n = (await alleNachrichten(env)).firstWhere((n) => n.autorId == fixIdAdmin);
    expect(n.inhalt, 'l1:Klar, bin dabei 🎉', reason: 'Klartext nur lokal');
    expect(n.rev, 0);
    expect(n.autorId, fixIdAdmin);
    expect(tester.widget<TextField>(eingabe()).controller!.text, isEmpty);
    // wieder Netz: der Server bekommt die Nachricht mit der Hülle
    env.sync.offline = false;
    await tester.pump(const Duration(seconds: 40));
    await warte(tester, 10);
    // der Server bekommt nur die verschlüsselte Hülle, nie den Klartext
    final gesendet = env.sync.zeilen.values.where((z) => z.entity == 'nachricht' && z.fields['autorId'] == fixIdAdmin);
    expect(gesendet.single.fields['text'], startsWith('e1:'));
    expect(gesendet, hasLength(1));
    expect(gesendet.single.fields['text'], isNot(contains('Klar')));
    expect(await meineTexte(env), ['Klar, bin dabei 🎉']);
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
    final antwort = (await alleNachrichten(env)).firstWhere((n) => n.autorId == fixIdAdmin);
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
    expect(await meineTexte(env), ['Ja, um 18 Uhr']);
    // eigene Nachricht löschen
    await tippeText(tester, 'Ja, um 18 Uhr');
    await tippeText(tester, 'Löschen');
    await tippeText(tester, 'Löschen'); // Bestätigen
    await warte(tester, 10);
    expect(find.text('Ja, um 18 Uhr'), findsNothing);
    expect(await meineTexte(env), isEmpty);
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

  testWidgets('nicht lesbare Nachrichten (Epoche ohne Schlüssel): kein Klartext, Hinweis "warte auf Schlüssel"', (tester) async {
    await start(tester, vorher: (env, a) async {
      await grundstand(env, a);
      // gültige Hülle, aber mit einer Epoche (7), für die Anna keinen Schlüssel hat
      final wire = HuellenCodec(a.crypto).versiegeln(
        schluessel: a.crypto.zufall(32),
        klartext: utf8Bytes('Z2VoZWlt'),
        kontext: HuellenKontext(conversationId: _famChat, messageId: 'a0000000-0000-4000-8000-000000000009', senderId: a.ben.id, epoch: 7, senderKeyVersion: 1),
        signGeheim: a.ben.pk.signGeheim,
      );
      env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000009', {'konversationId': _famChat, 'text': 'e1:$wire', 'autorId': fixIdKind, 'createdAt': vor(1)});
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
    final env = await start(tester, vorher: (e, a) => grundstand(e, a, gruppe: false));
    await tippeText(tester, 'Neuer Chat');
    await tippeText(tester, 'Cora Berger');
    expect(find.text('Chat starten'), findsOneWidget);
    await tippeText(tester, 'Chat starten');
    // Pflicht: Mitglieder und Sicherheitscode zeigen, erst dann wird angelegt
    expect(find.text('Direktchat starten'), findsOneWidget);
    expect(find.textContaining('Vergleiche diesen Code'), findsOneWidget);
    await tippeText(tester, 'Starten');
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
    await tippeText(tester, 'Chat starten'); // vorhandener Chat: ohne Rückfrage
    await warte(tester, 10);
    expect((await env.db.select(env.db.konversationen).get()).where((k) => k.art == 'direct'), hasLength(2));
  });

  testWidgets('Neuer Chat: mehrere Personen ergeben eine Gruppe mit optionalem Namen; die eigene Person ist dabei', (tester) async {
    final env = await start(tester, vorher: (e, a) => grundstand(e, a, gruppe: false));
    await tippeText(tester, 'Neuer Chat');
    await tippeText(tester, 'Ben');
    await tippeText(tester, 'Cora Berger');
    expect(find.text('Gruppe anlegen'), findsOneWidget);
    await eingeben(tester, 'Gruppenname (optional)', 'Skiurlaub');
    await tippeText(tester, 'Gruppe anlegen');
    expect(find.text('Gruppe anlegen'), findsOneWidget); // Titel der Bestätigung (Mitglieder und Sicherheitscode)
    await tippeText(tester, 'Anlegen');
    await warte(tester, 10);
    final g = (await env.db.select(env.db.konversationen).get()).firstWhere((k) => k.art == 'group');
    expect(g.titel, 'p1:Skiurlaub');
    expect(teilnehmerIds(g), [fixIdAdmin, fixIdKind, _cora]..sort());
    expect(find.text('Skiurlaub'), findsOneWidget); // Kopf des Verlaufs
    expect(find.textContaining('3 teilnehmer'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets); // Schloss im Kopf: Ende-zu-Ende verschlüsselt
  });

  testWidgets('Neuer Chat ohne weitere Mitglieder: Hinweis statt leerer Liste', (tester) async {
    await start(tester, vorher: (env, a) {
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
    await start(tester, skala: 1.5, vorher: (env, a) async {
      await grundstand(env, a);
      await a.nachricht(_famChat, 'a0000000-0000-4000-8000-0000000000aa', a.ben, '${'Wort ' * 80}${'x' * 120}', vor(2));
      env.sync.andereAendert('konversation', 'bbbbbbbb-0000-4000-8000-0000000000b2', {
        'art': 'group',
        'encVersion': 'e1',
        'titel': 'p1:Ein sehr langer Gruppenname der nicht in eine Zeile passt',
        'teilnehmer': [fixIdAdmin, fixIdKind]..sort(),
        'ownerId': fixIdKind,
        'createdAt': vor(100),
      });
      await a.epoche('bbbbbbbb-0000-4000-8000-0000000000b2', [a.anna, a.ben]);
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
    expect(find.text('Teilnehmer ändern?'), findsOneWidget, reason: 'auch das Entfernen zeigt die Mitglieder und den Sicherheitscode');
    await tippeText(tester, 'Ändern');
    await warte(tester, 10);
    var g = await (env.db.select(env.db.konversationen)..where((k) => k.id.equals('bbbbbbbb-0000-4000-8000-0000000000b1'))).getSingle();
    expect(teilnehmerIds(g), [fixIdAdmin, fixIdKind]..sort());
    // neue Epoche nur für die Verbleibenden: Cora bekommt keinen Wrap der neuen Epoche
    final wraps = await env.db.select(env.db.epocheWraps).get();
    expect(wraps.where((w) => w.konversationId == g.id && w.epoche == 2).map((w) => w.empfaengerId).toSet(), {fixIdAdmin, fixIdKind});
    await tester.tap(find.byTooltip('Gruppe verwalten'));
    await warte(tester);
    await tippeText(tester, 'Teilnehmer ändern');
    await tippeText(tester, 'Cora Berger');
    await tippeText(tester, 'Übernehmen');
    expect(find.text('Mitglieder prüfen und hinzufügen'), findsOneWidget);
    expect(find.text('Bisherigen Verlauf mit den Neuen teilen'), findsOneWidget);
    expect(find.textContaining('Vergleiche diesen Code'), findsOneWidget);
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
    await start(tester, vorher: (env, a) async {
      await grundstand(env, a);
      // Nachricht des Direktchats als Bezug
      await a.nachricht(_famChat, 'a0000000-0000-4000-8000-0000000000cc', a.ben, 'Bezug auf fremden Chat', vor(1), antwortAuf: 'a0000000-0000-4000-8000-000000000003');
    });
    await tippeText(tester, 'Ben: Bezug auf fremden Chat');
    expect(find.text('Nachricht nicht verfügbar'), findsOneWidget);
    expect(find.text('Kommst du zum Training?'), findsNothing);
  });

  testWidgets('Desktop: Lesestand nur bei sichtbarem Chat-Bereich; beim Zurückwechseln wird nachgeholt', (tester) async {
    final env = await angemeldeteUmgebung();
    final a = ChatUiAufbau(env);
    env.extraOverrides.addAll(a.overrides);
    await grundstand(env, a);
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
    await a.nachricht(dm, 'a0000000-0000-4000-8000-0000000000dd', a.ben, 'Bist du da?', vor(0));
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
      expect(await meineTexte(env), ['Erste Zeile']);
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

  group('Lesebestätigung (Haken) und Profilbilder im Chat', () {
    final dm = direktChatId(fixIdAdmin, fixIdKind);

    Future<void> mitEigenerNachricht(TestUmgebung env, ChatUiAufbau a, {String? benGelesenBis}) async {
      await grundstand(env, a);
      await a.nachricht(dm, 'a0000000-0000-4000-8000-000000000009', a.anna, 'Ja, ich komme', vor(5));
      if (benGelesenBis != null) {
        env.sync.andereAendert('lesestand', lesestandId(dm, fixIdKind), {'konversationId': dm, 'userId': fixIdKind, 'gelesenBis': benGelesenBis});
      }
    }

    testWidgets('eigene Nachricht, beim Server angekommen: ein Haken ("gesendet"), nach dem Lesestand des Partners zwei ("gelesen")', (tester) async {
      await start(tester, vorher: (env, a) => mitEigenerNachricht(env, a));
      await tippeText(tester, 'Du: Ja, ich komme');
      expect(find.byTooltip('gesendet'), findsOneWidget);
      expect(find.byTooltip('gelesen'), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsNothing);
      pruefeLayout(tester, 'Chatverlauf mit Haken');
    });

    testWidgets('Lesestand des Partners nach der Nachricht: zwei Haken in der Akzentfarbe; ein älterer Lesestand zählt nicht', (tester) async {
      await start(tester, vorher: (env, a) => mitEigenerNachricht(env, a, benGelesenBis: vor(1)));
      await tippeText(tester, 'Du: Ja, ich komme');
      expect(find.byTooltip('gelesen'), findsOneWidget);
      final haken = tester.widget<Icon>(find.byIcon(Icons.done_all));
      expect(haken.color, kAccent);
      await tester.pumpWidget(const SizedBox());
      await start(tester, vorher: (env, a) => mitEigenerNachricht(env, a, benGelesenBis: vor(8)));
      await tippeText(tester, 'Du: Ja, ich komme');
      expect(find.byTooltip('gesendet'), findsOneWidget);
    });

    testWidgets('Familienchat: zwei Haken erst, wenn ALLE anderen gelesen haben', (tester) async {
      await start(tester, vorher: (env, a) async {
        await grundstand(env, a);
        await a.nachricht(_famChat, 'a0000000-0000-4000-8000-000000000008', a.anna, 'Ich bin zu Hause', vor(2));
        env.sync.andereAendert('lesestand', lesestandId(_famChat, fixIdKind), {'konversationId': _famChat, 'userId': fixIdKind, 'gelesenBis': vor(1)});
      });
      await tippeText(tester, 'Du: Ich bin zu Hause');
      expect(find.byTooltip('gelesen'), findsNothing, reason: 'Cora hat noch nicht gelesen');
      expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('1 von 2')), findsOneWidget);
    });

    testWidgets('Familienchat: ein später hinzugekommenes Mitglied ohne Lesestand setzt gelesene Nachrichten nicht auf einen Haken zurück', (tester) async {
      await start(tester, vorher: (env, a) async {
        await grundstand(env, a);
        env.server.json('GET /members', {
          'members': [
            userJson(),
            userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
            userJson(id: _cora, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
            userJson(id: 'dddddddd-0000-4000-8000-0000000000d1', role: 'child', name: 'Dora Neu', email: 'dora@beispiel.de'),
          ],
        });
        await a.nachricht(_famChat, 'a0000000-0000-4000-8000-000000000008', a.anna, 'Alle gelesen', vor(2));
        for (final p in [fixIdKind, _cora]) {
          env.sync.andereAendert('lesestand', lesestandId(_famChat, p), {'konversationId': _famChat, 'userId': p, 'gelesenBis': vor(1)});
        }
      });
      await tippeText(tester, 'Du: Alle gelesen');
      expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('gelesen von allen')), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });

    testWidgets('Direktchat und Chatliste zeigen das Benutzerbild des Partners (Platzhalter), nicht nur Initialen', (tester) async {
      await start(tester, vorher: (env, a) async {
        await grundstand(env, a);
        env.server.json('GET /members', {
          'members': [
            userJson(),
            {...userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'), 'avatar': {'kind': 'preset', 'id': 'V01', 'version': 1}},
            userJson(id: _cora, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
          ],
        });
      });
      PersonAvatar ben() => tester.widgetList<PersonAvatar>(find.byType(PersonAvatar)).firstWhere((p) => p.name == 'Ben');
      expect(ben().bild, isA<AssetImage>());
      await tippeText(tester, 'Kommst du zum Training?');
      expect(tester.widgetList<PersonAvatar>(find.byType(PersonAvatar)).where((p) => p.name == 'Ben' && p.bild != null), isNotEmpty, reason: 'auch in der Kopfzeile des Verlaufs');
    });
  });

  group('Ausgang: Fehlerzustand', () {
    Future<void> sendeAbgelehnt(WidgetTester tester, TestUmgebung env) async {
      await tippeText(tester, 'Kommst du zum Training?');
      env.sync.ablehnung = (op) => op['entity'] == 'nachricht' ? 'forbidden' : null;
      await tester.enterText(eingabe(), 'Das klappt nicht');
      await tester.pump();
      await tippe(tester, find.byTooltip('Senden'));
      await tester.pump(const Duration(seconds: 40));
      await warte(tester, 10);
    }

    testWidgets('abgelehnte Nachricht bleibt mit Fehlersymbol (kDanger, Tooltip deutsch), Aktionen Erneut senden / Verwerfen; 360 px, Textskala 1.5', (tester) async {
      final env = await start(tester, skala: 1.5, vorher: grundstand);
      await sendeAbgelehnt(tester, env);
      expect(find.text('Das klappt nicht'), findsOneWidget, reason: 'die Nachricht verschwindet nicht');
      expect(find.text('nicht gesendet · tippen'), findsOneWidget);
      final symbol = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(symbol.color, kDanger);
      expect(symbol.semanticLabel, startsWith('Senden fehlgeschlagen'));
      expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Senden fehlgeschlagen')), findsOneWidget);
      final op = (await env.db.select(env.db.outbox).get()).single;
      expect(op.fehlerCode, 'forbidden');
      expect(tester.widget<Text>(find.text('nicht gesendet · tippen')).style?.color, kDanger);
      pruefeLayout(tester, 'abgelehnte Nachricht');
      await tippeText(tester, 'Das klappt nicht');
      expect(find.text('Erneut senden'), findsOneWidget);
      expect(find.text('Verwerfen'), findsOneWidget);
      expect(find.text('Text kopieren'), findsOneWidget);
      expect(find.text('Antworten'), findsNothing);
      expect(find.textContaining('Senden fehlgeschlagen.'), findsOneWidget);
      pruefeLayout(tester, 'Aktionen der abgelehnten Nachricht');
    });

    testWidgets('Chatliste zeigt für einen Chat mit abgelehnter Nachricht ein Fehlersymbol (360 px, Textskala 1.5); nach Verwerfen verschwindet es', (tester) async {
      final env = await start(tester, skala: 1.5, vorher: grundstand);
      await sendeAbgelehnt(tester, env);
      await tester.tap(find.byTooltip('Zurück zur Chatliste'));
      await warte(tester);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.error_outline)).color, kDanger);
      expect(find.bySemanticsLabel(RegExp('Nachricht nicht gesendet')), findsOneWidget);
      pruefeLayout(tester, 'Chatliste mit Fehler');
      await tippeText(tester, 'Ben');
      await tippeText(tester, 'Das klappt nicht');
      await tippeText(tester, 'Verwerfen');
      await tester.tap(find.byTooltip('Zurück zur Chatliste'));
      await warte(tester);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('Erneut senden: dieselbe Nachricht geht noch einmal hinaus, keine zweite entsteht', (tester) async {
      final env = await start(tester, vorher: grundstand);
      await sendeAbgelehnt(tester, env);
      final id = (await alleNachrichten(env)).firstWhere((n) => n.autorId == fixIdAdmin).id;
      env.sync.ablehnung = null;
      await tippeText(tester, 'Das klappt nicht');
      await tippeText(tester, 'Erneut senden');
      await tester.pump(const Duration(seconds: 40));
      await warte(tester, 10);
      expect(find.text('nicht gesendet · tippen'), findsNothing);
      expect(find.text('wird gesendet'), findsNothing);
      final eigene = (await alleNachrichten(env)).where((n) => n.autorId == fixIdAdmin);
      expect(eigene.map((n) => n.id), [id]);
      expect(eigene.single.rev, greaterThan(0));
      expect(env.sync.zeilen.values.where((z) => z.entity == 'nachricht' && z.fields['autorId'] == fixIdAdmin), hasLength(1));
      expect(await env.db.select(env.db.outbox).get(), isEmpty);
    });

    testWidgets('Verwerfen: Nachricht und Op verschwinden, nichts geht zum Server', (tester) async {
      final env = await start(tester, vorher: grundstand);
      await sendeAbgelehnt(tester, env);
      await tippeText(tester, 'Das klappt nicht');
      await tippeText(tester, 'Verwerfen');
      await warte(tester);
      expect(find.text('Das klappt nicht'), findsNothing);
      expect((await alleNachrichten(env)).where((n) => n.autorId == fixIdAdmin), isEmpty);
      expect(await env.db.select(env.db.outbox).get(), isEmpty);
      expect(env.sync.zeilen.values.where((z) => z.entity == 'nachricht' && z.fields['autorId'] == fixIdAdmin), isEmpty);
    });

    testWidgets('hängt: nach mehr als zwei Minuten ohne Fortschritt ein sanfter Hinweis statt des Fehlers', (tester) async {
      final env = await start(tester, vorher: grundstand);
      await tippeText(tester, 'Kommst du zum Training?');
      env.sync.offline = true;
      await tester.enterText(eingabe(), 'Warte auf Netz');
      await tester.pump();
      await tippe(tester, find.byTooltip('Senden'));
      await warte(tester, 10);
      expect(find.text('wird gesendet'), findsOneWidget);
      expect(find.text('wartet auf Verbindung oder Schlüssel'), findsNothing);
      await (env.db.update(env.db.outbox)).write(OutboxCompanion(createdAt: Value(DateTime.now().subtract(const Duration(minutes: 3)))));
      await warte(tester, 10);
      expect(find.text('wartet auf Verbindung oder Schlüssel'), findsOneWidget);
      expect(find.text('wird gesendet'), findsNothing);
      expect(find.text('nicht gesendet · tippen'), findsNothing);
      expect(tester.widget<Icon>(find.byIcon(Icons.schedule)).color, kWarn);
      pruefeLayout(tester, 'hängende Nachricht');
    });
  });
}
