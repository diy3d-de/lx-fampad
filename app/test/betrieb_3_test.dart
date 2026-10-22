// Betrieb, Paket 3: Backups (Server-Sicherung, Abholung und Wiederherstellungstest laut NAS), Wetter und Push, Nutzung und Verlauf, Update-Stand.
// Geprüft werden die tolerant lesenden Modelle (ältere Server, kaputte Angaben), die Texte zu den festen Codes (nie ein Servertext), die Seiten mit allen Zuständen
// (eingerichtet, nicht eingerichtet, ungültig, Hinweis, Störung) und das Layout (360 px, Textskala 1.5, Touch-Ziele mindestens 44 px).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/betrieb/betrieb_modelle.dart';
import 'package:lx_fampad/data/geraet_version_melder.dart';
import 'package:lx_fampad/features/betrieb/betrieb_anzeige.dart';
import 'package:lx_fampad/features/betrieb/betrieb_verlauf.dart';

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

Map<String, dynamic> _updates({int gesamt = 5, int aktuell = 2, int aelter = 1, int unterMin = 1, int inaktiv = 0, int unbekannt = 1, int personen = 2, String? neueste = '0.7.0'}) => {
  'reference': neueste,
  'minAppVersion': '0.4.0',
  'android': {'total': gesamt, 'current': aktuell, 'outdated': aelter, 'belowMin': unterMin, 'inactive': inaktiv, 'unknown': unbekannt},
  'otherDevices': 2,
  'personsBehind': personen,
};

Map<String, dynamic> _push({int aktiv = 3, int deaktiviert = 1, int fehlerhaft = 1, int fehler24h = 2, String? letzter}) => {
  'devicesActive': aktiv,
  'devicesDisabled': deaktiviert,
  'devicesFailing': fehlerhaft,
  'errors24h': fehler24h,
  'lastOkAt': letzter ?? _vor(const Duration(minutes: 40)),
};

Map<String, dynamic> _tag(int vorTagen, {int p7 = 2, int p30 = 3, int g7 = 3, int g30 = 4, int runs = 120, int err = 0, int limit = 1, int? db = 40 * 1024 * 1024, int? dateien}) => {
  'day': DateTime.now().toUtc().subtract(Duration(days: vorTagen)).toIso8601String().substring(0, 10),
  'activePersons7': p7,
  'activePersons30': p30,
  'activeDevices7': g7,
  'activeDevices30': g30,
  'syncRuns': runs,
  'syncErrors': err,
  'rateLimited': limit,
  'dbBytes': db,
  'filesBytes': dateien,
};

Map<String, dynamic> _verlauf({List<Map<String, dynamic>>? tage}) => {
  'generatedAt': _vor(Duration.zero),
  'retentionDays': 400,
  'days': tage ?? [for (var i = 29; i >= 0; i--) if (i % 7 != 3) _tag(i, runs: 100 + i, db: (40 + (29 - i)) * 1024 * 1024)],
};

Map<String, dynamic> _status({Object? nas = _std, Object? updates = _std, Object? push = _std, int wetterFehler = 0, String overall = 'ok'}) => {
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
    {
      'id': 'weather',
      'state': wetterFehler > 0 ? 'warn' : 'ok',
      'detail': {'configured': true, 'lastOkMinutesAgo': 6, 'lastErrorCode': wetterFehler > 0 ? 'http_500' : null, 'errorCount': wetterFehler},
    },
    {'id': 'ntfy', 'state': 'ok', 'detail': {'devices': 3}},
    {'id': 'caddy', 'state': 'ok', 'detail': {'daysLeft': 85}},
  ],
  'backup': {'state': 'ok', 'lastSuccessAt': _vor(const Duration(hours: 5)), 'ageHours': 5, 'totalBytes': 617472, 'lastResult': 'ok'},
  if (!identical(nas, _keine)) 'nas': identical(nas, _std) ? _nas() : nas,
  if (!identical(push, _keine)) 'push': identical(push, _std) ? _push() : push,
  if (!identical(updates, _keine)) 'updates': identical(updates, _std) ? _updates() : updates,
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

