// Teilen aus anderen Apps (Android): Logik (Kürzen, Bereinigen, Ziele) und Oberfläche (Annahme über den System-Kanal, Auswahl, Anlegen in Liste/Aufgabe/Chat,
// Warten bis zur Anmeldung, Verwerfen beim Abbrechen/Abmelden, Layout bei 360 px und Textskala 1.5/2.0). Der Android-Teil wird über den Kanal mit einem Fake geprüft.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart' show SessionDto;
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/teilen/teilen_logik.dart';
import 'package:lx_fampad/data/teilen/teilen_state.dart';
import 'package:lx_fampad/features/teilen/teilen_seite.dart';

import 'support/chat_ui_aufbau.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _famChat = '44444444-4444-4444-8444-444444444444';
const _l1 = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Logik', () {
    test('kürzen: Leerraum, Steuerzeichen, unsichtbare Zeichen', () {
      expect(teilenKuerzen(null), isNull);
      expect(teilenKuerzen('   \n\t '), isNull);
      expect(teilenKuerzen('  Hallo Welt  '), 'Hallo Welt');
      expect(teilenKuerzen('a\u0000b\u0007c\r\nd'), 'abc\nd');
      expect(teilenKuerzen('a${String.fromCharCode(0x200b)}b${String.fromCharCode(0x202e)}c${String.fromCharCode(0xfeff)}d'), 'abcd');
      expect(teilenKuerzen('Zeile 1\nZeile 2\tTab'), 'Zeile 1\nZeile 2\tTab');
    });

    test('kürzen: hart auf $kMaxTeilenZeichen Zeichen, nicht mitten im Zeichenpaar', () {
      final lang = '😀' * 5000;
      final k = teilenKuerzen(lang)!;
      expect(k.runes.length, kMaxTeilenZeichen);
      expect(k.endsWith('😀'), isTrue);
      expect(teilenKuerzen('x' * 100000)!.length, kMaxTeilenZeichen);
      expect(teilenWahrscheinlichGekuerzt(k), isTrue);
      expect(teilenWahrscheinlichGekuerzt('kurz'), isFalse);
    });

    test('Ziele: Listeneintrag einzeilig und höchstens 500 Zeichen', () {
      expect(eintragsText('Milch\n  und   Eier'), 'Milch und Eier');
      final e = eintragsText('a' * 900);
      expect(e.runes.length, kMaxEintragZeichen);
      expect(e.endsWith('…'), isTrue);
    });

    test('Ziele: Aufgabentitel aus der ersten Zeile, Notiz nur wenn mehr dasteht', () {
      expect(aufgabenTitel('\n\n  Zahnarzt anrufen \nNummer 0123'), 'Zahnarzt anrufen');
      expect(aufgabenNotiz('Zahnarzt anrufen', 'Zahnarzt anrufen'), '');
      expect(aufgabenNotiz('Zahnarzt anrufen\nNummer 0123', 'Zahnarzt anrufen'), 'Zahnarzt anrufen\nNummer 0123');
      final lang = 'b' * 300;
      final t = aufgabenTitel(lang);
      expect(t.runes.length, kMaxAufgabeTitelZeichen);
      expect(aufgabenNotiz(lang, t), lang);
    });

    test('Zustand: unbrauchbarer Text ersetzt nichts, verwerfen leert', () {
      final c = ProviderContainerHelfer.neu();
      addTearDown(c.dispose);
      c.read(teilenProvider.notifier).eingegangen('Eins');
      c.read(teilenProvider.notifier).eingegangen('   ');
      c.read(teilenProvider.notifier).eingegangen(null);
      expect(c.read(teilenProvider), 'Eins');
      c.read(teilenProvider.notifier).eingegangen('Zwei');
      expect(c.read(teilenProvider), 'Zwei');
      c.read(teilenProvider.notifier).verwerfen();
      expect(c.read(teilenProvider), isNull);
    });
  });

  group('Oberfläche', () {
    Future<void> teile(WidgetTester tester, String text) async {
      const codec = StandardMethodCodec();
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(kSystemChannel, codec.encodeMethodCall(MethodCall('share', text)), (_) {});
      await warte(tester);
    }

    Future<ProviderContainerHelfer> startMit(
      WidgetTester tester, {
      double skala = 1.0,
      Size groesse = const Size(360, 800),
      bool angemeldet = true,
      bool chat = false,
      void Function(TestUmgebung env)? vorher,
    }) async {
      final env = TestUmgebung(standardServer());
      if (angemeldet) await env.angemeldet();
      final a = ChatUiAufbau(env);
      env.extraOverrides.addAll(a.overrides);
      env.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
      if (chat) {
        env.sync.andereAendert('konversation', _famChat, {'art': 'family', 'encVersion': 'e1', 'titel': '', 'teilnehmer': <String>[], 'ownerId': null, 'createdAt': DateTime.now().toUtc().toIso8601String()});
        await a.epoche(_famChat, [a.anna, a.ben, a.cora], art: 'family');
      }
      vorher?.call(env);
      final container = await starteApp(tester, env, skala: skala, groesse: groesse);
      return ProviderContainerHelfer(env, container);
    }

    testWidgets('Angemeldet: geteilter Text öffnet die Auswahl, Liste: neuer Eintrag, Text danach verworfen', (tester) async {
      final h = await startMit(tester);
      await teile(tester, 'https://example.org/rezept\nSchnell und lecker');
      expect(find.byType(TeilenSeite), findsOneWidget);
      expect(find.text('Teilen mit lx-familyhub'), findsOneWidget);
      expect(find.textContaining('example.org/rezept'), findsWidgets);
      pruefeLayout(tester, 'Teilen-Auswahl');
      await tippe(tester, find.text('Zu einer Liste hinzufügen'));
      expect(find.text('In welche Liste?'), findsOneWidget);
      await tippe(tester, find.text('Einkauf'));
      expect(find.byType(TeilenSeite), findsNothing);
      final eintraege = await h.env.db.select(h.env.db.listenEintraege).get();
      expect(eintraege.single.inhalt, 'https://example.org/rezept Schnell und lecker');
      expect(eintraege.single.listId, _l1);
      expect(h.container.read(teilenProvider), isNull);
      expect(find.text('Zu „Einkauf“ hinzugefügt.'), findsOneWidget);
    });

    testWidgets('Aufgabe: Titel aus der ersten Zeile (änderbar), Rest als Notiz', (tester) async {
      final h = await startMit(tester);
      await teile(tester, 'Zahnarzt anrufen\nNummer steht im Heft');
      await tippe(tester, find.text('Als Aufgabe anlegen'));
      expect(find.text('Aufgabe anlegen'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Zahnarzt Termin machen');
      await tippe(tester, find.text('Anlegen'));
      expect(find.byType(TeilenSeite), findsNothing);
      final a = (await h.env.db.select(h.env.db.aufgaben).get()).single;
      expect(a.titel, 'Zahnarzt Termin machen');
      expect(a.beschreibung, 'Zahnarzt anrufen\nNummer steht im Heft');
      expect(h.container.read(teilenProvider), isNull);
    });

    testWidgets('Chat: Nachricht geht über den normalen Sendeweg (Klartext nur lokal im Ausgang, verschlüsselt beim Senden)', (tester) async {
      final h = await startMit(tester, chat: true);
      await teile(tester, 'Schau mal: https://example.org');
      await tippe(tester, find.text('Als Nachricht in einen Chat'));
      expect(find.text('In welchen Chat senden?'), findsOneWidget);
      await tippe(tester, find.text('Familie'));
      expect(find.byType(TeilenSeite), findsNothing);
      final n = (await h.env.db.select(h.env.db.nachrichten).get()).single;
      expect(n.konversationId, _famChat);
      expect(n.inhalt, 'l1:Schau mal: https://example.org'); // lokaler Klartext des Ausgangs, nie hinaus: beim Senden wird er verschlüsselt (ChatOpVorbereiter)
      final ops = await h.env.db.select(h.env.db.outbox).get();
      expect(ops.where((o) => o.entity == 'nachricht'), hasLength(1));
    });

    testWidgets('Chat ohne bereite Verschlüsselung ist nicht wählbar (Hinweis statt Senden)', (tester) async {
      await startMit(tester);
      await teile(tester, 'Hallo');
      expect(find.text('Dafür muss die Verschlüsselung auf diesem Gerät bereit sein.'), findsOneWidget);
      await tippe(tester, find.text('Als Nachricht in einen Chat'));
      expect(find.text('In welchen Chat senden?'), findsNothing);
    });

    testWidgets('Start per "Teilen" (App war zu): der Text wird beim Start abgeholt und angeboten', (tester) async {
      kanalTeilenStart = 'Kalter Start';
      await startMit(tester);
      expect(find.byType(TeilenSeite), findsOneWidget);
      expect(find.textContaining('Kalter Start'), findsWidgets);
      expect(kanalAufrufe.where((c) => c.method == 'initialShare'), hasLength(1));
    });

    testWidgets('Abbrechen verwirft den Text', (tester) async {
      final h = await startMit(tester);
      await teile(tester, 'Nur ansehen');
      await tippe(tester, find.text('Abbrechen'));
      expect(find.byType(TeilenSeite), findsNothing);
      expect(h.container.read(teilenProvider), isNull);
      expect(await h.env.db.select(h.env.db.listenEintraege).get(), isEmpty);
    });

    testWidgets('Nicht angemeldet: Text wartet, erscheint erst nach der Anmeldung', (tester) async {
      final h = await startMit(tester, angemeldet: false);
      await teile(tester, 'Wartet auf die Anmeldung');
      expect(find.byType(TeilenSeite), findsNothing);
      expect(h.container.read(teilenProvider), 'Wartet auf die Anmeldung');
      await h.container.read(apiClientProvider).sitzungUebernehmen(SessionDto.fromJson(appSession()));
      await h.container.read(authProvider.notifier).start();
      await warte(tester);
      expect(find.byType(TeilenSeite), findsOneWidget);
      expect(find.textContaining('Wartet auf die Anmeldung'), findsWidgets);
    });

    testWidgets('Abmelden verwirft einen wartenden Text', (tester) async {
      final h = await startMit(tester);
      await teile(tester, 'Geheimer Text');
      expect(find.byType(TeilenSeite), findsOneWidget);
      await h.container.read(authProvider.notifier).abmelden();
      await warte(tester);
      expect(h.container.read(teilenProvider), isNull);
      expect(find.byType(TeilenSeite), findsNothing);
    });

    testWidgets('Sehr langer Text wird auf $kMaxTeilenZeichen Zeichen gekürzt (mit Hinweis)', (tester) async {
      final h = await startMit(tester);
      await teile(tester, 'wort ' * 3000);
      expect(h.container.read(teilenProvider)!.runes.length, lessThanOrEqualTo(kMaxTeilenZeichen));
      expect(find.text('Der Text wurde auf $kMaxTeilenZeichen Zeichen gekürzt.'), findsOneWidget);
      pruefeLayout(tester, 'Teilen langer Text');
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Layout bei 360 px und Textskala $skala (Auswahl, Listen-Blatt)', (tester) async {
        await startMit(tester, skala: skala, chat: true);
        await teile(tester, 'Ein längerer geteilter Text mit einem Link https://example.org/ein/sehr/langer/pfad/der/umbrechen/muss und noch mehr Worten zum Prüfen des Layouts');
        pruefeLayout(tester, 'Teilen-Auswahl $skala');
        await tippe(tester, find.text('Zu einer Liste hinzufügen'));
        pruefeLayout(tester, 'Listen-Blatt $skala');
      });
    }
  });
}

/// Umgebung und Container zusammen (kleine Hilfe für die Tests).
class ProviderContainerHelfer {
  final TestUmgebung env;
  final ProviderContainer container;
  ProviderContainerHelfer(this.env, this.container);

  /// Nur ein Container ohne Umgebung (reine Zustandstests).
  static ProviderContainer neu() => ProviderContainer();
}
