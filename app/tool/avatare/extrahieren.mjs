// Zieht die zehn gewählten Platzhalter aus docs/mockups/avatare.html und schreibt je eine eigenständige SVG-Datei
// (ohne Hintergrund: den liefert die App je Person aus der Personenpalette). Aufruf aus der Repo-Wurzel:
//   node app/tool/avatare/extrahieren.mjs
// Danach rendert app/tool/avatare/rendern.mjs die SVGs zu PNG (app/assets/avatare/).
import fs from 'node:fs';

const NAMEN = {
  V01: 'vater_kurzhaar_hemd', V08: 'vater_basecap_hoodie', V12: 'vater_undercut_sonnenbrille',
  M01: 'mutter_lange_haare', M08: 'mutter_kurzhaarschnitt', M13: 'mutter_seitenzopf_brille',
  K07: 'kind_schulkind_basecap', K08: 'kind_schulkind_zoepfchen', K12: 'kind_teenager_kopfhoerer', K13: 'kind_teenager_lange_haare',
};
const html = fs.readFileSync('docs/mockups/avatare.html', 'utf8');
fs.mkdirSync('app/tool/avatare/svg', { recursive: true });
for (const [id, name] of Object.entries(NAMEN)) {
  const m = html.match(new RegExp(`<symbol id="${id}" viewBox="0 0 100 100">([^]*?)</symbol>`));
  if (!m) throw new Error('Symbol fehlt: ' + id);
  let inner = m[1];
  if (/<use|url\(|<defs|filter|<image|<script|href/.test(inner)) throw new Error('Unerwartetes Element in ' + id);
  // erste Fläche = Hintergrund des Mockups (volle Kachel): weg, die App malt die Personenfarbe darunter
  const bg = /^<rect width="100" height="100" fill="#[0-9A-Fa-f]{3,6}"\/>/;
  if (!bg.test(inner)) throw new Error('Hintergrund nicht erkannt: ' + id);
  inner = inner.replace(bg, '');
  fs.writeFileSync(`app/tool/avatare/svg/${id.toLowerCase()}_${name}.svg`, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">${inner}</svg>\n`);
}
console.log('fertig');
