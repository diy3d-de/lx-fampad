// Betreiber-Ansicht "Betrieb" (nur lesend): Modelle (tolerant), Anzeige-Hilfen, Sichtbarkeit (nur Betreiber: Profil mobil, Seitenleiste im Desktop-Layout),
// Übersicht (Kacheln, Dienste, Funktionen, Versionen), Protokoll (Filter, Seiten, Step-up), keine schreibenden Aufrufe, Layout (360 px, Textskala 1.5).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/betrieb/betrieb_modelle.dart';
import 'package:lx_fampad/features/auth/step_up.dart';
import 'package:lx_fampad/features/betrieb/betrieb_anzeige.dart';
import 'package:lx_fampad/features/betrieb/betrieb_screen.dart';
import 'package:lx_fampad/features/profile/profile_screen.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

Map<String, dynamic> _status({String overall = 'ok', Map<String, dynamic>? backup, Object? disk = _std}) => {
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'overall': overall,
  'server': {'version': '0.7.0', 'protocolVersion': 1, 'startedAt': '2026-10-18T08:00:00.000Z', 'uptimeSec': 3 * 86400 + 4 * 3600, 'memoryRssMb': 58},
  'database': {
    'ok': true,
    'latencyMs': 4,
    'sizeBytes': 38 * 1024 * 1024,
    'migrations': {'applied': 19, 'expected': 19, 'latest': '0018_betreiber', 'pending': false},
  },
  'services': [
    {'id': 'api', 'state': 'ok', 'detail': {'version': '0.7.0'}},
    {'id': 'database', 'state': 'ok', 'detail': {'latencyMs': 4}},
    {'id': 'weather', 'state': 'ok', 'detail': {'configured': true, 'lastOkMinutesAgo': 6, 'lastErrorCode': null}},
    {'id': 'ntfy', 'state': 'ok', 'detail': {'devices': 3}},
    {'id': 'caddy', 'state': 'ok', 'detail': {'daysLeft': 85}},
  ],
  'backup': backup ?? {'state': 'ok', 'lastSuccessAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String(), 'ageHours': 5, 'totalBytes': 617472, 'lastResult': 'ok'},
  'disk': identical(disk, _std) ? {'totalBytes': 44 * 1024 * 1024 * 1024, 'freeBytes': 26 * 1024 * 1024 * 1024, 'usedPercent': 41} : disk,
  'certificate': {'validTo': '2027-01-14T00:00:00.000Z', 'daysLeft': 85},
  'counts': {'members': 4, 'devices': 6, 'pushDevices': 3, 'activeSessions': 7},
  'versions': {
    'server': '0.7.0',
    'web': '0.7.0-20261021115255',
    'app': {'version': '0.7.0', 'versionCode': 7000, 'minVersion': '0.1.0'},
    'minAppVersion': '0.1.0',
  },
  'features': {'pwBackup': false, 'legacyPasswordLogin': true, 'weather': true, 'push': true, 'map': {'available': true, 'sizeBytes': 1181116006}},
};

const _std = Object();

Map<String, dynamic> _eintrag(int i, {String event = 'login_ok', String category = 'anmeldung', String? person = 'Anna', String? netz = '203.0.113.0/24'}) => {
  'id': '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
  'at': DateTime.now().toUtc().subtract(Duration(minutes: i * 7)).toIso8601String(),
  'event': event,
  'category': category,
  'actor': person == null ? null : {'id': 'u$i', 'displayName': person},
  'network': netz,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modelle und Hilfen', () {
    test('MeDto: operator fehlt bei älteren Servern = kein Betreiber', () {
      final ohne = MeDto.fromJson(meJson());
      expect(ohne.betreiber, isFalse);
      expect(MeDto.fromJson({...meJson(), 'operator': true}).betreiber, isTrue);
      expect(MeDto.fromJson({...meJson(), 'operator': 'ja'}).betreiber, isFalse);
    });

    test('BetriebStatus liest die Antwort; unbekannte Stufen und Dienste fallen nicht auf', () {
      final s = BetriebStatus.fromJson({
        ..._status(),
        'services': [
          {'id': 'api', 'state': 'ok', 'detail': <String, dynamic>{}},
          {'id': 'neu', 'state': 'seltsam', 'detail': 5},
          'kaputt',
        ],
      });
      expect(s.serverVersion, '0.7.0');
      expect(s.dienste.map((d) => d.id), ['api', 'neu']);
      expect(s.dienst('neu')!.stufe, BetriebStufe.unbekannt);
      expect(s.dienst('weather'), isNull);
      expect(s.gesamt, BetriebStufe.ok);
      expect(s.platte!.belegtProzent, 41);
      expect(s.appVersion!.versionCode, 7000);
      expect(s.karteDa, isTrue);
    });

    test('BetriebStatus mit fehlenden Teilen: unbekannt statt Absturz', () {
      final s = BetriebStatus.fromJson({'generatedAt': 'kaputt', 'overall': 'x'});
      expect(s.gesamt, BetriebStufe.unbekannt);
      expect(s.sicherung.stufe, BetriebStufe.unbekannt);
      expect(s.platte, isNull);
      expect(s.appVersion, isNull);
      expect(s.zertifikatBis, isNull);
      expect(s.mitglieder, 0);
      expect(() => BetriebStatus.fromJson('kein json'), throwsA(anything));
    });

    test('ProtokollSeite: kaputte Einträge fallen weg, unbekannte Kategorie wird "Änderungen"', () {
      final seite = ProtokollSeite.fromJson({
        'items': [
          _eintrag(1),
          {'id': 'x'},
          {..._eintrag(2), 'category': 'neu'},
          _eintrag(3, person: null, netz: null),
        ],
        'nextCursor': 'abc',
      });
      expect(seite.eintraege, hasLength(3));
      expect(seite.eintraege[1].art, ProtokollArt.aenderungen);
      expect(seite.eintraege[2].person, isNull);
      expect(seite.weiter, 'abc');
    });

    test('Texte: Größen, Laufzeit, Zeit, Ereignisse', () {
      expect(groesseText(null), '–');
      expect(groesseText(617472), '603 KB');
      expect(groesseText(38 * 1024 * 1024), '38 MB');
      expect(groesseText(1181116006), '1,1 GB');
      expect(laufzeitText(3 * 86400 + 4 * 3600), '3 T 4 Std');
      expect(laufzeitText(5 * 3600 + 12 * 60), '5 Std 12 Min');
      expect(laufzeitText(42 * 60), '42 Min');
      final jetzt = DateTime(2026, 10, 21, 12, 30);
      expect(zeitText(DateTime(2026, 10, 21, 9, 5), jetzt), 'heute 09:05');
      expect(zeitText(DateTime(2026, 10, 20, 22, 3), jetzt), 'gestern 22:03');
      expect(zeitText(DateTime(2026, 10, 19, 13, 41), jetzt), '19.10. 13:41');
      expect(vorText(const Duration(minutes: 6)), 'vor 6 Min');
      expect(ereignisText('login_failed'), 'Fehlgeschlagene Anmeldung');
      expect(ereignisText('<script>'), 'Ereignis');
    });
  });

  Future<TestUmgebung> start(
    WidgetTester tester, {
    bool betreiber = true,
    Object Function()? status,
    FutureOr<Object?> Function(Req)? audit,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
  }) async {
    final env = await angemeldeteUmgebung();
    env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': betreiber});
    env.server.on('GET /admin/status', (_) => jsonAntwort(status == null ? _status() : status()));
    env.server.on('GET /admin/audit', (r) async {
      final a = await audit?.call(r);
      if (a == null) return jsonAntwort({'items': [for (var i = 1; i <= 3; i++) _eintrag(i)], 'nextCursor': null});
      return jsonAntwort(a);
    });
    await starteApp(tester, env, skala: skala, groesse: groesse);
    return env;
  }

  Future<void> betriebOeffnenMobil(WidgetTester tester) async {
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippe(tester, find.text('Betrieb').last);
  }

  group('Sichtbarkeit', () {
    testWidgets('Betreiber: Zeile "Betrieb" im Profil; Nicht-Betreiber sehen nichts und es gibt keine Anfrage an /admin', (tester) async {
      final env = await start(tester, betreiber: false);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      expect(find.text('Betrieb'), findsNothing);
      expect(labelFinder('Betrieb'), findsNothing);
      expect(env.server.log.where((r) => r.path.startsWith('/admin')), isEmpty);
    });

    testWidgets('Desktop: Seitenleiste zeigt "Betrieb" nur dem Betreiber', (tester) async {
      await start(tester, betreiber: false, groesse: const Size(1440, 900));
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.text('Betrieb'), findsNothing);
    });

    testWidgets('Desktop: Betreiber öffnet "Betrieb" in der Seitenleiste, Seitenleiste und Fußzeile bleiben', (tester) async {
      final env = await start(tester, groesse: const Size(1440, 900));
      await tippe(tester, find.text('Betrieb').last);
      expect(find.byType(BetriebScreen), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.text('Version dev'), findsOneWidget);
      expect(find.text('0.7.0'), findsWidgets);
      expect(env.server.anfragen('GET /admin/status'), isNotEmpty);
      // erneutes Tippen öffnet keine zweite Seite
      await tippe(tester, find.text('Betrieb').first);
      expect(find.byType(BetriebScreen), findsOneWidget);
      pruefeLayout(tester, 'Betrieb Desktop');
    });
  });

  group('Übersicht', () {
    testWidgets('zeigt Kacheln, Dienste, Funktionen, Versionen und Ereignisse; schreibt nichts', (tester) async {
      final env = await start(tester);
      await betriebOeffnenMobil(tester);
      expect(find.byType(BetriebScreen), findsOneWidget);
      expect(find.text('alles in Ordnung'), findsOneWidget);
      expect(labelFinder('Server'), findsOneWidget);
      expect(find.text('online seit 3 T 4 Std'), findsOneWidget);
      expect(find.text('38 MB'), findsWidgets);
      expect(find.text('41 %'), findsOneWidget);
      expect(find.textContaining('603 KB'), findsOneWidget);
      expect(find.text('lx-fampad (API)'), findsOneWidget);
      expect(find.textContaining('Letzter Abruf vor 6 Min'), findsOneWidget);
      expect(find.textContaining('3 Geräte angemeldet'), findsOneWidget);
      expect(find.textContaining('gültig bis 14.01.2027'), findsOneWidget);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
      await warte(tester);
      expect(find.text('Karte (PMTiles)'), findsOneWidget);
      expect(find.text('0.7.0+7000'), findsOneWidget);
      expect(find.textContaining('Anna · 203.0.113.0/24'), findsWidgets);
      // nur Lesen: keine Anfrage außer GET
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
    });

    testWidgets('Störung und nicht lesbare Quellen: "unbekannt" statt Fehler', (tester) async {
      await start(
        tester,
        status: () => {..._status(overall: 'error', backup: {'state': 'unknown', 'lastSuccessAt': null, 'ageHours': null, 'totalBytes': null, 'lastResult': null}, disk: null), 'certificate': null},
      );
      await betriebOeffnenMobil(tester);
      expect(find.text('Störung'), findsOneWidget);
      expect(find.text('unbekannt'), findsWidgets);
      expect(find.text('Statusdatei nicht lesbar'), findsOneWidget);
      expect(find.textContaining('Zertifikat nicht ermittelbar'), findsOneWidget);
    });

    testWidgets('Serverfehler: Meldung ohne Servertext', (tester) async {
      final env = await angemeldeteUmgebung();
      env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': true});
      env.server.on('GET /admin/status', (_) => fehler(500, 'internal', message: 'GEHEIMER-SERVERTEXT'));
      env.server.on('GET /admin/audit', (_) => fehler(500, 'internal', message: 'GEHEIMER-SERVERTEXT'));
      await starteApp(tester, env);
      await betriebOeffnenMobil(tester);
      expect(find.byType(BetriebScreen), findsOneWidget);
      expect(find.textContaining('GEHEIMER-SERVERTEXT'), findsNothing);
    });

    testWidgets('360 px und Textskala 1.5: nichts läuft über, Touch-Ziele mindestens 44 px', (tester) async {
      await start(tester, skala: 1.5);
      await betriebOeffnenMobil(tester);
      pruefeLayout(tester, 'Betrieb Übersicht 1.5');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
      await warte(tester);
      pruefeLayout(tester, 'Betrieb Übersicht 1.5 mitte');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
      await warte(tester);
      pruefeLayout(tester, 'Betrieb Übersicht 1.5 unten');
    });
  });

  group('Protokoll', () {
    testWidgets('Filter, Person und gekürzte Netzadresse, ältere Einträge per Cursor', (tester) async {
      final env = await start(
        tester,
        audit: (r) {
          final art = r.query['category'] ?? 'alle';
          if (r.query['cursor'] != null) {
            return {'items': [_eintrag(9, event: 'role_changed', category: 'aenderungen', person: 'Ben')], 'nextCursor': null};
          }
          if (art == 'fehler') {
            return {'items': [_eintrag(4, event: 'login_failed', category: 'fehler', person: null, netz: '198.51.100.0/24')], 'nextCursor': null};
          }
          return {'items': [for (var i = 1; i <= 3; i++) _eintrag(i)], 'nextCursor': 'c1'};
        },
      );
      await betriebOeffnenMobil(tester);
      await tippe(tester, find.text('Protokoll'));
      expect(labelFinder('Audit-Protokoll'), findsOneWidget);
      expect(find.text('Anmeldung'), findsWidgets);
      expect(find.textContaining('Anna · 203.0.113.0/24'), findsWidgets);
      // nie das Detail-Feld oder Roh-Codes
      expect(find.text('login_ok'), findsNothing);
      await tippe(tester, find.text('Fehler'));
      expect(env.server.anfragen('GET /admin/audit').last.query['category'], 'fehler');
      expect(find.text('Fehlgeschlagene Anmeldung'), findsOneWidget);
      expect(find.textContaining('198.51.100.0/24'), findsOneWidget);
      await tippe(tester, find.text('Alle'));
      expect(find.text('Ältere Einträge laden'), findsOneWidget);
      await tippe(tester, find.text('Ältere Einträge laden'));
      expect(env.server.anfragen('GET /admin/audit').last.query['cursor'], 'c1');
      expect(find.text('Rolle geändert'), findsOneWidget);
      expect(find.text('Ältere Einträge laden'), findsNothing);
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
      pruefeLayout(tester, 'Betrieb Protokoll');
    });

    testWidgets('ohne frische Bestätigung: Hinweis, "Bestätigen und anzeigen" öffnet die Step-up-Abfrage', (tester) async {
      final env = await angemeldeteUmgebung();
      env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': true});
      env.server.on('GET /admin/status', (_) => jsonAntwort(_status()));
      env.server.on('GET /admin/audit', (_) => fehler(403, 'step_up_required'));
      await starteApp(tester, env);
      await betriebOeffnenMobil(tester);
      // Übersicht: kein Protokoll, dafür der Knopf
      expect(find.text('Bestätigen und anzeigen'), findsOneWidget);
      await tippe(tester, find.text('Bestätigen und anzeigen'));
      expect(find.byType(StepUpDialog), findsOneWidget);
    });

    testWidgets('360 px und Textskala 1.5 im Protokoll', (tester) async {
      await start(tester, skala: 1.5);
      await betriebOeffnenMobil(tester);
      await tippe(tester, find.text('Protokoll'));
      pruefeLayout(tester, 'Betrieb Protokoll 1.5');
    });
  });

  group('Review-Korrekturen', () {
    testWidgets('Gesamtzeile: Unbekanntes wird nicht als "alles in Ordnung" gemeldet', (tester) async {
      await start(tester, status: () => {..._status(), 'unknownCount': 3});
      await betriebOeffnenMobil(tester);
      expect(find.text('in Ordnung, 3 unbekannt'), findsOneWidget);
      expect(find.text('alles in Ordnung'), findsNothing);
    });

    testWidgets('Migrationsstand ohne Leserecht: "unbekannt" mit Hinweis auf den Grant', (tester) async {
      final s = _status();
      (s['database'] as Map<String, dynamic>)['migrations'] = {'applied': null, 'expected': 19, 'latest': null, 'pending': null, 'grantMissing': true};
      await start(tester, status: () => s);
      await betriebOeffnenMobil(tester);
      expect(find.textContaining('Grant fehlt, siehe README'), findsWidgets);
      expect(find.textContaining('Migrationen ? von'), findsNothing);
    });

    testWidgets('Textskala 2.0 bei 360 px: Kacheln in einer Spalte, nichts läuft über', (tester) async {
      // die Startseite selbst läuft bei 2.0 über (nicht Teil dieses Pakets): erst danach die Schrift vergrößern
      await start(tester);
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      await warte(tester);
      tester.takeException(); // Überlauf des Profils bei 2.0 gehört nicht zu diesem Paket
      await tippe(tester, find.text('Betrieb').last);
      await warte(tester);
      final a = tester.getTopLeft(labelFinder('Server'));
      final b = tester.getTopLeft(labelFinder('Datenbank'));
      expect(a.dx, b.dx);
      expect(b.dy, greaterThan(a.dy));
      pruefeLayout(tester, 'Betrieb 2.0');
    });

    testWidgets('"Prüfung neu starten" lädt Status (ohne Cache) und Ereignisse neu', (tester) async {
      final env = await start(tester);
      await betriebOeffnenMobil(tester);
      final status0 = env.server.anfragen('GET /admin/status').length;
      final audit0 = env.server.anfragen('GET /admin/audit').length;
      await tippe(tester, find.byTooltip('Prüfung neu starten'));
      expect(env.server.anfragen('GET /admin/status'), hasLength(status0 + 1));
      expect(env.server.anfragen('GET /admin/status').last.query['fresh'], '1');
      expect(env.server.anfragen('GET /admin/audit'), hasLength(audit0 + 1));
    });

    testWidgets('Desktop: Konto und Betrieb stapeln nicht', (tester) async {
      await start(tester, groesse: const Size(1440, 900));
      await tippe(tester, find.byIcon(Icons.settings_outlined));
      expect(find.byType(ProfileScreen), findsOneWidget);
      await tippe(tester, find.text('Betrieb').last);
      expect(find.byType(BetriebScreen), findsOneWidget);
      expect(find.byType(ProfileScreen), findsNothing);
      await tippe(tester, find.byIcon(Icons.settings_outlined));
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.byType(BetriebScreen), findsNothing);
      // aus dem Profil heraus ersetzt "Betrieb" das Konto
      await tippe(tester, find.text('Betrieb').last);
      expect(find.byType(BetriebScreen), findsOneWidget);
      expect(find.byType(ProfileScreen), findsNothing);
    });

    testWidgets('Step-up: nach Bestätigung wird das Protokoll geladen, nach Abbruch bleibt der Knopf', (tester) async {
      final env = await angemeldeteUmgebung();
      var bestaetigt = false;
      env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': true});
      env.server.on('GET /admin/status', (_) => jsonAntwort(_status()));
      env.server.on('GET /admin/audit', (_) => bestaetigt ? jsonAntwort({'items': [_eintrag(1)], 'nextCursor': null}) : fehler(403, 'step_up_required'));
      env.server.json('POST /auth/step-up/passkey/options', {'challengeId': 'c1', 'options': {'challenge': 'abc'}});
      env.server.on('POST /auth/step-up/passkey/verify', (_) {
        bestaetigt = true;
        return jsonAntwort({'stepUpAt': DateTime.now().toUtc().toIso8601String()});
      });
      await starteApp(tester, env);
      await betriebOeffnenMobil(tester);
      // Abbruch
      await tippe(tester, find.text('Bestätigen und anzeigen'));
      expect(find.byType(StepUpDialog), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(find.byType(StepUpDialog), findsNothing);
      expect(find.text('Bestätigen und anzeigen'), findsOneWidget);
      expect(bestaetigt, isFalse);
      // Bestätigung: die Anfrage wird wiederholt, die Ereignisse erscheinen
      await tippe(tester, find.text('Bestätigen und anzeigen'));
      await tippe(tester, find.text('Mit Passkey bestätigen'));
      expect(bestaetigt, isTrue);
      expect(find.byType(StepUpDialog), findsNothing);
      expect(find.text('Bestätigen und anzeigen'), findsNothing);
      expect(find.textContaining('Anna · 203.0.113.0/24'), findsWidgets);
    });

    testWidgets('Späte Antwort zu einem alten Filter wird verworfen (schneller Filterwechsel)', (tester) async {
      final spaet = Completer<void>();
      await start(
        tester,
        audit: (r) async {
          if (r.query['category'] == 'fehler') {
            // die Antwort kommt erst nach dem Wechsel zu "Anmeldung"
            await spaet.future;
            return {'items': [_eintrag(4, event: 'login_failed', category: 'fehler', person: null)], 'nextCursor': null};
          }
          return {'items': [_eintrag(5, event: 'logout')], 'nextCursor': null};
        },
      );
      await betriebOeffnenMobil(tester);
      await tippe(tester, find.text('Protokoll'));
      await tippe(tester, find.text('Fehler'));
      await tippe(tester, find.text('Anmeldung').last);
      expect(find.text('Abmeldung'), findsOneWidget);
      spaet.complete();
      await warte(tester, 10);
      expect(find.text('Abmeldung'), findsOneWidget);
      expect(find.text('Fehlgeschlagene Anmeldung'), findsNothing);
    });
  });
}
