// App-Updates (OTA) für Android über den eigenen Update-Kanal: <kReleasesBase>/android/latest.json mit signiertem
// Payload (Paketname, Version, versionCode, SHA-256, Größe, Zeitpunkt, Schlüssel-ID) und Ed25519-Signatur.
// Die App prüft die Signatur über den Payload-Text, dann Paketname, Schlüssel-ID und versionCode, lädt die APK,
// vergleicht Größe und Prüfsumme und installiert sie erst nach Klick (PackageInstaller, MainActivity.kt).
// Android installiert ohnehin nur Updates mit demselben Signaturschlüssel.
//
// Zusätzlich fragt die App /api/v1/version ab: Ist die installierte Version älter als minAppVersion oder die
// Protokollversion kleiner als minProtocolVersion, wird das Update zur Pflicht (Zustand `pflicht`). Im Web zeigt
// ein abweichendes webVersion den Hinweis "Neue Version - neu laden".
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../constants.dart';
import '../../data/providers.dart';
import '../../data/sync_state.dart';
import 'apk_downloader.dart';
import 'manifest_verifier.dart';
import 'versions.dart';

export 'manifest_verifier.dart';

enum UpdatePhase { deaktiviert, pruefe, aktuell, verfuegbar, laedt, bereit, fehler }

class UpdateInfo {
  final String version;
  final int versionCode;
  final String minVersion;
  final String notes;
  final Uri apkUrl;
  final String sha256;
  final int size;
  final DateTime issuedAt;
  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.minVersion,
    required this.notes,
    required this.apkUrl,
    required this.sha256,
    required this.size,
    required this.issuedAt,
  });

  /// Pflicht-Update: die installierte Version ist älter als die Mindestversion.
  bool pflichtFuer(String installiert) => compareVersions(installiert, minVersion) < 0;
}

/// Antwort von /api/v1/version (nur die Felder, die die App braucht).
class ServerVersion {
  final int protocolVersion;
  final int minProtocolVersion;
  final String minAppVersion;
  final String? webVersion;

  /// Version des Servers (Anzeige im Bereich "Über"); null bei älteren Servern.
  final String? version;
  const ServerVersion({
    this.version,
    required this.protocolVersion,
    required this.minProtocolVersion,
    required this.minAppVersion,
    required this.webVersion,
  });

  static ServerVersion? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final protocol = json['protocolVersion'];
    final minProtocol = json['minProtocolVersion'];
    final minApp = json['minAppVersion'];
    final web = json['webVersion'];
    final ver = json['version'];
    if (protocol is! int || minProtocol is! int || minApp is! String || !isVersion(minApp)) return null;
    return ServerVersion(
      version: ver is String && ver.isNotEmpty && ver.length <= 40 ? ver : null,
      protocolVersion: protocol,
      minProtocolVersion: minProtocol,
      minAppVersion: minApp,
      webVersion: web is String && web.isNotEmpty ? web : null,
    );
  }

  /// Die App spricht ein Protokoll, das der Server nicht mehr unterstützt.
  bool get protokollZuAlt => kProtocolVersion < minProtocolVersion;

  /// Die installierte App-Version ist älter als die Mindestversion des Servers.
  bool appZuAlt(String installiert) => compareVersions(installiert, minAppVersion) < 0;
}

class UpdateState {
  final UpdatePhase phase;
  final String? installierteVersion;
  final UpdateInfo? info;
  final double fortschritt;
  final String? fehler;
  final String? apkPfad;

  /// Pflicht-Update: Server verlangt eine neuere App-Version bzw. ein neueres Protokoll, oder das Manifest
  /// hat eine höhere Mindestversion. Die Oberfläche bietet dann nur noch das Update an.
  final bool pflicht;

  /// Web: Der Server liefert eine neuere Web-Version aus als die geladene.
  final bool webNeu;

  const UpdateState({
    this.phase = UpdatePhase.aktuell,
    this.installierteVersion,
    this.info,
    this.fortschritt = 0,
    this.fehler,
    this.apkPfad,
    this.pflicht = false,
    this.webNeu = false,
  });

  bool get updateDa => phase == UpdatePhase.verfuegbar || phase == UpdatePhase.bereit || webNeu;

  UpdateState copyWith({
    UpdatePhase? phase,
    String? installierteVersion,
    UpdateInfo? info,
    double? fortschritt,
    String? fehler,
    String? apkPfad,
    bool? pflicht,
    bool? webNeu,
  }) =>
      UpdateState(
        phase: phase ?? this.phase,
        installierteVersion: installierteVersion ?? this.installierteVersion,
        info: info ?? this.info,
        fortschritt: fortschritt ?? this.fortschritt,
        fehler: fehler,
        apkPfad: apkPfad ?? this.apkPfad,
        pflicht: pflicht ?? this.pflicht,
        webNeu: webNeu ?? this.webNeu,
      );

  /// Zustand "aktuell": setzt Update-Angaben (info, apkPfad, Fortschritt, Fehler) zurück.
  UpdateState aktuell({bool pflicht = false, bool webNeu = false}) =>
      UpdateState(installierteVersion: installierteVersion, pflicht: pflicht, webNeu: webNeu);
}