/// API mit gültigen Zugangsdaten gegen den Fake-Server (ohne Token würde der Client gar nicht erst senden).
FampadApi _api(FakeServer server) {
  final store = MemoryTokenStore();
  unawaited(
    store.writeTokens(
      StoredTokens(
        accessToken: 'access-1',
        accessExpiresAt: DateTime.now().add(const Duration(minutes: 15)),
        refreshToken: 'refresh-1',
        refreshExpiresAt: DateTime.now().add(const Duration(days: 90)),
        deviceId: 'dev-1',
      ),
    ),
  );
  return FampadApi(ApiClient(client: server.client, store: store, base: 'https://familie.test'), geraet: () async => null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  Future<TestUmgebung> start(WidgetTester tester, {Map<String, dynamic> Function()? status, Map<String, dynamic>? mitglieder, Object? verlauf = _std, double skala = 1.0, Size groesse = const Size(360, 800)}) async {
    final env = await angemeldeteUmgebung();
    env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': true});
    env.server.on('GET /admin/status', (_) => jsonAntwort(status == null ? _status() : status()));
    env.server.on('GET /admin/audit', (_) => jsonAntwort({'items': <Object>[], 'nextCursor': null}));
    if (mitglieder != null) env.server.json('GET /admin/members', mitglieder);
    env.server.on('GET /admin/metrics', (r) {
      if (identical(verlauf, _keine)) return fehler(404, 'not_found');
      final tage = int.tryParse(r.query['days'] ?? '') ?? 30;
      final liste = identical(verlauf, _std) ? _verlauf() : verlauf as Map<String, dynamic>;
      final alle = (liste['days'] as List).cast<Map<String, dynamic>>();
      return jsonAntwort({...liste, 'days': alle.length > tage ? alle.sublist(alle.length - tage) : alle});
    });
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (groesse.width >= 900) {
      // Desktop-Layout: "Betrieb" steht in der Seitenleiste
      await tippe(tester, find.text('Betrieb'));
    } else {
      await tippe(tester, find.byTooltip('Profil und Sicherheit'));
      await tippe(tester, find.text('Betrieb'));
    }
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



  group('Wetter, Push und Verlauf: Modelle und Hilfen', () {
    test('BetriebPush liest nur Zähler; fehlt der Block (älterer Server), ist push null', () {
      final p = BetriebStatus.fromJson(_status()).push!;
      expect((p.aktiv, p.deaktiviert, p.fehlerhaft, p.fehler24h), (3, 1, 1, 2));
      expect(p.letzterErfolg, isNotNull);
      expect(BetriebStatus.fromJson(_status(push: _keine)).push, isNull);
      final leer = BetriebPush.fromJson('kaputt');
      expect((leer.aktiv, leer.letzterErfolg), (0, null));
    });

    test('BetriebVerlauf: sortiert, kaputte Tage fallen weg, Zahlen werden begrenzt', () {
      final v = BetriebVerlauf.fromJson({
        'generatedAt': _vor(Duration.zero),
        'retentionDays': 400,
        'days': [
          _tag(1),
          _tag(3),
          {'day': 'gestern', 'syncRuns': 5},
          {'syncRuns': 5},
          'kaputt',
          {..._tag(2), 'syncRuns': -5, 'dbBytes': 'viel', 'filesBytes': null},
        ],
      });
      expect(v.tage, hasLength(3));
      expect(v.tage.map((t) => t.tag.isBefore(DateTime.now().toUtc())).every((x) => x), isTrue);
      expect(v.tage.first.tag.isBefore(v.tage.last.tag), isTrue);
      final mittel = v.tage[1];
      expect(mittel.abgleiche, 0, reason: 'negative Zahlen gibt es nicht');
      expect(mittel.datenbankBytes, isNull);
      expect(v.letzter, v.tage.last);
      // keine JSON-Antwort: wie bei den anderen Modellen ein Protokollfehler (die Oberfläche macht daraus eine ruhige Meldung)
      expect(() => BetriebVerlauf.fromJson('kaputt'), throwsA(anything));
      expect(BetriebVerlauf.fromJson({'days': 5}).tage, isEmpty);
    });

    test('verlaufReihe: Fenster bis heute, fehlende Tage sind Lücken (null), nie erfundene Werte', () {
      final heute = DateTime.utc(2026, 10, 20, 15, 30);
      DateTime tag(int vor) => DateTime.utc(2026, 10, 20).subtract(Duration(days: vor));
      final tage = [
        VerlaufTag(tag: tag(4), abgleiche: 10, datenbankBytes: 100),
        VerlaufTag(tag: tag(2), abgleiche: 30),
        VerlaufTag(tag: tag(0), abgleiche: 50, datenbankBytes: 300),
        VerlaufTag(tag: tag(10), abgleiche: 99), // außerhalb des Fensters
      ];
      expect(verlaufReihe(tage, 5, heute, (t) => t.abgleiche), [10, null, 30, null, 50]);
      expect(verlaufReihe(tage, 5, heute, (t) => t.datenbankBytes), [100, null, null, null, 300]);
      expect(verlaufReihe(tage, 1, heute, (t) => t.abgleiche), [50]);
      expect(verlaufReihe(const [], 3, heute, (t) => t.abgleiche), [null, null, null]);
      // ein Tag in einer anderen Uhrzeit des Tages liegt trotzdem im selben Fach
      expect(verlaufReihe([VerlaufTag(tag: DateTime.utc(2026, 10, 20, 23), abgleiche: 7)], 2, heute, (t) => t.abgleiche), [null, 7]);
    });

    test('Wetter-Fehlercodes: feste Wörter, nie der Rohtext', () {
      expect(wetterFehlerText('network'), 'Wetterdienst nicht erreichbar');
      expect(wetterFehlerText('http_503'), contains('503'));
      expect(wetterFehlerText('invalid_grant'), 'Zugangsdaten ungültig');
      expect(wetterFehlerText('token_http_500'), 'Token-Abruf abgelehnt');
      expect(wetterFehlerText('<script>alert(1)</script>'), 'Fehler beim Abruf');
      expect(wetterFehlerText('http_<b>'), 'Fehler beim Abruf');
    });
  });

  group('Verlaufsgrafik (CustomPaint)', () {
    Widget grafik(List<VerlaufReihe> reihen, {bool balken = false, VerlaufAchse achse = VerlaufAchse.abNull}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: VerlaufDiagramm(titel: 'test', zuletzt: '1', reihen: reihen, von: DateTime.utc(2026, 10, 1), bis: DateTime.utc(2026, 10, 5), format: anzahlText, balken: balken, achse: achse),
        ),
      ),
    );

    testWidgets('zeichnet Linien mit Lücken, Balken, einen Einzelwert und gleiche Werte ohne Fehler; Screenreader-Zusammenfassung nennt Werte und Zeitraum', (tester) async {
      const farbe = Color(0xFF00F0FF);
      final fall = <List<VerlaufReihe>>[
        [const VerlaufReihe(name: 'a', werte: [1, null, 3, 2, null], farbe: farbe)],
        [const VerlaufReihe(name: 'a', werte: [null, null, 4, null, null], farbe: farbe)], // Einzelwert
        [const VerlaufReihe(name: 'a', werte: [5, 5, 5, 5, 5], farbe: farbe)], // alles gleich
        [const VerlaufReihe(name: 'a', werte: [0, 0, 0, 0, 0], farbe: farbe)], // alles null (0)
        [const VerlaufReihe(name: 'a', werte: [1, 2, 3, 4, 5], farbe: farbe), const VerlaufReihe(name: 'b', werte: [5, 4, 3, 2, 1], farbe: farbe)],
        [const VerlaufReihe(name: 'a', werte: [1], farbe: farbe)], // ein Tag
      ];
      for (final balken in [false, true]) {
        for (final achse in VerlaufAchse.values) {
          for (final f in fall) {
            await tester.pumpWidget(grafik(f, balken: balken, achse: achse));
            expect(tester.takeException(), isNull, reason: '$balken $achse ${f.first.werte}');
          }
        }
      }
      await tester.pumpWidget(grafik([const VerlaufReihe(name: 'Abgleiche', werte: [1, null, 3, 2, 2], farbe: farbe)], balken: true));
      expect(find.bySemanticsLabel(RegExp(r'Verlauf test, .*Abgleiche zuletzt 2.*kleinster Wert 1.*größter Wert 3')), findsOneWidget);
      // ohne Werte: kein Zeichnen, sondern ein ruhiger Hinweis
      await tester.pumpWidget(grafik([const VerlaufReihe(name: 'a', werte: [null, null], farbe: farbe)]));
      expect(find.text('Noch keine Messpunkte'), findsOneWidget);
    });
  });

  group('Update-Stand: Modelle, Melder und Texte', () {
    test('BetriebUpdates liest die Zähler; ältere Server und kaputte Angaben ergeben null bzw. Nullen, nie einen Absturz', () {
      final u = BetriebStatus.fromJson(_status()).updates!;
      expect(u.neueste, '0.7.0');
      expect(u.mindestversion, '0.4.0');
      expect((u.gesamt, u.aktuell, u.aelter, u.unterMindestversion, u.unbekannt, u.andere, u.personenZurueck), (5, 2, 1, 1, 1, 2, 2));
      expect(u.zurueck, 2);
      expect(BetriebStatus.fromJson(_status(updates: _keine)).updates, isNull);
      final leer = BetriebUpdates.fromJson('kaputt');
      expect(leer.gesamt, 0);
      expect(leer.neueste, isNull);
      expect(BetriebUpdates.fromJson({'android': 5, 'personsBehind': 'viele'}).personenZurueck, 0);
    });

    test('AppStand: feste Codes, Unbekanntes ist "unbekannt" (nie aktuell), null bleibt null', () {
      expect(AppStand.lesen('current'), AppStand.aktuell);
      expect(AppStand.lesen('outdated'), AppStand.aelter);
      expect(AppStand.lesen('below_min'), AppStand.unterMindestversion);
      expect(AppStand.lesen('inactive'), AppStand.inaktiv);
      expect(AppStand.lesen('unknown'), AppStand.unbekannt);
      expect(AppStand.lesen('neu'), AppStand.unbekannt);
      expect(AppStand.lesen(null), isNull);
      expect(AppStand.aelter.zurueck, isTrue);
      expect(AppStand.unterMindestversion.zurueck, isTrue);
      expect(AppStand.aktuell.zurueck, isFalse);
      expect(AppStand.inaktiv.zurueck, isFalse);
      for (final st in AppStand.values) {
        expect(appStandText(st), isNotEmpty);
      }
    });

    test('Mitglied: Zahl der zurückgebliebenen Geräte und Stand je Gerät; fehlt das Feld (älterer Server), ist es 0 bzw. null', () {
      final m = BetriebMitglied.versuchen({
        'userId': 'u1',
        'displayName': 'Anna',
        'role': 'admin',
        'devicesBehind': 2,
        'devices': [
          {'id': 'd1', 'name': 'Pixel', 'platform': 'android', 'appVersion': '0.6.1', 'appState': 'outdated'},
          {'id': 'd2', 'name': 'Chrome', 'platform': 'web', 'appState': null},
          {'id': 'd3', 'name': 'Alt', 'platform': 'android'},
        ],
      })!;
      expect(m.geraeteZurueck, 2);
      expect(m.geraete.map((g) => g.appStand), [AppStand.aelter, null, null]);
      expect(BetriebMitglied.versuchen({'userId': 'u1', 'displayName': 'Anna', 'role': 'admin'})!.geraeteZurueck, 0);
    });
  });

  group('Update-Stand: Melder', () {
    FampadApi api(FakeServer server) => _api(server);

    test('meldet die Version einmal je Person und Sitzung; ungültige Versionen und fehlende Angaben werden nie gesendet', () async {
      final server = FakeServer()..json('PUT /me/device-info', {'ok': true});
      final melder = GeraetVersionMelder();
      final a = api(server);
      await melder.melden(a, 'u1', null);
      await melder.melden(a, 'u1', '0.7');
      await melder.melden(a, 'u1', 'v0.7.0');
      await melder.melden(a, 'u1', '0.7.0; drop');
      expect(server.anfragen('PUT /me/device-info'), isEmpty);
      await melder.melden(a, 'u1', '0.7.0');
      await melder.melden(a, 'u1', '0.7.0');
      expect(server.anfragen('PUT /me/device-info'), hasLength(1));
      expect(server.anfragen('PUT /me/device-info').single.json, {'appVersion': '0.7.0'});
      // neue Version (nach einem Update) und andere Person werden gemeldet
      await melder.melden(a, 'u1', '0.8.0');
      await melder.melden(a, 'u2', '0.8.0');
      expect(server.anfragen('PUT /me/device-info'), hasLength(3));
    });

    test('älterer Server (404) oder kein Gerät (409): keine weiteren Versuche in dieser Sitzung; sonstige Fehler wiederholt der nächste Start', () async {
      final alt = FakeServer()..on('PUT /me/device-info', (_) => fehler(404, 'not_found'));
      final m1 = GeraetVersionMelder();
      await m1.melden(api(alt), 'u1', '0.7.0');
      await m1.melden(api(alt), 'u1', '0.8.0');
      expect(alt.anfragen('PUT /me/device-info'), hasLength(1));
      final kaputt = FakeServer()..on('PUT /me/device-info', (_) => fehler(500, 'internal'));
      final m2 = GeraetVersionMelder();
      await m2.melden(api(kaputt), 'u1', '0.7.0');
      await m2.melden(api(kaputt), 'u1', '0.7.0');
      expect(kaputt.anfragen('PUT /me/device-info'), hasLength(2), reason: 'ein Serverfehler ist kein Dauerzustand');
    });

    test('eine andere Sitzung (Geräte-Kennung) beginnt von vorn', () async {
      final server = FakeServer()..json('PUT /me/device-info', {'ok': true});
      var sitzung = 'a';
      final melder = GeraetVersionMelder(sitzung: () async => sitzung);
      final a = api(server);
      await melder.melden(a, 'u1', '0.7.0');
      await melder.melden(a, 'u1', '0.7.0');
      expect(server.anfragen('PUT /me/device-info'), hasLength(1));
      sitzung = 'b';
      await melder.melden(a, 'u1', '0.7.0');
      expect(server.anfragen('PUT /me/device-info'), hasLength(2));
    });
  });

  group('Update-Stand: Mitglieder', () {
    Map<String, dynamic> geraet(String id, String name, String version, String? stand, {String platform = 'android'}) => {
      'id': id,
      'name': name,
      'platform': platform,
      'appVersion': version,
      'lastSeenAt': _vor(const Duration(minutes: 20)),
      'keyState': 'unknown',
      'appState': stand,
    };
    Map<String, dynamic> mitglied(String id, String name, List<Map<String, dynamic>> geraete, int zurueck) => {
      'userId': id,
      'displayName': name,
      'role': 'parent',
      'ampel': 'green',
      'hasKeys': true,
      'keyVersion': 1,
      'ways': {'device': true, 'pwBackup': true, 'recoveryBackup': false},
      'events': <Object>[],
      'lastLoginAt': _vor(const Duration(hours: 1)),
      'credentials': {'passkeys': 1, 'password': true, 'totp': true},
      'devicesBehind': zurueck,
      'devices': geraete,
    };

    testWidgets('je Person die Zahl der Geräte auf älterer Version, je Gerät eine Marke nur für zurückgebliebene; Layout 360 px / 1.5', (tester) async {
      await start(
        tester,
        skala: 1.5,
        mitglieder: {
          'generatedAt': _vor(Duration.zero),
          'members': [
            mitglied('u1', 'Anna', [geraet('d1', 'Pixel 9', '0.6.1', 'outdated'), geraet('d2', 'Tablet', '0.3.0', 'below_min'), geraet('d3', 'Chrome', '0.7.0', null, platform: 'web')], 2),
            mitglied('u2', 'Ben', [geraet('d4', 'Galaxy', '0.7.0', 'current')], 0),
          ],
        },
      );
      await seite(tester, 'Mitglieder');
      expect(find.text('2 Geräte auf älterer Version'), findsOneWidget);
      expect(find.text('ältere Version'), findsOneWidget);
      expect(find.text('Update nötig'), findsOneWidget);
      // aktuelle und Web-Geräte bekommen keine Marke
      expect(find.text('aktuell'), findsNothing);
      pruefeLayout(tester, 'Mitglieder mit Update-Stand 1.5');
    });
  });


  group('Nutzung, Verlauf, Wetter und Push: Seite', () {
    testWidgets('zeigt aktuelle Zahlen, Grafiken mit Zusammenfassung, Wetter- und Push-Zähler; schreibt nichts', (tester) async {
      final env = await start(tester, status: () => _status(wetterFehler: 3));
      await seite(tester, 'Nutzung');
      expect(find.text('// NUTZUNG'), findsOneWidget);
      expect(find.text('Aktive Personen'), findsOneWidget);
      expect(find.text('2 · 3'), findsOneWidget);
      expect(find.text('Rate-Limit-Treffer heute'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('// VERLAUF'), 300, scrollable: find.byType(Scrollable).first);
      await warte(tester);
      expect(find.text('30 Tage'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Verlauf aktive personen')), findsOneWidget);
      await tester.scrollUntilVisible(find.text('// WETTER UND PUSH'), 500, scrollable: find.byType(Scrollable).first);
      await warte(tester);
      expect(find.text('Wetter-Dienst'), findsOneWidget);
      expect(find.text('Fehler in Folge'), findsOneWidget);
      expect(find.text('Antwort des Wetterdienstes mit Fehlercode (500)'), findsOneWidget);
      expect(find.text('Geräte mit Wecker'), findsOneWidget);
      expect(find.textContaining('1 deaktiviert · 1 mit Zustellfehler in Folge'), findsOneWidget);
      expect(find.text('Zustellfehler, 24 Stunden'), findsOneWidget);
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
      expect(env.server.anfragen('GET /admin/metrics').single.query['days'], '30');
    });

    testWidgets('Spanne wählen lädt den Verlauf neu; eine späte Antwort der alten Spanne überschreibt nichts', (tester) async {
      final env = await start(tester);
      await seite(tester, 'Nutzung');
      await tester.scrollUntilVisible(find.text('7 Tage'), 300, scrollable: find.byType(Scrollable).first);
      await tippe(tester, find.text('7 Tage'));
      expect(env.server.anfragen('GET /admin/metrics').map((r) => r.query['days']), ['30', '7']);
      await tippe(tester, find.text('365 Tage'));
      expect(env.server.anfragen('GET /admin/metrics').last.query['days'], '365');
    });

    testWidgets('ohne Messpunkte: ruhiger Hinweis; älterer Server (404): "kennt den Verlauf noch nicht"; Push-Block fehlt: Rückfall auf die Zahl der Geräte', (tester) async {
      await start(tester, verlauf: {'generatedAt': _vor(Duration.zero), 'retentionDays': 400, 'days': <Object>[]}, status: () => _status(push: _keine));
      await seite(tester, 'Nutzung');
      await tester.scrollUntilVisible(find.textContaining('alle 5 Minuten'), 300, scrollable: find.byType(Scrollable).first);
      await warte(tester);
      expect(find.textContaining('alle 5 Minuten'), findsOneWidget);
      expect(find.text('Noch keine Messpunkte'), findsWidgets);
      await tester.scrollUntilVisible(find.text('// WETTER UND PUSH'), 500, scrollable: find.byType(Scrollable).first);
      expect(find.text('3 Geräte angemeldet'), findsOneWidget);
    });

    testWidgets('älterer Server ohne Route', (tester) async {
      await start(tester, verlauf: _keine);
      await seite(tester, 'Nutzung');
      await tester.scrollUntilVisible(find.textContaining('kennt den Verlauf noch nicht'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('kennt den Verlauf noch nicht'), findsOneWidget);
    });

    testWidgets('360 px und Textskala 1.5: nichts läuft über, Touch-Ziele mindestens 44 px (oben, Mitte, unten)', (tester) async {
      await start(tester, skala: 1.5, status: () => _status(wetterFehler: 3));
      await seite(tester, 'Nutzung');
      pruefeLayout(tester, 'Nutzung 1.5 oben');
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await warte(tester);
        pruefeLayout(tester, 'Nutzung 1.5 Schritt $i');
      }
    });

    testWidgets('Desktop 1440 px: Nutzung in der Shell', (tester) async {
      await start(tester, groesse: const Size(1440, 900));
      await seite(tester, 'Nutzung');
      expect(find.text('// NUTZUNG'), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      pruefeLayout(tester, 'Nutzung Desktop');
    });
  });

  group('Update-Stand: Seite', () {
    testWidgets('zeigt Versionen und Zähler; Hinweis auf die Personen; nichts Schreibendes', (tester) async {
      final env = await start(tester);
      await seite(tester, 'Nutzung');
      expect(find.text('// UPDATE-STAND'), findsOneWidget);
      expect(find.text('Android-App'), findsOneWidget);
      expect(find.text('Auf der neuesten Version'), findsOneWidget);
      expect(find.text('Auf älterer Version'), findsOneWidget);
      expect(find.text('Unter der Mindestversion'), findsOneWidget);
      expect(find.textContaining('2 Personen haben ein Gerät auf älterer Version'), findsOneWidget);
      expect(find.textContaining('nicht angezeigt'), findsOneWidget);
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
      pruefeLayout(tester, 'Nutzung');
    });

    testWidgets('älterer Server ohne "updates" und ohne Geräte: ruhiger Hinweis', (tester) async {
      await start(tester, status: () => _status(updates: _keine));
      await seite(tester, 'Nutzung');
      expect(find.textContaining('kennt den Update-Stand noch nicht'), findsOneWidget);
    });

    testWidgets('360 px und Textskala 1.5: nichts läuft über, Touch-Ziele mindestens 44 px', (tester) async {
      await start(tester, skala: 1.5);
      await seite(tester, 'Nutzung');
      pruefeLayout(tester, 'Nutzung 1.5');
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
      await warte(tester);
      pruefeLayout(tester, 'Nutzung 1.5 unten');
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
