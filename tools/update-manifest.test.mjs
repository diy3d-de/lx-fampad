// Test: node --test "tools/*.test.mjs"
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { test } from 'node:test';
import { buildPayload, rawPublicKey, signPayload, verifyManifest } from './update-manifest.mjs';

// Testschlüssel nur für diesen Test, erzeugt bei jedem Lauf
const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const pem = privateKey.export({ format: 'pem', type: 'pkcs8' });
const pub = rawPublicKey(publicKey).toString('base64');

const basis = {
  apkBytes: Buffer.from('apk-inhalt'),
  apkName: 'lx-familienzentrale-0.2.0.apk',
  version: '0.2.0',
  versionCode: 2,
  minVersion: '0.1.0',
  notes: 'Neu',
  packageName: 'dev.lx_labs.familienzentrale',
  keyId: 'test',
  issuedAt: '2026-10-18T12:00:00Z',
};

test('signiert und prüft genau den Payload-Text', () => {
  const manifest = signPayload(buildPayload(basis), pem);
  assert.ok(verifyManifest(manifest, pub));
  const payload = JSON.parse(manifest.payload);
  assert.equal(payload.sha256.length, 64);
  assert.equal(payload.size, 10);
  assert.equal(payload.issuedAt, '2026-10-18T12:00:00.000Z');
  assert.equal(Buffer.from(manifest.signature, 'base64').length, 64);
});

test('lehnt veränderten Payload und fremden Schlüssel ab', () => {
  const manifest = signPayload(buildPayload(basis), pem);
  assert.equal(verifyManifest({ ...manifest, payload: manifest.payload.replace('0.2.0', '9.9.9') }, pub), false);
  const other = generateKeyPairSync('ed25519').publicKey;
  assert.equal(verifyManifest(manifest, rawPublicKey(other).toString('base64')), false);
});

test('lehnt ungültige Eingaben ab', () => {
  assert.throws(() => buildPayload({ ...basis, version: '1.2' }), /version/);
  assert.throws(() => buildPayload({ ...basis, versionCode: 0 }), /version-code/);
  assert.throws(() => buildPayload({ ...basis, apkName: '../x.apk' }), /Dateiname/);
  assert.throws(() => buildPayload({ ...basis, apkBytes: Buffer.alloc(0) }), /Größe/);
});

test('lehnt Schlüssel anderer Art ab', () => {
  const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ format: 'pem', type: 'pkcs8' });
  assert.throws(() => signPayload(buildPayload(basis), rsa), /Ed25519/);
});
