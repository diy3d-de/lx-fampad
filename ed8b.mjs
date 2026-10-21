import fs from 'node:fs';
function edit(file, pairs) {
  let s = fs.readFileSync(file, 'utf8');
  for (const [a, b] of pairs) {
    if (!s.includes(a)) throw new Error('fehlt in ' + file + ': ' + a.slice(0, 70));
    s = s.replace(a, b);
  }
  fs.writeFileSync(file, s);
}
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
]);
