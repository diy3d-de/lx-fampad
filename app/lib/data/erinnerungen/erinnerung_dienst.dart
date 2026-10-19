// Dienst für Terminerinnerungen: hält die Planung des Geräts im Gleichklang mit den lokalen Kalenderdaten.
//  - Auslöser: Start der angemeldeten Oberfläche, jede Änderung der lokalen Termine (auch durch den Sync), Rückkehr in die App,
//    Änderung der Einstellungen. Nach Neustart des Geräts und App-Update setzt das Plugin seine gespeicherten Alarme selbst neu
//    (ScheduledNotificationBootReceiver); das Fenster wird beim nächsten App-Start aufgefrischt.
//  - Ein Lauf berechnet das Fenster (erinnerung_planung.dart) und gleicht das Gerät daran an. Läuft schon einer, wird danach genau einmal
//    wiederholt (kein Zeitgeber nötig). Ändert sich das Fenster nicht, bleibt das Betriebssystem unberührt.
//  - Erinnerungen entstehen nur lokal: kein Server, kein Push, nichts verlässt das Gerät.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../calendar/termin_repository.dart';
import 'erinnerung_einstellungen.dart';
import 'erinnerung_planung.dart';
import 'erinnerung_port.dart';
import 'erinnerung_port_stub.dart' if (dart.library.io) 'erinnerung_port_io.dart';

final erinnerungPortProvider = Provider<ErinnerungPort>((ref) => erinnerungPortErzeugen());

/// Uhr (für Tests überschreibbar).
final erinnerungUhrProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Wird beim Tippen auf eine Benachrichtigung aufgerufen (Tag und Termin aus dem Inhalt); die Oberfläche hängt hier die Navigation ein.
typedef ErinnerungGeoeffnet = void Function(({String terminId, DateTime tag}) ziel);

class ErinnerungDienst {
  final Ref _ref;
  final ErinnerungPort port;
  final DateTime Function() _jetzt;
  bool _laeuft = false;
  bool _nochmal = false;
  bool _bereit = false;
  bool _startGelesen = false;
  bool _beendet = false;

  /// Das Betriebssystem hat sicher keine Erinnerungen von uns mehr (nach Löschen oder leerer Planung).
  bool _leer = false;

  /// Navigation beim Tippen auf eine Benachrichtigung (setzt features/calendar/erinnerung_steuerung.dart).
  ErinnerungGeoeffnet? beiGeoeffnet;

  /// Zuletzt an das Betriebssystem übergebene Planung (null: noch nichts gesetzt).
  List<GeplanteErinnerung>? _letzte;

  ErinnerungDienst(this._ref, {required this.port, required DateTime Function() jetzt}) : _jetzt = jetzt; // ignore: prefer_initializing_formals

  /// Zuletzt geplante Erinnerungen (für Anzeige und Tests).
  List<GeplanteErinnerung> get geplant => _letzte ?? const [];

  void beenden() => _beendet = true;

  /// Gleicht die Planung an. Mehrfache Aufrufe während eines Laufs ergeben genau einen weiteren Lauf.
  Future<void> abgleichen() async {
    if (_beendet || !port.verfuegbar) return;
    if (_laeuft) {
      _nochmal = true;
      return;
    }
    _laeuft = true;
    try {
      do {
        _nochmal = false;
        await _lauf();
      } while (_nochmal && !_beendet);
    } catch (_) {
      // Erinnerungen sind Zusatz: ein Fehler beim Planen darf nichts anderes stören; der nächste Auslöser versucht es erneut
      _letzte = null;
    } finally {
      _laeuft = false;
    }
  }

  Future<void> _lauf() async {
    await _ref.read(erinnerungEinstellungenProvider.notifier).bereit;
    if (_beendet) return;
    if (!_bereit) {
      await port.initialisieren(beiTipp: _getippt);
      _bereit = true;
      if (!_startGelesen) {
        _startGelesen = true;
        _getippt(await port.startPayload());
      }
    }
    final einst = _ref.read(erinnerungEinstellungenProvider);
    final auth = _ref.read(authProvider);
    if (!einst.an || !auth.angemeldet) {
      if (!einst.an) await _loeschen();
      return;
    }
    // Erst planen, wenn die Datenbank die Termine geliefert hat (sonst würde ein leeres Fenster alle Alarme löschen)
    if (!_datenDa()) return;
    final plan = planeErinnerungen(daten: _ref.read(kalenderDatenProvider), ich: auth.user?.id, jetzt: _jetzt());
    final alt = _letzte;
    if (alt != null && alt.length == plan.length && [for (var i = 0; i < plan.length; i++) alt[i].gleich(plan[i])].every((b) => b)) return;
    final exakt = await port.exakteAlarmeMoeglich();
    await port.planen(plan, exakt: exakt);
    _letzte = plan;
    _leer = plan.isEmpty;
  }

  bool _datenDa() =>
      _ref.read(termineProvider).hasValue && _ref.read(terminAusnahmenProvider).hasValue && _ref.read(terminTeilnehmerProvider).hasValue;

  Future<void> _loeschen() async {
    if (_leer) return;
    await port.alleLoeschen();
    _leer = true;
    _letzte = const [];
  }

  /// Alle Erinnerungen dieses Geräts entfernen (Abmelden); die nächste Anmeldung plant neu.
  Future<void> alleEntfernen() async {
    if (_beendet || !port.verfuegbar) return;
    try {
      await port.initialisieren(beiTipp: _getippt);
      await port.alleLoeschen();
    } catch (_) {}
    _letzte = null;
    _leer = true;
  }

  void _getippt(String? payload) {
    final ziel = erinnerungPayloadLesen(payload);
    if (ziel == null || _beendet) return;
    beiGeoeffnet?.call(ziel);
  }

  /// Berechtigung für Benachrichtigungen anfragen (nur auf Wunsch der Person); plant danach neu.
  Future<bool> berechtigungAnfragen() async {
    await port.initialisieren(beiTipp: _getippt);
    final ok = await port.benachrichtigungenAnfragen();
    _letzte = null;
    unawaited(abgleichen());
    return ok;
  }

  Future<ErinnerungStatus> status() async {
    if (!port.verfuegbar) return const ErinnerungStatus(verfuegbar: false);
    await port.initialisieren(beiTipp: _getippt);
    return ErinnerungStatus(verfuegbar: true, erlaubt: await port.benachrichtigungenErlaubt(), exakt: await port.exakteAlarmeMoeglich());
  }

  /// Testbenachrichtigung in [wartezeit] (Standard 10 Sekunden).
  Future<void> testSenden({Duration wartezeit = const Duration(seconds: 10)}) async {
    await port.initialisieren(beiTipp: _getippt);
    final exakt = await port.exakteAlarmeMoeglich();
    await port.testPlanen(wartezeit, exakt: exakt);
  }
}

final erinnerungDienstProvider = Provider<ErinnerungDienst>((ref) {
  final d = ErinnerungDienst(ref, port: ref.watch(erinnerungPortProvider), jetzt: ref.watch(erinnerungUhrProvider));
  ref.onDispose(d.beenden);
  return d;
});

/// Zustand für die Einstellungen: gibt es Erinnerungen auf diesem Gerät, ist die Berechtigung da, sind genaue Alarme möglich?
class ErinnerungStatus {
  final bool verfuegbar;
  final bool erlaubt;
  final bool exakt;
  const ErinnerungStatus({required this.verfuegbar, this.erlaubt = false, this.exakt = false});
}

final erinnerungStatusProvider = FutureProvider.autoDispose<ErinnerungStatus>((ref) => ref.read(erinnerungDienstProvider).status());
