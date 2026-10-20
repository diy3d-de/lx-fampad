// Oberfläche der Chat-Verschlüsselung: Hinweis zum Einrichten (Chat-Bereich und Verlauf), Schloss im Kopf, Personen ohne Schlüssel in der Auswahl,
// Bestätigung der Mitglieder mit Sicherheitscode (Pflicht beim Hinzufügen), Verlauf teilen, Warnung bei Schlüsselwechsel, Altbestand ohne Verschlüsselung.
// Layout bei 360 px und Textskala 1.5.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/vertrauen.dart';

import 'support/chat_ui_aufbau.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _gruppe = 'bbbbbbbb-0000-4000-8000-0000000000b1';
String vor(int minuten) => DateTime.now().toUtc().subtract(Duration(minutes: minuten)).toIso8601String();

Future<void> zumChatTab(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
  await warte(tester);
}

Finder eingabe() => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'Nachricht');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<(TestUmgebung, ChatUiAufbau)> start(
    WidgetTester tester, {
    E2eeStatus status = E2eeStatus.bereit,
    Set<String> ohneSchluessel = const {},
    double skala = 1.0,
    FutureOr<void> Function(TestUmgebung env, ChatUiAufbau a)? vorher,
    bool chat = true,
  }) async {
    final env = await angemeldeteUmgebung();
    final a = ChatUiAufbau(env, status: status, ohneSchluessel: ohneSchluessel);
    env.extraOverrides.addAll(a.overrides);
    env.server.json('GET /members', {
      'members': [
        userJson(),
        userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
        userJson(id: coraId, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
      ],
    });
    await vorher?.call(env, a);
    await starteApp(tester, env, skala: skala, groesse: const Size(360, 800));
    if (chat) await zumChatTab(tester);
    return (env, a);
  }

  /// Gruppe mit allen dreien (verschlüsselt, Epoche 1 von Ben) und ein Direktchat mit Ben.
  Future<void> gruppeUndDirekt(TestUmgebung env, ChatUiAufbau a) async {
    env.sync.andereAendert('konversation', _gruppe, {
      'art': 'group',
      'encVersion': 'e1',
      'titel': 'p1:Wochenendausflug',
      'teilnehmer': [fixIdAdmin, fixIdKind, coraId]..sort(),
      'ownerId': fixIdKind,
      'createdAt': vor(200),
    });
    await a.epoche(_gruppe, [a.anna, a.ben, a.cora]);
    await a.nachricht(_gruppe, 'a0000000-0000-4000-8000-000000000001', a.ben, 'Wer fährt?', vor(20));
    final dm = direktChatId(fixIdAdmin, fixIdKind);
    env.sync.andereAendert('konversation', dm, {'art': 'direct', 'encVersion': 'e1', 'titel': '', 'teilnehmer': [fixIdAdmin, fixIdKind]..sort(), 'ownerId': fixIdKind, 'createdAt': vor(100)});
    await a.epoche(dm, [a.anna, a.ben]);
    await a.nachricht(dm, 'a0000000-0000-4000-8000-000000000002', a.ben, 'Hallo Anna', vor(10));
  }

  testWidgets('ohne eingerichteten Schlüssel: Hinweis "Verschlüsselung einrichten", Neuer Chat gesperrt, kein Eingabefeld im Verlauf', (tester) async {
    await start(tester, status: E2eeStatus.keinSchluessel, vorher: gruppeUndDirekt);
    expect(find.text('Verschlüsselung einrichten'), findsOneWidget);
    expect(find.text('Einrichten'), findsOneWidget);
    final knopf = tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('Neuer Chat'), matching: find.bySubtype<ButtonStyleButton>()).first);
    expect(knopf.onPressed, isNull);
    // ohne Schlüssel sind Nachrichten nicht lesbar und es gibt kein Eingabefeld
    expect(find.text('Ben: Nachricht nicht lesbar'), findsOneWidget);
    await tippeText(tester, 'Ben: Nachricht nicht lesbar');
    expect(eingabe(), findsNothing);
    expect(find.text('Verschlüsselung einrichten'), findsOneWidget, reason: 'Hinweis statt der Eingabe');
    pruefeLayout(tester, 'Hinweis Einrichten');
  });

  testWidgets('Schlüssel nicht auf diesem Gerät: Hinweis "Gerät verbinden"', (tester) async {
    await start(tester, status: E2eeStatus.geraetNichtVerbunden);
    expect(find.text('Gerät verbinden'), findsOneWidget);
    expect(find.text('Verbinden'), findsOneWidget);
  });

  testWidgets('Verlauf: Schloss und "ende-zu-ende verschlüsselt" im Kopf, Eingabe vorhanden', (tester) async {
    await start(tester, vorher: gruppeUndDirekt);
    expect(find.text('Verschlüsselung einrichten'), findsNothing);
    await tippeText(tester, 'Hallo Anna');
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.textContaining('ende-zu-ende verschlüsselt'), findsOneWidget);
    expect(find.bySemanticsLabel('Ende-zu-Ende verschlüsselt'), findsOneWidget);
    expect(eingabe(), findsOneWidget);
    expect(find.text('Hallo Anna'), findsOneWidget);
  });

  testWidgets('Altbestand ohne Verschlüsselung (p1): lesbar, aber kein Eingabefeld und ein klarer Hinweis', (tester) async {
    await start(tester, vorher: (env, a) async {
      env.sync.andereAendert('konversation', _gruppe, {'art': 'group', 'encVersion': 'p1', 'titel': 'p1:Alt', 'teilnehmer': [fixIdAdmin, fixIdKind]..sort(), 'ownerId': fixIdKind, 'createdAt': vor(200)});
      env.sync.andereAendert('nachricht', 'a0000000-0000-4000-8000-000000000001', {'konversationId': _gruppe, 'text': 'p1:alter Klartext', 'autorId': fixIdKind, 'createdAt': vor(20)});
    });
    await tippeText(tester, 'Ben: alter Klartext');
    expect(find.text('alter Klartext'), findsOneWidget);
    expect(eingabe(), findsNothing);
    expect(find.textContaining('nicht verschlüsselt'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
  });

  testWidgets('Neuer Chat: Person ohne eingerichtete Verschlüsselung ist markiert und lässt sich nicht wählen', (tester) async {
    await start(tester, ohneSchluessel: {coraId});
    await tippeText(tester, 'Neuer Chat');
    expect(find.text('Verschlüsselung noch nicht eingerichtet'), findsOneWidget);
    await tester.tap(find.text('Cora Berger'));
    await warte(tester);
    // nicht gewählt: kein Knopf "Chat starten" aktiv
    final starten = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Chat starten'));
    expect(starten.onPressed, isNull);
    await tippeText(tester, 'Ben');
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Chat starten')).onPressed, isNotNull);
    pruefeLayout(tester, 'Personenwahl mit Hinweis');
  });

  testWidgets('Mitglieder prüfen: Namen, Schlüsselversion und Sicherheitscode werden gezeigt; Abbrechen legt nichts an', (tester) async {
    final (env, _) = await start(tester, skala: 1.5);
    await tippeText(tester, 'Neuer Chat');
    await tippeText(tester, 'Ben');
    await tippeText(tester, 'Cora Berger');
    await tippeText(tester, 'Gruppe anlegen');
    expect(find.text('Gruppe anlegen'), findsOneWidget);
    expect(find.text('12345 67890 12345 67890 12345 67890'), findsOneWidget);
    expect(find.textContaining('Vergleiche diesen Code'), findsOneWidget);
    expect(find.text('Anna (du)'), findsOneWidget);
    expect(find.text('schlüssel v1'), findsWidgets);
    pruefeLayout(tester, 'Mitgliederdialog 1.5');
    await tippeText(tester, 'Abbrechen');
    expect((await env.db.select(env.db.konversationen).get()).where((k) => k.art != 'family'), isEmpty, reason: 'nur der Familienchat, keine Gruppe');
  });

  testWidgets('Gruppe: Neue mit "Verlauf teilen" bekommen die älteren Epochen, ohne den Haken nur die neue', (tester) async {
    final (env, _) = await start(tester, vorher: (env, a) async {
      env.sync.andereAendert('konversation', _gruppe, {
        'art': 'group',
        'encVersion': 'e1',
        'titel': 'p1:Wochenendausflug',
        'teilnehmer': [fixIdAdmin, fixIdKind]..sort(),
        'ownerId': fixIdKind,
        'createdAt': vor(200),
      });
      await a.epoche(_gruppe, [a.anna, a.ben]);
      await a.nachricht(_gruppe, 'a0000000-0000-4000-8000-000000000001', a.ben, 'Wer fährt?', vor(20));
    });
    await tippeText(tester, 'Wochenendausflug');
    Future<void> hinzufuegen({required bool verlauf}) async {
      await tester.tap(find.byTooltip('Gruppe verwalten'));
      await warte(tester);
      await tippeText(tester, 'Teilnehmer ändern');
      await tippeText(tester, 'Cora Berger');
      await tippeText(tester, 'Übernehmen');
      expect(find.text('Mitglieder prüfen und hinzufügen'), findsOneWidget);
      expect(find.text('neu'), findsOneWidget);
      if (verlauf) await tippeText(tester, 'Bisherigen Verlauf mit den Neuen teilen');
      await tippeText(tester, 'Hinzufügen');
      await warte(tester, 10);
    }

    await hinzufuegen(verlauf: true);
    var wraps = await env.db.select(env.db.epocheWraps).get();
    final fuerCora = wraps.where((w) => w.empfaengerId == coraId).map((w) => w.epoche).toSet();
    expect(fuerCora, {1, 2}, reason: 'Epoche 2 (neu) und Epoche 1 (Verlauf geteilt)');
    // zum Server: nur undurchsichtige Wraps, kein Klartext
    await tester.pump(const Duration(seconds: 40));
    await warte(tester, 10);
    expect(env.sync.zeilen.values.where((z) => z.entity == 'epoche_wrap' && z.fields['empfaengerId'] == coraId), isNotEmpty);
    wraps = await env.db.select(env.db.epocheWraps).get();
    expect(wraps.every((w) => !w.wrap.contains('Wer fährt')), isTrue);
  });

  testWidgets('Gruppe verlassen und Teilnehmer entfernen: neue Epoche nur für die Verbleibenden, Hinweis im Dialog', (tester) async {
    final (env, _) = await start(tester, vorher: gruppeUndDirekt);
    await tippeText(tester, 'Wochenendausflug');
    await tester.tap(find.byTooltip('Gruppe verwalten'));
    await warte(tester);
    await tippeText(tester, 'Teilnehmer ändern');
    await tippeText(tester, 'Cora Berger'); // abwählen
    await tippeText(tester, 'Übernehmen');
    expect(find.textContaining('Sie können neue Nachrichten nicht mehr lesen'), findsOneWidget);
    await tippeText(tester, 'Ändern');
    await warte(tester, 10);
    final wraps = await env.db.select(env.db.epocheWraps).get();
    expect(wraps.where((w) => w.epoche == 2).map((w) => w.empfaengerId).toSet(), {fixIdAdmin, fixIdKind});
  });

  testWidgets('Warnung bei Schlüsselwechsel einer Person im Chat: sichtbar im Verlauf, führt zur Verschlüsselung', (tester) async {
    final env = await angemeldeteUmgebung();
    final a = ChatUiAufbau(env);
    a.warnungen = [SchluesselWarnung(userId: fixIdKind, gemerkt: GemerkterSchluessel(a.ben.oeffentlich.enc, a.ben.oeffentlich.sign, 1), aktuell: a.ben.oeffentlich)];
    env.extraOverrides.addAll(a.overrides);
    env.server.json('GET /members', {
      'members': [userJson(), userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de')],
    });
    await gruppeUndDirekt(env, a);
    await starteApp(tester, env, groesse: const Size(360, 800), skala: 1.5);
    await zumChatTab(tester);
    await tippeText(tester, 'Hallo Anna');
    expect(find.textContaining('Der Schlüssel von Ben hat sich geändert'), findsOneWidget);
    expect(find.text('Prüfen'), findsOneWidget);
    pruefeLayout(tester, 'Warnung Schlüsselwechsel');
  });
}
