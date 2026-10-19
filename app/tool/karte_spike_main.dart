// Eigenständiger Einstieg nur für den Karten-Spike (ohne Anmeldung und Server): zeigt die Karten-Seite direkt.
//   flutter run -d chrome -t tool/karte_spike_main.dart
//   flutter build web --release --no-web-resources-cdn -t tool/karte_spike_main.dart
// Gehört nicht zur App (kein Teil von lib/main.dart); dient der Browser-Prüfung unter der echten CSP und dem Emulator-Test.
import 'package:flutter/material.dart';
import 'package:lx_fampad/constants.dart';
import 'package:lx_fampad/features/karte/karte_spike_screen.dart';
import 'package:lx_fampad/ui/theme.dart';

void main() {
  runApp(MaterialApp(title: kAppName, theme: buildTheme(), home: const KarteSpikeScreen()));
}
