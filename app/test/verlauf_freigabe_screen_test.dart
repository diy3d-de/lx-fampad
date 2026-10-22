// Oberfläche zu "Verlauf freigeben" (PR 7): die Frage im Chat, der Dialog mit Sicherheitscode und Warnhinweis, Später, Abbrechen und die Freigabe; Layout bei 360 px und
// Textskala 1.5. Die Logik (Angebote, Wraps, Empfang) prüft chat_krypto_test.dart; hier gibt ein Testcontroller feste Angebote vor.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';
import 'package:lx_fampad/data/chat/chat_krypto.dart';
import 'package:lx_fampad/data/chat/chat_krypto_state.dart';
import 'package:lx_fampad/data/crypto/sicherheitscode.dart';

import 'support/chat_ui_aufbau.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';

String vor(int minuten) => DateTime.now().toUtc().subtract(Duration(minutes: minuten)).toIso8601String();

/// Gibt feste Angebote vor und merkt sich, wofür freigegeben wurde.
class _AngebotController extends TestKryptoController {
  final List<VerlaufAngebot> angebote;
  final List<String> freigegeben;
  final Set<String> verborgen = {};
  bool klappt = true;
  _AngebotController(super.fabrik, super.aktiv, this.angebote, this.freigegeben);

  @override
  List<VerlaufAngebot> get verlaufAngebote => [for (final a in angebote) if (!verborgen.contains(a.userId) && !freigegeben.contains(a.userId)) a];

  @override
  void verlaufSpaeter(String userId) {
    verborgen.add(userId);
    state = state + 1;
  }

  @override
  Future<bool> verlaufFreigeben(String userId) async {
    if (!klappt) return false;
    freigegeben.add(userId);
    state = state + 1;
    return true;
  }
}

/// Ein [ChatKrypto], das feste Angebote meldet (die Logik dahinter prüft chat_krypto_test.dart); der echte Controller entscheidet danach über den Server (Gate).
class _KryptoMitAngeboten extends ChatKrypto {
  final List<VerlaufAngebot> angebote;
  _KryptoMitAngeboten(ChatKrypto k, this.angebote)
    : super(
        crypto: k.crypto,
        db: k.db,
        store: k.store,
        ichId: k.ichId,
        meinSchluessel: k.meinSchluessel,
        meineKeyVersion: k.meineKeyVersion,
        gemerkt: k.gemerkt,
        serverSchluessel: k.serverSchluessel,
        absenderSchluessel: k.absenderSchluessel,
      );

