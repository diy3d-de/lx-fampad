// Wetter-Hinweise bei geschlossener App: Hintergrund-Start nach einem Wecker holt GET /weather, wertet lokal aus und zeigt die neutrale Benachrichtigung
// (Entprellung, abgelaufenes Token einmal erneuert, offline/Fehler/Sitzung verloren in der Diagnose, Wandtablet schweigt), Meldung der Schalter an den
// Server und die Texte der Einstellungsseite. Echter Hintergrund-Container (ApiClient ohne eigenes Erneuern) gegen den Fake-Server.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart' show ChatAnzeigePort;
import 'package:lx_fampad/data/push/chat_benachrichtiger_provider.dart' show chatAnzeigePortProvider;
import 'package:lx_fampad/data/push/push_hintergrund.dart' show pushHintergrundStarten;
import 'package:lx_fampad/data/push/push_state.dart';
import 'package:lx_fampad/data/push/push_wecker.dart';
import 'package:lx_fampad/data/standort/standort_hinweis.dart';
import 'package:lx_fampad/data/wandtablet/wandtablet_einstellungen.dart';
import 'package:lx_fampad/data/wetter/wetter_hintergrund.dart';
import 'package:lx_fampad/data/wetter/wetter_hinweise.dart';
import 'package:lx_fampad/data/wetter/wetter_logik.dart' show WetterHinweisArt;
import 'package:lx_fampad/data/wetter/wetter_meldung.dart';
import 'package:lx_fampad/data/wetter/wetter_state.dart';

import 'support/fake_push.dart';
import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

class _Anzeige implements ChatAnzeigePort {
  final gezeigt = <({int id, String titel, String text, String nutzlast})>[];
  bool erlaubt = true;
  @override
  Future<bool> initialisieren() async => erlaubt;
  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async => true;
  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async {
    if (!erlaubt) return false;
    gezeigt.add((id: id, titel: titel, text: text, nutzlast: nutzlast));
    return true;
  }

  @override
  Future<void> entfernen(int id) async {}
}

class _Ereignisse implements EreignisBenachrichtiger {
  @override
  Future<void> neueEreignisse(int rev, {required int vorher}) async {}
}

Map<String, dynamic> _antwort({double temp = 12.5, bool stale = false, bool verfuegbar = true}) => verfuegbar
    ? {
        'available': true,
        'place': 'Westerburg',
        'current': {
          'measuredAt': DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
          'stale': stale,
          'temperature': temp,
          'humidity': 71,
          'pressure': 1013.2,
          'rain1h': 0.0,
          'rain24h': 0.0,
          'windKmh': 12,
          'gustKmh': 25,
          'windAngle': 270,
        },
        'min24h': 3.0,
        'max24h': 18.5,
        'series': <Object>[],
      }
    : {'available': false};

StoredTokens _abgelaufen() => StoredTokens(
  accessToken: 'alt',
  accessExpiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
  refreshToken: 'refresh-1',
  refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
  deviceId: fixDevice,
);

