// /api/v1/waste: Abfuhrtermine für angemeldete Mitglieder (auch Kinder) und „Jetzt prüfen“ für Eltern/Admins. Der API-Dienst ruft
// nie bei Dritten ab: die Route liest nur aus der Datenbank bzw. setzt eine Prüf-Anforderung, die der Dienst lx-fampad-waste abholt.
// Ist die Funktion aus (WASTE_ENABLED), antwortet sie mit 404. Antworten enthalten nie die Quelle, Straße, UID oder Fehlertexte.
import { createHash } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { writeAudit } from '../auth/audit.js';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { AppError } from '../errors.js';
import type { WasteService } from '../waste/service.js';
import { meta, strictLimit } from './util.js';

export function registerWasteRoutes(app: FastifyInstance, config: Config, auth: Auth, waste: WasteService): void {
  const strikt = strictLimit(config);

  app.get('/api/v1/waste', async (req, reply) => {
    const p = await auth.requireSession(req);
    if (!waste.enabled || p.familyId !== (await waste.servedFamilyId())) throw new AppError(404, 'not_found');
    const view = await waste.view(p.familyId);
    const etag = `"w-${createHash('sha256').update(JSON.stringify(view)).digest('hex').slice(0, 24)}"`;
    const headers = { etag, 'cache-control': 'private, no-cache', vary: 'Authorization, Cookie' };
    const inm = req.headers['if-none-match'];
    if (typeof inm === 'string' && inm.split(',').some((t) => t.trim() === etag || t.trim() === `W/${etag}`)) return reply.code(304).headers(headers).send();
    return reply.headers(headers).send(view);
  });

  // Rechte nur über die Rolle (admin/parent), nie über die Familienrolle. Kein Step-up: setzt nur eine Anforderung.
  app.post('/api/v1/waste/check', strikt, async (req, reply) => {
    const p = await auth.requireSession(req);
    // nur die Familie, die der Dienst bedient (der Server hält Müll-Daten für genau eine Familie): jede andere = 404
    if (!waste.enabled || p.familyId !== (await waste.servedFamilyId())) throw new AppError(404, 'not_found');
    if (p.role !== 'admin' && p.role !== 'parent') throw new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
    const r = await waste.requestCheck(p.familyId);
    if (!r.ok) {
      throw new AppError(429, 'rate_limited', 'Bitte etwas später erneut versuchen.', { 'retry-after': String(r.retryAfterSec) }, { retryAfterSec: r.retryAfterSec });
    }
    await writeAudit(auth.ctx, auth.ctx.db, { event: 'waste_check_requested', familyId: p.familyId, actorId: p.userId, ip: meta(req).ip });
    return reply.code(202).send({ ok: true });
  });
}
