// /api/v1/admin/*: Betreiber-Ansicht "Betrieb" (nur lesend). Sichtbar nur für Betreiber (Konto-Flag, siehe operator/service.ts); alle
// anderen Personen bekommen 404, ohne Sitzung 401. Keine Schreibzugriffe, keine Systembefehle, nie Geheimnisse oder Inhalte.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { AUDIT_CATEGORIES, CURSOR_FORMAT, listAudit } from '../operator/audit-view.js';
import type { Probes } from '../operator/probes.js';
import { requireOperator } from '../operator/service.js';
import { collectStatus } from '../operator/status.js';
import type { WeatherService } from '../weather/service.js';
import { parse, strictLimit } from './util.js';

const auditQuery = z
  .object({
    category: z.enum(AUDIT_CATEGORIES).default('alle'),
    limit: z.coerce.number().int().min(1).max(100).default(50),
    cursor: z.string().regex(CURSOR_FORMAT).optional(),
  })
  .strict();

export function registerOperatorRoutes(app: FastifyInstance, config: Config, auth: Auth, weather: WeatherService | undefined, probes?: Partial<Probes>): void {
  const ctx = auth.ctx;
  const limit = strictLimit(config);

  // Status ohne Step-up (nur Zahlen und Zustände); die Abfrage geht auch an ntfy und TLS, daher streng begrenzt
  app.get('/api/v1/admin/status', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req));
    return collectStatus({ ctx, weather, probes }, p.familyId);
  });

  // Das Protokoll nennt Personen und Netze: nur mit frischer Bestätigung (Step-up)
  app.get('/api/v1/admin/audit', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    return listAudit(ctx, p.familyId, parse(auditQuery, req.query));
  });
}
