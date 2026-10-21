// Erzeugt app/lib/data/crypto/nfkc_tabelle.dart: Tabellen der vollständigen Unicode-Normalisierung NFKC (Zerlegung, Kombinationsklassen, Komposition).
// Quelle: Unicode Character Database 16.0.0 (https://www.unicode.org/Public/16.0.0/ucd/): UnicodeData.txt, DerivedNormalizationProps.txt (Full_Composition_Exclusion).
// Aufruf: node app/tool/gen_nfkc.mjs <Ordner mit den UCD-Dateien> > app/lib/data/crypto/nfkc_tabelle.dart
// Hangul-Silben werden nicht tabelliert (algorithmisch, nfkc.dart). Prüfung: app/test/crypto/nfkc_test.dart gegen NormalizationTest.txt (selbe Version).
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
const version = '16.0.0';
const lines = fs.readFileSync(path.join(dir, 'UnicodeData.txt'), 'utf8').split('\n').filter((l) => l.trim());
const decomp = new Map(); // cp -> { compat, cps }
const ccc = new Map();
for (const l of lines) {
  const f = l.split(';');
  const cp = parseInt(f[0], 16);
  const c = parseInt(f[3], 10);
  if (c !== 0) ccc.set(cp, c);
  if (f[5]) {
    const compat = f[5].startsWith('<');
    const cps = f[5].replace(/<[^>]*>\s*/, '').split(' ').map((x) => parseInt(x, 16));
    decomp.set(cp, { compat, cps });
  }
}
const fce = new Set();
for (const l of fs.readFileSync(path.join(dir, 'DerivedNormalizationProps.txt'), 'utf8').split('\n')) {
  const m = l.match(/^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*Full_Composition_Exclusion/);
  if (!m) continue;
  const a = parseInt(m[1], 16), b = m[2] ? parseInt(m[2], 16) : a;
  for (let c = a; c <= b; c++) fce.add(c);
}
const isHangulSyl = (c) => c >= 0xac00 && c <= 0xd7a3;
const full = (cp) => {
  const d = decomp.get(cp);
  if (!d || isHangulSyl(cp)) return [cp];
  return d.cps.flatMap(full);
};
const nfkd = new Map();
for (const cp of decomp.keys()) if (!isHangulSyl(cp)) nfkd.set(cp, full(cp));
const pairs = [];
for (const [cp, d] of decomp) {
  if (d.compat || d.cps.length !== 2 || fce.has(cp)) continue;
  pairs.push([d.cps[0], d.cps[1], cp]);
}
const hex = (n) => '0x' + n.toString(16);
let out = `// ERZEUGT von app/tool/gen_nfkc.mjs aus der Unicode Character Database ${version} - nicht von Hand ändern (neue Version = neues Passwort-Profil, siehe nfkc.dart).
// ${nfkd.size} Zerlegungen, ${ccc.size} Kombinationsklassen, ${pairs.length} Kompositionen.

/// Version der Unicode-Daten.
const String kUnicodeVersion = '${version}';

/// Vollständige Kompatibilitätszerlegung (NFKD) je Codepunkt (ohne Hangul-Silben, die rechnet nfkc.dart).
const Map<int, List<int>> kNfkdZerlegung = {
`;
for (const [c, d] of [...nfkd].sort((a, b) => a[0] - b[0])) out += `  ${hex(c)}: [${d.map(hex).join(',')}],\n`;
out += `};\n\n/// Canonical Combining Class (nur Werte ungleich 0).\nconst Map<int, int> kKombinationsklasse = {\n`;
for (const [c, v] of [...ccc].sort((a, b) => a[0] - b[0])) out += `  ${hex(c)}: ${v},\n`;
out += `};\n\n/// Primäre Komposition: (erstes Zeichen << 21) | zweites Zeichen -> zusammengesetztes Zeichen (ohne Ausschlüsse, ohne Hangul).\nconst Map<int, int> kNfcKomposition = {\n`;
for (const [a, b, c] of pairs.sort((x, y) => x[2] - y[2])) out += `  ${hex(a * 2097152 + b)}: ${hex(c)},\n`;
out += '};\n';
process.stdout.write(out);
