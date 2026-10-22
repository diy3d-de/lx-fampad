// Betrieb, Paket 3: Backups (Server-Sicherung, Abholung und Wiederherstellungstest laut NAS), Wetter und Push, Nutzung und Verlauf, Update-Stand.
// Geprüft werden die tolerant lesenden Modelle (ältere Server, kaputte Angaben), die Texte zu den festen Codes (nie ein Servertext), die Seiten mit allen Zuständen
// (eingerichtet, nicht eingerichtet, ungültig, Hinweis, Störung) und das Layout (360 px, Textskala 1.5, Touch-Ziele mindestens 44 px).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/betrieb/betrieb_modelle.dart';
import 'package:lx_fampad/features/betrieb/betrieb_anzeige.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

String _vor(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

Map<String, dynamic> _nas({
  bool eingerichtet = true,
  bool ungueltig = false,
  Duration abholungAlter = const Duration(hours: 5),
  String abholung = 'ok',
  String abholungStufe = 'ok',
  Duration? testAlter = const Duration(days: 2),
  String test = 'ok',
  String testStufe = 'ok',
}) => {
  'configured': eingerichtet,
  'invalid': ungueltig,
  'receivedAt': eingerichtet ? _vor(const Duration(hours: 4)) : null,
  'pull': eingerichtet
      ? {
          'state': abholungStufe,
          'result': abholung,
          'lastRunAt': _vor(const Duration(hours: 4)),
          'lastSuccessAt': _vor(abholungAlter),
          'ageHours': abholungAlter.inHours,
          'newestBackupAt': _vor(abholungAlter + const Duration(hours: 1)),
          'count': 14,
        }
      : {'state': 'unknown', 'result': null, 'lastRunAt': null, 'lastSuccessAt': null, 'ageHours': null, 'newestBackupAt': null, 'count': null},
  'restore': eingerichtet && testAlter != null
      ? {'state': testStufe, 'result': test, 'lastRunAt': _vor(testAlter), 'lastSuccessAt': _vor(testAlter), 'ageDays': testAlter.inDays, 'configChecked': false}
      : {'state': 'unknown', 'result': null, 'lastRunAt': null, 'lastSuccessAt': null, 'ageDays': null, 'configChecked': null},
};

Map<String, dynamic> _status({Object? nas = _std, String overall = 'ok'}) => {
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'overall': overall,
  'server': {'version': '0.7.0', 'protocolVersion': 1, 'startedAt': '2026-10-18T08:00:00.000Z', 'uptimeSec': 3 * 86400, 'memoryRssMb': 58},
  'database': {
    'ok': true,
    'latencyMs': 4,
    'sizeBytes': 38 * 1024 * 1024,
    'migrations': {'applied': 24, 'expected': 24, 'latest': '0023_betrieb_paket_2b', 'pending': false},
  },
  'services': [
    {'id': 'api', 'state': 'ok', 'detail': {'version': '0.7.0'}},
    {'id': 'database', 'state': 'ok', 'detail': {'latencyMs': 4}},
    {'id': 'weather', 'state': 'ok', 'detail': {'configured': true, 'lastOkMinutesAgo': 6, 'lastErrorCode': null}},
    {'id': 'ntfy', 'state': 'ok', 'detail': {'devices': 3}},
    {'id': 'caddy', 'state': 'ok', 'detail': {'daysLeft': 85}},
  ],
  'backup': {'state': 'ok', 'lastSuccessAt': _vor(const Duration(hours: 5)), 'ageHours': 5, 'totalBytes': 617472, 'lastResult': 'ok'},
  if (!identical(nas, _keine)) 'nas': identical(nas, _std) ? _nas() : nas,
  'disk': {'totalBytes': 44 * 1024 * 1024 * 1024, 'freeBytes': 26 * 1024 * 1024 * 1024, 'usedPercent': 41},
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

// zwei verschiedene Marken (zwei "const Object()" wären dieselbe Instanz)
const _std = 'standard';
const _keine = 'keine';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {Map<String, dynamic> Function()? status, double skala = 1.0, Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung();
    env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': true});
    env.server.on('GET /admin/status', (_) => jsonAntwort(status == null ? _status() : status()));
    env.server.on('GET /admin/audit', (_) => jsonAntwort({'items': <Object>[], 'nextCursor': null}));
    await starteApp(tester, env, skala: skala, groesse: groesse);
    await tippe(tester, find.byTooltip('Profil und Sicherheit'));
    await tippe(tester, find.text('Betrieb'));
    return env;
  }

  Future<void> seite(WidgetTester tester, String name) async {
    await tippe(tester, find.text(name));
  }

  group('Backups: Modelle und Texte', () {
    test('BetriebNas liest die Rückmeldung des NAS; ältere Server und kaputte Angaben ergeben "unbekannt", nie einen Absturz', () {
      final n = BetriebNas.fromJson(_nas());
      expect(n.bekannt, isTrue);
      expect(n.eingerichtet, isTrue);
      expect(n.abholung.stufe, BetriebStufe.ok);
      expect(n.abholung.ergebnis, 'ok');
      expect(n.abholung.alterStunden, 5);
      expect(n.abholung.anzahl, 14);
      expect(n.test.alterTage, 2);
      expect(n.test.konfigGeprueft, isFalse);
      // nicht eingerichtet: bekannt, aber leer
      final leer = BetriebNas.fromJson(_nas(eingerichtet: false));
      expect(leer.bekannt, isTrue);
      expect(leer.eingerichtet, isFalse);
      expect(leer.abholung.stufe, BetriebStufe.unbekannt);
      // älterer Server: kein Feld
      expect(BetriebNas.fromJson(null).bekannt, isFalse);
      expect(BetriebNas.fromJson('kaputt').bekannt, isFalse);
      expect(BetriebStatus.fromJson({..._status(nas: _keine)}).nas.bekannt, isFalse);
      // unbekannte Werte
      final seltsam = BetriebNas.fromJson({
        'configured': true,
        'pull': {'state': 'seltsam', 'result': 'vielleicht', 'ageHours': 'viel', 'count': 5.5},
        'restore': 7,
      });
      expect(seltsam.abholung.stufe, BetriebStufe.unbekannt);
      expect(seltsam.abholung.ergebnis, isNull);
      expect(seltsam.abholung.alterStunden, isNull);
      expect(seltsam.test.stufe, BetriebStufe.unbekannt);
    });

    test('Warntexte zu den neuen Arten und Ereignissen sind fest; Unbekanntes bleibt allgemein', () {
      expect(warnArtText('nas_pull'), contains('NAS'));
      expect(warnArtText('nas_restore'), contains('Wiederherstellungstest'));
      expect(warnArtText('<script>'), 'Hinweis des Servers');
      expect(ereignisText('operator_alert_nas_pull'), 'Betrieb-Warnung: Abholung durch das NAS');
      expect(ereignisText('operator_alert_nas_restore'), 'Betrieb-Warnung: Wiederherstellungstest');
      expect(kWarnArten, containsAll(<String>['nas_pull', 'nas_restore']));
    });
  });

  group('Backups: Seite', () {
    testWidgets('eingerichtet: Server-Sicherung, Abholung und Wiederherstellungstest mit Alter und Stand', (tester) async {
      await start(tester);
      await seite(tester, 'Backups');
      expect(find.text('// SICHERUNG AUF DEM SERVER'), findsOneWidget);
      expect(find.text('Letzte Sicherung'), findsOneWidget);
      expect(find.textContaining('603 KB'), findsOneWidget);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
      await warte(tester);
      expect(find.text('// ABHOLUNG DURCH DAS NAS'), findsOneWidget);
      expect(find.text('Letzte erfolgreiche Abholung'), findsOneWidget);
      expect(find.textContaining('vor 5 Std'), findsWidgets);
      expect(find.text('Stände auf dem NAS'), findsOneWidget);
      expect(find.text('14'), findsOneWidget);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
      await warte(tester);
      expect(find.text('// WIEDERHERSTELLUNGSTEST'), findsOneWidget);
      expect(find.text('Letzter erfolgreicher Test'), findsOneWidget);
      expect(find.textContaining('vor 2 T'), findsWidgets);
      expect(find.text('Konfigurationsarchiv geprüft'), findsOneWidget);
      expect(find.text('bestanden'), findsWidgets);
      pruefeLayout(tester, 'Backups');
    });

    testWidgets('Abholung zu alt und Test fehlgeschlagen: Hinweis und Störung mit Wort, nie nur Farbe', (tester) async {
      await start(
        tester,
        status: () => _status(nas: _nas(abholungAlter: const Duration(hours: 40), abholungStufe: 'warn', test: 'fehler', testStufe: 'error'), overall: 'warn'),
      );
      await seite(tester, 'Backups');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
      await warte(tester);
      expect(find.text('Hinweis'), findsWidgets);
      expect(find.text('Störung'), findsWidgets);
      expect(find.text('fehlgeschlagen'), findsOneWidget);
      expect(find.textContaining('vor 1 T'), findsWidgets);
    });

    testWidgets('NAS noch nicht eingerichtet: ruhiger Hinweis, keine Warnung, keine Angabe statt "ok"', (tester) async {
      await start(tester, status: () => _status(nas: _nas(eingerichtet: false)));
      await seite(tester, 'Backups');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
      await warte(tester);
      expect(find.textContaining('Noch keine Rückmeldung vom NAS'), findsOneWidget);
      expect(find.textContaining('Noch kein Wiederherstellungstest gemeldet'), findsOneWidget);
      expect(find.text('Letzte erfolgreiche Abholung'), findsNothing);
      expect(find.text('Störung'), findsNothing);
      // die Sicherung des Servers wird trotzdem gezeigt
      expect(find.text('Letzte Sicherung'), findsOneWidget);
    });

    testWidgets('ungültige Rückmeldung: eigener Hinweis ohne Rohtext; älterer Server: "kennt das noch nicht"', (tester) async {
      await start(tester, status: () => _status(nas: _nas(eingerichtet: false, ungueltig: true)));
      await seite(tester, 'Backups');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
      await warte(tester);
      expect(find.textContaining('nicht lesbar'), findsOneWidget);
    });

    testWidgets('älterer Server ohne Feld "nas"', (tester) async {
      await start(tester, status: () => _status(nas: _keine));
      await seite(tester, 'Backups');
      expect(find.textContaining('kennt die Rückmeldung des NAS noch nicht'), findsWidgets);
      expect(find.text('Letzte Sicherung'), findsOneWidget);
    });

    testWidgets('360 px und Textskala 1.5: nichts läuft über, Touch-Ziele mindestens 44 px; auch mit sechs Reitern', (tester) async {
      await start(tester, skala: 1.5);
      pruefeLayout(tester, 'Reiter 1.5');
      await seite(tester, 'Backups');
      pruefeLayout(tester, 'Backups 1.5');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
      await warte(tester);
      pruefeLayout(tester, 'Backups 1.5 unten');
    });
  });
}
