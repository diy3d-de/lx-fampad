import fs from 'node:fs';
function edit(file, pairs) {
  let s = fs.readFileSync(file, 'utf8');
  for (const [a, b] of pairs) {
    if (!s.includes(a)) throw new Error('fehlt in ' + file + ': ' + a.slice(0, 70));
    s = s.replace(a, b);
  }
  fs.writeFileSync(file, s);
}
edit('lib/features/shell/desktop_shell.dart', [
  ["  void _kontoOeffnen() {\n    final nav = _navKey.currentState;\n    if (nav == null || _beobachter.konto.value) return;\n    nav.push<void>(ProfileScreen.route());\n  }",
   "  /// Konto und Betrieb stapeln nicht: vor dem Öffnen werden die offenen Unterseiten (auch die andere der beiden) per `maybePop` geschlossen;\n  /// lehnt eine Seite das Schließen ab (ungespeicherte Eingaben), bleibt alles, wie es ist.\n  Future<void> _kontoOeffnen() async {\n    if (_navKey.currentState == null || _beobachter.konto.value) return;\n    if (_beobachter.betrieb.value && !await _unterseitenSchliessen()) return;\n    if (!mounted || _beobachter.konto.value) return;\n    unawaited(_navKey.currentState?.push<void>(ProfileScreen.route()));\n  }"],
  ["  void _betriebOeffnen() {\n    final nav = _navKey.currentState;\n    if (nav == null || _beobachter.betrieb.value) return;\n    nav.push<void>(BetriebScreen.route());\n  }",
   "  Future<void> _betriebOeffnen() async {\n    if (_navKey.currentState == null || _beobachter.betrieb.value) return;\n    if (_beobachter.konto.value && !await _unterseitenSchliessen()) return;\n    if (!mounted || _beobachter.betrieb.value) return;\n    unawaited(_navKey.currentState?.push<void>(BetriebScreen.route()));\n  }"],
]);
edit('lib/features/profile/profile_screen.dart', [
  ["            onTap: () => Navigator.of(context).push<void>(BetriebScreen.route()),",
   "            // im Desktop-Layout ersetzt die Seite das Konto (beide stapeln dort nicht), mobil liegt sie darüber\n            onTap: () => DesktopShellMarke.vorhanden(context) ? Navigator.of(context).pushReplacement<void, void>(BetriebScreen.route()) : Navigator.of(context).push<void>(BetriebScreen.route()),"],
  ["import '../auth/step_up.dart';\n", "import '../auth/step_up.dart';\nimport '../shell/desktop_shell.dart' show DesktopShellMarke;\n"],
]);
