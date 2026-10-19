// Erzeugt branding/icon.svg und alle PNG-Varianten (Android, Web, Play Store). Rezept: CLAUDE.md, Abschnitt "Icon neu erzeugen".
// Abhängigkeiten NICHT im Repo: in einem Werkzeugordner außerhalb `npm i opentype.js sharp`; Aufruf: ICON_TOOLS=<ordner> node branding/make-icons.mjs
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const req = createRequire(process.env.ICON_TOOLS + '/x.js');
const opentype = req('opentype.js');
const sharp = req('sharp');
const R = fileURLToPath(new URL('../', import.meta.url)).split(String.fromCharCode(92)).join('/');
const b = fs.readFileSync(R + 'app/assets/fonts/Inter.ttf');
const font = opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.length));
font.variation.set({ wght: 800, opsz: 32 });
// "lx" Größe 42, x=17, y=54, letter-spacing -2
const size = 42, scale = size / font.unitsPerEm;
let x = 17, d = '';
for (const g of [...'lx'].map(c=>font.charToGlyph(c))) {
  const p = g.getPath(0, 0, font.unitsPerEm, { variation: { wght: 800, opsz: 32 } }, font);
  const bb = p.getBoundingBox();
  d += g.getPath(x, 54, size, { variation: { wght: 800, opsz: 32 } }, font).toPathData(2);
  x += (bb.x1 + bb.x2) * scale + 0.5; // Vorschub ~ symmetrische Seitenränder (Variationsvorschub nicht von opentype.js geliefert)
}
const TXT = `<path fill="#00F0FF" d="${d}"/>`;
const BG = `<rect width="120" height="120" fill="#090A0F"/><rect width="120" height="120" fill="url(#g)"/>`;
const DEFS = `<defs><radialGradient id="g" cx=".35" cy=".3" r=".85"><stop offset="0" stop-color="#7C3AED" stop-opacity=".85"/><stop offset=".45" stop-color="#00F0FF" stop-opacity=".18"/><stop offset="1" stop-color="#090A0F" stop-opacity="0"/></radialGradient></defs>`;
const BAR = `<rect x="14" y="66" width="60" height="11" rx="5.5" fill="#00F0FF"/>`;
const FRAME = `<rect x="64" y="56" width="46" height="50" rx="10" fill="#090A0F" stroke="#00F0FF" stroke-width="3.5"/>`;
const HOUSE = `<g fill="none" stroke="#00F0FF" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M69 80L87 65L105 80"/><path d="M73 78V100H101V78"/></g>`;
const DOTS = `<circle cx="80.5" cy="86" r="3.6" fill="#38BDF8"/><circle cx="93.5" cy="86" r="3.6" fill="#34D399"/><circle cx="80.5" cy="93.5" r="3.6" fill="#FBBF24"/><circle cx="93.5" cy="93.5" r="3.6" fill="#FB7185"/>`;
const CONTENT = TXT + BAR + FRAME + HOUSE + DOTS;
const svg = (inner, vb = '0 0 120 120') => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}" width="120" height="120">${inner}</svg>`;
const T = (s) => `<g transform="translate(60 60) scale(${s}) translate(-62.9 -65.4)">${CONTENT}</g>`;
const SQ = `<rect x=".5" y=".5" width="119" height="119" rx="27" fill="#090A0F"/><rect x=".5" y=".5" width="119" height="119" rx="27" fill="url(#g)"/>`;
const BORDER = `<rect x=".5" y=".5" width="119" height="119" rx="27" fill="none" stroke="#242936"/>`;
const master = svg(DEFS + SQ + CONTENT + BORDER);
fs.writeFileSync(R + 'branding/icon.svg', master.replace('<svg ', '<svg ').replace('><defs', '>\n<defs') + '\n');
// Monochrom: Rahmeninneres ausstanzen
const MONO_C = `<defs><mask id="m"><rect width="120" height="120" fill="#fff"/><rect x="65.75" y="57.75" width="42.5" height="46.5" rx="8.25" fill="#000"/></mask></defs>`
 + `<g fill="#000" stroke="none"><g mask="url(#m)"><path d="${d}"/><rect x="14" y="66" width="60" height="11" rx="5.5"/></g>`
 + `<rect x="64" y="56" width="46" height="50" rx="10" fill="none" stroke="#000" stroke-width="3.5"/>`
 + `<g fill="none" stroke="#000" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"><path d="M69 80L87 65L105 80"/><path d="M73 78V100H101V78"/></g>`
 + `<circle cx="80.5" cy="86" r="3.6"/><circle cx="93.5" cy="86" r="3.6"/><circle cx="80.5" cy="93.5" r="3.6"/><circle cx="93.5" cy="93.5" r="3.6"/></g>`;