final manifestVerifierProvider = Provider<ManifestVerifier>((ref) => Ed25519ManifestVerifier.base64(kUpdatePublicKey));

class UpdateController extends Notifier<UpdateState> {
  static const _channel = MethodChannel(kUpdateChannel);

  http.Client get _client => ref.read(httpClientProvider);

  @override
  UpdateState build() => const UpdateState();

  Future<String> _version() async {
    final bekannt = state.installierteVersion;
    if (bekannt != null) return bekannt;
    final v = await _channel.invokeMethod<String>('appVersion') ?? '0.0.0';
    state = state.copyWith(installierteVersion: v);
    return v;
  }

  Future<int> _versionCode() async => await _channel.invokeMethod<int>('appVersionCode') ?? 0;

  /// Installierte Version und Build-Nummer für den Bereich "Über" (Web und Tests ohne Kanal: null).
  Future<(String?, int?)> installierteAngaben() async {
    if (kIsWeb) return (null, null);
    try {
      return (await _version(), await _versionCode());
    } on PlatformException {
      return (null, null);
    } on MissingPluginException {
      return (null, null);
    }
  }

  /// Version des Servers (öffentlich für den Bereich "Über"); null bei jedem Fehler.
  Future<ServerVersion?> serverVersion() => _serverVersion();

  /// Der Sync meldet 426 (Protokoll zu alt): ab jetzt Pflicht-Update, bis die App aktualisiert ist.
  void pflichtSetzen() => state = state.copyWith(pflicht: true);

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

  /// Fragt /api/v1/version ab; null bei jedem Fehler (offline, alter Server): dann gilt kein Zwang.
  Future<ServerVersion?> _serverVersion() async {
    try {
      final res = await _client.get(Uri.base.resolve('$kApiBase/api/v1/version')).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      return ServerVersion.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
    } catch (_) {
      return null;
    }
  }

  /// Sucht nach einer neueren Version. Fehler (z. B. offline) landen nur im Status.
  /// Läuft schon eine Prüfung, ein Download oder liegt ein geladenes Update bereit, passiert nichts.
  Future<void> pruefen() async {
    final p = state.phase;
    if (p == UpdatePhase.deaktiviert || p == UpdatePhase.pruefe || p == UpdatePhase.laedt || p == UpdatePhase.bereit) return;
    state = state.copyWith(phase: UpdatePhase.pruefe);
    try {
      if (kIsWeb) {
        await _webPruefen();
      } else {
        await _androidPruefen();
      }
    } on http.ClientException {
      state = state.copyWith(phase: UpdatePhase.fehler, fehler: 'Keine Verbindung zum Update-Server');
    } catch (e) {
      state = state.copyWith(phase: UpdatePhase.fehler, fehler: 'Update-Prüfung fehlgeschlagen: ${_text(e)}');
    }
  }

  /// Web: kein APK, nur der Hinweis "Neue Version - neu laden".
  Future<void> _webPruefen() async {
    final server = await _serverVersion();
    final neu = server != null &&
        (server.protokollZuAlt || (kWebVersion.isNotEmpty && server.webVersion != null && server.webVersion != kWebVersion));
    state = state.aktuell(webNeu: neu, pflicht: server?.protokollZuAlt ?? false);
  }

