// Einwurf (Home Assistant, Zähler-Postfach). Der Server speichert nur UNDURCHSICHTIGE Päckchen (libsodium Sealed Box): er kennt weder Kanal noch Zahl noch
// Schlüssel, öffnet nie ein Päckchen und prüft nur Form und Größe. Ver- und Entschlüsselung und der HMAC passieren ausschließlich in Home Assistant und in der App.
// Token nur als SHA-256-Hash; Päckchen, `k` und Token nie in Log, Audit oder Fehlermeldungen; die Familie kommt immer aus dem Token bzw. der Sitzung.
import { randomBytes } from 'node:crypto';
import { and, asc, count, eq, gt, inArray, isNull, lt, or, sql } from 'drizzle-orm';
import { writeAudit } from '../auth/audit.js';
import type { AuthContext, RequestMeta } from '../auth/context.js';
import { sha256Hex } from '../auth/crypto.js';
import { requireStepUp } from '../auth/sessions.js';
import type { SessionPrincipal } from '../auth/types.js';
import { families, ingestInbox, ingestTokens } from '../db/schema.js';
import { AppError } from '../errors.js';

export const INGEST_TOKEN_PREFIX = 'fhi_';
/** Höchstens so viele aktive (nicht widerrufene) Tokens je Familie. */
export const MAX_ACTIVE_TOKENS = 5;
/** Höchstens so viele offene Päckchen je Familie. */
export const MAX_OPEN_BOXES = 3000;
/** Päckchen werden nach 30 Tagen gelöscht. */
export const INBOX_RETENTION_DAYS = 30;
/** `last_used_at` wird höchstens so oft geschrieben. */
const LAST_USED_GRANULARITY_MS = 5 * 60_000;
export const MAX_PAGE = 200;
export const MAX_ITEMS = 50;
export const MAX_BOX_BYTES = 1024;

const forbidden = () => new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
const notFound = () => new AppError(404, 'not_found');

/** Schalter aus = die Funktion existiert nicht (404). */
export function requireIngestEnabled(ctx: Pick<AuthContext, 'config'>): void {
  if (!ctx.config.ingest.enabled) throw notFound();
}

function requireAdmin(p: SessionPrincipal): void {
  if (p.role !== 'admin') throw forbidden();
}

/** Nur Eltern und Admins (Kinder bekommen 404 wie bei den Zählern). */
function requireParent(p: SessionPrincipal): void {
  if (p.role !== 'admin' && p.role !== 'parent') throw notFound();
}

export const tokenHash = (token: string): string => sha256Hex(token);

/** Form eines Tokens (nur für die Vorprüfung und die Rate-Limit-Schlüssel; ob es gilt, entscheidet allein die Datenbank). */
export const TOKEN_SHAPE = /^fhi_[A-Za-z0-9_-]{43}$/;

// ---------- Tokens (Admin) ----------

export interface TokenView {
  id: string;
  name: string;
  createdAt: Date;
  lastUsedAt: Date | null;
  revokedAt: Date | null;
}

export async function createToken(ctx: AuthContext, p: SessionPrincipal, name: string, meta: RequestMeta): Promise<TokenView & { token: string }> {
  requireIngestEnabled(ctx);
  requireAdmin(p);
  requireStepUp(ctx, p);
  const token = INGEST_TOKEN_PREFIX + randomBytes(32).toString('base64url');
  const now = ctx.now();
  const row = await ctx.db.transaction(async (tx) => {
    // Familie sperren: zwei gleichzeitige Anlagen dürfen die Obergrenze nicht überschreiten
    await tx.select({ id: families.id }).from(families).where(eq(families.id, p.familyId)).for('update');
    const [n] = await tx.select({ n: count() }).from(ingestTokens).where(and(eq(ingestTokens.familyId, p.familyId), isNull(ingestTokens.revokedAt)));
    if ((n?.n ?? 0) >= MAX_ACTIVE_TOKENS) throw new AppError(409, 'token_limit', 'Es gibt schon die höchste Zahl aktiver Zugänge. Widerrufe zuerst einen.');
    const [r] = await tx
      .insert(ingestTokens)
      .values({ familyId: p.familyId, name, tokenHash: tokenHash(token), createdBy: p.userId, createdAt: now })
      .returning({ id: ingestTokens.id, name: ingestTokens.name, createdAt: ingestTokens.createdAt, lastUsedAt: ingestTokens.lastUsedAt, revokedAt: ingestTokens.revokedAt });
    if (!r) throw new Error('Token nicht gespeichert');
    await writeAudit(ctx, tx, { event: 'ingest_token_created', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { tokenId: r.id } });
    return r;
  });
  return { ...row, token };
}

