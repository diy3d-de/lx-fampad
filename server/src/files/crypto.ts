// Blockverschlüsselung der Dateiablage im Modus `server` (Abschnitt 6n): AES-256-GCM im STREAM-Muster, `node:crypto`, keine eigenen Primitive.
//
// Format einer Blob-Datei:
//   Kopf (16 Byte):  "LXF1" | Blockgröße (u32 BE, 65536) | Nonce-Präfix (7 Byte, zufällig je Blob) | 0x00
//   danach je Block: Chiffretext (höchstens 64 KiB) | GCM-Tag (16 Byte)
// Je Blob ein eigener Dateischlüssel (DEK, 32 Byte, zufällig), der verpackt in der Datenbank liegt (`dek_wrap`, mit dem aus AUTH_SECRET_KEY abgeleiteten Schlüssel `files/wrap/v<kid>`).
// Nonce eines Blocks (12 Byte) = Präfix (7) | Blocknummer (u32 BE, 4) | Endkennzeichen (1 Byte: 1 beim letzten Block, sonst 0). Der letzte Block trägt das Kennzeichen in der Nonce:
// ein abgeschnittener Blob (letzter Block fehlt), vertauschte, doppelte oder ersetzte Blöcke scheitern an der Tag-Prüfung. AAD = "lxf1" | Blob-ID (16 Byte) | Blockgröße (u32 BE):
// ein Block aus einem anderen Blob passt nicht. Ein leerer Blob besteht aus genau einem leeren, als letzten gekennzeichneten Block.
// Der Gewinn ist ehrlich begrenzt: eine Kopie der Platte oder der NAS-Sicherung ist ohne AUTH_SECRET_KEY wertlos; der laufende Server kann lesen.
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { open, type FileHandle } from 'node:fs/promises';
import type { KeyRing } from '../auth/crypto.js';

export const BLOCK_SIZE = 65_536;
export const TAG_SIZE = 16;
export const HEADER_SIZE = 16;
export const WRAP_KID = 1;
const MAGIC = Buffer.from('LXF1', 'latin1');

/** Anzahl der Blöcke für einen Klartext dieser Größe (mindestens einer, auch für die leere Datei). */
export const blockCount = (size: number): number => Math.max(1, Math.ceil(size / BLOCK_SIZE));
/** Größe der Datei auf dem Datenträger. */
export const encryptedSize = (size: number): number => HEADER_SIZE + size + TAG_SIZE * blockCount(size);

export interface BlobKey {
  dek: Buffer;
  prefix: Buffer;
}

export const newBlobKey = (): BlobKey => ({ dek: randomBytes(32), prefix: randomBytes(7) });

const uuidBytes = (id: string): Buffer => Buffer.from(id.replaceAll('-', ''), 'hex');

export function header(prefix: Buffer): Buffer {
  const h = Buffer.alloc(HEADER_SIZE);
  MAGIC.copy(h, 0);
  h.writeUInt32BE(BLOCK_SIZE, 4);
  prefix.copy(h, 8);
  return h;
}

export function blockNonce(prefix: Buffer, index: number, last: boolean): Buffer {
  const n = Buffer.alloc(12);
  prefix.copy(n, 0);
  n.writeUInt32BE(index, 7);
  n[11] = last ? 1 : 0;
  return n;
}

export function blockAad(blobId: string): Buffer {
  const aad = Buffer.alloc(4 + 16 + 4);
  aad.write('lxf1', 0, 'latin1');
  uuidBytes(blobId).copy(aad, 4);
  aad.writeUInt32BE(BLOCK_SIZE, 20);
  return aad;
}

export function encryptBlock(key: BlobKey, blobId: string, index: number, last: boolean, plain: Buffer): Buffer {
  const c = createCipheriv('aes-256-gcm', key.dek, blockNonce(key.prefix, index, last));
  c.setAAD(blockAad(blobId));
  return Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
}

/** Entschlüsselt einen Block; wirft bei jeder Manipulation (Inhalt, Reihenfolge, Länge, fremder Blob). */
export function decryptBlock(key: BlobKey, blobId: string, index: number, last: boolean, sealed: Buffer): Buffer {
  if (sealed.length < TAG_SIZE) throw new Error('Block zu kurz');
  const d = createDecipheriv('aes-256-gcm', key.dek, blockNonce(key.prefix, index, last));
  d.setAAD(blockAad(blobId));
  d.setAuthTag(sealed.subarray(sealed.length - TAG_SIZE));
  return Buffer.concat([d.update(sealed.subarray(0, sealed.length - TAG_SIZE)), d.final()]);
}

