// Erzeugt app/lib/data/crypto/nfkc_tabelle.dart: eingeschränkte NFKC-Normalisierung für Passwörter (kein neues Paket).
// Aufruf: node tools/gen-nfkc.mjs > app/lib/data/crypto/nfkc_tabelle.dart
// Bereiche: Latin (U+00A0-U+024F, U+1E00-U+1EFF), Interpunktion/Leerzeichen (U+2000-U+2070), Ligaturen (U+FB00-U+FB06), Voll-/Halbbreite (U+FF00-U+FFEF).
const bereiche = [[0xa0, 0x24f], [0x1e00, 0x1eff], [0x2000, 0x2070], [0xfb00, 0xfb06], [0xff00, 0xffef]];
const alle = [];
for (const [a, b] of bereiche) for (let c = a; c <= b; c++) alle.push(c);
const cps = (s) => [...s].map((ch) => ch.codePointAt(0));
const zerlegung = new Map();
for (const c of alle) {
  const ch = String.fromCodePoint(c);
  const d = ch.normalize('NFKD');
  if (d !== ch) zerlegung.set(c, cps(d));
}
// Basis-Zeichen, die als Starter einer Komposition vorkommen: alle Zeichen, die nach NFKD unverändert sind (inkl. ASCII), plus bereits zusammengesetzte (für ü + Makron).
const basen = [...new Set([...[...Array(0x7f).keys()].filter((c) => c >= 0x20), ...alle])];
const paare = [];
for (const b of basen) {
  for (let m = 0x300; m <= 0x36f; m++) {
    const n = (String.fromCodePoint(b) + String.fromCodePoint(m)).normalize('NFC');
    const k = cps(n);
    if (k.length === 1 && k[0] !== b) paare.push([b, m, k[0]]);
  }
}
const hex = (n) => '0x' + n.toString(16);
let out = `// ERZEUGT von tools/gen-nfkc.mjs (Node ${process.version}, Unicode-Daten der JS-Engine) - nicht von Hand ändern.
// Tabellen für die eingeschränkte NFKC-Normalisierung von Passwörtern (nfkc.dart). ${zerlegung.size} Zerlegungen, ${paare.length} Kompositionen.

/// Kompatibilitäts- und kanonische Zerlegung (NFKD) je Codepunkt.
const Map<int, List<int>> kNfkdZerlegung = {
`;
for (const [c, d] of zerlegung) out += `  ${hex(c)}: [${d.map(hex).join(', ')}],\n`;
out += `};\n\n/// Kanonische Komposition: (Basis << 16) | Akzent -> zusammengesetzter Codepunkt.\nconst Map<int, int> kNfcKomposition = {\n`;
for (const [b, m, c] of paare) out += `  ${hex((b << 16) | m)}: ${hex(c)},\n`;
out += '};\n';
process.stdout.write(out);
