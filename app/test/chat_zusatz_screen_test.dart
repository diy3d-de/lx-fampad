// Chat-Erweiterungen in der Oberfläche: Reaktionen (Menü, Chips, Zurücknehmen), Umfrage (Karte, Abstimmen, Erstellen), Anheften (Leiste, Liste, Rechte) bei 360 px und
// Textskala 1.5 (keine Überläufe, Tipp-Flächen mindestens 44 px).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_zusatz_inhalt.dart';

import 'support/chat_ui_aufbau.dart';
import 'support/chat_welt.dart' show TestPerson;
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _famChat = '44444444-4444-4444-8444-444444444444';
const _n1 = 'a0000000-0000-4000-8000-000000000001';
const _n2 = 'a0000000-0000-4000-8000-000000000002';

String vor(int minuten) => DateTime.now().toUtc().subtract(Duration(minutes: minuten)).toIso8601String();

Finder eingabe() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Nachricht');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  final aufbauten = <TestUmgebung, ChatUiAufbau>{};

  /// Familienchat mit zwei Nachrichten (Ben, Cora); [mehr] legt weitere Dinge "vom Server" an.
  Future<TestUmgebung> start(WidgetTester tester, {String role = 'admin', double skala = 1.0, FutureOr<void> Function(TestUmgebung env, ChatUiAufbau a)? mehr}) async {
    final env = await angemeldeteUmgebung(role: role);
    final a = ChatUiAufbau(env);
    aufbauten[env] = a;
    env.extraOverrides.addAll(a.overrides);
    env.server.json('GET /members', {
      'members': [
        userJson(),
        userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
        userJson(id: coraId, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
      ],
    });
    env.sync.andereAendert('konversation', _famChat, {'art': 'family', 'encVersion': 'e1', 'titel': '', 'teilnehmer': <String>[], 'ownerId': null, 'createdAt': vor(600)});
    await a.epoche(_famChat, [a.anna, a.ben, a.cora], art: 'family');
    await a.nachricht(_famChat, _n1, a.ben, 'Wer holt heute die Kinder ab?', vor(30));
    await a.nachricht(_famChat, _n2, a.cora, 'Ich kann das machen', vor(20));
    await mehr?.call(env, a);
    await starteApp(tester, env, skala: skala, groesse: const Size(360, 800));
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
    await warte(tester);
    await tippe(tester, find.textContaining('Cora:'));
    await warte(tester, 20);
    return env;
  }

  Future<void> reaktionVon(ChatUiAufbau a, TestPerson wer, String nachricht, String emoji) async {
    final id = reaktionId(nachricht, wer.id);
    a.env.sync.andereAendert('reaktion', id, {
      'konversationId': _famChat,
      'nachrichtId': nachricht,
      'userId': wer.id,
      'inhalt': await a.verschluesselt(_famChat, id, wer, reaktionKodieren(emoji), antwortAuf: nachricht, art: 'r'),
      'createdAt': vor(5),
    });
  }

  Future<void> stimmeVon(ChatUiAufbau a, TestPerson wer, String nachricht, Set<int> optionen) async {
    final id = stimmeId(nachricht, wer.id);
    a.env.sync.andereAendert('stimme', id, {
      'konversationId': _famChat,
      'nachrichtId': nachricht,
      'userId': wer.id,
      'inhalt': await a.verschluesselt(_famChat, id, wer, stimmeKodieren(optionen), antwortAuf: nachricht, art: 's'),
      'createdAt': vor(5),
      'geaendertAt': null,
    });
  }

  const umfrageId = 'a0000000-0000-4000-8000-0000000000f1';
  Future<void> umfrageVon(ChatUiAufbau a, TestPerson wer, {bool mehrfach = false, DateTime? ende}) => a.nachricht(
    _famChat,
    umfrageId,
    wer,
    umfrageKodieren(frage: 'Wann Treffen?', optionen: ['Samstag', 'Sonntag', 'Montag'], mehrfach: mehrfach, ende: ende),
    vor(2),
  );

  testWidgets('Reaktionen anderer erscheinen als Chips mit Zähler, Tooltip und Beschriftung nennen die Personen; 360 px, Textskala 1.5', (tester) async {
    await start(tester, skala: 1.5, mehr: (env, a) async {
      await reaktionVon(a, a.ben, _n2, '👍');
      await reaktionVon(a, a.cora, _n2, '👍');
      await reaktionVon(a, a.cora, _n1, '❤️');
    });
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('❤️'), findsOneWidget);
    await warte(tester, 20); // Mitglieder (Namen) laden unabhängig vom Verlauf
    expect(find.bySemanticsLabel(RegExp(r'👍 2, von (Ben, Cora Berger|Cora Berger, Ben).')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message == 'Ben, Cora Berger' || w.message == 'Cora Berger, Ben')), findsOneWidget);
    pruefeLayout(tester, 'Verlauf mit Reaktionen');
  });

  testWidgets('Reagieren über das Menü der Nachricht, erneutes Antippen des Chips nimmt zurück; der Ausgang trägt nur lokalen Klartext', (tester) async {
    final env = await start(tester);
    await tippeText(tester, 'Ich kann das machen');
    expect(find.bySemanticsLabel('Mit 👍 reagieren'), findsOneWidget);
    await tippe(tester, find.bySemanticsLabel('Mit 👍 reagieren'));
    await warte(tester, 10);
    final zeilen = await env.db.select(env.db.reaktionen).get();
    expect(zeilen.single.id, reaktionId(_n2, fixIdAdmin));
    expect(zeilen.single.nachrichtId, _n2);
    expect(find.text('👍'), findsOneWidget);
    // beim Server ist es nur eine Hülle (e1), nie das Emoji
    final serverZeile = env.sync.zeilen.entries.where((e) => e.key.startsWith('reaktion/'));
    for (final z in serverZeile) {
      expect(z.value.toString(), isNot(contains('👍')));
    }
    // ersetzen: anderes Emoji, weiterhin eine Reaktion
    await tippeText(tester, 'Ich kann das machen');
    await tippe(tester, find.bySemanticsLabel('Mit ❤️ reagieren'));
    await warte(tester, 10);
    expect(await env.db.select(env.db.reaktionen).get(), hasLength(1));
    expect(find.text('❤️'), findsOneWidget);
    expect(find.text('👍'), findsNothing);
    // Chip antippen nimmt die eigene Reaktion zurück
    await tippe(tester, find.text('❤️'));
    await warte(tester, 10);
    expect(await env.db.select(env.db.reaktionen).get(), isEmpty);
    expect(find.text('❤️'), findsNothing);
  });

  testWidgets('Umfrage: Karte mit Antworten, Stimmen und Namen; Abstimmen (Einzelwahl) ersetzt die Stimme, erneutes Antippen nimmt sie zurück; 360 px, Textskala 1.5', (tester) async {
    final env = await start(tester, skala: 1.5, mehr: (env, a) async {
      await umfrageVon(a, a.cora);
      await stimmeVon(a, a.ben, umfrageId, {1});
    });
    expect(find.text('Wann Treffen?'), findsOneWidget);
    expect(find.text('Samstag'), findsOneWidget);
    expect(find.text('Sonntag'), findsOneWidget);
    expect(find.textContaining('1 Person hat abgestimmt'), findsOneWidget);
    expect(find.text('Ben'), findsWidgets); // wer abgestimmt hat
    pruefeLayout(tester, 'Umfrage');
    await tippeText(tester, 'Samstag');
    await warte(tester, 10);
    var stimmen = await env.db.select(env.db.stimmen).get();
    expect(stimmen.where((s) => s.userId == fixIdAdmin), hasLength(1));
    expect(find.textContaining('2 Personen haben abgestimmt'), findsOneWidget);
    // andere Antwort ersetzt, nicht dazu
    await tippeText(tester, 'Montag');
    await warte(tester, 10);
    stimmen = await env.db.select(env.db.stimmen).get();
    expect(stimmen.where((s) => s.userId == fixIdAdmin), hasLength(1));
    expect(find.textContaining('2 Personen haben abgestimmt'), findsOneWidget);
    // zurücknehmen
    await tippeText(tester, 'Montag');
    await warte(tester, 10);
    expect((await env.db.select(env.db.stimmen).get()).where((s) => s.userId == fixIdAdmin), isEmpty);
    expect(find.textContaining('1 Person hat abgestimmt'), findsOneWidget);
  });

  testWidgets('Umfrage mit Mehrfachauswahl und beendete Umfrage: abgelaufene lassen sich nicht mehr beantworten', (tester) async {
    final env = await start(tester, mehr: (env, a) async {
      await a.nachricht(_famChat, umfrageId, a.cora, umfrageKodieren(frage: 'Was essen wir?', optionen: ['Pizza', 'Pasta'], mehrfach: true), vor(2));
      await a.nachricht(
        _famChat,
        'a0000000-0000-4000-8000-0000000000f2',
        a.cora,
        umfrageKodieren(frage: 'Alte Frage', optionen: ['Ja', 'Nein'], mehrfach: false, ende: DateTime.now().subtract(const Duration(hours: 1))),
        vor(1),
      );
    });
    await tippeText(tester, 'Pizza');
    await tippeText(tester, 'Pasta');
    await warte(tester, 10);
    expect((await env.db.select(env.db.stimmen).get()).single.userId, fixIdAdmin);
    expect(find.textContaining('mehrere Antworten möglich'), findsOneWidget);
    expect(find.textContaining('beendet'), findsOneWidget);
    await tippeText(tester, 'Ja');
    await warte(tester, 10);
    expect((await env.db.select(env.db.stimmen).get()), hasLength(1), reason: 'nach dem Ende keine neue Stimme');
  });

  testWidgets('Umfrage erstellen: Eingabe prüfen, senden; die Nachricht trägt die Umfrage nur als Klartext im Ausgang, nie im Klartext zum Server', (tester) async {
    final env = await start(tester);
    await tippe(tester, find.byTooltip('Umfrage erstellen'));
    pruefeLayout(tester, 'Umfrage-Editor');
    // ohne Eingabe: Hinweis
    await tippe(tester, find.text('Umfrage senden'));
    expect(find.text('Gib eine Frage ein.'), findsOneWidget);
    await eingeben(tester, 'Frage', 'Was essen wir?');
    await eingeben(tester, 'Antwort 1', 'Pizza');
    await eingeben(tester, 'Antwort 2', 'Pasta');
    await tippe(tester, find.text('Antwort hinzufügen'));
    await eingeben(tester, 'Antwort 3', 'Salat');
    await tippe(tester, find.text('Mehrere Antworten erlauben'));
    await tippe(tester, find.text('Umfrage senden'));
    await warte(tester, 12);
    final eigene = (await env.db.select(env.db.nachrichten).get()).where((n) => n.autorId == fixIdAdmin).toList();
    expect(eigene, hasLength(1));
    expect(find.text('Was essen wir?'), findsOneWidget);
    expect(find.text('Salat'), findsOneWidget);
    for (final z in env.sync.zeilen.entries.where((e) => e.key.startsWith('nachricht/'))) {
      expect(z.value.toString(), isNot(contains('Was essen wir')));
    }
    final n = eigene.single;
    final klar = n.inhalt.startsWith('l1:')
        ? n.inhalt.substring(3)
        : (await aufbauten[env]!.annasKrypto.nachrichtOeffnen(konversationId: _famChat, nachrichtId: n.id, autorId: fixIdAdmin, wire: n.inhalt, antwortAuf: null)).text;
    final u = umfrageLesen(klar);
    expect(u?.optionen, ['Pizza', 'Pasta', 'Salat']);
    expect(u?.mehrfach, isTrue);
  });

  testWidgets('Anheften: Leiste oben, Liste und Lösen; Admin darf im Familienchat anheften', (tester) async {
    final env = await start(tester);
    expect(find.text('Angeheftet'), findsNothing);
    await tippeText(tester, 'Wer holt heute die Kinder ab?');
    await tippeText(tester, 'Anheften');
    await warte(tester, 10);
    expect((await env.db.select(env.db.pins).get()).single.id, pinId(_n1));
    expect(find.text('Angeheftet'), findsOneWidget);
    expect(find.text('Wer holt heute die Kinder ab?'), findsNWidgets(2)); // Leiste und Nachricht
    pruefeLayout(tester, 'Pin-Leiste');
    // Liste öffnen und lösen
    await tippe(tester, find.bySemanticsLabel(RegExp(r'Angeheftet: Wer holt')));
    expect(labelFinder('Angeheftete nachrichten'), findsOneWidget);
    await tippe(tester, find.byTooltip('Anheftung lösen'));
    await warte(tester, 10);
    expect(await env.db.select(env.db.pins).get(), isEmpty);
    expect(find.text('Angeheftet'), findsNothing);
  });

  testWidgets('Kinder können im Familienchat nicht anheften, sehen aber die Pins der Eltern und lösen sie nicht', (tester) async {
    final env = await start(tester, role: 'child', mehr: (env, a) async {
      env.sync.andereAendert('pin', pinId(_n1), {'konversationId': _famChat, 'nachrichtId': _n1, 'gepinntVon': coraId, 'createdAt': vor(3)});
    });
    expect(find.text('Angeheftet'), findsOneWidget);
    await tippeText(tester, 'Ich kann das machen');
    expect(find.text('Anheften'), findsNothing);
    await tester.tapAt(const Offset(5, 5)); // Menü schließen
    await warte(tester);
    await tippe(tester, find.bySemanticsLabel(RegExp(r'Angeheftet: Wer holt')));
    expect(find.byTooltip('Anheftung lösen'), findsNothing);
    expect(await env.db.select(env.db.pins).get(), hasLength(1));
  });

  testWidgets('Nicht lesbare Reaktionen werden nie als Platzhalter gezeigt', (tester) async {
    await start(tester, mehr: (env, a) async {
      final id = reaktionId(_n2, a.ben.id);
      env.sync.andereAendert('reaktion', id, {'konversationId': _famChat, 'nachrichtId': _n2, 'userId': a.ben.id, 'inhalt': 'e1:${'A' * 200}', 'createdAt': vor(5)});
    });
    expect(find.byTooltip('Ben'), findsNothing);
    expect(find.text('1'), findsNothing);
    pruefeLayout(tester, 'Verlauf');
  });
}
