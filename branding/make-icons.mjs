// Erzeugt branding/icon.svg und alle PNG-Varianten (Android, Web, Play Store). Rezept: CLAUDE.md, Abschnitt "Icon neu erzeugen".
// Grundlage ist das Icon von lx-labs.dev, 1:1 als Bilddatei (branding/lx-labs-icon-512.png, aus lx-labs/public/icon-512.png). Für den Familienhub kommt nur
// etwas hinzu (Dach in den Personenfarben, vier Personenpunkte, Zeile "familyhub"); Schriftzug, Pille, Farben und Glow bleiben unverändert.
// Für adaptive/maskierbare Icons wird das Original in Hintergrund (Verlauf, mathematisch identisch) und Vordergrund (Schriftzug, Pille) getrennt;
// die Gegenprobe (Neuaufbau gegen Original) bricht ab, wenn die Trennung mehr als 8 von 255 je Kanal abweicht.
// Abhängigkeiten NICHT im Repo: in einem Werkzeugordner außerhalb `npm i opentype.js sharp`; Aufruf: ICON_TOOLS=<ordner> node branding/make-icons.mjs
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const req = createRequire(process.env.ICON_TOOLS + '/x.js');
const opentype = req('opentype.js');
const sharp = req('sharp');
const R = fileURLToPath(new URL('../', import.meta.url)).split(String.fromCharCode(92)).join('/');
const N = 512;
const MUTED = '#9AA3B5';
const PERSONEN = ['#38BDF8', '#34D399', '#FBBF24', '#FB7185'];

// --- Ergänzungen (Koordinaten im 512er Raster des Originals) ---
const b = fs.readFileSync(R + 'app/assets/fonts/JetBrainsMono.ttf');
const mono = opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.length));
const ZEILE = 'familyhub', ZSIZE = 24, ZLS = 8, ZADV = 0.6 * ZSIZE; // JetBrains Mono: Vorschub 600/1000
let zx = 256 - (ZEILE.length * ZADV + (ZEILE.length - 1) * ZLS) / 2, zd = '';
for (const ch of ZEILE) { zd += mono.charToGlyph(ch).getPath(zx, 480, ZSIZE, { variation: { wght: 700 } }, mono).toPathData(2); zx += ZADV + ZLS; }
const stops = PERSONEN.map((c, i) => `<stop offset="${i / 3}" stop-color="${c}"/>`).join('');
const dots = [0, 1, 2, 3].map((i) => `<circle cx="${256 + (i - 1.5) * 42}" cy="428" r="12" fill="${PERSONEN[i]}"/>`).join('');
const OVERLAY = `<defs><linearGradient id="rg" x1="72" x2="440" y1="0" y2="0" gradientUnits="userSpaceOnUse">${stops}</linearGradient></defs>`
  + `<path d="M72 126 L256 66 L440 126" fill="none" stroke="url(#rg)" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>`
  + dots + `<path fill="${MUTED}" d="${zd}"/>`;
const svg = (inner, px = N) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${N} ${N}" width="${px}" height="${px}">${inner}</svg>`;

// --- Hintergrund (Verlauf wie lx-labs.dev) ---
const GLOW = `<defs><radialGradient id="glow" cx="35%" cy="30%" r="85%"><stop offset="0" stop-color="#7C3AED" stop-opacity=".85"/><stop offset=".45" stop-color="#00F0FF" stop-opacity=".18"/><stop offset="1" stop-color="#090A0F" stop-opacity="0"/></radialGradient></defs>`;
const BG = svg(GLOW + `<rect width="${N}" height="${N}" fill="#090A0F"/><rect width="${N}" height="${N}" fill="url(#glow)"/>`);
const bgRaw = await sharp(Buffer.from(BG)).resize(N, N).removeAlpha().raw().toBuffer();
const srcRaw = await sharp(R + 'branding/lx-labs-icon-512.png').removeAlpha().resize(N, N).raw().toBuffer();

