// Home-Assistant-Anbindung der Zähler: Oberfläche und Zustand. Zähler-Seite (Herkunft "Home Assistant" / "von Hand", Zeile "Home Assistant", "1 Wert prüfen" nur dort), Seite "Home Assistant"
// (Schalter je Gerät, Zustand, Jetzt abholen, Verbindungen, Koppeln mit einmal angezeigtem Code, Trennen), Prüfliste, Abschnitt "Quelle" im Zähler-Editor; 360 px und Textskala 1.5/2.0;
// Kinder sehen nichts; Schalter aus = kein Abruf. Daten kommen über überschriebene Provider, der Dienst selbst ist in ingest_dienst_test.dart geprüft.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/auth/auth_state.dart' show authProvider;
import 'package:lx_fampad/data/crypto/e2ee_state.dart' show cryptoProviderProvider, schluesselSpeicherProvider, schluesselVomGeraetLoeschen;
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/ingest/ingest_dienst.dart';
import 'package:lx_fampad/data/ingest/ingest_kopplung.dart';
import 'package:lx_fampad/data/ingest/ingest_logik.dart' show PruefGrund;
import 'package:lx_fampad/data/ingest/ingest_state.dart';
import 'package:lx_fampad/data/ingest/ingest_zwischenablage.dart';
import 'package:lx_fampad/data/tresor/tresor_zwischenablage.dart' show TresorZwischenablage;
import 'package:lx_fampad/data/zaehler/zaehler_logik.dart' show Stand;
import 'package:lx_fampad/data/zaehler/zaehler_modelle.dart';
import 'package:lx_fampad/data/zaehler/zaehler_repository.dart';
import 'package:lx_fampad/data/zaehler/zaehler_state.dart';
import 'package:lx_fampad/features/auth/auth_widgets.dart' show MeldungsBox;
import 'package:lx_fampad/features/zaehler/ha_verbindung_screen.dart';
import 'package:lx_fampad/features/zaehler/ha_zuordnen_screen.dart' show HaZuordnenScreen;
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_crypto.dart';
import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/ingest_welt.dart';
import 'support/test_app.dart';
import 'support/zaehler_welt.dart';

const _aktiv = IngestZustand(geladen: true, schalter: true, postfachDa: true);

ZaehlerBeispiel _haStrom({String kanal = 'strom_bezug', bool pruefen = true}) => ZaehlerBeispiel(
  zStrom,
  ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus', quelle: ZaehlerQuelle(kanal: kanal, pruefen: pruefen)),
  [for (var i = 0; i < 5; i++) Stand(heuteTag().subtract(Duration(days: 4 - i)), (2951000 + 10000 * i))],
);

ZaehlerBeispiel _handWasser() => wasser(zKalt1, 'Wasser Küche', gruppe: '');

