// /api/v1/admin/*: Betreiber-Ansicht "Betrieb" (nur lesend). Sichtbar nur für Betreiber (Konto-Flag, siehe operator/service.ts); alle
// anderen Personen bekommen 404, ohne Sitzung 401. Gelesen wird fast alles; geschrieben wird nur Weniges (Anmeldesperre eines Kontos aufheben, die eigenen Warnungen
// ein- oder ausschalten), jeweils mit frischem Step-up und Protokoll. Keine Systembefehle, nie Geheimnisse oder Inhalte.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { AUDIT_CATEGORIES, CURSOR_FORMAT, listAudit } from '../operator/audit-view.js';
import { collectKeyStatus } from '../operator/key-status.js';
import { collectMembers, unlockMember } from '../operator/members.js';
import { setWarningsEnabled, type OperatorMonitor } from '../operator/monitor.js';
import type { Probes } from '../operator/probes.js';
import { requireOperator } from '../operator/service.js';
import { collectStatus, type OperatorStatus } from '../operator/status.js';
import type { WeatherService } from '../weather/service.js';
import { idParams, meta, parse, strictLimit } from './util.js';

/** Status wird kurz zwischengespeichert (die Abfrage geht auch an ntfy und TLS); "fresh" umgeht den Cache höchstens alle 5 Sekunden. */
const STATUS_CACHE_MS = 15_000;
const STATUS_FRESH_MIN_MS = 5_000;

const statusQuery = z.object({ fresh: z.literal('1').optional() }).strict();

const auditQuery = z
  .object({
    category: z.enum(AUDIT_CATEGORIES).default('alle'),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    cursor: z.string().regex(CURSOR_FORMAT).optional(),
  })
  .strict();

export function registerOperatorRoutes(app: FastifyInstance, config: Config, auth: Auth, weather: WeatherService | undefined, monitor: OperatorMonitor, probes?: Partial<Probes>): void {
  const ctx = auth.ctx;
  const limit = strictLimit(config);
  const cache = new Map<string, { at: number; value: OperatorStatus }>();

  // Status ohne Step-up (nur Zahlen und Zustände); die Abfrage geht auch an ntfy und TLS, daher streng begrenzt
  app.get('/api/v1/admin/status', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req));
    const q = parse(statusQuery, req.query);
    const now = ctx.now().getTime();
    const hit = cache.get(p.familyId);
    const maxAge = q.fresh ? STATUS_FRESH_MIN_MS : STATUS_CACHE_MS;
    if (hit && now - hit.at >= 0 && now - hit.at < maxAge) return hit.value;
    const value = await collectStatus({ ctx, weather, probes }, p.familyId);
    cache.set(p.familyId, { at: now, value });
    return value;
  });

  // Das Protokoll nennt Personen und Netze: nur mit frischer Bestätigung (Step-up)
  app.get('/api/v1/admin/audit', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    return listAudit(ctx, p.familyId, parse(auditQuery, req.query));
  });

  // Schlüssel-Ampel je Person (nur Zustände und Zeiten, keine Geheimnisse; Namen der Familie kennt jedes Mitglied ohnehin)
  app.get('/api/v1/admin/key-status', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req));
    return collectKeyStatus(ctx, p.familyId);
  });

  // Mitglieder und Geräte (Gerätenamen, Versionen, letzte Anmeldung): wie das Protokoll nur mit frischem Step-up
  app.get('/api/v1/admin/members', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    return collectMembers(ctx, p);
  });

  // Anmeldesperre des Kontos aufheben (einzige schreibende Aktion über Mitglieder; Step-up, Protokoll)
  app.post('/api/v1/admin/members/:id/unlock', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    return unlockMember(ctx, p, parse(idParams, req.params).id, meta(req));
  });

  // Warnungen: Stand lesen (ohne Step-up; die App fragt es nach einem Wecker ab) und die eigenen Warnungen ein-/ausschalten (mit Step-up)
  app.get('/api/v1/admin/warnings', limit, async (req) => monitor.view(await requireOperator(ctx, await auth.requireSession(req))));
  app.put('/api/v1/admin/warnings', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    const body = parse(z.object({ enabled: z.boolean() }).strict(), req.body);
    await setWarningsEnabled(ctx, p, body.enabled, meta(req));
    return monitor.view(p);
  });
}
