// /api/v1/ingest: Einwurf für Home Assistant (Zähler-Postfach). Fachlogik in src/ingest/service.ts. Schalter INGEST_ENABLED (aus = alle Routen 404).
// Der Einwurf (POST /ingest/zaehler) authentifiziert NUR per Token im Header (kein Cookie, kein CSRF, keine Sitzung); das Token gilt auf keiner anderen Route.
// Die Routen für Token (Admin) und zum Abholen/Quittieren (Eltern/Admins) brauchen die normale Sitzung. Päckchen, `k` und Token landen nie im Log.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import {
  ackPending,
  authenticateToken,
  createToken,
  dropItems,
  listPending,
  listTokens,
  MAX_BOX_BYTES,
  MAX_ITEMS,
  MAX_PAGE,
  requireIngestEnabled,
  revokeToken,
  touchToken,
} from '../ingest/service.js';
import { claimPostfachTransfer, createPostfachTransfer } from '../ingest/transfer.js';
import { BoundedLimiter } from '../ingest/limiter.js';
import { normalizeIp } from '../net.js';
import { AppError } from '../errors.js';
import { b64urlBlobMin, b64urlKey, idParams, meta, parse, safeString, strictLimit, text, uuid } from './util.js';

/** Base64 (Standard-Alphabet, mit Auffüllung, kanonisch) zu 1 bis 1024 Bytes; sonst null. Der Inhalt wird nie ausgewertet. */
function decodeBox(s: string): Buffer | null {
  if (s.length === 0 || s.length > Math.ceil(MAX_BOX_BYTES / 3) * 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(s) || s.length % 4 !== 0) return null;
  const buf = Buffer.from(s, 'base64');
  if (buf.length < 1 || buf.length > MAX_BOX_BYTES || buf.toString('base64') !== s) return null;
  return buf;
}

const dropBody = z
  .object({
    items: z
      .array(
        z
          .object({
            k: safeString().pipe(z.string().min(1).max(64)),
            box: z.string().min(1).max(Math.ceil(MAX_BOX_BYTES / 3) * 4),
          })
          .strict(),
      )
      .min(1)
      .max(MAX_ITEMS),
  })
  .strict();

const pendingQuery = z
  .object({
    after: z.string().regex(/^\d{1,18}$/).optional(),
    limit: z.coerce.number().int().min(1).max(MAX_PAGE).default(MAX_PAGE),
    /** Nur die Päckchen dieser Verbindung (Token-ID); ohne Angabe alle der Familie. */
    token: uuid.optional(),
  })
  .strict();

const HOUR_MS = 3_600_000;
/** Alle Einwurf-Anfragen je Netzadresse und Stunde. */
export const IP_PER_HOUR = 300;
/** Anfragen mit ungültigem Token je Netzadresse und Stunde (nur Fehlschläge zählen). */
export const BAD_TOKEN_PER_HOUR = 20;
/** Weitergabe des Postfach-Schlüssels: Anlegen und Einlösen je Person (Sitzung) und Stunde, zusätzlich zur strengen Grenze je Netzadresse. */
export const TRANSFER_CREATE_PER_HOUR = 10;
export const TRANSFER_CLAIM_PER_HOUR = 20;

