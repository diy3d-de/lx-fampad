// Betrieb, Paket 2a: Schlüssel-Ampel (Modelle, Anzeige, Familienampel in der Übersicht), Warnungen (Stand, Schalter mit Step-up, Hinweis mit festem Text),
// Seite "Mitglieder und Geräte" (Step-up, Geräte mit Schlüsselstand, Entsperren, Passwort zurücksetzen über den Admin-Ablauf, eigene Geräte abmelden),
// tolerant gegenüber älteren Servern; die Meldung des Schlüsselstands (nur eine Zahl) und der Prüfer des Warnhinweises; Layout (360 px, Textskala 1.5/2.0, Touch 44 px).
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/api_client.dart';
import 'package:lx_fampad/data/api/fampad_api.dart';
import 'package:lx_fampad/data/api/models.dart' show MeDto, Role;
import 'package:lx_fampad/data/api/token_store.dart';
import 'package:lx_fampad/data/app_database.dart';
import 'package:lx_fampad/data/betrieb/betrieb_hinweis.dart';
import 'package:lx_fampad/data/betrieb/betrieb_modelle.dart';
import 'package:lx_fampad/data/crypto/e2ee_state.dart';
import 'package:lx_fampad/data/crypto/geraet_schluessel_melder.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/push/chat_benachrichtiger.dart';
import 'package:lx_fampad/features/auth/step_up.dart';
import 'package:lx_fampad/features/betrieb/betrieb_anzeige.dart';
import 'package:lx_fampad/features/betrieb/betrieb_screen.dart';

import 'support/fake_server.dart';
import 'support/harness.dart';
import 'support/test_app.dart';

const _anna = 'u-anna';
const _ben = 'u-ben';
const _kim = 'u-kim';

Map<String, dynamic> _status() => {
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'overall': 'ok',
  'server': {'version': '0.7.0', 'protocolVersion': 1, 'startedAt': '2026-10-18T08:00:00.000Z', 'uptimeSec': 3 * 86400, 'memoryRssMb': 58},
  'database': {
    'ok': true,
    'latencyMs': 4,
    'sizeBytes': 38 * 1024 * 1024,
    'migrations': {'applied': 21, 'expected': 21, 'latest': '0021_betrieb_paket_2a', 'pending': false},
  },
  'services': [
    {'id': 'api', 'state': 'ok', 'detail': <String, dynamic>{}},
  ],
  'backup': {'state': 'ok', 'lastSuccessAt': DateTime.now().toUtc().subtract(const Duration(hours: 5)).toIso8601String(), 'ageHours': 5, 'totalBytes': 617472, 'lastResult': 'ok'},
  'disk': {'totalBytes': 44 * 1024 * 1024 * 1024, 'freeBytes': 26 * 1024 * 1024 * 1024, 'usedPercent': 41},
  'certificate': {'validTo': '2027-01-14T00:00:00.000Z', 'daysLeft': 85},
  'counts': {'members': 3, 'devices': 4, 'pushDevices': 2, 'activeSessions': 5},
  'versions': {'server': '0.7.0', 'web': null, 'app': null, 'minAppVersion': '0.1.0'},
  'features': {'pwBackup': true, 'legacyPasswordLogin': true, 'weather': false, 'push': true, 'map': {'available': false, 'sizeBytes': null}},
};

Map<String, dynamic> _person(String id, String name, String ampel, {bool device = false, bool pw = false, bool recovery = false, bool hasKeys = true, bool legacy = false, int archive = 0, List<Map<String, dynamic>> events = const []}) => {
  'userId': id,
  'displayName': name,
  'role': 'admin',
  'ampel': ampel,
  'hasKeys': hasKeys,
  'keyVersion': hasKeys ? 1 : null,
  'ways': {'device': device, 'pwBackup': pw, 'recoveryBackup': recovery},
  'wayCount': [device, pw, recovery].where((x) => x).length,
  'devicesTotal': 1,
  'devicesWithKey': device ? 1 : 0,
  'legacyPassword': legacy,
  'archiveCount': archive,
  'events': events,
};

Map<String, dynamic> _keyStatus({bool bereit = false}) => {
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'overall': bereit ? 'green' : 'yellow',
  'ready': bereit,
  'counts': bereit ? {'green': 3, 'yellow': 0, 'red': 0} : {'green': 2, 'yellow': 1, 'red': 0},
  'persons': [
    _person(_anna, 'Anna', 'green', device: true, recovery: true),
    _person(_ben, 'Ben', 'green', device: true, pw: true),
    _person(_kim, 'Kim', bereit ? 'green' : 'yellow', device: true, recovery: bereit),
  ],
};

/// Die Zusammenfassung, die die Übersicht abfragt (`?summary=1`): nur Zähler, keine Namen, keine Ereignisse.
Map<String, dynamic> _zusammenfassung({bool bereit = false}) {
  final k = _keyStatus(bereit: bereit);
  return {'generatedAt': k['generatedAt'], 'overall': k['overall'], 'ready': k['ready'], 'counts': k['counts']};
}

Map<String, dynamic> _geraet(String id, String name, {String platform = 'android', String? version = '0.7.0', String keyState = 'current', int? keyVersion = 1}) => {
  'id': id,
  'name': name,
  'platform': platform,
  'appVersion': version,
  'createdAt': '2026-10-01T08:00:00.000Z',
  'lastSeenAt': DateTime.now().toUtc().subtract(const Duration(minutes: 20)).toIso8601String(),
  'keyState': keyState,
  'keyVersion': keyVersion,
  'keyReportedAt': DateTime.now().toUtc().toIso8601String(),
};

