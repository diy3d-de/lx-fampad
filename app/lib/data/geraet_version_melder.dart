// Meldet dem Server die App-Version dieses Geräts (nur Android), damit der Betreiber den Update-Stand sieht ("Wie viele Geräte sind auf der neuesten Version?").
// Gemeldet wird NUR der Versionsstring `x.y.z` (`PUT /me/device-info`); nie ein Gerätekennzeichen, nie ein Inhalt. Die Meldung ist eine Angabe des Geräts und kein Beweis.
//
// Regeln:
//  - Gemeldet wird beim Start und nach jeder Anmeldung (jede neue Version nach einem App-Update beim ersten Start), je Person und Version einmal pro Sitzung. Im Web und in
//    Tests (kein Systemkanal) gibt es keine Version: dann wird nichts gemeldet.
//  - Tolerant gegenüber alten Servern: 404 (Route unbekannt) oder 409 (kein Gerät zur Sitzung) beenden die Versuche für diese Sitzung; jeder andere Fehler (offline,
//    Server gestört) bleibt still, der nächste Start versucht es erneut.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_error.dart';
import 'api/fampad_api.dart';
import 'auth/auth_state.dart';

final _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');

/// Merkt, was schon gemeldet wurde (je Sitzung, Person und Version), damit nicht bei jeder Zustandsänderung gesendet wird.
class GeraetVersionMelder {
  GeraetVersionMelder({Future<String?> Function()? sitzung}) : _sitzung = sitzung ?? (() async => null);

  final Future<String?> Function() _sitzung;
  bool _sitzungGelesen = false;
  String? _sitzungKennung;
  String? _gemeldet;
  bool _nichtUnterstuetzt = false;
  bool _laeuft = false;

  /// Meldet [version] für [person], wenn sie neu ist und wie `x.y.z` aussieht. Wirft nie.
  Future<void> melden(FampadApi api, String person, String? version) async {
    if (_laeuft || version == null || !_version.hasMatch(version)) return;
    _laeuft = true;
    try {
      String? kennung;
      try {
        kennung = await _sitzung();
      } catch (_) {
        kennung = null;
      }
      if (!_sitzungGelesen || kennung != _sitzungKennung) {
        // andere Sitzung: nichts Gemerktes übernehmen, auch kein früheres 404/409
        _sitzungGelesen = true;
        _sitzungKennung = kennung;
        _gemeldet = null;
        _nichtUnterstuetzt = false;
      }
      final schluessel = '$person:$version';
      if (_nichtUnterstuetzt || _gemeldet == schluessel) return;
      try {
        await api.geraetVersionMelden(version);
        _gemeldet = schluessel;
      } on ApiException catch (e) {
        if (e.status == 404 || e.status == 409) _nichtUnterstuetzt = true;
      } catch (_) {
        // still: der nächste Start versucht es erneut
      }
    } finally {
      _laeuft = false;
    }
  }
}

final geraetVersionMelderZustandProvider = Provider<GeraetVersionMelder>(
  (ref) => GeraetVersionMelder(sitzung: () async => (await ref.read(tokenStoreProvider).readTokens())?.deviceId),
);

/// Wird am Wurzel-Widget beobachtet (siehe app.dart).
final geraetVersionMelderProvider = Provider<void>((ref) {
  final ich = ref.watch(authProvider.select((s) => s.status == AuthStatus.angemeldet ? s.user?.id : null));
  if (ich == null) return;
  Future.microtask(() async {
    if (!ref.mounted) return;
    final version = await ref.read(systemChannelProvider).appVersion();
    if (ref.mounted) unawaited(ref.read(geraetVersionMelderZustandProvider).melden(ref.read(apiProvider), ich, version));
  });
});
