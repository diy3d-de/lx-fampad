// Blockverschlüsselung der Dateiablage (STREAM, AES-256-GCM): Known-Answer-Tests, Manipulation, Reihenfolge, Kürzen; dazu Namens-, Typ- und Range-Regeln (rein).
import { createCipheriv, createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { afterAll, describe, expect, it } from 'vitest';
import { KeyRing } from '../src/auth/crypto.js';
import {
  BLOCK_SIZE,
  blockAad,
  blockNonce,
  decryptBlock,
  decryptRange,
  encryptBlock,
  encryptedSize,
  encryptFile,
  HEADER_SIZE,
  header,
  TAG_SIZE,
  unwrapKey,
  wrapKey,
  type BlobKey,
} from '../src/files/crypto.js';
import { cleanMime, cleanName, contentDisposition, decideMime, parseRange, sniffMime } from '../src/files/names.js';

const dir = mkdtempSync(`${tmpdir()}/lx-fcrypto-`);
afterAll(() => rmSync(dir, { recursive: true, force: true }));

// feste Eingaben für die Known-Answer-Tests (muss bei jeder Formatänderung bewusst angepasst werden)
const BLOB = '11111111-2222-4333-8444-555555555555';
const KEY: BlobKey = { dek: Buffer.alloc(32, 0x42), prefix: Buffer.from('01020304050607', 'hex') };

async function collect(it: AsyncGenerator<Buffer>): Promise<Buffer> {
  const parts: Buffer[] = [];
  for await (const p of it) parts.push(p);
  return Buffer.concat(parts);
}

describe('Blockverschlüsselung: Format und Known-Answer', () => {
  it('Kopf, Nonce und AAD sind exakt festgelegt', () => {
    expect(header(KEY.prefix).toString('hex')).toBe('4c58463100010000' + '01020304050607' + '00');
    expect(blockNonce(KEY.prefix, 0, false).toString('hex')).toBe('01020304050607' + '00000000' + '00');
    expect(blockNonce(KEY.prefix, 258, true).toString('hex')).toBe('01020304050607' + '00000102' + '01');
    expect(blockAad(BLOB).toString('hex')).toBe('6c786631' + '11111111222243338444555555555555' + '00010000');
  });

  it('ein Block entspricht einer unabhängig gebauten AES-256-GCM-Verschlüsselung (Known-Answer)', () => {
    const plain = Buffer.from('Hallo Familie');
    const c = createCipheriv('aes-256-gcm', KEY.dek, Buffer.from('01020304050607' + '00000000' + '01', 'hex'));
    c.setAAD(Buffer.from('6c786631' + '11111111222243338444555555555555' + '00010000', 'hex'));
    const erwartet = Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
    expect(encryptBlock(KEY, BLOB, 0, true, plain).equals(erwartet)).toBe(true);
    // fester Wert: Änderungen am Format fallen hier sofort auf
    expect(encryptBlock(KEY, BLOB, 0, true, plain).toString('hex')).toBe(KAT_BLOCK);
    expect(decryptBlock(KEY, BLOB, 0, true, erwartet).toString()).toBe('Hallo Familie');
  });

  it('Größe auf dem Datenträger: Kopf + Inhalt + ein Tag je Block (mindestens ein Block, auch leer)', () => {
    expect(encryptedSize(0)).toBe(HEADER_SIZE + TAG_SIZE);
    expect(encryptedSize(1)).toBe(HEADER_SIZE + 1 + TAG_SIZE);
    expect(encryptedSize(BLOCK_SIZE)).toBe(HEADER_SIZE + BLOCK_SIZE + TAG_SIZE);
    expect(encryptedSize(BLOCK_SIZE + 1)).toBe(HEADER_SIZE + BLOCK_SIZE + 1 + 2 * TAG_SIZE);
  });
});

describe('Blockverschlüsselung: Manipulation wird erkannt', () => {
  const plain = Buffer.alloc(BLOCK_SIZE * 2 + 100, 0x61);
  const src = `${dir}/klar.bin`;
  writeFileSync(src, plain);
  const enc = `${dir}/klar.enc`;
  let blob: Buffer;

  it('Rundlauf über mehrere Blöcke (volle Blöcke, Rest, genau ein Vielfaches, leer)', async () => {
    const hash = await encryptFile(src, enc, KEY, BLOB, plain.length);
    expect(hash).toBe(createHash('sha256').update(plain).digest('hex'));
    blob = readFileSync(enc);
    expect(blob.length).toBe(encryptedSize(plain.length));
    expect(blob.subarray(0, HEADER_SIZE).equals(header(KEY.prefix))).toBe(true);
    expect((await collect(decryptRange(enc, KEY, BLOB, plain.length, 0, plain.length - 1))).equals(plain)).toBe(true);
    for (const n of [0, 1, BLOCK_SIZE, BLOCK_SIZE * 2]) {
      const s = `${dir}/n${n}.bin`;
      const e = `${dir}/n${n}.enc`;
      writeFileSync(s, Buffer.alloc(n, 7));
      await encryptFile(s, e, KEY, BLOB, n);
      expect(readFileSync(e).length).toBe(encryptedSize(n));
      expect((await collect(decryptRange(e, KEY, BLOB, n, 0, n - 1))).length).toBe(n);
    }
  });

  it('Bereiche über Blockgrenzen', async () => {
    const mid = await collect(decryptRange(enc, KEY, BLOB, plain.length, BLOCK_SIZE - 3, BLOCK_SIZE + 3));
    expect(mid.length).toBe(7);
    expect((await collect(decryptRange(enc, KEY, BLOB, plain.length, plain.length - 1, plain.length - 1))).length).toBe(1);
  });

  it('ein verändertes Byte in einem Block bricht das Lesen dieses Blocks (und nur dort)', async () => {
    const bad = Buffer.from(blob);
    bad[HEADER_SIZE + 5] = (bad[HEADER_SIZE + 5] ?? 0) ^ 0x01;
    writeFileSync(`${dir}/bad1.enc`, bad);
    await expect(collect(decryptRange(`${dir}/bad1.enc`, KEY, BLOB, plain.length, 0, 10))).rejects.toThrow();
    // der zweite Block ist unberührt lesbar
    expect((await collect(decryptRange(`${dir}/bad1.enc`, KEY, BLOB, plain.length, BLOCK_SIZE, BLOCK_SIZE + 9))).length).toBe(10);
  });

  it('vertauschte Blöcke werden erkannt (die Blocknummer steckt in der Nonce)', async () => {
    const bs = BLOCK_SIZE + TAG_SIZE;
    const swapped = Buffer.concat([blob.subarray(0, HEADER_SIZE), blob.subarray(HEADER_SIZE + bs, HEADER_SIZE + 2 * bs), blob.subarray(HEADER_SIZE, HEADER_SIZE + bs), blob.subarray(HEADER_SIZE + 2 * bs)]);
    writeFileSync(`${dir}/swap.enc`, swapped);
    await expect(collect(decryptRange(`${dir}/swap.enc`, KEY, BLOB, plain.length, 0, 9))).rejects.toThrow();
  });

  it('ein abgeschnittener Blob wird erkannt (der letzte Block trägt das Endkennzeichen)', async () => {
    // ohne den letzten Block: der Rest endet an einer Blockgrenze, die Größe aus der Datenbank passt nicht mehr, der "letzte" Block ist nicht als letzter gekennzeichnet
    const bs = BLOCK_SIZE + TAG_SIZE;
    writeFileSync(`${dir}/cut.enc`, blob.subarray(0, HEADER_SIZE + 2 * bs));
    await expect(collect(decryptRange(`${dir}/cut.enc`, KEY, BLOB, 2 * BLOCK_SIZE, 0, 2 * BLOCK_SIZE - 1))).rejects.toThrow();
    // zu kurze Datei
    writeFileSync(`${dir}/short.enc`, blob.subarray(0, HEADER_SIZE + 100));
    await expect(collect(decryptRange(`${dir}/short.enc`, KEY, BLOB, plain.length, 0, 5))).rejects.toThrow();
  });

  it('ein Block aus einem anderen Blob oder mit anderem Schlüssel passt nicht', async () => {
    await expect(collect(decryptRange(enc, KEY, '99999999-2222-4333-8444-555555555555', plain.length, 0, 5))).rejects.toThrow();
    await expect(collect(decryptRange(enc, { ...KEY, dek: Buffer.alloc(32, 1) }, BLOB, plain.length, 0, 5))).rejects.toThrow();
    // falscher Kopf (Präfix)
    await expect(collect(decryptRange(enc, { ...KEY, prefix: Buffer.alloc(7, 9) }, BLOB, plain.length, 0, 5))).rejects.toThrow();
  });
});

describe('Verpacken des Dateischlüssels', () => {
  const keys = new KeyRing(Buffer.alloc(32, 5));
  it('Rundlauf; gebunden an Blob und Schlüsselnummer; anderer Hauptschlüssel scheitert', () => {
    const w = wrapKey(keys, BLOB, KEY, 1);
    expect(w.length).toBe(67);
    const k = unwrapKey(keys, BLOB, w, 1);
    expect(k.dek.equals(KEY.dek) && k.prefix.equals(KEY.prefix)).toBe(true);
    expect(() => unwrapKey(keys, '99999999-2222-4333-8444-555555555555', w, 1)).toThrow();
    expect(() => unwrapKey(keys, BLOB, w, 2)).toThrow();
    expect(() => unwrapKey(new KeyRing(Buffer.alloc(32, 6)), BLOB, w, 1)).toThrow();
    const bad = Buffer.from(w);
    bad[20] = (bad[20] ?? 0) ^ 1;
    expect(() => unwrapKey(keys, BLOB, bad, 1)).toThrow();
    // zwei Verpackungen desselben Schlüssels sind verschieden (Zufalls-Nonce)
    expect(wrapKey(keys, BLOB, KEY, 1).equals(w)).toBe(false);
  });
  it('der Ableitungsschlüssel ist ein eigener Zweck (Known-Answer der Ableitung)', () => {
    expect(keys.derive('files/wrap/v1').toString('hex')).toBe(KAT_WRAP_KEY);
    expect(keys.derive('files/wrap/v1').equals(keys.derive('files/wrap/v2'))).toBe(false);
  });
});

describe('Namen (rein)', () => {
  it.each([
    ['Foto.jpg', 'Foto.jpg'],
    ['  Urlaub 2026  ', 'Urlaub 2026'],
    ['A\u0000B', null],
    ['a/b', null],
    ['a\\b', null],
    ['..', null],
    ['.', null],
    ['', null],
    ['   ', null],
    ['name.', null],
    ['CON', null],
    ['con.txt', null],
    ['NUL.tar.gz', null],
    ['LPT1', null],
    ['COM9.log', null],
    ['console.txt', 'console.txt'],
    ['rechnung‮txt.exe', 'rechnungtxt.exe'],
    ['a⁦b⁩c', 'abc'],
    ['tab\tname', 'tabname'],
    ['zero​width', 'zerowidth'],
    ['é', 'é'],
  ] as const)('%j -> %j', (roh, erwartet) => {
    expect(cleanName(roh)).toBe(erwartet);
  });
  it('Länge: 200 Zeichen ja, 201 nein; 255 Byte (Mehrbyte-Zeichen) nein', () => {
    expect(cleanName('a'.repeat(200))).toBe('a'.repeat(200));
    expect(cleanName('a'.repeat(201))).toBeNull();
    expect(cleanName('ä'.repeat(128))).toBeNull(); // 256 Byte
    expect(cleanName('ä'.repeat(127))).not.toBeNull(); // 254 Byte
  });
  it('Content-Disposition: Anhang mit ASCII-Rückfall und UTF-8-Name, keine Einschleusung', () => {
    const d = contentDisposition('Größe "x".pdf');
    expect(d).toBe('attachment; filename="Gr__e _x_.pdf"; filename*=UTF-8\'\'Gr%C3%B6%C3%9Fe%20%22x%22.pdf');
    expect(contentDisposition('v.png', true).startsWith('inline;')).toBe(true);
    expect(d).not.toMatch(/[\r\n]/);
  });
});

describe('Typen (rein)', () => {
  it('cleanMime', () => {
    expect(cleanMime(' Image/PNG ')).toBe('image/png');
    expect(cleanMime('application/vnd.ms-excel')).toBe('application/vnd.ms-excel');
    for (const bad of ['text', 'text/html; charset=utf-8', 'a/b/c', '/x', 'x/', 'te xt/plain', '']) expect(cleanMime(bad), bad).toBeNull();
  });
  it('Magic-Bytes', () => {
    expect(sniffMime(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]))).toBe('image/png');
    expect(sniffMime(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe('image/jpeg');
    expect(sniffMime(Buffer.from('GIF89a....'))).toBe('image/gif');
    expect(sniffMime(Buffer.from('%PDF-1.4'))).toBe('application/pdf');
    expect(sniffMime(Buffer.from('PK\u0003\u0004xx', 'latin1'))).toBe('application/zip');
    expect(sniffMime(Buffer.from('....ftypheic....'))).toBe('image/heic');
    expect(sniffMime(Buffer.from('....ftypisom....'))).toBe('video/mp4');
    expect(sniffMime(Buffer.from('hallo'))).toBeNull();
  });
  it('decideMime: Bild und PDF müssen zu den Magic-Bytes passen, sonst gilt die Angabe als Anzeige', () => {
    const pngHead = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]);
    const pdfHead = Buffer.from('%PDF-1.4');
    expect(decideMime('image/png', pngHead)).toBe('image/png');
    expect(decideMime('image/jpeg', pngHead)).toBeNull();
    expect(decideMime('image/png', Buffer.from('kein bild'))).toBeNull();
    expect(decideMime('application/pdf', pdfHead)).toBe('application/pdf');
    expect(decideMime('application/pdf', pngHead)).toBeNull();
    expect(decideMime('application/octet-stream', pngHead)).toBe('image/png');
    expect(decideMime(null, pdfHead)).toBe('application/pdf');
    expect(decideMime(null, Buffer.from('xyz'))).toBe('application/octet-stream');
    expect(decideMime('text/plain', Buffer.from('xyz'))).toBe('text/plain');
    expect(decideMime('image/svg+xml', Buffer.from('<svg/>'))).toBe('image/svg+xml');
    expect(decideMime('application/vnd.openxmlformats-officedocument.wordprocessingml.document', Buffer.from('PK\u0003\u0004', 'latin1'))).toBe('application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    expect(decideMime('image/heif', Buffer.from('....ftypheic'))).toBe('image/heif');
  });
});

