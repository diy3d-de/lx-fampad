// App-Updates (OTA) für Android über den eigenen Update-Kanal: <kReleasesBase>/android/latest.json mit Version,
// Mindestversion, SHA-256, Release-Notes und Ed25519-Signatur. Die App lädt die APK, prüft die Prüfsumme und
// startet die Android-Installation erst nach Klick. Android installiert nur mit demselben Signaturschlüssel.
//
// Phase 0: Statusmodell, Manifest-Prüfung, Download und Prüfsumme sind umgesetzt. Die Ed25519-Prüfung des
// Manifests (ManifestVerifier) ist noch ein Platzhalter und lehnt ab; ohne gültige Signatur wird nichts geladen.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../constants.dart';
import '../../data/providers.dart';
import '../../data/sync_state.dart';
import 'apk_downloader.dart';
import 'versions.dart';

enum UpdatePhase { deaktiviert, pruefe, aktuell, verfuegbar, laedt, bereit, fehler }

class UpdateInfo {
  final String version;
  final String minVersion;
  final String notes;
  final Uri apkUrl;
  final String sha256;
  final int size;
  const UpdateInfo({
    required this.version,
    required this.minVersion,
    required this.notes,
    required this.apkUrl,
    required this.sha256,
    required this.size,
  });

  /// Pflicht-Update: die installierte Version ist älter als die Mindestversion.
  bool pflichtFuer(String installiert) => compareVersions(installiert, minVersion) < 0;
}

class UpdateState {
  final UpdatePhase phase;
  final String? installierteVersion;
  final UpdateInfo? info;
  final double fortschritt;
  final String? fehler;
  final String? apkPfad;

  const UpdateState({
    this.phase = UpdatePhase.aktuell,
    this.installierteVersion,
    this.info,
    this.fortschritt = 0,
    this.fehler,
    this.apkPfad,
  });

  bool get updateDa => phase == UpdatePhase.verfuegbar || phase == UpdatePhase.bereit;

  UpdateState copyWith({
    UpdatePhase? phase,
    String? installierteVersion,
    UpdateInfo? info,
    double? fortschritt,
    String? fehler,
    String? apkPfad,
  }) =>
      UpdateState(
        phase: phase ?? this.phase,
        installierteVersion: installierteVersion ?? this.installierteVersion,
        info: info ?? this.info,
        fortschritt: fortschritt ?? this.fortschritt,
        fehler: fehler,
        apkPfad: apkPfad ?? this.apkPfad,
      );
}

/// Prüft die Ed25519-Signatur des Update-Manifests. Phase 0: noch keine Implementierung (lehnt ab).
abstract class ManifestVerifier {
  bool verify({required String payload, required String signature});
}

class RejectingManifestVerifier implements ManifestVerifier {
  const RejectingManifestVerifier();

  @override
  bool verify({required String payload, required String signature}) => false;
}

final manifestVerifierProvider = Provider<ManifestVerifier>((ref) => const RejectingManifestVerifier());

class UpdateController extends Notifier<UpdateState> {
  static const _channel = MethodChannel(kUpdateChannel);

  http.Client get _client => ref.read(httpClientProvider);

  // Web: Updates laufen über den Hinweis "Neue Version - neu laden" (Phase 1), nicht über APK.
  @override
  UpdateState build() => UpdateState(phase: kIsWeb ? UpdatePhase.deaktiviert : UpdatePhase.aktuell);

  Future<String> _version() async {
    final bekannt = state.installierteVersion;
    if (bekannt != null) return bekannt;
    final v = await _channel.invokeMethod<String>('appVersion') ?? '0.0.0';
    state = state.copyWith(installierteVersion: v);
    return v;
  }

  /// Lädt die installierte Version für die Anzeige (ohne Android-Kanal, z. B. in Tests, bleibt sie leer).
  Future<void> init() async {
    if (kIsWeb) return;
    try {
      await _version();
    } on PlatformException {
      // ohne Android-Kanal bleibt die Anzeige leer
    } on MissingPluginException {
      // dito
    }
  }

