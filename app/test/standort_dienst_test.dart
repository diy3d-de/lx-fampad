// Standort teilen, Steuerung: Start und Ende, Empfänger, Drosselung der Positionen, Empfang, Ablauf, Replay, ungeprüfte Absender.
// Zwei Controller (Anna, Ben) mit je eigenem Fake-Socket; ein kleiner Relay im Test bildet den Server nach (Weitergabe nur an die Empfänger).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/api/models.dart';
import 'package:lx_fampad/data/auth/auth_state.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/crypto/schluessel.dart';
import 'package:lx_fampad/data/standort/standort_dienst.dart';
import 'package:lx_fampad/data/standort/standort_modelle.dart';
import 'package:lx_fampad/data/standort/standort_port.dart';
import 'package:lx_fampad/data/sync/sync_socket.dart';

import 'support/fake_crypto.dart';
import 'support/fake_socket.dart';

const _anna = 'a0000000-0000-4000-8000-00000000000a';
const _ben = 'b0000000-0000-4000-8000-00000000000b';
const _cora = 'c0000000-0000-4000-8000-00000000000c';

class _FakeAuth extends AuthController {
  final UserDto user;
  _FakeAuth(this.user);

  @override
  AuthState build() => AuthState(status: AuthStatus.angemeldet, user: user);
}

class _FakePort implements StandortPort {
  StandortStatus statusWert = const StandortStatus(fein: true, grob: true, benachrichtigungen: true, dienstAn: true);
  StartFehler? startFehler;
  var verfuegbarWert = true;
  var gestartet = 0;
  var gestoppt = 0;
  DateTime? ende;
  final verlaengert = <DateTime>[];
  ({bool laeuft, bool stopAngefordert}) herz = (laeuft: true, stopAngefordert: false);
  final ctrl = StreamController<StandortEreignis>.broadcast();

  @override
  bool get verfuegbar => verfuegbarWert;
  @override
  Future<StandortStatus> status() async => statusWert;
  @override
  Future<StandortStatus> berechtigungAnfragen() async => statusWert;
  @override
  Future<StartFehler?> starten(DateTime e) async {
    if (startFehler != null) return startFehler;
    gestartet++;
    ende = e;
    return null;
  }

  @override
  Future<void> verlaengern(DateTime e) async => verlaengert.add(e);
  @override
  Future<void> stoppen() async => gestoppt++;
  @override
  Future<({bool laeuft, bool stopAngefordert})> herzschlag() async => herz;
  @override
  Stream<StandortEreignis> get ereignisse => ctrl.stream;
  @override
  Future<bool> einstellungenOeffnen() async => true;
  @override
  Future<bool> akkuEinstellungenOeffnen() async => true;
}

UserDto _user(String id, String name, Role r) => UserDto(id: id, email: null, displayName: name, colorIndex: 1, role: r, status: MemberStatus.active);

/// Ein Gerät: Container, Port, Socket und Schlüssel.
class _Geraet {
  final String id;
  final Personenschluessel pk;
  final int version;
  final _FakePort port = _FakePort();
  final FakeSocketFabrik sockets = FakeSocketFabrik();
  late final ProviderContainer c;
  DateTime jetzt;
  int gelesen = 0;

  /// Schlüssel, denen dieses Gerät vertraut (TOFU); fehlt eine Person, ist sie unbestätigt.
  final Map<String, OeffentlicheSchluessel> vertraut = {};

