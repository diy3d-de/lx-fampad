// Erzeugt die statischen Kartenstile (app/assets/karte/style.json dunkel, style-hell.json hell), die Glyphen (nur Latein) und die Sprites (app/web/karte/).
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

// --- Dunkel: Das Protomaps-Thema "black" ist eine Graustufen-Rampe. Jede Stufe wird auf die Rampe bg -> hell (bläulich) abgebildet.
// Gegenüber der ersten Fassung deutlich mehr Kontrast (Straßen, Ortsnamen, Straßennamen; auch am Handy in der Sonne lesbar).
const black = namedFlavor('black');
const dunkel = {};
for (const [k, v] of Object.entries(black)) {
  if (typeof v !== 'string' || !/^#[0-9a-f]{6}$/i.test(v)) { dunkel[k] = v; continue; }
  const g = hex(v)[0] / 153; // 0x99 (Stadtnamen) = 1
  dunkel[k] = mix(T.bg, T.text, Math.min(g, 1.3) * 0.8);
}
Object.assign(dunkel, {
  background: T.bg,
  earth: '#10131B',
  water: '#0F3146',
  ocean_label: '#6FB2CB',
  park_a: '#10231F', park_b: '#10231F', wood_a: '#0F201C', wood_b: '#0F201C', scrub_a: '#10201B', scrub_b: '#10201B',
  buildings: '#1B2030',
  minor_a: '#465069', minor_b: '#39425A', minor_service: '#2E3550', other: '#39425A', link: '#55618A',
  major: '#6874A0', highway: '#8190BF', railway: '#55618A',
  major_casing_early: T.bg, highway_casing_early: T.bg, major_casing_late: T.bg, highway_casing_late: T.bg,
  boundaries: '#7C66C4',
  roads_label_minor: '#B4BBCD', roads_label_major: '#D4D9E6',
  subplace_label: '#B9C0D2', city_label: '#F4F6FA', state_label: '#8F98AE', country_label: '#B9C0D2',
  roads_label_minor_halo: T.bg, roads_label_major_halo: T.bg, subplace_label_halo: T.bg, city_label_halo: T.bg, state_label_halo: T.bg, address_label_halo: T.bg,
});

// --- Hell: Protomaps-Thema "light", leicht kühl getönt (zu den Design-Tokens passend), Straßen weiß mit Rand, dunkle Beschriftung.
const hell = { ...namedFlavor('light') };
Object.assign(hell, {
  background: '#EEF0F5',
  earth: '#EEF0F5',
  water: '#B7D3E6',
  ocean_label: '#4F7F9A',
  park_a: '#D6E8D6', park_b: '#D6E8D6', wood_a: '#CCE2CE', wood_b: '#CCE2CE', scrub_a: '#D3E5D1', scrub_b: '#D3E5D1',
  buildings: '#DCE0EA',
  minor_a: '#FFFFFF', minor_b: '#FFFFFF', minor_service: '#F8F9FC', other: '#F8F9FC', link: '#FFFFFF',
  major: '#FFFFFF', highway: '#FFE7A8', railway: '#B9BFCF',
  major_casing_early: '#B8BFCF', highway_casing_early: '#D9B45A', major_casing_late: '#B8BFCF', highway_casing_late: '#D9B45A',
  boundaries: '#8F7FC4',
  roads_label_minor: '#3A4155', roads_label_major: '#222838',
  subplace_label: '#3A4155', city_label: '#10131B', state_label: '#6A7389', country_label: '#3A4155',
  roads_label_minor_halo: '#FFFFFF', roads_label_major_halo: '#FFFFFF', subplace_label_halo: '#FFFFFF', city_label_halo: '#FFFFFF', state_label_halo: '#FFFFFF', address_label_halo: '#FFFFFF',
});

const ATTR = '<a href="https://www.openstreetmap.org/copyright">© OpenStreetMap-Mitwirkende</a>';
function baueStil(titel, flavor, sprite) {
  const style = {
    version: 8,
    name: `lx-familyhub (Protomaps, ${titel})`,
    // Platzhalter ersetzt die App zur Laufzeit (features/karte/karte_config.dart): absolute Adressen, auch für Android
    glyphs: '{{KARTE_BASE}}/glyphs/{fontstack}/{range}.pbf',
    sprite: `{{KARTE_BASE}}/sprites/${sprite}`,
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
  return style;
}
const stile = [
  { datei: 'style.json', style: baueStil('dunkel', dunkel, 'black'), sprite: 'black' },
  { datei: 'style-hell.json', style: baueStil('hell', hell, 'light'), sprite: 'light' },
];
fs.mkdirSync(path.dirname(outStyle), { recursive: true });
for (const { datei, style } of stile) {
  const ziel = path.join(path.dirname(outStyle), datei);
  fs.writeFileSync(ziel, JSON.stringify(style) + '\n');
  console.log('Style', ziel, fs.statSync(ziel).size, 'Byte,', style.layers.length, 'Ebenen');
}

// --- Glyphen: nur die Schriften des Styles, nur lateinische Bereiche (Deutsch, Westeuropa, Satzzeichen; ca. 0,9 MB) --------------------------
const RANGES = ['0-255', '256-511', '8192-8447'];
const fonts = new Set();
for (const { style } of stile) {
  for (const l of style.layers) {
    const f = l.layout?.['text-font'];
    if (f) JSON.stringify(f).match(/Noto Sans [A-Za-z ]+?(?=")/g).forEach((x) => fonts.add(x));
  }
}
fs.rmSync(path.join(outWeb, 'glyphs'), { recursive: true, force: true });
for (const f of fonts) {
  fs.mkdirSync(path.join(outWeb, 'glyphs', f), { recursive: true });
  for (const r of RANGES) fs.copyFileSync(path.join(assets, 'fonts', f, `${r}.pbf`), path.join(outWeb, 'glyphs', f, `${r}.pbf`));
}
fs.copyFileSync(path.join(assets, 'fonts/OFL.txt'), path.join(outWeb, 'glyphs/OFL.txt'));
console.log('Glyphen:', [...fonts].join(', '), RANGES.join(' '));

// --- Sprites (Version 4, Themen black für dunkel und light für hell) ------------------------------------------------------------------------------------------
fs.rmSync(path.join(outWeb, 'sprites'), { recursive: true, force: true });
fs.mkdirSync(path.join(outWeb, 'sprites'), { recursive: true });
for (const n of ['black.json', 'black.png', 'black@2x.json', 'black@2x.png', 'light.json', 'light.png', 'light@2x.json', 'light@2x.png']) fs.copyFileSync(path.join(assets, 'sprites/v4', n), path.join(outWeb, 'sprites', n));
console.log('Sprites kopiert');
