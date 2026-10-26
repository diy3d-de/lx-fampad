// Barrierefreiheit: Durchgang über die wichtigsten Oberflächen bei 360 px und Textskala 2.0 (kein Überlauf, Touch-Ziele mindestens 44 px) und eine Prüfung des Semantics-Baums:
// jedes antippbare Element und jedes Textfeld hat eine Beschriftung (Label, Hinweis, Wert oder Tooltip), damit ein Screenreader nie "Schaltfläche" ohne Namen vorliest.
// Die Kontraste der Token prüft kontrast_test.dart, die Suche, das Teilen und die Chat-Suche haben ihre Layout-Tests mit Textskala 2.0 selbst.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/api/models.dart' show MemberStatus, Role, UserDto;
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/crypto/e2ee_state.dart' show cryptoProviderProvider, schluesselSpeicherProvider;
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart' show MemorySchluesselSpeicher;
import 'package:lx_fampad/data/ingest/ingest_dienst.dart' show IngestLauf;
import 'package:lx_fampad/data/ingest/ingest_logik.dart' show PruefGrund;
import 'package:lx_fampad/data/ingest/ingest_state.dart';
import 'package:lx_fampad/data/medikamente/medikament_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart' show Stand;
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/medikamente/medikament_state.dart';
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart' show zaehlerRepositoryProvider;
import 'package:lx_fampad/data/zaehler/zaehler_state.dart' show zaehlerDatenProvider;
import 'package:lx_fampad/features/zaehler/zaehler_diagramm.dart' show VerbrauchsDiagramm;
import 'package:lx_fampad/features/tagesbriefing/briefing_karte.dart' show BriefingStartKarte;
import 'package:lx_fampad/features/neuigkeiten/neuigkeiten_dialog.dart';
import 'package:lx_fampad/data/neuigkeiten/neuigkeiten.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart' show EinstellungsZeile;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/suche/such_einstieg.dart' show SuchKnopf;

import 'support/chat_ui_aufbau.dart';
import 'support/fake_erinnerung_port.dart';

import 'support/fake_crypto.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/ingest_welt.dart';
import 'support/test_app.dart';
import 'support/zaehler_welt.dart';