export function registerIngestRoutes(app: FastifyInstance, config: Config, auth: Auth): void {
  const ctx = auth.ctx;
  const strikt = strictLimit(config);

  // Grenzen: (1) je Netzadresse für ALLE Einwurf-Anfragen (Plugin, großzügig), (2) je Netzadresse nur für Fehlschläge der Anmeldung (eng),
  // (3) je Token erst NACH gültiger Anmeldung (Schlüssel = Token-ID aus der Datenbank, nie das Eingabetoken). Die eigenen Zähler sind in der Größe begrenzt.
  const badAuth = new BoundedLimiter(BAD_TOKEN_PER_HOUR, HOUR_MS, ctx.now);
  const perToken = new BoundedLimiter(config.ingest.ratePerHour, HOUR_MS, ctx.now);
  const tooMany = () => new AppError(429, 'rate_limited', 'Zu viele Anfragen. Bitte später erneut versuchen.', { 'retry-after': '600' });
  const transferCreate = new BoundedLimiter(TRANSFER_CREATE_PER_HOUR, HOUR_MS, ctx.now);
  const transferClaim = new BoundedLimiter(TRANSFER_CLAIM_PER_HOUR, HOUR_MS, ctx.now);
  const dropLimit = {
    config: {
      rateLimit: {
        max: IP_PER_HOUR,
        timeWindow: '1 hour',
        keyGenerator: (req: { ip: string }) => `ingest-ip:${normalizeIp(req.ip)}`,
      },
    },
    bodyLimit: 100 * 1024,
  };

  app.post('/api/v1/ingest/zaehler', dropLimit, async (req, reply) => {
    requireIngestEnabled(ctx);
    const ip = normalizeIp(req.ip);
    if (badAuth.blocked(ip)) throw tooMany();
    let who: Awaited<ReturnType<typeof authenticateToken>>;
    try {
      who = await authenticateToken(ctx, req.headers.authorization);
    } catch (err: unknown) {
      if (err instanceof AppError && err.status === 401) badAuth.hit(ip);
      throw err;
    }
    if (!perToken.hit(who.tokenId)) throw tooMany();
    const body = parse(dropBody, req.body);
    const items = body.items.map((i) => {
      const box = decodeBox(i.box);
      if (!box) throw new AppError(400, 'invalid_request');
      return { k: i.k, box };
    });
    await touchToken(ctx, who.tokenId);
    const res = await dropItems(ctx, who, items);
    return reply.header('cache-control', 'no-store').send(res);
  });

  app.post('/api/v1/ingest/tokens', strikt, async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    const body = parse(z.object({ name: text(40) }).strict(), req.body);
    const t = await createToken(ctx, p, body.name, meta(req));
    // das Klartext-Token steht nur in dieser Antwort
    return reply.header('cache-control', 'no-store').send({ token: t.token, id: t.id, name: t.name, createdAt: t.createdAt });
  });

  app.get('/api/v1/ingest/tokens', async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    return reply.header('cache-control', 'no-store').send({ tokens: await listTokens(ctx, p) });
  });

  app.delete('/api/v1/ingest/tokens/:id', strikt, async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    await revokeToken(ctx, p, id, meta(req));
    return reply.send({ ok: true });
  });

  app.get('/api/v1/ingest/zaehler/pending', async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    const q = parse(pendingQuery, req.query);
    const page = await listPending(ctx, p, q.after === undefined ? undefined : Number(q.after), q.limit, q.token);
    return reply.header('cache-control', 'no-store').send(page);
  });

  app.post('/api/v1/ingest/zaehler/ack', async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    const body = parse(z.object({ ids: z.array(uuid).min(1).max(MAX_PAGE) }).strict(), req.body);
    return reply.send({ deleted: await ackPending(ctx, p, body.ids) });
  });
  // Weitergabe des Postfach-Schlüssels an ein weiteres Gerät derselben Person (Eltern/Admins, Sitzung; der Blob bleibt für den Server undurchsichtig)
  app.post('/api/v1/ingest/postfach-transfer', strikt, async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    if (!transferCreate.hit(p.userId)) throw tooMany();
    const body = parse(z.object({ lookup: b64urlKey, blob: b64urlBlobMin(32, 1024) }).strict(), req.body);
    return reply.header('cache-control', 'no-store').send(await createPostfachTransfer(ctx, p, body, meta(req)));
  });

  app.post('/api/v1/ingest/postfach-transfer/claim', strikt, async (req, reply) => {
    requireIngestEnabled(ctx);
    const p = await auth.requireSession(req);
    if (!transferClaim.hit(p.userId)) throw tooMany();
    const body = parse(z.object({ lookup: b64urlKey }).strict(), req.body);
    return reply.header('cache-control', 'no-store').send(await claimPostfachTransfer(ctx, p, body, meta(req)));
  });
}
