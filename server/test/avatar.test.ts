// Benutzerbild: Magic-Bytes, Größenlimit, SVG-Ablehnung, Platzhalter, Familiengrenze (IDOR), ETag, Rechte, Rate-Limit, Metadaten in /me und /members.
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { AVATAR_MAX_BYTES, AVATAR_PRESETS, inspectImage } from '../src/avatar/image.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, backends, type Client, World, type Harness } from './helpers.js';

// ---- synthetische Bilddateien (nur der Kopf zählt: der Server dekodiert nichts) ----
function png(w: number, h: number, pad = 0): Buffer {
  const head = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(head, 0);
  head.writeUInt32BE(13, 8);
  head.write('IHDR', 12, 'latin1');
  head.writeUInt32BE(w, 16);
  head.writeUInt32BE(h, 20);
  return Buffer.concat([head, Buffer.alloc(pad, 1)]);
}
function jpeg(w: number, h: number): Buffer {
  const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  const sof = Buffer.from([0xff, 0xc0, 0x00, 0x0b, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x01, 0x01, 0x11, 0x00]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, sof, Buffer.from([0xff, 0xd9])]);
}
function webpLossless(w: number, h: number): Buffer {
  const b = Buffer.alloc(30);
  b.write('RIFF', 0, 'latin1');
  b.writeUInt32LE(22, 4);
  b.write('WEBP', 8, 'latin1');
  b.write('VP8L', 12, 'latin1');
  b.writeUInt32LE(10, 16);
  b[20] = 0x2f;
  b.writeUInt32LE(((w - 1) & 0x3fff) | (((h - 1) & 0x3fff) << 14), 21);
  return b;
}
const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script></svg>');

describe('Bild-Prüfung', () => {
  it('erkennt PNG, JPEG, WebP und liest die Maße', () => {
    expect(inspectImage(png(512, 256))).toEqual({ mime: 'image/png', width: 512, height: 256 });
    expect(inspectImage(jpeg(300, 200))).toEqual({ mime: 'image/jpeg', width: 300, height: 200 });
    expect(inspectImage(webpLossless(400, 400))).toEqual({ mime: 'image/webp', width: 400, height: 400 });
  });
  it('lehnt SVG, Text, zu große und kaputte Köpfe ab', () => {
    expect(inspectImage(svg)).toBeNull();
    expect(inspectImage(Buffer.from('GIF89a' + 'x'.repeat(40)))).toBeNull();
    expect(inspectImage(png(1025, 10))).toBeNull();
    expect(inspectImage(png(0, 10))).toBeNull();
    expect(inspectImage(jpeg(2000, 10))).toBeNull();
    expect(inspectImage(png(10, 10).subarray(0, 20))).toBeNull();
    expect(inspectImage(jpeg(10, 10).subarray(0, 12))).toBeNull();
  });
});