// --- Vordergrund des Originals entmischen: Pixel = a*F + (1-a)*Hintergrund mit F = Cyan oder Weiß ---
const FARBEN = [[0, 240, 255], [255, 255, 255]];
const fg = Buffer.alloc(N * N * 4);
for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
  const i = (y * N + x) * 3, o = (y * N + x) * 4;
  let best = { a: 0, res: 1e9, c: FARBEN[0] };
  for (const c of FARBEN) {
    let num = 0, den = 0;
    for (let k = 0; k < 3; k++) { const dv = c[k] - bgRaw[i + k]; num += (srcRaw[i + k] - bgRaw[i + k]) * dv; den += dv * dv; }
    const a = Math.max(0, Math.min(1, num / den));
    let res = 0; for (let k = 0; k < 3; k++) { const e = srcRaw[i + k] - (a * c[k] + (1 - a) * bgRaw[i + k]); res += e * e; }
    if (res < best.res) best = { a, res, c };
  }
  if (best.a < 0.02) continue;
  [fg[o], fg[o + 1], fg[o + 2]] = best.c; fg[o + 3] = Math.round(best.a * 255);
  if (best.res > 600) { fg[o] = srcRaw[i]; fg[o + 1] = srcRaw[i + 1]; fg[o + 2] = srcRaw[i + 2]; fg[o + 3] = 255; }
}
// Pille: Innenraum samt dunkler ".dev"-Schrift deckend aus dem Original (Schrift ist fast so dunkel wie der Hintergrund)
let x0 = N, x1 = 0, y0 = N, y1 = 0;
for (let y = 260; y < 410; y++) for (let x = 0; x < N; x++) { const i = (y * N + x) * 3; if (srcRaw[i] < 40 && srcRaw[i + 1] > 200 && srcRaw[i + 2] > 200) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); } }
const pr = (y1 - y0 + 1) / 2, pcy = (y0 + y1 + 1) / 2;
for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
  const px = x + 0.5, cx = Math.min(Math.max(px, x0 + pr), x1 + 1 - pr);
  if (Math.hypot(px - cx, y + 0.5 - pcy) < pr - 1.5) { const i = (y * N + x) * 3, o = (y * N + x) * 4; fg[o] = srcRaw[i]; fg[o + 1] = srcRaw[i + 1]; fg[o + 2] = srcRaw[i + 2]; fg[o + 3] = 255; }
}
const fgPng = await sharp(fg, { raw: { width: N, height: N, channels: 4 } }).png().toBuffer();
const bgPng = await sharp(Buffer.from(BG)).png().toBuffer();
const re = await sharp(bgPng).composite([{ input: fgPng }]).removeAlpha().raw().toBuffer();
let maxAbw = 0; for (let i = 0; i < N * N * 3; i++) maxAbw = Math.max(maxAbw, Math.abs(re[i] - srcRaw[i]));
if (maxAbw > 8) throw new Error('Trennung des Originals weicht ab: ' + maxAbw);
console.log('Trennung Original: größte Abweichung', maxAbw, 'von 255');

// Vordergrund mit Ergänzungen (transparent) und Gesamtbild (randlos)
const overlayPng = await sharp(Buffer.from(svg(OVERLAY))).png().toBuffer();
const fgFull = await sharp(fgPng).composite([{ input: overlayPng }]).png().toBuffer();
const flat = await sharp(bgPng).composite([{ input: fgFull }]).png().toBuffer(); // randlos 512

