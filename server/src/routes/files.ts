// Dateiablage: tus-Teilprotokoll für Uploads (Kern 1.0.0 + creation, expiration, termination), Auslieferung von Blobs und das Kontingent.
//   OPTIONS/POST /api/v1/uploads, HEAD/PATCH/DELETE /api/v1/uploads/:id, GET /api/v1/files/blobs/:id, GET /api/v1/files/usage
// Ohne FILES_ENABLED antworten alle Routen mit 404 (noch vor der Anmeldung und vor dem Einlesen eines Bodys). Anmeldung bei JEDEM Abruf, nie ein Link mit Token (keine Signed URLs).
// Fachlogik in src/files/. Uploads sind Binär-Anfragen mit hartem Größenlimit nur für diese Route (Muster: routes/avatar.ts).
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { Auth } from '../auth/service.js';
import type { SessionPrincipal } from '../auth/types.js';
import { FILES_CHUNK_BYTES, type Config } from '../config.js';
import { AppError } from '../errors.js';
import { cleanMime, contentDisposition, parseRange } from '../files/names.js';
import type { BlobKind, BlobModus } from '../files/claim.js';
import type { FilesService, UploadRow } from '../files/service.js';
import { idParams, parse } from './util.js';

const TUS_VERSION = '1.0.0';
const CHUNK_TYPE = 'application/offset+octet-stream';

/** Zahl im Kopf: nur Ziffern, kein Vorzeichen, kein Überlauf (höchstens 15 Stellen). */
function headerNumber(value: string | string[] | undefined): number | null {
  if (typeof value !== 'string' || !/^\d{1,15}$/.test(value)) return null;
  return Number(value);
}

/** `Upload-Metadata`: "schlüssel base64wert,schlüssel2 …"; doppelte oder ungültige Einträge ergeben null (400). */
function parseMetadata(value: string | string[] | undefined): Map<string, string> | null {
  const out = new Map<string, string>();
  if (value === undefined || value === '') return out;
  if (typeof value !== 'string' || value.length > 1024) return null;
  for (const part of value.split(',')) {
    const [key, b64, extra] = part.trim().split(' ');
    if (!key || extra !== undefined || !/^[a-z][a-z0-9_]{0,31}$/.test(key) || out.has(key)) return null;
    if (b64 === undefined) {
      out.set(key, '');
      continue;
    }
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64) || b64.length > 400) return null;
    const text = Buffer.from(b64, 'base64').toString('utf8');
    if (text.length > 255 || text.includes('\u0000')) return null;
    out.set(key, text);
  }
  return out;
}

const httpDate = (d: Date): string => d.toUTCString();

