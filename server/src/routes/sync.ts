// POST /api/v1/sync: Ops hochladen, Änderungen seit sinceRev abholen (Protokoll: docs/API.md). Fachlogik in src/sync/.
import { and, count, eq, gt, isNull, sql } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import type { Role } from '../auth/types.js';
import { appliedOps, devices } from '../db/schema.js';
import { AppError } from '../errors.js';
import { applyOp, toConflicts } from '../sync/engine.js';
import { defaultRegistry } from '../sync/index.js';
import { SyncLimiter } from '../sync/limits.js';
import { pullChanges } from '../sync/pull.js';
import type { Registry } from '../sync/registry.js';
import { DEFAULT_PAGE, opEnvelope, opList, syncHead, type ConflictOut, type RejectCode, type SyncResponse } from '../sync/types.js';
import { parse } from './util.js';

export function registerSyncRoutes(app: FastifyInstance, config: Config, auth: Auth, registry: Registry = defaultRegistry): void {
  const ctx = auth.ctx;
  const limiter = new SyncLimiter(config, () => ctx.now().getTime());
  const timeouts = { lockMs: config.syncLockTimeoutMs, statementMs: config.syncStatementTimeoutMs };
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

      // Mengenbegrenzung je Gerät und Person (Anfragen und Ops), danach Tagesobergrenze je Gerät; nichts wird halb verarbeitet
      const wait = limiter.check(p.deviceId, p.userId, ops.length);
      if (wait !== null) throw new AppError(429, 'rate_limited', undefined, { 'retry-after': String(wait) });
      if (ops.length > 0) {
        const since = new Date(ctx.now().getTime() - 86_400_000);
        const [used] = await ctx.db
          .select({ n: count() })
          .from(appliedOps)
          .where(and(eq(appliedOps.deviceId, p.deviceId), gt(appliedOps.createdAt, since)));
        if ((used?.n ?? 0) + ops.length > config.syncOpsPerDay) throw new AppError(429, 'rate_limited', undefined, { 'retry-after': '3600' });
      }
      const [device] = await ctx.db
        .select({ resync: devices.resyncRequired })
        .from(devices)
        .where(and(eq(devices.id, p.deviceId), eq(devices.familyId, p.familyId), isNull(devices.revokedAt)));
      const resyncRequired = device?.resync === true;

      const acked: string[] = [];
      const rejected: SyncResponse['rejected'] = [];
      const conflicts: ConflictOut[] = [];
      let newest: number | null = null;
      const roles = new Set<Role>();
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
        const done = await applyOp(ctx, registry, { actor, familyId: p.familyId, deviceId: p.deviceId, op, timeouts });
        if (done.outcome.status === 'acked') {
          acked.push(op.opId);
          conflicts.push(...toConflicts(op, done.outcome));
        } else {
          rejected.push({ opId: op.opId, code: (done.outcome.code ?? 'invalid') as RejectCode });
        }
        if (done.committedRev !== null) {
          newest = Math.max(newest ?? 0, done.committedRev);
          for (const r of done.outcome.roles ?? (['admin', 'parent', 'child'] as const)) roles.add(r);
        }
      }
      // nach dem Commit: die Geräte der Familie, deren Rolle die Änderung sieht, erfahren die neue Revision (ohne Inhalt)
      if (newest !== null) ctx.onRev(p.familyId, newest, [...roles]);

      const pulled = await pullChanges(ctx, registry, { actor, familyId: p.familyId, sinceRev: head.sinceRev, limit: head.limit ?? DEFAULT_PAGE,
        snapshotRev: head.snapshotRev,
        forceResync: resyncRequired && head.sinceRev > 0,
      });
      const now = ctx.now();
      // last_rev (Stand, den das Gerät sicher kennt) nur bei normalen Läufen und beim Start eines Snapshots; Folgeseiten eines Snapshots
      // zählen nicht (der Cursor ist kein vollständiger Stand)
      const snapshotPage = head.sinceRev > 0 && head.snapshotRev !== undefined && head.snapshotRev > head.sinceRev;
      await ctx.db
        .update(devices)
        .set({ ...(pulled.status === 'ok' && !snapshotPage ? { lastRev: head.sinceRev } : {}), lastSeenAt: now })
        .where(and(eq(devices.id, p.deviceId), eq(devices.familyId, p.familyId), isNull(devices.revokedAt)));
      // Neustart (sinceRev 0) erledigt die erzwungene Neusynchronisierung, aber nur, wenn die Rolle unverändert ist
      if (resyncRequired && head.sinceRev === 0 && pulled.status === 'ok') {
        await ctx.db
          .update(devices)
          .set({ resyncRequired: false })
          .where(
            and(
              eq(devices.id, p.deviceId),
              sql`exists (select 1 from memberships m where m.family_id = ${p.familyId} and m.user_id = ${p.userId} and m.role = ${p.role} and m.status = 'active')`,
            ),
          );
      }
      reply.header('cache-control', 'no-store');
      return { ...pulled, acked, rejected, conflicts, serverTime: now.toISOString() };
    },
  );
}
