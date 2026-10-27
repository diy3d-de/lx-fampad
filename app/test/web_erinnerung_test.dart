// Erinnerungen in der Web-App: Dienst + Web-Port + Minutentakt gegen die lokale Datenbank (fester Uhr, Fake-Browser), Profil-Seite im Web (Schalter,
// Erlaubnis nur auf Klick, Zustände), Hinweiskarte der Startseite (fällig, verpasst), Wandtablet, Schalter aus, Wiper; nie ein Titel in Benachrichtigung
// oder Hinweis. Layout bei 360 px, Textskala 1.0/1.5/2.0.
import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart' show MemoryFeiertageSpeicher;
import 'package:lx_fampad/data/tagesbriefing/briefing_einstellungen.dart' show kBriefingKachelSchluessel;
import 'package:lx_fampad/data/erinnerungen/browser_benachrichtigung.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_einstellungen.dart';
import 'package:lx_fampad/data/erinnerungen/web_erinnerung_logik.dart';
import 'package:lx_fampad/data/erinnerungen/web_erinnerung_port.dart';
import 'package:lx_fampad/data/erinnerungen/web_erinnerung_state.dart';
import 'package:lx_fampad/data/sync_state.dart' show lokaleDatenWiper;
import 'package:lx_fampad/data/wandtablet/wandtablet_einstellungen.dart' show wandtabletLaeuftProvider;
import 'package:lx_fampad/features/calendar/calendar_anzeige.dart' show minutenTaktProvider;
import 'package:lx_fampad/features/calendar/erinnerung_steuerung.dart';
import 'package:lx_fampad/features/calendar/web_erinnerung_steuerung.dart';
import 'package:lx_fampad/features/home/web_erinnerung_karte.dart';
import 'package:lx_fampad/features/profile/profil_plattform.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_server.dart' show fixIdAdmin;
import 'support/harness.dart';
import 'support/test_app.dart' show TestUmgebung;

const _u = '3f2b8c1e-9d4a-4b6f-8a1c-2e7d5f0a9b13';
const _titel = 'Zahnarzt Dr. Geheim';