  @override
  Future<List<VerlaufAngebot>> verlaufAngebote() async => angebote;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  /// Echter Controller (nur ohne Hintergrundlauf) mit einem Gate des Servers: die Frage erscheint nur, wenn der Server Wraps mit Schlüsselversion annimmt.
  Future<int> gateFall(WidgetTester tester, Future<bool> Function() gate) async {
    final env = await angemeldeteUmgebung();
    final a = ChatUiAufbau(env);
    final dm = direktChatId(fixIdAdmin, fixIdKind);
    final krypto = _KryptoMitAngeboten(a.annasKrypto, [
      VerlaufAngebot(userId: fixIdKind, keyVersion: 2, epochen: {dm: [1]}),
    ]);
    var fragen = 0;
    env.extraOverrides.addAll([
      chatKryptoProvider.overrideWith(() => TestKryptoController(() => krypto, () => true)),
      a.overrides[1],
      serverKannVerlaufFreigebenProvider.overrideWith((ref) {
        fragen++;
        return gate();
      }),
    ]);
    env.server.json('GET /members', {
      'members': [userJson(), userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de')],
    });
    env.sync.andereAendert('konversation', dm, {'art': 'direct', 'encVersion': 'e1', 'titel': '', 'teilnehmer': [fixIdAdmin, fixIdKind]..sort(), 'ownerId': fixIdKind, 'createdAt': vor(100)});
    await a.epoche(dm, [a.anna, a.ben]);
    await a.nachricht(dm, 'a0000000-0000-4000-8000-000000000002', a.ben, 'Hallo Anna', vor(10));
    await starteApp(tester, env, groesse: const Size(360, 800));
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
    await warte(tester, 12);
    await tippeText(tester, 'Hallo Anna');
    await warte(tester, 12);
    return fragen;
  }

  testWidgets('Gate: meldet der Server wrapKeyVersion, erscheint die Frage', (tester) async {
    await gateFall(tester, () async => true);
    expect(find.textContaining('Ben hat einen neuen Schlüssel'), findsOneWidget);
  });

  testWidgets('Gate: ein älterer Server (ohne wrapKeyVersion) bekommt keine Frage, nichts ändert sich', (tester) async {
    final fragen = await gateFall(tester, () async => false);
    expect(fragen, greaterThan(0));
    expect(find.textContaining('Ben hat einen neuen Schlüssel'), findsNothing);
  });

  testWidgets('Gate: ein Fehler (offline) zeigt nichts und fragt beim nächsten Mal erneut, nie ein Absturz', (tester) async {
    final fragen = await gateFall(tester, () async => throw StateError('offline'));
    expect(fragen, greaterThan(0));
    expect(find.textContaining('Ben hat einen neuen Schlüssel'), findsNothing);
  });

  late String dm;
  late String gruppe;
  final freigegeben = <String>[];
  late _AngebotController controller;

  Future<ChatUiAufbau> start(WidgetTester tester, {double skala = 1.0}) async {
    freigegeben.clear();
    final env = await angemeldeteUmgebung();
    final a = ChatUiAufbau(env);
    dm = direktChatId(fixIdAdmin, fixIdKind);
    gruppe = 'bbbbbbbb-0000-4000-8000-0000000000b1';
    controller = _AngebotController(
      () => a.annasKrypto,
      () => true,
      [
        VerlaufAngebot(userId: fixIdKind, keyVersion: 2, epochen: {dm: [1], gruppe: [1, 2]}),
      ],
      freigegeben,
    );
    env.extraOverrides.addAll([chatKryptoProvider.overrideWith(() => controller), a.overrides[1]]);
    env.server.json('GET /members', {
      'members': [
        userJson(),
        userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'),
        userJson(id: coraId, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de'),
      ],
    });
    env.sync.andereAendert('konversation', dm, {'art': 'direct', 'encVersion': 'e1', 'titel': '', 'teilnehmer': [fixIdAdmin, fixIdKind]..sort(), 'ownerId': fixIdKind, 'createdAt': vor(100)});
    await a.epoche(dm, [a.anna, a.ben]);
    await a.nachricht(dm, 'a0000000-0000-4000-8000-000000000002', a.ben, 'Hallo Anna', vor(10));
    env.sync.andereAendert('konversation', gruppe, {
      'art': 'group',
      'encVersion': 'e1',
      'titel': 'p1:Wochenendausflug',
      'teilnehmer': [fixIdAdmin, fixIdKind, coraId]..sort(),
      'ownerId': fixIdKind,
      'createdAt': vor(200),
    });
    await a.epoche(gruppe, [a.anna, a.ben, a.cora]);
    await starteApp(tester, env, skala: skala, groesse: const Size(360, 800));
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Chat')));
    await warte(tester);
    return a;
  }

  testWidgets('die Frage erscheint im Chat, in dem die Person Verlauf hat (Direktchat und Gruppe); Später blendet sie aus', (tester) async {
    await start(tester);
    await tippeText(tester, 'Hallo Anna');
    expect(find.textContaining('Ben hat einen neuen Schlüssel und kann ältere Nachrichten nicht lesen'), findsOneWidget);
    expect(find.text('Prüfen und freigeben'), findsOneWidget);
    expect(freigegeben, isEmpty, reason: 'nie von selbst');
    await tippeText(tester, 'Später');
    expect(find.textContaining('hat einen neuen Schlüssel'), findsNothing);
    expect(freigegeben, isEmpty);
  });

  testWidgets('Dialog: Sicherheitscode der Person, Warnhinweis, Zahl der Chats; Abbrechen gibt nichts frei, "Ja, das ist Ben" gibt frei', (tester) async {
    final a = await start(tester, skala: 1.5);
    await tippeText(tester, 'Hallo Anna');
    await tippeText(tester, 'Prüfen und freigeben');
    expect(find.text('Verlauf für Ben freigeben?'), findsOneWidget);
    final code = personenSicherheitscode(MitgliedSchluessel(a.ben.id, a.ben.oeffentlich));
    expect(find.text(code), findsOneWidget);
    expect(find.textContaining('3 Schlüssel aus 2 Chats'), findsOneWidget);
    expect(find.textContaining('nur frei, wenn du sicher bist, dass das wirklich Ben ist'), findsOneWidget);
    pruefeLayout(tester, 'Dialog Verlauf freigeben 1.5');
    await tippeText(tester, 'Abbrechen');
    expect(freigegeben, isEmpty);
    expect(find.textContaining('hat einen neuen Schlüssel'), findsOneWidget, reason: 'die Frage bleibt stehen');
    await tippeText(tester, 'Prüfen und freigeben');
    await tippeText(tester, 'Ja, das ist Ben – Verlauf freigeben');
    expect(freigegeben, [fixIdKind]);
    expect(find.text('Verlauf für Ben freigegeben.'), findsOneWidget);
    expect(find.textContaining('hat einen neuen Schlüssel'), findsNothing, reason: 'erledigt');
  });

  testWidgets('geht die Freigabe gerade nicht, steht eine ruhige Meldung da und die Frage bleibt', (tester) async {
    await start(tester);
    controller.klappt = false;
    await tippeText(tester, 'Hallo Anna');
    await tippeText(tester, 'Prüfen und freigeben');
    await tippeText(tester, 'Ja, das ist Ben – Verlauf freigeben');
    expect(find.text('Das geht gerade nicht. Versuche es gleich noch einmal.'), findsOneWidget);
    expect(freigegeben, isEmpty);
    expect(find.textContaining('hat einen neuen Schlüssel'), findsOneWidget);
  });

  testWidgets('Layout: Frage und Knöpfe bei 360 px und Textskala 1.5 ohne Überlauf, Touch-Ziele mindestens 44 px', (tester) async {
    await start(tester, skala: 1.5);
    await tippeText(tester, 'Hallo Anna');
    pruefeLayout(tester, 'Frage Verlauf freigeben 1.5');
    for (final t in ['Später', 'Prüfen und freigeben']) {
      final groesse = tester.getSize(find.ancestor(of: find.text(t), matching: find.bySubtype<ButtonStyleButton>()).first);
      expect(groesse.height, greaterThanOrEqualTo(44), reason: t);
    }
  });
}
