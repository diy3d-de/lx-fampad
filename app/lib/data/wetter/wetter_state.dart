// Wetter (Netatmo-Station des Betreibers): der Server ruft ab, die App fragt nur den eigenen Server (GET /weather) und hält den letzten Stand
// lokal vor (Offline-Stand mit Zeitstempel, `sync_meta`). Der Schalter für die Startseite gilt je Gerät, nie auf dem Server.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';

const kWetterCacheSchluessel = 'wetter_cache';
const kWetterAnzeigenSchluessel = 'wetter_anzeigen';

/// So oft fragt die App den Server, solange Kachel oder Seite offen sind (der Server holt höchstens alle 10 Minuten neue Werte).
const kWetterAbfrageIntervall = Duration(minutes: 10);

/// Abstand der erneuten Abfrage; null = keine (nur Tests, damit kein Timer stehen bleibt).
final wetterTaktProvider = Provider<Duration?>(
  (ref) => kWetterAbfrageIntervall,
);

class WetterZustand {
  final WetterDto? dto;

  /// Wann die App den Stand zuletzt vom Server bekam (bei einem Offline-Stand: aus der lokalen Ablage).
  final DateTime? abgerufen;
  final bool laedt;

  /// Die letzte Abfrage ist gescheitert (offline oder Serverfehler); der Stand stammt dann aus der Ablage.
  final bool fehler;

  /// Schalter "Wetter auf der Startseite" (Standard an).
  final bool anzeigen;
  const WetterZustand({
    this.dto,
    this.abgerufen,
    this.laedt = false,
    this.fehler = false,
    this.anzeigen = true,
  });

  /// Es gibt etwas zu zeigen: der Server hat das Wetter an und liefert eine Messung.
  bool get hatDaten => (dto?.verfuegbar ?? false) && dto?.aktuell != null;

  /// Kachel auf der Startseite: nur mit Daten und eingeschaltetem Schalter.
  bool get kachelSichtbar => anzeigen && hatDaten;

  WetterZustand mit({
    WetterDto? dto,
    DateTime? abgerufen,
    bool? laedt,
    bool? fehler,
    bool? anzeigen,
  }) => WetterZustand(
    dto: dto ?? this.dto,
    abgerufen: abgerufen ?? this.abgerufen,
    laedt: laedt ?? this.laedt,
    fehler: fehler ?? this.fehler,
    anzeigen: anzeigen ?? this.anzeigen,
  );
}

class WetterNotifier extends Notifier<WetterZustand> {
  Timer? _timer;
  bool _laeuft = false;

  @override
  WetterZustand build() {
    // je angemeldeter Person neu (Abmelden, Personenwechsel)
    final userId = ref.watch(authProvider.select((s) => s.user?.id));
    ref.onDispose(() => _timer?.cancel());
    if (userId != null) unawaited(_start());
    return const WetterZustand();
  }

  Future<void> _start() async {
    await _ablageLesen();
    if (!ref.mounted) return;
    await aktualisieren();
  }

  Future<void> _ablageLesen() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final cache = await db.metaLesen(kWetterCacheSchluessel);
      final anzeigen = await db.metaLesen(kWetterAnzeigenSchluessel);
      if (!ref.mounted) return;
      WetterDto? dto;
      DateTime? abgerufen;
      if (cache != null) {
        try {
          final m = jsonDecode(cache) as Map<String, dynamic>;
          dto = WetterDto.fromJson(m['daten']);
          abgerufen = DateTime.tryParse(m['abgerufen'] as String? ?? '');
        } on Object {
          dto = null; // beschädigte Ablage: ignorieren
        }
      }
      state = state.mit(
        dto: dto,
        abgerufen: abgerufen,
        anzeigen: anzeigen != 'nein',
      );
    } on Object {
      // Datenbank nicht lesbar: Standard
    }
  }

  /// Holt den Stand vom Server; bei Fehlern bleibt der Stand aus der Ablage stehen (`fehler`).
  Future<void> aktualisieren() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = state.mit(laedt: true);
    try {
      final roh = await ref.read(apiProvider).wetterRoh();
      final dto = WetterDto.fromJson(roh);
      final jetzt = DateTime.now();
      if (!ref.mounted) return;
      state = state.mit(
        dto: dto,
        abgerufen: jetzt,
        laedt: false,
        fehler: false,
      );
      try {
        await ref
            .read(appDatabaseProvider)
            .metaSchreiben(
              kWetterCacheSchluessel,
              jsonEncode({'abgerufen': jetzt.toIso8601String(), 'daten': roh}),
            );
      } on Object {
        // nicht speicherbar: gilt bis zum Schließen
      }
    } on ApiException {
      if (ref.mounted) state = state.mit(laedt: false, fehler: true);
    } on Object {
      if (ref.mounted) state = state.mit(laedt: false, fehler: true);
    } finally {
      _laeuft = false;
      final takt = ref.mounted ? ref.read(wetterTaktProvider) : null;
      if (takt != null) {
        _timer?.cancel();
        _timer = Timer(takt, () => unawaited(aktualisieren()));
      }
    }
  }

  Future<void> anzeigenSetzen(bool an) async {
    state = state.mit(anzeigen: an);
    try {
      await ref
          .read(appDatabaseProvider)
          .metaSchreiben(kWetterAnzeigenSchluessel, an ? 'ja' : 'nein');
    } on Object {
      // nicht speicherbar: gilt bis zum Schließen
    }
  }
}

final wetterProvider = NotifierProvider<WetterNotifier, WetterZustand>(
  WetterNotifier.new,
);

/// Himmelsrichtung zu einem Winkel (0 = Nord, Richtung, aus der der Wind kommt).
String windRichtungText(double grad) {
  const namen = ['N', 'NO', 'O', 'SO', 'S', 'SW', 'W', 'NW'];
  return namen[(((grad % 360) + 360) % 360 / 45 + 0.5).floor() % 8];
}

String _zahl(double v, int stellen) =>
    v.toStringAsFixed(stellen).replaceAll('.', ',');

String temperaturText(double? v) => v == null ? '–' : '${_zahl(v, 1)} °C';
String feuchteText(double? v) => v == null ? '–' : '${v.round()} %';
String druckText(double? v) => v == null ? '–' : '${v.round()} hPa';
String regenText(double? v) => v == null ? '–' : '${_zahl(v, 1)} mm';
String windText(double? v) => v == null ? '–' : '${v.round()} km/h';

/// Uhrzeit der Messung; ältere als heute mit Datum.
String standText(DateTime t, DateTime jetzt) {
  final l = t.toLocal();
  final j = jetzt.toLocal();
  String z(int n) => n.toString().padLeft(2, '0');
  final uhr = '${z(l.hour)}:${z(l.minute)}';
  return l.year == j.year && l.month == j.month && l.day == j.day
      ? uhr
      : '${z(l.day)}.${z(l.month)}. $uhr';
}

/// Kurzer Text zum Stand: Messzeit, bei Offline-Stand oder alter Messung mit Hinweis.
({String text, bool warnung}) wetterStand(WetterZustand st, DateTime jetzt) {
  final a = st.dto!.aktuell!;
  final basis = 'Stand ${standText(a.gemessen, jetzt)}';
  if (st.fehler) return (text: '$basis · offline', warnung: true);
  if (a.veraltet) return (text: '$basis · veraltet', warnung: true);
  return (text: basis, warnung: false);
}