  _Geraet(this.id, CryptoProvider crypto, this.version, this.jetzt, {UserDto? user, StandortZeiten zeiten = const StandortZeiten()}) : pk = Personenschluessel.erzeugen(crypto) {
    c = ProviderContainer(
      overrides: <Override>[
        authProvider.overrideWith(() => _FakeAuth(user ?? _user(id, 'Person', Role.parent))),
        standortPortProvider.overrideWithValue(port),
        standortUhrProvider.overrideWith((ref) => () => jetzt),
        standortZeitenProvider.overrideWithValue(zeiten),
        standortSchluesselProvider.overrideWith(
          (ref) => () async => StandortSchluessel(
            crypto: crypto,
            ichId: id,
            schluessel: pk,
            keyVersion: version,
            vertrauenswuerdig: (u) async => vertraut[u],
            gemerkt: (u) async => vertraut[u],
          ),
        ),
        standortSocketFabrikProvider.overrideWith(
          (ref) => ({required beiNachricht, required beiStatus}) => SyncSocket(
            ticket: () async => 't',
            beiRev: (_) {},
            beiStatus: beiStatus,
            beiNachricht: beiNachricht,
            oeffner: sockets.oeffner,
            adresse: () => Uri.parse('wss://familie.test/ws'),
          ),
        ),
      ],
    );
  }

  StandortController get ctrl => c.read(standortProvider.notifier);
  StandortState get st => c.read(standortProvider);
  FakeSocket get socket => sockets.letzter;

  /// Neue Nachrichten, die dieses Gerät an den Server geschickt hat (ohne auth und ping).
  /// Kennung der zuletzt gesendeten Freigabe.
  String? get letzteShareId {
    final m = socket.gesendet.lastWhere((m) => m['type'] == 'loc_start', orElse: () => const {});
    return m['shareId'] as String?;
  }

  FakeSocket? _gelesenVon;

  List<Map<String, dynamic>> neueNachrichten() {
    if (!identical(_gelesenVon, socket)) {
      _gelesenVon = socket;
      gelesen = 0;
    }
    final alle = [for (final m in socket.gesendet) if ((m['type'] as String).startsWith('loc_')) m];
    final neu = alle.sublist(gelesen);
    gelesen = alle.length;
    return neu;
  }

  Future<void> starten() async {
    // Startet den Empfang und wartet, bis die Verbindung steht
    ctrl.starten();
    await pumpen();
  }

  void schliessen() => c.dispose();
}

