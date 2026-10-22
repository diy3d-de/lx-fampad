// /api/v1/admin/*: Betreiber-Ansicht "Betrieb" (nur lesend). Sichtbar nur für Betreiber (Konto-Flag, siehe operator/service.ts); alle
// anderen Personen bekommen 404, ohne Sitzung 401. Gelesen wird fast alles; geschrieben wird nur Weniges (Anmeldesperre eines Kontos aufheben, die eigenen Warnungen
// ein- oder ausschalten), jeweils mit frischem Step-up und Protokoll. Keine Systembefehle, nie Geheimnisse oder Inhalte.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { AUDIT_CATEGORIES, CURSOR_FORMAT, listAudit } from '../operator/audit-view.js';
import { collectConfig } from '../operator/config-view.js';
import { collectKeyStatus, summarize } from '../operator/key-status.js';
import { listMetrics, METRICS_MAX_DAYS } from '../operator/metrics.js';
import type { MaintenanceGate } from '../operator/maintenance.js';
import { collectMembers, unlockMember } from '../operator/members.js';
import { setWarningsEnabled, type OperatorMonitor } from '../operator/monitor.js';
import type { Probes } from '../operator/probes.js';
import { requireOperator } from '../operator/service.js';
import { getSettings, setMaintenance, setNotice } from '../operator/settings.js';
import { collectStatus, readAppReference, type OperatorStatus } from '../operator/status.js';
import type { WeatherService } from '../weather/service.js';
import { idParams, meta, parse, safeString, strictLimit } from './util.js';

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

const maintenanceBody = z.object({ active: z.boolean(), untilMinutes: z.number().int().nullable().optional() }).strict();
const noticeBody = z.object({ text: safeString().max(2000).nullable(), expiresInMinutes: z.number().int().nullable().optional() }).strict();

export function registerOperatorRoutes(
  app: FastifyInstance,
  config: Config,
  auth: Auth,
  weather: WeatherService | undefined,
  monitor: OperatorMonitor,
  gate: MaintenanceGate,
  probes?: Partial<Probes>,
): void {
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

  // Nutzung und Verlauf (Paket 3): tägliche Messpunkte, nur Zahlen (aktive Personen und Geräte, Zähler, Größen), ohne Step-up (keine Namen, keine Inhalte)
  app.get('/api/v1/admin/metrics', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req));
    const q = parse(z.object({ days: z.coerce.number().int().min(1).max(METRICS_MAX_DAYS).default(90) }).strict(), req.query);
    return listMetrics(ctx, p.familyId, q.days);
  });

  // Konfiguration (Paket 2b): nur sichere Ausschnitte (Schalter, Limits), nie Geheimnisse; nur lesend, ohne Step-up (keine Personen, keine Adressen mit Zugangsdaten)
  app.get('/api/v1/admin/config', limit, async (req) => {
    await requireOperator(ctx, await auth.requireSession(req));
    return collectConfig(config);
  });

  // Wartungsmodus und Familienhinweis (Paket 2b): Stand lesen ohne Step-up, Schalten und Setzen mit frischem Step-up; jeweils ins Audit-Log
  app.get('/api/v1/admin/settings', limit, async (req) => getSettings(ctx, (await requireOperator(ctx, await auth.requireSession(req))).familyId));
  app.put('/api/v1/admin/maintenance', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    const body = parse(maintenanceBody, req.body);
    return setMaintenance(ctx, gate, p, { active: body.active, minutes: body.untilMinutes ?? null }, meta(req));
  });
  app.put('/api/v1/admin/notice', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    const body = parse(noticeBody, req.body);
    return setNotice(ctx, p, { text: body.text, expiresInMinutes: body.expiresInMinutes ?? null }, meta(req));
  });

  // Für ALLE angemeldeten Mitglieder (kein Betreiber nötig): Wartung und Familienhinweis, die die App als Banner bzw. Meldung zeigt. Reiner Text, keine Personen.
  app.get('/api/v1/family-notice', async (req) => getSettings(ctx, (await auth.requireSession(req)).familyId));

  // Das Protokoll nennt Personen und Netze: nur mit frischer Bestätigung (Step-up)
  app.get('/api/v1/admin/audit', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    return listAudit(ctx, p.familyId, parse(auditQuery, req.query));
  });

  // Schlüssel-Ampel: `?summary=1` liefert nur die Zähler (grün/gelb/rot, bereit) ohne Namen und Ereignisse und braucht kein Step-up (Übersicht); die Einzelheiten je Person
  // (Namen, Wege, Ereignisse) nur mit frischem Step-up. Nie Geheimnisse.
  app.get('/api/v1/admin/key-status', limit, async (req) => {
    const q = parse(z.object({ summary: z.literal('1').optional() }).strict(), req.query);
    const p = await requireOperator(ctx, await auth.requireSession(req), q.summary ? {} : { stepUp: true });
    const k = await collectKeyStatus(ctx, p.familyId);
    return q.summary ? summarize(k) : k;
  });

  // Mitglieder und Geräte (Gerätenamen, Versionen, letzte Anmeldung): wie das Protokoll nur mit frischem Step-up
  app.get('/api/v1/admin/members', limit, async (req) => {
    const p = await requireOperator(ctx, await auth.requireSession(req), { stepUp: true });
    return collectMembers(ctx, p, await readAppReference(config, probes));
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
