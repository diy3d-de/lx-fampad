// /api/v1/me/push: UnifiedPush-Endpunkt des eigenen Geräts (Wecker ohne Inhalt). Gehört immer zum Gerät der Sitzung, nie zu einem fremden.
import { and, eq, ne } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { pushEndpoints } from '../db/schema.js';
import { AppError } from '../errors.js';
import { topicFromEndpoint } from '../push/endpoint.js';
import type { PushService } from '../push/service.js';
import { ALERT_KINDS, kindsToMask } from '../weather/alerts.js';
import { parse, strictLimit } from './util.js';

function isUniqueViolation(err: unknown): boolean {
  const e = err as { code?: string; cause?: { code?: string } } | null;
  return e?.code === '23505' || e?.cause?.code === '23505';
}

export function registerPushRoutes(app: FastifyInstance, config: Config, auth: Auth, push: PushService): void {
  const ctx = auth.ctx;
  const strikt = strictLimit(config);

  /** Das Gerät der Sitzung; ohne Gerät (z. B. Cookie-Sitzung ohne Geräteeintrag) gibt es keinen Push. */
  const deviceOf = (p: { deviceId?: string | null }): string => {
    if (!p.deviceId) throw new AppError(409, 'no_device', 'Für diese Sitzung gibt es kein Gerät.');
    return p.deviceId;
  };

  app.get('/api/v1/me/push', async (req) => {
    const p = await auth.requireSession(req);
    const deviceId = deviceOf(p);
    const [row] = await ctx.db
      .select({ disabledAt: pushEndpoints.disabledAt, lastOkAt: pushEndpoints.lastOkAt, lastErrorAt: pushEndpoints.lastErrorAt })
      .from(pushEndpoints)
      .where(and(eq(pushEndpoints.deviceId, deviceId), eq(pushEndpoints.familyId, p.familyId)));
    return {
      available: push.enabled,
      server: `https://${config.ntfyPublicHost}`,
      registered: !!row,
      active: !!row && !row.disabledAt,
      lastOkAt: row?.lastOkAt ?? null,
      lastErrorAt: row?.lastErrorAt ?? null,
    };
  });

  // Endpunkt anmelden oder ersetzen (Topic-Rotation durch Neuanmeldung; ein deaktivierter Endpunkt wird wieder aktiv)
  app.put('/api/v1/me/push', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const deviceId = deviceOf(p);
    if (!push.enabled) throw new AppError(503, 'push_unavailable', 'Push ist auf dem Server nicht eingerichtet.');
    const body = parse(z.object({ endpoint: z.string().max(300) }).strict(), req.body);
    const topic = topicFromEndpoint(body.endpoint, config.ntfyPublicHost);
    if (!topic) throw new AppError(400, 'invalid_endpoint', 'Der Push-Endpunkt ist ungültig.');
    // ein Topic gehört genau einem Gerät (fremdes Topic kann nicht übernommen werden)
    const [taken] = await ctx.db.select({ d: pushEndpoints.deviceId }).from(pushEndpoints).where(and(eq(pushEndpoints.topic, topic), ne(pushEndpoints.deviceId, deviceId)));
    // fremdes Topic: Antwort wie bei ungültigem Endpunkt (verrät nicht, dass es das Topic gibt)
    if (taken) throw new AppError(400, 'invalid_endpoint', 'Der Push-Endpunkt ist ungültig.');
    const now = ctx.now();
    try {
      await ctx.db
        .insert(pushEndpoints)
        .values({ deviceId, familyId: p.familyId, topic, createdAt: now, updatedAt: now })
        .onConflictDoUpdate({
          target: pushEndpoints.deviceId,
          set: { topic, updatedAt: now, failCount: 0, disabledAt: null, lastErrorAt: null, lastOkAt: null },
        });
    } catch (err: unknown) {
      if (isUniqueViolation(err)) throw new AppError(400, 'invalid_endpoint', 'Der Push-Endpunkt ist ungültig.');
      throw err;
    }
    return { ok: true };
  });

  app.delete('/api/v1/me/push', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const deviceId = deviceOf(p);
    await ctx.db.delete(pushEndpoints).where(and(eq(pushEndpoints.deviceId, deviceId), eq(pushEndpoints.familyId, p.familyId)));
    return { ok: true };
  });

  // Wetter-Hinweise per Wecker: welche Arten dieses Gerät will (nur das Gerät der Sitzung; [] = aus). Der Server merkt sich nur "Gerät will Art X",
  // nie Inhalte oder Standort. Ohne angemeldeten Push-Endpunkt gibt es nichts zu wecken (409); die Wünsche erlöschen mit dem Endpunkt.
  app.put('/api/v1/me/weather-alerts', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const deviceId = deviceOf(p);
    const body = parse(z.object({ kinds: z.array(z.enum(ALERT_KINDS)).max(ALERT_KINDS.length) }).strict(), req.body);
    if (!config.weather.enabled) throw new AppError(503, 'weather_unavailable', 'Das Wetter ist auf dem Server nicht eingerichtet.');
    const mask = kindsToMask([...new Set(body.kinds)]);
    const rows = await ctx.db
      .update(pushEndpoints)
      .set({ weatherKinds: mask })
      .where(and(eq(pushEndpoints.deviceId, deviceId), eq(pushEndpoints.familyId, p.familyId)))
      .returning({ d: pushEndpoints.deviceId });
    if (rows.length === 0) throw new AppError(409, 'no_endpoint', 'Für dieses Gerät ist Push nicht angemeldet.');
    return { ok: true };
  });

  // Test-Wecker an das eigene Gerät; die App zeigt, ob etwas ankommt
  app.post('/api/v1/me/push/test', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const result = await push.sendeTest(deviceOf(p), p.familyId);
    if (result === 'rate_limited') throw new AppError(429, 'rate_limited', undefined, { 'retry-after': '10' });
    if (result === 'push_off') throw new AppError(503, 'push_unavailable', 'Push ist auf dem Server nicht eingerichtet.');
    if (result === 'no_endpoint') throw new AppError(409, 'no_endpoint', 'Für dieses Gerät ist Push nicht angemeldet.');
    return { result };
  });
}