Future<void> pumpen([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Der "Server": gibt Nachrichten von [von] an die Empfänger weiter (wie server/src/location/service.ts, nur das Nötigste).
class _Relay {
  final Map<String, _Geraet> geraete;
  _Relay(this.geraete);

  String? letzteShare;

  /// Verarbeitet die neuen Nachrichten von [von]; liefert sie zur Kontrolle zurück.
  Future<List<Map<String, dynamic>>> weiter(_Geraet von) async {
    final neu = von.neueNachrichten();
    for (final m in neu) {
      switch (m['type']) {
        case 'loc_start':
          letzteShare = m['shareId'] as String;
          von.socket.vomServer({'type': 'loc_started', 'shareId': m['shareId'], 'endsAt': m['endsAt']});
          for (final r in (m['recipients'] as List).cast<Map<String, dynamic>>()) {
            geraete[r['userId']]?.socket.vomServer({'type': 'loc_start', 'from': von.id, 'shareId': m['shareId'], 'endsAt': m['endsAt'], 'wrap': r['wrap']});
          }
        case 'loc_pos':
          for (final g in geraete.values.where((g) => g.id != von.id)) {
            g.socket.vomServer({'type': 'loc_pos', 'from': von.id, 'shareId': m['shareId'], 'packet': m['packet']});
          }
        case 'loc_extend':
          for (final g in geraete.values.where((g) => g.id != von.id)) {
            g.socket.vomServer({'type': 'loc_extend', 'from': von.id, 'shareId': m['shareId'], 'endsAt': m['endsAt']});
          }
        case 'loc_stop':
          for (final g in geraete.values.where((g) => g.id != von.id)) {
            g.socket.vomServer({'type': 'loc_stop', 'from': von.id, 'shareId': m['shareId'], 'reason': 'stopped'});
          }
      }
    }
    await pumpen();
    return neu;
  }
}

GeraetePosition _pos(DateTime t, {double lat = 48.1372, double lon = 11.5755, double? g = 10}) => GeraetePosition(breite: lat, laenge: lon, genauigkeit: g, zeit: t);

Future<void> main() async {
  for (final (name, crypto) in await kryptoVarianten()) {
    group('Standort teilen, Steuerung ($name)', () {
      final start = DateTime.utc(2026, 10, 20, 12);
      late _Geraet anna;
      late _Geraet ben;
      late _Relay relay;
      const zeiten = StandortZeiten(takt: Duration(milliseconds: 20), verbindungsFrist: Duration(milliseconds: 300), startFrist: Duration(milliseconds: 400), herzschlag: Duration(milliseconds: 25));

      setUp(() async {
        anna = _Geraet(_anna, crypto, 3, start, user: _user(_anna, 'Anna', Role.parent), zeiten: zeiten);
        ben = _Geraet(_ben, crypto, 2, start, user: _user(_ben, 'Ben', Role.child), zeiten: zeiten);
        anna.vertraut[_ben] = ben.pk.oeffentlich(2);
        ben.vertraut[_anna] = anna.pk.oeffentlich(3);
        relay = _Relay({_anna: anna, _ben: ben});
        await anna.starten();
        await ben.starten();
      });

      tearDown(() {
        anna.schliessen();
        ben.schliessen();
      });

      Future<void> teilenAnna({Set<String> an = const {_ben}, Duration dauer = const Duration(hours: 1)}) async {
        final f = anna.ctrl.teilen(dauer: dauer, empfaenger: an);
        await pumpen();
        await relay.weiter(anna);
        expect(await f, isTrue);
      }

      test('Start: Wrap nur für vertraute Empfänger, Dienst gestartet, nach der Bestätigung des Servers läuft es', () async {
        await teilenAnna(an: {_ben, _cora}); // Cora: Schlüssel nicht bestätigt
        expect(anna.port.gestartet, 1);
        expect(anna.port.ende, start.add(const Duration(hours: 1)));
        expect(anna.st.phase, StandortPhase.teilt);
        expect(anna.st.empfaenger, {_ben});
        expect(anna.st.ausgelassen, {_cora});
        expect(ben.st.geteilt.keys, [_anna]);
        expect(ben.st.geteilt[_anna]!.hatPosition, isFalse);
        expect(ben.st.geteilt[_anna]!.ungeprueft, isFalse);
      });

      test('Position: verschlüsselt gesendet, Empfänger zeigt Genauigkeit und Messzeit; der Klartext steht nicht in der Nachricht', () async {
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        final gesendet = await relay.weiter(anna);
        final p = gesendet.singleWhere((m) => m['type'] == 'loc_pos');
        expect(jsonEncode(p), isNot(contains('48.1372')));
        final e = ben.st.geteilt[_anna]!;
        expect(e.breite, 48.1372);
        expect(e.laenge, 11.5755);
        expect(e.genauigkeit, 10);
        expect(e.messzeit!.toUtc(), start);
        expect(e.alter(start.add(const Duration(minutes: 2))), const Duration(minutes: 2));
        expect(e.veraltet(start.add(const Duration(minutes: 6))), isTrue);
        expect(e.veraltet(start.add(const Duration(minutes: 1))), isFalse);
      });

      test('Drosselung: bei Bewegung höchstens alle 10 s, in Ruhe erst nach 60 s (dann wiederholt der Takt die letzte Position)', () async {
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        expect((await relay.weiter(anna)).where((m) => m['type'] == 'loc_pos'), hasLength(1));
        // 5 s später, 100 m weiter: noch zu früh
        anna.jetzt = start.add(const Duration(seconds: 5));
        anna.port.ctrl.add(PositionEreignis(_pos(anna.jetzt, lat: 48.1382)));
        await pumpen();
        expect((await relay.weiter(anna)).where((m) => m['type'] == 'loc_pos'), isEmpty);
        // 12 s, 100 m weiter: Bewegung
        anna.jetzt = start.add(const Duration(seconds: 12));
        anna.port.ctrl.add(PositionEreignis(_pos(anna.jetzt, lat: 48.1382)));
        await pumpen();
        expect((await relay.weiter(anna)).where((m) => m['type'] == 'loc_pos'), hasLength(1));
        // 25 s, gleicher Ort: Ruhe, noch nichts
        anna.jetzt = start.add(const Duration(seconds: 25));
        anna.port.ctrl.add(PositionEreignis(_pos(anna.jetzt, lat: 48.1382)));
        await pumpen();
        expect((await relay.weiter(anna)).where((m) => m['type'] == 'loc_pos'), isEmpty);
        // nach 75 s ohne Versand wiederholt der Takt (auch ohne neue Messung); die Messzeit bleibt die der letzten Messung
        anna.jetzt = start.add(const Duration(seconds: 80));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final nach = await relay.weiter(anna);
        expect(nach.where((m) => m['type'] == 'loc_pos'), isNotEmpty);
        expect(ben.st.geteilt[_anna]!.messzeit!.toUtc(), start.add(const Duration(seconds: 25)));
      });

      test('Beenden: Empfänger erfahren es, der Dienst stoppt, kein Rest im Zustand', () async {
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        await relay.weiter(anna);
        await anna.ctrl.beenden();
        final m = await relay.weiter(anna);
        expect(m.map((x) => x['type']), contains('loc_stop'));
        expect(anna.port.gestoppt, greaterThan(0));
        expect(anna.st.phase, StandortPhase.aus);
        expect(anna.st.eigene, isNull);
        expect(anna.st.empfaenger, isEmpty);
        expect(ben.st.geteilt, isEmpty);
      });

      test('"Beenden" in der Benachrichtigung (Ereignis oder Herzschlag) beendet das Teilen', () async {
        await teilenAnna();
        anna.port.ctrl.add(const StopEreignis());
        await pumpen();
        expect(anna.st.phase, StandortPhase.aus);
        await relay.weiter(anna);
        expect(ben.st.geteilt, isEmpty);
        // zweiter Weg: der Herzschlag meldet die Anforderung
        anna.port.herz = (laeuft: true, stopAngefordert: false);
        await teilenAnna();
        anna.port.herz = (laeuft: true, stopAngefordert: true);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(anna.st.phase, StandortPhase.aus);
      });

      test('Läuft der Dienst nicht mehr (vom System beendet), endet das Teilen mit Hinweis', () async {
        await teilenAnna();
        anna.port.herz = (laeuft: false, stopAngefordert: false);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(anna.st.phase, StandortPhase.aus);
        expect(anna.st.meldung, contains('beendet'));
      });

      test('Ablauf: nach der Endzeit endet das Teilen von selbst', () async {
        await teilenAnna(dauer: const Duration(minutes: 15));
        anna.jetzt = start.add(const Duration(minutes: 16));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(anna.st.phase, StandortPhase.aus);
        expect(anna.st.meldung, contains('abgelaufen'));
      });

      test('Dauer ist auf 12 Stunden begrenzt; Verlängern ebenso und meldet es Dienst und Server', () async {
        await teilenAnna(dauer: const Duration(days: 2));
        expect(anna.port.ende, start.add(kStandortHoechstdauer));
        anna.jetzt = start.add(const Duration(hours: 3));
        await anna.ctrl.verlaengern(const Duration(hours: 20));
        expect(anna.st.endetAt, anna.jetzt.add(kStandortHoechstdauer));
        expect(anna.port.verlaengert, [anna.jetzt.add(kStandortHoechstdauer)]);
        final m = await relay.weiter(anna);
        expect(m.where((x) => x['type'] == 'loc_extend'), hasLength(1));
      });

      test('Empfang: dieselbe Position noch einmal (Replay) und Pakete mit alter Sequenznummer ändern nichts', () async {
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        final erste = (await relay.weiter(anna)).singleWhere((m) => m['type'] == 'loc_pos');
        anna.jetzt = start.add(const Duration(seconds: 15));
        ben.jetzt = anna.jetzt;
        anna.port.ctrl.add(PositionEreignis(_pos(anna.jetzt, lat: 48.2)));
        await pumpen();
        await relay.weiter(anna);
        expect(ben.st.geteilt[_anna]!.breite, 48.2);
        // der Server (oder jemand dazwischen) spielt das ältere Paket noch einmal ein
        ben.socket.vomServer({'type': 'loc_pos', 'from': _anna, 'shareId': relay.letzteShare, 'packet': erste['packet']});
        await pumpen();
        expect(ben.st.geteilt[_anna]!.breite, 48.2);
      });

      test('Die Standort-Verbindung meldet sich beim Server als solche (loc_hello)', () async {
        expect(anna.socket.gesendet.where((m) => m['type'] == 'loc_hello'), hasLength(1));
      });

      test('Verlängern: der Empfänger übernimmt das neue Ende', () async {
        await teilenAnna();
        final vorher = ben.st.geteilt[_anna]!.endetAt;
        await anna.ctrl.verlaengern(const Duration(hours: 2));
        await relay.weiter(anna);
        expect(ben.st.geteilt[_anna]!.endetAt.isAfter(vorher), isTrue);
      });

      test('Reihenfolge beim Empfänger: loc_pos und loc_stop direkt nach loc_start gehen nicht verloren und hinterlassen keinen Geist', () async {
        final f = anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben});
        await pumpen();
        final start1 = anna.neueNachrichten().singleWhere((m) => m['type'] == 'loc_start');
        anna.socket.vomServer({'type': 'loc_started', 'shareId': start1['shareId'], 'endsAt': start1['endsAt']});
        await pumpen();
        expect(await f, isTrue);
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        final pos = anna.neueNachrichten().singleWhere((m) => m['type'] == 'loc_pos');
        final wrap = (start1['recipients'] as List).first['wrap'];
        ben.socket.vomServer({'type': 'loc_start', 'from': _anna, 'shareId': start1['shareId'], 'endsAt': start1['endsAt'], 'wrap': wrap});
        ben.socket.vomServer({'type': 'loc_pos', 'from': _anna, 'shareId': start1['shareId'], 'packet': pos['packet']});
        await pumpen();
        expect(ben.st.geteilt[_anna]!.hatPosition, isTrue);
        ben.socket.vomServer({'type': 'loc_stop', 'from': _anna, 'shareId': start1['shareId'], 'reason': 'stopped'});
        await pumpen();
        expect(ben.st.geteilt, isEmpty);
      });

      test('Eine beendete Freigabe lebt durch ein erneut eingespieltes loc_start nicht wieder auf', () async {
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        await relay.weiter(anna);
        final wrap = anna.socket.gesendet.lastWhere((m) => m['type'] == 'loc_start')['recipients'][0]['wrap'];
        final share = relay.letzteShare;
        await anna.ctrl.beenden();
        await relay.weiter(anna);
        expect(ben.st.geteilt, isEmpty);
        ben.socket.vomServer({'type': 'loc_start', 'from': _anna, 'shareId': share, 'endsAt': start.add(const Duration(hours: 1)).millisecondsSinceEpoch, 'wrap': wrap});
        await pumpen();
        expect(ben.st.geteilt, isEmpty);
      });

      test('Empfang: Pakete einer anderen Freigabe oder von einer anderen Person werden ignoriert', () async {
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        final p = (await relay.weiter(anna)).singleWhere((m) => m['type'] == 'loc_pos');
        final vorher = ben.st.geteilt[_anna]!;
        ben.socket.vomServer({'type': 'loc_pos', 'from': _cora, 'shareId': relay.letzteShare, 'packet': p['packet']});
        ben.socket.vomServer({'type': 'loc_pos', 'from': _anna, 'shareId': 'andere-share', 'packet': p['packet']});
        ben.socket.vomServer({'type': 'loc_pos', 'from': _anna, 'shareId': relay.letzteShare, 'packet': 'AAAA'});
        ben.socket.vomServer({'type': 'loc_stop', 'from': _anna, 'shareId': 'andere-share', 'reason': 'x'});
        ben.socket.vomServer({'type': 'loc_stop', 'from': _cora, 'shareId': relay.letzteShare, 'reason': 'x'});
        await pumpen();
        expect(ben.st.geteilt[_anna]!.breite, vorher.breite);
        expect(ben.st.geteilt.keys, [_anna]);
      });

      test('Ungeprüfter Absender (Schlüssel nicht bestätigt): Eintrag ohne Position, später kommende Pakete bleiben ungelesen', () async {
        ben.vertraut.remove(_anna);
        anna.vertraut[_ben] = ben.pk.oeffentlich(2);
        await teilenAnna();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        await relay.weiter(anna);
        final e = ben.st.geteilt[_anna]!;
        expect(e.ungeprueft, isTrue);
        expect(e.hatPosition, isFalse);
      });

      test('Wrap mit falschem Schlüssel des Absenders (anderer gemerkter Schlüssel) wird nicht angenommen', () async {
        ben.vertraut[_anna] = Personenschluessel.erzeugen(crypto).oeffentlich(3);
        await teilenAnna();
        expect(ben.st.geteilt[_anna]!.ungeprueft, isTrue);
      });

      test('Ohne vertraute Empfänger, ohne Erlaubnis, ohne Verschlüsselung oder ohne Verbindung startet nichts', () async {
        anna.vertraut.clear();
        expect(await anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben}), isFalse);
        expect(anna.st.meldung, contains('bestätig'));
        expect(anna.port.gestartet, 0);

        anna.vertraut[_ben] = ben.pk.oeffentlich(2);
        anna.port.statusWert = const StandortStatus(fein: false, grob: false, benachrichtigungen: true);
        expect(await anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben}), isFalse);
        expect(anna.st.meldung, contains('Erlaubnis'));

        anna.port.statusWert = const StandortStatus(fein: true, benachrichtigungen: false);
        expect(await anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben}), isFalse);
        expect(anna.st.meldung, contains('Benachrichtigungen'));

        anna.port.statusWert = const StandortStatus(fein: true, benachrichtigungen: true);
        anna.port.startFehler = StartFehler.dienstStart;
        expect(await anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben}), isFalse);
        expect(anna.port.gestartet, 0);
        expect(anna.st.phase, StandortPhase.aus);

        anna.port.startFehler = null;
        anna.socket.serverSchliesst(1006);
        await pumpen(2);
        expect(await anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben}), isFalse);
        expect(anna.st.meldung, contains('Verbindung'));
        expect(anna.port.gestartet, 0);
      });

      test('Der Server lehnt ab oder kennt die Freigabe nicht (unknown_share): lokal wird sauber beendet', () async {
        final f = anna.ctrl.teilen(dauer: const Duration(hours: 1), empfaenger: {_ben});
        await pumpen();
        anna.neueNachrichten();
        anna.socket.vomServer({'type': 'loc_error', 'code': 'too_many_shares', 'shareId': anna.letzteShareId});
        await pumpen();
        expect(await f, isTrue); // gestartet, danach vom Server abgelehnt
        await pumpen();
        expect(anna.st.phase, StandortPhase.aus);
        expect(anna.port.gestoppt, greaterThan(0));
      });

      test('Der Server beendet die Freigabe (Ablauf, Ersetzen): das Teilen endet auch hier', () async {
        await teilenAnna();
        anna.socket.vomServer({'type': 'loc_stop', 'from': _anna, 'shareId': relay.letzteShare, 'reason': 'expired'});
        await pumpen();
        expect(anna.st.phase, StandortPhase.aus);
        expect(anna.port.gestoppt, greaterThan(0));
      });

      test('Rate-Limit-Antwort des Servers beendet nichts', () async {
        await teilenAnna();
        anna.socket.vomServer({'type': 'loc_error', 'code': 'rate_limited', 'shareId': relay.letzteShare});
        await pumpen();
        expect(anna.st.phase, StandortPhase.teilt);
      });

      test('Abgelaufene Freigaben anderer verschwinden aus der Liste (keine Historie)', () async {
        await teilenAnna(dauer: const Duration(minutes: 15));
        expect(ben.st.geteilt, isNotEmpty);
        ben.jetzt = start.add(const Duration(minutes: 20));
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(ben.st.geteilt, isEmpty);
      });

      test('Im Hintergrund bleibt die Verbindung nur, solange geteilt wird', () async {
        final n = ben.sockets.sockets.length;
        ben.ctrl.vordergrund(false);
        await pumpen();
        expect(ben.st.verbunden, isFalse);
        ben.ctrl.vordergrund(true);
        await pumpen();
        expect(ben.sockets.sockets.length, n + 1);
        expect(ben.st.verbunden, isTrue);
        await teilenAnna();
        final m = anna.sockets.sockets.length;
        anna.ctrl.vordergrund(false);
        await pumpen();
        expect(anna.st.verbunden, isTrue);
        expect(anna.sockets.sockets.length, m);
        await anna.ctrl.beenden();
        await pumpen();
        expect(anna.st.verbunden, isFalse);
      });

      test('Nach dem Wiederverbinden geht sofort die neueste Position raus; währenddessen wird nichts gepuffert', () async {
        await teilenAnna();
        anna.socket.serverSchliesst(1006);
        await pumpen();
        anna.port.ctrl.add(PositionEreignis(_pos(start)));
        await pumpen();
        expect(anna.neueNachrichten().where((m) => m['type'] == 'loc_pos'), isEmpty);
        // der SyncSocket verbindet nach dem Backoff neu; der Server meldet die Freigabe als aktiv
        await Future<void>.delayed(const Duration(seconds: 3));
        anna.socket.vomServer({'type': 'loc_active', 'shareId': relay.letzteShare, 'endsAt': anna.port.ende!.millisecondsSinceEpoch});
        await pumpen();
        expect(anna.neueNachrichten().where((m) => m['type'] == 'loc_pos'), hasLength(1));
      }, timeout: const Timeout(Duration(seconds: 20)));
    });
  }

  group('Hilfen', () {
    test('Voreinstellung der Empfänger: Eltern teilen mit allen, Kinder zunächst nur mit Eltern und Admins', () {
      final alle = [_user(_anna, 'Anna', Role.admin), _user(_ben, 'Ben', Role.child), _user(_cora, 'Cora', Role.child), _user('d', 'Dora', Role.parent)];
      expect(standardEmpfaenger(alle[0], alle), {_ben, _cora, 'd'});
      expect(standardEmpfaenger(alle[1], alle), {_anna, 'd'});
      expect(standardEmpfaenger(alle[3], alle), {_anna, _ben, _cora});
    });

    test('Abstand in Metern (Haversine)', () {
      expect(abstandMeter(48.1372, 11.5755, 48.1372, 11.5755), 0);
      expect(abstandMeter(48.1372, 11.5755, 48.1382, 11.5755), closeTo(111, 2));
    });

    test('Texte: Alter und Genauigkeit', () {
      expect(alterText(const Duration(seconds: 10)), 'gerade eben');
      expect(alterText(const Duration(minutes: 3)), 'vor 3 Min');
      expect(alterText(const Duration(hours: 2)), 'vor 2 Std');
      expect(genauigkeitText(12.4), '± 12 m');
      expect(genauigkeitText(1400), '± 1,4 km');
      expect(genauigkeitText(null), 'Genauigkeit unbekannt');
      expect(koordinatenText(48.13721, 11.5755), '48,13721, 11,57550');
    });
  });
}