Map<String, dynamic> _mitglied(String id, String name, String ampel, {bool you = false, bool operator = false, String role = 'admin', Map<String, dynamic>? locked, List<Map<String, dynamic>>? devices, bool legacy = false, int archive = 0}) => {
  ..._person(id, name, ampel, device: ampel != 'red', recovery: ampel == 'green', legacy: legacy, archive: archive, events: [
    {'kind': 'key_rotated', 'at': DateTime.now().toUtc().subtract(const Duration(days: 2)).toIso8601String()},
  ]),
  'role': role,
  'familyRole': 'elternteil',
  'operator': operator,
  'you': you,
  'lastLoginAt': DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
  'credentials': {'passkeys': 1, 'password': true, 'totp': true},
  'locked': locked,
  'devices': devices ?? [_geraet('d-$id', 'Pixel von $name')],
};

Map<String, dynamic> _members({Map<String, dynamic>? lock}) => {
  'generatedAt': DateTime.now().toUtc().toIso8601String(),
  'members': [
    _mitglied(_anna, 'Anna', 'green', you: true, operator: true, devices: [_geraet('d-anna-1', 'Pixel 9'), _geraet('d-anna-2', 'Chrome auf Windows', platform: 'web', version: null, keyState: 'unknown', keyVersion: null)]),
    _mitglied(_ben, 'Ben', 'yellow', role: 'parent', legacy: true, archive: 2, locked: lock),
    _mitglied(_kim, 'Kim', 'red', role: 'child', devices: [_geraet('d-kim', 'Galaxy', keyState: 'none', keyVersion: 0)]),
  ],
};

Map<String, dynamic> _warnungen({bool an = true, bool push = true, List<Map<String, dynamic>> aktiv = const [], String? zuletzt}) => {
  'enabled': an,
  'pushAvailable': push,
  'checkedAt': DateTime.now().toUtc().subtract(const Duration(minutes: 3)).toIso8601String(),
  'lastNotifiedAt': zuletzt,
  'active': aktiv,
};