export async function listTokens(ctx: AuthContext, p: SessionPrincipal): Promise<TokenView[]> {
  requireIngestEnabled(ctx);
  requireAdmin(p);
  return ctx.db
    .select({ id: ingestTokens.id, name: ingestTokens.name, createdAt: ingestTokens.createdAt, lastUsedAt: ingestTokens.lastUsedAt, revokedAt: ingestTokens.revokedAt })
    .from(ingestTokens)
    .where(eq(ingestTokens.familyId, p.familyId))
    .orderBy(asc(ingestTokens.createdAt), asc(ingestTokens.id));
}

/** Widerruft ein Token (nie hart löschen). Unbekannt, fremd oder schon widerrufen: 404. */
export async function revokeToken(ctx: AuthContext, p: SessionPrincipal, id: string, meta: RequestMeta): Promise<void> {
  requireIngestEnabled(ctx);
  requireAdmin(p);
  requireStepUp(ctx, p);
  await ctx.db.transaction(async (tx) => {
    const hit = await tx
      .update(ingestTokens)
      .set({ revokedAt: ctx.now() })
      .where(and(eq(ingestTokens.id, id), eq(ingestTokens.familyId, p.familyId), isNull(ingestTokens.revokedAt)))
      .returning({ id: ingestTokens.id });
    if (hit.length === 0) throw notFound();
    await writeAudit(ctx, tx, { event: 'ingest_token_revoked', familyId: p.familyId, actorId: p.userId, ip: meta.ip, detail: { tokenId: id } });
  });
}

// ---------- Einwurf (Token) ----------

const unauthorized = () => new AppError(401, 'unauthenticated', 'Nicht angemeldet.');

/** Prüft den Header `Authorization: Bearer fhi_…`. Jeder Fehlschlag (fehlt, falsche Form, unbekannt, widerrufen) antwortet gleich. */
export async function authenticateToken(ctx: AuthContext, authorization: string | undefined): Promise<{ tokenId: string; familyId: string }> {
  const m = authorization === undefined ? null : /^Bearer\s+(\S+)$/i.exec(authorization);
  const token = m?.[1];
  if (!token || !TOKEN_SHAPE.test(token)) throw unauthorized();
  const [row] = await ctx.db
    .select({ id: ingestTokens.id, familyId: ingestTokens.familyId })
    .from(ingestTokens)
    .where(and(eq(ingestTokens.tokenHash, tokenHash(token)), isNull(ingestTokens.revokedAt)));
  if (!row) throw unauthorized();
  return { tokenId: row.id, familyId: row.familyId };
}

/** `last_used_at` nur nach gültiger Body-Prüfung und höchstens alle paar Minuten schreiben. */
export async function touchToken(ctx: Pick<AuthContext, 'db' | 'now'>, tokenId: string): Promise<void> {
  const now = ctx.now();
  await ctx.db
    .update(ingestTokens)
    .set({ lastUsedAt: now })
    .where(and(eq(ingestTokens.id, tokenId), or(isNull(ingestTokens.lastUsedAt), lt(ingestTokens.lastUsedAt, new Date(now.getTime() - LAST_USED_GRANULARITY_MS)))));
}

export interface DropItem {
  k: string;
  box: Buffer;
}