/// Alle sichtbaren, antippbaren Knoten und Textfelder des Semantics-Baums ohne Beschriftung (Pfad zur Fehlersuche).
List<String> unbeschriftet(WidgetTester tester) {
  final wurzel = tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  final fehler = <String>[];
  if (wurzel == null) return ['kein Semantics-Baum (ensureSemantics fehlt)'];
  void besuche(SemanticsNode n, String pfad) {
    final d = n.getSemanticsData();
    // in den Elternknoten eingemischte Knoten (z. B. der Schalter in einer SwitchListTile) zählen mit diesem
    final versteckt = d.flagsCollection.isHidden || n.isMergedIntoParent;
    if (!versteckt) {
      final bedienbar = d.hasAction(SemanticsAction.tap) || d.flagsCollection.isTextField;
      final name = d.label.trim().isNotEmpty || d.value.trim().isNotEmpty || d.hint.trim().isNotEmpty || d.tooltip.trim().isNotEmpty;
      // ein innerer Knoten gleicher Größe unter einem benannten Knoten gehört zum selben Bedienelement (z. B. der Knopf unter dem Tooltip des Schwebeknopfs)
      final elter = n.parent?.getSemanticsData();
      final vomElterBenannt = elter != null && n.parent!.rect.size == n.rect.size && (elter.label.trim().isNotEmpty || elter.tooltip.trim().isNotEmpty);
      if (bedienbar && !name && !vomElterBenannt) fehler.add('$pfad/${n.id} ${n.rect.size.width.round()}x${n.rect.size.height.round()}');
    }
    n.visitChildren((c) {
      besuche(c, '$pfad/${n.id}');
      return true;
    });
  }

  besuche(wurzel, '');
  return fehler;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  const l1 = '11111111-1111-4111-8111-111111111111';

  Future<TestUmgebung> start(WidgetTester tester, {double skala = 2.0, Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung();
    env.sync.andereAendert('list', l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
    for (final (i, e) in [('Milch', 'Kühlregal'), ('Vollkornbrot mit Sonnenblumenkernen und Leinsamen', 'Backwaren'), ('Äpfel', 'Obst und Gemüse')].indexed) {
      env.sync.andereAendert('list_item', '33333333-3333-4333-8333-00000000000$i', {'listId': l1, 'text': e.$1, 'position': i, 'category': null});
    }
    env.sync.andereAendert('aufgabe', 'bbbbbbbb-1111-4111-8111-111111111111', {'titel': 'Eine Aufgabe mit einem langen Titel, der umbrechen muss', 'beschreibung': '', 'prioritaet': 3});
    env.sync.andereAendert('termin', 'aaaaaaaa-1111-4111-8111-111111111111', {
      'titel': 'Zahnarzt',
      'ganztaegig': true,
      'startDate': '2026-11-14',
      'endDate': '2026-11-15',
      'ownerId': fixIdAdmin,
      'audience': 'family',
    });
    await starteApp(tester, env, skala: skala, groesse: groesse);
    return env;
  }

  Future<void> zumTab(WidgetTester tester, String label) async {
    await zumBereich(tester, label);
  }

  void pruefe(WidgetTester tester, String wo) {
    pruefeLayout(tester, wo);
    final ohne = unbeschriftet(tester);
    expect(ohne, isEmpty, reason: '$wo: Elemente ohne Beschriftung im Semantics-Baum');
  }

  for (final skala in [1.0, 2.0]) {
    group('Textskala $skala', () {
      testWidgets('Startseite', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        pruefe(tester, 'Startseite $skala');
        h.dispose();
      });

      testWidgets('Listen (Einkaufsliste mit Einträgen)', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await zumTab(tester, 'Listen');
        pruefe(tester, 'Listen $skala');
        h.dispose();
      });

      testWidgets('Chat-Liste', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await zumTab(tester, 'Chat');
        pruefe(tester, 'Chat-Liste $skala');
        h.dispose();
      });

      testWidgets('Aufgaben und Kalender', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await zumTab(tester, 'Aufgaben');
        pruefe(tester, 'Aufgaben $skala');
        await zumTab(tester, 'Kalender');
        pruefe(tester, 'Kalender $skala');
        h.dispose();
      });

      testWidgets('Termin-Farben: Farbwahl im Editor, Farben im Filter-Blatt, Termin mit Farbe in der Agenda', (tester) async {
        final h = tester.ensureSemantics();
        final env = await start(tester, skala: skala);
        env.sync.andereAendert('termin', 'aaaaaaaa-2222-4222-8222-222222222222', {
          'titel': 'Rufdienst am Wochenende',
          'ganztaegig': true,
          'startDate': '2026-11-14',
          'endDate': '2026-11-15',
          'ownerId': fixIdAdmin,
          'audience': 'family',
          'farbe': 10,
        });
        await tester.pump(const Duration(seconds: 1));
        await zumTab(tester, 'Kalender');
        pruefe(tester, 'Kalender mit Farbtermin $skala');
        await tippe(tester, find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Filter und Anzeige')));
        expect(labelFinder('Farben'), findsOneWidget);
        pruefe(tester, 'Filter-Blatt mit Farben $skala');
        await tippeText(tester, 'Fertig');
        await tippe(tester, find.byTooltip('Neuer Termin'));
        expect(find.bySemanticsLabel('Farbe Rufdienst'), findsOneWidget);
        pruefe(tester, 'Termin-Editor mit Farbwahl $skala');
        h.dispose();
      });

      testWidgets('Profil: Hauptseite und Sammelseiten', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        pruefe(tester, 'Profil-Hauptseite $skala');
        for (final seite in ['Sicherheit', 'Benachrichtigungen', 'Startseite und Anzeige']) {
          await tippe(tester, find.text(seite));
          pruefe(tester, 'Profil > $seite $skala');
          await tippe(tester, find.byTooltip('Zurück'));
        }
        h.dispose();
      });
    });
  }

  for (final skala in [1.0, 2.0]) {
    group('Weitere Seiten, Textskala $skala', () {
      testWidgets('Kalender-Einstellungen, Startseite anpassen', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippe(tester, find.widgetWithText(EinstellungsZeile, 'Kalender'));
        pruefe(tester, 'Kalender-Einstellungen $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippe(tester, find.text('Startseite und Anzeige'));
        await tippe(tester, find.text('Startseite anpassen'));
        pruefe(tester, 'Startseite anpassen $skala');
        h.dispose();
      });

      testWidgets('Suche und Teilen-Auswahl', (tester) async {
        final h = tester.ensureSemantics();
        await start(tester, skala: skala);
        await tippe(tester, find.byType(SuchKnopf));
        pruefe(tester, 'Suche leer $skala');
        await tester.enterText(find.byType(TextField), 'zahn');
        await tester.pump(const Duration(milliseconds: 300));
        await warte(tester);
        pruefe(tester, 'Suche mit Treffern $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        const codec = StandardMethodCodec();
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(kSystemChannel, codec.encodeMethodCall(const MethodCall('share', 'Ein geteilter Text')), (_) {});
        await warte(tester);
        pruefe(tester, 'Teilen-Auswahl $skala');
        h.dispose();
      });

      testWidgets('Chat-Verlauf mit Suchleiste', (tester) async {
        final h = tester.ensureSemantics();
        final env = await angemeldeteUmgebung();
        final a = ChatUiAufbau(env);
        env.extraOverrides.addAll(a.overrides);
        env.server.json('GET /members', {
          'members': [userJson(), userJson(id: fixIdKind, role: 'child', name: 'Ben', email: 'ben@beispiel.de'), userJson(id: coraId, role: 'parent', name: 'Cora Berger', email: 'cora@beispiel.de')],
        });
        const fam = '44444444-4444-4444-8444-444444444444';
        env.sync.andereAendert('konversation', fam, {'art': 'family', 'encVersion': 'e1', 'titel': '', 'teilnehmer': <String>[], 'ownerId': null, 'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String()});
        await a.epoche(fam, [a.anna, a.ben, a.cora], art: 'family');
        await a.nachricht(fam, 'a0000000-0000-4000-8000-000000000001', a.ben, 'Wer holt heute die Kinder ab? Das ist eine längere Nachricht, die umbrechen muss.', DateTime.now().toUtc().subtract(const Duration(minutes: 30)).toIso8601String());
        await starteApp(tester, env, skala: skala);
        await zumTab(tester, 'Chat');
        await tippe(tester, find.textContaining('Wer holt heute'));
        pruefe(tester, 'Chat-Verlauf $skala');
        await tippe(tester, find.byTooltip('Im Chat suchen'));
        await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == 'In diesem Chat suchen …'), 'kinder');
        await tester.pump(const Duration(milliseconds: 400));
        await warte(tester, 10);
        pruefe(tester, 'Chat-Suchleiste $skala');
        h.dispose();
      });

      testWidgets('Neuigkeiten-Dialog und Countdown-Kachel', (tester) async {
        final h = tester.ensureSemantics();
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(skala)), child: w!),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () => neuigkeitenDialogZeigen(ctx, Neuigkeit('0.9.2', [for (var i = 0; i < 4; i++) 'Ein längerer Stichpunkt Nummer $i, der in der schmalen Breite umbrechen muss']), onGesehen: () {}),
                  child: const Text('auf'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('auf'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(unbeschriftet(tester), isEmpty, reason: 'Neuigkeiten-Dialog');
        expect(tester.getSize(find.byType(TextButton).last).height, greaterThanOrEqualTo(44));
        h.dispose();
      });
    });
  }

  // Medikamenten-Plan: Heute (mit Filter, Warnkarte, bei Bedarf), Detail und Editor, jedes Bedienelement beschriftet
  for (final skala in [1.0, 2.0]) {
    group('Medikamente, Textskala $skala', () {
      const med1 = 'dddddddd-0000-4000-8000-000000000001';
      const med2 = 'dddddddd-0000-4000-8000-000000000002';
      const med3 = 'dddddddd-0000-4000-8000-000000000003';
      final daten = MedDaten(
        geladen: true,
        ich: fixIdAdmin,
        ichRolle: Role.admin,
        personen: const [
          UserDto(id: fixIdAdmin, email: null, displayName: 'Anna', colorIndex: 0, role: Role.admin, status: MemberStatus.active),
          UserDto(id: fixIdKind, email: null, displayName: 'Ben', colorIndex: 1, role: Role.child, status: MemberStatus.active),
        ],
        eintraege: [
          MedEintrag(MedikamentAnsicht(id: med1, konversationId: 'k1', subjektId: fixIdAdmin, inhalt: const MedikamentInhalt(name: 'Blutdrucktablette', dosis: '5 mg', zeiten: ['00:01', '23:59'], beginn: '2026-10-01'), erstelltAt: DateTime.utc(2026, 10, 1)), const []),
          MedEintrag(MedikamentAnsicht(id: med2, konversationId: 'k2', subjektId: fixIdKind, inhalt: MedikamentInhalt(name: 'Vitamin D', zeiten: const ['00:02'], beginn: '2026-10-01', bestand: 3, bestandStand: DateTime.now().toUtc(), packung: 30), erstelltAt: DateTime.utc(2026, 10, 1)), const []),
          MedEintrag(MedikamentAnsicht(id: med3, konversationId: 'k1', subjektId: fixIdAdmin, inhalt: const MedikamentInhalt(name: 'Nasenspray', rhythmus: Rhythmus.bedarf(), beginn: '2026-10-01'), erstelltAt: DateTime.utc(2026, 10, 1)), const []),
        ],
      );

      Future<void> medStart(WidgetTester tester) async {
        final env = await angemeldeteUmgebung();
        env.extraOverrides.addAll([
          erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
          medDatenProvider.overrideWithValue(daten),
          medAnsichtProvider.overrideWithValue(daten),
        ]);
        await starteApp(tester, env, skala: skala, groesse: const Size(360, 900));
        await zumTab(tester, 'Medikamente');
      }

      testWidgets('Heute und Detail', (tester) async {
        final h = tester.ensureSemantics();
        await medStart(tester);
        pruefe(tester, 'Medikamente Heute $skala');
        await tippe(tester, find.text('Vitamin D').first);
        pruefe(tester, 'Medikament Detail $skala');
        h.dispose();
      });

      testWidgets('Editor', (tester) async {
        final h = tester.ensureSemantics();
        await medStart(tester);
        await tippe(tester, find.widgetWithText(FilledButton, 'Medikament'));
        pruefe(tester, 'Medikament Editor $skala');
        await tippe(tester, find.text('Wochentage'));
        pruefe(tester, 'Medikament Editor Wochentage $skala');
        h.dispose();
      });

      // Zähler (nur Eltern und Admins): Übersicht, Verlauf mit bedienbarem Diagramm, Stand eintragen, Einrichten, Bericht
      Future<ZaehlerRepoAttrappe> zaehlerStart(WidgetTester tester) async {
        final repo = ZaehlerRepoAttrappe();
        final env = await angemeldeteUmgebung();
        final st = monatsStaende();
        final d = datenAus([
          strom(staende: st.sublist(0, st.length - 1)),
          wasser(zKalt1, 'Kaltwasser Etage'),
          wasser(zKalt2, 'Kaltwasser Waschkeller', start: 50, proMonat: 2),
          solar(),
        ]);
        env.extraOverrides.addAll([
          erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
          zaehlerTestUhr,
          zaehlerDatenProvider.overrideWithValue(d),
          zaehlerRepositoryProvider.overrideWithValue(repo),
        ]);
        await starteApp(tester, env, skala: skala, groesse: const Size(360, 900));
        await zumTab(tester, 'Zähler');
        return repo;
      }

      testWidgets('Zähler: Übersicht', (tester) async {
        final h = tester.ensureSemantics();
        await zaehlerStart(tester);
        pruefe(tester, 'Zähler Übersicht $skala');
        h.dispose();
      });

      testWidgets('Zähler: Verlauf mit Diagramm (Wert, Nachbarwerte, Schrittaktionen)', (tester) async {
        final h = tester.ensureSemantics();
        await zaehlerStart(tester);
        await tippe(tester, find.bySemanticsLabel(RegExp(r'^Strom.')));
        pruefe(tester, 'Zähler Verlauf $skala');
        // das Diagramm trägt Wert, Vor- und Nachwert und beide Schrittaktionen
        final diagramm = tester.getSemantics(find.byType(VerbrauchsDiagramm));
        final data = diagramm.getSemanticsData();
        expect(data.hasAction(SemanticsAction.increase), isTrue);
        expect(data.hasAction(SemanticsAction.decrease), isTrue);
        expect(data.label, contains('Verbrauch je Monat'));
        expect(data.label, contains('Januar 2026'));
        expect(data.increasedValue, isNotEmpty);
        expect(data.decreasedValue, isNotEmpty);
        tester.semantics.increase(find.semantics.byLabel(RegExp(r'^Verbrauch je Monat')));
        await warte(tester);
        expect(find.textContaining('September'), findsOneWidget);
        h.dispose();
      });

      testWidgets('Zähler: Stand eintragen mit Hinweis, Einrichten, Bericht', (tester) async {
        final h = tester.ensureSemantics();
        await zaehlerStart(tester);
        await tippe(tester, find.widgetWithText(FilledButton, 'Stand eintragen'));
        pruefe(tester, 'Zähler Stand $skala');
        await eingeben(tester, 'Zählerstand in kWh', '100');
        await warte(tester);
        pruefe(tester, 'Zähler Stand mit Hinweis $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippe(tester, find.byTooltip('Zähler hinzufügen'));
        pruefe(tester, 'Zähler Editor $skala');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippe(tester, find.byTooltip('Bericht als PDF'));
        pruefe(tester, 'Zähler Bericht $skala');
        h.dispose();
      });

      // Home Assistant (Werte automatisch abholen): Zeile auf der Zähler-Seite, Seite, Koppeln, Prüfliste, Abschnitt "Quelle" im Editor
      Future<void> haStart(WidgetTester tester, {IngestZustand? zustand, String role = 'admin', bool altStand = false}) async {
        final repo = ZaehlerRepoAttrappe();
        final env = await angemeldeteUmgebung(role: role);
        // altStand: der letzte Wert liegt über 3 Tage zurück (Karte "kein Wert")
        final st = altStand ? [for (var i = 0; i < 4; i++) Stand(heuteTag().subtract(Duration(days: 10 - i)), 1000000 + 10000 * i)] : monatsStaende();
        final d = datenAus([
          ZaehlerBeispiel(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus', quelle: const ZaehlerQuelle(kanal: 'strom_bezug')), st),
          wasser(zKalt1, 'Kaltwasser Etage', gruppe: ''),
        ]);
        env.server.on('GET /ingest/tokens', (_) => jsonAntwort({'tokens': [{'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null}]}));
        env.server.on('POST /ingest/tokens', (req) => jsonAntwort({'token': 'fhi_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'id': 't9', 'name': req.json['name'], 'createdAt': '2026-10-24T10:00:00.000Z'}));
        env.extraOverrides.addAll([
          erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
          zaehlerTestUhr,
          zaehlerDatenProvider.overrideWithValue(d),
          zaehlerRepositoryProvider.overrideWithValue(repo),
          ingestProvider.overrideWith(() => TestIngest(zustand ?? IngestZustand(geladen: true, schalter: true, postfachDa: true, letzter: IngestLauf(zeit: DateTime.now(), eingetragen: 2, wartend: 1, fremd: 1, ohneZaehler: 1), zuPruefen: [pruefEintrag(), pruefEintrag(id: 'p2', grund: PruefGrund.sprung)]))),
          ingestVerfuegbarProvider.overrideWith((ref) async => true),
          schluesselSpeicherProvider.overrideWithValue(MemorySchluesselSpeicher()),
          cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider(seed: 3)),
        ]);
        await starteApp(tester, env, skala: skala, groesse: const Size(360, 900));
        await zumTab(tester, 'Zähler');
      }

      testWidgets('Zähler mit Home Assistant: Übersicht, Seite, Koppeln, Prüfliste', (tester) async {
        final h = tester.ensureSemantics();
        await haStart(tester);
        pruefe(tester, 'Zähler Übersicht mit Home Assistant $skala');
        await tippe(tester, find.text('Home Assistant'));
        pruefe(tester, 'Home Assistant Seite $skala');
        await tippe(tester, find.text('Neue Verbindung koppeln …'));
        pruefe(tester, 'Home Assistant Koppeln $skala');
        await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
        pruefe(tester, 'Home Assistant Kopplungscode $skala');
        await tippe(tester, find.textContaining('QR-Code zeigen'));
        pruefe(tester, 'Home Assistant Kopplungscode mit QR $skala');
        await tippe(tester, find.text('Es klappt nicht?'));
        pruefe(tester, 'Home Assistant Hilfe $skala');
        await tippe(tester, find.text('Zurück zum Code'));
        await tippe(tester, find.widgetWithText(FilledButton, 'Weiter: Zähler zuordnen'));
        pruefe(tester, 'Home Assistant Rückfrage Code $skala');
        await tippe(tester, find.text('Ja, eingegeben'));
        pruefe(tester, 'Home Assistant Zähler zuordnen $skala');
        await tippe(tester, find.widgetWithText(FilledButton, 'Fertig'));
        await tippe(tester, find.text('Technische Details'));
        pruefe(tester, 'Home Assistant Seite mit Details $skala');
        await tippe(tester, find.textContaining('Werte warten auf dich'));
        pruefe(tester, 'Home Assistant Prüfliste $skala');
        h.dispose();
      });

      testWidgets('Zähler mit Home Assistant auf einem Gerät ohne Schlüssel (zweites Elternteil) und mit "kein Wert"', (tester) async {
        final h = tester.ensureSemantics();
        await haStart(tester, zustand: const IngestZustand(geladen: true), role: 'parent', altStand: true);
        pruefe(tester, 'Zähler Übersicht kein Wert $skala');
        await tippe(tester, find.widgetWithText(TextButton, 'Prüfen'));
        pruefe(tester, 'Home Assistant anderes Gerät $skala');
        h.dispose();
      });

      testWidgets('Zähler-Editor mit Quelle Home Assistant', (tester) async {
        final h = tester.ensureSemantics();
        await haStart(tester);
        await tippe(tester, find.byTooltip('Zähler hinzufügen'));
        await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
        pruefe(tester, 'Zähler Editor Quelle $skala');
        h.dispose();
      });
    });
  }

  testWidgets('Prüfer erkennt einen Icon-Knopf ohne Beschriftung und akzeptiert einen mit Tooltip', (tester) async {
    final h = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Row(children: [IconButton(icon: const Icon(Icons.add), onPressed: () {})]))));
    expect(unbeschriftet(tester), isNotEmpty);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Row(children: [IconButton(tooltip: 'Hinzufügen', icon: const Icon(Icons.add), onPressed: () {})]))));
    expect(unbeschriftet(tester), isEmpty);
    h.dispose();
  });

  testWidgets('Desktop-Layout: Seitenleiste und Startseite haben beschriftete Bedienelemente', (tester) async {
    final h = tester.ensureSemantics();
    final env = await start(tester, skala: 1.0, groesse: const Size(1200, 800));
    expect(env, isNotNull);
    pruefe(tester, 'Desktop-Startseite');
    h.dispose();
  });

  // Tagesbriefing: Startseiten-Kachel "Heute im Überblick" (nur Text, kein Tipp-Knopf) und die Schalter in den Einstellungen
  for (final skala in [1.0, 2.0]) {
    testWidgets('Tagesbriefing: Kachel und Einstellungen, Textskala $skala', (tester) async {
      final h = tester.ensureSemantics();
      final env = await angemeldeteUmgebung();
      final heute = heuteTag();
      String tag(int n) => tagText(DateTime.utc(heute.year, heute.month, heute.day + n));
      env.sync.andereAendert('termin', 'aaaaaaaa-2222-4222-8222-222222222222', {'titel': 'Familienfeier', 'ganztaegig': true, 'startDate': tag(0), 'endDate': tag(1), 'ownerId': fixIdAdmin, 'audience': 'family'});
      env.sync.andereAendert('aufgabe', 'bbbbbbbb-2222-4222-8222-222222222222', {'titel': 'Eine Aufgabe', 'faelligDate': tag(0), 'assigneeId': fixIdAdmin});
      await starteApp(tester, env, skala: skala);
      expect(find.byType(BriefingStartKarte), findsOneWidget);
      pruefe(tester, 'Startseite mit Tagesbriefing $skala');
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Startseite und Anzeige'));
      expect(find.text('Tagesbriefing'), findsOneWidget);
      pruefe(tester, 'Startseite und Anzeige mit Tagesbriefing $skala');
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.text('Benachrichtigungen'));
      expect(find.text('Morgens benachrichtigen'), findsOneWidget);
      pruefe(tester, 'Benachrichtigungen mit Tagesbriefing $skala');
      h.dispose();
    });
  }

  test('Konstante: Touch-Ziel-Mindestmaß', () => expect(minZiel, 44.0));
  test('Konstante: Desktop-Grenze', () => expect(kDesktopBreakpoint, 900.0));
  test('Konstante: Listen-Tab', () => expect(kTabs[kListenTab].label, 'Listen'));
}
