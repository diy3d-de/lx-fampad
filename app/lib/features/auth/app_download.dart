// "App installieren": fester Download-Link der Android-App (ohne Token, nie mit Einladungsdaten gemischt).
// Einladungs-Ergebnisseite (QR + Link), Willkommenshinweis im Browser und Profil > Über nutzen dieselben Bausteine.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import 'auth_widgets.dart';
import 'download_oeffnen_stub.dart' if (dart.library.js_interop) 'download_oeffnen_web.dart';
import 'qr_anzeige.dart';

/// Ist das Gerät ein Android-Gerät (im Browser: Android-Browser)? Für Tests überschreibbar.
bool istAndroidGeraet() => defaultTargetPlatform == TargetPlatform.android;

/// Hinweise zur Installation (Ergebnisseite der Einladung).
const kInstallHinweis =
    'Android: Beim Installieren ggf. Installation aus dieser Quelle erlauben; hilft nichts, die Automatische Sperre (Samsung) kurz ausschalten.';
const kOderBrowserHinweis = 'Oder öffne den Einladungslink einfach im Browser.';

/// Abschnitt "App installieren" mit Link, Kopieren-Knopf und QR-Code des Download-Links.
class AppInstallierenBlock extends StatelessWidget {
  const AppInstallierenBlock({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const MonoLabel('// app installieren', color: kTextMuted),
      const SizedBox(height: 4),
      const Text(
        'Lade $kAppName für Android herunter. Dieser Link enthält keine Einladungsdaten.',
        style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
      ),
      const SizedBox(height: 12),
      const QrAnzeige(daten: kApkDownloadUrl, beschreibung: 'QR-Code des App-Download-Links'),
      const SizedBox(height: 12),
      Semantics(
        label: 'App-Download-Link',
        child: const SelectableText(kApkDownloadUrl, style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: kAccent)),
      ),
      const SizedBox(height: 8),
      ZweitKnopf(text: 'Download-Link kopieren', icon: Icons.copy, onPressed: () => inZwischenablage(context, kApkDownloadUrl, 'Download-Link kopiert.')),
      const SizedBox(height: 8),
      const Text(kInstallHinweis, style: TextStyle(fontSize: 12, height: 1.5, color: kTextMuted)),
      const SizedBox(height: 4),
      const Text(kOderBrowserHinweis, style: TextStyle(fontSize: 12, height: 1.5, color: kTextMuted)),
    ],
  );
}

/// Hinweis im Browser vor dem Registrieren. [android] (Standard: Android-Browser) zeigt ein auffälliges Feld mit Knopf,
/// sonst nur ein dezenter Text. In der App selbst erscheint nichts (siehe [istWeb]).
class WillkommenAppHinweis extends StatelessWidget {
  final bool? android;
  final bool? istWeb;
  const WillkommenAppHinweis({super.key, this.android, this.istWeb});

  @override
  Widget build(BuildContext context) {
    if (!(istWeb ?? kIsWeb)) return const SizedBox.shrink();
    if (!(android ?? istAndroidGeraet())) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Semantics(
          label: 'Hinweis: App für Android',
          child: const Text(
            '$kAppName gibt es auch als Android-App: $kApkDownloadUrl',
            style: TextStyle(fontSize: 12, height: 1.5, color: kTextMuted),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('// lieber die app?'),
            const SizedBox(height: 8),
            const Text(
              'Lieber die App? $kAppName für Android herunterladen',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kTextStrong),
            ),
            const SizedBox(height: 4),
            const Text(
              'Die Einladung kannst du danach in der App annehmen. Oder mach einfach hier im Browser weiter.',
              style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
            ),
            const SizedBox(height: 12),
            ZweitKnopf(
              text: 'App herunterladen',
              icon: Icons.download,
              onPressed: () {
                if (!downloadOeffnen(kApkDownloadUrl)) inZwischenablage(context, kApkDownloadUrl, 'Download-Link kopiert.');
              },
            ),
            const SizedBox(height: 8),
            const Text(kInstallHinweis, style: TextStyle(fontSize: 12, height: 1.5, color: kTextMuted)),
          ],
        ),
      ),
    );
  }
}