/// Scrollt die Übersicht (lazy gebaut) bis [f] sichtbar ist.
Future<void> _zu(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 250, scrollable: find.byType(Scrollable).first);
  await warte(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(testVorbereiten);

  group('Modelle und Anzeige', () {
    test('Schlüssel-Ampel: Zählung, Familie, "bereit" nur wenn der Server es sagt UND alle grün sind', () {
      final s = SchluesselStatus.fromJson(_keyStatus());
      expect((s.gruen, s.gelb, s.rot, s.anzahl), (2, 1, 0, 3));
      expect(s.gesamt, BetriebAmpel.gelb);
      expect(s.bereit, isFalse);
      expect(familienAmpelText(s), '2 von 3 grün (1 gelb), noch nicht Stichtag-bereit');
      final bereit = SchluesselStatus.fromJson(_keyStatus(bereit: true));
      expect(bereit.bereit, isTrue);
      expect(familienAmpelText(bereit), 'alle grün: Stichtag-bereit');
      // ein Server, der "bereit" meldet, obwohl eine Person nicht grün ist: die App glaubt es nicht
      expect(SchluesselStatus.fromJson({..._keyStatus(), 'ready': true}).bereit, isFalse);
      // ohne Personen nie bereit
      expect(SchluesselStatus.fromJson({'overall': 'green', 'ready': true, 'persons': <Object>[]}).bereit, isFalse);
    });

    test('Zusammenfassung (ohne Personen): Zähler genügen, "bereit" nur bei lauter Grün; fehlende Zähler = nie bereit', () {
      final z = SchluesselStatus.fromJson(_zusammenfassung(bereit: true));
      expect((z.gruen, z.gelb, z.rot, z.anzahl, z.bereit), (3, 0, 0, 3, true));
      expect(z.personen, isEmpty);
      expect(SchluesselStatus.fromJson(_zusammenfassung()).bereit, isFalse);
      expect(SchluesselStatus.fromJson({'overall': 'green', 'ready': true}).bereit, isFalse);
      expect(SchluesselStatus.fromJson({'overall': 'green', 'ready': true, 'counts': {'green': 2}}).bereit, isFalse);
      expect(SchluesselStatus.fromJson({'ready': true, 'counts': {'green': 2, 'yellow': 0, 'red': 0}}).bereit, isTrue);
      expect(familienAmpelText(SchluesselStatus.fromJson({'counts': {'green': 2, 'yellow': 0, 'red': 1}})), '2 von 3 grün (1 rot), noch nicht Stichtag-bereit');
    });

    test('tolerant: unbekannte Ampel = unbekannt (nie grün), kaputte Personen fallen weg, fehlende Felder sind leer', () {
      final s = SchluesselStatus.fromJson({
        'overall': 'lila',
        'persons': [
          {'userId': 'a', 'displayName': 'A', 'ampel': 'regenbogen'},
          {'userId': 'b'},
          'kaputt',
          _person('c', 'C', 'green', device: true, recovery: true),
        ],
      });
      expect(s.gesamt, BetriebAmpel.unbekannt);
      expect(s.personen.map((p) => p.name), ['A', 'C']);
      expect(s.personen.first.ampel, BetriebAmpel.unbekannt);
      expect(s.personen.first.wege.anzahl, 0);
      expect(s.personen.first.ereignisse, isEmpty);
      expect(() => SchluesselStatus.fromJson('kein json'), throwsA(anything));
    });

    test('Mitglieder: Rolle (unbekannt = Kind), Sperre, Geräte mit Schlüsselstand; kaputte Zeilen fallen weg', () {
      final m = BetriebMitglieder.fromJson({
        'members': [
          _mitglied(_anna, 'Anna', 'green', you: true),
          {..._mitglied(_ben, 'Ben', 'yellow', locked: {'until': '2026-10-21T10:00:00.000Z', 'seconds': 45}), 'role': 'gast'},
          {'userId': 'x'},
          'kaputt',
        ],
      });
      expect(m.mitglieder.map((x) => x.name), ['Anna', 'Ben']);
      expect(m.mitglieder[0].ich, isTrue);
      expect(m.mitglieder[1].rolle, Role.child);
      expect(m.mitglieder[1].gesperrtSekunden, 45);
      expect(m.mitglieder[0].gesperrtSekunden, isNull);
      expect(m.mitglieder[0].geraete.single.schluessel, GeraeteSchluesselStand.aktuell);
      final unklar = BetriebGeraet.versuchen({'id': 'd', 'keyState': 'neu', 'name': null});
      expect(unklar!.schluessel, GeraeteSchluesselStand.unbekannt);
      expect(unklar.name, 'Gerät');
      expect(BetriebGeraet.versuchen({'name': 'ohne id'}), isNull);
      expect(BetriebMitglied.versuchen({'userId': 'a', 'displayName': 'A', 'locked': {'seconds': 0}})!.gesperrtSekunden, isNull);
    });

    test('Warnungen: fehlende Angaben gelten als Standard (an), Arten bleiben lesbar', () {
      final w = BetriebWarnungen.fromJson({
        'active': [
          {'kind': 'cert', 'since': '2026-10-21T08:00:00.000Z'},
          {'kind': 'key', 'count': 2},
          {'kind': 'etwas-neues', 'count': 0},
          {'nix': 1},
        ],
      });
      expect(w.aktiv.map((a) => a.anzahl), [1, 2, 1]);
      expect(warnZeile('key', 2), 'Schlüssel-Ampel einer Person ist rot (2)');
      expect(warnZeile('cert', 1), 'Zertifikat läuft in weniger als 14 Tagen ab');
      expect(w.an, isTrue);
      expect(w.pushDa, isFalse);
      expect(w.aktiv.map((a) => a.art), ['cert', 'key', 'etwas-neues']);
      expect(warnArtText('etwas-neues'), 'Hinweis des Servers');
      for (final art in kWarnArten) {
        expect(warnArtText(art), isNot('Hinweis des Servers'), reason: art);
      }
      expect(BetriebWarnungen.fromJson({'enabled': false}).an, isFalse);
    });

    test('feste Texte: Ampel, Geräte-Schlüsselstand, Ereignisse, Protokoll; nie ein Rohcode', () {
      expect(ampelText(BetriebAmpel.gruen), 'grün');
      expect(ampelText(BetriebAmpel.unbekannt), 'unbekannt');
      expect(geraetSchluesselText(GeraeteSchluesselStand.keiner), 'kein Schlüssel');
      expect(schluesselEreignisText('key_rotated'), 'Schlüssel gewechselt');
      expect(schluesselEreignisText('<script>'), 'Ereignis');
      expect(ereignisText('operator_alert_cert'), 'Betrieb-Warnung: Zertifikat');
      expect(ereignisText('operator_alert_key'), 'Betrieb-Warnung: Schlüssel-Ampel');
      expect(ereignisText('operator_unlock'), 'Konto entsperrt');
      expect(ereignisText('operator_warnings_set'), 'Betrieb-Warnungen umgestellt');
      expect(plattformText('android'), 'Android');
      expect(plattformText('x' * 40), hasLength(16));
      expect(sperreText(45), 'noch 45 s');
      expect(sperreText(150), 'noch 3 Min');
      final p = SchluesselPerson.versuchen(_person('a', 'A', 'red', hasKeys: false))!;
      expect(ampelErklaerung(p), 'noch kein Schlüssel eingerichtet');
      expect(ampelErklaerung(SchluesselPerson.versuchen(_person('a', 'A', 'red', recovery: true))!), contains('nur eine Sicherung'));
      expect(ampelErklaerung(SchluesselPerson.versuchen(_person('a', 'A', 'yellow', device: true))!), contains('nur ein Weg'));
    });
  });

  group('Meldung des Schlüsselstands (nur eine Zahl)', () {
    E2eeState z(E2eeStatus s, {int? version}) => E2eeState(
      status: s,
      serverSchluessel: version == null ? null : OeffentlicheSchluessel(enc: Uint8List(32), sign: Uint8List(32), version: version),
    );

    test('Zahl je Zustand: Version bei "bereit", 0 ohne passenden Schlüssel, nichts solange unklar', () {
      expect(geraetSchluesselStand(z(E2eeStatus.bereit, version: 3)), 3);
      expect(geraetSchluesselStand(z(E2eeStatus.bereit)), isNull);
      expect(geraetSchluesselStand(z(E2eeStatus.keinSchluessel)), 0);
      expect(geraetSchluesselStand(z(E2eeStatus.geraetNichtVerbunden, version: 2)), 0);
      expect(geraetSchluesselStand(z(E2eeStatus.abweichend, version: 2)), 0);
      expect(geraetSchluesselStand(z(E2eeStatus.laedt)), isNull);
      expect(geraetSchluesselStand(z(E2eeStatus.nichtVerfuegbar)), isNull);
    });

    FampadApi apiMit(FakeServer server) => _api(server);

    test('meldet nur Neues (je Person und Zahl), erzwingt auf Wunsch, sendet nur {keyVersion: n}', () async {
      final server = FakeServer()..json('PUT /me/device-key', {'ok': true});
      final api = apiMit(server);
      final m = GeraetSchluesselMelder();
      await m.melden(api, 'p1', 2);
      await m.melden(api, 'p1', 2);
      expect(server.anfragen('PUT /me/device-key'), hasLength(1));
      expect(server.anfragen('PUT /me/device-key').single.json, {'keyVersion': 2});
      await m.melden(api, 'p1', 3);
      await m.melden(api, 'p2', 3);
      await m.melden(api, 'p2', 3, erzwingen: true);
      expect(server.anfragen('PUT /me/device-key'), hasLength(4));
    });

    test('Auffrischen beim Zurückkehren: erst nach 12 Stunden erneut, nie ohne klaren Stand oder ohne Person', () async {
      final server = FakeServer()..json('PUT /me/device-key', {'ok': true});
      final api = apiMit(server);
      final user = MeDto.fromJson(meJson()).user;
      final m = GeraetSchluesselMelder();
      final bereit = z(E2eeStatus.bereit, version: 2);
      await m.auffrischen(api, user, z(E2eeStatus.laedt));
      await m.auffrischen(api, null, bereit);
      expect(server.anfragen('PUT /me/device-key'), isEmpty);
      await m.auffrischen(api, user, bereit);
      await m.auffrischen(api, user, bereit);
      expect(server.anfragen('PUT /me/device-key'), hasLength(1));
      await m.auffrischen(api, user, bereit, abstand: Duration.zero);
      expect(server.anfragen('PUT /me/device-key'), hasLength(2));
      expect(server.anfragen('PUT /me/device-key').last.json, {'keyVersion': 2});
    });

    test('ein Stand, der während eines laufenden Aufrufs eintrifft, wird nachgeholt (nur der neueste, nie parallel)', () async {
      final erste = Completer<void>();
      var offen = 0;
      var parallel = 0;
      final gesehen = <int>[];
      final server = FakeServer()
        ..on('PUT /me/device-key', (r) async {
          offen++;
          if (offen > parallel) parallel = offen;
          gesehen.add(r.json['keyVersion'] as int);
          if (gesehen.length == 1) await erste.future;
          offen--;
          return jsonAntwort({'ok': true});
        });
      final api = apiMit(server);
      final m = GeraetSchluesselMelder();
      final lauf = m.melden(api, 'p', 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await m.melden(api, 'p', 2); // trifft während des ersten Aufrufs ein
      await m.melden(api, 'p', 3); // der neueste gewinnt
      erste.complete();
      await lauf;
      expect(gesehen, [1, 3]);
      expect(parallel, 1);
    });

    test('Sitzungswechsel (andere Geräte-ID): ein früheres 404 und das Gemerkte gelten nicht mehr', () async {
      var sitzung = 'dev-1';
      var neuerServer = false;
      final server = FakeServer()..on('PUT /me/device-key', (_) => neuerServer ? jsonAntwort({'ok': true}) : fehler(404, 'not_found'));
      final api = apiMit(server);
      final m = GeraetSchluesselMelder(sitzung: () async => sitzung);
      await m.melden(api, 'p', 1);
      await m.melden(api, 'p', 2); // gesperrt für diese Sitzung
      expect(server.anfragen('PUT /me/device-key'), hasLength(1));
      sitzung = 'dev-2'; // neu angemeldet, der Server kann es jetzt
      neuerServer = true;
      await m.melden(api, 'p', 2);
      expect(server.anfragen('PUT /me/device-key'), hasLength(2));
      await m.melden(api, 'p', 2); // dieselbe Sitzung, schon gemeldet
      expect(server.anfragen('PUT /me/device-key'), hasLength(2));
      sitzung = 'dev-3'; // wieder eine neue Sitzung: dieselbe Zahl wird neu gemeldet
      await m.melden(api, 'p', 2);
      expect(server.anfragen('PUT /me/device-key'), hasLength(3));
    });

    test('älterer Server (404) oder Sitzung ohne Gerät (409): keine weiteren Versuche; andere Fehler: der nächste Auslöser versucht es erneut', () async {
      final alt = FakeServer(); // keine Route = 404
      final a = GeraetSchluesselMelder();
      await a.melden(apiMit(alt), 'p', 1);
      await a.melden(apiMit(alt), 'p', 2);
      expect(alt.anfragen('PUT /me/device-key'), hasLength(1));

      final kein = FakeServer()..on('PUT /me/device-key', (_) => fehler(409, 'no_device'));
      final k = GeraetSchluesselMelder();
      await k.melden(apiMit(kein), 'p', 1);
      await k.melden(apiMit(kein), 'p', 2);
      expect(kein.anfragen('PUT /me/device-key'), hasLength(1));

      var versuche = 0;
      final gestoert = FakeServer()
        ..on('PUT /me/device-key', (_) {
          versuche++;
          return versuche == 1 ? fehler(500, 'internal') : jsonAntwort({'ok': true});
        });
      final g = GeraetSchluesselMelder();
      await g.melden(apiMit(gestoert), 'p', 1);
      await g.melden(apiMit(gestoert), 'p', 1);
      await g.melden(apiMit(gestoert), 'p', 1);
      expect(gestoert.anfragen('PUT /me/device-key'), hasLength(2));
    });
  });

  group('Warnhinweis auf dem Gerät', () {
    Future<_PruefAufbau> bauen({bool betreiber = true, DateTime Function()? jetzt}) async {
      final server = FakeServer();
      final api = _api(server);
      final db = AppDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      addTearDown(db.close);
      final anzeige = _FakeAnzeige();
      final p = BetriebWarnPruefer(api: api, db: db, anzeige: anzeige, jetzt: jetzt);
      if (betreiber) await p.betreiberMerken(true);
      return _PruefAufbau(p, server, db, anzeige);
    }

    final t0 = DateTime.utc(2026, 10, 21, 8);

    test('kein Betreiber-Flag: es gibt nie eine Anfrage nach /admin', () async {
      final a = await bauen(betreiber: false);
      a.server.json('GET /admin/warnings', _warnungen(zuletzt: t0.toIso8601String()));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      await a.pruefer.grundlinieSetzen();
      expect(a.server.log, isEmpty);
      expect(a.anzeige.gezeigt, isEmpty);
    });

    test('Grundlinie: der Bestand beim ersten Mal ist nichts Neues; ein späterer Wecker meldet mit festem Text und fester Nutzlast, genau einmal', () async {
      final a = await bauen();
      a.server.json('GET /admin/warnings', _warnungen(zuletzt: t0.toIso8601String()));
      await a.pruefer.grundlinieSetzen();
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.gezeigt, isEmpty);
      // neue Warnung
      a.server.json('GET /admin/warnings', _warnungen(zuletzt: t0.add(const Duration(hours: 7)).toIso8601String(), aktiv: [
        {'kind': 'disk', 'since': t0.toIso8601String()},
      ]));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.gezeigt, hasLength(1));
      final g = a.anzeige.gezeigt.single;
      expect(g.titel, 'Betrieb: Hinweis – öffne Betrieb');
      expect(g.nutzlast, kBetriebPayload);
      // nie eine Einzelheit (Art, Person, Zahl) im Text
      expect('${g.titel} ${g.text}'.toLowerCase(), isNot(anyOf(contains('speicher'), contains('disk'), contains('zertifikat'), contains('%'))));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.gezeigt, hasLength(1));
    });

    test('Vordergrund: nur der Rückruf (die Oberfläche zeigt den festen Text), der Stand rückt vor; Hintergrund ohne Erlaubnis: der Stand bleibt', () async {
      final a = await bauen();
      a.server.json('GET /admin/warnings', _warnungen(zuletzt: t0.toIso8601String()));
      var hinweise = 0;
      await a.pruefer.pruefenUndMelden(vordergrund: true, hinweis: () => hinweise++);
      expect(hinweise, 1);
      expect(a.anzeige.gezeigt, isEmpty);
      await a.pruefer.pruefenUndMelden(vordergrund: true, hinweis: () => hinweise++);
      expect(hinweise, 1);
      // ohne Erlaubnis zeigt der Hintergrund nichts und merkt es sich nicht als gesehen
      a.server.json('GET /admin/warnings', _warnungen(zuletzt: t0.add(const Duration(days: 1)).toIso8601String()));
      a.anzeige.erlaubt = false;
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.gezeigt, isEmpty);
      a.anzeige.erlaubt = true;
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.gezeigt, hasLength(1));
    });

    test('Warnungen ausgeschaltet: keine Meldung; Mindestabstand der Weckrufe; 404 löscht das lokale Flag', () async {
      var jetzt = t0;
      final a = await bauen(jetzt: () => jetzt);
      a.server.json('GET /admin/warnings', _warnungen(an: false, zuletzt: t0.add(const Duration(hours: 1)).toIso8601String()));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.anzeige.gezeigt, isEmpty);
      // Mindestabstand: der zweite Weckruf direkt danach fragt gar nicht erst nach
      final vorher = a.server.anfragen('GET /admin/warnings').length;
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kBetriebMindestabstand);
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kBetriebMindestabstand);
      expect(a.server.anfragen('GET /admin/warnings'), hasLength(vorher));
      jetzt = jetzt.add(const Duration(minutes: 6));
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kBetriebMindestabstand);
      await a.pruefer.pruefenUndMelden(vordergrund: false, mindestAbstand: kBetriebMindestabstand);
      expect(a.server.anfragen('GET /admin/warnings'), hasLength(vorher + 1));
      // kein Betreiber mehr (404): das Flag verschwindet, weitere Weckrufe fragen nicht mehr
      a.server.on('GET /admin/warnings', (_) => fehler(404, 'not_found'));
      jetzt = jetzt.add(const Duration(minutes: 6));
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(await a.db.metaLesen(kBetriebBetreiberSchluessel), isNull);
      final n = a.server.log.length;
      await a.pruefer.pruefenUndMelden(vordergrund: false);
      expect(a.server.log, hasLength(n));
    });
  });

  Future<TestUmgebung> start(
    WidgetTester tester, {
    Object Function()? keyStatus,
    Object Function()? mitglieder,
    Object Function()? warnungen,
    bool oeffnen = true,
    double skala = 1.0,
    Size groesse = const Size(360, 800),
    void Function(TestUmgebung env)? vorStart,
  }) async {
    final env = await angemeldeteUmgebung();
    env.server.json('GET /me', {...meJson(role: 'admin', passkeys: 1, password: true, totp: true), 'operator': true});
    env.server.on('GET /admin/status', (_) => jsonAntwort(_status()));
    env.server.on('GET /admin/audit', (_) => jsonAntwort({'items': <Object>[], 'nextCursor': null}));
    env.server.on('GET /admin/key-status', (_) => jsonAntwort(keyStatus == null ? _zusammenfassung() : keyStatus()));
    env.server.on('GET /admin/members', (_) => jsonAntwort(mitglieder == null ? _members() : mitglieder()));
    env.server.on('GET /admin/warnings', (_) => jsonAntwort(warnungen == null ? _warnungen() : warnungen()));
    vorStart?.call(env);
    await starteApp(tester, env, skala: skala, groesse: groesse);
    if (oeffnen) {
      if (groesse.width >= 900) {
        await tippe(tester, find.text('Betrieb').last);
      } else {
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippe(tester, find.text('Betrieb').last);
      }
    }
    return env;
  }

  group('Übersicht: Schlüssel-Ampel und Warnungen', () {
    testWidgets('Familienampel mit Personen und Erklärung; Warnstatus ohne aktive Warnung', (tester) async {
      final env = await start(tester);
      await _zu(tester, labelFinder('Schlüssel-ampel'));
      expect(labelFinder('Schlüssel-ampel'), findsOneWidget);
      expect(find.text('gelb'), findsOneWidget);
      expect(find.text('2 von 3 grün (1 gelb), noch nicht Stichtag-bereit'), findsOneWidget);
      // die Übersicht kennt nur Zähler: keine Namen (die stehen auf der Seite Mitglieder, mit Bestätigung)
      expect(find.textContaining('Anna'), findsNothing);
      expect(env.server.anfragen('GET /admin/key-status').every((r) => r.query['summary'] == '1'), isTrue);
      await _zu(tester, labelFinder('Warnungen'));
      expect(labelFinder('Warnungen'), findsOneWidget);
      expect(find.text('Warnungen an dich'), findsOneWidget);
      expect(find.textContaining('Keine aktive Warnung'), findsOneWidget);
      // beim Öffnen nur lesen
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
    });

    testWidgets('alle grün: "Stichtag-bereit" in Grün; aktive Warnungen mit festem Text und Zeit', (tester) async {
      await start(
        tester,
        keyStatus: () => _zusammenfassung(bereit: true),
        warnungen: () => _warnungen(zuletzt: '2026-10-21T08:00:00.000Z', aktiv: [
          {'kind': 'cert', 'since': DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String()},
          {'kind': 'key', 'since': null, 'count': 2},
          {'kind': 'etwas-neues', 'since': null},
        ]),
      );
      await _zu(tester, labelFinder('Schlüssel-ampel'));
      expect(find.text('grün'), findsOneWidget);
      expect(find.text('alle grün: Stichtag-bereit'), findsOneWidget);
      await _zu(tester, labelFinder('Warnungen'));
      expect(find.text('Zertifikat läuft in weniger als 14 Tagen ab'), findsOneWidget);
      expect(find.text('Schlüssel-Ampel einer Person ist rot (2)'), findsOneWidget);
      expect(find.text('Hinweis des Servers'), findsOneWidget);
      expect(find.textContaining('Keine aktive Warnung'), findsNothing);
    });

    testWidgets('ohne Push auf dem Server: ehrlicher Hinweis', (tester) async {
      await start(tester, warnungen: () => _warnungen(push: false));
      await _zu(tester, labelFinder('Warnungen'));
      expect(find.textContaining('Push ist auf dem Server nicht eingerichtet'), findsOneWidget);
    });

    testWidgets('älterer Server (404): ruhiger Hinweis statt Fehler, der Rest der Seite bleibt', (tester) async {
      await start(
        tester,
        vorStart: (env) {
          env.server.on('GET /admin/key-status', (_) => fehler(404, 'not_found'));
          env.server.on('GET /admin/warnings', (_) => fehler(404, 'not_found'));
        },
      );
      await _zu(tester, labelFinder('Warnungen'));
      expect(find.text('Dieser Server kennt das noch nicht (älterer Stand).'), findsNWidgets(2));
      expect(find.text('alles in Ordnung'), findsOneWidget);
      expect(labelFinder('Dienste'), findsOneWidget);
    });

    testWidgets('Schalter "Warnungen": Step-up, dann PUT {enabled: false}; Hinweis "Aus"', (tester) async {
      var bestaetigt = false;
      var an = true;
      final env = await start(
        tester,
        warnungen: () => _warnungen(an: an),
        vorStart: (env) {
          env.server.on('PUT /admin/warnings', (r) {
            if (!bestaetigt) return fehler(403, 'step_up_required');
            an = r.json['enabled'] == true;
            return jsonAntwort(_warnungen(an: an));
          });
          env.server.json('POST /auth/step-up/passkey/options', {'challengeId': 'c1', 'options': {'challenge': 'abc'}});
          env.server.on('POST /auth/step-up/passkey/verify', (_) {
            bestaetigt = true;
            return jsonAntwort({'stepUpAt': DateTime.now().toUtc().toIso8601String()});
          });
        },
      );
      await _zu(tester, labelFinder('Warnungen'));
      await tippe(tester, find.byType(Switch));
      expect(find.byType(StepUpDialog), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(an, isTrue);
      await tippe(tester, find.byType(Switch));
      await tippe(tester, find.text('Mit Passkey bestätigen'));
      expect(bestaetigt, isTrue);
      expect(env.server.anfragen('PUT /admin/warnings').last.json, {'enabled': false});
      expect(an, isFalse);
      expect(find.textContaining('Aus: der Server prüft weiter'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('"Einzelheiten je Person" wechselt zur Seite Mitglieder', (tester) async {
      await start(tester);
      await _zu(tester, find.text('Einzelheiten je Person (mit Bestätigung)'));
      await tippe(tester, find.text('Einzelheiten je Person (mit Bestätigung)'));
      expect(labelFinder('Mitglieder und Geräte'), findsOneWidget);
    });
  });

  group('Mitglieder und Geräte', () {
    testWidgets('Mitglieder mit Rolle, Ampel, Wegen, Geräten und Schlüsselstand; keine E-Mail, kein Schlüsselmaterial', (tester) async {
      final env = await start(tester);
      await tippe(tester, find.text('Mitglieder'));
      expect(labelFinder('Mitglieder und Geräte'), findsOneWidget);
      expect(find.text('Anna (du)'), findsOneWidget);
      expect(find.text('Ben'), findsOneWidget);
      expect(find.text('Kim'), findsOneWidget);
      expect(find.text('grün'), findsWidgets);
      expect(find.text('rot'), findsOneWidget);
      expect(find.text('betreiber'), findsOneWidget);
      expect(find.text('Pixel 9'), findsOneWidget);
      expect(find.textContaining('Android · 0.7.0 · zuletzt '), findsWidgets);
      expect(find.text('Schlüssel aktuell'), findsWidgets);
      expect(find.text('Stand unbekannt'), findsOneWidget);
      expect(find.text('kein Schlüssel'), findsOneWidget);
      expect(find.text('altes Passwort-Verfahren'), findsOneWidget);
      expect(find.text('2 archivierte Sicherungen'), findsOneWidget);
      expect(find.textContaining('Schlüssel gewechselt · '), findsWidgets);
      expect(find.textContaining('@'), findsNothing);
      expect(env.server.log.where((r) => r.path.startsWith('/admin') && r.method != 'GET'), isEmpty);
    });

    testWidgets('ohne frische Bestätigung: Knopf "Bestätigen und anzeigen", nach der Bestätigung erscheint die Liste', (tester) async {
      var bestaetigt = false;
      await start(
        tester,
        vorStart: (env) {
          env.server.on('GET /admin/members', (_) => bestaetigt ? jsonAntwort(_members()) : fehler(403, 'step_up_required'));
          env.server.json('POST /auth/step-up/passkey/options', {'challengeId': 'c1', 'options': {'challenge': 'abc'}});
          env.server.on('POST /auth/step-up/passkey/verify', (_) {
            bestaetigt = true;
            return jsonAntwort({'stepUpAt': DateTime.now().toUtc().toIso8601String()});
          });
        },
      );
      await tippe(tester, find.text('Mitglieder'));
      // das Öffnen der Seite fragt schon nach der Bestätigung (Dialog): abbrechen, der Knopf bleibt (unabhängig von der Höhe der Reiterleiste)
      if (find.byType(StepUpDialog).evaluate().isNotEmpty) await tippe(tester, find.text('Abbrechen'));
      expect(find.text('Anna (du)'), findsNothing);
      expect(find.text('Bestätigen und anzeigen'), findsOneWidget);
      await tippe(tester, find.text('Bestätigen und anzeigen'));
      expect(find.byType(StepUpDialog), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(find.text('Bestätigen und anzeigen'), findsOneWidget);
      await tippe(tester, find.text('Bestätigen und anzeigen'));
      await tippe(tester, find.text('Mit Passkey bestätigen'));
      expect(find.text('Anna (du)'), findsOneWidget);
    });

    testWidgets('gesperrtes Konto: "Entsperren" (Step-up) sendet POST und lädt neu', (tester) async {
      var gesperrt = true;
      final env = await start(
        tester,
        mitglieder: () => _members(lock: gesperrt ? {'until': '2026-10-21T10:00:00.000Z', 'seconds': 45} : null),
        vorStart: (env) {
          env.server.on('POST /admin/members/$_ben/unlock', (_) {
            gesperrt = false;
            return jsonAntwort({'cleared': true});
          });
        },
      );
      await tippe(tester, find.text('Mitglieder'));
      expect(find.text('gesperrt · noch 45 s'), findsOneWidget);
      await tippe(tester, find.text('Entsperren'));
      expect(env.server.anfragen('POST /admin/members/$_ben/unlock'), hasLength(1));
      expect(find.text('gesperrt · noch 45 s'), findsNothing);
      expect(find.text('Entsperren'), findsNothing);
      // nur Ben wurde angefasst
      expect(env.server.log.where((r) => r.path.contains('/unlock')).map((r) => r.path), ['/admin/members/$_ben/unlock']);
    });

    testWidgets('"Passwort zurücksetzen" nur bei anderen Personen und nur als Admin; es öffnet den Admin-Ablauf und ändert selbst nichts', (tester) async {
      final env = await start(tester);
      await tippe(tester, find.text('Mitglieder'));
      // Anna (du): kein Knopf; Ben und Kim: je einer
      expect(find.text('Passwort zurücksetzen'), findsNWidgets(2));
      await tippe(tester, find.text('Passwort zurücksetzen').first);
      expect(find.text('Familie verwalten'), findsOneWidget);
      expect(env.server.log.where((r) => r.path.contains('password-reset')), isEmpty);
    });

    testWidgets('"Andere Geräte abmelden" gilt nur für die eigenen Geräte: Rückfrage, dann DELETE je anderem Gerät', (tester) async {
      final env = await start(
        tester,
        vorStart: (env) {
          env.server.json('GET /devices', {
            'devices': [
              {'id': 'd-anna-1', 'name': 'Pixel 9', 'platform': 'android', 'appVersion': '0.7.0', 'createdAt': '2026-10-01T08:00:00.000Z', 'lastSeenAt': null, 'current': true},
              {'id': 'd-anna-2', 'name': 'Chrome auf Windows', 'platform': 'web', 'appVersion': null, 'createdAt': '2026-10-02T08:00:00.000Z', 'lastSeenAt': null, 'current': false},
            ],
          });
          env.server.json('DELETE /devices/d-anna-2', {'ok': true});
        },
      );
      await tippe(tester, find.text('Mitglieder'));
      // nur an der eigenen Karte (Ben und Kim haben keinen solchen Knopf)
      expect(find.text('Andere Geräte abmelden'), findsOneWidget);
      await tippe(tester, find.text('Andere Geräte abmelden'));
      expect(find.text('Andere Geräte abmelden?'), findsOneWidget);
      await tippe(tester, find.text('Abbrechen'));
      expect(env.server.anfragen('DELETE /devices/d-anna-2'), isEmpty);
      await tippe(tester, find.text('Andere Geräte abmelden'));
      await tippe(tester, find.text('Abmelden'));
      expect(env.server.anfragen('DELETE /devices/d-anna-2'), hasLength(1));
      expect(env.server.log.where((r) => r.method == 'DELETE').map((r) => r.path), ['/devices/d-anna-2']);
    });

    testWidgets('älterer Server (404 auf /admin/members): Fehlermeldung ohne Servertext, die anderen Seiten bleiben benutzbar', (tester) async {
      await start(tester, vorStart: (env) => env.server.on('GET /admin/members', (_) => fehler(404, 'not_found', message: 'GEHEIMER-SERVERTEXT')));
      await tippe(tester, find.text('Mitglieder'));
      expect(find.textContaining('GEHEIMER-SERVERTEXT'), findsNothing);
      await tippe(tester, find.text('Übersicht'));
      expect(labelFinder('Dienste'), findsOneWidget);
    });
  });

  group('Hinweis im Vordergrund', () {
    testWidgets('fester Text mit "Öffnen", der Betrieb öffnet; sonst nichts', (tester) async {
      await start(tester, oeffnen: false);
      final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      container.read(betriebHinweisProvider.notifier).zeigen();
      await warte(tester);
      expect(find.text('Betrieb: Hinweis – öffne Betrieb'), findsOneWidget);
      expect(find.text('Öffnen'), findsOneWidget);
      await tippe(tester, find.text('Öffnen'));
      expect(find.byType(BetriebScreen), findsOneWidget);
    });
  });

  group('Layout', () {
    for (final skala in [1.0, 1.5, 2.0]) {
      testWidgets('360 px, Textskala $skala: Übersicht und Mitglieder laufen nicht über, Touch-Ziele mindestens 44 px', (tester) async {
        // erst bei normaler Schrift zur Seite, dann vergrößern: die Startseite und das Profil laufen bei 2.0 über (nicht Teil dieses Pakets)
        await start(tester, oeffnen: false, mitglieder: () => _members(lock: {'until': '2026-10-21T10:00:00.000Z', 'seconds': 45}));
        await tippe(tester, find.byTooltip('Profil und Sicherheit'));
        await tippe(tester, find.text('Betrieb').last);
        tester.platformDispatcher.textScaleFactorTestValue = skala;
        await warte(tester);
        tester.takeException();
        pruefeLayout(tester, 'Übersicht oben $skala');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await warte(tester);
        pruefeLayout(tester, 'Übersicht Ampel/Warnungen $skala');
        await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
        await warte(tester);
        await tippe(tester, find.text('Mitglieder'));
        pruefeLayout(tester, 'Mitglieder oben $skala');
        for (var i = 0; i < 4; i++) {
          await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
          await warte(tester);
          pruefeLayout(tester, 'Mitglieder $i $skala');
        }
      });
    }

    testWidgets('Desktop 1440 px: Mitglieder in der Shell, Seitenleiste und Fußzeile bleiben', (tester) async {
      await start(tester, groesse: const Size(1440, 900));
      await tippe(tester, find.text('Mitglieder'));
      expect(find.text('Anna (du)'), findsOneWidget);
      expect(find.text('lx-familyhub'), findsOneWidget);
      expect(find.text('Version dev'), findsOneWidget);
      pruefeLayout(tester, 'Betrieb Mitglieder Desktop');
    });
  });
}

// ------------------------------------------------------------------------------------------------------------------------------------------------ Hilfen

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

class _Gezeigt {
  final int id;
  final String titel;
  final String text;
  final String nutzlast;
  _Gezeigt(this.id, this.titel, this.text, this.nutzlast);
}

class _FakeAnzeige implements ChatAnzeigePort {
  final gezeigt = <_Gezeigt>[];
  bool erlaubt = true;

  @override
  Future<bool> initialisieren() async => erlaubt;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, int? anzahl}) async => true;

  @override
  Future<bool> zeigenSicherheit({required int id, required String titel, required String text, String nutzlast = 'sicherheit'}) async {
    gezeigt.add(_Gezeigt(id, titel, text, nutzlast));
    return true;
  }

  @override
  Future<void> entfernen(int id) async {}
}

class _PruefAufbau {
  final BetriebWarnPruefer pruefer;
  final FakeServer server;
  final AppDatabase db;
  final _FakeAnzeige anzeige;
  _PruefAufbau(this.pruefer, this.server, this.db, this.anzeige);
}