/** Wirft Päckchen ein. Doppelte (gleiches Token und `k`) werden still gezählt. Über der Obergrenze offener Päckchen: 429 `inbox_full` (nichts wird gespeichert). */
export async function dropItems(ctx: AuthContext, who: { tokenId: string; familyId: string }, items: DropItem[]): Promise<{ accepted: number; duplicates: number }> {
  const now = ctx.now();
  const accepted = await ctx.db.transaction(async (tx) => {
    // Advisory-Lock je Familie (bis zum Ende der Transaktion), damit die Obergrenze auch bei gleichzeitigen Einwürfen gilt
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${'ingest-inbox:' + who.familyId}, 0))`);
    const rows = await tx
      .insert(ingestInbox)
      .values(items.map((i) => ({ familyId: who.familyId, tokenId: who.tokenId, k: i.k, box: i.box, receivedAt: now })))
      .onConflictDoNothing({ target: [ingestInbox.tokenId, ingestInbox.k] })
      .returning({ id: ingestInbox.id });
    const [n] = await tx.select({ n: count() }).from(ingestInbox).where(eq(ingestInbox.familyId, who.familyId));
    if ((n?.n ?? 0) > MAX_OPEN_BOXES) throw new AppError(429, 'inbox_full', 'Das Postfach ist voll.');
    return rows.length;
  });
  return { accepted, duplicates: items.length - accepted };
}

// ---------- Abholen und Quittieren (Eltern/Admins) ----------

export interface PendingPage {
  items: Array<{ id: string; box: string; receivedAt: Date }>;
  next: string | null;
}

/**
 * Seite offener Päckchen, stabil nach Eingang geordnet. `after` ist der `next`-Wert der Seite davor (undurchsichtig). Mit `tokenId` nur die Päckchen dieser Verbindung (jedes
 * Abholgerät fragt nur nach seinen eigenen); die Familie der Sitzung bleibt immer maßgeblich: ein fremdes oder unbekanntes Token ergibt eine leere Liste, nie einen Fehler oder
 * Päckchen einer anderen Familie.
 */
export async function listPending(ctx: AuthContext, p: SessionPrincipal, after: number | undefined, limit: number, tokenId?: string): Promise<PendingPage> {
  requireIngestEnabled(ctx);
  requireParent(p);
  const rows = await ctx.db
    .select({ id: ingestInbox.id, seq: ingestInbox.seq, box: ingestInbox.box, receivedAt: ingestInbox.receivedAt })
    .from(ingestInbox)
    .where(and(eq(ingestInbox.familyId, p.familyId), after !== undefined ? gt(ingestInbox.seq, after) : undefined, tokenId !== undefined ? eq(ingestInbox.tokenId, tokenId) : undefined))
    .orderBy(asc(ingestInbox.seq))
    .limit(limit + 1);
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return {
    items: page.map((r) => ({ id: r.id, box: Buffer.from(r.box).toString('base64'), receivedAt: r.receivedAt })),
    next: rows.length > limit && last ? String(last.seq) : null,
  };
}

/** Löscht quittierte Päckchen der eigenen Familie atomar; unbekannte oder fremde IDs zählen nicht. */
export async function ackPending(ctx: AuthContext, p: SessionPrincipal, ids: string[]): Promise<number> {
  requireIngestEnabled(ctx);
  requireParent(p);
  const hit = await ctx.db
    .delete(ingestInbox)
    .where(and(eq(ingestInbox.familyId, p.familyId), inArray(ingestInbox.id, ids)))
    .returning({ id: ingestInbox.id });
  return hit.length;
}

// ---------- Aufräumen ----------

/** Päckchen nach 30 Tagen löschen. */
export async function purgeInbox(ctx: Pick<AuthContext, 'db' | 'now'>): Promise<number> {
  const cutoff = new Date(ctx.now().getTime() - INBOX_RETENTION_DAYS * 86_400_000);
  const gone = await ctx.db.delete(ingestInbox).where(lt(ingestInbox.receivedAt, cutoff)).returning({ id: ingestInbox.id });
  return gone.length;
}

/** Widerrufene Tokens nach 400 Tagen endgültig löschen (Päckchen hängen per ON DELETE CASCADE am Token und sind nach 30 Tagen ohnehin weg). */
export const REVOKED_TOKEN_RETENTION_DAYS = 400;
export async function purgeRevokedTokens(ctx: Pick<AuthContext, 'db' | 'now'>): Promise<number> {
  const cutoff = new Date(ctx.now().getTime() - REVOKED_TOKEN_RETENTION_DAYS * 86_400_000);
  const gone = await ctx.db.delete(ingestTokens).where(lt(ingestTokens.revokedAt, cutoff)).returning({ id: ingestTokens.id });
  return gone.length;
}

/** Nur Zahlen (für eine spätere Betreiber-Ansicht): aktive Tokens, offene Päckchen. */
export async function ingestCounts(ctx: Pick<AuthContext, 'db'>, familyId: string): Promise<{ activeTokens: number; openBoxes: number }> {
  const [t] = await ctx.db.select({ n: count() }).from(ingestTokens).where(and(eq(ingestTokens.familyId, familyId), isNull(ingestTokens.revokedAt)));
  const [b] = await ctx.db.select({ n: count() }).from(ingestInbox).where(eq(ingestInbox.familyId, familyId));
  return { activeTokens: t?.n ?? 0, openBoxes: b?.n ?? 0 };
}
