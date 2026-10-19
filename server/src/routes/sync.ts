// POST /api/v1/sync: Ops hochladen, Änderungen seit sinceRev abholen (Protokoll: docs/API.md). Fachlogik in src/sync/.
import { and, eq, isNull } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { devices } from '../db/schema.js';
import { AppError } from '../errors.js';
import { applyOp, toConflicts } from '../sync/engine.js';
import { defaultRegistry } from '../sync/index.js';
import { pullChanges } from '../sync/pull.js';
import type { Registry } from '../sync/registry.js';
import { DEFAULT_PAGE, opEnvelope, opList, syncHead, type ConflictOut, type RejectCode, type SyncResponse } from '../sync/types.js';
import { parse } from './util.js';

export function registerSyncRoutes(app: FastifyInstance, config: Config, auth: Auth, registry: Registry = defaultRegistry): void {
  const ctx = auth.ctx;
  app.post(
    '/api/v1/sync',
    // Body höchstens 1 MB (auch global), eigenes Anfragelimit je IP; Inhalte werden nie geloggt
    { bodyLimit: 1024 * 1024, config: { rateLimit: { max: config.syncRateLimitMax, timeWindow: '1 minute' } } },
    async (req, reply): Promise<SyncResponse> => {
      const p = await auth.requireSession(req);
      if (typeof req.body !== 'object' || req.body === null || Array.isArray(req.body)) throw new AppError(400, 'invalid_request');
      const { ops: rawOps, ...rest } = req.body as Record<string, unknown>;
      const head = parse(syncHead, rest);
      const ops = opList.parse(rawOps ?? []);
      if (head.protocolVersion < config.minProtocolVersion) {
        throw new AppError(426, 'update_required', 'Bitte aktualisiere die App.');
      }
      // Familie und Rolle kommen aus der Sitzung, das Gerät muss zur Sitzung passen (nie Angaben des Clients vertrauen)
      if (!p.deviceId || p.deviceId !== head.deviceId) throw new AppError(409, 'device_mismatch', 'Dieses Gerät passt nicht zur Sitzung.');
      const actor = { userId: p.userId, role: p.role };

      const acked: string[] = [];
      const rejected: SyncResponse['rejected'] = [];
      const conflicts: ConflictOut[] = [];
      let newest: number | null = null;
      for (const raw of ops) {
        const parsed = opEnvelope.safeParse(raw);
        if (!parsed.success) {
          // ohne gültige opId lässt sich nichts bestätigen oder ablehnen: der Client hat einen Fehler
          const opId = typeof raw === 'object' && raw !== null ? (raw as { opId?: unknown }).opId : undefined;
          if (typeof opId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(opId)) throw new AppError(400, 'invalid_request');
          rejected.push({ opId, code: 'invalid' });
          continue;
        }
        const op = parsed.data;
        const done = await applyOp(ctx, registry, { actor, familyId: p.familyId, deviceId: p.deviceId, op });
        if (done.outcome.status === 'acked') {
          acked.push(op.opId);
          conflicts.push(...toConflicts(op, done.outcome));
        } else {
          rejected.push({ opId: op.opId, code: (done.outcome.code ?? 'invalid') as RejectCode });
        }
        if (done.committedRev !== null) newest = Math.max(newest ?? 0, done.committedRev);
      }
      // nach dem Commit: alle Geräte der Familie erfahren die neue Revision (ohne Inhalt)
      if (newest !== null) ctx.onRev(p.familyId, newest);

      const pulled = await pullChanges(ctx, registry, { actor, familyId: p.familyId, sinceRev: head.sinceRev, limit: head.limit ?? DEFAULT_PAGE });
      const now = ctx.now();
      await ctx.db
        .update(devices)
        .set({ ...(pulled.status === 'ok' ? { lastRev: head.sinceRev } : {}), lastSeenAt: now })
        .where(and(eq(devices.id, p.deviceId), eq(devices.familyId, p.familyId), isNull(devices.revokedAt)));
      reply.header('cache-control', 'no-store');
      return { ...pulled, acked, rejected, conflicts, serverTime: now.toISOString() };
    },
  );
}
