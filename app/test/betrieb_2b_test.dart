// Betrieb, Paket 2b: Modelle (Familienstand, Hinweis, Konfiguration), die Wartungs-Antwort des Servers, Familienhinweis und Wartung als Banner an alle (Zustand: Abfrage, Wegklicken je Version,
// Ablauf, älterer Server), die Seite "Einstellungen" des Betreibers (Wartungsmodus mit Bestätigung und Step-up, Hinweis senden und löschen, Konfiguration nur lesend) und das Layout
// (360 px, Textskala 1.5/2.0, Touch-Ziele mindestens 44 px).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_error.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/betrieb/familien_hinweis_state.dart';
import 'package:lx_fampad/data/betrieb/familien_stand.dart';
import 'package:lx_fampad/features/auth/step_up.dart';
import 'package:lx_fampad/features/betrieb/betrieb_konfig_anzeige.dart';
import 'package:lx_fampad/widgets/familien_hinweis_banner.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Map<String, dynamic> _hinweis(String text, {String setAt = '2026-10-22T08:00:00.000Z', String? expiresAt}) => {'text': text, 'setAt': setAt, 'expiresAt': expiresAt};

Map<String, dynamic> _stand({bool wartung = false, String? bis, Map<String, dynamic>? hinweis}) => {
  'maintenance': {'active': wartung, 'since': wartung ? '2026-10-22T08:00:00.000Z' : null, 'until': wartung ? bis : null},
  'notice': hinweis,
};

Map<String, dynamic> _konfig() => {
  'groups': [
    {
      'id': 'switches',
      'items': [
        {'key': 'E2EE_PW_BACKUP', 'value': true},
        {'key': 'WEATHER_ENABLED', 'value': false},
        {'key': 'NTFY', 'value': true},
      ],
    },
    {
      'id': 'server',
      'items': [
        {'key': 'NODE_ENV', 'value': 'production'},
        {'key': 'PUBLIC_URL', 'value': 'https://familyhub.lx-labs.dev'},
        {'key': 'RATE_LIMIT_MAX', 'value': 300, 'unit': 'perMinute'},
        {'key': 'AUDIT_RETENTION_DAYS', 'value': 365, 'unit': 'd'},
      ],
    },
    {
      'id': 'location',
      'items': [
        {'key': 'LOC_MAX_DURATION_MS', 'value': 43200000, 'unit': 'ms'},
        {'key': 'LOC_MIN_INTERVAL_MS', 'value': 1000, 'unit': 'ms'},
        {'key': 'LOC_GRACE_MS', 'value': 90000, 'unit': 'ms'},
      ],
    },
    {
      'id': 'sync',
      'items': [
        {'key': 'SYNC_OPS_PER_DAY', 'value': 5000, 'unit': 'perDay'},
        {'key': 'NEU_VOM_SERVER', 'value': 7},
      ],
    },
  ],
};

/// Ein Zustand, der fest vorgegeben ist (für Tests des Banners ohne Server).
class _FesterHinweis extends FamilienHinweisNotifier {
  final FamilienStand _stand;
  _FesterHinweis(this._stand);

  @override
  FamilienHinweisZustand build() => FamilienHinweisZustand(stand: _stand);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modelle und Anzeige', () {
    test('Familienstand: Wartung und Hinweis; unbrauchbare Angaben ergeben keinen Hinweis (nie ein Absturz)', () {
      final s = FamilienStand.fromJson(_stand(wartung: true, bis: '2026-10-22T10:00:00.000Z', hinweis: _hinweis('  Samstag Wartung  ', expiresAt: '2026-10-25T00:00:00.000Z')));
      expect(s.wartung.aktiv, isTrue);
      expect(s.wartung.bis, DateTime.utc(2026, 10, 22, 10));
      expect(s.hinweis?.text, 'Samstag Wartung');
      expect(s.hinweis?.version, DateTime.utc(2026, 10, 22, 8));
      expect(s.hinweis?.ablauf, DateTime.utc(2026, 10, 25));
      for (final kaputt in <Object?>[null, 'text', 5, <String, dynamic>{}, _hinweis(''), _hinweis('   '), {'text': 'x', 'setAt': 'gestern'}, {'text': 5, 'setAt': '2026-10-22T08:00:00Z'}, _hinweis('x' * (kHinweisMaxZeichen + 1))]) {
        expect(FamilienHinweis.versuchen(kaputt), isNull, reason: '$kaputt');
      }
      expect(FamilienHinweis.versuchen(_hinweis('😀' * kHinweisMaxZeichen)), isNotNull, reason: 'Zeichen, nicht UTF-16-Einheiten');
      // ältere Server und Unsinn in den Teilen: keine Wartung, kein Hinweis; eine Antwort, die gar kein Objekt ist, ist ein Protokollfehler (die Zustände fangen ihn ab)
      expect(() => FamilienStand.fromJson('x'), throwsA(isA<ApiException>()));
      for (final leer in <Object?>[<String, dynamic>{}, {'maintenance': 'an', 'notice': 3}, {'maintenance': null, 'notice': 'x'}]) {
        final e = FamilienStand.fromJson(leer);
        expect(e.wartung.aktiv, isFalse);
        expect(e.hinweis, isNull);
      }
    });