  /// Sucht nach einer neueren Version. Fehler (z. B. offline) landen nur im Status.
  Future<void> pruefen() async {
    if (state.phase == UpdatePhase.deaktiviert || state.phase == UpdatePhase.pruefe || state.phase == UpdatePhase.laedt) return;
    state = state.copyWith(phase: UpdatePhase.pruefe);
    try {
      final aktuell = await _version();
      final res = await _client.get(Uri.parse('$kReleasesBase/android/latest.json')).timeout(const Duration(seconds: 15));
      if (res.statusCode == 404) {
        state = state.copyWith(phase: UpdatePhase.aktuell); // noch kein Release veröffentlicht
        return;
      }
      if (res.statusCode != 200) throw Exception('Update-Server: HTTP ${res.statusCode}');
      final info = parseManifest(utf8.decode(res.bodyBytes), verifier: ref.read(manifestVerifierProvider));
      if (compareVersions(info.version, aktuell) <= 0) {
        state = state.copyWith(phase: UpdatePhase.aktuell);
        return;
      }
      state = state.copyWith(phase: UpdatePhase.verfuegbar, info: info);
    } on http.ClientException {
      state = state.copyWith(phase: UpdatePhase.fehler, fehler: 'Keine Verbindung zum Update-Server');
    } catch (e) {
      state = state.copyWith(phase: UpdatePhase.fehler, fehler: 'Update-Prüfung fehlgeschlagen: ${_text(e)}');
    }
  }

  /// Lädt die APK herunter und prüft die SHA-256-Prüfsumme aus dem signierten Manifest.
  Future<void> herunterladen() async {
    final info = state.info;
    if (info == null || state.phase == UpdatePhase.laedt) return;
    state = state.copyWith(phase: UpdatePhase.laedt, fortschritt: 0);
    try {
      final pfad = await apkHerunterladen(
        client: _client,
        url: info.apkUrl,
        erwartetSha256: info.sha256,
        groesse: info.size,
        onFortschritt: (anteil) => state = state.copyWith(fortschritt: anteil),
      );
      state = state.copyWith(phase: UpdatePhase.bereit, apkPfad: pfad);
    } catch (e) {
      state = state.copyWith(phase: UpdatePhase.fehler, fehler: _text(e));
    }
  }

  /// Startet die Android-Installation (nur per Klick). Ohne Erlaubnis "Unbekannte Apps installieren" öffnet
  /// Android zuerst die Einstellung; danach erneut tippen. Während Abgleich oder offenen Änderungen gesperrt.
  Future<String?> installieren() async {
    final pfad = state.apkPfad;
    if (pfad == null || state.phase != UpdatePhase.bereit) return 'Kein geladenes Update vorhanden';
    if (ref.read(syncProvider).beschaeftigt) return 'Bitte warten, bis der Abgleich abgeschlossen ist.';
    try {
      final ergebnis = await _channel.invokeMethod<String>('installApk', {'path': pfad});
      return ergebnis == 'permission'
          ? 'Bitte "Apps aus dieser Quelle zulassen" aktivieren und dann erneut auf Installieren tippen.'
          : null;
    } on PlatformException catch (e) {
      return 'Installation nicht möglich: ${e.message}';
    }
  }

  String _text(Object e) => '$e'.replaceFirst('Exception: ', '');
}

final updateProvider = NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

/// Liest und prüft das Manifest. Wirft eine Exception mit verständlichem Text bei jedem Fehler.
/// Signiert wird der Text von `payload` (Manifest ohne `signature`), siehe docs/PROJEKTBESCHREIBUNG.md Abschnitt 8.
@visibleForTesting
UpdateInfo parseManifest(String json, {required ManifestVerifier verifier}) {
  final Object? raw = jsonDecode(json);
  if (raw is! Map<String, dynamic>) throw Exception('Manifest ungültig');
  final signature = raw['signature'];
  final payload = raw['payload'];
  if (signature is! String || payload is! String) throw Exception('Manifest ist nicht signiert');
  if (!verifier.verify(payload: payload, signature: signature)) throw Exception('Signatur des Manifests ungültig');

  final Object? daten = jsonDecode(payload);
  if (daten is! Map<String, dynamic>) throw Exception('Manifest ungültig');
  final version = daten['version'];
  final minVersion = daten['minVersion'] ?? '0.0.0';
  final sha = daten['sha256'];
  final apk = daten['apk'];
  if (version is! String || !isVersion(version)) throw Exception('Manifest: Version ungültig');
  if (minVersion is! String || !isVersion(minVersion)) throw Exception('Manifest: Mindestversion ungültig');
  if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) throw Exception('Manifest: Prüfsumme ungültig');
  // Nur Dateinamen im Release-Ordner zulassen (keine fremden Adressen, kein Pfad nach oben)
  if (apk is! String || !RegExp(r'^[A-Za-z0-9._-]+\.apk$').hasMatch(apk)) throw Exception('Manifest: APK-Name ungültig');
  return UpdateInfo(
    version: version,
    minVersion: minVersion,
    notes: (daten['notes'] as String?) ?? '',
    apkUrl: Uri.parse('$kReleasesBase/android/$apk'),
    sha256: sha,
    size: (daten['size'] as num?)?.toInt() ?? 0,
  );
}