describe('Range (rein)', () => {
  it.each([
    [undefined, 100, { kind: 'none' }],
    ['bytes=0-0', 100, { kind: 'range', start: 0, end: 0 }],
    ['bytes=0-99', 100, { kind: 'range', start: 0, end: 99 }],
    ['bytes=10-', 100, { kind: 'range', start: 10, end: 99 }],
    ['bytes=90-500', 100, { kind: 'range', start: 90, end: 99 }],
    ['bytes=-10', 100, { kind: 'range', start: 90, end: 99 }],
    ['bytes=-500', 100, { kind: 'range', start: 0, end: 99 }],
    ['bytes=99-99', 100, { kind: 'range', start: 99, end: 99 }],
    ['bytes=100-', 100, { kind: 'unsatisfiable' }],
    ['bytes=100-100', 100, { kind: 'unsatisfiable' }],
    ['bytes=5-2', 100, { kind: 'unsatisfiable' }],
    ['bytes=-0', 100, { kind: 'unsatisfiable' }],
    ['bytes=-', 100, { kind: 'unsatisfiable' }],
    ['bytes=0-1,5-6', 100, { kind: 'unsatisfiable' }],
    ['bytes=a-b', 100, { kind: 'unsatisfiable' }],
    ['items=0-1', 100, { kind: 'unsatisfiable' }],
    ['bytes=0-0', 0, { kind: 'unsatisfiable' }],
    ['bytes=0-9999999999999999', 100, { kind: 'unsatisfiable' }],
  ] as const)('%j bei Größe %j', (kopf, groesse, erwartet) => {
    expect(parseRange(kopf, groesse)).toEqual(erwartet);
  });
});

// Werte, die einmal aus der Umsetzung berechnet und gegen die unabhängige node:crypto-Berechnung oben geprüft wurden
const KAT_BLOCK = '4bfcc5f3327590cd1789f36fe771c8267eebfe9d9dffb6617268d2c495';
const KAT_WRAP_KEY = '8fad30192d9deab93207093712636f3f901e67370f5f780691009602a491ff6b';
