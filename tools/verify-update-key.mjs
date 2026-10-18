#!/usr/bin/env node
// Prüft vor dem Signieren (Release-Workflow), dass app/lib/constants.dart zum Signierschlüssel passt:
//   - kUpdateKeyId ist ein echter Text (nicht der Platzhalter, nicht ein Verweis auf kPlatzhalterKeyId)
//   - kUpdatePublicKey ist der öffentliche Schlüssel zu UPDATE_SIGNING_KEY (Umgebungsvariable, PEM)
// Aufruf: node tools/verify-update-key.mjs app/lib/constants.dart   -> gibt "key_id=<id>" aus (für $GITHUB_OUTPUT)
// Der private Schlüssel wird nie ausgegeben.
import { createPrivateKey, createPublicKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { rawPublicKey } from './update-manifest.mjs';

export const PLATZHALTER_KEY_ID = 'platzhalter';

/** Liest kUpdateKeyId und kUpdatePublicKey aus dem Quelltext von constants.dart. */
export function readKeyConstants(source) {
  const keyId = /const\s+kUpdateKeyId\s*=\s*'([^']+)'\s*;/.exec(source)?.[1] ?? null;
  const publicKey = /const\s+kUpdatePublicKey\s*=\s*'([^']+)'\s*;/.exec(source)?.[1] ?? null;
  return { keyId, publicKey };
}

/** Wirft bei Platzhalter oder wenn der öffentliche Schlüssel nicht zum privaten passt; liefert die Schlüssel-ID. */
export function checkKey(source, privatePem) {
  const { keyId, publicKey } = readKeyConstants(source);
  if (!keyId) throw new Error("kUpdateKeyId ist kein Textwert (noch der Verweis auf den Platzhalter?). Echte ID eintragen, z. B. 'fampad-2026-1'.");
  if (keyId === PLATZHALTER_KEY_ID) throw new Error('kUpdateKeyId ist noch der Platzhalter');
  if (!publicKey) throw new Error('kUpdatePublicKey nicht gefunden');
  if (!privatePem) throw new Error('UPDATE_SIGNING_KEY fehlt');
  const key = createPrivateKey(privatePem);
  if (key.asymmetricKeyType !== 'ed25519') throw new Error('UPDATE_SIGNING_KEY ist kein Ed25519-Schlüssel');
  const abgeleitet = rawPublicKey(createPublicKey(key)).toString('base64');
  if (abgeleitet !== publicKey) throw new Error('kUpdatePublicKey in constants.dart passt nicht zum Schlüssel in UPDATE_SIGNING_KEY');
  return keyId;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const file = process.argv[2];
    if (!file) throw new Error('Aufruf: verify-update-key.mjs <constants.dart>');
    console.log(`key_id=${checkKey(readFileSync(file, 'utf8'), process.env.UPDATE_SIGNING_KEY)}`);
  } catch (err) {
    console.error(`Fehler: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  }
}
