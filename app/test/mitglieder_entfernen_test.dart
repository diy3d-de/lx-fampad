// P1 Soft-Delete beim Entfernen von Mitgliedern (Oberfläche): ehrlicher Text mit Aufbewahrungsfrist, Bereich "Kürzlich entfernt" mit "Zurückholen" (Step-up), ältere
// Server ohne Soft-Delete behalten den bisherigen Text, der Hinweis an die Familie steht im Dialog zum Komplett-Reset. 360 px, Textskala 1.0 und 1.5.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _idOma = '77777777-3333-4444-8555-666666666666';

Map<String, dynamic> _entfernt({String name = 'Opa', String id = _idOma, bool schluessel = true}) => {
  'id': id,
  'displayName': name,
  'colorIndex': 3,
  'role': 'parent',
  'removedAt': '2026-10-10T08:00:00.000Z',
  'purgeAt': '2026-11-09T08:00:00.000Z',
  'hasKeys': schluessel,
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modelle', () {
    test('entfernte Mitglieder: Felder, Frist, tolerant bei fehlenden Angaben', () {
      final e = EntfernteMitglieder.fromJson({'members': [_entfernt()], 'retentionDays': 30});
      expect(e.aufbewahrungTage, 30);
      expect(e.mitglieder.single.name, 'Opa');
      expect(e.mitglieder.single.rolle, Role.parent);
      expect(e.mitglieder.single.hatSchluessel, isTrue);
      expect(e.mitglieder.single.loeschtAm.isAfter(e.mitglieder.single.entferntAm), isTrue);
      final leer = EntfernteMitglieder.fromJson(<String, dynamic>{});
      expect(leer.mitglieder, isEmpty);
      expect(leer.aufbewahrungTage, 30);
      expect(() => EntferntesMitglied.fromJson({'id': 'x'}), throwsA(anything));
    });
  });

  group('Oberfläche', () {
    Future<(TestUmgebung, FakeServer)> zumAdmin(WidgetTester tester, double skala, {bool softDelete = true, List<Map<String, dynamic>>? entfernte}) async {
      final server = standardServer()
        ..json('DELETE /members/$fixIdKind', {'ok': true})
        ..json('POST /members/$_idOma/restore', {'ok': true})
        ..json('POST /members/$fixIdKind/reset', neueEinladungJson());
      if (softDelete) server.json('GET /members/removed', {'members': entfernte ?? [_entfernt()], 'retentionDays': 30});
      final env = await angemeldeteUmgebung(server: server);
      await starteApp(tester, env, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Mitglieder und Einladungen'));
      return (env, server);
    }

    for (final skala in [1.0, 1.5]) {
      testWidgets('Bereich "Kürzlich entfernt" mit Frist und Knopf "Zurückholen" (360 px, Textskala $skala)', (tester) async {
        await zumAdmin(tester, skala);
        await tester.dragUntilVisible(find.text('Opa'), find.byType(Scrollable).first, const Offset(0, -150));
        expect(labelFinder('Kürzlich entfernt (1)'), findsOneWidget);
        expect(find.text('Opa'), findsOneWidget);
        expect(find.textContaining('noch 30 Tage'), findsOneWidget);
        expect(find.textContaining('endgültig gelöscht am 09.11.2026'), findsOneWidget);
        expect(find.text('schlüssel gespeichert'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Zurückholen'), findsOneWidget);
        pruefeLayout(tester, 'Kürzlich entfernt');
      });
    }

    testWidgets('Zurückholen: Rückfrage, POST /restore, danach lädt die Liste neu', (tester) async {
      final (_, server) = await zumAdmin(tester, 1.0);
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Zurückholen'));
      expect(find.text('Opa zurückholen?'), findsOneWidget);
      expect(find.textContaining('Schlüssel und Sicherungen sind unverändert da'), findsOneWidget);
      expect(find.textContaining('Chat-Teilnahmen kommen nicht zurück'), findsOneWidget);
      expect(find.textContaining('Führe danach „Zugang zurücksetzen“ für Opa aus'), findsOneWidget);
      // abbrechen: nichts wird gesendet
      await tippeText(tester, 'Abbrechen');
      expect(server.anfragen('POST /members/$_idOma/restore'), isEmpty);
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Zurückholen'));
      final vorher = server.anfragen('GET /members/removed').length;
      server.json('GET /members/removed', {'members': <Object>[], 'retentionDays': 30});
      await tippe(tester, find.widgetWithText(TextButton, 'Zurückholen'));
      expect(server.anfragen('POST /members/$_idOma/restore'), hasLength(1));
      expect(server.anfragen('GET /members/removed').length, greaterThan(vorher));
      expect(find.text('Opa ist wieder in der Familie.'), findsOneWidget);
      expect(find.textContaining('Kürzlich entfernt'), findsNothing, reason: 'der Bereich verschwindet, wenn niemand mehr dort ist');
    });

    testWidgets('Zurückholen verlangt Step-up und wiederholt danach', (tester) async {
      var versuche = 0;
      final (_, server) = await zumAdmin(tester, 1.0);
      server
        ..on('POST /members/$_idOma/restore', (r) {
          versuche++;
          return versuche == 1 ? fehler(403, 'step_up_required') : jsonAntwort({'ok': true});
        })
        ..json('POST /auth/step-up/code', {'stepUpAt': DateTime.now().toUtc().toIso8601String()});
      await tippe(tester, find.widgetWithText(OutlinedButton, 'Zurückholen'));
      await tippe(tester, find.widgetWithText(TextButton, 'Zurückholen'));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await eingeben(tester, 'Code aus der Authenticator-App', '654321');
      await tippeText(tester, 'Mit Code bestätigen');
      expect(versuche, 2);
    });

    testWidgets('Entfernen: Dialog nennt Aufbewahrungsfrist, was bleibt und was nicht zurückkommt', (tester) async {
      final (_, server) = await zumAdmin(tester, 1.0);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Entfernen');
      expect(find.text('Mitglied entfernen?'), findsOneWidget);
      expect(find.textContaining('noch 30 Tage gespeichert'), findsOneWidget);
      expect(find.textContaining('„Kürzlich entfernt“ zurück'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('endgültig gelöscht')), findsOneWidget);
      expect(find.textContaining('Chat-Teilnahmen kommen auch bei einer Rückkehr nicht von selbst zurück'), findsOneWidget);
      expect(find.textContaining('Die E-Mail-Adresse bleibt in dieser Zeit belegt'), findsOneWidget);
      pruefeLayout(tester, 'Entfernen-Dialog');
      await tippe(tester, find.widgetWithText(TextButton, 'Entfernen'));
      expect(server.anfragen('DELETE /members/$fixIdKind'), hasLength(1));
      expect(find.textContaining('zurückholen'), findsWidgets);
    });

    testWidgets('älterer Server ohne Soft-Delete: kein Bereich, der bisherige Text (endgültig, ohne Versprechen)', (tester) async {
      await zumAdmin(tester, 1.0, softDelete: false);
      expect(find.textContaining('Kürzlich entfernt'), findsNothing);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Entfernen');
      expect(find.textContaining('wird entfernt und überall abgemeldet'), findsOneWidget);
      expect(find.textContaining('Tage'), findsNothing, reason: 'ohne Soft-Delete wird nichts aufbewahrt und nichts versprochen');
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Jetzt endgültig löschen": nur mit getipptem Wort, dann POST /purge (Step-up über den bekannten Dialog)', (tester) async {
      final (_, server) = await zumAdmin(tester, 1.0);
      server.json('POST /members/$_idOma/purge', {'ok': true});
      await tippe(tester, find.text('Jetzt endgültig löschen'));
      expect(find.text('Opa jetzt endgültig löschen?'), findsOneWidget);
      expect(find.textContaining('sofort und unwiderruflich gelöscht'), findsOneWidget);
      expect(find.textContaining('Datensicherungen'), findsOneWidget);
      // ohne das Wort ist der Knopf gesperrt
      final knopf = find.widgetWithText(TextButton, 'Endgültig löschen');
      expect(tester.widget<TextButton>(knopf).onPressed, isNull);
      expect(server.anfragen('POST /members/$_idOma/purge'), isEmpty);
      pruefeLayout(tester, 'Löschen-Dialog');
      await tester.enterText(find.byType(TextField).last, 'löschen');
      await tester.pump();
      server.json('GET /members/removed', {'members': <Object>[], 'retentionDays': 30});
      await tippe(tester, knopf);
      expect(server.anfragen('POST /members/$_idOma/purge'), hasLength(1));
      expect(find.text('Opa ist endgültig gelöscht.'), findsOneWidget);
    });

    testWidgets('Komplett-Reset: der Dialog sagt, dass die Familie einen Hinweis bekommt', (tester) async {
      await zumAdmin(tester, 1.0);
      await tippe(tester, find.byTooltip('Aktionen für Ben'));
      await tippeText(tester, 'Zugang zurücksetzen');
      expect(find.textContaining('Alle anderen in der Familie bekommen einen Hinweis darauf'), findsOneWidget);
      expect(find.textContaining('nur nach Rücksprache annehmen'), findsOneWidget);
      pruefeLayout(tester, 'Reset-Dialog');
    });
  });
}