  Future<void> _androidPruefen() async {
    pruefeBasisAdressen();
    final aktuell = await _version();
    final server = await _serverVersion();
    final serverPflicht = server != null && (server.protokollZuAlt || server.appZuAlt(aktuell));

    final res = await _client.get(Uri.parse('$kReleasesBase/android/latest.json')).timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) {
      state = state.aktuell(pflicht: serverPflicht); // noch kein Release veröffentlicht
      return;
    }
    if (res.statusCode != 200) throw Exception('Update-Server: HTTP ${res.statusCode}');
    final code = await _versionCode();
    final info = await parseManifest(
      utf8.decode(res.bodyBytes),
      verifier: ref.read(manifestVerifierProvider),
      installierteVersionCode: code,
    );
    if (info.versionCode <= code || compareVersions(info.version, aktuell) <= 0) {
      state = state.aktuell(pflicht: serverPflicht);
      return;
    }
    state = state.copyWith(phase: UpdatePhase.verfuegbar, info: info, pflicht: serverPflicht || info.pflichtFuer(aktuell));
  }

  /// Lädt die APK herunter und prüft Größe und SHA-256-Prüfsumme aus dem signierten Manifest.
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

  /// Startet die Android-Installation (nur per Klick). Rechnet vorher die Prüfsumme der Datei neu nach.
  /// Ohne Erlaubnis "Unbekannte Apps installieren" öffnet Android zuerst die Einstellung; danach erneut tippen.
  /// Während Abgleich oder offenen Änderungen gesperrt.
  Future<String?> installieren() async {
    final pfad = state.apkPfad;
    final info = state.info;
    if (pfad == null || info == null || state.phase != UpdatePhase.bereit) return 'Kein geladenes Update vorhanden';
    if (ref.read(syncProvider).beschaeftigt) return 'Bitte warten, bis der Abgleich abgeschlossen ist.';
    if (!await apkPruefsummeStimmt(pfad, info.sha256)) {
      state = UpdateState(
        phase: UpdatePhase.verfuegbar,
        installierteVersion: state.installierteVersion,
        info: info,
        pflicht: state.pflicht,
      );
      return 'Die geladene Datei ist nicht mehr unverändert und wurde verworfen. Bitte erneut herunterladen.';
    }
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

/// Ältestes akzeptiertes Ausstellungsdatum eines Manifests, das ein Update anbietet (Schutz vor altem Manifest).
const kManifestMaxAlter = Duration(days: 365);

/// Erlaubte Abweichung der Uhr des Geräts gegenüber `issuedAt`.
const _uhrToleranz = Duration(days: 1);

/// Liest und prüft das Manifest. Wirft eine Exception mit verständlichem Text bei jedem Fehler.
///
/// Reihenfolge: (1) Signatur über den Payload-Text, erst danach wird der Payload überhaupt gelesen;
/// (2) Paketname und Schlüssel-ID; (3) Formate; (4) ein Manifest mit kleinerem versionCode als der installierte
/// wird abgelehnt (altes Manifest/Downgrade); (5) liegt ein Update an, darf `issuedAt` nicht in der Zukunft
/// liegen und nicht älter als [kManifestMaxAlter] sein. Ein Manifest mit gleichem versionCode ist gültig
/// ("aktuell") und braucht keine Altersprüfung.
@visibleForTesting
Future<UpdateInfo> parseManifest(
  String json, {
  required ManifestVerifier verifier,
  required int installierteVersionCode,
  DateTime? jetzt,
  String releasesBase = kReleasesBase,
  String packageName = kPackageName,
  String keyId = kUpdateKeyId,
}) async {
  // Solange nur der Platzhalter-Schlüssel eingebaut ist, gibt es keinen vertrauenswürdigen Signierer: nichts akzeptieren.
  if (keyId == kPlatzhalterKeyId) {
    throw Exception('Updates sind noch nicht eingerichtet (Platzhalter-Schlüssel)');
  }
  final Object? raw = jsonDecode(json);
  if (raw is! Map<String, dynamic>) throw Exception('Manifest ungültig');
  final signature = raw['signature'];
  final payload = raw['payload'];
  if (signature is! String || payload is! String) throw Exception('Manifest ist nicht signiert');
  if (!await verifier.verify(payload: payload, signature: signature)) throw Exception('Signatur des Manifests ungültig');

  final Object? daten = jsonDecode(payload);
  if (daten is! Map<String, dynamic>) throw Exception('Manifest ungültig');
  if (daten['packageName'] != packageName) throw Exception('Manifest gehört zu einer anderen App');
  if (daten['keyId'] != keyId) throw Exception('Manifest: unbekannter Schlüssel');
  final version = daten['version'];
  final versionCode = daten['versionCode'];
  final minVersion = daten['minVersion'] ?? '0.0.0';
  final sha = daten['sha256'];
  final apk = daten['apk'];
  final size = daten['size'];
  final issued = daten['issuedAt'];
  if (version is! String || !isVersion(version)) throw Exception('Manifest: Version ungültig');
  if (versionCode is! int || versionCode < 1) throw Exception('Manifest: versionCode ungültig');
  if (minVersion is! String || !isVersion(minVersion)) throw Exception('Manifest: Mindestversion ungültig');
  if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) throw Exception('Manifest: Prüfsumme ungültig');
  if (size is! int || size < 1 || size > kMaxApkBytes) throw Exception('Manifest: Größe ungültig');
  // Nur Dateinamen im Release-Ordner zulassen (keine fremden Adressen, kein Pfad nach oben)
  if (apk is! String || !RegExp(r'^[A-Za-z0-9._-]+\.apk$').hasMatch(apk)) throw Exception('Manifest: APK-Name ungültig');
  final issuedAt = issued is String ? DateTime.tryParse(issued)?.toUtc() : null;
  if (issuedAt == null) throw Exception('Manifest: Ausstellungsdatum ungültig');

  if (versionCode < installierteVersionCode) throw Exception('Manifest ist älter als die installierte Version');
  if (versionCode > installierteVersionCode) {
    final now = (jetzt ?? DateTime.now()).toUtc();
    if (issuedAt.isAfter(now.add(_uhrToleranz))) throw Exception('Manifest: Ausstellungsdatum liegt in der Zukunft');
    if (now.difference(issuedAt) > kManifestMaxAlter) throw Exception('Manifest ist zu alt');
  }
  return UpdateInfo(
    version: version,
    versionCode: versionCode,
    minVersion: minVersion,
    notes: (daten['notes'] as String?) ?? '',
    apkUrl: Uri.parse('$releasesBase/android/$apk'),
    sha256: sha,
    size: size,
    issuedAt: issuedAt,
  );
}