    test('Konfiguration: Gruppen und Werte; Unbekanntes bleibt, Ungültiges fällt weg', () {
      final k = BetriebKonfiguration.fromJson(_konfig());
      expect(k.gruppen.map((g) => g.id), ['switches', 'server', 'location', 'sync']);
      expect(k.gruppen.first.werte.map((w) => w.key), ['E2EE_PW_BACKUP', 'WEATHER_ENABLED', 'NTFY']);
      final tolerant = BetriebKonfiguration.fromJson({
        'groups': [
          'kaputt',
          {'id': 'switches', 'items': ['x', {'key': ''}, {'key': 'A', 'value': 'y' * 200}, {'key': 'B', 'value': double.nan}, {'key': 'C', 'value': [1]}]},
          {'items': []},
        ],
      });
      expect(tolerant.gruppen, hasLength(1));
      expect(tolerant.gruppen.single.werte.map((w) => (w.key, w.wert)), [('A', null), ('B', null), ('C', null)]);
      expect(BetriebKonfiguration.fromJson(<String, dynamic>{}).gruppen, isEmpty);
      expect(() => BetriebKonfiguration.fromJson(null), throwsA(isA<ApiException>()));
    });

    test('Zahlenformate je Einheit; bekannte Namen deutsch, unbekannte unter ihrem Namen', () {
      String t(Object? v, [String? u]) => konfigWertText(KonfigWert(key: 'K', wert: v, einheit: u));
      expect(t(43200000, 'ms'), '12 Std.');
      expect(t(90000, 'ms'), '90 s');
      expect(t(1000, 'ms'), '1 s');
      expect(t(300000, 'ms'), '5 Min.');
      expect(t(500, 'ms'), '500 ms');
      expect(t(1500, 'ms'), '1.500 ms');
      expect(t(900, 's'), '15 Min.');
      expect(t(1, 'd'), '1 Tag');
      expect(t(365, 'd'), '365 Tage');
      expect(t(300, 'perMinute'), '300 / Min.');
      expect(t(100000, 'perDay'), '100.000 / Tag');
      expect(t(true), 'an');
      expect(t(false), 'aus');
      expect(t('production'), 'production');
      expect(t(null), 'unbekannt');
      expect(konfigNameText('E2EE_PW_BACKUP'), 'Passwort-Sicherung');
      expect(konfigNameText('NEU_VOM_SERVER'), 'NEU_VOM_SERVER');
      expect(konfigGruppeText('location'), 'Standort teilen');
      expect(konfigGruppeText('neu'), 'neu');
    });

    test('Wartungs-Antwort des Servers: eigener Zustand mit fester Meldung (nie der Servertext); andere 503 bleiben "ausgelastet"', () {
      final w = ApiException.vonAntwort(status: 503, code: 'maintenance', retryAfterSekunden: 60);
      expect(w.kind, ApiErrorKind.wartung);
      expect(w.message, kWartungMeldung);
      expect(w.message, contains('Wartung'));
      expect(w.retryAfter, const Duration(seconds: 60));
      expect(w.istNetzwerk, isFalse);
      expect(ApiException.vonAntwort(status: 503, code: 'server_busy').kind, ApiErrorKind.serverBusy);
      expect(ApiException.vonAntwort(status: 503, code: '').kind, ApiErrorKind.serverBusy);
    });

