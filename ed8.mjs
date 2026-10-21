import fs from 'node:fs';
function edit(file, pairs) {
  let s = fs.readFileSync(file, 'utf8');
  for (const [a, b] of pairs) {
    if (!s.includes(a)) throw new Error('fehlt in ' + file + ': ' + a.slice(0, 70));
    s = s.replace(a, b);
  }
  fs.writeFileSync(file, s);
}
edit('lib/data/betrieb/betrieb_modelle.dart', [
  ["  final bool? ausstehend;\n  const BetriebMigrationen({this.angewendet, this.erwartet, this.letzte, this.ausstehend});",
   "  final bool? ausstehend;\n\n  /// Die Laufzeitrolle darf die Migrationstabelle nicht lesen (Grant fehlt, siehe deploy/README).\n  final bool grantFehlt;\n  const BetriebMigrationen({this.angewendet, this.erwartet, this.letzte, this.ausstehend, this.grantFehlt = false});"],
  ["  final BetriebStufe gesamt;\n", "  final BetriebStufe gesamt;\n\n  /// Quellen ohne Messwert: \"in Ordnung\" gilt dann nur für das Gemessene.\n  final int unbekannt;\n"],
  ["    required this.gesamt,\n", "    required this.gesamt,\n    required this.unbekannt,\n"],
  ["      gesamt: gesamt == BetriebStufe.aus ? BetriebStufe.unbekannt : gesamt,\n", "      gesamt: gesamt == BetriebStufe.aus ? BetriebStufe.unbekannt : gesamt,\n      unbekannt: _zahl(m['unknownCount']) ?? 0,\n"],
  ["        ausstehend: mig['pending'] is bool ? mig['pending'] as bool : null,\n", "        ausstehend: mig['pending'] is bool ? mig['pending'] as bool : null,\n        grantFehlt: mig['grantMissing'] == true,\n"],
]);
edit('lib/data/api/fampad_api.dart', [
  ["  Future<BetriebStatus> betriebStatus() async => BetriebStatus.fromJson(await client.get('/admin/status'));",
   "  /// [frisch] umgeht den kurzen Cache des Servers (der begrenzt das selbst auf höchstens eine Messung je 5 Sekunden).\n  Future<BetriebStatus> betriebStatus({bool frisch = false}) async => BetriebStatus.fromJson(await client.get(frisch ? '/admin/status?fresh=1' : '/admin/status'));"],
]);
edit('lib/data/betrieb/betrieb_state.dart', [
  ["  Future<void> laden() async {\n    if (_laeuft", "  Future<void> laden({bool frisch = false}) async {\n    if (_laeuft"],
  ["betriebStatus();", "betriebStatus(frisch: frisch);"],
]);
edit('lib/features/betrieb/betrieb_anzeige.dart', [
  ["String gesamtText(BetriebStufe s) => switch (s) {\n  BetriebStufe.ok => 'alles in Ordnung',",
   "String gesamtText(BetriebStufe s, {int unbekannt = 0}) => switch (s) {\n  BetriebStufe.ok when unbekannt > 0 => 'in Ordnung, $unbekannt unbekannt',\n  BetriebStufe.ok => 'alles in Ordnung',"],
  ["/// Gesamtzustand für die Zeile", "/// Farbe der Gesamtzeile: \"in Ordnung\" mit unbekannten Quellen ist neutral, nicht grün.\nColor gesamtFarbe(BetriebStufe s, {int unbekannt = 0}) => s == BetriebStufe.ok && unbekannt > 0 ? kTextMuted : stufeFarbe(s);\n\n/// Gesamtzustand für die Zeile"],
]);
edit('lib/features/betrieb/betrieb_screen.dart', [
  ["          onPressed: st.laedt\n              ? null\n              : () {\n                  unawaited(ref.read(betriebStatusProvider.notifier).laden());\n                  if (_seite == _Seite.protokoll) unawaited(_protokollLaden());\n                },",
   "          onPressed: st.laedt\n              ? null\n              : () {\n                  unawaited(ref.read(betriebStatusProvider.notifier).laden(frisch: true));\n                  // auch die Ereignisse neu laden; auf der Übersicht still (ohne Step-up-Abfrage), auf der Protokollseite mit\n                  unawaited(_protokollLaden(still: _seite != _Seite.protokoll));\n                },"],
  ["    final farbe = stufeFarbe(s.gesamt);", "    final farbe = gesamtFarbe(s.gesamt, unbekannt: s.unbekannt);"],
  ["StatusPill('● ${gesamtText(s.gesamt)}', color: farbe)", "StatusPill('● ${gesamtText(s.gesamt, unbekannt: s.unbekannt)}', color: farbe)"],
  ["        hinweis: s.datenbankOk ? 'Migrationen ${mig.angewendet ?? '?'} von ${mig.erwartet ?? '?'}' : 'nicht erreichbar',",
   "        hinweis: !s.datenbankOk\n            ? 'nicht erreichbar'\n            : (mig.angewendet == null ? (mig.grantFehlt ? 'Migrationsstand unbekannt: Grant fehlt, siehe README' : 'Migrationsstand unbekannt') : 'Migrationen ${mig.angewendet} von ${mig.erwartet ?? '?'}'),"],
  ["        final spalten = c.maxWidth >= 600 ? 3 : 2;", "        // große Schrift: eine Spalte, sonst brechen die Kacheln um\n        final grosseSchrift = MediaQuery.textScalerOf(context).scale(10) > 13;\n        final spalten = grosseSchrift ? 1 : (c.maxWidth >= 600 ? 3 : 2);"],
  ["Antwort ${ms ?? '?'} ms · ${groesseText(s.datenbankBytes)}${s.migrationen.ausstehend == true ? ' · Migration ausstehend' : ''}'",
   "Antwort ${ms ?? '?'} ms · ${groesseText(s.datenbankBytes)}${s.migrationen.ausstehend == true ? ' · Migration ausstehend' : ''}${s.migrationen.angewendet == null ? (s.migrationen.grantFehlt ? ' · Grant fehlt, siehe README' : '') : ''}'"],
  ["            onTap: () => Navigator.of(context).push<void>(BetriebScreen.route()),", "XX"],
]);
