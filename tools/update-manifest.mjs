#!/usr/bin/env node
// Signiert das Update-Manifest (latest.json) des Android-Update-Kanals mit Ed25519 (node:crypto, keine Abhängigkeiten).
//
//   node tools/update-manifest.mjs keygen <datei.pem>
//       Erzeugt ein Schlüsselpaar. Der private Schlüssel (PEM) wird NUR in <datei.pem> geschrieben (nie ins Repo!),
//       der öffentliche Schlüssel (Base64, 32 Byte) wird ausgegeben und gehört nach app/lib/constants.dart
//       (kUpdatePublicKey, dazu kUpdateKeyId).
//
//   node tools/update-manifest.mjs sign --apk <datei.apk> --version 0.2.0 --version-code 2 --key-id <id> \
//        [--min-version 0.1.0] [--notes "Text"] [--package-name dev.lx_labs.fampad] \
//        [--issued-at 2026-10-18T12:00:00Z] [--key-file <datei.pem> | Umgebungsvariable UPDATE_SIGNING_KEY] --out latest.json
//       Schreibt latest.json: { "payload": "<JSON-Text>", "signature": "<Base64, 64 Byte>" }.
//       Signiert wird genau der Text in "payload" (UTF-8). Die App prüft diesen Text unverändert.
//
// In der CI liegt der private Schlüssel als Secret UPDATE_SIGNING_KEY (PEM-Text) vor; er wird nie ausgegeben.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

export const DEFAULT_PACKAGE_NAME = 'dev.lx_labs.fampad';
export const MAX_APK_BYTES = 200 * 1024 * 1024;

/** Rohschlüssel (32 Byte) eines Ed25519-Public-Keys. */
export function rawPublicKey(publicKey) {
  const der = publicKey.export({ format: 'der', type: 'spki' });
  return der.subarray(der.length - 32);
}

/** Baut den Payload-Text. Die Feldreihenfolge ist fest; die App liest den Text nur, sie baut ihn nie nach. */
export function buildPayload({ apkBytes, apkName, version, versionCode, minVersion, notes, packageName, keyId, issuedAt }) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`version ungültig: ${version}`);
  if (!/^\d+\.\d+\.\d+$/.test(minVersion)) throw new Error(`min-version ungültig: ${minVersion}`);
  if (!Number.isInteger(versionCode) || versionCode < 1) throw new Error('version-code muss eine ganze Zahl >= 1 sein');
  if (!/^[A-Za-z0-9._-]+\.apk$/.test(apkName)) throw new Error(`Dateiname ungültig (nur A-Z a-z 0-9 . _ -, Endung .apk): ${apkName}`);
  if (apkBytes.length < 1 || apkBytes.length > MAX_APK_BYTES) throw new Error('APK-Größe außerhalb von 1 Byte bis 200 MB');
  if (!keyId) throw new Error('key-id fehlt');
  if (Number.isNaN(Date.parse(issuedAt))) throw new Error(`issued-at ungültig: ${issuedAt}`);
  return JSON.stringify({
    packageName,
    version,
    versionCode,
    minVersion,
    apk: apkName,
    sha256: createHash('sha256').update(apkBytes).digest('hex'),
    size: apkBytes.length,
    notes,
    issuedAt: new Date(issuedAt).toISOString(),
    keyId,
  });
}

/** Signiert [payload] (String) und liefert das Manifest-Objekt. */
export function signPayload(payload, privateKeyPem) {
  const key = createPrivateKey(privateKeyPem);
  if (key.asymmetricKeyType !== 'ed25519') throw new Error('Der Schlüssel ist kein Ed25519-Schlüssel');
  const signature = sign(null, Buffer.from(payload, 'utf8'), key).toString('base64');
  return { payload, signature };
}

/** Prüft ein Manifest gegen einen öffentlichen Rohschlüssel (Base64) - wie die App. */
export function verifyManifest(manifest, publicKeyBase64) {
  const raw = Buffer.from(publicKeyBase64, 'base64');
  if (raw.length !== 32) return false;
  // SPKI-Präfix für Ed25519 + 32 Byte Rohschlüssel
  const der = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]);
  const key = createPublicKey({ key: der, format: 'der', type: 'spki' });
  const sig = Buffer.from(manifest.signature, 'base64');
  return sig.length === 64 && verify(null, Buffer.from(manifest.payload, 'utf8'), key, sig);
}

function fail(message) {
  console.error(`Fehler: ${message}`);
  process.exit(1);
}

function main(argv) {
  const [command, ...rest] = argv;
  if (command === 'keygen') {
    const target = rest[0];
    if (!target) fail('Aufruf: keygen <datei.pem> (Ablage außerhalb des Repositories!)');
    const repoRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
    if (resolve(target).startsWith(repoRoot)) fail('Der private Schlüssel darf nicht im Repository liegen. Anderen Pfad wählen.');
    if (existsSync(target)) fail(`${target} existiert schon, wird nicht überschrieben`);
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    writeFileSync(target, privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });
    console.log(`Privater Schlüssel geschrieben nach ${target} (sicher aufbewahren, als CI-Secret UPDATE_SIGNING_KEY hinterlegen).`);
    console.log(`Öffentlicher Schlüssel (kUpdatePublicKey): ${rawPublicKey(publicKey).toString('base64')}`);
    return;
  }
  if (command === 'sign') {
    const { values } = parseArgs({
      args: rest,
      options: {
        apk: { type: 'string' },
        version: { type: 'string' },
        'version-code': { type: 'string' },
        'min-version': { type: 'string', default: '0.0.0' },
        notes: { type: 'string', default: '' },
        'package-name': { type: 'string', default: DEFAULT_PACKAGE_NAME },
        'key-id': { type: 'string' },
        'issued-at': { type: 'string' },
        'key-file': { type: 'string' },
        out: { type: 'string' },
      },
    });
    for (const k of ['apk', 'version', 'version-code', 'key-id', 'out']) if (!values[k]) fail(`--${k} fehlt`);
    const pem = values['key-file'] ? readFileSync(values['key-file'], 'utf8') : process.env.UPDATE_SIGNING_KEY;
    if (!pem) fail('Schlüssel fehlt: --key-file oder Umgebungsvariable UPDATE_SIGNING_KEY');
    if (!statSync(values.apk).isFile()) fail(`${values.apk} ist keine Datei`);
    const payload = buildPayload({
      apkBytes: readFileSync(values.apk),
      apkName: basename(values.apk),
      version: values.version,
      versionCode: Number(values['version-code']),
      minVersion: values['min-version'],
      notes: values.notes,
      packageName: values['package-name'],
      keyId: values['key-id'],
      issuedAt: values['issued-at'] ?? new Date().toISOString(),
    });
    writeFileSync(values.out, JSON.stringify(signPayload(payload, pem)) + '\n');
    console.log(`Manifest geschrieben: ${values.out}`);
    return;
  }
  fail('Aufruf: keygen <datei.pem> | sign --apk ... (siehe Kopfkommentar)');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (err) {
    fail(err instanceof Error ? err.message : String(err));
  }
}
