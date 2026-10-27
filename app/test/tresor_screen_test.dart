// Tresor (Teil 2): Oberfläche. Gesperrter Einstieg und Entsperren (erneute Bestätigung), Auto-Sperre nach 2 Minuten ohne Eingabe (Fake-Uhr der Testumgebung), Sperre beim Wechsel der App in den
// Hintergrund, Sperren leert den Zustand und schließt die Unterseiten, Übersicht (Kategorien mit Zähler), Suche (nie in geheimen Werten und Notizen), Eintrag ansehen (geheime Werte verdeckt,
// 15 Sekunden sichtbar, Kopieren und Leeren der Zwischenablage nach 30 Sekunden), Anlegen/Bearbeiten/Löschen, Vorlagen, Grenzen; bei 360 px und Textskala 1.0/1.5/2.0 mit Touch-Ziel-Prüfung.
// Rollen: Elternteil und Admin bedienen alles, ein Kind hat nichts davon (Menüpunkt, Seitenleiste, Deep-Link, auch bei Rollenwechsel zur Laufzeit). Daten kommen über überschriebene Provider
// (kein Schlüsselmaterial), die Schreibwege über ein aufzeichnendes Repository; die echten Wege prüft tresor_repository_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/tresor/tresor_daten.dart';
import 'package:lx_fampad/data/tresor/tresor_modelle.dart';
import 'package:lx_fampad/data/tresor/tresor_repository.dart';
import 'package:lx_fampad/data/tresor/tresor_sperre.dart';
import 'package:lx_fampad/data/tresor/tresor_state.dart';
import 'package:lx_fampad/features/shell/shell_tab.dart';

import 'support/fake_server.dart' show fehler, jsonAntwort;
import 'support/harness.dart';
import 'support/test_app.dart';
import 'support/tresor_welt.dart';

