// Abmelden behält den Schlüssel (P0 "Kein Datenverlust"): "Abmelden", "Überall abmelden" und "Dieses Gerät abmelden" beenden nur die Sitzung und leeren die
// zwischengespeicherten Daten; der Personenschlüssel bleibt im Schlüsselspeicher liegen. Die Rückfrage ist nur ein ruhiger Hinweis ("Dein Schlüssel bleibt auf diesem
// Gerät"), keine Warnung und kein "Trotzdem abmelden". Die harte Warnung gehört zu "Gerät abgeben" (kein_datenverlust_test.dart).
// 360 px, Textskala 1.0 und 1.5 (ganze App); 2.0 nur für den Dialog allein (die Startseite läuft bei 2.0 über, unabhängig von dieser Änderung).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/sync_state.dart';
import 'package:lx_fampad/data/crypto/schluessel_speicher.dart';
import 'package:lx_fampad/features/profile/abmelden_pruefung.dart';

import 'support/fake_crypto.dart';
import 'support/fake_e2ee_server.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

/// Schlüsselspeicher, dessen Lesen sich ausschalten lässt (wie ein vorübergehend nicht lesbarer Keystore).
class _KaputterSpeicher extends MemorySchluesselSpeicher {
  bool kaputt = false;

  @override
  Future<Uint8List?> lesen(String name) async {
    if (kaputt) {
      throw const SchluesselSpeicherFehler('nicht lesbar', dauerhaft: false);
    }
    return super.lesen(name);
  }
}

class _Aufbau {
  final TestUmgebung env;
  final FakeE2eeServer srv;
  final _KaputterSpeicher speicher;
  _Aufbau(this.env, this.srv, this.speicher);
}

Future<_Aufbau> _aufbau({bool pwServer = true}) async {
  final server = standardServer()
    ..json('POST /auth/logout', {'ok': true})
    ..json('POST /auth/logout-all', {'ok': true})
    ..json('DELETE /devices/$fixDevice', {'ok': true});
  final srv = FakeE2eeServer(server, standardId: fixIdAdmin)
    ..person(fixIdAdmin, 'Anna');
  srv.pwSchalter = pwServer;
  final env = TestUmgebung(server)..wiperMitVerschluesselung = true;
  await env.angemeldet();
  final speicher = _KaputterSpeicher();
  env.extraOverrides.addAll([
    cryptoProviderProvider.overrideWith((ref) async => FakeCryptoProvider()),
    schluesselSpeicherProvider.overrideWithValue(speicher),
  ]);
  return _Aufbau(env, srv, speicher);
}

/// Einrichtung ohne Sicherung des Wiederherstellungsschlüssels, danach zurück im Profil.
Future<void> _einrichten(WidgetTester tester) async {
  await tippe(tester, find.byTooltip('Profil und Sicherheit'));
  await tippeText(tester, 'Verschlüsselung');
  await tippeText(tester, 'Verschlüsselung einrichten');
  await tippeText(tester, 'Später sichern');
  await tippe(tester, find.widgetWithText(TextButton, 'Später'));
  await tippe(tester, find.byTooltip('Zurück'));
}

/// Der Personenschlüssel dieser Person liegt noch im Schlüsselspeicher.
Future<bool> _schluesselDa(_Aufbau a) async {
  a.speicher.kaputt = false;
  return await a.speicher.lesen(personenschluesselName(fixIdAdmin)) != null;
}

/// Zustand fest vorgegeben (nur für den Dialog allein).
class _FesterZustand extends E2eeController {
  final E2eeState fest;
  _FesterZustand(this.fest);

  @override
  E2eeState build() => fest;

  @override
  Future<void> laden() async {}
}