Future<void> ruhe([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  late TestUmgebung env;
  late _Anzeige anzeige;
  late ProviderContainer c;
  var anfragen = 0;
  Object? Function() wetter = _antwort;

  ProviderContainer hinter() => ProviderContainer(overrides: [...env.overrides, chatAnzeigePortProvider.overrideWithValue(anzeige)]);

  /// Container wie der Hintergrund-Start (ApiClient mit hintergrundErneuern, ohne eigenes Erneuern der Sitzung).
  Future<void> bau() async {
    env = await angemeldeteUmgebung();
    env
      ..refreshErlaubt = false
      ..hintergrundErneuern = true;
    anzeige = _Anzeige();
    anfragen = 0;
    wetter = _antwort;
    env.server.on('GET /weather', (_) {
      anfragen++;
      final w = wetter();
      return w is Map<String, dynamic> ? jsonAntwort(w) : fehler(500, 'x');
    });
    c = hinter();
    addTearDown(c.dispose);
  }

  Future<String?> diag() async => StandortDiagnoseEintrag.lesen(await env.db.metaLesen(kDiagWetter))?.code;
  Future<void> pruefen({Duration abstand = Duration.zero}) => c.read(wetterHintergrundPrueferProvider).pruefen(mindestAbstand: abstand);

  group('Hintergrund-Prüfung', () {
    test('Frost: GET /weather, lokale Benachrichtigung neutral mit Nutzlast wetter, Diagnose gezeigt, Stand im Offline-Speicher', () async {
      await bau();
      wetter = () => _antwort(temp: 1.4);
      await pruefen();
      expect(anfragen, 1);
      expect(anzeige.gezeigt, hasLength(1));
      final g = anzeige.gezeigt.single;
      expect(g.titel, 'Wetter');
      expect(g.text, 'Frostwarnung: 1,4 °C');
      expect(g.nutzlast, 'wetter');
      expect(g.text, isNot(contains('Westerburg')));
      expect(await diag(), 'gezeigt');
      expect(await env.db.metaLesen(kWetterCacheSchluessel), isNotNull);
    });

    test('Entprellung: dieselbe Art höchstens alle 6 Stunden, auch wenn der Abstand zwischen den Abrufen keine Rolle spielt', () async {
      await bau();
      wetter = () => _antwort(temp: -3);
      await pruefen();
      await pruefen();
      expect(anfragen, 2);
      expect(anzeige.gezeigt, hasLength(1));
      expect(await diag(), 'schon_gemeldet');
      // nach 6 Stunden wieder
      await env.db.metaSchreiben(WetterHinweisArt.frost.zuletztSchluessel, DateTime.now().subtract(const Duration(hours: 7)).millisecondsSinceEpoch.toString());
      await pruefen();
      expect(anzeige.gezeigt, hasLength(2));
    });

    test('Abruf vor weniger als 10 Minuten (App oder früherer Lauf): kein Netzzugriff', () async {
      await bau();
      wetter = () => _antwort(temp: 0);
      await pruefen(abstand: const Duration(minutes: 10));
      expect(anfragen, 1);
      await pruefen(abstand: const Duration(minutes: 10));
      expect(anfragen, 1);
      expect(await diag(), 'kurz_her');
    });

    test('alle Arten aus: kein Netzzugriff, Diagnose aus', () async {
      await bau();
      await env.db.metaSchreiben(WetterHinweisArt.frost.schluessel, 'nein');
      await pruefen();
      expect(anfragen, 0);
      expect(await diag(), 'aus');
    });

    test('Wandtablet-Betrieb (Modus offen oder automatischer Start an): keine Benachrichtigung, kein Abruf', () async {
      await bau();
      wetter = () => _antwort(temp: -5);
      await env.db.metaSchreiben(kWandAutostartSchluessel, 'ja');
      await pruefen();
      expect(anfragen, 0);
      expect(anzeige.gezeigt, isEmpty);
      expect(await diag(), 'wandtablet');
      await env.db.metaSchreiben(kWandAutostartSchluessel, 'nein');
      c.read(wandtabletLaeuftProvider.notifier).setzen(true);
      await pruefen();
      expect(anfragen, 0);
      expect(await diag(), 'wandtablet');
      c.read(wandtabletLaeuftProvider.notifier).setzen(false);
      await pruefen();
      expect(anzeige.gezeigt, hasLength(1));
    });

    test('veraltete Messung warnt nie; ohne Wetter auf dem Server: Diagnose nicht_verfuegbar', () async {
      await bau();
      wetter = () => _antwort(temp: -5, stale: true);
      await pruefen();
      expect(anzeige.gezeigt, isEmpty);
      expect(await diag(), 'ok');
      wetter = () => _antwort(verfuegbar: false);
      await pruefen();
      expect(await diag(), 'nicht_verfuegbar');
    });

    test('abgelaufenes Zugangstoken wird genau einmal erneuert, danach läuft der Abruf mit dem neuen Token', () async {
      await bau();
      await env.store.writeTokens(_abgelaufen());
      env.server.on('POST /auth/refresh', (r) => r.json['refreshToken'] == 'refresh-1' ? jsonAntwort({'session': appSession(access: 'access-2', refresh: 'refresh-2')}) : fehler(401, 'invalid_token'));
      wetter = () => _antwort(temp: 0.5);
      await pruefen();
      expect(env.server.anfragen('POST /auth/refresh'), hasLength(1));
      expect(env.server.anfragen('GET /weather').single.headers['authorization'], 'Bearer access-2');
      expect(await diag(), 'gezeigt');
      expect((await env.store.readTokens())!.refreshToken, 'refresh-2');
    });

    test('Erneuern abgelehnt: Diagnose sitzung_verloren, keine Benachrichtigung, kein zweiter Versuch', () async {
      await bau();
      await env.store.writeTokens(_abgelaufen());
      env.server.on('POST /auth/refresh', (_) => fehler(401, 'invalid_token'));
      await pruefen();
      expect(env.server.anfragen('POST /auth/refresh'), hasLength(1));
      expect(anfragen, 0);
      expect(anzeige.gezeigt, isEmpty);
      expect(await diag(), 'sitzung_verloren');
    });

    test('offline und Serverfehler schreiben eine Diagnose, nie eine Benachrichtigung', () async {
      await bau();
      env.server.on('GET /weather', (_) => throw const SocketException('kein Netz'));
      await pruefen();
      expect(await diag(), 'offline');
      env.server.on('GET /weather', (_) => fehler(500, 'x'));
      await pruefen();
      expect(await diag(), 'fehler');
      expect(anzeige.gezeigt, isEmpty);
    });

    test('keine Android-Erlaubnis: Diagnose keine_erlaubnis, Art bleibt ungemeldet (kommt beim nächsten Mal noch einmal)', () async {
      await bau();
      anzeige.erlaubt = false;
      wetter = () => _antwort(temp: 0);
      await pruefen();
      expect(await diag(), 'keine_erlaubnis');
      expect(await env.db.metaLesen(WetterHinweisArt.frost.zuletztSchluessel), isNull);
      anzeige.erlaubt = true;
      await pruefen();
      expect(anzeige.gezeigt, hasLength(1));
    });

    test('Wecker -> Hintergrund-Start: Sync, Wetterabruf und Benachrichtigung in einem Lauf', () async {
      await bau();
      wetter = () => _antwort(temp: -2);
      final bg = FakePush();
      final lauf = await pushHintergrundStarten(
        plattform: bg,
        containerFabrik: hinter,
        ereignisse: _Ereignisse(),
        abstand: const Duration(milliseconds: 20),
      );
      bg.wecker();
      await ruhe(400);
      expect(anfragen, 1);
      expect(anzeige.gezeigt.map((g) => g.text), ['Frostwarnung: -2,0 °C']);
      expect(StandortDiagnoseEintrag.lesen(await env.db.metaLesen(kDiagWetter))?.code, 'gezeigt');
      lauf!.beenden();
    });

    test('Diagnose-Texte sind feste Sätze', () {
      for (final code in ['aus', 'wandtablet', 'kurz_her', 'nicht_verfuegbar', 'offline', 'sitzung_verloren', 'fehler', 'gezeigt', 'schon_gemeldet', 'keine_erlaubnis', 'ok']) {
        expect(standortDiagnoseText(code), isNot(code), reason: code);
      }
    });
  });

  group('Meldung der Schalter an den Server', () {
    late FakePush fake;
    final bodies = <Map<String, dynamic>>[];

    Future<void> start({bool wetterDa = true}) async {
      env = await angemeldeteUmgebung();
      bodies.clear();
      env.server
        ..on('GET /weather', (_) => jsonAntwort(_antwort(verfuegbar: wetterDa)))
        ..on('PUT /me/push', (_) => jsonAntwort({'ok': true}))
        ..on('GET /me/push', (_) => jsonAntwort({'available': true, 'registered': true, 'active': true, 'lastOkAt': null}))
        ..on('PUT /me/weather-alerts', (r) {
          bodies.add(r.json);
          return jsonAntwort({'ok': true});
        });
      fake = FakePush();
      c = ProviderContainer(overrides: [...env.overrides, pushPlattformProvider.overrideWithValue(fake), chatAnzeigePortProvider.overrideWithValue(_Anzeige())]);
      addTearDown(() {
        c.dispose();
      });
      c.listen(wetterMeldungProvider, (_, _) {});
      await c.read(authProvider.notifier).start();
      c.read(wetterProvider); // Abruf, damit die App weiß, dass der Server das Wetter anbietet
      await ruhe(60);
    }

    test('mit Push und Wetter: Start meldet den Stand (nur Frost), jede Änderung meldet neu, nichts außer den Namen der Arten', () async {
      await start();
      expect(bodies, isEmpty, reason: 'ohne angemeldeten Push nichts');
      await c.read(pushProvider.notifier).einschalten();
      await ruhe(100);
      expect(c.read(pushProvider).angemeldet, isTrue);
      expect(bodies, [
        {'kinds': ['frost']},
      ]);
      await c.read(wetterHinweisEinstellungenProvider.notifier).setzen(WetterHinweisArt.wind, true);
      await ruhe(60);
      expect(bodies.last, {'kinds': ['frost', 'wind']});
      await c.read(wetterHinweisEinstellungenProvider.notifier).setzen(WetterHinweisArt.frost, false);
      await c.read(wetterHinweisEinstellungenProvider.notifier).setzen(WetterHinweisArt.wind, false);
      await ruhe(60);
      expect(bodies.last, {'kinds': <String>[]});
      for (final b in bodies) {
        expect(b.keys, ['kinds']);
      }
    });

    test('Server ohne Wetter: die Route wird nie aufgerufen', () async {
      await start(wetterDa: false);
      await c.read(pushProvider.notifier).einschalten();
      await ruhe(100);
      await c.read(wetterHinweisEinstellungenProvider.notifier).setzen(WetterHinweisArt.wind, true);
      await ruhe(60);
      expect(bodies, isEmpty);
    });

    test('Artennamen: feste Liste in fester Reihenfolge', () {
      expect(wetterArtNamen(WetterHinweisArt.values), ['frost', 'regen', 'wind', 'hitze', 'druck']);
      expect(wetterArtNamen({WetterHinweisArt.druck, WetterHinweisArt.frost}), ['frost', 'druck']);
    });
  });

  group('Einstellungsseite', () {
    Future<void> seite(WidgetTester tester, {required bool push, double skala = 1.0}) async {
      final e = await angemeldeteUmgebung();
      e.server.on('GET /weather', (_) => jsonAntwort(_antwort()));
      if (push) e.extraOverrides.add(pushPlattformProvider.overrideWithValue(FakePush()));
      await starteApp(tester, e, skala: skala);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippeText(tester, 'Benachrichtigungen');
      await tippe(tester, find.text('Wetter-Hinweise'));
    }

    testWidgets('ehrlicher Text: per Wecker auch bei geschlossener App, braucht Push und Erlaubnis; kein "nur bei geöffneter App" mehr', (tester) async {
      await seite(tester, push: false, skala: 2.0);
      expect(find.textContaining('per Wecker auch bei geschlossener App'), findsOneWidget);
      expect(find.textContaining('eingerichtetes Push'), findsOneWidget);
      expect(find.textContaining('Android-Erlaubnis'), findsOneWidget);
      expect(find.textContaining('Ohne geöffnete App kommt kein Hinweis'), findsNothing);
      expect(find.textContaining('nichts an einen Server'), findsNothing);
      pruefeLayout(tester, 'Wetter-Hinweise');
    });

    testWidgets('Push unterstützt, aber nicht eingerichtet: Hinweis, dass dann nur die offene App gilt (360 px, Textskala 1.5)', (tester) async {
      await seite(tester, push: true, skala: 1.5);
      expect(find.textContaining('Push ist auf diesem Gerät nicht eingerichtet'), findsOneWidget);
      expect(find.textContaining('nur, solange die App offen ist'), findsOneWidget);
      pruefeLayout(tester, 'Wetter-Hinweise ohne Push');
    });
  });
}