describe.each(backends)('Benutzerbild ($name)', (backend) => {
  let harness: Harness;
  let world: World;

  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  beforeEach(async () => {
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db);
  });

  const upload = (c: Client, body: Buffer | undefined, type: string, url = '/api/v1/me/avatar') =>
    c.request('PUT', url, { ...(body ? { body } : {}), headers: { 'content-type': type } });
  const idOf = async (email: string) => (await harness.db.select().from(schema.users).where(eq(schema.users.email, email)))[0]?.id ?? '';
  /** Rohe Anfrage mit den Anmeldedaten des Clients (Cookie oder Bearer), für Binär-Antworten. */
  const raw = (c: Client, url: string, headers: Record<string, string> = {}) =>
    world.app.inject({ method: 'GET', url, headers: { ...(c.bearer ? { authorization: `Bearer ${c.bearer}` } : {}), ...(c.cookie ? { cookie: c.cookie } : {}), 'x-forwarded-for': '203.0.113.10', ...headers } });
  const bearerGet = (c: Client, url: string, headers: Record<string, string> = {}) => c.get(url, { headers });

  async function familie() {
    const a = await adminPassword(world);
    const mama = await addMember(world, a.client, 'parent', 'mama@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    return { a, mama, kind };
  }

  it('Platzhalter wählen: alle zehn gültigen Kennungen; ungültige, fremde Felder und falsche Typen werden abgelehnt', async () => {
    const { mama } = await familie();
    for (const id of AVATAR_PRESETS) {
      const res = await mama.client.request('PUT', '/api/v1/me/avatar', { body: { preset: id } });
      expect(res.status, id).toBe(200);
      expect(res.json.avatar).toMatchObject({ kind: 'preset', id });
    }
    for (const bad of [{ preset: 'V99' }, { preset: '../../x' }, { preset: 'v01' }, { preset: 1 }, {}, { preset: 'V01', extra: 1 }, { preset: 'V01'.repeat(5) }]) {
      const res = await mama.client.request('PUT', '/api/v1/me/avatar', { body: bad });
      expect(res.status, JSON.stringify(bad)).toBe(400);
    }
    // der letzte gültige Stand bleibt
    const me = await mama.client.get('/api/v1/me');
    expect(me.json.user.avatar).toMatchObject({ kind: 'preset', id: 'K13' });
  });

  it('Foto: PNG/JPEG/WebP werden gespeichert und mit festem Content-Type und Schutz-Headern ausgeliefert', async () => {
    const { mama, kind } = await familie();
    const mamaId = await idOf('mama@example.org');
    for (const [body, type] of [
      [png(512, 512, 100), 'image/png'],
      [jpeg(512, 512), 'image/jpeg'],
      [webpLossless(512, 512), 'image/webp'],
    ] as const) {
      const res = await upload(mama.client, body, type);
      expect(res.status, type).toBe(200);
      expect(res.json.avatar.kind).toBe('photo');
      // ein anderes Mitglied derselben Familie darf es abrufen
      const get = await raw(kind.client, `/api/v1/members/${mamaId}/avatar`);
      expect(get.statusCode, type).toBe(200);
      expect(get.headers['content-type']).toBe(type);
      expect(get.headers['x-content-type-options']).toBe('nosniff');
      expect(String(get.headers['cache-control'])).toContain('private');
      expect(String(get.headers['content-security-policy'])).toContain("default-src 'none'");
      expect(Buffer.compare(get.rawPayload, body)).toBe(0);
    }
    expect(await world.count('user_avatars')).toBe(1);
  });

  it('lehnt SVG, andere Typen, Typ-Täuschung, zu große Maße und leere Bilder ab', async () => {
    const { mama } = await familie();
    expect((await upload(mama.client, svg, 'image/svg+xml')).status).toBe(415);
    expect((await upload(mama.client, Buffer.from('GIF89a' + 'x'.repeat(40)), 'image/gif')).status).toBe(415);
    expect((await upload(mama.client, svg, 'text/plain')).status).toBe(415);
    // SVG als PNG getarnt: Magic-Bytes entscheiden
    expect((await upload(mama.client, svg, 'image/png')).json.error).toBe('invalid_image');
    // PNG-Inhalt mit JPEG-Etikett
    expect((await upload(mama.client, png(100, 100), 'image/jpeg')).status).toBe(400);
    // Maße über 1024
    expect((await upload(mama.client, png(1025, 100), 'image/png')).status).toBe(400);
    expect((await upload(mama.client, jpeg(4000, 3000), 'image/jpeg')).status).toBe(400);
    // leer
    expect((await upload(mama.client, undefined, 'image/png')).status).toBe(400);
    expect(await world.count('user_avatars')).toBe(0);
  });

  it('Größenlimit 512 KB gilt hart für diese Route (413), knapp darunter geht', async () => {
    const { mama } = await familie();
    const ok = await upload(mama.client, png(512, 512, AVATAR_MAX_BYTES - 33), 'image/png');
    expect(ok.status).toBe(200);
    const big = await upload(mama.client, png(512, 512, AVATAR_MAX_BYTES), 'image/png');
    expect(big.status).toBe(413);
    // das gute Bild bleibt
    expect((await mama.client.get('/api/v1/me')).json.user.avatar.kind).toBe('photo');
    // das globale Limit (1 MB) für andere Routen bleibt unberührt
    const json = await mama.client.request('PUT', '/api/v1/me/avatar', { body: { preset: 'V01', pad: 'x'.repeat(AVATAR_MAX_BYTES) } });
    expect(json.status).toBe(413);
  });

  it('Platzhalter ersetzt das Foto und umgekehrt; Löschen entfernt die Bytes; die Version zählt hoch', async () => {
    const { mama } = await familie();
    const v = async () => (await mama.client.get('/api/v1/me')).json.user.avatar?.version as number | undefined;
    await upload(mama.client, png(64, 64), 'image/png');
    const v1 = await v();
    await mama.client.request('PUT', '/api/v1/me/avatar', { body: { preset: 'M01' } });
    expect(await world.count('user_avatars')).toBe(0);
    const v2 = await v();
    expect(v2).toBeGreaterThan(v1 ?? 0);
    await upload(mama.client, png(64, 64), 'image/png');
    expect(await world.count('user_avatars')).toBe(1);
    expect((await mama.client.del('/api/v1/me/avatar')).status).toBe(200);
    expect(await world.count('user_avatars')).toBe(0);
    expect((await mama.client.get('/api/v1/me')).json.user.avatar).toBeNull();
  });

  it('GET: ETag und If-None-Match (304), Platzhalter und fehlendes Bild ergeben 404, ohne Anmeldung 401', async () => {
    const { mama, kind } = await familie();
    const id = await idOf('mama@example.org');
    expect((await bearerGet(kind.client, `/api/v1/members/${id}/avatar`)).status).toBe(404);
    await upload(mama.client, png(64, 64), 'image/png');
    const first = await raw(kind.client, `/api/v1/members/${id}/avatar`);
    const etag = String(first.headers.etag);
    expect(etag).toMatch(/^"a\d+"$/);
    const again = await kind.client.get(`/api/v1/members/${id}/avatar`, { headers: { 'if-none-match': etag } });
    expect(again.status).toBe(304);
    // nach Änderung neuer ETag, alter liefert wieder 200
    await upload(mama.client, png(65, 65), 'image/png');
    const after = await kind.client.get(`/api/v1/members/${id}/avatar`, { headers: { 'if-none-match': etag } });
    expect(after.status).toBe(200);
    expect(String(after.headers.etag)).not.toBe(etag);
    // Platzhalter hat kein Foto
    await mama.client.request('PUT', '/api/v1/me/avatar', { body: { preset: 'M01' } });
    expect((await kind.client.get(`/api/v1/members/${id}/avatar`)).status).toBe(404);
    // ohne Anmeldung
    expect((await world.client().get(`/api/v1/members/${id}/avatar`)).status).toBe(401);
    expect((await world.client().request('PUT', '/api/v1/me/avatar', { body: { preset: 'V01' } })).status).toBe(401);
  });

  it('Familiengrenze (IDOR): fremde Familie und unbekannte Ids = 404; Admin darf nur eigene Familie zurücksetzen', async () => {
    const { a, mama, kind } = await familie();
    const [fam] = await harness.db.insert(schema.families).values({ name: 'Fremde Familie' }).returning();
    const [fremd] = await harness.db.insert(schema.users).values({ email: 'fremd@example.org', displayName: 'Fremd', avatarKind: 'photo', avatarVersion: 1 }).returning();
    if (!fam || !fremd) throw new Error('Setup');
    await harness.db.insert(schema.memberships).values({ familyId: fam.id, userId: fremd.id, role: 'admin' });
    await harness.db.insert(schema.userAvatars).values({ userId: fremd.id, contentType: 'image/png', width: 8, height: 8, data: png(8, 8) });
    for (const c of [a.client, mama.client, kind.client]) {
      expect((await c.get(`/api/v1/members/${fremd.id}/avatar`)).status).toBe(404);
      expect((await c.get('/api/v1/members/00000000-0000-4000-8000-000000000000/avatar')).status).toBe(404);
    }
    expect((await a.client.del(`/api/v1/members/${fremd.id}/avatar`)).status).toBe(404);
    expect(await world.count('user_avatars')).toBe(1);
    // /members zeigt Fremde nicht, auch keine Avatar-Daten
    expect(JSON.stringify((await a.client.get('/api/v1/members')).json)).not.toContain(fremd.id);
  });

  it('Rechte: PUT/DELETE wirken nur auf die eigene Person; Admin setzt fremdes Bild zurück, Eltern und Kinder nicht', async () => {
    const { a, mama, kind } = await familie();
    const kindId = await idOf('kind@example.org');
    await upload(kind.client, png(64, 64), 'image/png');
    // es gibt keine Route, mit der ein Mitglied das Bild eines anderen setzt
    expect((await upload(mama.client, png(64, 64), 'image/png', `/api/v1/members/${kindId}/avatar`)).status).toBe(404);
    expect((await mama.client.del(`/api/v1/members/${kindId}/avatar`)).status).toBe(403);
    expect((await kind.client.del(`/api/v1/members/${kindId}/avatar`)).status).toBe(403);
    expect(await world.count('user_avatars')).toBe(1);
    expect((await a.client.del(`/api/v1/members/${kindId}/avatar`)).status).toBe(200);
    expect(await world.count('user_avatars')).toBe(0);
    expect((await kind.client.get('/api/v1/me')).json.user.avatar).toBeNull();
  });

  it('/me und /members liefern die Bild-Metadaten (null, Platzhalter, Foto)', async () => {
    const { a, mama, kind } = await familie();
    await mama.client.request('PUT', '/api/v1/me/avatar', { body: { preset: 'M08' } });
    await upload(kind.client, png(64, 64), 'image/png');
    const list = (await a.client.get('/api/v1/members')).json.members as Array<{ email?: string; avatar: { kind: string; id?: string; version: number } | null }>;
    expect(list.find((m) => m.email === 'admin@example.org')?.avatar).toBeNull();
    expect(list.find((m) => m.email === 'mama@example.org')?.avatar).toMatchObject({ kind: 'preset', id: 'M08' });
    expect(list.find((m) => m.email === 'kind@example.org')?.avatar).toMatchObject({ kind: 'photo' });
    // Foto-Bytes stehen nie in den Metadaten
    expect(JSON.stringify(list)).not.toContain('data');
  });

  it('Datenbank: Prüfungen am Schema (Art/Platzhalter, Typ, Größe) und Kaskade beim Löschen der Person', async () => {
    const { mama } = await familie();
    const id = await idOf('mama@example.org');
    await expect(harness.db.update(schema.users).set({ avatarKind: 'photo', avatarPreset: 'V01' }).where(eq(schema.users.id, id))).rejects.toThrow();
    await expect(harness.db.update(schema.users).set({ avatarKind: 'preset', avatarPreset: null }).where(eq(schema.users.id, id))).rejects.toThrow();
    await expect(harness.db.insert(schema.userAvatars).values({ userId: id, contentType: 'image/svg+xml', width: 8, height: 8, data: svg })).rejects.toThrow();
    await expect(harness.db.insert(schema.userAvatars).values({ userId: id, contentType: 'image/png', width: 2000, height: 8, data: png(8, 8) })).rejects.toThrow();
    await upload(mama.client, png(64, 64), 'image/png');
    await harness.db.delete(schema.users).where(eq(schema.users.id, id));
    expect(await world.count('user_avatars')).toBe(0);
  });

  it('kein Bildinhalt im Log', async () => {
    const lines: string[] = [];
    const { Writable } = await import('node:stream');
    const w = await World.create(harness.db, { LOG_LEVEL: 'info' }, { logStream: new Writable({ write: (chunk, _e, cb) => (lines.push(String(chunk)), cb()) }) });
    try {
      const boot = await w.bootstrap();
      const reg = await w.registerPassword(boot.token, { email: 'log@example.org' });
      const body = png(64, 64, 200);
      const res = await upload(reg.client, body, 'image/png');
      expect(res.status).toBe(200);
      const log = lines.join('');
      expect(log).not.toContain(body.toString('base64'));
      expect(log).not.toContain(body.toString('latin1'));
    } finally {
      await w.close();
    }
  });
});

describe.each(backends)('Benutzerbild Rate-Limit ($name)', (backend) => {
  it('PUT ist strikt begrenzt (429)', async () => {
    const harness = await backend.open();
    const world = await World.create(harness.db, { AUTH_RATE_LIMIT_MAX: '4' });
    try {
      const a = await adminPassword(world);
      const codes: number[] = [];
      for (let i = 0; i < 8; i++) codes.push((await a.client.request('PUT', '/api/v1/me/avatar', { body: { preset: 'V01' } })).status);
      expect(codes).toContain(429);
      expect(codes[0]).toBe(200);
    } finally {
      await world.close();
      await harness.close();
    }
  });
});