const _token = 'fhi_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  late ZaehlerRepoAttrappe repo;
  late TestIngest ingest;
  late MemorySchluesselSpeicher speicher;
  late TestUmgebung env;
  late List<Map<String, dynamic>> tokens;

  Future<ProviderContainer> start(
    WidgetTester tester,
    ZaehlerDaten d, {
    String role = 'admin',
    IngestZustand zustand = _aktiv,
    bool verfuegbar = true,
    double skala = 1.0,
    String? bereich = 'Zähler',
    List<Map<String, dynamic>>? verbindungen,
    List<Override> mehr = const [],
    TestIngest? ingestAlt,
    MemorySchluesselSpeicher? speicherAlt,
  }) async {
    repo = ZaehlerRepoAttrappe();
    ingest = ingestAlt ?? TestIngest(zustand);
    speicher = speicherAlt ?? MemorySchluesselSpeicher();
    tokens = verbindungen ?? [];
    env = await angemeldeteUmgebung(role: role);
    env.server.on('GET /ingest/tokens', (_) => jsonAntwort({'tokens': tokens}));
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
      zaehlerTestUhr,
      zaehlerDatenProvider.overrideWithValue(d),
      zaehlerRepositoryProvider.overrideWithValue(repo),
      ingestProvider.overrideWith(() => ingest),
      ingestVerfuegbarProvider.overrideWith((ref) async => verfuegbar),
      schluesselSpeicherProvider.overrideWithValue(speicher),
      cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider(seed: 3)),
      ...mehr,
    ]);
    final c = await starteApp(tester, env, skala: skala, groesse: const Size(360, 900));
    if (bereich != null) await zumBereich(tester, bereich);
    return c;
  }

  Future<void> zurHaSeite(WidgetTester tester) async {
    await tippe(tester, find.text('Home Assistant'));
    expect(find.text('Werte automatisch abholen'), findsOneWidget);
  }

  group('Zähler-Seite', () {
    testWidgets('Herkunft: nur automatische Zähler tragen "Home Assistant" auf der Kachel, Zähler von Hand tragen nichts (keine Pille "von Hand")', (tester) async {
      await start(tester, datenAus([_haStrom(), _handWasser()]));
      expect(find.text('⇄ HOME ASSISTANT'), findsOneWidget);
      expect(find.text('VON HAND'), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'^Strom Haus\..*Werte aus Home Assistant')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Wasser Küche\..*Von Hand')), findsNothing);
      pruefeLayout(tester, 'Übersicht mit Herkunft');
    });

    testWidgets('Ohne automatische Zähler: keine Herkunfts-Pillen (alles wie bisher)', (tester) async {
      await start(tester, datenAus([_handWasser()]), verfuegbar: false);
      expect(find.text('VON HAND'), findsNothing);
      expect(find.text('⇄ HOME ASSISTANT'), findsNothing);
      expect(find.text('Home Assistant'), findsNothing); // Server ohne Einwurf: keine Zeile
    });

    testWidgets('Zeile "Home Assistant" öffnet die Seite; sie erscheint, wenn der Server den Einwurf kennt', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      expect(find.text('Home Assistant'), findsOneWidget);
      expect(find.textContaining('Werte automatisch abholen'), findsNothing); // die Zeile sagt nur "läuft" (oder Problem), der Schalter steht auf der Seite
      await zurHaSeite(tester);
    });

    testWidgets('Die Zeile "Home Assistant" steht oben (vor den Kacheln) und sagt "läuft"', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      expect(tester.getTopLeft(find.text('Home Assistant')).dy, lessThan(tester.getTopLeft(find.text('Strom Haus').first).dy));
      expect(find.textContaining('läuft'), findsOneWidget);
    });

    testWidgets('Leerer Zustand: Einstieg zum Koppeln (Admin)', (tester) async {
      await start(tester, datenAus([]));
      expect(find.text('Noch keine Zähler'), findsOneWidget);
      expect(find.textContaining('von Home Assistant liefern'), findsOneWidget);
      await tippe(tester, find.text('Mit Home Assistant verbinden'));
      expect(find.text('Neue Verbindung'), findsWidgets); // Admin: direkt zum Koppeln
    });

    testWidgets('Leerer Zustand ohne Home Assistant (Server bietet es nicht an): kein Einstieg', (tester) async {
      await start(tester, datenAus([]), verfuegbar: false);
      expect(find.text('Noch keine Zähler'), findsOneWidget);
      expect(find.text('Mit Home Assistant verbinden'), findsNothing);
    });

    testWidgets('Elternteil im leeren Zustand: der Einstieg führt zur Seite "Home Assistant", nicht zum Koppeln', (tester) async {
      await start(tester, datenAus([]), role: 'parent');
      await tippe(tester, find.text('Mit Home Assistant verbinden'));
      expect(find.text('Werte automatisch abholen'), findsOneWidget);
      expect(find.text('Neue Verbindung koppeln …'), findsNothing);
    });

    testWidgets('Gerät ohne Postfach-Schlüssel (zweites Elternteil): die Zeile sagt "läuft über ein anderes Gerät", nie "aus"', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: const IngestZustand(geladen: true), role: 'parent');
      expect(find.textContaining('läuft über ein anderes Gerät'), findsOneWidget);
      expect(find.textContaining('Abholen ist aus'), findsNothing);
    });

    testWidgets('Der Anstoß beim Öffnen ruft den Notifier (der selbst nur mit Schalter und Schlüssel abholt)', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      expect(ingest.aufrufe, contains('oeffnen'));
    });

    testWidgets('"1 Wert prüfen" steht nur auf der Zähler-Seite und führt zur Prüfliste', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: IngestZustand(geladen: true, schalter: true, postfachDa: true, zuPruefen: [pruefEintrag()]));
      expect(find.text('1 Wert prüfen'), findsOneWidget);
      await tippe(tester, find.widgetWithText(TextButton, 'Prüfen'));
      expect(find.text('Zu prüfen'), findsWidgets);
      expect(find.textContaining('liegt unter dem letzten'), findsOneWidget);
    });

    testWidgets('Automatischer Zähler ohne Wert seit mehr als 3 Tagen: "kein Wert" (nie die Aufforderung zum Ablesen) mit Weg zur Seite Home Assistant; mit frischem Wert nicht', (tester) async {
      final alt = ZaehlerBeispiel(zStrom, _haStrom().inhalt, [for (var i = 0; i < 4; i++) Stand(heuteTag().subtract(Duration(days: 10 - i)), 1000000 + 10000 * i)]);
      await start(tester, datenAus([alt]));
      expect(find.text('KEIN WERT'), findsOneWidget);
      expect(find.text('ABLESEN FÄLLIG'), findsNothing);
      expect(find.textContaining('Strom Haus: seit 7 Tagen kein Wert'), findsOneWidget);
      expect(find.textContaining('Home Assistant hat nichts geschickt'), findsOneWidget);
      expect(find.text('Ablesen'), findsNothing);
      pruefeLayout(tester, 'Kein Wert');
      await tippe(tester, find.widgetWithText(TextButton, 'Prüfen'));
      expect(find.text('Werte automatisch abholen'), findsOneWidget);
    });

    testWidgets('Ein Zähler von Hand mit abgelaufenem Rhythmus fragt weiter nach dem Ablesen, daneben die Karte für den automatischen Zähler', (tester) async {
      final alt = ZaehlerBeispiel(zStrom, _haStrom().inhalt, [for (var i = 0; i < 4; i++) Stand(heuteTag().subtract(Duration(days: 10 - i)), 1000000 + 10000 * i)]);
      final hand = ZaehlerBeispiel(zKalt1, ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Wasser Küche', ablesung: Ablesung.monatlich(1)), [Stand(heuteTag().subtract(const Duration(days: 80)), 5000)]);
      await start(tester, datenAus([alt, hand]));
      expect(find.text('KEIN WERT'), findsOneWidget);
      expect(find.text('ABLESEN FÄLLIG'), findsOneWidget);
    });

    testWidgets('Automatischer Zähler mit gestrigem Wert: nicht fällig', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      expect(find.text('ABLESEN FÄLLIG'), findsNothing);
      expect(find.text('AKTUELL'), findsOneWidget);
    });
  });

  group('Seite "Home Assistant"', () {
    testWidgets('Zustand, Schalter und "Jetzt abholen" (Admin sieht auch die Verbindungen)', (tester) async {
      await start(
        tester,
        datenAus([_haStrom()]),
        zustand: IngestZustand(
          geladen: true,
          schalter: true,
          postfachDa: true,
          letzter: IngestLauf(zeit: DateTime.now(), eingetragen: 3, wartend: 2),
          zuPruefen: [pruefEintrag()],
        ),
        verbindungen: [
          {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': DateTime.now().toUtc().toIso8601String(), 'revokedAt': null},
          {'id': 't2', 'name': 'Alt', 'createdAt': '2026-09-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': '2026-09-02T10:00:00.000Z'},
        ],
      );
      await zurHaSeite(tester);
      expect(find.textContaining('3 Werte eingetragen'), findsOneWidget);
      expect(find.text('OK'), findsOneWidget);
      expect(find.text('1 Wert wartet auf dich'), findsOneWidget);
      // die Zahlen für Technikinteressierte sind eingeklappt und ohne Fachwörter
      expect(find.text('Wartet beim Server'), findsNothing);
      await tippe(tester, find.text('Technische Details'));
      expect(find.text('Wartet beim Server'), findsOneWidget);
      expect(find.text('2 Werte'), findsOneWidget);
      expect(find.textContaining('Päckchen'), findsNothing);
      expect(find.text('Haus Keller'), findsOneWidget);
      expect(find.textContaining('Zuletzt gehört: heute'), findsOneWidget);
      expect(find.text('Alt'), findsNothing); // widerrufene Verbindungen stehen nicht in der Liste
      expect(find.text('Neue Verbindung koppeln …'), findsOneWidget);
      expect(find.text('Dieses Gerät kann nicht abholen; die Verbindung wurde auf einem anderen Gerät gekoppelt.'), findsNothing);
      pruefeLayout(tester, 'HA-Seite');
      await tippe(tester, find.text('Jetzt abholen'));
      expect(ingest.aufrufe, contains('abholen'));
      await tippe(tester, find.byType(Switch));
      expect(ingest.aufrufe, contains('schalter:false'));
    });

    testWidgets('Ohne Postfach-Schlüssel auf diesem Gerät (zweites Elternteil): ruhiger Text "Läuft über ein anderes Gerät" mit dem letzten Wert, kein Schalter, kein "aus", kein "Jetzt abholen"', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: const IngestZustand(geladen: true), role: 'parent');
      await tippe(tester, find.text('Home Assistant'));
      expect(find.text('Läuft über ein anderes Gerät'), findsOneWidget);
      expect(find.textContaining('Letzter Wert: Strom Haus'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Werte automatisch abholen'), findsNothing);
      expect(find.text('Jetzt abholen'), findsNothing);
      expect(find.text('aus'), findsNothing);
      expect(find.textContaining('unbekannt'), findsNothing);
      pruefeLayout(tester, 'HA-Seite ohne Schlüssel');
    });

    testWidgets('Zustand nach Handlungen geordnet: Zu prüfen und "Noch kein Zähler zugeordnet" stehen über der letzten Abholung; "für ein anderes Gerät" und "unlesbar" nur in den Details', (tester) async {
      await start(
        tester,
        datenAus([_haStrom()]),
        zustand: IngestZustand(geladen: true, schalter: true, postfachDa: true, letzter: IngestLauf(zeit: DateTime.now(), eingetragen: 1, wartend: 5, ungueltig: 1, fremd: 2, ohneZaehler: 1), zuPruefen: [pruefEintrag()]),
      );
      await zurHaSeite(tester);
      final pruefen = tester.getTopLeft(find.text('Zu prüfen')).dy;
      final zuordnen = tester.getTopLeft(find.text('Noch kein Zähler zugeordnet')).dy;
      final abholung = tester.getTopLeft(find.text('Letzte Abholung')).dy;
      expect(pruefen, lessThan(zuordnen));
      expect(zuordnen, lessThan(abholung));
      expect(find.text('Für ein anderes Gerät'), findsNothing);
      await tippe(tester, find.text('Technische Details'));
      expect(find.text('Für ein anderes Gerät'), findsOneWidget);
      expect(find.textContaining('2 Werte kann nur ein anderes Gerät oder eine neuere App öffnen'), findsOneWidget);
      expect(find.text('Unlesbar entfernt'), findsOneWidget);
      // "Zuordnen" führt zur Zuordnung der Zähler
      await tippe(tester, find.text('Noch kein Zähler zugeordnet'));
      expect(find.text('Zähler zuordnen'), findsOneWidget);
      expect(find.text('Strom Bezug'), findsOneWidget);
    });

    testWidgets('Schalter aus, aber Postfach-Schlüssel da (zum Beispiel nach dem Abmelden): ruhiger Hinweis mit dem Knopf "Einschalten", der den Schalter setzt; bei eingeschaltetem Schalter fehlt er', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: const IngestZustand(geladen: true, postfachDa: true));
      await zurHaSeite(tester);
      expect(find.text('Dieses Gerät holt gerade nichts ab'), findsOneWidget);
      pruefeLayout(tester, 'HA-Seite mit Hinweis Einschalten');
      await tippe(tester, find.widgetWithText(FilledButton, 'Einschalten'));
      expect(ingest.aufrufe, contains('schalter:true'));
      expect(find.text('Dieses Gerät holt gerade nichts ab'), findsNothing);
    });

    testWidgets('Der Hinweis "Einschalten" fehlt auf einem Gerät ohne Schlüssel und solange noch nichts gelesen ist', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: const IngestZustand(geladen: true), role: 'parent');
      await tippe(tester, find.text('Home Assistant'));
      expect(find.text('Dieses Gerät holt gerade nichts ab'), findsNothing);
    });

    testWidgets('Doppelt belegter Kanal (zwei Abholgeräte schreiben denselben Tag): die Seite meldet es mit Zähler und Kanal', (tester) async {
      final tag = heuteTag().subtract(const Duration(days: 1));
      final doppelt = ZaehlerBeispiel(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus', quelle: const ZaehlerQuelle(kanal: 'strom_bezug')), [Stand(tag, 2951000), Stand(tag, 2951000)]);
      await start(tester, datenAus([doppelt]));
      await zurHaSeite(tester);
      expect(find.text('Werte kommen doppelt an'), findsOneWidget);
      expect(find.textContaining('„Strom Haus“ liefern mehrere Verbindungen oder Geräte denselben Kanal (Strom Bezug)'), findsOneWidget);
      expect(find.text('DOPPELT'), findsOneWidget);
      pruefeLayout(tester, 'HA-Seite doppelt');
    });

    testWidgets('Ohne doppelte Tage kein Hinweis "doppelt"', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      await zurHaSeite(tester);
      expect(find.text('Werte kommen doppelt an'), findsNothing);
    });

    testWidgets('Werte ohne Zähler, die bald gelöscht werden (älter als 25 Tage): die Zeile sagt, in wie vielen Tagen; ohne Alter kein Hinweis', (tester) async {
      await start(
        tester,
        datenAus([_haStrom()]),
        zustand: IngestZustand(geladen: true, schalter: true, postfachDa: true, letzter: IngestLauf(zeit: DateTime.now(), wartend: 2, ohneZaehler: 2, aeltestOhneZaehler: DateTime.now().subtract(const Duration(days: 27, hours: 1)))),
      );
      await zurHaSeite(tester);
      expect(find.textContaining('Wird in 3 Tagen vom Server gelöscht'), findsOneWidget);
    });

    testWidgets('Werte ohne Zähler ohne bekanntes Alter: kein Löschhinweis', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: IngestZustand(geladen: true, schalter: true, postfachDa: true, letzter: IngestLauf(zeit: DateTime.now(), wartend: 1, ohneZaehler: 1)));
      await zurHaSeite(tester);
      expect(find.textContaining('vom Server gelöscht'), findsNothing);
    });

    testWidgets('Fehler des letzten Laufs: fester Text, nie ein Servertext', (tester) async {
      await start(tester, datenAus([_haStrom()]), zustand: IngestZustand(geladen: true, schalter: true, postfachDa: true, letzter: IngestLauf(zeit: DateTime.now(), abbruch: IngestAbbruch.netz)));
      await zurHaSeite(tester);
      expect(find.text('FEHLER'), findsOneWidget);
      expect(find.textContaining('Der Server ist gerade nicht erreichbar'), findsOneWidget);
    });

    testWidgets('Elternteil (kein Admin): keine Verbindungsliste, kein Koppeln', (tester) async {
      await start(tester, datenAus([_haStrom()]), role: 'parent');
      await zurHaSeite(tester);
      expect(find.text('Neue Verbindung koppeln …'), findsNothing);
      expect(find.textContaining('// verbindung'), findsNothing);
      expect(find.textContaining('VERBINDUNG (NUR ADMIN)'), findsNothing);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Layout bei 360 px und Textskala $skala (Seite, Prüfliste, Koppeln)', (tester) async {
        await start(
          tester,
          datenAus([_haStrom()]),
          skala: skala,
          zustand: IngestZustand(geladen: true, schalter: true, postfachDa: true, letzter: IngestLauf(zeit: DateTime.now(), eingetragen: 3, wartend: 2, ungueltig: 1, ohneZaehler: 1), zuPruefen: [pruefEintrag(), pruefEintrag(id: 'p2', grund: PruefGrund.sprung)]),
          verbindungen: [
            {'id': 't1', 'name': 'Haus Keller mit langem Namen', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
          ],
        );
        await zurHaSeite(tester);
        pruefeLayout(tester, 'HA-Seite');
        await tippe(tester, find.text('Technische Details'));
        pruefeLayout(tester, 'HA-Seite mit Details');
        await tippe(tester, find.text('Neue Verbindung koppeln …'));
        expect(find.text('Neue Verbindung'), findsWidgets);
        pruefeLayout(tester, 'Koppeln');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippe(tester, find.text('Noch kein Zähler zugeordnet'));
        pruefeLayout(tester, 'Zuordnen');
        await tippe(tester, find.byTooltip('Zurück'));
        await tippe(tester, find.textContaining('Werte warten auf dich'));
        pruefeLayout(tester, 'Prüfliste');
      });
    }
  });

  group('Verbindung trennen', () {
    testWidgets('Letzte Verbindung: Token widerrufen, danach auf Nachfrage den Schlüssel dieses Geräts löschen und abschalten', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      await speicher.schreiben(postfachName(fixIdAdmin), Uint8List(96));
      env.server.on('DELETE /ingest/tokens/t1', (_) {
        tokens = [for (final t in tokens) {...t, 'revokedAt': '2026-10-24T10:00:00.000Z'}];
        return jsonAntwort({'ok': true});
      });
      await zurHaSeite(tester);
      await tippe(tester, find.bySemanticsLabel('Verbindung Haus Keller trennen'));
      expect(find.text('Verbindung trennen?'), findsOneWidget);
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Trennen')));
      expect(env.server.anfragen('DELETE /ingest/tokens/t1'), hasLength(1));
      expect(find.text('Schlüssel dieser Verbindung löschen?'), findsOneWidget);
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Löschen')));
      expect(await speicher.lesen(postfachName(fixIdAdmin)), isNull);
      expect(ingest.aufrufe, contains('schalter:false'));
      expect(find.text('Haus Keller'), findsNothing);
    });

    testWidgets('Bleiben andere Verbindungen, behält das Gerät den Schlüssel (sie brauchen ihn)', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
        {'id': 't2', 'name': 'Ferienhaus', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      await speicher.schreiben(postfachName(fixIdAdmin), Uint8List(96));
      env.server.on('DELETE /ingest/tokens/t1', (_) {
        tokens = [for (final t in tokens) if (t['id'] == 't1') {...t, 'revokedAt': '2026-10-24T10:00:00.000Z'} else t];
        return jsonAntwort({'ok': true});
      });
      await zurHaSeite(tester);
      await tippe(tester, find.bySemanticsLabel('Verbindung Haus Keller trennen'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Trennen')));
      expect(find.text('Schlüssel dieser Verbindung löschen?'), findsNothing);
      expect(await speicher.lesen(postfachName(fixIdAdmin)), isNotNull);
      expect(find.text('Ferienhaus'), findsOneWidget);
    });

    testWidgets('Letzte Verbindung: vor der Rückfrage ein letzter Abholvorgang; der Dialog sagt, dass noch nicht abgeholte Werte danach unlesbar sind', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      await PostfachSpeicher(speicher).schreiben(fixIdAdmin, PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 3)));
      env.server.on('GET /ingest/zaehler/pending', (_) => jsonAntwort({'items': <Object>[], 'next': null}));
      env.server.on('DELETE /ingest/tokens/t1', (_) {
        tokens = [for (final t in tokens) {...t, 'revokedAt': '2026-10-24T10:00:00.000Z'}];
        return jsonAntwort({'ok': true});
      });
      await zurHaSeite(tester);
      await tippe(tester, find.bySemanticsLabel('Verbindung Haus Keller trennen'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Trennen')));
      expect(env.server.anfragen('GET /ingest/zaehler/pending'), hasLength(1)); // der letzte Abholvorgang, nach dem Widerruf und vor der Rückfrage
      expect(find.text('Schlüssel dieser Verbindung löschen?'), findsOneWidget);
      expect(find.textContaining('Noch nicht abgeholte Werte lassen sich danach nicht mehr öffnen und gehen verloren.'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(await PostfachSpeicher(speicher).vorhanden(fixIdAdmin), isTrue); // Abbrechen löscht nichts
    });

    testWidgets('Scheitert der letzte Abholvorgang (Serverfehler), kommt die Rückfrage trotzdem', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      await PostfachSpeicher(speicher).schreiben(fixIdAdmin, PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 3)));
      env.server.on('GET /ingest/zaehler/pending', (_) => fehler(500, 'internal_error'));
      env.server.on('DELETE /ingest/tokens/t1', (_) {
        tokens = [for (final t in tokens) {...t, 'revokedAt': '2026-10-24T10:00:00.000Z'}];
        return jsonAntwort({'ok': true});
      });
      await zurHaSeite(tester);
      await tippe(tester, find.bySemanticsLabel('Verbindung Haus Keller trennen'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Trennen')));
      expect(find.text('Schlüssel dieser Verbindung löschen?'), findsOneWidget);
      expect(find.textContaining('Beim Server warten noch'), findsNothing);
      await tippe(tester, find.text('Abbrechen'));
    });

    testWidgets('Abbrechen der Rückfrage ändert nichts', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      await zurHaSeite(tester);
      await tippe(tester, find.bySemanticsLabel('Verbindung Haus Keller trennen'));
      await tippe(tester, find.text('Abbrechen'));
      expect(env.server.anfragen('DELETE /ingest/tokens/t1'), isEmpty);
    });
  });

  group('Verbindung koppeln', () {
    testWidgets('Token anlegen, Schlüssel nur im Schlüsselspeicher, Anleitung mit echtem Pfad, Kopieren als Hauptweg, QR und Text nur auf Wunsch; Rückfrage vor dem Weitergehen; der Code passt zum Schlüssel', (tester) async {
      final zwischen = <String>[];
      var inhalt = '';
      var geleert = 0;
      await start(
        tester,
        datenAus([_haStrom()]),
        mehr: [
          ingestZwischenablageProvider.overrideWith((ref) {
            final z = TresorZwischenablage(
              setzen: (t, g) async {
                inhalt = t;
                zwischen.add(t);
              },
              lesen: () async => inhalt,
              leeren: () async {
                inhalt = '';
                geleert++;
              },
              frist: kIngestZwischenablageFrist,
            );
            ref.onDispose(z.verwerfen);
            return z;
          }),
        ],
      );
      env.server.on('POST /ingest/tokens', (req) => jsonAntwort({'token': _token, 'id': 't9', 'name': req.json['name'], 'createdAt': '2026-10-24T10:00:00.000Z'}));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      expect(find.text('// SCHRITT 1 VON 3'), findsOneWidget);
      await eingeben(tester, 'Name der Verbindung (zum Beispiel Haus Keller)', 'Haus Keller');
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(env.server.anfragen('POST /ingest/tokens').single.json, {'name': 'Haus Keller'});
      expect(find.text('Code in Home Assistant einfügen'), findsOneWidget);
      expect(find.text('// SCHRITT 2 VON 3'), findsOneWidget);
      // die Anleitung nennt den echten Pfad in Home Assistant; von einem QR-Scan in Home Assistant ist keine Rede
      expect(find.textContaining('Einstellungen › Geräte & Dienste › Integration hinzufügen › Familyhub'), findsOneWidget);
      expect(find.textContaining('Scanne den QR-Code in Home Assistant'), findsNothing);
      expect(find.textContaining('Die Zwischenablage wird nach 60 Sekunden geleert'), findsOneWidget);
      // QR und Text sind zugeklappt, der Code steht noch nicht im Widgetbaum
      expect(find.byType(SelectableText), findsNothing);
      expect(ingest.aufrufe, contains('schalter:true'));
      pruefeLayout(tester, 'Kopplungscode');
      // Kopieren (Hauptweg): der Code liegt in der Zwischenablage und ist ein Kopplungscode
      await tippe(tester, find.text('Code kopieren'));
      expect(zwischen, hasLength(1));
      expect(zwischen.single, startsWith('FH1-'));
      expect(find.text('Kopiert'), findsOneWidget);
      // nach 60 Sekunden leert die App die Zwischenablage, aber nur, wenn noch derselbe Text darin steht
      await tester.pump(const Duration(seconds: 59));
      expect(geleert, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(geleert, 1);
      expect(inhalt, '');
      // QR und Text als Zusatz
      await tippe(tester, find.textContaining('QR-Code zeigen'));
      final textFeld = find.byType(SelectableText);
      expect(textFeld, findsOneWidget);
      final code = tester.widget<SelectableText>(textFeld).data!;
      expect(code, zwischen.single);
      final k = kopplungscodeLesen(code)!;
      expect(k.token, _token);
      expect(k.name, 'Haus Keller');
      // der geheime Schlüssel liegt nur im Schlüsselspeicher, der öffentliche steht im Code
      final s = (await PostfachSpeicher(speicher).lesen(fixIdAdmin))!;
      expect(k.postfach, s.oeffentlich);
      expect(k.geheimnis, s.geheimnis);
      expect(await PostfachSpeicher(speicher).verbindungen(fixIdAdmin), ['t9']); // dieses Gerät holt nur die Päckchen seiner eigenen Verbindungen
      // nichts davon ging zum Server
      final gesendet = jsonEncode(env.server.log.map((r) => r.body.toString()).toList());
      expect(gesendet, isNot(contains(base64.encode(s.geheim))));
      expect(gesendet, isNot(contains(base64.encode(s.geheimnis))));
      expect(find.byTooltip('Zurück'), findsNothing); // der Code verschwindet nicht versehentlich
      // Rückfrage vor dem Weitergehen: "Noch nicht" lässt alles stehen
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter: Zähler zuordnen'));
      expect(find.text('Hast du den Code in Home Assistant eingegeben?'), findsOneWidget);
      await tippe(tester, find.text('Noch nicht'));
      expect(find.text('Code in Home Assistant einfügen'), findsOneWidget);
      // "Ja": der Code ist weg, Schritt 3 beginnt mit dem Hinweis auf den ersten Wert nach Mitternacht
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter: Zähler zuordnen'));
      await tippe(tester, find.text('Ja, eingegeben'));
      expect(find.text('Code in Home Assistant einfügen'), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Fast geschafft'), findsOneWidget);
      expect(find.text('// SCHRITT 3 VON 3'), findsOneWidget);
      expect(find.textContaining('erst nach der nächsten Mitternacht'), findsOneWidget);
      pruefeLayout(tester, 'Zähler zuordnen');
    });

    testWidgets('"Es klappt nicht?": Hilfe mit möglichen Gründen; "Seite schließen" verwirft den Code', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      env.server.on('POST /ingest/tokens', (req) => jsonAntwort({'token': _token, 'id': 't9', 'name': req.json['name'], 'createdAt': '2026-10-24T10:00:00.000Z'}));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      await tippe(tester, find.text('Es klappt nicht?'));
      expect(find.textContaining('Prüfe, ob die Integration „Familyhub“'), findsOneWidget);
      await tippe(tester, find.text('Zurück zum Code'));
      expect(find.text('Code in Home Assistant einfügen'), findsOneWidget);
      await tippe(tester, find.text('Es klappt nicht?'));
      await tippe(tester, find.text('Seite schließen'));
      expect(find.text('Code in Home Assistant einfügen'), findsNothing);
      expect(find.text('Werte automatisch abholen'), findsOneWidget);
    });

    testWidgets('Es gibt schon eine Verbindung auf einem anderen Gerät: Hinweis vor dem Koppeln (Gerät ohne Postfach)', (tester) async {
      await start(
        tester,
        datenAus([_haStrom()]),
        zustand: const IngestZustand(geladen: true),
        verbindungen: [
          {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
        ],
      );
      await tippe(tester, find.text('Home Assistant'));
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      expect(find.text('Es gibt schon eine Verbindung auf einem anderen Gerät'), findsOneWidget);
      expect(find.textContaining('„Haus Keller“ wurde auf einem anderen Gerät gekoppelt'), findsOneWidget);
      pruefeLayout(tester, 'Hinweis Abholgerät');
    });

    testWidgets('Kein Hinweis, wenn die Verbindung von diesem Gerät stammt (gemerkte Kennung)', (tester) async {
      await start(
        tester,
        datenAus([_haStrom()]),
        verbindungen: [
          {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
        ],
      );
      await PostfachSpeicher(speicher).schreiben(fixIdAdmin, PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 5)));
      await PostfachSpeicher(speicher).verbindungMerken(fixIdAdmin, 't1');
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      expect(find.text('Es gibt schon eine Verbindung auf einem anderen Gerät'), findsNothing);
    });

    testWidgets('Hat das Gerät schon ein Postfach, wird es weiterverwendet (alle Verbindungen teilen es)', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Alt', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      env.server.on('POST /ingest/tokens', (req) => jsonAntwort({'token': _token, 'id': 't9', 'name': req.json['name'], 'createdAt': '2026-10-24T10:00:00.000Z'}));
      final vorhanden = PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 99));
      await PostfachSpeicher(speicher).schreiben(fixIdAdmin, vorhanden);
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      await tippe(tester, find.textContaining('QR-Code zeigen'));
      final k = kopplungscodeLesen(tester.widget<SelectableText>(find.byType(SelectableText)).data!)!;
      expect(k.postfach, vorhanden.oeffentlich);
      expect(k.geheimnis, vorhanden.geheimnis);
      // ein Gerät aus der Zeit vor der Merkliste: seine bisherigen Verbindungen werden mit der neuen zusammen festgehalten, damit es keine verliert
      expect(await PostfachSpeicher(speicher).verbindungen(fixIdAdmin), ['t1', 't9']);
    });

    testWidgets('Schlägt das Anlegen fehl: kein Code, ein eben erst erzeugter Schlüssel wird wieder entfernt, deutsche Meldung', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      env.server.on('POST /ingest/tokens', (_) => fehler(409, 'token_limit'));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(find.text('Code in Home Assistant einfügen'), findsNothing);
      expect(find.textContaining('höchste Zahl an Verbindungen'), findsOneWidget);
      expect(await speicher.lesen(postfachName(fixIdAdmin)), isNull);
      expect(ingest.aufrufe, isNot(contains('schalter:true')));
    });

    testWidgets('Fehlt nach dem Anlegen etwas (Merkliste nicht schreibbar): das Token wird widerrufen und der eben erzeugte Schlüssel entfernt, kein Code, deutsche Meldung', (tester) async {
      final kaputt = _MerklisteKaputt(fixIdAdmin);
      await start(tester, datenAus([_haStrom()]), speicherAlt: kaputt);
      env.server.on('POST /ingest/tokens', (req) => jsonAntwort({'token': _token, 'id': 't9', 'name': req.json['name'], 'createdAt': '2026-10-24T10:00:00.000Z'}));
      env.server.on('DELETE /ingest/tokens/t9', (_) => jsonAntwort({'ok': true}));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(env.server.anfragen('POST /ingest/tokens'), hasLength(1));
      expect(env.server.anfragen('DELETE /ingest/tokens/t9'), hasLength(1));
      expect(find.text('Code in Home Assistant einfügen'), findsNothing);
      expect(find.textContaining('Die neue Verbindung wurde wieder entfernt'), findsOneWidget);
      expect(await kaputt.lesen(postfachName(fixIdAdmin)), isNull);
      expect(ingest.aufrufe, isNot(contains('schalter:true')));
    });

    testWidgets('Lässt sich das Token nicht widerrufen, behält das Gerät den Schlüssel (die Verbindung lebt) und sagt, was zu tun ist', (tester) async {
      final kaputt = _MerklisteKaputt(fixIdAdmin);
      await start(tester, datenAus([_haStrom()]), speicherAlt: kaputt);
      env.server.on('POST /ingest/tokens', (req) => jsonAntwort({'token': _token, 'id': 't9', 'name': req.json['name'], 'createdAt': '2026-10-24T10:00:00.000Z'}));
      env.server.on('DELETE /ingest/tokens/t9', (_) => fehler(500, 'internal_error'));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(env.server.anfragen('DELETE /ingest/tokens/t9'), isNotEmpty);
      expect(find.textContaining('Trenne sie in der Liste'), findsOneWidget);
      expect(await kaputt.lesen(postfachName(fixIdAdmin)), isNotNull);
    });

    testWidgets('Eine unbrauchbare Serveradresse fällt VOR dem Anlegen auf: es entsteht kein Token', (tester) async {
      await start(tester, datenAus([_haStrom()]), mehr: [ingestServerAdresseProvider.overrideWithValue('https://familie.test/pfad')]);
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(env.server.anfragen('POST /ingest/tokens'), isEmpty);
      expect(find.textContaining('Der Kopplungscode ließ sich nicht erzeugen'), findsOneWidget);
      expect(await speicher.lesen(postfachName(fixIdAdmin)), isNull);
    });

    testWidgets('Step-up abgebrochen: nichts angelegt, der neue Schlüssel wieder weg', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      env.server.on('POST /ingest/tokens', (_) => fehler(403, 'step_up_required'));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(find.text('Bitte bestätigen'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(find.text('Code in Home Assistant einfügen'), findsNothing);
      expect(await speicher.lesen(postfachName(fixIdAdmin)), isNull);
    });

    testWidgets('Name ist Pflicht', (tester) async {
      await start(tester, datenAus([_haStrom()]));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Neue Verbindung koppeln …'));
      await eingeben(tester, 'Name der Verbindung (zum Beispiel Haus Keller)', '   ');
      await tippe(tester, find.widgetWithText(FilledButton, 'Weiter'));
      expect(find.textContaining('Gib der Verbindung einen Namen'), findsOneWidget);
      expect(env.server.anfragen('POST /ingest/tokens'), isEmpty);
    });
  });

  group('Prüfliste', () {
    Future<void> hin(WidgetTester tester, List<IngestPruefEintrag> l, {TestIngest Function(IngestZustand)? bauer}) async {
      final z = IngestZustand(geladen: true, schalter: true, postfachDa: true, zuPruefen: l);
      await start(tester, datenAus([_haStrom()]), zustand: z, ingestAlt: bauer?.call(z));
      await tippe(tester, find.widgetWithText(TextButton, 'Prüfen'));
    }

    testWidgets('Texte je Grund mit Kontext und Antworten; "Wert verwerfen" und "Wert stimmt, trotzdem eintragen" rufen den Notifier und entfernen den Eintrag', (tester) async {
      await hin(tester, [pruefEintrag(), pruefEintrag(id: 'p2', grund: PruefGrund.sprung, milli: 3100000)]);
      expect(find.textContaining('Strom Haus · 24.10.'), findsNWidgets(2));
      expect(find.textContaining('Neuer Stand 12,4 kWh liegt unter dem letzten (2.951,7 kWh)'), findsOneWidget);
      expect(find.text('Der neue Wert ist kleiner. Was ist passiert?'), findsOneWidget);
      expect(find.text('Davor: 2.951,7 kWh'), findsNWidgets(2));
      expect(find.text('Neu: 12,4 kWh'), findsOneWidget);
      expect(find.textContaining('Sprung um +86 kWh an einem Tag (üblich: 1,5 kWh)'), findsOneWidget);
      expect(find.text('Der Verbrauch ist an diesem Tag ungewöhnlich hoch. Stimmt der Wert?'), findsOneWidget);
      // Antworten statt Befehle; kein Knopf ist als "Hauptknopf" hervorgehoben (der Zählerwechsel ist bei einem zurückgesetzten Sensor die riskanteste Wahl)
      expect(find.widgetWithText(FilledButton, 'Der Zähler wurde getauscht'), findsNothing);
      expect(find.text('Home Assistant wurde zurückgesetzt – Wert verwerfen'), findsOneWidget);
      pruefeLayout(tester, 'Prüfliste');
      await tippe(tester, find.text('Home Assistant wurde zurückgesetzt – Wert verwerfen'));
      expect(ingest.aufrufe, ['oeffnen', 'verwerfen:p1']);
      expect(find.textContaining('Neuer Stand 12,4'), findsNothing);
      await tippe(tester, find.text('Wert stimmt, trotzdem eintragen'));
      expect(ingest.aufrufe.last, 'eintragen:p2');
      expect(find.text('Nichts zu prüfen'), findsOneWidget);
    });

    testWidgets('Der Ladekreis dreht sich nur am gedrückten Knopf; alle anderen sind solange gesperrt', (tester) async {
      late _Haengt haengt;
      await hin(tester, [pruefEintrag(), pruefEintrag(id: 'p2')], bauer: (z) => haengt = _Haengt(z));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final verwerfen = find.text('Home Assistant wurde zurückgesetzt – Wert verwerfen');
      await tester.ensureVisible(verwerfen.first);
      await tester.tap(verwerfen.first);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // der Ladekreis sitzt im Knopf "Verwerfen" (an dessen Stelle der Text fehlt), nicht in einem der anderen Knöpfe
      for (final k in tester.widgetList<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Wert stimmt, trotzdem eintragen'))) {
        expect(k.onPressed, isNull);
      }
      expect(find.widgetWithText(OutlinedButton, 'Wert stimmt, trotzdem eintragen'), findsNWidgets(2));
      expect(find.descendant(of: find.byType(OutlinedButton), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      haengt.tor.complete();
      await warte(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('"Der Zähler wurde getauscht" öffnet den Dialog "Zähler wechseln" mit dem Wert als Startstand; nach dem Wechsel ist das Päckchen erledigt', (tester) async {
      await hin(tester, [pruefEintrag()]);
      await tippe(tester, find.text('Der Zähler wurde getauscht'));
      expect(find.text('Zähler wechseln'), findsOneWidget);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Startstand des neuen Zählers in kWh')).controller!.text, '12,4');
      await eingeben(tester, 'Endstand des alten Zählers in kWh', '3000');
      await tippe(tester, find.widgetWithText(FilledButton, 'Wechseln'));
      expect(repo.wechsel.single.id, zStrom);
      expect(repo.wechsel.single.ende, 3000000);
      expect(repo.wechsel.single.start, 12400);
      expect(ingest.aufrufe.last, 'erledigt:p1');
    });

    testWidgets('Abbrechen im Wechsel-Dialog lässt den Wert in der Liste', (tester) async {
      await hin(tester, [pruefEintrag()]);
      await tippe(tester, find.text('Der Zähler wurde getauscht'));
      await tippe(tester, find.text('Abbrechen'));
      expect(repo.wechsel, isEmpty);
      expect(ingest.aufrufe, isNot(contains('erledigt:p1')));
      expect(find.textContaining('Neuer Stand 12,4'), findsOneWidget);
    });
    testWidgets('Unlesbarer Stand (mehr als 10 Stellen): erklärt, nur "Wert verwerfen" als Antwort (nie Eintragen oder Zählerwechsel), die Entscheidung geht an den Notifier', (tester) async {
      await hin(tester, [pruefEintrag(grund: PruefGrund.ungueltig, milli: 0, standText: '12345678901234')]);
      expect(find.textContaining('keine gültige Zahl ist ("12345678901234")'), findsOneWidget);
      expect(find.textContaining('Der Wert bleibt beim Server, bis du ihn verwirfst'), findsOneWidget);
      expect(find.text('Wert stimmt, trotzdem eintragen'), findsNothing);
      expect(find.text('Der Zähler wurde getauscht'), findsNothing);
      expect(find.text('Davor: 2.951,7 kWh'), findsNothing);
      pruefeLayout(tester, 'Prüfliste ungültig');
      await tippe(tester, find.text('Wert verwerfen'));
      expect(ingest.aufrufe.last, 'verwerfen:p1');
      expect(find.text('Nichts zu prüfen'), findsOneWidget);
    });

    testWidgets('Ein Wert, der seit 25 Tagen oder länger beim Server wartet, zeigt "Wird in x Tagen vom Server gelöscht"; ein frischer nicht', (tester) async {
      await hin(tester, [
        pruefEintrag(empfangen: DateTime.now().subtract(const Duration(days: 28, hours: 2))),
        pruefEintrag(id: 'p2', empfangen: DateTime.now().subtract(const Duration(days: 2))),
        pruefEintrag(id: 'p3'),
      ]);
      expect(find.text('Wird in 2 Tagen vom Server gelöscht'), findsOneWidget);
      expect(find.textContaining('vom Server gelöscht'), findsOneWidget);
    });

  });

  group('Zähler-Editor: Abschnitt "Quelle"', () {
    testWidgets('Home Assistant wählen: Kanal, "Prüfen vor dem Eintragen", kein Rhythmus; gespeichert wird die Quelle mit Eingabeart Zählerstand', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      expect(find.text('// QUELLE'), findsOneWidget);
      expect(find.text('Von Hand'), findsOneWidget);
      expect(find.text('Strom Bezug'), findsNothing); // Kanäle erst nach der Wahl
      await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
      expect(find.text('Strom Bezug'), findsOneWidget);
      expect(find.text('Strom Einspeisung'), findsOneWidget);
      expect(find.text('Solar Erzeugung'), findsOneWidget);
      expect(find.text('Prüfen vor dem Eintragen'), findsOneWidget);
      expect(find.textContaining('Entfällt bei automatischer Quelle'), findsOneWidget);
      expect(find.text('Kein Rhythmus'), findsNothing);
      expect(find.text('Monatswerte'), findsNothing); // Eingabeart ist fest
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Strom Haus');
      await tippe(tester, find.text('Strom Bezug'));
      pruefeLayout(tester, 'Editor mit Quelle');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      final z = repo.angelegt.single;
      expect(z.quelle, const ZaehlerQuelle(kanal: 'strom_bezug', pruefen: true));
      expect(z.modus, ZaehlerModus.stand);
      expect(z.ablesung, isNull);
    });

    testWidgets('Der Kanal ist vorbelegt (Strom: Bezug); ein eigener Name steht eingeklappt für Fortgeschrittene, ein ungültiger lässt sich nicht speichern; "Prüfen" ausschalten wird gespeichert', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
      expect(find.widgetWithText(TextField, 'Kanal (Name, den Home Assistant mitschickt)'), findsNothing); // eingeklappt
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Strom Haus');
      await tippe(tester, find.text('Eigener Name (für Fortgeschrittene)'));
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Kanal (Name, den Home Assistant mitschickt)')).controller!.text, 'strom_bezug');
      await eingeben(tester, 'Kanal (Name, den Home Assistant mitschickt)', 'Ungültig!');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt, isEmpty);
      expect(find.textContaining('Wähle den Kanal von Home Assistant'), findsOneWidget);
      await eingeben(tester, 'Kanal (Name, den Home Assistant mitschickt)', 'gas_bezug');
      await tippe(tester, find.widgetWithText(SwitchListTile, 'Prüfen vor dem Eintragen'));
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.quelle, const ZaehlerQuelle(kanal: 'gas_bezug', pruefen: false));
    });

    testWidgets('Ohne weitere Eingabe gilt der vorbelegte Kanal; der Schalter beschreibt, was wirklich geprüft wird (auch "höher als ein späterer Stand")', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
      expect(find.textContaining('kleiner ist als der davor oder höher als ein späterer, wird immer vorgelegt'), findsOneWidget);
      expect(find.textContaining('plötzlichen großen Sprung'), findsOneWidget);
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Strom Haus');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.quelle, const ZaehlerQuelle(kanal: 'strom_bezug', pruefen: true));
    });

    testWidgets('Quelle "Home Assistant" nur für Strom und Solar: bei Wasser fehlt der Abschnitt, der Wechsel der Art nimmt eine gewählte Quelle zurück', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      expect(find.text('// QUELLE'), findsOneWidget); // Standardart Strom
      await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
      expect(find.text('Strom Bezug'), findsOneWidget);
      await tippe(tester, find.text('Kaltwasser · m³'));
      expect(find.text('// QUELLE'), findsNothing);
      expect(find.text('Strom Bezug'), findsNothing);
      await tippe(tester, find.text('Gas · m³'));
      expect(find.text('// QUELLE'), findsNothing);
      await eingeben(tester, 'Name (zum Beispiel Strom Haus)', 'Gas Haus');
      await tippe(tester, find.widgetWithText(FilledButton, 'Speichern'));
      expect(repo.angelegt.single.quelle, isNull);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('Zähler mit älterer Fehlkonfiguration (Wasser mit Quelle): Warnung, Speichern erst nach "Von Hand"', (tester) async {
      final falsch = ZaehlerBeispiel(zKalt1, ZaehlerInhalt(art: ZaehlerArt.kaltwasser, name: 'Wasser Küche', quelle: const ZaehlerQuelle(kanal: 'strom_bezug')), const []);
      await start(tester, datenAus([falsch]), verfuegbar: false);
      await tippe(tester, find.bySemanticsLabel(RegExp(r'^Wasser Küche')));
      await tippe(tester, find.text('Zähler bearbeiten').first);
      expect(find.text('// QUELLE'), findsOneWidget);
      expect(find.textContaining('Home Assistant liefert bisher nur Strom und Solar'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Änderungen speichern'));
      expect(repo.geaendert, isEmpty);
      expect(find.textContaining('Home Assistant liefert nur Strom und Solar'), findsOneWidget);
      await tippe(tester, find.widgetWithText(Semantics, 'Von Hand').first);
      await tippe(tester, find.widgetWithText(FilledButton, 'Änderungen speichern'));
      expect(repo.geaendert.single.inhalt.quelle, isNull);
    });

    testWidgets('Noch keine Verbindung? Der Link im Editor führt zur Seite Home Assistant', (tester) async {
      await start(tester, datenAus([_handWasser()]));
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
      await tippe(tester, find.text('Mit Home Assistant verbinden ›'));
      expect(find.text('Werte automatisch abholen'), findsOneWidget);
    });

    testWidgets('Ein vorhandener automatischer Zähler zeigt seine Quelle; "Von Hand" entfernt sie', (tester) async {
      await start(tester, datenAus([_haStrom(kanal: 'solar_erzeugung', pruefen: false)]), verfuegbar: false);
      await tippe(tester, find.bySemanticsLabel(RegExp(r'^Strom Haus\.')));
      await tippe(tester, find.text('Zähler bearbeiten').first);
      expect(find.text('// QUELLE'), findsOneWidget); // auch ohne Antwort des Servers: der Zähler hat eine Quelle
      expect(find.text('Solar Erzeugung'), findsOneWidget);
      await tippe(tester, find.widgetWithText(Semantics, 'Von Hand').first);
      await tippe(tester, find.widgetWithText(FilledButton, 'Änderungen speichern'));
      expect(repo.geaendert.single.inhalt.quelle, isNull);
    });

    testWidgets('Server ohne Einwurf und Zähler ohne Quelle: der Abschnitt fehlt ganz', (tester) async {
      await start(tester, datenAus([_handWasser()]), verfuegbar: false);
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      expect(find.text('// QUELLE'), findsNothing);
    });

    testWidgets('Doppelter Kanal: Warnung mit dem Namen des anderen Zählers', (tester) async {
      await start(tester, datenAus([_haStrom(kanal: 'strom_bezug')]));
      await tippe(tester, find.byTooltip('Zähler hinzufügen'));
      await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
      await tippe(tester, find.text('Strom Bezug'));
      expect(find.textContaining('gehört schon zu „Strom Haus“'), findsOneWidget);
    });

    for (final skala in [1.5, 2.0]) {
      testWidgets('Editor mit Quelle bei 360 px und Textskala $skala', (tester) async {
        await start(tester, datenAus([_handWasser()]), skala: skala);
        await tippe(tester, find.byTooltip('Zähler hinzufügen'));
        await tippe(tester, find.widgetWithText(Semantics, 'Home Assistant').first);
        pruefeLayout(tester, 'Editor');
      });
    }
  });

  group('Zähler zuordnen', () {
    ZaehlerBeispiel stromOhne() => ZaehlerBeispiel(zStrom, ZaehlerInhalt(art: ZaehlerArt.strom, name: 'Strom Haus'), [Stand(heuteTag().subtract(const Duration(days: 1)), 2951000)]);
    ZaehlerBeispiel solarOhne() => ZaehlerBeispiel(zSolar, ZaehlerInhalt(art: ZaehlerArt.erzeugung, name: 'Solar Dach'), [Stand(heuteTag().subtract(const Duration(days: 1)), 1204000)]);

    Future<void> hinZurZuordnung(WidgetTester tester, List<ZaehlerBeispiel> z) async {
      await start(tester, datenAus(z));
      await zurHaSeite(tester);
      await tippe(tester, find.text('Zähler zuordnen …'));
      expect(find.text('Zähler zuordnen'), findsOneWidget);
    }

    testWidgets('Je Kanal ein Zähler gleicher Art zur Auswahl; die Wahl schreibt dieselbe Quelle wie der Editor (Zählerstand, kein Rhythmus), Prüfen bleibt an', (tester) async {
      await hinZurZuordnung(tester, [stromOhne(), solarOhne(), _handWasser()]);
      expect(find.text('Strom Bezug'), findsWidgets);
      expect(find.text('Strom Einspeisung'), findsWidgets);
      expect(find.text('Solar Erzeugung'), findsWidgets);
      pruefeLayout(tester, 'Zuordnen');
      // Strom Bezug: "Strom Haus" wählen (nur passende Arten stehen zur Auswahl, nie das Wasser)
      await tippe(tester, find.byType(DropdownButtonFormField<String?>).first);
      expect(find.text('Wasser Küche'), findsNothing);
      await tippe(tester, find.text('Strom Haus').last);
      final z = repo.geaendert.single;
      expect(z.id, zStrom);
      expect(z.inhalt.quelle, const ZaehlerQuelle(kanal: 'strom_bezug', pruefen: true));
      expect(z.inhalt.modus, ZaehlerModus.stand);
      expect(z.inhalt.ablesung, isNull);
    });

    testWidgets('"Nicht nutzen" löst den Zähler wieder vom Kanal; ohne passenden Zähler steht ein Hinweis statt der Auswahl', (tester) async {
      await hinZurZuordnung(tester, [_haStrom()]);
      expect(find.textContaining('Noch kein passender Zähler'), findsNWidgets(2)); // Einspeisung (der einzige Stromzähler gehört schon zum Bezug) und Solar (kein Erzeugungszähler)
      await tippe(tester, find.byType(DropdownButtonFormField<String?>).first);
      await tippe(tester, find.text('Nicht nutzen').last);
      expect(repo.geaendert.single.id, zStrom);
      expect(repo.geaendert.single.inhalt.quelle, isNull);
    });

    testWidgets('Die eigenständige Seite: Hinweis auf den ersten Wert nach Mitternacht (ohne "Fast geschafft"); "Fertig" schließt', (tester) async {
      await start(tester, datenAus([stromOhne()]));
      // die eigenständige Seite sagt dasselbe ohne "Fast geschafft"
      await zurHaSeite(tester);
      await tippe(tester, find.text('Zähler zuordnen …'));
      expect(find.text('Fast geschafft'), findsNothing);
      expect(find.textContaining('erst nach der nächsten Mitternacht'), findsOneWidget);
      await tippe(tester, find.widgetWithText(FilledButton, 'Fertig'));
      expect(find.text('Werte automatisch abholen'), findsOneWidget);
    });

    testWidgets('Kind: nicht verfügbar', (tester) async {
      env = await angemeldeteUmgebung(role: 'child');
      final c = env.container();
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: HaZuordnenScreen())));
      await warte(tester);
      expect(find.text('Nicht verfügbar'), findsWidgets);
      expect(find.text('Strom Bezug'), findsNothing);
    });
  });

  group('Herkunft im Verlauf und Meldungen', () {
    testWidgets('Der Verlauf nennt bei automatischen Ständen "aus Home Assistant", bei Ständen von Hand nichts', (tester) async {
      await start(tester, datenAus([_haStrom(), _handWasser()]));
      await tippe(tester, find.bySemanticsLabel(RegExp(r'^Strom Haus\.')));
      expect(find.text('aus Home Assistant'), findsWidgets);
      await tippe(tester, find.byTooltip('Zurück'));
      await tippe(tester, find.bySemanticsLabel(RegExp(r'^Wasser Küche\.')));
      expect(find.text('aus Home Assistant'), findsNothing);
    });

    testWidgets('Nach erfolgreichem Trennen erscheint nie eine Fehlermeldung, auch wenn die Nacharbeit (Liste der Verbindungen) scheitert', (tester) async {
      await start(tester, datenAus([_haStrom()]), verbindungen: [
        {'id': 't1', 'name': 'Haus Keller', 'createdAt': '2026-10-01T10:00:00.000Z', 'lastUsedAt': null, 'revokedAt': null},
      ]);
      var widerrufen = false;
      env.server.on('GET /ingest/tokens', (_) => widerrufen ? fehler(404, 'not_found') : jsonAntwort({'tokens': tokens}));
      env.server.on('DELETE /ingest/tokens/t1', (_) {
        widerrufen = true;
        return jsonAntwort({'ok': true});
      });
      await zurHaSeite(tester);
      await tippe(tester, find.bySemanticsLabel('Verbindung Haus Keller trennen'));
      await tippe(tester, find.descendant(of: find.byType(AlertDialog), matching: find.text('Trennen')));
      expect(env.server.anfragen('DELETE /ingest/tokens/t1'), hasLength(1));
      expect(find.byType(MeldungsBox), findsNothing);
      // die Seite verlassen: die automatische Wiederholung des fehlgeschlagenen Ladens der Liste endet mit ihr
      await tippe(tester, find.byTooltip('Zurück'));
    });
  });

  group('Rechte und Zustand', () {
    testWidgets('Kind: die Seite ist "Nicht verfügbar", der Server wird nie gefragt', (tester) async {
      final server = standardServer(role: 'child');
      env = await angemeldeteUmgebung(role: 'child', server: server);
      speicher = MemorySchluesselSpeicher();
      env.extraOverrides.add(schluesselSpeicherProvider.overrideWithValue(speicher));
      final c = env.container();
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: HaVerbindungScreen())));
      await warte(tester);
      expect(find.text('Nicht verfügbar'), findsWidgets);
      expect(find.text('Werte automatisch abholen'), findsNothing);
      expect(c.read(ingestVerfuegbarProvider).value ?? false, isFalse);
      expect(server.anfragen('GET /ingest/zaehler/pending'), isEmpty);
      expect(server.anfragen('GET /ingest/tokens'), isEmpty);
    });
  });

  group('Notifier (echt): Schalter, Schlüssel, Rolle', () {
    Future<(ProviderContainer, FakeIngestDienst)> bauen({String role = 'admin', bool schalter = false, bool schluessel = true, Duration? takt}) async {
      final dienst = FakeIngestDienst();
      speicher = MemorySchluesselSpeicher();
      if (schluessel) await PostfachSpeicher(speicher).schreiben(fixIdAdmin, PostfachSchluessel.erzeugen(FakeCryptoProvider(seed: 4)));
      env = await angemeldeteUmgebung(role: role)..ingestTakt = takt;
      await env.db.metaSchreiben(kIngestAbholenSchluessel, schalter ? '1' : '0');
      env.extraOverrides.addAll([schluesselSpeicherProvider.overrideWithValue(speicher), ingestDienstProvider.overrideWithValue(dienst)]);
      final c = env.container();
      addTearDown(c.dispose);
      await c.read(authProvider.notifier).start();
      c.read(ingestProvider); // der Zustand entsteht (am Wurzel-Widget hält ihn ingestSteuerungProvider am Leben)
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return (c, dienst);
    }

    test('Schalter aus: kein Lauf, auch nicht auf Anforderung', () async {
      final (c, d) = await bauen();
      expect(c.read(ingestProvider).schalter, isFalse);
      expect(c.read(ingestProvider).postfachDa, isTrue);
      await c.read(ingestProvider.notifier).abholen();
      await c.read(ingestProvider.notifier).beimOeffnen();
      expect(d.laeufe, 0);
    });

    test('Schalter an, aber kein Schlüssel auf diesem Gerät: kein Lauf, der Schalter lässt sich nicht einschalten', () async {
      final (c, d) = await bauen(schalter: true, schluessel: false);
      expect(c.read(ingestProvider).postfachDa, isFalse);
      await c.read(ingestProvider.notifier).abholen();
      await c.read(ingestProvider.notifier).schalterSetzen(true);
      expect(d.laeufe, 0);
      expect(env.server.anfragen('GET /ingest/zaehler/pending'), isEmpty);
    });

    test('Schalter an und Schlüssel da: ein Lauf beim Start; das Öffnen der Seite direkt danach löst keinen zweiten aus', () async {
      final (c, d) = await bauen(schalter: true);
      expect(d.laeufe, 1);
      expect(c.read(ingestProvider).letzter, isNotNull);
      expect(c.read(ingestProvider).laeuft, isFalse);
      await c.read(ingestProvider.notifier).beimOeffnen();
      expect(d.laeufe, 1);
      await c.read(ingestProvider.notifier).abholen(); // ausdrücklich: immer
      expect(d.laeufe, 2);
    });

    test('Die Werte zur Prüfung bleiben nach einem abgebrochenen Lauf stehen', () async {
      final (c, d) = await bauen(schalter: true);
      d.lauf = IngestLauf(zeit: DateTime.now(), zuPruefen: [pruefEintrag()]);
      await c.read(ingestProvider.notifier).abholen();
      expect(c.read(ingestProvider).zuPruefen, hasLength(1));
      d.lauf = IngestLauf(zeit: DateTime.now(), abbruch: IngestAbbruch.netz);
      await c.read(ingestProvider.notifier).abholen();
      expect(c.read(ingestProvider).zuPruefen, hasLength(1));
      d.lauf = IngestLauf(zeit: DateTime.now());
      await c.read(ingestProvider.notifier).abholen();
      expect(c.read(ingestProvider).zuPruefen, isEmpty);
    });

    test('Entschiedene Werte bleiben bis zum nächsten Lauf aus der Liste: ein Lauf, der VOR der Entscheidung begann, blendet sie nicht wieder ein', () async {
      final (c, d) = await bauen(schalter: true);
      final n = c.read(ingestProvider.notifier);
      d.lauf = IngestLauf(zeit: DateTime.now(), zuPruefen: [pruefEintrag()]);
      await n.abholen();
      expect(c.read(ingestProvider).zuPruefen, hasLength(1));
      // ein Lauf beginnt (sein Ergebnis kennt den Wert noch), währenddessen entscheidet die Person
      d.tor = Completer<void>();
      final lauf = n.abholen();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await n.verwerfen(c.read(ingestProvider).zuPruefen.single);
      expect(d.entschieden, ['verwerfen:p1']);
      expect(c.read(ingestProvider).zuPruefen, isEmpty);
      d.tor!.complete();
      await lauf;
      expect(c.read(ingestProvider).zuPruefen, isEmpty); // das veraltete Ergebnis blendet ihn nicht wieder ein
      d.tor = null;
      await n.abholen(); // dieser Lauf begann nach der Entscheidung und kennt den Stand des Servers: das Gemerkte wird hier noch gefiltert und danach vergessen
      expect(c.read(ingestProvider).zuPruefen, isEmpty);
      await n.abholen();
      expect(c.read(ingestProvider).zuPruefen, hasLength(1)); // kommt der Wert vom Server doch wieder, steht er wieder da
    });

    test('Schalter einschalten startet einen Lauf, ausschalten stoppt ihn', () async {
      final (c, d) = await bauen();
      await c.read(ingestProvider.notifier).schalterSetzen(true);
      expect(d.laeufe, 1);
      expect(await env.db.metaLesen(kIngestAbholenSchluessel), '1');
      await c.read(ingestProvider.notifier).schalterSetzen(false);
      await c.read(ingestProvider.notifier).abholen();
      expect(d.laeufe, 1);
      expect(await env.db.metaLesen(kIngestAbholenSchluessel), '0');
    });

    test('Elternteil holt ab', () async {
      final (_, d) = await bauen(role: 'parent', schalter: true);
      expect(d.laeufe, 1);
    });

    test('Kind: nie ein Lauf, nichts gelesen, auch nicht mit Schalter und Schlüssel', () async {
      final (c, d) = await bauen(role: 'child', schalter: true);
      expect(c.read(ingestProvider).geladen, isFalse);
      await c.read(ingestProvider.notifier).abholen();
      await c.read(ingestProvider.notifier).beimOeffnen();
      expect(d.laeufe, 0);
      expect(c.read(ingestVerfuegbarProvider).value ?? false, isFalse);
    });

    test('Der Takt hängt am App-Lebenszyklus: im Hintergrund steht er still, beim Zurückkehren holt die App nach', () async {
      void zurueck() {
        // wie auf dem Gerät: Hintergrund -> versteckt -> inaktiv -> Vordergrund
        for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(s);
        }
      }

      addTearDown(zurueck);
      final (_, d) = await bauen(schalter: true, takt: const Duration(milliseconds: 60));
      expect(d.laeufe, greaterThanOrEqualTo(1)); // der Lauf beim Start
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final vorn = d.laeufe;
      expect(vorn, greaterThan(1), reason: 'im Vordergrund läuft der Takt');
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final beimAusblenden = d.laeufe;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(d.laeufe, beimAusblenden, reason: 'im Hintergrund holt die App nichts ab');
      zurueck();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(d.laeufe, greaterThan(beimAusblenden), reason: 'beim Zurückkehren wird ein überfälliger Lauf nachgeholt');
    });

    test('Verfügbarkeit: features.ingest aus GET /version entscheidet ohne Probe-Aufruf; ein älterer Server ohne das Feld wird wie früher mit einem Probe-Aufruf gefragt', () async {
      final (c, _) = await bauen();
      env.server.json('GET /version', {'service': 'lx-fampad', 'features': {'ingest': true}});
      expect(await c.read(ingestVerfuegbarProvider.future), isTrue);
      c.invalidate(ingestVerfuegbarProvider);
      env.server.json('GET /version', {'service': 'lx-fampad', 'features': {'ingest': false}});
      expect(await c.read(ingestVerfuegbarProvider.future), isFalse);
      expect(env.server.anfragen('GET /ingest/zaehler/pending'), isEmpty);
      // älterer Server: kein Feld, der Probe-Aufruf entscheidet (200 = ja, 404 = nein)
      env.server.json('GET /version', {'service': 'lx-fampad', 'features': {'files': true}});
      env.server.json('GET /ingest/zaehler/pending', {'items': [], 'next': null});
      c.invalidate(ingestVerfuegbarProvider);
      expect(await c.read(ingestVerfuegbarProvider.future), isTrue);
      expect(env.server.anfragen('GET /ingest/zaehler/pending'), hasLength(1));
      env.server.on('GET /ingest/zaehler/pending', (_) => fehler(404, 'not_found'));
      c.invalidate(ingestVerfuegbarProvider);
      expect(await c.read(ingestVerfuegbarProvider.future), isFalse);
      // die zuletzt bekannte Antwort überlebt einen Ausfall
      expect(await env.db.metaLesen(kIngestVerfuegbarSchluessel), '0');
    });

    test('Abmelden verwirft den Zustand, aber nie den Schlüssel; "Gerät abgeben" löscht ihn', () async {
      final (c, _) = await bauen(schalter: true);
      c.invalidate(ingestProvider); // wie der Wiper beim Abmelden
      expect(c.read(ingestProvider).letzter, isNull);
      expect(await PostfachSpeicher(speicher).vorhanden(fixIdAdmin), isTrue);
      await schluesselVomGeraetLoeschen(speicher, fixIdAdmin);
      expect(await PostfachSpeicher(speicher).vorhanden(fixIdAdmin), isFalse);
    });
  });
}


/// Ein Notifier, dessen "Verwerfen" erst endet, wenn der Test es erlaubt (für den Ladekreis am gedrückten Knopf).
class _Haengt extends TestIngest {
  final tor = Completer<void>();
  _Haengt(super.start);

  @override
  Future<void> verwerfen(IngestPruefEintrag e) async {
    await tor.future;
    return super.verwerfen(e);
  }
}

/// Ein Schlüsselspeicher, der die Liste der Verbindungen (Merkliste) nicht schreiben kann: simuliert einen Fehler NACH dem Anlegen der Verbindung beim Server.
class _MerklisteKaputt extends MemorySchluesselSpeicher {
  final String uid;
  _MerklisteKaputt(this.uid);

  @override
  Future<void> schreiben(String name, Uint8List bytes) {
    if (name == postfachVerbindungenName(uid)) throw const SchluesselSpeicherFehler('Speicher nicht schreibbar', dauerhaft: false);
    return super.schreiben(name, bytes);
  }
}