export function registerFilesRoutes(app: FastifyInstance, config: Config, auth: Auth, files: FilesService): void {
  const principals = new WeakMap<FastifyRequest, SessionPrincipal>();
  // 1. Schalter (404 noch vor allem anderen), 2. Anmeldung vor dem Einlesen des Bodys
  const onRequest = async (req: FastifyRequest) => {
    if (!files.enabled) throw new AppError(404, 'not_found');
    principals.set(req, await auth.requireSession(req));
  };
  const who = async (req: FastifyRequest) => {
    const p = principals.get(req) ?? (await auth.requireSession(req));
    return { userId: p.userId, familyId: p.familyId, role: p.role };
  };
  const tusHeaders = (reply: FastifyReply) => reply.header('tus-resumable', TUS_VERSION);
  const needTus = (req: FastifyRequest) => {
    if (req.headers['tus-resumable'] !== TUS_VERSION) throw new AppError(412, 'tus_version', 'Nicht unterstützte Upload-Version.', { 'tus-version': TUS_VERSION });
  };
  const stateHeaders = (reply: FastifyReply, u: UploadRow) =>
    reply.headers({ 'upload-offset': String(u.offset), 'upload-length': String(u.length), 'upload-expires': httpDate(u.expiresAt), 'cache-control': 'no-store' });

  void app.register(async (scope) => {
    scope.addContentTypeParser(CHUNK_TYPE, { parseAs: 'buffer', bodyLimit: FILES_CHUNK_BYTES }, (_req, body, done) => done(null, body));

    scope.options('/api/v1/uploads', { onRequest }, async (_req, reply) => {
      return tusHeaders(reply)
        .headers({
          'tus-version': TUS_VERSION,
          'tus-extension': 'creation,expiration,termination',
          'tus-max-size': String(config.files.maxE2eeBytes),
          'cache-control': 'no-store',
        })
        .code(204)
        .send();
    });

    // Upload anlegen: Upload-Length (Pflicht), Upload-Metadata: modus (server|e2ee), kind (datei|thumb, nur Modus server), mime (nur Modus server)
    scope.post('/api/v1/uploads', { onRequest }, async (req, reply) => {
      needTus(req);
      const p = await who(req);
      const length = headerNumber(req.headers['upload-length']);
      if (length === null) throw new AppError(400, 'invalid_request', 'Upload-Length fehlt oder ist ungültig.');
      if (req.headers['upload-defer-length'] !== undefined) throw new AppError(400, 'invalid_request', 'Upload-Defer-Length wird nicht unterstützt.');
      const meta = parseMetadata(req.headers['upload-metadata']);
      if (!meta) throw new AppError(400, 'invalid_request', 'Upload-Metadata ist ungültig.');
      const modus = (meta.get('modus') || 'server') as BlobModus;
      if (modus !== 'server' && modus !== 'e2ee') throw new AppError(400, 'invalid_request', 'Unbekannter Modus.');
      const kindRaw = meta.get('kind') || (modus === 'e2ee' ? 'opak' : 'datei');
      const kind = kindRaw as BlobKind;
      if (modus === 'e2ee' ? kind !== 'opak' : kind !== 'datei' && kind !== 'thumb') throw new AppError(400, 'invalid_request', 'Unbekannte Art.');
      let mime: string | null = null;
      const mimeRaw = meta.get('mime');
      if (modus === 'server' && mimeRaw) {
        mime = cleanMime(mimeRaw);
        if (mime === null) throw new AppError(400, 'invalid_request', 'Der Dateityp ist ungültig.');
      }
      const upload = await files.createUpload(p, { length, modus, kind, mime });
      return tusHeaders(reply)
        .headers({ location: `/api/v1/uploads/${upload.id}`, 'upload-expires': httpDate(upload.expiresAt), 'upload-offset': '0', 'cache-control': 'no-store' })
        .code(201)
        .send();
    });

    scope.head('/api/v1/uploads/:id', { onRequest }, async (req, reply) => {
      needTus(req);
      const { id } = parse(idParams, req.params);
      const u = await files.head(await who(req), id);
      return stateHeaders(tusHeaders(reply), u).code(200).send();
    });

    scope.patch('/api/v1/uploads/:id', { onRequest, bodyLimit: FILES_CHUNK_BYTES, config: { rateLimit: { max: 240, timeWindow: '1 minute' } } }, async (req, reply) => {
      needTus(req);
      const { id } = parse(idParams, req.params);
      const type = (req.headers['content-type'] ?? '').split(';')[0]?.trim().toLowerCase() ?? '';
      if (type !== CHUNK_TYPE) throw new AppError(415, 'unsupported_media_type', 'Der Inhaltstyp muss application/offset+octet-stream sein.');
      const offset = headerNumber(req.headers['upload-offset']);
      if (offset === null) throw new AppError(400, 'invalid_request', 'Upload-Offset fehlt oder ist ungültig.');
      const body = req.body === undefined || req.body === null ? Buffer.alloc(0) : req.body;
      if (!Buffer.isBuffer(body)) throw new AppError(400, 'invalid_request');
      const { upload, blob } = await files.append(await who(req), id, offset, body);
      stateHeaders(tusHeaders(reply), upload);
      if (blob) reply.headers({ 'upload-blob-id': blob.id, 'upload-sha256': blob.sha256 });
      return reply.code(204).send();
    });

    scope.delete('/api/v1/uploads/:id', { onRequest }, async (req, reply) => {
      needTus(req);
      const { id } = parse(idParams, req.params);
      await files.terminate(await who(req), id);
      return tusHeaders(reply).code(204).send();
    });

    // Kontingent der Familie (für die Anzeige „belegt von“ und die Vorprüfung der App)
    scope.get('/api/v1/files/usage', { onRequest }, async (req) => {
      const p = await who(req);
      const u = await files.usage(p.familyId);
      return {
        usedBytes: u.usedBytes,
        reservedBytes: u.reservedBytes,
        quotaBytes: u.quotaBytes,
        maxFileBytes: config.files.maxBytes,
        maxE2eeBytes: config.files.maxE2eeBytes,
        chunkBytes: FILES_CHUNK_BYTES,
      };
    });

    // Auslieferung: Anmeldung bei jedem Abruf, Sicht über den beanspruchenden Datensatz (sonst 404), ein Range (206), ETag = Blob-ID, immer als Anhang
    scope.get('/api/v1/files/blobs/:id', { onRequest, config: { rateLimit: { max: 1200, timeWindow: '1 minute' } } }, async (req, reply) => {
      const { id } = parse(idParams, req.params);
      const hit = await files.authorizeRead(await who(req), id);
      if (!hit) throw new AppError(404, 'not_found');
      const { blob } = hit;
      const thumb = blob.kind === 'thumb' && blob.mime !== null;
      const etag = `"${blob.id}"`;
      const headers: Record<string, string> = {
        etag,
        'accept-ranges': 'bytes',
        // Vorschaubilder sind unveränderlich (an die Blob-ID gebunden) und dürfen im Cache des angemeldeten Geräts liegen, Originale nie
        'cache-control': thumb ? 'private, max-age=31536000, immutable' : 'private, no-store',
        vary: 'Authorization, Cookie',
        'x-content-type-options': 'nosniff',
        'content-security-policy': "sandbox; default-src 'none'",
        'cross-origin-resource-policy': 'same-origin',
        'content-type': thumb ? (blob.mime as string) : 'application/octet-stream',
        'content-disposition': thumb ? contentDisposition('vorschau', true) : contentDisposition(hit.filename ?? 'datei'),
      };
      const inm = req.headers['if-none-match'];
      if (typeof inm === 'string' && inm.split(',').some((t) => t.trim() === etag || t.trim() === `W/${etag}`)) return reply.code(304).headers(headers).send();
      // If-Range: nur mit passender ETag gilt der Bereich, sonst die ganze Datei
      const ifRange = req.headers['if-range'];
      const rangeHeader = ifRange !== undefined && ifRange !== etag ? undefined : req.headers.range;
      const range = parseRange(rangeHeader, blob.size);
      if (range.kind === 'unsatisfiable') return reply.code(416).headers({ ...headers, 'content-range': `bytes */${blob.size}` }).send();
      const start = range.kind === 'range' ? range.start : 0;
      const end = range.kind === 'range' ? range.end : blob.size - 1;
      const length = blob.size === 0 ? 0 : end - start + 1;
      reply.code(range.kind === 'range' ? 206 : 200).headers({ ...headers, 'content-length': String(length) });
      if (range.kind === 'range') reply.header('content-range', `bytes ${start}-${end}/${blob.size}`);
      if (req.method === 'HEAD' || length === 0) return reply.send();
      const stream = files.readRange(blob, start, end);
      stream.on('error', (err) => req.log.error({ err }, 'Blob: Lesefehler'));
      return reply.send(stream);
    });
  });
}
