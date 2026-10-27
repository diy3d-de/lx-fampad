// Einwurf (Home Assistant): Weitergabe des Postfach-Schlüssels an ein weiteres Gerät derselben Person (Mehrgeräte-Abholen). Der Server reicht nur einen UNDURCHSICHTIGEN Blob
// weiter (2 Minuten, einmal einlösbar, nur durch dieselbe Person); das Einmalgeheimnis, mit dem er verschlüsselt ist, steht nur im QR bzw. Code und erreicht den Server nie.
// Wie die Geräte-Übertragung des Personenschlüssels (auth/keys.ts), aber eigene Tabelle und eigene Ereignisse: kein Sicherheitsereignis zu Personenschlüsseln, kein Wecker.
// Blob, Suchkennung und Geheimnis landen nie in Log, Audit oder Fehlermeldungen. Nur Eltern und Admins (Kinder 404), nur mit eingeschaltetem Einwurf.
import { and, eq, gt, lt } from 'drizzle-orm';
import { writeAudit } from '../auth/audit.js';
import type { AuthContext, RequestMeta } from '../auth/context.js';
import { sha256Hex } from '../auth/crypto.js';
import type { SessionPrincipal } from '../auth/types.js';
import { ingestPostfachTransfers } from '../db/schema.js';
import { AppError } from '../errors.js';
import { requireIngestEnabled, requireParent } from './service.js';

export const POSTFACH_TRANSFER_TTL_SEC = 120;

const notFound = () => new AppError(404, 'not_found');

function istEindeutigkeitsfehler(e: unknown): boolean {
  const x = e as { code?: string; cause?: { code?: string } } | null;
  return x?.code === '23505' || x?.cause?.code === '23505';
}

/** Legt die Weitergabe an (ersetzt eine offene derselben Person). Kollidiert die Suchkennung mit der einer anderen Person (praktisch ausgeschlossen), 409 statt 500. */
export async function createPostfachTransfer(
  ctx: AuthContext,
  p: SessionPrincipal,
  input: { lookup: string; blob: string },
  meta: RequestMeta,
): Promise<{ expiresAt: string; ttlSec: number }> {
  requireIngestEnabled(ctx);
  requireParent(p);
  const now = ctx.now();
  const expiresAt = new Date(now.getTime() + POSTFACH_TRANSFER_TTL_SEC * 1000);
  const lookupHash = sha256Hex(input.lookup);
  try {
    await ctx.db.transaction(async (tx) => {
      await tx
        .insert(ingestPostfachTransfers)
        .values({ userId: p.userId, lookupHash, blob: input.blob, createdAt: now, expiresAt })
        .onConflictDoUpdate({ target: ingestPostfachTransfers.userId, set: { lookupHash, blob: input.blob, createdAt: now, expiresAt } });
      await writeAudit(ctx, tx, { event: 'ingest_postfach_transfer_created', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip });
    });
  } catch (e) {
    if (istEindeutigkeitsfehler(e)) throw new AppError(409, 'transfer_conflict', 'Bitte versuche es noch einmal.');
    throw e;
  }
  return { expiresAt: expiresAt.toISOString(), ttlSec: POSTFACH_TRANSFER_TTL_SEC };
}

/** Löst die Weitergabe ein: genau einmal (DELETE ... RETURNING), nur durch dieselbe Person, nur vor Ablauf. Jeder Fehlschlag (unbekannt, abgelaufen, schon eingelöst, fremde Person) antwortet gleich mit 404. */
export async function claimPostfachTransfer(ctx: AuthContext, p: SessionPrincipal, input: { lookup: string }, meta: RequestMeta): Promise<{ blob: string }> {
  requireIngestEnabled(ctx);
  requireParent(p);
  return ctx.db.transaction(async (tx) => {
    const rows = await tx
      .delete(ingestPostfachTransfers)
      .where(and(eq(ingestPostfachTransfers.userId, p.userId), eq(ingestPostfachTransfers.lookupHash, sha256Hex(input.lookup)), gt(ingestPostfachTransfers.expiresAt, ctx.now())))
      .returning({ blob: ingestPostfachTransfers.blob });
    const row = rows[0];
    if (!row) throw notFound();
    await writeAudit(ctx, tx, { event: 'ingest_postfach_transfer_claimed', familyId: p.familyId, actorId: p.userId, deviceId: p.deviceId, ip: meta.ip });
    return row;
  });
}

/** Abgelaufene Weitergaben löschen (der Aufräum-Job). */
export async function purgePostfachTransfers(ctx: Pick<AuthContext, 'db' | 'now'>): Promise<number> {
  const gone = await ctx.db.delete(ingestPostfachTransfers).where(lt(ingestPostfachTransfers.expiresAt, ctx.now())).returning({ userId: ingestPostfachTransfers.userId });
  return gone.length;
}
