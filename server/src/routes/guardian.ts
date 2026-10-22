// Eltern-Wiederherstellung für Kinder (Schalter E2EE_PARENT_RECOVERY, sonst gibt es die Routen nicht: 404). Fachlogik in src/auth/guardian-recovery.ts; hier nur Form und Größe
// der Eingaben (alles Undurchsichtige bleibt für den Server undurchsichtig) und die Verdrahtung.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import {
  cancelRecovery,
  challengeRecovery,
  createRecovery,
  declineRecovery,
  doneRecovery,
  getEscrowStatus,
  getMyRecovery,
  guardianOverview,
  MAX_GUARDIANS,
  releaseRecovery,
  removeEscrow,
  revealRecovery,
  setEscrow,
} from '../auth/guardian-recovery.js';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { b64urlBlobMin, b64urlKey, idParams, meta, parse, strictLimit, uuid } from './util.js';

export function registerGuardianRoutes(app: FastifyInstance, config: Config, auth: Auth): void {
  if (!config.e2eeParentRecovery) return;
  const ctx = auth.ctx;
  const strikt = strictLimit(config);

  // ----- Kind: Hinterlegung -----
  app.get('/api/v1/me/guardian-escrow', async (req) => getEscrowStatus(ctx, await auth.requireSession(req)));

  const entry = z
    .object({ guardianId: uuid, guardianKeyVersion: z.number().int().min(1), blob: b64urlBlobMin(64, 2048), sig: b64urlBlobMin(64, 256) })
    .strict();
  app.put('/api/v1/me/guardian-escrow', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ keyVersion: z.number().int().min(1), entries: z.array(entry).min(1).max(MAX_GUARDIANS) }).strict(), req.body);
    return { ok: true, ...(await setEscrow(ctx, p, body, meta(req))) };
  });
  app.delete('/api/v1/me/guardian-escrow', strikt, async (req) => {
    const p = await auth.requireSession(req);
    return { ok: true, ...(await removeEscrow(ctx, p, meta(req))) };
  });

  // ----- Kind: Anfrage -----
  app.post('/api/v1/me/guardian-recovery', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const body = parse(z.object({ commit: b64urlKey }).strict(), req.body);
    return { recovery: await createRecovery(ctx, p, body, meta(req)) };
  });
  app.get('/api/v1/me/guardian-recovery', async (req) => ({ recovery: await getMyRecovery(ctx, await auth.requireSession(req)) }));
  app.post('/api/v1/me/guardian-recovery/:id/reveal', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    await revealRecovery(ctx, p, id, parse(z.object({ pub: b64urlKey, nonce: b64urlBlobMin(16, 64), challenge: b64urlBlobMin(16, 64).optional() }).strict(), req.body), meta(req));
    return { ok: true };
  });
  app.post('/api/v1/me/guardian-recovery/:id/cancel', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await cancelRecovery(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });
  app.post('/api/v1/me/guardian-recovery/:id/done', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await doneRecovery(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });

  // ----- Eltern -----
  app.get('/api/v1/guardian/recoveries', async (req) => guardianOverview(ctx, await auth.requireSession(req)));
  app.post('/api/v1/guardian/recoveries/:id/challenge', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    await challengeRecovery(ctx, p, id, parse(z.object({ challenge: b64urlBlobMin(16, 64) }).strict(), req.body), meta(req));
    return { ok: true };
  });
  app.post('/api/v1/guardian/recoveries/:id/release', strikt, async (req) => {
    const p = await auth.requireSession(req);
    const { id } = parse(idParams, req.params);
    await releaseRecovery(ctx, p, id, parse(z.object({ blob: b64urlBlobMin(64, 2048), sig: b64urlBlobMin(64, 256) }).strict(), req.body), meta(req));
    return { ok: true };
  });
  app.post('/api/v1/guardian/recoveries/:id/decline', strikt, async (req) => {
    const p = await auth.requireSession(req);
    await declineRecovery(ctx, p, parse(idParams, req.params).id, meta(req));
    return { ok: true };
  });
}
