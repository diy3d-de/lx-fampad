// Bausteine für die Tests der Dateiablage: tus-Aufrufe, Beispieldateien, Welt mit eigenem Ablageordner.
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { crc32, deflateSync } from 'node:zlib';
import type { FilesDeps } from '../src/files/service.js';
import type { Client, Harness, Res } from './helpers.js';
import { World } from './helpers.js';

export const TUS = { 'tus-resumable': '1.0.0' };
export const sha256 = (b: Buffer): string => createHash('sha256').update(b).digest('hex');

/** `Upload-Metadata` aus einem Objekt. */
export const metaHeader = (o: Record<string, string>): string =>
  Object.entries(o)
    .map(([k, v]) => `${k} ${Buffer.from(v).toString('base64')}`)
    .join(',');

export const createUpload = (c: Client, length: number, md: Record<string, string> = {}, extra: Record<string, string> = {}): Promise<Res> =>
  c.request('POST', '/api/v1/uploads', { headers: { ...TUS, 'upload-length': String(length), ...(Object.keys(md).length > 0 ? { 'upload-metadata': metaHeader(md) } : {}), ...extra } });

export const uploadIdOf = (res: Res): string => {
  const m = /\/api\/v1\/uploads\/([0-9a-f-]{36})$/.exec(String(res.headers.location));
  if (!m?.[1]) throw new Error(`Upload nicht angelegt: ${res.status} ${JSON.stringify(res.json)}`);
  return m[1];
};

export const patchUpload = (c: Client, id: string, offset: number, body: Buffer, extra: Record<string, string> = {}): Promise<Res> =>
  c.request('PATCH', `/api/v1/uploads/${id}`, { headers: { ...TUS, 'content-type': 'application/offset+octet-stream', 'upload-offset': String(offset), ...extra }, body });

export const headUpload = (c: Client, id: string): Promise<Res> => c.request('HEAD', `/api/v1/uploads/${id}`, { headers: TUS });

/** Lädt Bytes in Abschnitten hoch und gibt die ID (= Blob-ID) und die letzte Antwort zurück. */
export async function upload(c: Client, bytes: Buffer, md: Record<string, string> = {}, chunk = 1_048_576): Promise<{ id: string; last: Res }> {
  const id = uploadIdOf(await createUpload(c, bytes.length, md));
  let last: Res = await patchUpload(c, id, 0, bytes.subarray(0, 0));
  for (let off = 0; off < bytes.length; off += chunk) last = await patchUpload(c, id, off, bytes.subarray(off, off + chunk));
  if (last.status !== 204) throw new Error(`Upload fehlgeschlagen: ${last.status} ${JSON.stringify(last.json)}`);
  return { id, last };
}

/** Kleines gültiges PNG (ein Pixel, oder b x h mit Nullen). */
export function png(width = 1, height = 1): Buffer {
  const chunk = (type: string, data: Buffer): Buffer => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

/** Eine PDF-ähnliche Datei (Magic-Bytes) mit Zufallsinhalt. */
export const pdfLike = (size: number): Buffer => Buffer.concat([Buffer.from('%PDF-1.7\n'), randomBytes(Math.max(0, size - 9))]);

export interface FilesWorld {
  world: World;
  dir: string;
  deps: { free: number };
  close(): Promise<void>;
}

/** Welt mit eingeschalteter Dateiablage in einem eigenen Temp-Ordner; `free` steuert den "freien Platz". */
export async function filesWorld(harness: Harness, env: Record<string, string> = {}): Promise<FilesWorld> {
  const dir = mkdtempSync(`${tmpdir()}/lx-files-`);
  const deps = { free: 1_000_000_000_000 };
  const filesDeps: FilesDeps = { freeBytes: async () => deps.free };
  const world = await World.create(harness.db, { FILES_ENABLED: 'true', FILES_DIR: dir, FILES_MIN_FREE_BYTES: '0', SYNC_RATE_LIMIT_MAX: '100000', ...env }, { filesDeps });
  return {
    world,
    dir,
    deps,
    async close() {
      await world.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export const newId = (): string => randomUUID();