Future<void> _dialogAllein(
  WidgetTester tester,
  E2eeState zustand, {
  bool ueberall = false,
  bool web = false,
  String knopf = 'Abmelden',
  int abgelehnt = 0,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = const Size(360, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        e2eeProvider.overrideWith(() => _FesterZustand(zustand)),
        abgelehnteAenderungenProvider.overrideWith((ref) => Stream.value(abgelehnt)), // ohne Datenbank
        ...extra,
      ],
      child: MaterialApp(
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: w!,
        ),
        home: Consumer(
          builder: (c, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => abmeldenBestaetigen(
                  c,
                  ref,
                  titel: 'Abmelden?',
                  text: 'Du wirst abgemeldet.',
                  knopf: knopf,
                  ueberall: ueberall,
                  web: web,
                ),
                child: const Text('los'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('los'));
  await tester.pumpAndSettle();
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  for (final skala in [1.0, 1.5]) {
    final s = '360 px, Textskala $skala';

    testWidgets(
      'ohne Schlüssel: einfache Rückfrage, Abmelden wie bisher ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Abmelden');
        expect(find.text('Abmelden?'), findsOneWidget);
        expect(find.textContaining('Schlüssel'), findsNothing);
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1);
        expect(find.text('Willkommen zurück'), findsOneWidget);
      },
    );

    testWidgets(
      'mit Schlüssel: nur ein ruhiger Hinweis, keine Warnung; Abmelden löscht den Schlüssel NICHT ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        expect(await _schluesselDa(a), isTrue);
        await tippeText(tester, 'Abmelden');
        expect(find.textContaining('Dein Schlüssel bleibt auf diesem Gerät'), findsOneWidget);
        expect(find.textContaining('Gerät abgeben'), findsOneWidget, reason: 'Hinweis auf den Weg, den Schlüssel bewusst zu löschen');
        expect(find.text('Trotzdem abmelden'), findsNothing);
        expect(find.text('Erst sichern'), findsNothing);
        expect(find.text('Passwort-Sicherung anlegen'), findsNothing);
        expect(find.textContaining('gelöscht, falls einer da ist'), findsNothing);
        pruefeLayout(tester, 'Abmelden-Hinweis mit Schlüssel');
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1, reason: 'zwischengespeicherte Daten werden wie bisher geleert');
        expect(find.text('Willkommen zurück'), findsOneWidget);
        expect(await _schluesselDa(a), isTrue, reason: 'der Personenschlüssel bleibt im Schlüsselspeicher');
        expect(await a.speicher.lesen('e2ee.kv.$fixIdAdmin'), isNotNull);
      },
    );

    testWidgets('"Abbrechen" lässt alles unberührt ($s)', (tester) async {
      final a = await _aufbau();
      await starteApp(tester, a.env, skala: skala);
      await _einrichten(tester);
      await tippeText(tester, 'Abmelden');
      await tippeText(tester, 'Abbrechen');
      expect(find.byType(AlertDialog), findsNothing);
      expect(a.env.geloescht, 0);
      expect(a.srv.server.anfragen('POST /auth/logout'), isEmpty);
      expect(await a.env.store.readTokens(), isNotNull);
      expect(find.text('Profil'), findsOneWidget);
    });

    testWidgets(
      'der Hinweis hängt nicht vom Stand der Sicherung ab (Server nicht erreichbar, keine Sicherung): derselbe ruhige Hinweis ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        a.srv.server.on('GET /me/keys', (_) => fehler(500, 'server_error'));
        await tippeText(tester, 'Abmelden');
        expect(find.textContaining('Dein Schlüssel bleibt auf diesem Gerät'), findsOneWidget);
        // der Dialog sagt nichts über die Sicherung (die Profilseite dahinter hat seit P1 die Zeile "Bin ich abgesichert?", daher nur der Dialog)
        expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('gesichert')), findsNothing);
        expect(find.text('Trotzdem abmelden'), findsNothing);
        pruefeLayout(tester, 'Abmelden bei nicht erreichbarem Server');
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(await _schluesselDa(a), isTrue);
      },
    );

    testWidgets(
      'Schlüsselspeicher nicht lesbar: "unbekannt, evtl. vorhanden", nie "kein Schlüssel"; der Schlüssel bleibt ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        // frischer App-Start mit nicht lesbarem Schlüsselspeicher: der Schlüssel ist nicht im Arbeitsspeicher
        a.speicher.kaputt = true;
        await tester.pumpWidget(const SizedBox());
        await starteApp(tester, a.env, skala: skala);
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippeText(tester, 'Abmelden');
        expect(find.textContaining('die App konnte ihn gerade nicht prüfen'), findsOneWidget);
        expect(find.text('Abmelden?'), findsOneWidget);
        expect(find.text('Trotzdem abmelden'), findsNothing);
        pruefeLayout(tester, 'Abmelden bei unbekanntem Schlüsselstand');
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1);
        expect(await _schluesselDa(a), isTrue, reason: 'ein nicht lesbarer Speicher ist nie ein Grund zu löschen');
      },
    );

    testWidgets(
      'Überall abmelden: Hinweis auf die anderen Geräte, ruft logout-all, Schlüssel bleibt ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Überall abmelden');
        expect(find.textContaining('Auch deine anderen Geräte werden abgemeldet; sie behalten ihren Schlüssel'), findsOneWidget);
        pruefeLayout(tester, 'Überall abmelden mit Schlüssel');
        await tippe(
          tester,
          find.widgetWithText(TextButton, 'Überall abmelden'),
        );
        expect(a.srv.server.anfragen('POST /auth/logout-all'), hasLength(1));
        expect(a.env.geloescht, 1);
        expect(await _schluesselDa(a), isTrue);
      },
    );

    testWidgets(
      'Geräteliste, dieses Gerät: ruhiger Hinweis, Schlüssel bleibt; anderes Gerät ohne Hinweis ($s)',
      (tester) async {
        final a = await _aufbau();
        await starteApp(tester, a.env, skala: skala);
        await _einrichten(tester);
        await tippeText(tester, 'Angemeldete Geräte');
        await tippe(tester, find.byTooltip('Firefox auf Windows abmelden'));
        expect(
          find.textContaining('Schlüssel'),
          findsNothing,
          reason: 'ein anderes Gerät ist hier nicht betroffen',
        );
        await tippeText(tester, 'Abbrechen');
        await tippe(tester, find.byTooltip('Pixel 9 abmelden'));
        expect(find.textContaining('Dein Schlüssel bleibt auf diesem Gerät'), findsOneWidget);
        pruefeLayout(tester, 'Geräteliste mit Schlüssel-Hinweis');
        await tippeText(tester, 'Abbrechen');
        expect(a.env.geloescht, 0);
        await tippe(tester, find.byTooltip('Pixel 9 abmelden'));
        await tippe(tester, find.widgetWithText(TextButton, 'Abmelden'));
        expect(a.env.geloescht, 1);
        expect(await _schluesselDa(a), isTrue);
      },
    );
  }

  group('Textskala 2.0, nur der Dialog (360 px)', () {
    testWidgets('Hinweis mit Schlüssel und Überall-Zeile', (tester) async {
      await _dialogAllein(
        tester,
        const E2eeState(status: E2eeStatus.bereit),
        ueberall: true,
      );
      expect(find.textContaining('Dein Schlüssel bleibt auf diesem Gerät'), findsOneWidget);
      expect(find.text('Abbrechen'), findsOneWidget);
      pruefeLayout(tester, 'Dialog 2.0 mit Hinweis');
    });

    testWidgets('Web mit Schlüssel: Hinweis auf "Gerät abgeben" für gemeinsam genutzte Computer', (tester) async {
      await _dialogAllein(tester, const E2eeState(status: E2eeStatus.bereit), web: true);
      expect(find.textContaining('Auf einem gemeinsam genutzten Computer nutze „Gerät abgeben“'), findsOneWidget);
      pruefeLayout(tester, 'Dialog 2.0 Web');
    });

    testWidgets('nicht im Web: kein Computer-Hinweis', (tester) async {
      await _dialogAllein(tester, const E2eeState(status: E2eeStatus.bereit));
      expect(find.textContaining('gemeinsam genutzten Computer'), findsNothing);
    });

    testWidgets('unbekannter Stand', (tester) async {
      await _dialogAllein(
        tester,
        const E2eeState(status: E2eeStatus.nichtVerfuegbar),
      );
      expect(
        find.textContaining('die App konnte ihn gerade nicht prüfen'),
        findsOneWidget,
      );
      pruefeLayout(tester, 'Dialog 2.0 unbekannt');
    });

    // Lücke L-5: ungesendete Änderungen im Ausgang gehen beim Abmelden verloren, darum nennt der Dialog die Anzahl und bietet das Synchronisieren an
    testWidgets('ungesendete Änderungen: Warnung mit Anzahl, "Erst synchronisieren" gleicht ab', (tester) async {
      final sync = _OffenSync(3);
      await _dialogAllein(tester, const E2eeState(status: E2eeStatus.bereit), extra: [syncProvider.overrideWith(() => sync)]);
      expect(find.textContaining('3 Änderungen'), findsOneWidget);
      expect(find.text('Erst synchronisieren'), findsOneWidget);
      expect(find.textContaining('Änderungen verwerfen'), findsOneWidget, reason: 'der Abmelden-Knopf sagt ehrlich, was passiert');
      pruefeLayout(tester, 'Dialog 2.0 mit ungesendeten Änderungen');
      sync.nachSync = 0;
      await tester.tap(find.text('Erst synchronisieren'));
      await tester.pumpAndSettle();
      expect(sync.synchronisiert, 1);
      expect(find.textContaining('noch nicht an den Server gesendet'), findsNothing, reason: 'nach dem Abgleich ist nichts mehr offen');
      expect(find.text('Erst synchronisieren'), findsNothing);
      expect(find.text('Abmelden'), findsOneWidget);
    });

    testWidgets('ohne ungesendete Änderungen: keine Warnung', (tester) async {
      await _dialogAllein(tester, const E2eeState(status: E2eeStatus.bereit));
      expect(find.textContaining('noch nicht an den Server gesendet'), findsNothing);
      expect(find.text('Erst synchronisieren'), findsNothing);
    });

    // G-2: vom Server abgelehnte Änderungen (Fehlercode im Ausgang) gehen beim Abmelden ebenfalls verloren und werden getrennt genannt
    testWidgets('abgelehnte Änderungen: getrennt genannt, kein "Erst synchronisieren", Knopf warnt', (tester) async {
      await _dialogAllein(tester, const E2eeState(status: E2eeStatus.bereit), abgelehnt: 2);
      expect(find.textContaining('2 nicht gesendete Nachrichten (Änderungen) mit Fehler'), findsOneWidget);
      expect(find.textContaining('noch nicht an den Server gesendet'), findsNothing);
      expect(find.text('Erst synchronisieren'), findsNothing, reason: 'ein Abgleich ändert an abgelehnten Änderungen nichts');
      expect(find.textContaining('Änderungen verwerfen'), findsOneWidget);
      pruefeLayout(tester, 'Dialog 2.0 mit abgelehnten Änderungen');
    });

    // G-3: der Zähler ist live: ändert sich der Ausgang bei geöffnetem Dialog (Abgleich im Hintergrund), folgt der Text ohne Schnappschuss
    testWidgets('der Zähler folgt dem Ausgang live', (tester) async {
      final sync = _OffenSync(2);
      await _dialogAllein(tester, const E2eeState(status: E2eeStatus.bereit), extra: [syncProvider.overrideWith(() => sync)]);
      expect(find.textContaining('2 Änderungen'), findsOneWidget);
      sync.setze(5);
      await tester.pumpAndSettle();
      expect(find.textContaining('5 Änderungen'), findsOneWidget);
      sync.setze(0);
      await tester.pumpAndSettle();
      expect(find.textContaining('noch nicht an den Server gesendet'), findsNothing);
      expect(find.text('Abmelden'), findsOneWidget, reason: 'ohne Verlust steht wieder der schlichte Knopf da');
    });

    // der längste Knopftext bei 360 px und Textskala 2.0
    testWidgets('"Überall abmelden (Änderungen verwerfen)": längster Knopftext ohne Layoutfehler', (tester) async {
      await _dialogAllein(
        tester,
        const E2eeState(status: E2eeStatus.bereit),
        ueberall: true,
        knopf: 'Überall abmelden',
        abgelehnt: 3,
        extra: [syncProvider.overrideWith(() => _OffenSync(12))],
      );
      expect(find.text('Überall abmelden (Änderungen verwerfen)'), findsOneWidget);
      expect(find.text('Erst synchronisieren'), findsOneWidget);
      expect(find.text('Abbrechen'), findsOneWidget);
      pruefeLayout(tester, 'Dialog 2.0 längster Knopf');
      expect(tester.takeException(), isNull);
    });
  });
}

/// Sync-Dienst mit festem Zähler offener Änderungen; der Abgleich setzt ihn auf [nachSync].
class _OffenSync extends SyncController {
  final int start;
  int nachSync = 0;
  int synchronisiert = 0;
  _OffenSync(this.start);

  @override
  SyncState build() => SyncState(offeneAenderungen: start);

  /// Der Ausgang ändert sich (wie über den Datenbank-Strom).
  void setze(int n) => state = state.copyWith(offeneAenderungen: n);

  @override
  Future<void> synchronisieren({bool manuell = false}) async {
    synchronisiert++;
    setze(nachSync);
  }
}
