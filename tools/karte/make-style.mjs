// Erzeugt den statischen Kartenstil (app/assets/karte/style.json), die Glyphen (nur Latein) und die Sprites (app/web/karte/).
// Werkzeug, nicht Teil der App: Die Pakete liegen außerhalb des Repos (siehe tools/karte/README.md).
//   KARTE_TOOLS=<Ordner mit node_modules/@protomaps/basemaps> ASSETS=<Checkout von protomaps/basemaps-assets> node tools/karte/make-style.mjs
// Farben stehen NUR hier und im erzeugten Style (Dart-Code nutzt Konstanten). Werte entsprechen app/lib/constants.dart (Dark-Design).
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const tools = process.env.KARTE_TOOLS;
const assets = process.env.ASSETS;
if (!tools || !assets) throw new Error('KARTE_TOOLS und ASSETS setzen (siehe tools/karte/README.md)');
const { layers, namedFlavor } = await import(pathToFileURL(path.join(tools, 'node_modules/@protomaps/basemaps/dist/esm/index.js')).href);

const root = path.resolve(import.meta.dirname, '../..');
const outStyle = path.join(root, 'app/assets/karte/style.json');
const outWeb = path.join(root, 'app/web/karte');

// --- Farben aus den Design-Tokens (constants.dart) ---------------------------------------------------------------------------
const T = { bg: '#090A0F', bgElevated: '#0E1017', surface: '#13161F', border: '#242936', text: '#E6E8EE', muted: '#8B93A7', faint: '#5D6578', accent: '#00F0FF', neural: '#7C3AED' };
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const toHex = (c) => '#' + c.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('');
const mix = (a, b, t) => { const x = hex(a), y = hex(b); return toHex(x.map((v, i) => v + (y[i] - v) * t)); };

// Das Protomaps-Thema "black" ist eine Graustufen-Rampe. Jede Stufe wird auf die Rampe bg -> muted (bläulich) abgebildet.
const black = namedFlavor('black');
const flavor = {};
for (const [k, v] of Object.entries(black)) {
  if (typeof v !== 'string' || !/^#[0-9a-f]{6}$/i.test(v)) { flavor[k] = v; continue; }
  const g = hex(v)[0] / 153; // 0x99 (Stadtnamen) = 1
  flavor[k] = mix(T.bg, T.muted, Math.min(g, 1.3));
}
Object.assign(flavor, {
  background: T.bg,
  earth: T.bg,
  water: '#0B2230',
  ocean_label: '#3F7F95',
  park_a: '#0C1A18', park_b: '#0C1A18', wood_a: '#0B1816', wood_b: '#0B1816', scrub_a: '#0C1714', scrub_b: '#0C1714',
  buildings: T.bgElevated,
  minor_a: '#1D2230', minor_b: '#171B27', minor_service: '#141824', other: '#171B27', link: '#2A3042',
  major: '#2E3548', highway: '#3A4560', railway: '#2A3042',
  major_casing_early: T.bg, highway_casing_early: T.bg, major_casing_late: T.bg, highway_casing_late: T.bg,
  boundaries: '#4A3C7A',
  roads_label_minor: T.faint, roads_label_major: T.muted,
  subplace_label: T.muted, city_label: T.text, state_label: T.faint, country_label: T.muted,
  roads_label_minor_halo: T.bg, roads_label_major_halo: T.bg, subplace_label_halo: T.bg, city_label_halo: T.bg, state_label_halo: T.bg, address_label_halo: T.bg,
});

const ATTR = '<a href="https://www.openstreetmap.org/copyright">© OpenStreetMap-Mitwirkende</a>';
const style = {
  version: 8,
  name: 'lx-familyhub (Protomaps, dunkel)',
  // Platzhalter ersetzt die App zur Laufzeit (features/karte/karte_config.dart): absolute Adressen, auch für Android
  glyphs: '{{KARTE_BASE}}/glyphs/{fontstack}/{range}.pbf',
  sprite: '{{KARTE_BASE}}/sprites/black',
  sources: { protomaps: { type: 'vector', url: 'pmtiles://{{PMTILES_URL}}', attribution: ATTR } },
  layers: layers('protomaps', flavor, { lang: 'de' }),
};
// Vereinfachte Beschriftung: Protomaps wählt Namen je Schrift (is-supported-script, Devanagari-Schriftwechsel in format-Abschnitten). MapLibre Native
// (Android) zeigte damit keine Beschriftung; für Deutschland genügt der deutsche Name mit Rückfall auf den Ortsnamen. Nur Latein-Glyphen werden ausgeliefert.
for (const l of style.layers) {
  const tf = l.layout?.['text-field'];
  if (Array.isArray(tf) && tf[0] === 'case') l.layout['text-field'] = ['coalesce', ['get', 'name:de'], ['get', 'name']];
  // MapLibre Native wertet Ausdrücke in text-font und text-variable-anchor nicht aus (Beschriftung fehlt): feste Werte
  const tfont = l.layout?.['text-font'];
  if (Array.isArray(tfont) && !String(tfont[0]).startsWith('Noto')) l.layout['text-font'] = ['Noto Sans Regular'];
  const anchor = l.layout?.['text-variable-anchor'];
  if (Array.isArray(anchor) && ['step', 'case', 'literal', 'interpolate'].includes(anchor[0])) l.layout['text-variable-anchor'] = ['bottom', 'left', 'right', 'top'];
}
fs.mkdirSync(path.dirname(outStyle), { recursive: true });
fs.writeFileSync(outStyle, JSON.stringify(style) + '\n');
console.log('Style', outStyle, fs.statSync(outStyle).size, 'Byte,', style.layers.length, 'Ebenen');

// --- Glyphen: nur die Schriften des Styles, nur lateinische Bereiche (Deutsch, Westeuropa, Satzzeichen; ca. 0,9 MB) --------------------------
const RANGES = ['0-255', '256-511', '8192-8447'];
const fonts = new Set();
for (const l of style.layers) {
  const f = l.layout?.['text-font'];
  if (f) JSON.stringify(f).match(/Noto Sans [A-Za-z ]+?(?=")/g).forEach((x) => fonts.add(x));
}
fs.rmSync(path.join(outWeb, 'glyphs'), { recursive: true, force: true });
for (const f of fonts) {
  fs.mkdirSync(path.join(outWeb, 'glyphs', f), { recursive: true });
  for (const r of RANGES) fs.copyFileSync(path.join(assets, 'fonts', f, `${r}.pbf`), path.join(outWeb, 'glyphs', f, `${r}.pbf`));
}
fs.copyFileSync(path.join(assets, 'fonts/OFL.txt'), path.join(outWeb, 'glyphs/OFL.txt'));
console.log('Glyphen:', [...fonts].join(', '), RANGES.join(' '));

// --- Sprites (Version 4, Thema black) ------------------------------------------------------------------------------------------
fs.rmSync(path.join(outWeb, 'sprites'), { recursive: true, force: true });
fs.mkdirSync(path.join(outWeb, 'sprites'), { recursive: true });
for (const n of ['black.json', 'black.png', 'black@2x.json', 'black@2x.png']) fs.copyFileSync(path.join(assets, 'sprites/v4', n), path.join(outWeb, 'sprites', n));
console.log('Sprites kopiert');