const px2 = (buf, px) => sharp(buf).resize(px, px, { kernel: 'lanczos3' });
const write = async (img, file) => { fs.mkdirSync(file.replace(/[^/]+$/, ''), { recursive: true }); await img.png().toFile(file); };
// abgerundete Fassung (Quadrat-Icons ohne Systemmaske: Favicon, Web "any", Android < 8): Squircle 22,5 % wie zuvor, Rand #242936
const RX = 0.225 * N;
const maskSvg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${N}" height="${N}"><rect width="${N}" height="${N}" rx="${RX}" fill="#fff"/></svg>`);
const randSvg = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${N}" height="${N}"><rect x="1" y="1" width="${N - 2}" height="${N - 2}" rx="${RX}" fill="none" stroke="#242936" stroke-width="2"/></svg>`);
const rounded = await sharp(await sharp(flat).composite([{ input: maskSvg, blend: 'dest-in' }]).png().toBuffer()).composite([{ input: randSvg }]).png().toBuffer();
// Vordergrund verkleinert in die Mitte eines transparenten Feldes (Safe-Zone) beziehungsweise auf den Hintergrund
const klein = async (buf, canvas, scale) => {
  const s = Math.round(canvas * scale), off = Math.round((canvas - s) / 2);
  const inner = await sharp(buf).resize(s, s, { kernel: 'lanczos3' }).png().toBuffer();
  return sharp({ create: { width: canvas, height: canvas, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).composite([{ input: inner, left: off, top: off }]).png().toBuffer();
};
const mitHintergrund = async (canvas, scale) => sharp(await sharp(Buffer.from(BG)).resize(canvas, canvas).png().toBuffer()).composite([{ input: await klein(fgFull, canvas, scale) }]).png().toBuffer();

const AR = R + 'app/android/app/src/main/res/';
const WEB = R + 'app/web/';
const ADAPTIV = 0.68, MASKABLE = 0.74; // Vordergrund in der Safe-Zone (Kreis 61 % beziehungsweise 80 %)
const dens = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
const kreis = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${N}" height="${N}"><circle cx="${N / 2}" cy="${N / 2}" r="${N / 2}" fill="#fff"/></svg>`);
const rund = await sharp(await mitHintergrund(N, 0.7)).composite([{ input: kreis, blend: 'dest-in' }]).png().toBuffer();
for (const [k, px] of Object.entries(dens)) {
  await write(px2(rounded, px), `${AR}mipmap-${k}/ic_launcher.png`);
  await write(px2(rund, px), `${AR}mipmap-${k}/ic_launcher_round.png`);
}
await write(sharp(Buffer.from(BG)).resize(432, 432), `${AR}drawable-nodpi/ic_launcher_background.png`);
const fg432 = await klein(fgFull, 432, ADAPTIV);
await write(sharp(fg432), `${AR}drawable-nodpi/ic_launcher_foreground.png`);
// Monochrom: einfarbige Silhouette; die dunkle ".dev"-Schrift der Pille wird ausgestanzt
const m = await sharp(fg432).raw().toBuffer();
const mb = Buffer.alloc(432 * 432 * 4);
for (let i = 0; i < 432 * 432; i++) {
  const lum = (m[i * 4] + m[i * 4 + 1] + m[i * 4 + 2]) / 3;
  mb[i * 4 + 3] = Math.round(m[i * 4 + 3] * Math.min(1, Math.max(0, (lum - 40) / 120))); // dunkel -> durchsichtig, Farbe bleibt schwarz
}
const monoPng = await sharp(mb, { raw: { width: 432, height: 432, channels: 4 } }).png().toBuffer();
await write(sharp(monoPng), `${AR}drawable-nodpi/ic_launcher_monochrome.png`);
await write(px2(flat, 512), R + 'branding/play-store-icon-512.png');
await write(px2(rounded, 192), WEB + 'icons/Icon-192.png');
await write(px2(rounded, 512), WEB + 'icons/Icon-512.png');
const maskable = await mitHintergrund(N, MASKABLE);
await write(px2(maskable, 192), WEB + 'icons/Icon-maskable-192.png');
await write(px2(maskable, 512), WEB + 'icons/Icon-maskable-512.png');
await write(px2(flat, 180), WEB + 'icons/apple-touch-icon.png'); // randlos, iOS rundet selbst
await write(px2(rounded, 48), WEB + 'favicon.png');

// Master als SVG: Original als Bild, Ergänzungen als Vektor darüber
const dataUri = 'data:image/png;base64,' + fs.readFileSync(R + 'branding/lx-labs-icon-512.png').toString('base64');
fs.writeFileSync(R + 'branding/icon.svg', `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${N} ${N}" width="${N}" height="${N}">\n<image href="${dataUri}" width="${N}" height="${N}"/>${OVERLAY}</svg>\n`);

// Vorschauen
const SC = (process.env.PREVIEW_DIR || process.env.ICON_TOOLS + '/prev') + '/';
fs.mkdirSync(SC, { recursive: true });
await write(px2(rounded, 512), SC + 'master.png');
for (const p of [48, 24]) await write(px2(rounded, p), SC + `s${p}.png`);
const adaptivBild = await mitHintergrund(N, ADAPTIV);
await write(sharp(await sharp(adaptivBild).composite([{ input: kreis, blend: 'dest-in' }]).png().toBuffer()), SC + 'adaptive-circle.png');
await write(sharp(await sharp(adaptivBild).composite([{ input: maskSvg, blend: 'dest-in' }]).png().toBuffer()), SC + 'adaptive-squircle.png');
await write(sharp({ create: { width: 432, height: 432, channels: 4, background: '#fff' } }).composite([{ input: monoPng }]), SC + 'mono.png');