TermineCompanion _termin(String id, DateTime start, {int min = 15}) => TermineCompanion.insert(
  id: id,
  titel: _titel,
  ort: const Value('Praxis Geheimweg 1'),
  startUtc: Value(start),
  endUtc: Value(start.add(const Duration(hours: 1))),
  tzid: const Value('Europe/Berlin'),
  erinnerungMin: Value(min),
  ownerId: const Value(fixIdAdmin),
  createdAt: DateTime.utc(2026, 10, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(testVorbereiten);
  tzdata.initializeTimeZones();

  late TestUmgebung env;
  late FakeBrowserBenachrichtigung browser;
  late MemoryFeiertageSpeicher sp;
  late StreamController<DateTime> takt;
  late DateTime nun;

  Future<void> vorbereiten({BrowserErlaubnis stand = BrowserErlaubnis.erlaubt, bool an = true}) async {
    env = await angemeldeteUmgebung();
    sp = MemoryFeiertageSpeicher(null, {kBriefingKachelSchluessel: 'nein'});
    env.speicher = sp;
    browser = FakeBrowserBenachrichtigung(stand: stand);
    takt = StreamController<DateTime>.broadcast();
    nun = DateTime.utc(2026, 10, 19, 10);
    if (an) sp.werte[kWebAnSchluessel] = 'ja';
    env.extraOverrides.addAll([
      browserBenachrichtigungProvider.overrideWithValue(browser),
      erinnerungPortProvider.overrideWith((ref) => ref.watch(webErinnerungPortProvider)),
      erinnerungUhrProvider.overrideWithValue(() => nun),
      erinnerungEntprellenProvider.overrideWithValue(Duration.zero),
      erinnerungSpeicherProvider.overrideWithValue(MemoryErinnerungSpeicher()),
      minutenTaktProvider.overrideWith((ref) => takt.stream),
      profilWebProvider.overrideWithValue(true),
    ]);
  }

  Future<void> bis(bool Function() bedingung, {String grund = 'Bedingung'}) async {
    for (var i = 0; i < 100; i++) {
      if (bedingung()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Zeitüberschreitung: $grund');
  }

  Future<void> tick(ProviderContainer c, DateTime zeit) async {
    nun = zeit;
    takt.add(zeit);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  group('Dienst, Port und Takt', () {
    late ProviderContainer c;

    Future<void> los() async {
      c = env.container();
      addTearDown(c.dispose);
      addTearDown(takt.close);
      await c.read(authProvider.notifier).start();
      c.listen(erinnerungSteuerungProvider, (_, _) {});
      c.listen(webErinnerungSteuerungProvider, (_, _) {});
    }

    WebErinnerungPort port() => c.read(erinnerungPortProvider) as WebErinnerungPort;

    test('fällig: eine neutrale Benachrichtigung, ein Hinweis, nie doppelt; der Titel erscheint nirgends', () async {
      await vorbereiten();
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await bis(() => port().plan.length == 1, grund: 'Schnappschuss');
      expect(browser.gezeigt, isEmpty, reason: 'vor der Zeit nichts');
      await tick(c, DateTime.utc(2026, 10, 19, 11, 16));
      expect(browser.gezeigt, hasLength(1));
      final g = browser.gezeigt.single;
      expect(g.text, 'Erinnerung: Ein Termin steht an');
      expect('${g.titel} ${g.text} ${g.tag}', isNot(anyOf(contains('Zahnarzt'), contains('Geheim'), contains('Praxis'))));
      expect(c.read(webHinweiseProvider).neu, hasLength(1));
      await tick(c, DateTime.utc(2026, 10, 19, 11, 17));
      await tick(c, DateTime.utc(2026, 10, 19, 11, 18));
      expect(browser.gezeigt, hasLength(1), reason: 'nie doppelt, auch nicht nach einer neuen Planung');
      await c.read(erinnerungDienstProvider).abgleichen();
      await tick(c, DateTime.utc(2026, 10, 19, 11, 19));
      expect(browser.gezeigt, hasLength(1));
    });

    test('Titel zeigen auf dem Sperrbildschirm (Android-Einstellung) ändert nichts: das Web bleibt neutral', () async {
      await vorbereiten();
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await c.read(erinnerungEinstellungenProvider.notifier).sperrbildschirmSetzen(true);
      await bis(() => port().plan.length == 1);
      await tick(c, DateTime.utc(2026, 10, 19, 11, 16));
      expect(browser.gezeigt.single.text, isNot(contains('Zahnarzt')));
    });

    test('ohne Browser-Erlaubnis: kein Aufruf der Anzeige, der Hinweis in der App kommt trotzdem', () async {
      await vorbereiten(stand: BrowserErlaubnis.blockiert);
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await bis(() => port().plan.length == 1);
      await tick(c, DateTime.utc(2026, 10, 19, 11, 16));
      expect(browser.gezeigt, isEmpty);
      expect(c.read(webHinweiseProvider).neu, hasLength(1));
    });

    test('nach einer Pause: zu spät für eine Benachrichtigung, nur die ruhige Zeile "verpasst"', () async {
      await vorbereiten();
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await bis(() => port().plan.length == 1);
      await tick(c, DateTime.utc(2026, 10, 19, 14));
      expect(browser.gezeigt, isEmpty);
      expect(c.read(webHinweiseProvider).neu, isEmpty);
      expect(c.read(webHinweiseProvider).verpasst, hasLength(1));
    });

    test('Wandtablet: nichts gezeigt und nichts als gezeigt gemerkt', () async {
      await vorbereiten();
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await bis(() => port().plan.length == 1);
      c.read(wandtabletLaeuftProvider.notifier).setzen(true);
      await tick(c, DateTime.utc(2026, 10, 19, 11, 16));
      expect(browser.gezeigt, isEmpty);
      expect(c.read(webHinweiseProvider).neu, isEmpty);
      c.read(wandtabletLaeuftProvider.notifier).setzen(false);
      await tick(c, DateTime.utc(2026, 10, 19, 11, 17));
      expect(browser.gezeigt, hasLength(1), reason: 'noch in der Toleranz: jetzt wird es gezeigt');
    });

    test('Schalter aus (Standard): nichts wird geplant, gehalten oder gezeigt', () async {
      await vorbereiten(an: false);
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(port().plan, isEmpty);
      expect(sp.werte[kWebPlanSchluessel], isNull);
      await tick(c, DateTime.utc(2026, 10, 19, 11, 16));
      expect(browser.gezeigt, isEmpty);
      expect(browser.anfragenAnzahl, 0, reason: 'die Erlaubnis wird nie von selbst angefragt');
    });

    test('Ausschalten leert Ablage und Hinweise; der Wiper (Abmelden, Personenwechsel) leert Merkliste, Schnappschuss und Schalter', () async {
      await vorbereiten();
      await env.db.into(env.db.termine).insert(_termin(_u, DateTime.utc(2026, 10, 19, 11, 30)));
      await los();
      await bis(() => port().plan.length == 1);
      await tick(c, DateTime.utc(2026, 10, 19, 11, 16));
      expect(sp.werte[kWebMerklisteSchluessel], isNotNull);
      await c.read(webErinnerungAnProvider.notifier).ausschalten();
      expect(c.read(webHinweiseProvider).leer, isTrue);
      expect(sp.werte[kWebPlanSchluessel], isNull);
      expect(sp.werte[kWebMerklisteSchluessel], isNull);

      nun = DateTime.utc(2026, 10, 19, 10);
      await c.read(webErinnerungAnProvider.notifier).einschalten();
      await bis(() => port().plan.isNotEmpty || nun.isAfter(DateTime.utc(2030)), grund: 'neue Planung nach dem Einschalten');
      final wiper = Provider<Future<void> Function()>((ref) => lokaleDatenWiper(ref));
      await c.read(wiper)();
      expect(port().plan, isEmpty);
      expect(sp.werte[kWebPlanSchluessel], isNull);
      expect(sp.werte[kWebMerklisteSchluessel], isNull);
      expect(c.read(webHinweiseProvider).leer, isTrue);
    });
  });

  group('Oberfläche', () {
    Future<ProviderContainer> start(WidgetTester tester, {double skala = 1.0, Size groesse = const Size(360, 800)}) async {
      final c = await starteApp(tester, env, skala: skala, groesse: groesse);
      return c;
    }

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Profil-Seite im Web, Textskala $skala: Schalter aus, keine Anfrage beim Öffnen, Einschalten fragt, Erlaubnis angezeigt, Touch-Ziele', (tester) async {
        await vorbereiten(stand: BrowserErlaubnis.offen, an: false);
        await start(tester, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Erinnerungen im Browser');
        expect(find.text('Erinnerungen im Browser'), findsWidgets);
        expect(find.textContaining('Nur solange die Web-App geöffnet ist'), findsOneWidget);
        expect(find.textContaining('Hintergrundnutzungsgrenzen'), findsNothing, reason: 'Android-Teile fehlen im Web');
        expect(find.text('Titel auf Sperrbildschirm zeigen'), findsNothing);
        expect(find.text('Medikamenten-Erinnerungen'), findsOneWidget);
        final schalter = find.descendant(of: find.widgetWithText(SwitchListTile, 'Erinnerungen im Browser'), matching: find.byType(Switch));
        expect(tester.widget<Switch>(schalter).value, isFalse);
        expect(browser.anfragenAnzahl, 0);
        await tippe(tester, schalter);
        await warte(tester, 10);
        expect(browser.anfragenAnzahl, 1);
        expect(tester.widget<Switch>(schalter).value, isTrue);
        expect(find.textContaining('erlaubt Benachrichtigungen'), findsOneWidget);
        expect(sp.werte[kWebAnSchluessel], 'ja');
        for (final f in [find.byType(SwitchListTile), find.byType(OutlinedButton)]) {
          for (final e in f.evaluate()) {
            expect((e.renderObject! as RenderBox).size.height, greaterThanOrEqualTo(44), reason: '${e.widget.runtimeType}');
          }
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Profil-Seite: blockiert und nicht unterstützt werden ehrlich benannt, kein Test-Knopf', (tester) async {
      await vorbereiten(stand: BrowserErlaubnis.blockiert);
      await start(tester);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Erinnerungen im Browser');
      expect(find.textContaining('blockiert Benachrichtigungen'), findsOneWidget);
      expect(find.text('Testbenachrichtigung in 10 Sekunden'), findsNothing);
      expect(find.text('Benachrichtigungen erlauben'), findsNothing);
    });

    testWidgets('Benachrichtigungen-Seite: Zeile "Erinnerungen im Browser" mit Zustand', (tester) async {
      await vorbereiten(an: false);
      await start(tester);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Benachrichtigungen'));
      expect(find.text('Erinnerungen im Browser'), findsOneWidget);
      expect(find.text('Aus'), findsWidgets);
    });

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Startseite, Textskala $skala: Hinweis (neutral, schließbar, tippen öffnet) und "Verpasst seit du weg warst"', (tester) async {
        await vorbereiten();
        final jetzt = DateTime.utc(2026, 10, 19, 12);
        // gespeicherter Schnappschuss: eine gerade fällige Aufgabe, zwei verpasste (Termin, Müll)
        final plan = [
          WebEintrag(1, jetzt.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch, 'aufgabe|$_u'),
          WebEintrag(2, jetzt.subtract(const Duration(hours: 2)).millisecondsSinceEpoch, 'termin|$_u|2026-10-19'),
          WebEintrag(3, jetzt.subtract(const Duration(hours: 3)).millisecondsSinceEpoch, 'muell|2026-10-19'),
        ];
        sp.werte[kWebPlanSchluessel] = webPlanKodieren(plan);
        nun = jetzt;
        final h = tester.ensureSemantics();
        final c = await start(tester, skala: skala, groesse: const Size(360, 900));
        await warte(tester, 10);
        expect(find.text('Erinnerung: Eine Aufgabe steht an'), findsOneWidget);
        expect(browser.gezeigt, hasLength(1));
        expect(browser.gezeigt.single.text, 'Erinnerung: Eine Aufgabe steht an');
        expect(find.textContaining('Verpasst seit du weg warst: 2 Erinnerungen'), findsOneWidget);
        expect(find.textContaining('Erinnerung: Ein Termin steht an'), findsNothing, reason: 'die Liste ist zugeklappt');
        await tippe(tester, find.textContaining('Verpasst seit du weg warst'));
        expect(find.textContaining('Erinnerung: Ein Termin steht an'), findsOneWidget);
        expect(find.textContaining('Erinnerung: Eine Abholung steht an'), findsOneWidget);
        // Touch-Ziele und Bedienhilfe
        for (final f in [find.byType(IconButton), find.byType(InkWell)]) {
          for (final e in f.evaluate()) {
            final box = e.renderObject;
            if (box is RenderBox && box.hasSize && (e.widget is IconButton || find.descendant(of: find.byType(WebErinnerungKarte), matching: find.byWidget(e.widget)).evaluate().isNotEmpty)) {
              expect(box.size.height, greaterThanOrEqualTo(44), reason: '${e.widget.runtimeType}');
            }
          }
        }
        expect(find.byTooltip('Hinweis schließen'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Verpasst seit du weg warst')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tippe(tester, find.text('Alles gesehen'));
        expect(c.read(webHinweiseProvider).verpasst, isEmpty);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 900)); // zurück nach oben (die Seite hat zum Tippen gescrollt)
        await warte(tester, 3);
        expect(find.textContaining('Verpasst seit du weg warst'), findsNothing);
        await tippe(tester, find.byTooltip('Hinweis schließen'));
        expect(find.text('Erinnerung: Eine Aufgabe steht an'), findsNothing);
        h.dispose();
      });
    }

    testWidgets('Tipp auf den Hinweis öffnet das Ziel (Aufgabe) und nimmt den Hinweis weg', (tester) async {
      await vorbereiten();
      final jetzt = DateTime.utc(2026, 10, 19, 12);
      sp.werte[kWebPlanSchluessel] = webPlanKodieren([WebEintrag(1, jetzt.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch, 'muell|2026-10-20')]);
      nun = jetzt;
      final c = await start(tester);
      await warte(tester, 10);
      await tippe(tester, find.text('Erinnerung: Eine Abholung steht an'));
      expect(c.read(webHinweiseProvider).neu, isEmpty);
    });

    testWidgets('Ohne Hinweise ist die Karte unsichtbar', (tester) async {
      await vorbereiten();
      await start(tester);
      await warte(tester, 4);
      expect(find.byType(WebErinnerungKarte), findsOneWidget);
      expect(find.textContaining('Erinnerung:'), findsNothing);
      expect(find.textContaining('Verpasst'), findsNothing);
    });
  });
}
