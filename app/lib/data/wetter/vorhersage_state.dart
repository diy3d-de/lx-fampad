// Vorhersage und amtliche Warnungen (Deutscher Wetterdienst): die App fragt nur den eigenen Server (`GET /weather/forecast`), nie den DWD oder einen Dritten,
// und hält den letzten Stand lokal vor (`sync_meta`, `wetter_vorhersage_cache`). Gefragt wird nur, wenn der Server das Wetter eingeschaltet hat;
// ältere Server ohne die Route (404) oder ein Fehler ergeben ruhig "keine Vorhersage", nie eine Fehlerfläche. Ein Offline-Stand gilt nie als aktuell
// (`vorhersageVeraltet` und `warnungenVeraltet` rechnen aus dem Zeitstempel des Servers).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import '../database_provider.dart';
import 'vorhersage_modelle.dart';
import 'wetter_state.dart';

const kVorhersageCacheSchluessel = 'wetter_vorhersage_cache';

/// Abstand der erneuten Abfrage, solange Kachel oder Seite offen sind (der Server holt Warnungen alle 10 Minuten); null = keine (nur Tests).
final vorhersageTaktProvider = Provider<Duration?>((ref) => const Duration(minutes: 10));

class VorhersageZustand {
  final VorhersageDto? dto;
  final DateTime? abgerufen;
  final bool laedt;

  /// Die letzte Abfrage ist gescheitert; der Stand stammt dann aus der Ablage (oder fehlt).
  final bool fehler;
  const VorhersageZustand({this.dto, this.abgerufen, this.laedt = false, this.fehler = false});

  VorhersageZustand mit({VorhersageDto? dto, DateTime? abgerufen, bool? laedt, bool? fehler}) =>
      VorhersageZustand(dto: dto ?? this.dto, abgerufen: abgerufen ?? this.abgerufen, laedt: laedt ?? this.laedt, fehler: fehler ?? this.fehler);
}

class VorhersageNotifier extends Notifier<VorhersageZustand> {
  Timer? _timer;
  bool _laeuft = false;

  @override
  VorhersageZustand build() {
    final userId = ref.watch(authProvider.select((s) => s.user?.id));
    // nur bei eingeschaltetem Wetter auf dem Server (sonst gibt es nichts zu holen)
    final wetterAn = ref.watch(wetterProvider.select((s) => s.dto?.verfuegbar ?? false));
    ref.onDispose(() => _timer?.cancel());
    if (userId != null && wetterAn) unawaited(_start());
    return const VorhersageZustand();
  }

  Future<void> _start() async {
    await _ablageLesen();
    if (!ref.mounted) return;
    await aktualisieren();
  }

  Future<void> _ablageLesen() async {
    try {
      final cache = await ref.read(appDatabaseProvider).metaLesen(kVorhersageCacheSchluessel);
      if (cache == null || !ref.mounted) return;
      final m = jsonDecode(cache) as Map<String, dynamic>;
      final dto = VorhersageDto.fromJson(m['daten']);
      state = state.mit(dto: dto, abgerufen: DateTime.tryParse(m['abgerufen'] as String? ?? ''));
    } on Object {
      // beschädigte oder unlesbare Ablage: ignorieren
    }
  }

  /// Holt den Stand vom Server; bei Fehlern bleibt der Stand aus der Ablage stehen (`fehler`).
  Future<void> aktualisieren() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = state.mit(laedt: true);
    try {
      final roh = await ref.read(apiProvider).wetterVorhersageRoh();
      final dto = VorhersageDto.fromJson(roh);
      final jetzt = DateTime.now();
      if (!ref.mounted) return;
      state = state.mit(dto: dto, abgerufen: jetzt, laedt: false, fehler: false);
      try {
        await ref.read(appDatabaseProvider).metaSchreiben(kVorhersageCacheSchluessel, jsonEncode({'abgerufen': jetzt.toIso8601String(), 'daten': roh}));
      } on Object {
        // nicht speicherbar: gilt bis zum Schließen
      }
    } on Object {
      if (ref.mounted) state = state.mit(laedt: false, fehler: true);
    } finally {
      _laeuft = false;
      final takt = ref.mounted ? ref.read(vorhersageTaktProvider) : null;
      if (takt != null) {
        _timer?.cancel();
        _timer = Timer(takt, () => unawaited(aktualisieren()));
      }
    }
  }
}

final vorhersageProvider = NotifierProvider<VorhersageNotifier, VorhersageZustand>(VorhersageNotifier.new);