const monoT = `<g transform="translate(60 60) scale(.68) translate(-62.9 -65.4)">${MONO_C}</g>`;
const out = async (s, px, file, flat) => {
  fs.mkdirSync(file.replace(/[^/]+$/, ''), { recursive: true });
  let img = sharp(Buffer.from(s), { density: 72 * px / 120 }).resize(px, px);
  await img.png().toFile(file);
};
const FS = 0.74; // Skalierung Vordergrund in Safe-Zone (maskable/adaptiv/Play)
const full = svg(DEFS + BG + T(FS));
const AR = R + 'app/android/app/src/main/res/';
const WEB = R + 'app/web/';
const dens = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
for (const [k, px] of Object.entries(dens)) {
  await out(svg(DEFS + SQ + CONTENT + BORDER), px, `${AR}mipmap-${k}/ic_launcher.png`);
  const round = svg(DEFS + `<clipPath id="c"><circle cx="60" cy="60" r="60"/></clipPath><g clip-path="url(#c)">${BG}</g>` + T(0.7));
  await out(round, px, `${AR}mipmap-${k}/ic_launcher_round.png`);
}
await out(svg(DEFS + `<rect width="120" height="120" fill="#090A0F"/>` + `<rect width="120" height="120" fill="url(#g)"/>`), 432, `${AR}drawable-nodpi/ic_launcher_background.png`);
await out(svg(T(FS)), 432, `${AR}drawable-nodpi/ic_launcher_foreground.png`);
await out(svg(monoT.replace('scale(.68)', `scale(${FS})`)), 432, `${AR}drawable-nodpi/ic_launcher_monochrome.png`);
await out(full, 512, R + 'branding/play-store-icon-512.png');
await out(svg(DEFS + SQ + CONTENT + BORDER), 192, WEB + 'icons/Icon-192.png');
await out(svg(DEFS + SQ + CONTENT + BORDER), 512, WEB + 'icons/Icon-512.png');
await out(full, 192, WEB + 'icons/Icon-maskable-192.png');
await out(full, 512, WEB + 'icons/Icon-maskable-512.png');
await out(full.replace(T(FS), T(0.86)), 180, WEB + 'icons/apple-touch-icon.png');
await out(svg(DEFS + SQ + CONTENT), 48, WEB + 'favicon.png');
// Vorschauen
const SC = (process.env.PREVIEW_DIR || process.env.ICON_TOOLS + '/prev') + '/';
fs.mkdirSync(SC, { recursive: true });
await out(master, 1024, SC + 'master.png');
for (const p of [48, 24]) await out(master, p, SC + `s${p}.png`);
const circ = svg(DEFS + `<clipPath id="k"><circle cx="60" cy="60" r="60"/></clipPath><g clip-path="url(#k)">${BG}${T(FS)}</g><circle cx="60" cy="60" r="36.7" fill="none" stroke="red" stroke-width=".5"/>`);
await out(circ, 512, SC + 'adaptive-circle.png');
await out(svg(DEFS + `<rect width="120" height="120" fill="#fff"/>` + monoT.replace('scale(.68)', `scale(${FS})`)), 512, SC + 'mono.png');
await out(svg(DEFS + `<rect width="120" height="120" fill="#fff"/>` + monoT.replace('scale(.68)', `scale(${FS})`)), 512, SC + 'mono.png');
