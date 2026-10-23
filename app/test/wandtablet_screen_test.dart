// Wandtablet-Modus, Oberfläche: Querformat 1280x800 und 1024x600, Hochformat 360x800 (Textskala 1.5/2.0), Inhalt aus den vorhandenen Daten (nie Chat und
// Standort), Ausstieg (Uhr gedrückt halten, Zurück-Taste beendet nicht), Wake-Lock (Fake), Dimmen, Verschiebung, Offline-Hinweis, Abmeldung, Autostart,
// Einstieg über Profil und Desktop-Startseite, Schalter-Persistenz.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/calendar/expansion.dart';
import 'package:lx_fampad/data/calendar/feiertage.dart';
import 'package:lx_fampad/data/erinnerungen/erinnerung_dienst.dart' show erinnerungPortProvider;
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/data/wandtablet/bildschirm_wach.dart';
import 'package:lx_fampad/data/wandtablet/wandtablet_einstellungen.dart';
import 'package:lx_fampad/data/wandtablet/wandtablet_logik.dart';
import 'package:lx_fampad/features/calendar/calendar_anzeige.dart' show minutenTaktProvider;
import 'package:lx_fampad/features/calendar/calendar_state.dart';
import 'package:lx_fampad/features/home/desktop_home.dart' show DesktopHome;
import 'package:lx_fampad/features/shell/shell_tab.dart';
import 'package:lx_fampad/features/wandtablet/wandtablet_screen.dart';
import 'package:lx_fampad/features/wandtablet/wandtablet_steuerung.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;

import 'support/fake_erinnerung_port.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _t1 = 'dddddddd-1111-4111-8111-111111111111';
const _t2 = 'dddddddd-2222-4222-8222-222222222222';
const _t3 = 'dddddddd-3333-4333-8333-333333333333';
const _a1 = 'eeeeeeee-1111-4111-8111-111111111111';
const _a2 = 'eeeeeeee-2222-4222-8222-222222222222';
const _a3 = 'eeeeeeee-3333-4333-8333-333333333333';
const _l1 = 'ffffffff-1111-4111-8111-111111111111';
const _i1 = 'ffffffff-2222-4222-8222-222222222222';

String _tag(int tage) {
  final h = heuteTag();
  return tagText(DateTime.utc(h.year, h.month, h.day + tage));
}

/// Ganztägiger Termin (bleibt den ganzen Tag, unabhängig von der Uhrzeit des Testlaufs).
Map<String, dynamic> _ganztags(String titel, {int tage = 0}) => {
  'titel': titel,
  'ganztaegig': true,
  'startDate': _tag(tage),
  'endDate': _tag(tage + 1),
  'ownerId': fixIdAdmin,
  'audience': 'family',
};

class _FakeWach implements BildschirmWach {
  int gehalten = 0;
  int freigegeben = 0;
  bool get aktiv => gehalten > freigegeben;

  @override
  Future<void> halten() async => gehalten++;

  @override
  Future<void> freigeben() async => freigegeben++;
}