/// Alles, was die Bedienhilfe zu sehen bekommt (Beschriftung, Wert, Hinweis, Tooltip) als ein Text.
String alleSemantik(WidgetTester tester) {
  final b = StringBuffer();
  void gehe(SemanticsNode n) {
    final d = n.getSemanticsData();
    b..writeln(d.label)..writeln(d.value)..writeln(d.hint)..writeln(d.tooltip);
    n.visitChildren((c) {
      gehe(c);
      return true;
    });
  }

  gehe(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return b.toString();
}

class _Schalter extends Notifier<bool> {
  @override
  bool build() => true;
  void setzen(bool v) => state = v;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  /// Startet die App, geht in den Tresor (mobil über "Mehr", Desktop über die Seitenleiste) und entsperrt auf Wunsch.
  Future<(TresorTestAufbau, ProviderContainer)> start(
    WidgetTester tester, {
    String role = 'admin',
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    TresorTestAufbau? aufbau,
    bool oeffnen = true,
    bool entsperren = false,
    void Function(TestUmgebung env)? vorStart,
  }) async {
    final a = aufbau ?? TresorTestAufbau();
    final env = await angemeldeteUmgebung(role: role);
    vorStart?.call(env);
    env.extraOverrides.addAll(a.overrides);
    final c = await starteApp(tester, env, skala: skala, groesse: groesse);
    if (oeffnen) {
      if (groesse.width >= kDesktopBreakpoint) {
        c.read(shellTabProvider.notifier).waehlen(kTresorTab);
        await warte(tester);
      } else {
        await zumBereich(tester, 'Tresor');
      }
    }
    if (entsperren) await tippe(tester, find.text('Tresor entsperren'));
    return (a, c);
  }

  /// Sperrt und räumt Zeitgeber ab (ein offener Timer ließe den Test scheitern).
  Future<void> ende(WidgetTester tester, ProviderContainer c, TresorTestAufbau a) async {
    c.read(tresorSperreProvider.notifier).sperren();
    a.ablage.dienst.verwerfen();
    await warte(tester);
  }

  Future<void> eingabe(WidgetTester tester, Finder f, String text) async {
    await tester.ensureVisible(f.first);
    await tester.pump();
    await tester.enterText(f.first, text);
    await tester.pump();
  }

  Future<void> oeffneEintrag(WidgetTester tester, String kategorie, String titel) async {
    await tippe(tester, find.text(kategorie));
    await tippe(tester, find.text(titel));
  }

  void fuerSkalen(String name, Future<void> Function(WidgetTester tester, double skala) body) {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('$name (Textskala $skala)', (tester) => body(tester, skala));
    }
  }

  group('Sperre und Entsperren', () {
    fuerSkalen('Beim Öffnen ist der Tresor gesperrt: nur der Entsperr-Bildschirm, kein Eintrag', (tester, skala) async {
      final (a, _) = await start(tester, skala: skala);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      expect(find.text('Tresor entsperren'), findsOneWidget);
      expect(find.text('WLAN Zuhause'), findsNothing);
      expect(find.text('Entsperrt'), findsNothing);
      expect(a.bestaetigungen, 0);
      pruefeLayout(tester, 'gesperrt');
    });

    testWidgets('Abbrechen der Bestätigung lässt ihn gesperrt, bestandene Bestätigung entsperrt (mit "bis" und Sperren-Knopf)', (tester) async {
      final a = TresorTestAufbau()..bestaetigungOk = false;
      final (_, c) = await start(tester, aufbau: a);
      await tippe(tester, find.text('Tresor entsperren'));
      expect(a.bestaetigungen, 1);
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      a.bestaetigungOk = true;
      await tippe(tester, find.text('Tresor entsperren'));
      expect(a.bestaetigungen, 2);
      expect(c.read(tresorSperreProvider).entsperrt, isTrue);
      expect(find.text('Entsperrt'), findsOneWidget);
      expect(find.text('bis 14:02'), findsOneWidget); // Fake-Uhr 14:00 + 2 Minuten
      expect(find.text('Sperren'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Echter Weg: Step-up-Dialog mit Code; richtiger Code entsperrt, falscher lässt gesperrt (immer eine Rückfrage beim Server)', (tester) async {
      var versuche = 0;
      final a = TresorTestAufbau(echteBestaetigung: true);
      final (_, c) = await start(tester, aufbau: a, vorStart: (env) => env.server.on('POST /auth/step-up/code', (_) {
        versuche++;
        return versuche == 1 ? fehler(401, 'step_up_failed') : jsonAntwort({});
      }));
      await tippe(tester, find.text('Tresor entsperren'));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '111111');
      await tippe(tester, find.text('Mit Code bestätigen'));
      expect(c.read(tresorSperreProvider).entsperrt, isFalse, reason: 'falscher Code');
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '123456');
      await tippe(tester, find.text('Mit Code bestätigen'));
      expect(versuche, 2);
      expect(c.read(tresorSperreProvider).entsperrt, isTrue);
      expect(find.text('Haushalt'), findsOneWidget);
      // nach dem Sperren fragt der nächste Versuch wieder (keine Wiederverwendung der alten Bestätigung)
      await tippe(tester, find.text('Sperren'));
      await tippe(tester, find.text('Tresor entsperren'));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      await ende(tester, c, a);
    });

    testWidgets('Manuelles Sperren: zurück zum Entsperr-Bildschirm, nichts mehr sichtbar', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      expect(find.text('Haushalt'), findsOneWidget);
      await tippe(tester, find.text('Sperren'));
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      expect(find.text('Haushalt'), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Auto-Sperre: nach 2 Minuten ohne Eingabe; eine Eingabe im Tresor setzt die Frist zurück', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await tester.pump(const Duration(seconds: 90));
      expect(c.read(tresorSperreProvider).entsperrt, isTrue);
      // Eingabe (Tippen ins Suchfeld): die Frist beginnt von vorn
      await tester.tap(find.byType(TextField).first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 90));
      expect(c.read(tresorSperreProvider).entsperrt, isTrue, reason: '90 s nach der Eingabe');
      await tester.pump(const Duration(seconds: 40));
      expect(c.read(tresorSperreProvider).entsperrt, isFalse, reason: '130 s ohne Eingabe');
      await warte(tester);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Der Wechsel der App in den Hintergrund sperrt sofort, auch wenn der Tresor gerade nicht zu sehen ist', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      expect(c.read(tresorSperreProvider).entsperrt, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(c.read(tresorSperreProvider).entsperrt, isTrue, reason: 'inactive (z. B. ein Systemdialog) sperrt nicht');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await warte(tester);
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await warte(tester);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget, reason: 'nach der Rückkehr: gesperrt, nichts offen');
      expect(find.text('Haushalt'), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Sperren leert Suchtext, schließt Eintrag, Editor und Rückfrage und leert die Zwischenablage', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await eingabe(tester, find.byType(TextField).first, 'wlan');
      await tester.pump();
      expect(c.read(tresorSucheProvider), 'wlan');
      await tippe(tester, find.text('WLAN Zuhause'));
      expect(find.text('Zuletzt geändert'), findsOneWidget);
      await tippe(tester, find.byTooltip('Passwort kopieren'));
      expect(a.ablage.inhalt, geheimWlan);
      await tester.pump(const Duration(seconds: 5)); // die Rückmeldung verschwindet
      await warte(tester);
      await tippe(tester, find.text('Bearbeiten'));
      expect(find.text('Eintrag bearbeiten'), findsOneWidget);
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
      await tippe(tester, find.text('Löschen'));
      expect(find.text('Eintrag löschen?'), findsOneWidget);
      // gesperrt, während die Rückfrage offen ist
      c.read(tresorSperreProvider.notifier).sperren();
      await warte(tester);
      expect(find.text('Eintrag löschen?'), findsNothing);
      expect(find.text('Zuletzt geändert'), findsNothing);
      expect(find.text('WLAN Zuhause'), findsNothing);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      expect(a.ablage.inhalt, '', reason: 'Zwischenablage geleert');
      expect(c.read(tresorSucheProvider), '');
      expect(c.read(tresorDatenProvider).eintraege, isEmpty);
      await ende(tester, c, a);
    });

    testWidgets('Der Editor schließt sich mit der Sperre auch mit ungespeicherter Eingabe (Desktop-Layout, wo sonst gefragt würde)', (tester) async {
      final (a, c) = await start(tester, groesse: const Size(1200, 1100), entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Halb fertig');
      expect(find.text('Halb fertig'), findsOneWidget);
      c.read(tresorSperreProvider.notifier).sperren();
      await warte(tester);
      expect(find.text('Halb fertig'), findsNothing);
      expect(find.text('Änderungen verwerfen?'), findsNothing);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      await ende(tester, c, a);
    });
  });

  group('Übersicht und Suche', () {
    fuerSkalen('Kategorien mit Zähler, Einträge je Kategorie, eigene Kategorie, Layout', (tester, skala) async {
      final (a, c) = await start(tester, skala: skala, entsperren: true);
      expect(find.text('Notfall-Infos'), findsOneWidget);
      expect(find.text('Dokumente'), findsOneWidget);
      expect(find.text('Zugangsdaten'), findsOneWidget);
      expect(find.text('Haushalt'), findsOneWidget);
      expect(find.text('Hobby'), findsOneWidget); // eigene Kategorie als eigene Zeile
      expect(find.text('WLAN Zuhause'), findsNothing); // zugeklappt
      await tippe(tester, find.text('Haushalt'));
      expect(find.text('WLAN Zuhause'), findsOneWidget);
      expect(find.textContaining(geheimWlan), findsNothing, reason: 'in der Liste nie ein Wert');
      await tippe(tester, find.text('Hobby'));
      expect(find.text('Vereinskonto'), findsOneWidget);
      expect(find.text('Für alle Eltern sichtbar'), findsOneWidget);
      expect(find.text('Eintrag hinzufügen'), findsOneWidget);
      pruefeLayout(tester, 'Übersicht');
      await ende(tester, c, a);
    });

    testWidgets('Leerer Tresor: ruhiger Hinweis', (tester) async {
      final (a, c) = await start(tester, aufbau: TresorTestAufbau(daten: []), entsperren: true);
      expect(find.text('Noch nichts im Tresor'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Suche: findet Titel, Bezeichnungen und offene Werte, nie geheime Werte und Notizen', (tester, ) async {
      final (a, c) = await start(tester, entsperren: true);
      final feld = find.byType(TextField).first;
      await eingabe(tester, feld, 'wlan');
      expect(find.text('WLAN Zuhause'), findsOneWidget);
      expect(find.text('Haushalt'), findsNothing, reason: 'bei der Suche eine flache Trefferliste');
      await eingabe(tester, feld, offenNetz.toLowerCase()); // offener Wert
      expect(find.text('WLAN Zuhause'), findsOneWidget);
      await eingabe(tester, feld, 'router-adresse'); // Bezeichnung
      expect(find.text('WLAN Zuhause'), findsOneWidget);
      await eingabe(tester, feld, 'sonne-mond'); // geheimer Wert
      expect(find.text('Keine Treffer'), findsOneWidget);
      expect(find.text('WLAN Zuhause'), findsNothing);
      await eingabe(tester, feld, 'notiz-geheim'); // Notiz
      expect(find.text('Keine Treffer'), findsOneWidget);
      await eingabe(tester, feld, 'hv-0048213'); // geheimer Wert eines anderen Eintrags
      expect(find.text('Keine Treffer'), findsOneWidget);
      await tippe(tester, find.byTooltip('Suche leeren'));
      expect(find.text('Haushalt'), findsOneWidget);
      await ende(tester, c, a);
    });
  });

  group('Eintrag ansehen', () {
    fuerSkalen('Felder mit Bezeichnung und Wert, geheime Werte verdeckt, Hinweiskarten, Layout', (tester, skala) async {
      final (a, c) = await start(tester, skala: skala, entsperren: true);
      await oeffneEintrag(tester, 'Haushalt', 'WLAN Zuhause');
      expect(find.text('Netzname'), findsOneWidget);
      expect(find.text(offenNetz), findsOneWidget);
      expect(find.text('Passwort'), findsOneWidget);
      expect(find.text(geheimWlan), findsNothing, reason: 'geheimer Wert nie als Text im Widgetbaum');
      expect(find.textContaining('Sonne-Mond'), findsNothing);
      expect(find.text('••••••••'), findsOneWidget);
      expect(find.text('Für alle Eltern sichtbar'), findsOneWidget);
      expect(find.text('Zuletzt geändert'), findsOneWidget);
      expect(find.text('10.09.2026, 02:40'), findsNothing); // Zeitzone des Rechners: nur das Datum zählt
      expect(find.textContaining('.09.2026'), findsOneWidget);
      expect(find.text(geheimNotiz), findsOneWidget);
      expect(find.text('Bearbeiten'), findsOneWidget);
      expect(find.text('Löschen'), findsOneWidget);
      pruefeLayout(tester, 'Eintrag ansehen');
      await ende(tester, c, a);
    });

    testWidgets('Anzeigen auf Tipp, nach 15 Sekunden wieder verdeckt', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await oeffneEintrag(tester, 'Haushalt', 'WLAN Zuhause');
      await tippe(tester, find.byTooltip('Passwort anzeigen'));
      expect(find.text(geheimWlan), findsOneWidget);
      expect(find.byTooltip('Passwort verbergen'), findsOneWidget);
      await tester.pump(const Duration(seconds: 14));
      expect(find.text(geheimWlan), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(geheimWlan), findsNothing);
      expect(find.text('••••••••'), findsOneWidget);
      // von Hand wieder verbergen
      await tippe(tester, find.byTooltip('Passwort anzeigen'));
      expect(find.text(geheimWlan), findsOneWidget);
      await tippe(tester, find.byTooltip('Passwort verbergen'));
      expect(find.text(geheimWlan), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Kopieren nur auf Klick (auch verdeckt), Zwischenablage nach 30 Sekunden geleert, aber nur wenn noch derselbe Inhalt darin steht', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await oeffneEintrag(tester, 'Haushalt', 'WLAN Zuhause');
      expect(a.ablage.kopiert, isEmpty, reason: 'nie automatisch');
      await tippe(tester, find.byTooltip('Passwort kopieren'));
      expect(a.ablage.inhalt, geheimWlan);
      expect(find.text(geheimWlan), findsNothing, reason: 'Kopieren zeigt den Wert nicht an');
      await tester.pump(const Duration(seconds: 29));
      expect(a.ablage.inhalt, geheimWlan);
      await tester.pump(const Duration(seconds: 2));
      expect(a.ablage.inhalt, '');
      // jemand kopiert inzwischen etwas anderes: das bleibt unberührt
      await tippe(tester, find.byTooltip('Netzname kopieren'));
      expect(a.ablage.inhalt, offenNetz);
      a.ablage.inhalt = 'etwas anderes';
      await tester.pump(const Duration(seconds: 31));
      expect(a.ablage.inhalt, 'etwas anderes');
      // nicht lesbar (Browser): bleibt unberührt, kein Fehler
      await tippe(tester, find.byTooltip('Passwort kopieren'));
      a.ablage.lesbar = false;
      await tester.pump(const Duration(seconds: 31));
      expect(tester.takeException(), isNull);
      expect(a.ablage.inhalt, geheimWlan);
      await ende(tester, c, a);
    });

    testWidgets('Bearbeiten öffnet den Editor mit den Werten, Löschen fragt nach und löscht erst nach Bestätigung', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await oeffneEintrag(tester, 'Haushalt', 'WLAN Zuhause');
      await tippe(tester, find.text('Löschen'));
      expect(find.text('Eintrag löschen?'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(a.repo.geloescht, isEmpty);
      await tippe(tester, find.text('Löschen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Löschen'));
      expect(a.repo.geloescht, ['e-wlan']);
      expect(find.text('Eintrag bearbeiten'), findsNothing);
      await ende(tester, c, a);
    });
  });

  group('Eintrag anlegen und bearbeiten', () {
    fuerSkalen('Vorlage WLAN füllt die Felder vor, Speichern legt den Eintrag an (geheim-Marken bleiben), Layout', (tester, skala) async {
      final (a, c) = await start(tester, skala: skala, entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      expect(find.text('Eintrag'), findsWidgets);
      for (final v in ['WLAN', 'Versicherung', 'Ausweis', 'Arzt', 'Eigener Eintrag']) {
        expect(find.text(v), findsOneWidget, reason: v);
      }
      expect(find.text('Alle Eltern sehen diesen Eintrag'), findsOneWidget);
      expect(find.text('Wer sieht das?'), findsNothing);
      expect(find.textContaining('anhängen'), findsNothing);
      await tippe(tester, find.text('WLAN'));
      expect(find.text('4 von 20 Feldern'), findsOneWidget);
      pruefeLayout(tester, 'Editor');
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'WLAN Keller');
      await eingabe(tester, find.widgetWithText(TextField, 'Wert').at(0), 'KellerNetz');
      await eingabe(tester, find.widgetWithText(TextField, 'Wert').at(1), 'geheimes-pw');
      await tippe(tester, find.text('Speichern'));
      expect(a.repo.angelegt, hasLength(1));
      final i = a.repo.angelegt.single;
      expect(i.titel, 'WLAN Keller');
      expect(i.kategorie, TresorKategorie.haushalt);
      expect(i.vorlage, TresorVorlage.wlan);
      expect(i.felder.map((f) => f.bezeichnung), ['Netzname', 'Passwort', 'Router-Adresse', 'Router-Passwort']);
      expect(i.felder[1].geheim, isTrue);
      expect(i.felder[1].wert, 'geheimes-pw');
      expect(i.felder[0].geheim, isFalse);
      expect(find.text('Eintrag bearbeiten'), findsNothing); // zurück in der Übersicht
      await ende(tester, c, a);
    });

    testWidgets('Geheime Werte: keine Tastaturvorschläge, keine Autokorrektur, verdeckt mit Umschalter; der Geheim-Schalter wirkt sofort', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await tippe(tester, find.text('WLAN'));
      TextField wert(int n) => tester.widget<TextField>(find.widgetWithText(TextField, 'Wert').at(n));
      expect(wert(1).obscureText, isTrue);
      expect(wert(1).enableSuggestions, isFalse);
      expect(wert(1).autocorrect, isFalse);
      expect(wert(0).obscureText, isFalse);
      expect(wert(0).enableSuggestions, isFalse);
      expect(wert(0).autocorrect, isFalse);
      await tippe(tester, find.byTooltip('Wert anzeigen'));
      expect(wert(1).obscureText, isFalse);
      await tippe(tester, find.byType(Switch).first); // Netzname wird geheim
      expect(wert(0).obscureText, isTrue);
      await ende(tester, c, a);
    });

    testWidgets('Felder hinzufügen, umsortieren (Pfeile) und entfernen; leere Felder werden nicht gespeichert', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await tippe(tester, find.text('Arzt')); // Vorlage: Person, Praxis, Telefon, Adresse, Versichertennummer
      expect(find.text('5 von 20 Feldern'), findsOneWidget);
      await tippe(tester, find.byTooltip('Feld 1 nach unten'));
      await tippe(tester, find.byTooltip('Feld 5 entfernen'));
      await tippe(tester, find.text('Feld hinzufügen'));
      expect(find.text('5 von 20 Feldern'), findsOneWidget);
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Kinderärztin');
      await eingabe(tester, find.widgetWithText(TextField, 'Bezeichnung (Feld 5)'), 'Notiz zur Praxis');
      await eingabe(tester, find.widgetWithText(TextField, 'Wert').at(4), 'montags zu');
      await tippe(tester, find.text('Speichern'));
      final i = a.repo.angelegt.single;
      expect(i.kategorie, TresorKategorie.notfall);
      expect(i.felder.map((f) => f.bezeichnung), ['Praxis', 'Person', 'Telefon', 'Adresse', 'Notiz zur Praxis']);
      await ende(tester, c, a);
    });

    testWidgets('Eigene Kategorie braucht einen Namen; Pflichtangaben melden sich verständlich und nichts wird geschrieben', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await tippe(tester, find.text('Speichern'));
      expect(find.text('Gib dem Eintrag einen Titel.'), findsOneWidget);
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Schließfach');
      await tippe(tester, find.text('Eigene'));
      await tippe(tester, find.text('Speichern'));
      expect(find.text('Gib deiner eigenen Kategorie einen Namen.'), findsOneWidget);
      await eingabe(tester, find.widgetWithText(TextField, 'Name der Kategorie'), 'Bank');
      await eingabe(tester, find.widgetWithText(TextField, 'Bezeichnung (Feld 1)'), '');
      await eingabe(tester, find.widgetWithText(TextField, 'Wert').at(0), 'ohne Bezeichnung');
      await tippe(tester, find.text('Speichern'));
      expect(find.text('Jedes Feld braucht eine Bezeichnung.'), findsOneWidget);
      expect(a.repo.angelegt, isEmpty);
      await eingabe(tester, find.widgetWithText(TextField, 'Bezeichnung (Feld 1)'), 'Fachnummer');
      await tippe(tester, find.text('Speichern'));
      expect(a.repo.angelegt.single.kategorie, TresorKategorie.eigene);
      expect(a.repo.angelegt.single.kategorieName, 'Bank');
      await ende(tester, c, a);
    });

    testWidgets('Grenzen: höchstens 20 Felder, 16 KB je Eintrag, 500 Einträge (verständliche Meldungen)', (tester) async {
      // 20 Felder
      var (a, c) = await start(tester, entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      for (var n = 1; n < kMaxTresorFelder; n++) {
        await tippe(tester, find.text('Feld hinzufügen'));
      }
      expect(find.text('Mehr als $kMaxTresorFelder Felder passen nicht in einen Eintrag.'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Feld hinzufügen')).onPressed, isNull);
      // 16 KB: 20 Felder mit je 900 Zeichen
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Zu groß');
      for (var n = 0; n < kMaxTresorFelder; n++) {
        await eingabe(tester, find.widgetWithText(TextField, 'Bezeichnung (Feld ${n + 1})'), 'F$n');
        await eingabe(tester, find.widgetWithText(TextField, 'Wert').at(n), 'x' * 900);
      }
      await tippe(tester, find.text('Speichern'));
      expect(find.text('Der Eintrag ist zu groß. Kürze Werte oder Notiz.'), findsOneWidget);
      expect(a.repo.angelegt, isEmpty);
      await ende(tester, c, a);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      // 500 Einträge
      final voll = [for (var n = 0; n < kMaxTresorEintraege; n++) ansicht('e$n', TresorInhalt(kategorie: TresorKategorie.zugang, titel: 'Eintrag $n'))];
      (a, c) = await start(tester, aufbau: TresorTestAufbau(daten: voll), entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Nummer 501');
      await tippe(tester, find.text('Speichern'));
      expect(find.textContaining('Der Tresor ist voll: höchstens $kMaxTresorEintraege Einträge'), findsOneWidget);
      expect(a.repo.angelegt, isEmpty);
      await ende(tester, c, a);
    });

    testWidgets('Speicherfehler des Repositorys (z. B. Nachrichten-Schutz nicht bereit) erscheinen als ruhige Meldung', (tester) async {
      final a = TresorTestAufbau();
      a.repo.fehler = const TresorFehler('Den Eintrag gibt es nicht mehr.');
      final (_, c) = await start(tester, aufbau: a, entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Test');
      await tippe(tester, find.text('Speichern'));
      expect(find.text('Den Eintrag gibt es nicht mehr.'), findsOneWidget);
      a.repo.fehler = Exception('intern mit Geheimnis');
      await tippe(tester, find.text('Speichern'));
      expect(find.textContaining('Geheimnis'), findsNothing);
      expect(find.text('Das Speichern hat nicht geklappt. Versuche es noch einmal.'), findsOneWidget);
      await ende(tester, c, a);
    });

    testWidgets('Bearbeiten: die Felder sind vorbelegt, Speichern ruft aendern mit der ID auf', (tester) async {
      final (a, c) = await start(tester, entsperren: true);
      await oeffneEintrag(tester, 'Haushalt', 'WLAN Zuhause');
      await tippe(tester, find.text('Bearbeiten'));
      expect(find.text('Eintrag bearbeiten'), findsOneWidget);
      expect(find.text('Vorlage'), findsNothing, reason: 'Vorlagen nur beim Anlegen');
      expect(find.text('WLAN Zuhause'), findsOneWidget);
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'WLAN Haus');
      await tippe(tester, find.text('Änderungen speichern'));
      expect(a.repo.geaendert.single.id, 'e-wlan');
      expect(a.repo.geaendert.single.inhalt.titel, 'WLAN Haus');
      expect(a.repo.geaendert.single.inhalt.felder[1].wert, geheimWlan);
      expect(a.repo.geaendert.single.inhalt.vorlage, TresorVorlage.wlan);
      await ende(tester, c, a);
    });

    testWidgets('Desktop: ungespeicherte Eingaben fragen "Änderungen verwerfen?"', (tester) async {
      final (a, c) = await start(tester, groesse: const Size(1200, 1100), entsperren: true);
      await tippe(tester, find.text('Eintrag hinzufügen'));
      await eingabe(tester, find.widgetWithText(TextField, 'Titel (zum Beispiel WLAN Zuhause)'), 'Entwurf');
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
      expect(find.text('Änderungen verwerfen?'), findsOneWidget);
      await tippe(tester, find.text('Weiter bearbeiten'));
      expect(find.text('Entwurf'), findsOneWidget);
      await ende(tester, c, a);
    });
  });

  group('Bildschirmschutz', () {
    testWidgets('Alle Tresor-Seiten schalten FLAG_SECURE ein und beim Verlassen wieder aus', (tester) async {
      final (a, c) = await start(tester);
      bool gesichert() {
        final letzte = kanalAufrufe.where((m) => m.method == 'setSecure').toList();
        return letzte.isNotEmpty && (letzte.last.arguments as Map)['secure'] == true;
      }

      expect(gesichert(), isTrue, reason: 'schon der gesperrte Einstieg');
      await tippe(tester, find.text('Tresor entsperren'));
      await oeffneEintrag(tester, 'Haushalt', 'WLAN Zuhause');
      expect(gesichert(), isTrue);
      await ende(tester, c, a); // Sperre schließt die Eintragsseite, der Einstieg bleibt geschützt
      expect(gesichert(), isTrue);
      await tippe(tester, find.byTooltip('Zurück'));
      await warte(tester);
      expect(gesichert(), isFalse, reason: 'Tresor verlassen: Schutz aus');
    });
  });

  group('Rollen', () {
    testWidgets('Elternteil und Admin: Eintrag im Mehr-Blatt (nach Zähler, ohne Zahl) und bedienen den Tresor', (tester) async {
      for (final rolle in ['parent', 'admin']) {
        final (a, c) = await start(tester, role: rolle, oeffnen: false);
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
        await warte(tester);
        expect(find.byKey(const ValueKey('mehr:tresor')), findsOneWidget, reason: rolle);
        expect(find.bySemanticsLabel(RegExp(r'^Tresor$')), findsOneWidget, reason: '$rolle: keine Zahl, kein Hinweis');
        final zaehler = tester.getTopLeft(find.byKey(const ValueKey('mehr:zaehler'))).dy;
        final tresor = tester.getTopLeft(find.byKey(const ValueKey('mehr:tresor'))).dy;
        expect(tresor, greaterThan(zaehler), reason: rolle);
        await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Tresor')));
        await warte(tester);
        await tippe(tester, find.text('Tresor entsperren'));
        expect(find.text('Haushalt'), findsOneWidget, reason: rolle);
        await ende(tester, c, a);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    });

    testWidgets('Kind: kein Menüpunkt im Mehr-Blatt, nichts am Feld Mehr, keine Kachel', (tester) async {
      final (a, c) = await start(tester, role: 'child', oeffnen: false);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Mehr')));
      await warte(tester);
      expect(find.byKey(const ValueKey('mehr:tresor')), findsNothing);
      expect(find.text('Tresor'), findsNothing);
      expect(find.byKey(const ValueKey('mehr:medikamente')), findsOneWidget); // das Blatt selbst ist da
      await ende(tester, c, a);
    });

    testWidgets('Kind: Bereichswahl, Entsperren und Öffnen führen nirgends hinein', (tester) async {
      final (a, c) = await start(tester, role: 'child', oeffnen: false);
      c.read(shellTabProvider.notifier).waehlen(kTresorTab);
      await warte(tester);
      expect(c.read(shellTabProvider), 0);
      expect(c.read(tresorDarfProvider), isFalse);
      c.read(tresorSperreProvider.notifier).entsperren();
      expect(c.read(tresorSperreProvider).entsperrt, isFalse, reason: 'ohne Rolle nie entsperrt');
      expect(c.read(tresorDatenProvider).eintraege, isEmpty);
      expect(find.text('Tresor'), findsNothing);
      expect(a.bestaetigungen, 0);
    });

    testWidgets('Desktop: Seitenleiste mit Eintrag Tresor (Admin, ohne Zahl) und ohne (Kind)', (tester) async {
      final (a, c) = await start(tester, groesse: const Size(1200, 1100), oeffnen: false);
      expect(find.text('Tresor'), findsOneWidget); // der Eintrag der Seitenleiste
      await ende(tester, c, a);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await start(tester, role: 'child', groesse: const Size(1200, 1100), oeffnen: false);
      expect(find.text('Tresor'), findsNothing);
      expect(find.text('Zähler'), findsNothing);
      expect(find.text('Medikamente'), findsWidgets);
    });

    testWidgets('Desktop: der Bereich ist gesperrt und entsperrt wie mobil; Wechsel in einen anderen Bereich lässt ihn entsperrt bis zur Frist', (tester) async {
      final (a, c) = await start(tester, groesse: const Size(1200, 1100));
      expect(c.read(shellTabProvider), kTresorTab);
      expect(find.text('Der Tresor ist gesperrt'), findsOneWidget);
      await tippe(tester, find.text('Tresor entsperren'));
      expect(find.text('Haushalt'), findsOneWidget);
      pruefeLayout(tester, 'Desktop Tresor');
      await ende(tester, c, a);
    });

    testWidgets('Rollenwechsel zum Kind zur Laufzeit: Seitenleiste, Bereich und Mehr-Eintrag verschwinden, der Tresor sperrt, die Shell fällt auf die Startseite zurück', (tester) async {
      final darf = NotifierProvider<_Schalter, bool>(_Schalter.new);
      final a = TresorTestAufbau();
      final env = await angemeldeteUmgebung();
      env.extraOverrides.addAll([
        ...a.overrides,
        tresorDarfProvider.overrideWith((ref) => ref.watch(darf)),
      ]);
      final c = await starteApp(tester, env, groesse: const Size(1200, 1100));
      c.read(shellTabProvider.notifier).waehlen(kTresorTab);
      await warte(tester);
      await tippe(tester, find.text('Tresor entsperren'));
      expect(find.text('Haushalt'), findsOneWidget);
      expect(c.read(tresorSperreProvider).entsperrt, isTrue);
      await tippe(tester, find.text('Haushalt'));
      await tippe(tester, find.text('WLAN Zuhause'));
      expect(find.text('Zuletzt geändert'), findsOneWidget);
      // die Person wird zum Kind
      c.read(darf.notifier).setzen(false);
      await warte(tester);
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      expect(c.read(shellTabProvider), 0);
      expect(find.text('Tresor'), findsNothing);
      expect(find.text('Zuletzt geändert'), findsNothing);
      expect(find.text('WLAN Zuhause'), findsNothing);
      expect(find.text('Haushalt'), findsNothing);
      await ende(tester, c, a);
    });

    testWidgets('Rollenwechsel zum Kind bei geöffnetem Tresor (mobil): die Seite zeigt nur noch "Nicht verfügbar", der Tresor ist gesperrt', (tester) async {
      final darf = NotifierProvider<_Schalter, bool>(_Schalter.new);
      final a = TresorTestAufbau();
      final env = await angemeldeteUmgebung();
      env.extraOverrides.addAll([...a.overrides, tresorDarfProvider.overrideWith((ref) => ref.watch(darf))]);
      final c = await starteApp(tester, env);
      await zumBereich(tester, 'Tresor');
      await tippe(tester, find.text('Tresor entsperren'));
      expect(find.text('Haushalt'), findsOneWidget);
      c.read(darf.notifier).setzen(false);
      await warte(tester);
      expect(find.text('Nicht verfügbar'), findsWidgets);
      expect(find.text('Haushalt'), findsNothing);
      expect(c.read(tresorSperreProvider).entsperrt, isFalse);
      await ende(tester, c, a);
    });
  });

  group('Bedienhilfe', () {
    for (final skala in [1.0, 2.0]) {
      testWidgets('Geheime Werte stehen nie in der Bedienhilfe, verdeckte Felder heißen "verdeckt", Knöpfe haben Beschriftungen (Textskala $skala)', (tester) async {
        final handle = tester.ensureSemantics();
        final (a, c) = await start(tester, skala: skala, entsperren: true);
        // Übersicht
        var s = alleSemantik(tester);
        expect(s, contains('Entsperrt bis 14:02 Uhr'));
        expect(s, isNot(contains(geheimWlan)));
        expect(s, isNot(contains(geheimVertrag)));
        expect(s, isNot(contains(geheimNotiz)));
        await tippe(tester, find.text('Haushalt'));
        s = alleSemantik(tester);
        expect(s, contains('Haushalt, 1 Eintrag'));
        expect(s, contains('WLAN Zuhause, 3 Felder'));
        // Eintrag
        await tippe(tester, find.text('WLAN Zuhause'));
        s = alleSemantik(tester);
        expect(s, isNot(contains(geheimWlan)), reason: 'verdeckter Wert nie in der Bedienhilfe');
        expect(s, isNot(contains('Sonne-Mond')));
        expect(s, contains('Passwort: verdeckt'));
        expect(s, contains('Netzname: $offenNetz'));
        expect(s, contains('Passwort anzeigen'));
        expect(s, contains('Passwort kopieren'));
        expect(s, contains('Für alle Eltern sichtbar'));
        // Editor: verdeckte Eingabefelder geben ihren Inhalt nicht preis
        await tippe(tester, find.text('Bearbeiten'));
        s = alleSemantik(tester);
        expect(s, isNot(contains(geheimWlan)), reason: 'auch im Editor nicht (Feld ist verdeckt)');
        expect(s, contains('Feld 2 nach oben'));
        expect(s, contains('Feld 2 entfernen'));
        await ende(tester, c, a);
        handle.dispose();
      });
    }
  });
}
