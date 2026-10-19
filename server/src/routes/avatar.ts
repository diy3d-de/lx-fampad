// Benutzerbild: PUT/DELETE /api/v1/me/avatar, GET /api/v1/members/:id/avatar, DELETE /api/v1/members/:id/avatar (Admin: zurücksetzen).
// Fachlogik in src/avatar/. Der Upload ist eine Binär-Anfrage (Content-Type image/png|jpeg|webp) mit hartem Größenlimit nur für diese Route.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { AVATAR_MAX_BYTES, AVATAR_MIMES, inspectImage, isAvatarPreset } from '../avatar/image.js';
import { assertMemberOfFamily, clearAvatar, loadPhoto, photoVersion, setPhoto, setPreset } from '../avatar/service.js';
import type { Auth } from '../auth/service.js';
import type { Config } from '../config.js';
import { AppError } from '../errors.js';
import { idParams, parse, strictLimit } from './util.js';

const presetBody = z.object({ preset: z.string().max(8) }).strict();

const etagOf = (version: number) => `"a${version}"`;

export function registerAvatarRoutes(app: FastifyInstance, config: Config, auth: Auth): void {
  const ctx = auth.ctx;
  const strikt = strictLimit(config);

  // eigener Kapselbereich: Binär-Parser (nur Bild-Typen) gelten nur hier, alles andere (auch SVG) endet mit 415
  void app.register(async (scope) => {
    scope.addContentTypeParser([...AVATAR_MIMES], { parseAs: 'buffer', bodyLimit: AVATAR_MAX_BYTES }, (_req, body, done) => done(null, body));

    // Platzhalter wählen (JSON {"preset":"V01"}) oder Foto hochladen (Rohbytes); nur die eigene Person
    scope.put('/api/v1/me/avatar', { ...strikt, bodyLimit: AVATAR_MAX_BYTES }, async (req) => {
      const p = await auth.requireSession(req);
      const type = (req.headers['content-type'] ?? '').split(';')[0]?.trim().toLowerCase() ?? '';
      if (type === 'application/json') {
        const { preset } = parse(presetBody, req.body);
        if (!isAvatarPreset(preset)) throw new AppError(400, 'invalid_request', 'Dieses Bild gibt es nicht.');
        return { avatar: await setPreset(ctx, p.userId, preset) };
      }
      if (!(AVATAR_MIMES as readonly string[]).includes(type)) throw new AppError(415, 'unsupported_media_type', 'Erlaubt sind PNG, JPEG und WebP.');
      const body = req.body;
      if (!Buffer.isBuffer(body) || body.length === 0) throw new AppError(400, 'invalid_image', 'Das Bild ist leer oder nicht lesbar.');
      // Maßgeblich sind die Magic-Bytes; der Content-Type muss dazu passen
      const info = inspectImage(body);
      if (!info || info.mime !== type) throw new AppError(400, 'invalid_image', 'Erlaubt sind PNG, JPEG und WebP bis 1024 x 1024 Pixel.');
      return { avatar: await setPhoto(ctx, p.userId, body, info) };
    });

    scope.delete('/api/v1/me/avatar', async (req) => {
      const p = await auth.requireSession(req);
      await clearAvatar(ctx, p.userId);
      return { ok: true };
    });

    // Admin setzt das Bild eines Mitglieds seiner Familie zurück (Initialen)
    scope.delete('/api/v1/members/:id/avatar', async (req) => {
      const p = await auth.requireSession(req);
      if (p.role !== 'admin') throw new AppError(403, 'forbidden', 'Dazu fehlt dir die Berechtigung.');
      const { id } = parse(idParams, req.params);
      await assertMemberOfFamily(ctx, p, id);
      await clearAvatar(ctx, id);
      return { ok: true };
    });

    // Foto eines Mitglieds derselben Familie; Platzhalter liefert der Server nicht (die Zeichnungen liegen in der App)
    scope.get('/api/v1/members/:id/avatar', async (req, reply) => {
      const p = await auth.requireSession(req);
      const { id } = parse(idParams, req.params);
      await assertMemberOfFamily(ctx, p, id);
      const version = await photoVersion(ctx, id);
      if (version === null) throw new AppError(404, 'not_found');
      const etag = etagOf(version);
      const headers = {
        etag,
        // nur im Cache des angemeldeten Geräts, jedes Mal per ETag neu geprüft
        'cache-control': 'private, no-cache',
        vary: 'Authorization, Cookie',
        'x-content-type-options': 'nosniff',
        'content-security-policy': "default-src 'none'; sandbox",
        'cross-origin-resource-policy': 'same-origin',
      };
      const inm = req.headers['if-none-match'];
      if (typeof inm === 'string' && inm.split(',').some((t) => t.trim() === etag || t.trim() === `W/${etag}`)) {
        return reply.code(304).headers(headers).send();
      }
      const photo = await loadPhoto(ctx, id);
      if (!photo) throw new AppError(404, 'not_found');
      return reply
        .code(200)
        .headers({ ...headers, etag: etagOf(photo.version), 'content-type': photo.contentType, 'content-disposition': 'inline; filename="avatar"' })
        .send(photo.data);
    });
  });
}
