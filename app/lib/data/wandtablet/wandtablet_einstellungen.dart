// Einstellungen des Wandtablet-Modus: nur dieses Gerät, lokal in `sync_meta` (über `feiertageSpeicherProvider`), nie synchronisiert, kein Server.
//  - autostart: beim Start der App (nach der Anmeldung) automatisch starten (Standard: aus),
//  - dimmen: nachts (22 bis 6 Uhr) abdunkeln (Standard: an),
//  - liste: ID der EINEN Liste (Einkaufsliste), die der Modus zeigt (Standard: keine).
// Änderungen warten, bis der gespeicherte Stand gelesen ist; Lese-/Schreibfehler gelten nur bis zum Schließen der App.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../calendar/feiertage.dart' show feiertageSpeicherProvider;

const kWandAutostartSchluessel = 'wandtablet_autostart';
const kWandDimmenSchluessel = 'wandtablet_dimmen';
const kWandListeSchluessel = 'wandtablet_liste';

class WandtabletEinstellungen {
  final bool autostart;
  final bool dimmen;

  /// null = keine Liste.
  final String? liste;

  /// Der gespeicherte Stand ist gelesen (der Autostart wartet darauf).
  final bool geladen;
  const WandtabletEinstellungen({this.autostart = false, this.dimmen = true, this.liste, this.geladen = false});

  WandtabletEinstellungen kopie({bool? autostart, bool? dimmen, Object? liste = _keine, bool? geladen}) => WandtabletEinstellungen(
    autostart: autostart ?? this.autostart,
    dimmen: dimmen ?? this.dimmen,
    liste: identical(liste, _keine) ? this.liste : liste as String?,
    geladen: geladen ?? this.geladen,
  );
}

const Object _keine = Object();

/// Läuft der Wandtablet-Modus gerade (Bildschirm offen)? Wetter-Benachrichtigungen werden dann nicht gezeigt. Nur im Arbeitsspeicher der laufenden App; die
/// Hintergrund-Engine kennt nur die Einstellung "Beim Start automatisch starten" ([kWandAutostartSchluessel]) als Hinweis auf ein dauerhaftes Wandtablet.
class WandtabletLaeuft extends Notifier<bool> {
  @override
  bool build() => false;

  void setzen(bool laeuft) => state = laeuft;
}

final wandtabletLaeuftProvider = NotifierProvider<WandtabletLaeuft, bool>(WandtabletLaeuft.new);

class WandtabletEinstellungenNotifier extends Notifier<WandtabletEinstellungen> {
  int _generation = 0;
  Future<void> _gelesen = Future<void>.value();

  @override
  WandtabletEinstellungen build() {
    final gen = ++_generation;
    _gelesen = _laden(gen);
    return const WandtabletEinstellungen();
  }

  Future<void> _laden(int gen) async {
    String? a, d, l;
    try {
      final s = ref.read(feiertageSpeicherProvider);
      a = await s.lesen(schluessel: kWandAutostartSchluessel);
      d = await s.lesen(schluessel: kWandDimmenSchluessel);
      l = await s.lesen(schluessel: kWandListeSchluessel);
    } catch (_) {
      a = d = l = null;
    }
    if (!ref.mounted || gen != _generation) return;
    state = WandtabletEinstellungen(autostart: a == 'ja', dimmen: d != 'nein', liste: (l == null || l.isEmpty) ? null : l, geladen: true);
  }

  Future<void> _aendern(WandtabletEinstellungen Function(WandtabletEinstellungen) f, Map<String, String?> schreiben) async {
    final gen = _generation;
    if (!state.geladen) await _gelesen;
    if (!ref.mounted || gen != _generation) return;
    state = f(state);
    try {
      final s = ref.read(feiertageSpeicherProvider);
      for (final e in schreiben.entries) {
        final w = e.value;
        w == null ? await s.loeschen(e.key) : await s.schreiben(w, schluessel: e.key);
      }
    } catch (_) {
      // gilt dann nur bis zum Schließen der App
    }
  }

  Future<void> autostartSetzen(bool an) => _aendern((e) => e.kopie(autostart: an), {kWandAutostartSchluessel: an ? 'ja' : 'nein'});
  Future<void> dimmenSetzen(bool an) => _aendern((e) => e.kopie(dimmen: an), {kWandDimmenSchluessel: an ? 'ja' : 'nein'});
  Future<void> listeSetzen(String? id) => _aendern((e) => e.kopie(liste: id), {kWandListeSchluessel: id});
}

final wandtabletEinstellungenProvider = NotifierProvider<WandtabletEinstellungenNotifier, WandtabletEinstellungen>(WandtabletEinstellungenNotifier.new);
