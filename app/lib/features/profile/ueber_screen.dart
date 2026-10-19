// Profil > Über: App-Version und Build-Nummer, Server-Version und Protokoll, Plattform, Gerätename, Update-Stand
// und "Nach Update suchen" (die vorhandene Update-Prüfung). Ein Tipp auf die Versionszeile kopiert eine Kurzangabe
// (ohne persönliche Daten) in die Zwischenablage, nur auf Klick.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../auth/auth_widgets.dart';
import '../karte/karte_spike_screen.dart';
import '../update/update_service.dart';
import 'profile_screen.dart' show EinstellungsZeile;

/// Angaben für die Anzeige. [version] ist im Web die Kennung des Bundles (WEB_VERSION, lokal "dev").
class UeberInfo {
  final String version;
  final int? build;
  final String plattform;
  final String? geraet;
  final ServerVersion? server;
  const UeberInfo({required this.version, this.build, required this.plattform, this.geraet, this.server});

  /// Kurzangabe für die Zwischenablage, z. B. "lx-familyhub 0.2.0 (1002) · Android".
  String get kurz => '$kAppName $version${build != null ? ' ($build)' : ''} · $plattform';
}

final ueberInfoProvider = FutureProvider.autoDispose<UeberInfo>((ref) async {
  final update = ref.read(updateProvider.notifier);
  final server = await update.serverVersion();
  if (kIsWeb) {
    return UeberInfo(version: kWebVersion.isNotEmpty ? kWebVersion : 'dev', plattform: 'Web', server: server);
  }
  final (version, build) = await update.installierteAngaben();
  final geraet = (await ref.read(systemChannelProvider).geraetename())?.trim();
  return UeberInfo(
    version: version ?? '–',
    build: build != null && build > 0 ? build : null,
    plattform: defaultTargetPlatform == TargetPlatform.android ? 'Android' : 'App',
    geraet: geraet == null || geraet.isEmpty ? null : geraet,
    server: server,
  );
});

class UeberScreen extends ConsumerWidget {
  const UeberScreen({super.key});

  Future<void> _kopieren(BuildContext context, UeberInfo info) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: info.kurz));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Versionsangabe kopiert')));
  }

  String _updateText(UpdateState u) {
    switch (u.phase) {
      case UpdatePhase.pruefe:
        return 'prüfe …';
      case UpdatePhase.laedt:
        return 'lädt Update …';
      case UpdatePhase.bereit:
        return 'Update ${u.info?.version ?? ''} bereit zum Installieren'.replaceAll('  ', ' ');
      case UpdatePhase.verfuegbar:
        return 'Update ${u.info?.version ?? ''} verfügbar'.replaceAll('  ', ' ');
      case UpdatePhase.fehler:
        return u.fehler ?? 'Prüfung fehlgeschlagen';
      case UpdatePhase.deaktiviert:
        return 'Updates nicht eingerichtet';
      case UpdatePhase.aktuell:
        return u.webNeu ? 'neue Web-Version verfügbar, Seite neu laden' : 'kein Update bekannt';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(ueberInfoProvider);
    final update = ref.watch(updateProvider);
    final i = info.value;
    final server = i?.server;
    final serverText = i == null
        ? 'wird geladen …'
        : server == null
            ? 'nicht erreichbar'
            : '${server.version != null ? 'Server ${server.version}' : 'Server'} · Protokoll ${server.protocolVersion}';
    // Karten-Spike: nur für Administratoren und Debug-Builds, kein normaler Tab
    final zeigeKarte = kDebugMode || ref.watch(authProvider.select((s) => s.istAdmin));
    final pruefend = update.phase == UpdatePhase.pruefe || update.phase == UpdatePhase.laedt;
    return AuthSeite(
      label: '// app',
      titel: 'Über $kAppName',
      maxBreite: kMaxContentWidth,
      kinder: [
        Semantics(
          button: i != null,
          label: i == null ? 'Version wird geladen' : 'Version ${i.kurz}, antippen zum Kopieren',
          excludeSemantics: true,
          child: EinstellungsZeile(
            icon: Icons.info_outline,
            titel: i == null ? 'wird geladen …' : '$kAppName ${i.version}',
            untertitel: i == null ? null : [if (i.build != null) 'build ${i.build}', i.plattform].join(' · '),
            status: i == null ? null : const Icon(Icons.copy, size: 18, color: kTextMuted),
            onTap: i == null ? null : () => unawaited(_kopieren(context, i)),
          ),
        ),
        EinstellungsZeile(icon: Icons.dns_outlined, titel: 'Server', untertitel: serverText),
        if (i?.geraet != null) EinstellungsZeile(icon: Icons.phone_android, titel: 'Gerät', untertitel: i!.geraet),
        EinstellungsZeile(
          icon: update.updateDa ? Icons.system_update : Icons.check_circle_outline,
          titel: 'Update',
          untertitel: _updateText(update),
        ),
        Semantics(
          button: true,
          label: 'App-Download-Link kopieren',
          excludeSemantics: true,
          child: EinstellungsZeile(
            icon: Icons.link,
            titel: 'App-Download-Link kopieren',
            untertitel: 'zum Weitergeben der Android-App',
            status: const Icon(Icons.copy, size: 18, color: kTextMuted),
            onTap: () => unawaited(inZwischenablage(context, kApkDownloadUrl, 'Download-Link kopiert.')),
          ),
        ),
        if (zeigeKarte)
          EinstellungsZeile(
            icon: Icons.map_outlined,
            titel: 'Karte (Test)',
            untertitel: 'Spike für Standort teilen, nur für Admins',
            onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const KarteSpikeScreen())),
          ),
        const SizedBox(height: 4),
        ZweitKnopf(
          text: 'Nach Update suchen',
          icon: Icons.refresh,
          onPressed: pruefend
              ? null
              : () async {
                  await ref.read(updateProvider.notifier).pruefen();
                  ref.invalidate(ueberInfoProvider);
                },
        ),
      ],
    );
  }
}