    test('Endezeit: heute nur mit Uhrzeit, sonst mit Datum', () {
      final jetzt = DateTime(2026, 10, 22, 9);
      expect(endeText(DateTime(2026, 10, 22, 14, 30), jetzt), 'heute 14:30');
      expect(endeText(DateTime(2026, 10, 23, 8, 5), jetzt), '23. Okt., 08:05');
    });
  });

  group('Zustand: Hinweis und Wartung auf dem Gerät', () {
    late TestUmgebung env;
    late ProviderContainer c;

    Future<void> bauen({Object Function()? stand, bool alt = false}) async {
      env = await angemeldeteUmgebung();
      if (!alt) env.server.on('GET /family-notice', (_) => jsonAntwort(stand == null ? _stand() : stand()));
      c = env.container();
      addTearDown(c.dispose);
      // der Zustand hängt an der angemeldeten Person (und der gemerkte Stand an ihrer Kennung)
      await c.read(authProvider.notifier).start();
      expect(c.read(authProvider).user?.id, fixIdAdmin);
    }

    test('Abfrage: Wartung und Hinweis erscheinen; ohne Abfrage ist nichts da', () async {
      await bauen(stand: () => _stand(wartung: true, hinweis: _hinweis('Hallo')));
      expect(c.read(familienHinweisProvider).stand, isNull);
      expect(c.read(familienHinweisProvider).wartung, isFalse);
      await c.read(familienHinweisProvider.notifier).starten();
      final z = c.read(familienHinweisProvider);
      expect(z.wartung, isTrue);
      expect(z.sichtbar(DateTime.utc(2026, 10, 22, 9))?.text, 'Hallo');
    });

    test('Wegklicken gilt je Version und bleibt gemerkt; ein neu gesetzter Hinweis erscheint wieder', () async {
      var aktuell = _hinweis('Erster', setAt: '2026-10-22T08:00:00.000Z');
      await bauen(stand: () => _stand(hinweis: aktuell));
      final n = c.read(familienHinweisProvider.notifier);
      await n.starten();
      final jetzt = DateTime.utc(2026, 10, 22, 9);
      expect(c.read(familienHinweisProvider).sichtbar(jetzt)?.text, 'Erster');
      await n.schliessen();
      expect(c.read(familienHinweisProvider).sichtbar(jetzt), isNull);
      expect(await env.db.metaLesen(hinweisGeschlossenSchluessel(fixIdAdmin)), '2026-10-22T08:00:00.000Z');
      expect(await env.db.metaLesen(kHinweisGeschlossenSchluessel), isNull, reason: 'je Person ein eigener Schlüssel');
      // die Abfrage bringt denselben Hinweis wieder: er bleibt weg
      await n.laden();
      expect(c.read(familienHinweisProvider).sichtbar(jetzt), isNull);
      // neu gesetzt (spätere Version): erscheint wieder
      aktuell = _hinweis('Zweiter', setAt: '2026-10-22T08:30:00.000Z');
      await n.laden();
      expect(c.read(familienHinweisProvider).sichtbar(jetzt)?.text, 'Zweiter');
    });

    test('der gemerkte Stand gilt nach einem Neustart (Start liest die Ablage)', () async {
      await bauen(stand: () => _stand(hinweis: _hinweis('Alt')));
      await env.db.metaSchreiben(hinweisGeschlossenSchluessel(fixIdAdmin), '2026-10-22T08:00:00.000Z');
      await c.read(familienHinweisProvider.notifier).starten();
      expect(c.read(familienHinweisProvider).sichtbar(DateTime.utc(2026, 10, 22, 9)), isNull);
    });

    test('geteiltes Gerät: was eine andere Person weggeklickt hat, blendet den Hinweis nicht für diese Person aus', () async {
      await bauen(stand: () => _stand(hinweis: _hinweis('Für alle')));
      await env.db.metaSchreiben(hinweisGeschlossenSchluessel('u-andere-person'), '2026-10-22T08:00:00.000Z');
      await env.db.metaSchreiben(kHinweisGeschlossenSchluessel, '2026-10-22T08:00:00.000Z'); // der alte Schlüssel ohne Person gilt nicht mehr
      await c.read(familienHinweisProvider.notifier).starten();
      expect(c.read(familienHinweisProvider).sichtbar(DateTime.utc(2026, 10, 22, 9))?.text, 'Für alle');
    });

    test('Personenwechsel während einer Abfrage: die späte Antwort der vorigen Person ändert den neuen Zustand nicht, der Lauf ist zurückgesetzt', () async {
      final antwort = Completer<void>();
      await bauen(stand: () => _stand(hinweis: _hinweis('Alt')));
      env.server.on('GET /family-notice', (_) async {
        await antwort.future;
        return jsonAntwort(_stand(hinweis: _hinweis('Spät')));
      });
      final lauf = c.read(familienHinweisProvider.notifier).laden();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.invalidate(familienHinweisProvider); // Personenwechsel: der Zustand wird neu aufgebaut
      expect(c.read(familienHinweisProvider).stand, isNull);
      antwort.complete();
      await lauf;
      expect(c.read(familienHinweisProvider).stand, isNull, reason: 'die Antwort der vorigen Person wird verworfen');
      // und der neue Zustand fragt wieder (kein hängengebliebener "läuft"-Zustand)
      env.server.on('GET /family-notice', (_) => jsonAntwort(_stand(hinweis: _hinweis('Neu'))));
      await c.read(familienHinweisProvider.notifier).laden();
      expect(c.read(familienHinweisProvider).stand?.hinweis?.text, 'Neu');
    });

    test('Ablauf: nach dem Ablaufzeitpunkt ist der Hinweis weg, auch ohne neue Abfrage; Wartung ist nicht wegklickbar', () async {
      await bauen(stand: () => _stand(wartung: true, hinweis: _hinweis('Kurz', expiresAt: '2026-10-22T10:00:00.000Z')));
      await c.read(familienHinweisProvider.notifier).starten();
      final z = c.read(familienHinweisProvider);
      expect(z.sichtbar(DateTime.utc(2026, 10, 22, 9, 59))?.text, 'Kurz');
      expect(z.sichtbar(DateTime.utc(2026, 10, 22, 10)), isNull);
      await c.read(familienHinweisProvider.notifier).schliessen();
      expect(c.read(familienHinweisProvider).wartung, isTrue);
    });

    test('älterer Server (404) oder Fehler: der letzte Stand bleibt, nie eine Ausnahme', () async {
      await bauen(alt: true);
      await c.read(familienHinweisProvider.notifier).starten();
      expect(c.read(familienHinweisProvider).stand, isNull);
      var kaputt = false;
      env.server.on('GET /family-notice', (_) => kaputt ? fehler(500, 'internal_error') : jsonAntwort(_stand(hinweis: _hinweis('Bleibt'))));
      await c.read(familienHinweisProvider.notifier).laden();
      expect(c.read(familienHinweisProvider).stand?.hinweis?.text, 'Bleibt');
      kaputt = true;
      await c.read(familienHinweisProvider.notifier).laden();
      expect(c.read(familienHinweisProvider).stand?.hinweis?.text, 'Bleibt');
    });
  });

  // ------------------------------------------------------------------------------------------------------------------------ Oberfläche

  Future<TestUmgebung> start(
    WidgetTester tester, {
    bool betreiber = true,
    bool oeffnen = true,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    Map<String, dynamic> Function()? stand,
    void Function(TestUmgebung env)? vorStart,
  }) async {
    final env = await angemeldeteUmgebung();
    var aktuell = _stand();
    env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': betreiber});
    env.server.on('GET /family-notice', (_) => jsonAntwort(stand == null ? aktuell : stand()));
    env.server.on('GET /admin/settings', (_) => jsonAntwort(stand == null ? aktuell : stand()));
    env.server.on('GET /admin/config', (_) => jsonAntwort(_konfig()));
    env.server.on('GET /admin/status', (_) => fehler(500, 'internal_error'));
    env.server.on('GET /admin/audit', (_) => jsonAntwort({'items': <Object>[], 'nextCursor': null}));
    env.server.on('GET /admin/key-status', (_) => fehler(404, 'not_found'));
    env.server.on('GET /admin/members', (_) => fehler(403, 'step_up_required'));
    env.server.json('GET /admin/warnings', {'enabled': true, 'pushAvailable': true, 'checkedAt': null, 'lastNotifiedAt': null, 'active': <Object>[]});
    // Schalten antwortet mit dem neuen Stand und merkt ihn für die nächsten Abfragen
    var bestaetigt = true;
    env.server.json('POST /auth/step-up/passkey/options', {'challengeId': 'c1', 'options': {'challenge': 'abc'}});
    env.server.on('POST /auth/step-up/passkey/verify', (_) {
      bestaetigt = true;
      return jsonAntwort({'stepUpAt': DateTime.now().toUtc().toIso8601String()});
    });
    env.server.on('PUT /admin/maintenance', (r) {
      if (!bestaetigt) return fehler(403, 'step_up_required');
      final an = r.json['active'] == true;
      final minuten = r.json['untilMinutes'] as int? ?? 72 * 60;
      aktuell = _stand(wartung: an, bis: DateTime.now().toUtc().add(Duration(minutes: minuten)).toIso8601String(), hinweis: aktuell['notice'] as Map<String, dynamic>?);
      return jsonAntwort(aktuell);
    });
    env.server.on('PUT /admin/notice', (r) {
      if (!bestaetigt) return fehler(403, 'step_up_required');
      final text = r.json['text'] as String?;
      aktuell = _stand(
        wartung: (aktuell['maintenance'] as Map<String, dynamic>)['active'] == true,
        hinweis: text == null
            ? null
            : _hinweis(
                text.trim(),
                setAt: DateTime.now().toUtc().toIso8601String(),
                expiresAt: r.json['expiresInMinutes'] == null ? null : DateTime.now().toUtc().add(Duration(minutes: r.json['expiresInMinutes'] as int)).toIso8601String(),
              ),
      );
      return jsonAntwort(aktuell);
    });
    // das erste Schalten verlangt die Bestätigung
    bestaetigt = false;
    vorStart?.call(env);
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (oeffnen) {
      if (groesse.width >= 900) {
        await tippe(tester, find.text('Betrieb').last);
      } else {
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippe(tester, find.text('Betrieb').last);
      }
      await tippe(tester, find.text('Einstellungen').last);
    }
    return env;
  }

  /// Tippt ein Element, das vorher in die Mitte der Seite gescrollt wird (am oberen Rand läge es unter der Kopfzeile der Seite).
  Future<void> mitte(WidgetTester tester, Finder f) async {
    await Scrollable.ensureVisible(tester.element(f.first), alignment: 0.5);
    await warte(tester);
    await tester.tap(f.first);
    await warte(tester);
  }

  Future<void> zu(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 250, scrollable: find.byType(Scrollable).first);
    await warte(tester);
  }

  group('Banner für alle', () {
    testWidgets('Familienhinweis erscheint für jede Person, lässt sich wegklicken und bleibt gemerkt', (tester) async {
      final env = await start(tester, betreiber: false, oeffnen: false, stand: () => _stand(hinweis: _hinweis('Samstag ist Wartung, plant bitte um.')));
      expect(find.text('Samstag ist Wartung, plant bitte um.'), findsOneWidget);
      expect(find.byType(FamilienHinweisBanner), findsOneWidget);
      // fester Absender über dem Text: der Hinweis ist klar der Text des Betreibers
      expect(labelFinder('Hinweis des Betreibers'), findsOneWidget);
      await tippe(tester, find.byTooltip('Hinweis schließen'));
      expect(find.text('Samstag ist Wartung, plant bitte um.'), findsNothing);
      expect(await env.db.metaLesen(hinweisGeschlossenSchluessel(fixIdAdmin)), isNotNull);
      pruefeLayout(tester, 'nach dem Wegklicken');
    });

    testWidgets('Wartung: fester Text, mit Ende, nicht wegklickbar; zusammen mit einem Hinweis zwei Banner', (tester) async {
      final bis = DateTime.now().toUtc().add(const Duration(hours: 2)).toIso8601String();
      await start(tester, betreiber: false, oeffnen: false, stand: () => _stand(wartung: true, bis: bis, hinweis: _hinweis('Kurze Pause')));
      expect(find.textContaining('Wartung bis '), findsOneWidget);
      // Wartung und Hinweis tragen verschiedene feste Kennzeichen
      expect(labelFinder('Wartung'), findsOneWidget);
      expect(labelFinder('Hinweis des Betreibers'), findsOneWidget);
      expect(find.textContaining('Änderungen bleiben auf deinem Gerät'), findsOneWidget);
      expect(find.text('Kurze Pause'), findsOneWidget);
      // nur der Hinweis hat einen Schließen-Knopf
      expect(find.byTooltip('Hinweis schließen'), findsOneWidget);
    });

    testWidgets('ohne Hinweis und ohne Wartung: kein Banner', (tester) async {
      await start(tester, betreiber: false, oeffnen: false);
      expect(find.byType(FamilienHinweisBanner), findsOneWidget);
      expect(find.byIcon(Icons.campaign_outlined), findsNothing);
      expect(find.byIcon(Icons.build_outlined), findsNothing);
    });

    testWidgets('älterer Server (404 auf /family-notice): kein Banner, keine Fehlermeldung', (tester) async {
      await start(tester, betreiber: false, oeffnen: false, vorStart: (env) => env.server.on('GET /family-notice', (_) => fehler(404, 'not_found')));
      expect(find.byIcon(Icons.campaign_outlined), findsNothing);
      expect(find.byIcon(Icons.build_outlined), findsNothing);
    });

    for (final skala in [1.0, 1.5]) {
      testWidgets('360 px, Textskala  (in der App): langer Hinweis plus Wartung laufen nicht über, Touch-Ziele mindestens 44 px', (tester) async {
        await start(
          tester,
          betreiber: false,
          oeffnen: false,
          skala: skala,
          stand: () => _stand(wartung: true, hinweis: _hinweis('Wir ziehen am Samstag auf einen neuen Server um. Von 9 bis 12 Uhr geht nichts, danach läuft alles wie vorher. ' * 2)),
        );
        pruefeLayout(tester, 'Banner ');
        expect(find.byIcon(Icons.build_outlined), findsOneWidget);
      });
    }

    // Die Navigationsleiste der App läuft bei 2.0 über (nicht Teil dieses Pakets): der Banner allein wird deshalb ohne sie geprüft
    for (final skala in [1.5, 2.0]) {
      testWidgets('360 px, Textskala  (Banner allein): sehr langer Hinweis scrollt im Banner, nichts läuft über', (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = skala;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final stand = FamilienStand.fromJson(_stand(wartung: true, bis: DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(), hinweis: _hinweis('Langer Text zum Umzug. ' * 12)));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [familienHinweisProvider.overrideWith(() => _FesterHinweis(stand))],
            child: const MaterialApp(home: Scaffold(body: SafeArea(child: Column(children: [FamilienHinweisBanner(), Expanded(child: SizedBox.shrink())])))),
          ),
        );
        await warte(tester);
        pruefeLayout(tester, 'Banner allein ');
        // höchstens ein Drittel der Höhe je Banner
        expect(tester.getSize(find.byType(FamilienHinweisBanner)).height, lessThan(800 * 0.75));
      });
    }

    testWidgets('Desktop 1440 px: der Banner steht über dem Inhalt, Seitenleiste und Fußzeile bleiben', (tester) async {
      await start(tester, betreiber: false, oeffnen: false, groesse: const Size(1440, 900), stand: () => _stand(hinweis: _hinweis('Hallo Familie')));
      expect(find.text('Hallo Familie'), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.text('Version dev'), findsOneWidget);
      pruefeLayout(tester, 'Desktop-Banner');
    });
  });

  group('Einstellungen des Betreibers', () {
    testWidgets('Seite: Wartung aus, kein Hinweis, Konfiguration mit deutschen Namen und Werten; beim Öffnen nur lesen', (tester) async {
      final env = await start(tester);
      expect(labelFinder('Wartungsmodus'), findsOneWidget);
      expect(find.text('aus'), findsWidgets);
      expect(find.text('Zurzeit ist kein Hinweis gesetzt.'), findsOneWidget);
      await zu(tester, labelFinder('Konfiguration'));
      await zu(tester, find.text('Passwort-Sicherung'));
      expect(find.text('E2EE_PW_BACKUP'), findsOneWidget);
      await zu(tester, find.text('12 Std.'));
      expect(find.text('Längste Freigabe'), findsOneWidget);
      await zu(tester, find.text('300 / Min.'));
      await zu(tester, find.text('NEU_VOM_SERVER'));
      expect(find.text('Die Konfiguration steht in der Datei', skipOffstage: false), findsNothing);
      expect(find.textContaining('nie Schlüssel, Token oder Passwörter'), findsOneWidget);
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
    });

    testWidgets('Wartung einschalten: Rückfrage, Ende wählbar, Step-up, dann PUT mit Ende; danach "Wartung läuft" und der Banner', (tester) async {
      final env = await start(tester);
      // kein "ohne Ende" mehr: die Wartung hat immer ein Ende, vorgewählt sind 4 Stunden
      expect(find.text('Ohne Ende'), findsNothing);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '4 Std.')).selected, isTrue);
      await tippe(tester, find.text('24 Std.'));
      await tippe(tester, find.text('Wartung einschalten'));
      // Rückfrage mit Abbrechen: nichts geschieht
      expect(find.text('Wartungsmodus einschalten?'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(env.server.anfragen('PUT /admin/maintenance'), isEmpty);
      await tippe(tester, find.text('Wartung einschalten'));
      await tippe(tester, find.text('Einschalten'));
      expect(find.byType(StepUpDialog), findsOneWidget);
      await tippe(tester, find.text('Mit Passkey bestätigen'));
      final puts = env.server.anfragen('PUT /admin/maintenance');
      expect(puts, hasLength(2), reason: 'erst abgelehnt (Step-up nötig), nach der Bestätigung noch einmal');
      final body = puts.last.json;
      expect(body, {'active': true, 'untilMinutes': 24 * 60}, reason: 'die Dauer geht an den Server (er rechnet das Ende mit seiner Uhr), keine Uhrzeit vom Gerät');
      expect(find.text('Wartung läuft'), findsOneWidget);
      expect(find.text('Wartung beenden'), findsOneWidget);
      // der eigene Banner (hinter der Seite) holt den Stand sofort neu
      expect(env.server.anfragen('GET /family-notice').length, greaterThanOrEqualTo(2));
    });

    testWidgets('Wartung: Standard 4 Stunden, 72 Stunden wählbar; beenden sendet active=false und keine Dauer', (tester) async {
      final env = await start(tester, vorStart: (env) => env.server.json('GET /admin/settings', _stand(wartung: true, bis: null)));
      // läuft schon: nur "beenden"
      expect(find.text('Wartung läuft'), findsOneWidget);
      expect(find.text('ohne Ende'), findsOneWidget);
      await tippe(tester, find.text('Wartung beenden'));
      await tippe(tester, find.text('Mit Passkey bestätigen'));
      expect(env.server.anfragen('PUT /admin/maintenance').last.json, {'active': false});
      expect(find.text('aus'), findsWidgets);
      // wieder an: die vorgewählten 4 Stunden, danach 72 Stunden
      await tippe(tester, find.text('Wartung einschalten'));
      await tippe(tester, find.text('Einschalten'));
      expect(env.server.anfragen('PUT /admin/maintenance').last.json, {'active': true, 'untilMinutes': 240});
      await tippe(tester, find.text('Wartung beenden'));
      await tippe(tester, find.text('72 Std.'));
      await tippe(tester, find.text('Wartung einschalten'));
      await tippe(tester, find.text('Einschalten'));
      expect(env.server.anfragen('PUT /admin/maintenance').last.json, {'active': true, 'untilMinutes': 72 * 60});
    });

    testWidgets('Hinweis senden: leerer Text wird nicht gesendet, Umbrüche fallen weg, Ablauf wählbar; danach sichtbar, Eingabe leer; löschen', (tester) async {
      final env = await start(tester);
      await zu(tester, find.text('Hinweis senden'));
      await mitte(tester, find.text('Hinweis senden'));
      expect(find.text('Bitte gib einen Text ein.'), findsOneWidget);
      expect(env.server.anfragen('PUT /admin/notice'), isEmpty);
      await tester.enterText(find.byType(TextField), 'Zeile eins\nZeile zwei');
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Zeile einsZeile zwei');
      await tester.enterText(find.byType(TextField), '  Server-Umzug am Samstag  ');
      await mitte(tester, find.text('7 Tage'));
      await mitte(tester, find.text('Hinweis senden'));
      await tippe(tester, find.text('Mit Passkey bestätigen'));
      final put = env.server.anfragen('PUT /admin/notice').last.json;
      expect(put, {'text': 'Server-Umzug am Samstag', 'expiresInMinutes': 7 * 24 * 60}, reason: 'getrimmt, der Ablauf als Dauer (der Server rechnet mit seiner Uhr)');
      expect(find.text('sichtbar'), findsOneWidget);
      expect(find.text('Hinweis löschen'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      // löschen
      await mitte(tester, find.text('Hinweis löschen'));
      expect(env.server.anfragen('PUT /admin/notice').last.json, {'text': null});
      expect(find.text('Zurzeit ist kein Hinweis gesetzt.'), findsOneWidget);
    });

    for (final (code, text) in [
      ('invalid_request', 'Die Eingabe ist nicht gültig. Bitte prüfe sie.'),
      ('invalid_notice', 'Der Hinweis ist nicht gültig: 1 bis 280 Zeichen in einer Zeile, ohne Sonderzeichen.'),
      ('notice_link', 'Der Hinweis darf keine Links oder Webadressen enthalten.'),
      ('invalid_duration', 'Die gewählte Dauer ist nicht gültig. Bitte wähle sie noch einmal.'),
    ]) {
      testWidgets('Fehler des Servers $code: klare deutsche Meldung, kein Servertext', (tester) async {
        await start(tester, vorStart: (env) => env.server.on('PUT /admin/notice', (_) => fehler(400, code)));
        await zu(tester, find.text('Hinweis senden'));
        await tester.enterText(find.byType(TextField), 'Text');
        await mitte(tester, find.text('Hinweis senden'));
        expect(find.text(text), findsOneWidget);
      });
    }

    testWidgets('älterer Server (404): ruhiger Hinweis statt Fehler, die anderen Seiten bleiben benutzbar', (tester) async {
      await start(
        tester,
        vorStart: (env) {
          env.server.on('GET /admin/settings', (_) => fehler(404, 'not_found'));
          env.server.on('GET /admin/config', (_) => fehler(404, 'not_found'));
        },
      );
      expect(find.text('Dieser Server kennt das noch nicht (älterer Stand).'), findsNWidgets(3));
      await tippe(tester, find.text('Protokoll'));
      expect(labelFinder('Audit-Protokoll'), findsOneWidget);
    });

    testWidgets('Nicht-Betreiber sehen den Bereich nicht und die Seite fragt nie /admin', (tester) async {
      final env = await start(tester, betreiber: false, oeffnen: false);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      expect(find.text('Betrieb'), findsNothing);
      expect(env.server.log.where((r) => r.path.startsWith('/admin/config') || r.path.startsWith('/admin/settings')), isEmpty);
    });
  });

  group('Layout der Einstellungen', () {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: Einstellungen laufen nicht über, Touch-Ziele mindestens 44 px', (tester) async {
        // erst bei normaler Schrift zur Seite, dann vergrößern (die Startseite und das Profil laufen bei 2.0 über: nicht Teil dieses Pakets)
        await start(tester, oeffnen: false, stand: () => _stand(wartung: true, hinweis: _hinweis('Server-Umzug am Samstag, danach läuft alles schneller.')));
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippe(tester, find.text('Betrieb').last);
        await tippe(tester, find.text('Einstellungen'));
        tester.platformDispatcher.textScaleFactorTestValue = skala;
        await warte(tester);
        tester.takeException();
        pruefeLayout(tester, 'Einstellungen oben $skala');
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
          await warte(tester);
          pruefeLayout(tester, 'Einstellungen $i $skala');
        }
      });
    }

    testWidgets('Desktop 1440 px: Einstellungen in der Shell', (tester) async {
      await start(tester, groesse: const Size(1440, 900));
      expect(labelFinder('Wartungsmodus'), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      pruefeLayout(tester, 'Betrieb Einstellungen Desktop');
    });
  });
}