async function readFully(fh: FileHandle, length: number, position: number): Promise<Buffer> {
  const buf = Buffer.alloc(length);
  let got = 0;
  while (got < length) {
    const { bytesRead } = await fh.read(buf, got, length - got, position + got);
    if (bytesRead === 0) throw new Error('Datei zu kurz');
    got += bytesRead;
  }
  return buf;
}

/**
 * Verschlüsselt `src` (Klartext, `size` Byte) blockweise nach `dst` und gibt die SHA-256 des Klartexts (Hex) zurück. Die Zieldatei wird mit 0600 angelegt und mit fsync gesichert.
 * Liest `src` genau `size` Byte (eine später wachsende oder kürzere Datei ergibt einen Fehler, nie einen halben Blob).
 */
export async function encryptFile(src: string, dst: string, key: BlobKey, blobId: string, size: number): Promise<string> {
  const hash = createHash('sha256');
  const input = await open(src, 'r');
  let output: FileHandle | undefined;
  try {
    output = await open(dst, 'wx', 0o600);
    await output.write(header(key.prefix), 0, HEADER_SIZE, 0);
    let written = HEADER_SIZE;
    const blocks = blockCount(size);
    for (let i = 0; i < blocks; i++) {
      const len = Math.min(BLOCK_SIZE, size - i * BLOCK_SIZE);
      const plain = len === 0 ? Buffer.alloc(0) : await readFully(input, len, i * BLOCK_SIZE);
      hash.update(plain);
      const sealed = encryptBlock(key, blobId, i, i === blocks - 1, plain);
      await output.write(sealed, 0, sealed.length, written);
      written += sealed.length;
    }
    await output.sync();
    return hash.digest('hex');
  } finally {
    await input.close();
    await output?.close();
  }
}

/** Entschlüsselt den Bereich [start, end] (beide eingeschlossen) und liefert ihn blockweise; schließt die Datei auch beim Abbruch. */
export async function* decryptRange(path: string, key: BlobKey, blobId: string, size: number, start: number, end: number): AsyncGenerator<Buffer> {
  if (size === 0 || start > end) return;
  const fh = await open(path, 'r');
  try {
    const head = await readFully(fh, HEADER_SIZE, 0);
    if (!head.subarray(0, 4).equals(MAGIC) || head.readUInt32BE(4) !== BLOCK_SIZE || !head.subarray(8, 15).equals(key.prefix)) throw new Error('Kopf ungültig');
    const blocks = blockCount(size);
    for (let i = Math.floor(start / BLOCK_SIZE); i <= Math.floor(end / BLOCK_SIZE); i++) {
      const len = Math.min(BLOCK_SIZE, size - i * BLOCK_SIZE);
      const sealed = await readFully(fh, len + TAG_SIZE, HEADER_SIZE + i * (BLOCK_SIZE + TAG_SIZE));
      const plain = decryptBlock(key, blobId, i, i === blocks - 1, sealed);
      const from = Math.max(start - i * BLOCK_SIZE, 0);
      const to = Math.min(end - i * BLOCK_SIZE + 1, len);
      yield plain.subarray(from, to);
    }
  } finally {
    await fh.close();
  }
}

// ---- Verpacken des Dateischlüssels ----

/** AAD des Verpackens: bindet den verpackten Schlüssel an Blob und Schlüsselnummer. */
const wrapAad = (blobId: string, kid: number): Buffer => Buffer.concat([Buffer.from('lxf1-wrap', 'latin1'), uuidBytes(blobId), Buffer.from([kid])]);

/** Dateischlüssel und Nonce-Präfix, verpackt (Nonce 12 | Chiffretext 39 | Tag 16): AES-256-GCM mit dem abgeleiteten Schlüssel `files/wrap/v<kid>`. */
export function wrapKey(keys: KeyRing, blobId: string, key: BlobKey, kid = WRAP_KID): Buffer {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', keys.derive(`files/wrap/v${kid}`), iv);
  c.setAAD(wrapAad(blobId, kid));
  return Buffer.concat([iv, c.update(Buffer.concat([key.dek, key.prefix])), c.final(), c.getAuthTag()]);
}

export function unwrapKey(keys: KeyRing, blobId: string, wrapped: Buffer, kid: number): BlobKey {
  if (wrapped.length !== 12 + 39 + 16) throw new Error('Verpackter Schlüssel ungültig');
  const d = createDecipheriv('aes-256-gcm', keys.derive(`files/wrap/v${kid}`), wrapped.subarray(0, 12));
  d.setAAD(wrapAad(blobId, kid));
  d.setAuthTag(wrapped.subarray(wrapped.length - 16));
  const plain = Buffer.concat([d.update(wrapped.subarray(12, wrapped.length - 16)), d.final()]);
  return { dek: plain.subarray(0, 32), prefix: plain.subarray(32, 39) };
}
