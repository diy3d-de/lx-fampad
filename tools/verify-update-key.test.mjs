// Test: node --test "tools/*.test.mjs"
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { test } from 'node:test';
import { rawPublicKey } from './update-manifest.mjs';
import { checkKey, readKeyConstants } from './verify-update-key.mjs';

const a = generateKeyPairSync('ed25519');
const b = generateKeyPairSync('ed25519');
const pemA = a.privateKey.export({ format: 'pem', type: 'pkcs8' });
const pubA = rawPublicKey(a.publicKey).toString('base64');
const quelle = (id, pub) => `const kUpdatePublicKey = '${pub}';\nconst kUpdateKeyId = ${id};\n`;

test('akzeptiert passenden Schlüssel mit echter ID', () => {
  assert.equal(checkKey(quelle("'fampad-2026-1'", pubA), pemA), 'fampad-2026-1');
});

test('lehnt den Platzhalter ab (Verweis und Textwert)', () => {
  assert.throws(() => checkKey(quelle('kPlatzhalterKeyId', pubA), pemA), /kein Textwert/);
  assert.throws(() => checkKey(quelle("'platzhalter'", pubA), pemA), /Platzhalter/);
});

test('lehnt einen nicht passenden öffentlichen Schlüssel ab', () => {
  const pubB = rawPublicKey(b.publicKey).toString('base64');
  assert.throws(() => checkKey(quelle("'x1'", pubB), pemA), /passt nicht/);
});

test('lehnt fehlenden privaten Schlüssel und fehlende Konstanten ab', () => {
  assert.throws(() => checkKey(quelle("'x1'", pubA), undefined), /fehlt/);
  assert.deepEqual(readKeyConstants('nichts'), { keyId: null, publicKey: null });
});

test('liest die echte constants.dart (derzeit Platzhalter)', async () => {
  const { readFileSync } = await import('node:fs');
  const src = readFileSync(new URL('../app/lib/constants.dart', import.meta.url), 'utf8');
  assert.ok(readKeyConstants(src).publicKey, 'kUpdatePublicKey muss gefunden werden');
});