void ohneFehler(WidgetTester tester) {
  final ex = tester.takeException();
  expect(ex, isNull, reason: ex is FlutterError ? ex.toStringDeep() : '$ex');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  setUpAll(testVorbereiten);

  void seed(TestUmgebung e) {
    e.sync.andereAendert('termin', _t1, _ganztags('Zahnarzt'));
    e.sync.andereAendert('termin', _t2, _ganztags('Elternabend', tage: 1));
    e.sync.andereAendert('termin', _t3, _ganztags('Urlaub in drei Tagen', tage: 3));
    e.sync.andereAendert('aufgabe', _a1, {'titel': 'Müll rausstellen', 'faelligDate': _tag(0)});
    e.sync.andereAendert('aufgabe', _a2, {'titel': 'Später erledigen', 'faelligDate': _tag(5)});
    e.sync.andereAendert('aufgabe', _a3, {'titel': 'Längst fällig', 'faelligDate': _tag(-2)});
  }

  Future<void> oeffne(WidgetTester tester) async {
    final ctx = tester.element(find.byType(Scaffold).first);
    unawaited(wandtabletStarten(ctx));
    await warte(tester, 10);
  }

  /// Startet die App, öffnet den Modus über allem und liefert Umgebung, Container und den Fake des Wake-Locks.
  Future<(TestUmgebung, ProviderContainer, _FakeWach)> start(
    WidgetTester tester, {
    Size groesse = const Size(1280, 800),
    double skala = 1.0,
    void Function(TestUmgebung env)? vorher,
    Map<String, String> einstellungen = const {},
    DateTime? uhr,
    bool oeffnen = true,
    String role = 'admin',
  }) async {
    final env = await angemeldeteUmgebung(role: role);
    final wach = _FakeWach();
    env.extraOverrides.addAll([
      erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false),
      bildschirmWachProvider.overrideWithValue(wach),
      if (uhr != null) minutenTaktProvider.overrideWith((ref) => Stream.value(uhr)),
    ]);
    env.speicher = MemoryFeiertageSpeicher('nein', {kKalenderAnsichtSchluessel: 'agenda', ...einstellungen});
    vorher?.call(env);
    final container = await starteApp(tester, env, groesse: groesse, skala: skala);
    if (oeffnen) await oeffne(tester);
    return (env, container, wach);
  }

  final uhrFinder = find.textContaining(RegExp(r'^\d\d:\d\d$'));

  Future<void> beenden(WidgetTester tester) async {
    await tester.longPress(uhrFinder);
    await warte(tester, 10);
  }

  Offset verschiebungVon(WidgetTester tester) {
    final t = tester.widget<Transform>(find.descendant(of: find.byType(TweenAnimationBuilder<Offset>), matching: find.byType(Transform)).first);
    final v = t.transform.getTranslation();
    return Offset(v.x, v.y);
  }

  group('Inhalt', () {
    testWidgets('Querformat 1280x800: Uhr, Datum, Termine heute und morgen, fällige Aufgaben; Späteres fehlt', (tester) async {
      await start(tester, vorher: seed);
      expect(uhrFinder, findsOneWidget);
      expect(find.textContaining(RegExp(r'^(Montag|Dienstag|Mittwoch|Donnerstag|Freitag|Samstag|Sonntag), ')), findsOneWidget, reason: 'Datum');
      expect(find.text('// TERMINE'), findsOneWidget);
      expect(find.text('HEUTE'), findsOneWidget);
      expect(find.text('MORGEN'), findsOneWidget);
      expect(find.text('Zahnarzt'), findsOneWidget);
      expect(find.text('Elternabend'), findsOneWidget);
      expect(find.text('Urlaub in drei Tagen'), findsNothing, reason: 'nur heute und morgen');
      expect(find.text('// AUFGABEN'), findsOneWidget);
      expect(find.text('Müll rausstellen'), findsOneWidget);
      expect(find.text('Längst fällig'), findsOneWidget, reason: 'überfällig zählt als fällig');
      expect(find.text('Später erledigen'), findsNothing);
      ohneFehler(tester);
      // 3 Spalten: Termine links, Aufgaben rechts daneben
      final termine = tester.getTopLeft(find.text('// TERMINE'));
      final aufgaben = tester.getTopLeft(find.text('// AUFGABEN'));
      expect(aufgaben.dx, greaterThan(termine.dx + 300), reason: 'eigene Spalte');
    });

    testWidgets('nie Chat, Standort, Schlüssel, Betrieb oder Profil; keine Bedienelemente', (tester) async {
      await start(tester, vorher: seed);
      for (final wort in ['Chat', 'Standort', 'Schlüssel', 'Betrieb', 'Profil', 'Nachricht', 'Verschlüsselung']) {
        expect(find.textContaining(wort), findsNothing, reason: wort);
      }
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(PopupMenuButton<dynamic>), findsNothing);
    });

    testWidgets('Fristen und Einkaufsliste nur mit Inhalt bzw. gewählter Liste; Geburtstage erscheinen als Termine', (tester) async {
      await start(
        tester,
        einstellungen: {kWandListeSchluessel: _l1},
        vorher: (e) {
          seed(e);
          e.sync.andereAendert('aufgabe', 'eeeeeeee-4444-4444-8444-444444444444', {
            'titel': 'TÜV',
            'faelligDate': _tag(10),
            'frist': true,
            'fristMonate': 12,
            'erinnerungMin': 30 * 1440,
          });
          e.sync.andereAendert('list', _l1, {'name': 'Einkauf', 'kind': 'shopping', 'audience': 'family'});
          e.sync.andereAendert('list_item', _i1, {'listId': _l1, 'text': 'Milch', 'position': 0});
          e.sync.andereAendert('termin', 'dddddddd-4444-4444-8444-444444444444', {
            ..._ganztags('Oma'),
            'rrule': 'FREQ=YEARLY',
            'icalUid': 'lxfampad-geb-0000-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          });
        },
      );
      expect(find.text('// FRISTEN'), findsOneWidget);
      expect(find.text('TÜV'), findsOneWidget);
      expect(find.text('// EINKAUF'), findsOneWidget);
      expect(find.text('Milch'), findsOneWidget);
      expect(find.text('Oma hat Geburtstag'), findsWidgets);
    });

    testWidgets('Müll (morgen, hervorgehoben) und Wetter erscheinen, wenn der Server sie liefert', (tester) async {
      final morgen = heuteTag().add(const Duration(days: 1));
      await start(
        tester,
        vorher: (e) {
          e.server.on('GET /waste', (_) => jsonAntwort({
            'place': 'Salz',
            'years': [
              {'year': morgen.year, 'status': 'loaded', 'eventCount': 1, 'checkedAt': DateTime.now().toUtc().toIso8601String(), 'errorCode': null},
            ],
            'events': [
              {'date': tagText(morgen), 'kinds': ['bio']},
            ],
            'check': {'pending': false, 'lastCheckAt': null, 'nextCheckAt': null, 'nextRequestAt': null},
          }));
          e.server.on('GET /weather', (_) => jsonAntwort({
            'available': true,
            'place': 'Westerburg',
            'current': {'measuredAt': DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(), 'stale': false, 'temperature': 12.5, 'humidity': 71, 'pressure': 1013.2, 'rain1h': 0.5, 'rain24h': 2.1, 'windKmh': 12, 'gustKmh': 25, 'windAngle': 270},
            'min24h': 3.0,
            'max24h': 18.5,
            'series': <Object>[],
          }));
        },
      );
      expect(find.text('// MÜLL · MORGEN'), findsOneWidget);
      expect(find.byIcon(Icons.eco_outlined), findsOneWidget);
      expect(find.text('// WETTER'), findsOneWidget);
      expect(find.text('Westerburg'), findsOneWidget);
      expect(find.text('12,5 °C'), findsOneWidget);
      ohneFehler(tester);
    });

    testWidgets('ohne Fristen, Liste, Wetter, Müll und Countdown gibt es nur Termine und Aufgaben', (tester) async {
      await start(tester, vorher: seed);
      expect(find.text('// FRISTEN'), findsNothing);
      expect(find.text('// COUNTDOWN'), findsNothing);
      expect(find.text('// WETTER'), findsNothing);
      expect(find.textContaining('// MÜLL'), findsNothing);
      expect(find.text('// EINKAUF'), findsNothing);
    });

    testWidgets('Kind sieht die Anzeige ebenfalls (nach seinen Rechten)', (tester) async {
      await start(tester, role: 'child', vorher: seed);
      expect(find.text('Zahnarzt'), findsOneWidget);
      expect(find.text('// AUFGABEN'), findsOneWidget);
    });
  });

  group('Layout', () {
    for (final (groesse, name) in [(const Size(1280, 800), '1280x800'), (const Size(1024, 600), '1024x600'), (const Size(800, 1280), '800x1280 Hochformat')]) {
      testWidgets('$name: keine Layoutfehler, alle Blöcke erreichbar', (tester) async {
        await start(tester, groesse: groesse, vorher: seed);
        ohneFehler(tester);
        expect(find.text('Zahnarzt'), findsOneWidget);
        expect(find.text('Müll rausstellen'), findsOneWidget);
      });
    }

    testWidgets('1024x600: zwei Spalten (Termine links, Aufgaben rechts)', (tester) async {
      await start(tester, groesse: const Size(1024, 600), vorher: seed);
      expect(tester.getTopLeft(find.text('// AUFGABEN')).dx, greaterThan(tester.getTopLeft(find.text('// TERMINE')).dx + 300));
    });

    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('Hochformat 360x800, Textskala $skala: einspaltig, scrollbar, keine Layoutfehler', (tester) async {
        await start(tester, groesse: const Size(360, 800), skala: skala, vorher: seed);
        ohneFehler(tester);
        expect(find.text('Zahnarzt'), findsOneWidget);
        // einspaltig: Aufgaben liegen unter den Terminen (nach dem Scrollen erreichbar)
        await tester.scrollUntilVisible(find.text('// AUFGABEN'), 200, scrollable: find.byType(Scrollable).first);
        await warte(tester);
        ohneFehler(tester);
        expect(find.text('Müll rausstellen'), findsOneWidget);
        expect(tester.getTopLeft(find.text('// AUFGABEN')).dx, lessThan(60));
      });
    }

    testWidgets('1280x800 mit Textskala 2.0: keine Layoutfehler', (tester) async {
      await start(tester, skala: 2.0, vorher: seed, oeffnen: false);
      // die normale Startseite hat bei Textskala 2.0 eigene Randfälle; geprüft wird nur die Wandanzeige
      while (tester.takeException() != null) {}
      await oeffne(tester);
      ohneFehler(tester);
    });
  });

  group('Bedienung', () {
    testWidgets('Hinweis "Zum Beenden gedrückt halten" beim Start, verschwindet nach einigen Sekunden', (tester) async {
      await start(tester);
      expect(find.text(kWandHinweisBeenden), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      expect(find.text(kWandHinweisBeenden), findsNothing);
    });

    testWidgets('Ausstieg: Uhr gedrückt halten beendet; ein kurzer Tipp nicht', (tester) async {
      await start(tester);
      await tester.tap(uhrFinder);
      await warte(tester);
      expect(find.byType(WandtabletScreen), findsOneWidget);
      await beenden(tester);
      expect(find.byType(WandtabletScreen), findsNothing);
      expect(find.byType(NavigationBar), findsNothing, reason: 'Desktop-Shell: Startseite wieder da');
      ohneFehler(tester);
    });

    testWidgets('Zurück-Taste beendet nicht, erinnert aber an den Ausstieg', (tester) async {
      await start(tester);
      await tester.pump(const Duration(seconds: 7));
      expect(find.text(kWandHinweisBeenden), findsNothing);
      await tester.binding.handlePopRoute();
      await warte(tester);
      expect(find.byType(WandtabletScreen), findsOneWidget);
      expect(find.text(kWandHinweisBeenden), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Screenreader: Uhr hat die Aktion "Gedrückt halten" und nennt den Ausstieg', (tester) async {
      final handle = tester.ensureSemantics();
      await start(tester);
      final knoten = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Uhr, ')));
      expect(knoten.hint, kWandHinweisBeenden);
      // ignore: deprecated_member_use
      expect(knoten.getSemanticsData().hasAction(SemanticsAction.longPress), isTrue);
      tester.semantics.longPress(find.semantics.byLabel(RegExp(r'^Uhr, ')));
      await warte(tester, 10);
      expect(find.byType(WandtabletScreen), findsNothing);
      handle.dispose();
    });

    testWidgets('Wake-Lock: beim Öffnen gehalten, beim Verlassen freigegeben', (tester) async {
      final (_, _, wach) = await start(tester);
      expect(wach.aktiv, isTrue);
      expect(wach.gehalten, 1);
      await beenden(tester);
      expect(wach.aktiv, isFalse);
      expect(wach.freigegeben, 1);
    });

    testWidgets('System-Kanal (Android): setKeepScreenOn wird gesendet und freigegeben', (tester) async {
      final env = await angemeldeteUmgebung();
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      await starteApp(tester, env, groesse: const Size(1280, 800));
      await oeffne(tester);
      expect(kanalAufrufe.where((c) => c.method == 'setKeepScreenOn' && (c.arguments as Map)['an'] == true), isNotEmpty);
      await beenden(tester);
      expect(kanalAufrufe.where((c) => c.method == 'setKeepScreenOn' && (c.arguments as Map)['an'] == false), isNotEmpty);
    });
  });

  group('Einbrenn-Schutz', () {
    final nacht = DateTime.utc(2026, 1, 15, 23); // 00:00 Berlin
    final tag = DateTime.utc(2026, 1, 15, 11);

    bool abgedunkelt(WidgetTester tester) =>
        find.byWidgetPredicate((w) => w is ColoredBox && (w.color.a - kWandNachtDeckkraft).abs() < 0.01).evaluate().isNotEmpty;

    testWidgets('nachts gedimmt (Standard), tagsüber nicht', (tester) async {
      await start(tester, uhr: nacht);
      expect(abgedunkelt(tester), isTrue);
    });

    testWidgets('tagsüber nicht gedimmt', (tester) async {
      await start(tester, uhr: tag);
      expect(abgedunkelt(tester), isFalse);
    });

    testWidgets('"Nachts dimmen" aus: auch nachts nicht gedimmt', (tester) async {
      await start(tester, uhr: nacht, einstellungen: {kWandDimmenSchluessel: 'nein'});
      expect(abgedunkelt(tester), isFalse);
    });

    testWidgets('Inhalt ist um wenige Pixel verschoben und wechselt im 5-Minuten-Takt', (tester) async {
      final erwartet = verschiebung(tag);
      await start(tester, uhr: tag);
      await tester.pump(const Duration(seconds: 5));
      final o = verschiebungVon(tester);
      expect((o.dx, o.dy), (erwartet.dx.toDouble(), erwartet.dy.toDouble()));
      expect(o.dx.abs() <= kWandVerschiebeMax && o.dy.abs() <= kWandVerschiebeMax, isTrue);
    });

    testWidgets('keine hellen Vollflächen: Hintergrund ist die dunkle Grundfarbe', (tester) async {
      await start(tester);
      expect(tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor, kBg);
    });
  });

  group('Verbindung und Sitzung', () {
    testWidgets('Offline: kleiner Hinweis "Offline …", letzte Daten bleiben, keine Fehlerfläche', (tester) async {
      final (env, container, _) = await start(tester, vorher: seed);
      expect(find.textContaining('Offline'), findsNothing);
      env.sync.offline = true;
      unawaited(container.read(syncProvider.notifier).synchronisieren(manuell: true));
      await warte(tester, 10);
      expect(container.read(syncProvider).status, SyncStatus.offline);
      expect(find.textContaining('Offline'), findsOneWidget);
      expect(find.text('Zahnarzt'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      ohneFehler(tester);
    });

    testWidgets('Abmeldung beendet den Modus und zeigt die Anmeldung; Wake-Lock ist frei', (tester) async {
      final (_, container, wach) = await start(tester, vorher: seed);
      unawaited(container.read(authProvider.notifier).dieseSitzungBeendet());
      await warte(tester, 12);
      expect(find.byType(WandtabletScreen), findsNothing);
      expect(find.text('Willkommen zurück'), findsOneWidget);
      expect(wach.aktiv, isFalse);
    });
  });

  group('Einstieg und Einstellungen', () {
    testWidgets('Profil > Startseite und Anzeige > Wandtablet-Modus: Schalter bleiben gemerkt, "Jetzt starten" öffnet den Modus', (tester) async {
      final env = await angemeldeteUmgebung();
      final wach = _FakeWach();
      final speicher = MemoryFeiertageSpeicher('nein', {kKalenderAnsichtSchluessel: 'agenda'});
      env.speicher = speicher;
      env.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false), bildschirmWachProvider.overrideWithValue(wach)]);
      final container = await starteApp(tester, env);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Wandtablet-Modus');
      expect(find.text('Jetzt starten'), findsOneWidget);
      expect(container.read(wandtabletEinstellungenProvider).dimmen, isTrue);
      await tippe(tester, find.text('Nachts dimmen'));
      await tippe(tester, find.text('Beim Start der App automatisch starten'));
      expect(speicher.werte[kWandDimmenSchluessel], 'nein');
      expect(speicher.werte[kWandAutostartSchluessel], 'ja');
      ohneFehler(tester);
      await tippe(tester, find.text('Jetzt starten'));
      await warte(tester, 8);
      expect(find.byType(WandtabletScreen), findsOneWidget);
      expect(wach.aktiv, isTrue);
      await beenden(tester);
      expect(find.text('Jetzt starten'), findsOneWidget, reason: 'zurück auf der Einstellungsseite');
    });

    testWidgets('Einstellungsseite bei 360 px und Textskala 2.0: keine Layoutfehler', (tester) async {
      final env = await angemeldeteUmgebung();
      env.extraOverrides.add(erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false));
      await starteApp(tester, env, skala: 2.0);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Wandtablet-Modus');
      pruefeLayout(tester, 'Wandtablet-Einstellungen');
    });

    testWidgets('Desktop-Startseite: Zeile "Wandtablet-Modus" startet den Modus (keine Kopfzeilen-Aktion)', (tester) async {
      final env = await angemeldeteUmgebung();
      env.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false), bildschirmWachProvider.overrideWithValue(_FakeWach())]);
      final container = await starteApp(tester, env, groesse: const Size(1280, 800));
      container.read(shellTabProvider.notifier).waehlen(0);
      await warte(tester);
      final zeile = find.text('Wandtablet-Modus');
      await tester.scrollUntilVisible(zeile, 200, scrollable: find.descendant(of: find.byType(DesktopHome), matching: find.byType(Scrollable)).first);
      await tippe(tester, zeile);
      await warte(tester, 8);
      expect(find.byType(WandtabletScreen), findsOneWidget);
    });

    testWidgets('Autostart: nach der Anmeldung startet der Modus von selbst, nach dem Ausstieg nicht erneut', (tester) async {
      final env = await angemeldeteUmgebung();
      final wach = _FakeWach();
      env.speicher = MemoryFeiertageSpeicher('nein', {kKalenderAnsichtSchluessel: 'agenda', kWandAutostartSchluessel: 'ja'});
      env.extraOverrides.addAll([erinnerungPortProvider.overrideWithValue(FakeErinnerungPort()..verfuegbar = false), bildschirmWachProvider.overrideWithValue(wach)]);
      await starteApp(tester, env, groesse: const Size(1280, 800));
      await warte(tester, 10);
      expect(find.byType(WandtabletScreen), findsOneWidget);
      expect(wach.gehalten, 1);
      await beenden(tester);
      expect(find.byType(WandtabletScreen), findsNothing);
      await warte(tester, 10);
      expect(find.byType(WandtabletScreen), findsNothing);
      expect(wach.gehalten, 1);
    });

    testWidgets('ohne Autostart öffnet sich der Modus nicht von selbst', (tester) async {
      await start(tester, oeffnen: false);
      await warte(tester, 10);
      expect(find.byType(WandtabletScreen), findsNothing);
    });
  });
}
