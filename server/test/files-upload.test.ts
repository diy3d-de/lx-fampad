// Dateiablage: tus-Teilprotokoll, Kontingent, Mengenbegrenzung, Modi `server` und `e2ee`, Auslieferung (Header, Range), Unterbrechung beim Abschluss, Aufräumen, Betreiber-Zahlen,
// Schalter aus = 404. Gegen PGlite, mit eigenem Temp-Ordner je Welt.
import { randomBytes, randomUUID } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync, mkdirSync } from 'node:fs';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { collectStatus } from '../src/operator/status.js';
import { encryptedSize } from '../src/files/crypto.js';
import { runFilesMaintenance } from '../src/files/maintenance.js';
import { backends, World, type Harness } from './helpers.js';
import { createUpload, filesWorld, headUpload, patchUpload, pdfLike, png, sha256, TUS, upload, uploadIdOf, type FilesWorld } from './files-kit.js';
import { createFamily, type Family } from './sync-kit.js';

const MB = 1_048_576;
const DAY = 86_400_000;

describe.each(backends)('Dateiablage: Upload und Auslieferung (%s)', (backend) => {
  let harness: Harness;
  let fw: FilesWorld;
  let world: World;
  let fam: Family;

  beforeAll(async () => {
    harness = await backend.open();
    fw = await filesWorld(harness, { FILES_QUOTA_BYTES: String(50 * MB), FILES_MAX_BYTES: String(20 * MB), FILES_STAGING_MAX_BYTES: String(40 * MB) });
    world = fw.world;
    fam = await createFamily(world);
  }, 180_000);
  afterAll(async () => {
    await fw.close();
    await harness.close();
  });
  beforeEach(async () => {
    await world.db.execute(sql`truncate table datei_blob, datei_upload`);
    fw.deps.free = 1_000_000_000_000;
    // Dateien der vorigen Tests entfernen (die Ordner bleiben)
    const leeren = (d: string) => {
      if (!existsSync(d)) return;
      for (const n of readdirSync(d)) {
        if (statSync(`${d}/${n}`).isDirectory()) leeren(`${d}/${n}`);
        else rmSync(`${d}/${n}`);
      }
    };
    leeren(fw.dir);
  });

  /** Eigene Welt (eigene Datenbank) mit anderer Konfiguration. */
  async function neu(env: Record<string, string>) {
    const h = await backend.open();
    const w = await filesWorld(h, env);
    const f = await createFamily(w.world);
    return {
      w,
      f,
      close: async () => {
        await w.close();
        await h.close();
      },
    };
  }
  const parent = () => fam.parent.client;
  const admin = () => fam.admin.client;
  const child = () => fam.child.client;
  const rows = async (q: ReturnType<typeof sql>) => (await world.db.execute(q)).rows as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
  const blobFile = (id: string) => `${fw.dir}/blobs/${id.slice(0, 2)}/${id}`;
  const getBlob = (c = parent(), id: string, headers: Record<string, string> = {}) => c.request('GET', `/api/v1/files/blobs/${id}`, { headers });
  /** GET mit Rohbytes (inject liefert die Antwort als Text: für Binärdaten über rawPayload). */
  async function rawGet(c = parent(), id: string, headers: Record<string, string> = {}) {
    const h: Record<string, string> = { 'x-forwarded-for': c.ip, 'user-agent': 'Mozilla/5.0 Chrome/130', origin: 'https://familie.lx-labs.dev', ...headers };
    if (c.cookie) h.cookie = c.cookie;
    const res = await world.app.inject({ method: 'GET', url: `/api/v1/files/blobs/${id}`, headers: h });
    return { status: res.statusCode, body: res.rawPayload, headers: res.headers };
  }

  describe('Schalter und Anmeldung', () => {
    it('ohne FILES_ENABLED: alle Routen 404 (auch ohne Anmeldung), nichts wird angelegt', async () => {
      const aus = await World.create(harness.db, { FILES_DIR: `${fw.dir}-aus` });
      try {
        const anon = aus.client();
        for (const [m, u] of [
          ['OPTIONS', '/api/v1/uploads'],
          ['POST', '/api/v1/uploads'],
          ['HEAD', `/api/v1/uploads/${randomUUID()}`],
          ['PATCH', `/api/v1/uploads/${randomUUID()}`],
          ['DELETE', `/api/v1/uploads/${randomUUID()}`],
          ['GET', `/api/v1/files/blobs/${randomUUID()}`],
          ['GET', '/api/v1/files/usage'],
        ] as const) expect((await anon.request(m, u, { headers: TUS })).status, `${m} ${u}`).toBe(404);
        expect(existsSync(`${fw.dir}-aus`)).toBe(false);
        expect((await anon.get('/api/v1/version')).json.features.files).toBe(false);
      } finally {
        await aus.close();
      }
    });

    it('mit Schalter: ohne Anmeldung 401; Merkmal files = true', async () => {
      const anon = world.client();
      expect((await anon.request('POST', '/api/v1/uploads', { headers: { ...TUS, 'upload-length': '1' } })).status).toBe(401);
      expect((await anon.get(`/api/v1/files/blobs/${randomUUID()}`)).status).toBe(401);
      expect((await anon.get('/api/v1/version')).json.features.files).toBe(true);
    });

    it('FILES_DIR muss mit Schalter in Produktion absolut sein; Grenzen müssen stimmen', async () => {
      const { loadConfig } = await import('../src/config.js');
      const base = { NODE_ENV: 'production', AUTH_SECRET_KEY: 'k'.repeat(10) + 'abcdefghijklmnopqrstuvwxyz0123456789ABCD', FILES_ENABLED: 'true' };
      expect(() => loadConfig({ ...base })).toThrow(/FILES_DIR/);
      expect(() => loadConfig({ ...base, FILES_DIR: 'relativ/pfad' })).toThrow(/FILES_DIR/);
      expect(() => loadConfig({ ...base, FILES_DIR: '/srv/fampad/files', FILES_MAX_BYTES: '200', FILES_QUOTA_BYTES: '100' })).toThrow(/FILES_MAX_BYTES/);
      expect(() => loadConfig({ ...base, FILES_DIR: '/srv/fampad/files', FILES_MAX_BYTES: '200', FILES_QUOTA_BYTES: '1000', FILES_STAGING_MAX_BYTES: '100' })).toThrow(/FILES_STAGING/);
      const c = loadConfig({ ...base, FILES_DIR: '/srv/fampad/files' });
      expect(c.files.quotaBytes).toBe(10_737_418_240);
      expect(c.files.maxBytes).toBe(104_857_600);
      expect(c.files.minFreeBytes).toBe(5_368_709_120);
      expect(c.files.stagingMaxBytes).toBe(2_147_483_648);
      expect(c.files.maxE2eeBytes).toBe(104_857_600 + 1_048_576);
      expect(() => loadConfig({ ...base, FILES_DIR: '/x/y', FILES_ENABLED: 'vielleicht' })).toThrow(/FILES_ENABLED/);
    });
  });

  describe('tus: Anlegen und Fortsetzen', () => {
    it('OPTIONS meldet Version, Erweiterungen und Höchstgröße', async () => {
      const res = await parent().request('OPTIONS', '/api/v1/uploads');
      expect(res.status).toBe(204);
      expect(res.headers['tus-version']).toBe('1.0.0');
      expect(res.headers['tus-extension']).toBe('creation,expiration,termination');
      expect(res.headers['tus-resumable']).toBe('1.0.0');
      expect(Number(res.headers['tus-max-size'])).toBe(20 * MB + MB);
    });

    it('Anlegen: Pflichtangaben und Eingabefehler', async () => {
      const c = parent();
      const post = (h: Record<string, string>) => c.request('POST', '/api/v1/uploads', { headers: h });
      expect((await post({ 'upload-length': '10' })).status).toBe(412); // ohne Tus-Resumable
      expect((await post({ 'tus-resumable': '0.2.2', 'upload-length': '10' })).status).toBe(412);
      for (const len of [undefined, '', '-1', '1.5', 'abc', '0x10', '1e3', '1234567890123456', ' 5']) {
        const h: Record<string, string> = { ...TUS };
        if (len !== undefined) h['upload-length'] = len;
        expect((await post(h)).status, `Länge ${len}`).toBe(400);
      }
      expect((await post({ ...TUS, 'upload-length': '10', 'upload-defer-length': '1' })).status).toBe(400);
      for (const md of ['modus ###', 'modus c2VydmVy,modus c2VydmVy', 'Modus c2VydmVy', 'a b c', `k ${Buffer.from('a\u0000b').toString('base64')}`, 'modus ' + 'A'.repeat(500)]) {
        expect((await post({ ...TUS, 'upload-length': '10', 'upload-metadata': md })).status, md).toBe(400);
      }
      const md = (o: Record<string, string>) => ({ ...TUS, 'upload-length': '10', 'upload-metadata': Object.entries(o).map(([k, v]) => `${k} ${Buffer.from(v).toString('base64')}`).join(',') });
      expect((await post(md({ modus: 'anders' }))).status).toBe(400);
      expect((await post(md({ kind: 'opak' }))).status).toBe(400); // opak nur im Modus e2ee
      expect((await post(md({ modus: 'e2ee', kind: 'datei' }))).status).toBe(400);
      expect((await post(md({ modus: 'e2ee', kind: 'thumb' }))).status).toBe(400);
      expect((await post(md({ mime: 'text/html; charset=x' }))).status).toBe(400);
      expect(await rows(sql`select 1 from datei_upload`)).toHaveLength(0);
    });

    it('mehrere Abschnitte, Fortsetzen nach HEAD, Abschluss mit Blob-ID und Prüfsumme', async () => {
      const c = parent();
      const bytes = pdfLike(300_000);
      const created = await createUpload(c, bytes.length, { mime: 'application/pdf' });
      expect(created.status).toBe(201);
      expect(created.headers['tus-resumable']).toBe('1.0.0');
      expect(created.headers['upload-offset']).toBe('0');
      expect(Date.parse(String(created.headers['upload-expires'])) - world.clock).toBeGreaterThan(23 * 3_600_000);
      const id = uploadIdOf(created);
      let h = await headUpload(c, id);
      expect(h.status).toBe(200);
      expect(h.headers['upload-offset']).toBe('0');
      expect(h.headers['upload-length']).toBe(String(bytes.length));
      expect(h.headers['cache-control']).toBe('no-store');
      const first = await patchUpload(c, id, 0, bytes.subarray(0, 100_000));
      expect(first.status).toBe(204);
      expect(first.headers['upload-offset']).toBe('100000');
      expect(first.headers['upload-blob-id']).toBeUndefined();
      // Verbindung "abgebrochen": der Client fragt nach und macht beim gemeldeten Stand weiter
      h = await headUpload(c, id);
      expect(h.headers['upload-offset']).toBe('100000');
      expect((await patchUpload(c, id, 100_000, bytes.subarray(100_000, 250_000))).status).toBe(204);
      const last = await patchUpload(c, id, 250_000, bytes.subarray(250_000));
      expect(last.status).toBe(204);
      expect(last.headers['upload-offset']).toBe(String(bytes.length));
      expect(last.headers['upload-blob-id']).toBe(id);
      expect(last.headers['upload-sha256']).toBe(sha256(bytes));
      // Blob-Zeile, Datei verschlüsselt, Staging weg
      const [b] = await rows(sql`select * from datei_blob where id = ${id}`);
      expect(b).toMatchObject({ modus: 'server', kind: 'datei', state: 'ready', size: bytes.length, sha256: sha256(bytes), mime: 'application/pdf', kid: 1 });
      expect(Number(b?.disk_size)).toBe(encryptedSize(bytes.length));
      expect(b?.dek_wrap).toBeTruthy();
      const onDisk = readFileSync(blobFile(id));
      expect(onDisk.length).toBe(encryptedSize(bytes.length));
      expect(onDisk.includes(bytes.subarray(20, 60))).toBe(false); // nicht im Klartext
      expect(readdirSync(`${fw.dir}/tmp`)).toEqual([]);
      expect((await rows(sql`select status from datei_upload where id = ${id}`))[0]?.status).toBe('done');
      // danach: weiteres PATCH ist ein Konflikt, HEAD zeigt den Endstand
      expect((await patchUpload(c, id, bytes.length, Buffer.from('x'))).status).toBe(409);
      expect((await headUpload(c, id)).headers['upload-offset']).toBe(String(bytes.length));
    });

    it('Abschnittsfehler: falscher Offset 409 (mit Stand), zu viele Bytes 413, falscher Typ 415, fehlender Offset 400, zu großer Abschnitt 413', async () => {
      const c = parent();
      const id = uploadIdOf(await createUpload(c, 5 * MB));
      expect((await patchUpload(c, id, 0, Buffer.alloc(1000))).status).toBe(204);
      const wrong = await patchUpload(c, id, 0, Buffer.alloc(10));
      expect(wrong.status).toBe(409);
      expect(wrong.headers['upload-offset']).toBe('1000');
      expect((await patchUpload(c, id, 2000, Buffer.alloc(10))).status).toBe(409);
      // mehr als angekündigt
      const small = uploadIdOf(await createUpload(c, 10));
      expect((await patchUpload(c, small, 0, Buffer.alloc(11))).status).toBe(413);
      expect((await headUpload(c, small)).headers['upload-offset']).toBe('0');
      // Typ und Offset
      const noType = await c.request('PATCH', `/api/v1/uploads/${id}`, { headers: { ...TUS, 'content-type': 'application/octet-stream', 'upload-offset': '1000' }, body: Buffer.alloc(5) });
      expect(noType.status).toBe(415);
      const noOffset = await c.request('PATCH', `/api/v1/uploads/${id}`, { headers: { ...TUS, 'content-type': 'application/offset+octet-stream' }, body: Buffer.alloc(5) });
      expect(noOffset.status).toBe(400);
      for (const off of ['-1', '1.0', 'x', '']) {
        expect((await patchUpload(c, id, 0, Buffer.alloc(1), { 'upload-offset': off })).status, off).toBe(400);
      }
      expect((await c.request('PATCH', `/api/v1/uploads/${id}`, { headers: { 'content-type': 'application/offset+octet-stream', 'upload-offset': '1000' }, body: Buffer.alloc(5) })).status).toBe(412);
      // Abschnitt über 4 MiB
      const big = await patchUpload(c, id, 1000, Buffer.alloc(4 * MB + 1));
      expect(big.status).toBe(413);
      // genau 4 MiB geht
      expect((await patchUpload(c, id, 1000, Buffer.alloc(4 * MB))).status).toBe(204);
    });

    it('Beenden (termination): Staging weg, danach 404; ein fertiger, nicht beanspruchter Blob verschwindet mit', async () => {
      const c = parent();
      const id = uploadIdOf(await createUpload(c, 100));
      await patchUpload(c, id, 0, Buffer.alloc(50));
      expect(readdirSync(`${fw.dir}/tmp`)).toHaveLength(1);
      expect((await c.request('DELETE', `/api/v1/uploads/${id}`, { headers: TUS })).status).toBe(204);
      expect(readdirSync(`${fw.dir}/tmp`)).toHaveLength(0);
      expect((await headUpload(c, id)).status).toBe(404);
      expect((await patchUpload(c, id, 50, Buffer.alloc(5))).status).toBe(404);
      expect((await c.request('DELETE', `/api/v1/uploads/${id}`, { headers: TUS })).status).toBe(404);
      const { id: fertig } = await upload(c, pdfLike(500));
      expect((await c.request('DELETE', `/api/v1/uploads/${fertig}`, { headers: TUS })).status).toBe(204);
      expect(existsSync(blobFile(fertig))).toBe(false);
      expect(await rows(sql`select 1 from datei_blob`)).toHaveLength(0);
      expect((await getBlob(c, fertig)).status).toBe(404);
    });

    it('Ablauf nach 24 Stunden: der Upload ist weg, die Staging-Datei auch', async () => {
      const c = parent();
      const id = uploadIdOf(await createUpload(c, 100));
      await patchUpload(c, id, 0, Buffer.alloc(10));
      world.advance(25 * 3_600_000);
      expect((await headUpload(c, id)).status).toBe(404);
      expect(readdirSync(`${fw.dir}/tmp`)).toHaveLength(0);
      expect((await patchUpload(c, id, 10, Buffer.alloc(5))).status).toBe(404);
    });

    it('zwei gleichzeitige Abschnitte an derselben Stelle: höchstens einer gewinnt', async () => {
      const c = parent();
      const id = uploadIdOf(await createUpload(c, 2000));
      const [a, b] = await Promise.all([patchUpload(c, id, 0, Buffer.alloc(500, 1)), patchUpload(c, id, 0, Buffer.alloc(500, 2))]);
      expect([a.status, b.status].filter((s) => s === 204)).toHaveLength(1);
      expect([409, 423]).toContain([a.status, b.status].find((s) => s !== 204));
      expect((await headUpload(c, id)).headers['upload-offset']).toBe('500');
    });
  });

  describe('Rechte: nur die eigene Person', () => {
    it('Upload und Blob einer anderen Person derselben Familie sind ein 404 (kein 403), auch für Admin', async () => {
      const bytes = pdfLike(1000);
      const id = uploadIdOf(await createUpload(parent(), bytes.length));
      await patchUpload(parent(), id, 0, bytes.subarray(0, 500));
      for (const other of [admin(), child()]) {
        expect((await headUpload(other, id)).status).toBe(404);
        expect((await patchUpload(other, id, 500, bytes.subarray(500))).status).toBe(404);
        expect((await other.request('DELETE', `/api/v1/uploads/${id}`, { headers: TUS })).status).toBe(404);
      }
      expect((await patchUpload(parent(), id, 500, bytes.subarray(500))).status).toBe(204);
      // fertig, aber nicht beansprucht: nur die hochladende Person liest
      expect((await getBlob(parent(), id)).status).toBe(200);
      for (const other of [admin(), child()]) expect((await getBlob(other, id)).status).toBe(404);
      expect((await getBlob(parent(), randomUUID())).status).toBe(404);
      expect((await getBlob(parent(), 'kein-uuid')).status).toBe(400);
    });

    it('Daten einer fremden Familie sind ein 404', async () => {
      const fremd = randomUUID();
      const user = randomUUID();
      const blob = randomUUID();
      const up = randomUUID();
      await world.db.execute(sql`insert into families (id, name) values (${fremd}, 'Fremd')`);
      await world.db.execute(sql`insert into users (id, email, display_name) values (${user}, 'f@example.org', 'F')`);
      await world.db.execute(sql`insert into datei_blob (id, family_id, uploader_id, modus, kind, size, disk_size, sha256) values (${blob}, ${fremd}, ${user}, 'e2ee', 'opak', 1, 1, 'x')`);
      await world.db.execute(sql`insert into datei_upload (id, family_id, uploader_id, modus, kind, length, expires_at) values (${up}, ${fremd}, ${user}, 'e2ee', 'opak', 5, now() + interval '1 day')`);
      for (const c of [parent(), admin()]) {
        expect((await getBlob(c, blob)).status).toBe(404);
        expect((await headUpload(c, up)).status).toBe(404);
        expect((await patchUpload(c, up, 0, Buffer.alloc(1))).status).toBe(404);
      }
      await world.db.execute(sql`delete from families where id = ${fremd}`);
      await world.db.execute(sql`delete from users where id = ${user}`);
    });
  });

  describe('Mengenbegrenzung', () => {
    it('höchstens 3 gleichzeitige Uploads je Person, 6 je Familie', async () => {
      const mk = (c = parent()) => createUpload(c, 100);
      const ids: string[] = [];
      for (let i = 0; i < 3; i++) ids.push(uploadIdOf(await mk()));
      const vierter = await mk();
      expect(vierter.status).toBe(429);
      expect(vierter.json.error).toBe('too_many_uploads');
      for (let i = 0; i < 3; i++) expect((await mk(admin())).status).toBe(201);
      // Familie voll (6): auch das Kind mit eigenem Zähler
      const kind = await mk(child());
      expect(kind.status).toBe(429);
      // ein beendeter Upload gibt den Platz frei
      await parent().request('DELETE', `/api/v1/uploads/${ids[0]}`, { headers: TUS });
      expect((await mk(parent())).status).toBe(201);
    });

    it('höchstens 30 neue Uploads je Person und Stunde (auch beendete zählen); nach einer Stunde wieder frei', async () => {
      const c = admin();
      for (let i = 0; i < 30; i++) {
        const r = await createUpload(c, 10);
        expect(r.status, `Upload ${i}`).toBe(201);
        await c.request('DELETE', r.headers.location as string, { headers: TUS });
      }
      const r = await createUpload(c, 10);
      expect(r.status).toBe(429);
      expect(r.json.error).toBe('rate_limited');
      world.advance(3_600_001);
      expect((await createUpload(c, 10)).status).toBe(201);
    });

    it('Kinder-Deckel je Stunde und Tag (Bytes), Eltern nicht betroffen', async () => {
      const { w, f, close } = await neu({ FILES_CHILD_BYTES_PER_HOUR: '1000', FILES_CHILD_BYTES_PER_DAY: '1500', FILES_MAX_BYTES: String(MB), FILES_QUOTA_BYTES: String(10 * MB) });
      try {
        expect((await createUpload(f.child.client, 800)).status).toBe(201);
        expect((await createUpload(f.child.client, 300)).status).toBe(429); // 1100 > 1000 je Stunde
        expect((await createUpload(f.parent.client, 5000)).status).toBe(201);
        w.world.advance(3_700_000);
        expect((await createUpload(f.child.client, 600)).status).toBe(201); // Stunde frei, Tag: 1400 <= 1500
        w.world.advance(3_700_000);
        expect((await createUpload(f.child.client, 300)).status).toBe(429); // Tag: 1700 > 1500
        w.world.advance(24 * 3_600_000);
        expect((await createUpload(f.child.client, 300)).status).toBe(201);
      } finally {
        await close();
      }
    }, 120_000);
  });

  describe('Kontingent, Dateigröße, Platz', () => {
    it('Kontingent je Familie (belegt + reserviert), Datei-Obergrenze, Race', async () => {
      const { f, close } = await neu({ FILES_QUOTA_BYTES: '1000', FILES_MAX_BYTES: '600', FILES_STAGING_MAX_BYTES: '100000' });
      try {
        const p = f.parent.client;
        const a = await createUpload(p, 600);
        expect(a.status).toBe(201);
        const zuGross = await createUpload(p, 601);
        expect(zuGross.status).toBe(413);
        expect(zuGross.json.error).toBe('file_too_large');
        const voll = await createUpload(p, 500); // 600 reserviert + 500 > 1000
        expect(voll.status).toBe(413);
        expect(voll.json.error).toBe('quota_exceeded');
        expect((await createUpload(p, 400)).status).toBe(201);
        // Race: viele gleichzeitige Anfragen, höchstens so viele, wie ins Kontingent passen (hier ist nichts mehr frei)
        const race = await Promise.all([f.admin.client, f.admin.client, f.parent.client].map((c) => createUpload(c, 50)));
        expect(race.map((r) => r.status)).toEqual([413, 413, 413]);
        // fertig hochgeladene Blobs zählen weiter; Beenden gibt frei
        const id = uploadIdOf(a);
        await patchUpload(p, id, 0, pdfLike(600));
        const u = (await p.get('/api/v1/files/usage')).json;
        expect(u).toMatchObject({ usedBytes: 600, reservedBytes: 400, quotaBytes: 1000, maxFileBytes: 600, chunkBytes: 4 * MB });
        await p.request('DELETE', `/api/v1/uploads/${id}`, { headers: TUS });
        expect((await p.get('/api/v1/files/usage')).json.usedBytes).toBe(0);
        expect((await createUpload(p, 500)).status).toBe(201);
      } finally {
        await close();
      }
    }, 120_000);

    it('Quota-Race: gleichzeitige Anlage mit knappem Kontingent lässt nie mehr durch als frei ist', async () => {
      const { f, close } = await neu({ FILES_QUOTA_BYTES: '1000', FILES_MAX_BYTES: '600', FILES_STAGING_MAX_BYTES: '100000' });
      try {
        const res = await Promise.all([f.parent.client, f.admin.client, f.parent.client].map((c) => createUpload(c, 400)));
        expect(res.filter((r) => r.status === 201)).toHaveLength(2);
        expect(res.filter((r) => r.status === 413)).toHaveLength(1);
      } finally {
        await close();
      }
    }, 120_000);

    it('Staging gesamt begrenzt: 503 mit Wartezeit', async () => {
      const { f, close } = await neu({ FILES_QUOTA_BYTES: '100000', FILES_MAX_BYTES: '600', FILES_STAGING_MAX_BYTES: '1000' });
      try {
        expect((await createUpload(f.parent.client, 600)).status).toBe(201);
        const r = await createUpload(f.admin.client, 600);
        expect(r.status).toBe(503);
        expect(r.json.error).toBe('staging_full');
        expect(r.headers['retry-after']).toBe('120');
      } finally {
        await close();
      }
    }, 120_000);

    it('zu wenig freier Platz: 507, nichts angelegt; mit genug Platz geht es wieder', async () => {
      const { w, f, close } = await neu({ FILES_MIN_FREE_BYTES: '5000' });
      try {
        w.deps.free = 5099;
        const r = await createUpload(f.parent.client, 100);
        expect(r.status).toBe(507);
        expect(r.json.error).toBe('insufficient_storage');
        expect((await w.world.db.execute(sql`select 1 from datei_upload`)).rows).toHaveLength(0);
        w.deps.free = 5100;
        expect((await createUpload(f.parent.client, 100)).status).toBe(201);
      } finally {
        await close();
      }
    }, 120_000);
  });

  describe('Modus server: Prüfung beim Abschluss', () => {
    it('Typ passt nicht zum Inhalt: 422, Upload verworfen, nichts abgelegt', async () => {
      const c = parent();
      const bytes = pdfLike(300);
      const id = uploadIdOf(await createUpload(c, bytes.length, { mime: 'image/png' }));
      const res = await patchUpload(c, id, 0, bytes);
      expect(res.status).toBe(422);
      expect(res.json.error).toBe('mime_mismatch');
      expect((await headUpload(c, id)).status).toBe(404);
      expect(readdirSync(`${fw.dir}/tmp`)).toEqual([]);
      expect(await rows(sql`select 1 from datei_blob`)).toHaveLength(0);
      // das Kontingent ist wieder frei
      expect((await c.get('/api/v1/files/usage')).json.reservedBytes).toBe(0);
    });

    it('Typ: octet-stream/ohne Angabe -> erkannt; Text bleibt wie genannt; Bild ohne Magic-Bytes abgelehnt', async () => {
      const c = parent();
      const a = await upload(c, png(), { mime: 'application/octet-stream' });
      expect((await rows(sql`select mime from datei_blob where id = ${a.id}`))[0]?.mime).toBe('image/png');
      const b = await upload(c, Buffer.from('hallo welt'));
      expect((await rows(sql`select mime from datei_blob where id = ${b.id}`))[0]?.mime).toBe('application/octet-stream');
      const t = await upload(c, Buffer.from('<html>x</html>'), { mime: 'text/html' });
      expect((await rows(sql`select mime from datei_blob where id = ${t.id}`))[0]?.mime).toBe('text/html');
      const id = uploadIdOf(await createUpload(c, 5, { mime: 'image/jpeg' }));
      expect((await patchUpload(c, id, 0, Buffer.from('hallo'))).status).toBe(422);
    });

    it('leere Datei: ein Abschluss ohne Bytes, lesbar als leere Antwort', async () => {
      const c = parent();
      const { id } = await upload(c, Buffer.alloc(0));
      const [b] = await rows(sql`select size, disk_size from datei_blob where id = ${id}`);
      expect(Number(b?.size)).toBe(0);
      expect(Number(b?.disk_size)).toBe(encryptedSize(0));
      const r = await rawGet(c, id);
      expect(r.status).toBe(200);
      expect(r.body.length).toBe(0);
      expect((await rawGet(c, id, { range: 'bytes=0-0' })).status).toBe(416);
    });

    it('Vorschaubild: nur kleine, gültige Bilder (inspectImage); als Bild mit Cache-Header ausgeliefert', async () => {
      const c = parent();
      const klein = png(8, 8);
      const { id } = await upload(c, klein, { kind: 'thumb' });
      expect((await rows(sql`select kind, mime, modus from datei_blob where id = ${id}`))[0]).toEqual({ kind: 'thumb', mime: 'image/png', modus: 'server' });
      const kein = uploadIdOf(await createUpload(c, 20, { kind: 'thumb' }));
      expect((await patchUpload(c, kein, 0, Buffer.from('das ist kein bild!!!'))).status).toBe(422);
      // zu groß (Bytes) schon beim Anlegen
      expect((await createUpload(c, 256 * 1024 + 1, { kind: 'thumb' })).status).toBe(413);
      // zu große Maße (> 1024 Pixel)
      const breit = png(2000, 1);
      const w = uploadIdOf(await createUpload(c, breit.length, { kind: 'thumb' }));
      expect((await patchUpload(c, w, 0, breit)).status).toBe(422);
    });
  });

  describe('Modus e2ee: undurchsichtig', () => {
    it('Bytes unverändert abgelegt, kein Typ, kein Schlüssel, keine Magic-Byte-Prüfung; Prüfsumme der übertragenen Bytes', async () => {
      const c = parent();
      // sieht aus wie ein PNG, ist aber als undurchsichtig gemeldet: der Server schaut nicht hinein
      const bytes = Buffer.concat([png(), randomBytes(5000)]);
      const { id, last } = await upload(c, bytes, { modus: 'e2ee', mime: 'application/pdf', name: 'geheim.pdf' }, 2048);
      expect(last.headers['upload-sha256']).toBe(sha256(bytes));
      const [b] = await rows(sql`select * from datei_blob where id = ${id}`);
      expect(b).toMatchObject({ modus: 'e2ee', kind: 'opak', mime: null, dek_wrap: null, kid: null, size: bytes.length, sha256: sha256(bytes) });
      expect(Number(b?.disk_size)).toBe(bytes.length);
      expect(readFileSync(blobFile(id)).equals(bytes)).toBe(true);
      expect((await rows(sql`select declared_mime from datei_upload where id = ${id}`))[0]?.declared_mime).toBeNull();
      // Auslieferung unverändert, immer als Anhang ohne Namen
      const r = await rawGet(c, id);
      expect(r.status).toBe(200);
      expect(Buffer.from(r.body).equals(bytes)).toBe(true);
      expect(r.headers['content-type']).toBe('application/octet-stream');
      expect(String(r.headers['content-disposition'])).toBe('attachment; filename="datei"; filename*=UTF-8\'\'datei');
      const part = await rawGet(c, id, { range: 'bytes=100-199' });
      expect(part.status).toBe(206);
      expect(Buffer.from(part.body).equals(bytes.subarray(100, 200))).toBe(true);
    });

    it('gleiche Obergrenze (Datei + Overhead) und gleiches Kontingent wie der Modus server', async () => {
      const { f, close } = await neu({ FILES_QUOTA_BYTES: '5000000', FILES_MAX_BYTES: '600', FILES_STAGING_MAX_BYTES: '5000000' });
      try {
        const p = f.parent.client;
        const grenze = 600 + MB;
        expect((await createUpload(p, grenze + 1, { modus: 'e2ee' })).status).toBe(413);
        expect((await createUpload(p, 601, { modus: 'server' })).status).toBe(413);
        expect((await createUpload(p, 0, { modus: 'e2ee' })).status).toBe(400);
        const ok = await createUpload(p, grenze, { modus: 'e2ee' });
        expect(ok.status).toBe(201);
        // zählt gegen dasselbe Kontingent
        expect((await p.get('/api/v1/files/usage')).json).toMatchObject({ reservedBytes: grenze, maxE2eeBytes: grenze });
        expect((await createUpload(f.admin.client, 4_000_000, { modus: 'e2ee' })).status).toBe(413);
      } finally {
        await close();
      }
    }, 120_000);
  });

  describe('Auslieferung: Header und Range', () => {
    const bytes = Buffer.concat([Buffer.from('%PDF-1.7\n'), randomBytes(200_000 - 9)]);
    let id: string;
    beforeEach(async () => {
      id = (await upload(parent(), bytes, { mime: 'application/pdf' }, 70_000)).id;
    });

    it('ganze Datei: Sicherheits- und Cache-Header, immer Anhang, Typ octet-stream', async () => {
      const r = await rawGet(parent(), id);
      expect(r.status).toBe(200);
      expect(Buffer.from(r.body).equals(bytes)).toBe(true);
      expect(r.headers).toMatchObject({
        etag: `"${id}"`,
        'accept-ranges': 'bytes',
        'cache-control': 'private, no-store',
        'x-content-type-options': 'nosniff',
        'content-security-policy': "sandbox; default-src 'none'",
        'content-type': 'application/octet-stream',
        'cross-origin-resource-policy': 'same-origin',
        'content-length': String(bytes.length),
      });
      expect(String(r.headers['content-disposition'])).toMatch(/^attachment; /);
      expect(String(r.headers.vary)).toContain('Authorization');
    });

    it.each([
      ['bytes=0-0', 0, 0],
      ['bytes=0-99', 0, 99],
      ['bytes=65535-65536', 65_535, 65_536],
      ['bytes=65536-131071', 65_536, 131_071],
      ['bytes=60000-190000', 60_000, 190_000],
      ['bytes=199990-', 199_990, 199_999],
      ['bytes=199999-199999', 199_999, 199_999],
      ['bytes=-10', 199_990, 199_999],
      ['bytes=199000-9999999', 199_000, 199_999],
    ] as const)('Bereich %s', async (range, von, bis) => {
      const r = await rawGet(parent(), id, { range });
      expect(r.status).toBe(206);
      expect(r.headers['content-range']).toBe(`bytes ${von}-${bis}/${bytes.length}`);
      expect(r.headers['content-length']).toBe(String(bis - von + 1));
      expect(Buffer.from(r.body).equals(bytes.subarray(von, bis + 1))).toBe(true);
    });

    it.each(['bytes=200000-', 'bytes=200000-200005', 'bytes=0-1,5-6', 'bytes=abc', 'bytes=5-2', 'bytes=-0', 'bytes=', 'items=0-5', 'bytes=0-99999999999999999999'])('ungültiger oder nicht erfüllbarer Bereich %j: 416 mit Größe', async (range) => {
      const r = await rawGet(parent(), id, { range });
      expect(r.status).toBe(416);
      expect(r.headers['content-range']).toBe(`bytes */${bytes.length}`);
    });

    it('If-None-Match 304; If-Range mit falscher ETag liefert die ganze Datei, mit passender den Bereich; HEAD ohne Inhalt', async () => {
      expect((await rawGet(parent(), id, { 'if-none-match': `"${id}"` })).status).toBe(304);
      expect((await rawGet(parent(), id, { 'if-none-match': '"x"' })).status).toBe(200);
      const falsch = await rawGet(parent(), id, { range: 'bytes=0-9', 'if-range': '"anders"' });
      expect(falsch.status).toBe(200);
      expect(falsch.body.length).toBe(bytes.length);
      expect((await rawGet(parent(), id, { range: 'bytes=0-9', 'if-range': `"${id}"` })).status).toBe(206);
      const h = await parent().request('HEAD', `/api/v1/files/blobs/${id}`);
      expect(h.status).toBe(200);
      expect(h.headers.etag).toBe(`"${id}"`);
      expect(h.headers['content-disposition']).toMatch(/^attachment/);
    });

    it('Anmeldung bei jedem Abruf: ein abgemeldetes Gerät bekommt nichts mehr', async () => {
      const c = world.client('203.0.113.99');
      // zweite Sitzung der Mutter
      const zweit = await fam.secondDevice('parent');
      expect((await rawGet(zweit.client, id)).status).toBe(200);
      await zweit.client.post('/api/v1/auth/logout');
      expect((await rawGet(zweit.client, id)).status).toBe(401);
      void c;
    });

    it('beschädigte Datei auf der Platte: der Abruf bricht ab, liefert nie falschen Inhalt', async () => {
      const file = blobFile(id);
      const raw = readFileSync(file);
      raw[116] = (raw[116] ?? 0) ^ 0xff;
      writeFileSync(file, raw);
      const ok = await rawGet(parent(), id).then(
        (r) => r.status === 200 && Buffer.from(r.body).equals(bytes),
        () => false,
      );
      expect(ok).toBe(false);
    });
  });

  describe('Unterbrechung beim Abschluss', () => {
    it('Fehler nach dem Umbenennen: Zieldatei entfernt, Upload bleibt abschließbar (HEAD / leerer PATCH)', async () => {
      let fail = true;
      const dir = fw.dir;
      const hooks = { afterInstall: async () => { if (fail) throw new Error('Stromausfall'); } };
      const h = await backend.open();
      const w = await World.create(h.db, { FILES_ENABLED: 'true', FILES_DIR: dir, FILES_MIN_FREE_BYTES: '0', SYNC_RATE_LIMIT_MAX: '100000' }, { filesDeps: { freeBytes: async () => 1e12, ...hooks } });
      try {
        const f = await createFamily(w);
        const rows = async (q: ReturnType<typeof sql>) => (await w.db.execute(q)).rows as Array<Record<string, any>>; // eslint-disable-line @typescript-eslint/no-explicit-any
        const c = f.parent.client;
        const bytes = pdfLike(70_000);
        const id = uploadIdOf(await createUpload(c, bytes.length));
        const res = await patchUpload(c, id, 0, bytes);
        expect(res.status).toBe(503);
        expect(res.json.error).toBe('finalize_failed');
        expect(existsSync(`${dir}/blobs/${id.slice(0, 2)}/${id}`)).toBe(false);
        expect(readdirSync(`${dir}/tmp`).some((n) => n.endsWith('.enc'))).toBe(false);
        expect(readdirSync(`${dir}/tmp`)).toContain(`${id}.part`);
        expect((await rows(sql`select status from datei_upload where id = ${id}`))[0]?.status).toBe('finalizing');
        expect(await rows(sql`select 1 from datei_blob where id = ${id}`)).toHaveLength(0);
        // das Kontingent bleibt reserviert
        expect((await c.get('/api/v1/files/usage')).json.reservedBytes).toBe(bytes.length);
        // weiterer Abschnitt mit Inhalt geht nicht, ein leerer löst den Abschluss erneut aus
        expect((await patchUpload(c, id, bytes.length, Buffer.from('x'))).status).toBe(409);
        fail = false;
        const again = await patchUpload(c, id, bytes.length, Buffer.alloc(0));
        expect(again.status).toBe(204);
        expect(again.headers['upload-blob-id']).toBe(id);
        expect(existsSync(`${dir}/blobs/${id.slice(0, 2)}/${id}`)).toBe(true);
        expect(readdirSync(`${dir}/tmp`)).toEqual([]);

        // zweite Variante: über HEAD
        fail = true;
        const b2 = pdfLike(1000);
        const id2 = uploadIdOf(await createUpload(c, b2.length));
        expect((await patchUpload(c, id2, 0, b2)).status).toBe(503);
        fail = false;
        const head = await headUpload(c, id2);
        expect(head.status).toBe(200);
        expect((await rows(sql`select status from datei_upload where id = ${id2}`))[0]?.status).toBe('done');
        expect(existsSync(`${dir}/blobs/${id2.slice(0, 2)}/${id2}`)).toBe(true);
      } finally {
        await w.close();
        await h.close();
      }
    }, 120_000);
  });

  describe('Aufräumen', () => {
    const ctx = () => ({ db: world.db, config: world.config, now: world.now, log: { warn: () => undefined, error: () => undefined } });

    it('abgelaufene Uploads, beendete Zeilen und Reste in tmp/ verschwinden; Fremdes bleibt', async () => {
      const c = parent();
      const id = uploadIdOf(await createUpload(c, 100));
      await patchUpload(c, id, 0, Buffer.alloc(10));
      const rest = `${fw.dir}/tmp/${randomUUID()}.part`;
      writeFileSync(rest, 'rest');
      const alt = new Date(world.clock - 3 * DAY);
      utimesSync(rest, alt, alt);
      writeFileSync(`${fw.dir}/tmp/notiz.txt`, 'fremd');
      utimesSync(`${fw.dir}/tmp/notiz.txt`, alt, alt);
      world.advance(25 * 3_600_000);
      const r = await runFilesMaintenance(ctx());
      expect(r.uploadsExpired).toBe(1);
      expect(r.stagingRemoved).toBe(2); // die Staging-Datei des abgelaufenen Uploads und der alte Rest
      expect(existsSync(rest)).toBe(false);
      expect(readdirSync(`${fw.dir}/tmp`)).toEqual(['notiz.txt']); // Fremdes bleibt
      world.advance(25 * 3_600_000);
      expect((await runFilesMaintenance(ctx())).uploadsDeleted).toBe(1);
      expect(await rows(sql`select 1 from datei_upload`)).toHaveLength(0);
    });

    it('nie beanspruchte Blobs: erst nach 7 Tagen weg; Abgleich Platte/Datenbank meldet nur', async () => {
      const c = parent();
      const { id } = await upload(c, pdfLike(500));
      const zurueck = (tage: number) => world.db.execute(sql`update datei_blob set created_at = created_at - ${`${tage} days`}::interval`);
      await zurueck(6);
      let r = await runFilesMaintenance(ctx());
      expect(r.blobsDeleted).toBe(0);
      expect(existsSync(blobFile(id))).toBe(true);
      await zurueck(2);
      r = await runFilesMaintenance(ctx());
      expect(r.blobsDeleted).toBe(1);
      expect(existsSync(blobFile(id))).toBe(false);
      expect(await rows(sql`select 1 from datei_blob`)).toHaveLength(0);

      // Abgleich: Datei ohne Zeile (älter als ein Tag) und Zeile ohne Datei werden nur gezählt, nie gelöscht
      const stray = randomUUID();
      mkdirSync(`${fw.dir}/blobs/${stray.slice(0, 2)}`, { recursive: true });
      writeFileSync(blobFile(stray), 'waise');
      const alt = new Date(world.clock - 3 * DAY);
      utimesSync(blobFile(stray), alt, alt);
      const { id: weg } = await upload(c, pdfLike(100));
      rmSync(blobFile(weg));
      r = await runFilesMaintenance(ctx());
      expect(r.strayFiles).toBe(1);
      expect(r.missingFiles).toBe(1);
      expect(existsSync(blobFile(stray))).toBe(true);
      expect(await rows(sql`select 1 from datei_blob where id = ${weg}`)).toHaveLength(1);
    });

    it('läuft nur mit Schalter und gehört zum stündlichen Wartungsjob', async () => {
      const aus = await World.create(harness.db, {});
      try {
        expect(await runFilesMaintenance({ db: aus.db, config: aus.config, now: aus.now, log: { warn: () => undefined, error: () => undefined } })).toMatchObject({ blobsDeleted: 0, uploadsExpired: 0 });
      } finally {
        await aus.close();
      }
      const { runMaintenance } = await import('../src/auth/maintenance.js');
      expect((await runMaintenance(world.auth.ctx)).files).not.toBeNull();
    });
  });

  describe('Betreiber-Ansicht: nur Zahlen', () => {
    it('Status enthält belegt/reserviert/Kontingent/Anzahl, nie Namen oder Typen', async () => {
      await upload(parent(), pdfLike(4000), { mime: 'application/pdf', name: 'Steuerbescheid.pdf' });
      await createUpload(admin(), 100);
      const status = await collectStatus({ ctx: world.auth.ctx, weather: undefined }, fam.familyId);
      expect(status.files).toEqual({ enabled: true, usedBytes: 4000, reservedBytes: 100, quotaBytes: 50 * MB, blobs: 1, uploadsOpen: 1 });
      const text = JSON.stringify(status.files);
      expect(text).not.toMatch(/Steuer|pdf|application/);
      for (const v of Object.values(status.files)) expect(['number', 'boolean']).toContain(typeof v);
      // ohne Schalter: nur "aus", keine Zahlen
      const aus = await World.create(harness.db, {});
      try {
        const s = await collectStatus({ ctx: aus.auth.ctx, weather: undefined }, fam.familyId);
        expect(s.files).toEqual({ enabled: false, usedBytes: null, reservedBytes: null, quotaBytes: null, blobs: null, uploadsOpen: null });
      } finally {
        await aus.close();
      }
    });
  });
});
