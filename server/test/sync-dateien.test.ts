// Dateien im Sync (Abschnitt 6n): Ordner, Dateien, Fassungen, Tresor-Anhänge. Geprüft werden die Rechte-Regeltabelle, die Freigabe-Invariante (kein Kind sieht etwas unter einem Ordner,
// den es nicht sieht), Zyklus und Tiefe, der atomare Claim von Blobs (Doppel-Claim, fremder Upload, falsche Art/Modus, Zurückrollen), die Leseberechtigung der Blobs über den Datensatz,
// die verborgene Tresor-Konversation für Anhänge und das Aufräumen verwaister Blobs.
import { randomBytes, randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../src/auth/types.js';
import { runFilesMaintenance } from '../src/files/maintenance.js';
import { tresorChatId } from '../src/sync/entities/chat-ids.js';
import { dateiEntity, dateiVersionEntity, MAX_ORDNER_TIEFE, ordnerEntity } from '../src/sync/entities/dateien.js';
import { tresorAnhangEntity } from '../src/sync/entities/tresor-anhang.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, type Harness } from './helpers.js';
import { filesWorld, patchUpload, createUpload, pdfLike, png, uploadIdOf, upload, type FilesWorld } from './files-kit.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const actor = (role: Role, userId: string): Actor => ({ role, userId });
const E1 = (laenge = 160) => `e1:${'A'.repeat(laenge)}`;

describe('Dateien: Rechte-Regeltabelle (rein)', () => {
  const ME = 'u-ich';
  const ANDERE = 'u-andere';
  const f = (audience: 'parents' | 'family', owner: string): Facts => ({ audience, ownerId: owner });

  it.each([
    ['Ordner', ordnerEntity],
    ['Datei', dateiEntity],
  ] as const)('%s: Eltern und Admins alles; Kind sieht Stufe family, legt nur family an, ändert und löscht nur Eigenes (ohne Stufe)', (_n, def) => {
    for (const role of ['admin', 'parent'] as const) {
      for (const aud of ['parents', 'family'] as const) {
        expect(mayRead(def.rules, actor(role, ME), f(aud, ANDERE))).toBe(true);
        for (const a of ['update', 'delete'] as const) expect(authorize(def.rules, a, actor(role, ME), f(aud, ANDERE), ['name']), `${role} ${a}`).toBe('ok');
        expect(authorize(def.rules, 'create', actor(role, ME), f(aud, ME), ['name'], { audience: aud })).toBe('ok');
      }
    }
    const k = actor('child', ME);
    expect(mayRead(def.rules, k, f('family', ANDERE))).toBe(true);
    expect(mayRead(def.rules, k, f('parents', ME))).toBe(false); // auch das eigene Verborgene gibt es für das Kind nicht
    expect(authorize(def.rules, 'create', k, f('family', ME), ['name'], { audience: 'family' })).toBe('ok');
    expect(authorize(def.rules, 'create', k, f('parents', ME), ['name'], { audience: 'parents' })).toBe('forbidden');
    expect(authorize(def.rules, 'update', k, f('family', ME), ['name'])).toBe('ok');
    expect(authorize(def.rules, 'update', k, f('family', ANDERE), ['name'])).toBe('forbidden');
    expect(authorize(def.rules, 'update', k, f('family', ME), ['audience'], { audience: 'parents' })).toBe('forbidden'); // Stufe ändert das Kind nie
    expect(authorize(def.rules, 'delete', k, f('family', ME))).toBe('ok');
    expect(authorize(def.rules, 'delete', k, f('family', ANDERE))).toBe('forbidden');
    expect(authorize(def.rules, 'update', k, f('parents', ANDERE), ['name'])).toBe('not_found');
    expect(authorize(def.rules, 'delete', k, f('parents', ANDERE))).toBe('not_found');
  });

  it('Fassung: unveränderlich (niemand ändert), Kind legt nur für eigene Dateien an und löscht nur dort', () => {
    const d = dateiVersionEntity;
    for (const role of ['admin', 'parent'] as const) {
      expect(authorize(d.rules, 'create', actor(role, ME), f('family', ANDERE), ['dateiId'])).toBe('ok');
      expect(authorize(d.rules, 'update', actor(role, ME), f('family', ANDERE), ['nr'])).toBe('forbidden');
      expect(authorize(d.rules, 'delete', actor(role, ME), f('parents', ANDERE))).toBe('ok');
    }
    const k = actor('child', ME);
    expect(authorize(d.rules, 'create', k, f('family', ME), ['dateiId'])).toBe('ok');
    expect(authorize(d.rules, 'create', k, f('family', ANDERE), ['dateiId'])).toBe('forbidden');
    expect(authorize(d.rules, 'update', k, f('family', ME), ['nr'])).toBe('forbidden');
    expect(authorize(d.rules, 'delete', k, f('family', ME))).toBe('ok');
    expect(authorize(d.rules, 'delete', k, f('family', ANDERE))).toBe('forbidden');
    expect(mayRead(d.rules, k, f('parents', ME))).toBe(false);
  });

  it('Tresor-Anhang: nur Teilnehmer (Eltern/Admins), nie ein Kind, unveränderlich', () => {
    const d = tresorAnhangEntity;
    const privat: Facts = { audience: 'family', ownerId: ANDERE, participants: [ME, ANDERE], quiet: true };
    for (const role of ['admin', 'parent'] as const) {
      expect(mayRead(d.rules, actor(role, ME), privat)).toBe(true);
      expect(authorize(d.rules, 'create', actor(role, ME), privat, ['blobId'])).toBe('ok');
      expect(authorize(d.rules, 'delete', actor(role, ME), privat)).toBe('ok');
      expect(authorize(d.rules, 'update', actor(role, ME), privat, ['inhalt'])).toBe('forbidden');
      expect(mayRead(d.rules, actor(role, 'u-fremd'), privat)).toBe(false);
    }
    expect(mayRead(d.rules, actor('child', ME), privat)).toBe(false);
    expect(authorize(d.rules, 'create', actor('child', ME), privat, ['blobId'])).toBe('forbidden');
  });
});

describe.each(backends)('Dateien im Sync (%s)', (backend) => {
  let harness: Harness;
  let fw: FilesWorld;
  let fam: Family;
  let papa: Device;

  beforeAll(async () => {
    harness = await backend.open();
    fw = await filesWorld(harness, { WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
    fam = await createFamily(fw.world);
    papa = await extraMember(fw.world, fam.admin, 'parent', 'papa@example.org');
  }, 180_000);
  afterAll(async () => {
    await fw.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(fw.world);
    for (const d of [fam.admin, fam.parent, fam.child, papa]) d.sinceRev = 0;
  });

  const world = () => fw.world;
  const rows = async (q: ReturnType<typeof sql>): Promise<Json[]> => (await world().db.execute(q)).rows as Json[];
  const codes = (res: { json: Json }) => (res.json.rejected as Array<{ code: string }>).map((r) => r.code);
  const acked = (res: { json: Json }) => (res.json.acked as unknown[]).length;
  const ids = (changes: Json[], entity: string) => changes.filter((c) => c.entity === entity && !c.deleted).map((c) => c.id as string);
  const ctx = () => ({ db: world().db, config: world().config, now: world().now, log: { warn: () => undefined, error: () => undefined } });
  const blobRow = async (id: string) => (await rows(sql`select * from datei_blob where id = ${id}`))[0];

  // ---- Bausteine
  const ordner = (id: string, fields: Json, baseRev = 0) => upsert('ordner', id, { name: `Ordner ${id.slice(0, 4)}`, ...fields }, baseRev);
  const datei = (id: string, fields: Json = {}) => upsert('datei', id, { name: 'Plan.pdf', ...fields });
  const version = (id: string, dateiId: string, blobId: string, fields: Json = {}) => upsert('datei_version', id, { dateiId, nr: 1, blobId, ...fields });
  /** Lädt eine Datei hoch (Modus server) und gibt die Blob-ID zurück. */
  const hoch = async (by: Device, bytes: Buffer = pdfLike(2000), md: Record<string, string> = { mime: 'application/pdf' }) => (await upload(by.client, bytes, md)).id;
  const hochE2ee = async (by: Device, bytes: Buffer = randomBytes(3000)) => (await upload(by.client, bytes, { modus: 'e2ee' })).id;
  const get = async (by: Device, blobId: string) => {
    const c = by.client;
    const res = await world().app.inject({
      method: 'GET',
      url: `/api/v1/files/blobs/${blobId}`,
      headers: { 'x-forwarded-for': c.ip, 'user-agent': 'Mozilla/5.0 Chrome/130', origin: 'https://familie.lx-labs.dev', ...(c.cookie ? { cookie: c.cookie } : {}) },
    });
    return { status: res.statusCode, body: res.rawPayload, headers: res.headers };
  };
  /** Datei samt erster Fassung anlegen. */
  async function neueDatei(by: Device, bytes?: Buffer, fields: Json = {}): Promise<{ dateiId: string; versionId: string; blobId: string }> {
    const blobId = await hoch(by, bytes);
    const dateiId = randomUUID();
    const versionId = randomUUID();
    const res = await by.sync([datei(dateiId, fields), version(versionId, dateiId, blobId)]);
    expect(res.json.rejected, JSON.stringify(res.json)).toEqual([]);
    return { dateiId, versionId, blobId };
  }
  async function kette(by: Device, tiefe: number, audience = 'family'): Promise<string[]> {
    const out: string[] = [];
    for (let i = 0; i < tiefe; i++) {
      const id = randomUUID();
      const res = await by.sync([ordner(id, { parentId: out[i - 1] ?? null, audience })]);
      expect(res.json.rejected, `Ebene ${i + 1}: ${JSON.stringify(res.json.rejected)}`).toEqual([]);
      out.push(id);
    }
    return out;
  }
  const revOf = async (table: string, id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);

  describe('Ordner: Baum, Tiefe, Zyklus', () => {
    it('Ebenen bis 6, die siebte wird abgelehnt', async () => {
      expect(MAX_ORDNER_TIEFE).toBe(6);
      const k = await kette(fam.parent, 6);
      expect(codes(await fam.parent.sync([ordner(randomUUID(), { parentId: k[5] })]))).toEqual(['invalid']);
    });

    it('Zyklus und Selbstverweis werden abgelehnt (auch über mehrere Ebenen)', async () => {
      const [a, b, c] = await kette(fam.parent, 3);
      expect(codes(await fam.parent.sync([ordner(a!, { parentId: c }, await revOf('ordner', a!))]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([ordner(a!, { parentId: a }, await revOf('ordner', a!))]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([ordner(b!, { parentId: c }, await revOf('ordner', b!))]))).toEqual(['invalid']);
      // ein gültiges Verschieben geht
      expect(acked(await fam.parent.sync([ordner(c!, { parentId: a }, await revOf('ordner', c!))]))).toBe(1);
    });

    it('Verschieben prüft die Tiefe des ganzen Teilbaums', async () => {
      const x = await kette(fam.parent, 4);
      const y = await kette(fam.parent, 3);
      // Y3 (Tiefe 3) + X1 samt Teilbaum (4 Ebenen) = 7
      expect(codes(await fam.parent.sync([ordner(x[0]!, { parentId: y[2] }, await revOf('ordner', x[0]!))]))).toEqual(['invalid']);
      // unter Y2: 2 + 4 = 6
      expect(acked(await fam.parent.sync([ordner(x[0]!, { parentId: y[1] }, await revOf('ordner', x[0]!))]))).toBe(1);
    });

    it('fehlender, gelöschter oder fremder Elternordner: invalid; Name nach den Regeln', async () => {
      expect(codes(await fam.parent.sync([ordner(randomUUID(), { parentId: randomUUID() })]))).toEqual(['invalid']);
      const [a] = await kette(fam.parent, 1);
      await fam.parent.sync([remove('ordner', a!, await revOf('ordner', a!))]);
      expect(codes(await fam.parent.sync([ordner(randomUUID(), { parentId: a })]))).toEqual(['invalid']);
      for (const name of ['CON', 'nul.txt', '../x', 'a/b', '..', '', 'ende.']) {
        expect(codes(await fam.parent.sync([ordner(randomUUID(), { name })])), name).toEqual(['invalid']);
      }
      const id = randomUUID();
      await fam.parent.sync([ordner(id, { name: '  Urlaub‮ 2026 ' })]);
      expect((await rows(sql`select name from ordner where id = ${id}`))[0]?.name).toBe('Urlaub 2026');
      // Zufalls-ID (v4) Pflicht
      expect(codes(await fam.parent.sync([ordner('00000000-0000-1000-8000-000000000001', {})]))).toEqual(['invalid']);
    });

    it('Löschen nur leer: nicht leer = forbidden, nach dem Leeren (von unten nach oben) geht es', async () => {
      const [a, b] = await kette(fam.parent, 2);
      const d = randomUUID();
      await fam.parent.sync([datei(d, { ordnerId: b })]);
      expect(codes(await fam.parent.sync([remove('ordner', a!, await revOf('ordner', a!))]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([remove('ordner', b!, await revOf('ordner', b!))]))).toEqual(['forbidden']);
      const res = await fam.parent.sync([remove('datei', d, await revOf('dateien', d)), remove('ordner', b!, await revOf('ordner', b!)), remove('ordner', a!, await revOf('ordner', a!))]);
      expect(res.json.rejected).toEqual([]);
      expect(await rows(sql`select 1 from ordner where deleted_at is null`)).toHaveLength(0);
    });
  });

  describe('Freigabe ohne Vererbung: Invariante und Sicht', () => {
    it('ein Eintrag der Stufe family liegt nie unter einem Ordner der Stufe parents', async () => {
      const [p] = await kette(fam.parent, 1, 'parents');
      expect(codes(await fam.parent.sync([ordner(randomUUID(), { parentId: p, audience: 'family' })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([datei(randomUUID(), { ordnerId: p, audience: 'family' })]))).toEqual(['invalid']);
      // unter einem family-Ordner darf es verborgen sein, unter einem verborgenen verborgen
      const [f] = await kette(fam.parent, 1, 'family');
      expect(acked(await fam.parent.sync([ordner(randomUUID(), { parentId: f, audience: 'parents' })]))).toBe(1);
      expect(acked(await fam.parent.sync([datei(randomUUID(), { ordnerId: p, audience: 'parents' })]))).toBe(1);
      // Verschieben einer family-Datei in einen verborgenen Ordner: abgelehnt
      const d = randomUUID();
      await fam.parent.sync([datei(d, { audience: 'family' })]);
      expect(codes(await fam.parent.sync([upsert('datei', d, { ordnerId: p }, await revOf('dateien', d))]))).toEqual(['invalid']);
    });

    it('einen Ordner auf parents stellen geht nur, wenn direkt darunter nichts family ist', async () => {
      const [a, b] = await kette(fam.parent, 2); // a (family) > b (family)
      const d = randomUUID();
      await fam.parent.sync([datei(d, { ordnerId: a })]);
      expect(codes(await fam.parent.sync([upsert('ordner', a!, { audience: 'parents' }, await revOf('ordner', a!))]))).toEqual(['invalid']);
      // erst die Kinder verbergen (Datei und Unterordner), dann den Ordner
      const res = await fam.parent.sync([
        upsert('datei', d, { audience: 'parents' }, await revOf('dateien', d)),
        upsert('ordner', b!, { audience: 'parents' }, await revOf('ordner', b!)),
        upsert('ordner', a!, { audience: 'parents' }, await revOf('ordner', a!)),
      ]);
      expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
      // und zurück: nur von oben nach unten (der Elternordner muss zuerst family sein)
      expect(codes(await fam.parent.sync([upsert('ordner', b!, { audience: 'family' }, await revOf('ordner', b!))]))).toEqual(['invalid']);
    });

    it('das Kind sieht nur family-Einträge und nie etwas unter einem verborgenen Ordner', async () => {
      const [pub] = await kette(fam.parent, 1, 'family');
      const [priv] = await kette(fam.parent, 1, 'parents');
      const dp = randomUUID();
      const dpub = randomUUID();
      await fam.parent.sync([datei(dp, { ordnerId: priv, audience: 'parents' }), datei(dpub, { ordnerId: pub, audience: 'family' })]);
      const kind = await fam.child.pull();
      expect(ids(kind, 'ordner').sort()).toEqual([pub].sort());
      expect(ids(kind, 'datei')).toEqual([dpub]);
      const eltern = await fam.admin.pull();
      expect(ids(eltern, 'ordner').sort()).toEqual([pub, priv].sort());
      expect(ids(eltern, 'datei').sort()).toEqual([dp, dpub].sort());
    });

    it('Kind: legt family an (auch im sichtbaren Ordner), nie parents, nie in einen verborgenen Ordner; ändert/löscht nur Eigenes', async () => {
      const [pub] = await kette(fam.parent, 1, 'family');
      const [priv] = await kette(fam.parent, 1, 'parents');
      const eigen = randomUUID();
      expect(acked(await fam.child.sync([ordner(eigen, { parentId: pub })]))).toBe(1);
      expect(codes(await fam.child.sync([ordner(randomUUID(), { audience: 'parents' })]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([ordner(randomUUID(), { parentId: priv })]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([datei(randomUUID(), { ordnerId: priv })]))).toEqual(['invalid']);
      // fremden Ordner ändern/löschen: sichtbar, aber kein Recht; verborgener: nicht gefunden
      expect(codes(await fam.child.sync([upsert('ordner', pub!, { name: 'Neu' }, await revOf('ordner', pub!))]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([remove('ordner', pub!, await revOf('ordner', pub!))]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([upsert('ordner', priv!, { name: 'Neu' }, await revOf('ordner', priv!))]))).toEqual(['not_found']);
      // eigenen umbenennen und die Stufe nicht ändern
      expect(acked(await fam.child.sync([upsert('ordner', eigen, { name: 'Meins' }, await revOf('ordner', eigen))]))).toBe(1);
      expect(codes(await fam.child.sync([upsert('ordner', eigen, { audience: 'parents' }, await revOf('ordner', eigen))]))).toEqual(['forbidden']);
      expect(acked(await fam.child.sync([remove('ordner', eigen, await revOf('ordner', eigen))]))).toBe(1);
    });
  });

  describe('Claim: Fassung beansprucht den Blob atomar', () => {
    it('Datei + Fassung in einem Stapel: Größe, Typ und Prüfsumme setzt der Server; der Blob gehört danach dem Datensatz', async () => {
      const bytes = pdfLike(3333);
      const { dateiId, versionId, blobId } = await neueDatei(fam.parent, bytes);
      const [v] = await rows(sql`select size::int as size, mime, sha256, blob_id from datei_versionen where id = ${versionId}`);
      expect(v).toMatchObject({ size: 3333, mime: 'application/pdf', blob_id: blobId });
      const b = await blobRow(blobId);
      expect(b).toMatchObject({ state: 'claimed', claim_entity: 'datei_version', claim_id: versionId, modus: 'server' });
      expect(v?.sha256).toBe(b?.sha256);
      const wire = (await fam.admin.pull()).find((c) => c.entity === 'datei_version');
      expect(wire?.fields ?? wire?.changes).toMatchObject({ dateiId, nr: 1, blobId, size: 3333, mime: 'application/pdf' });
    });

    it('Doppel-Claim: derselbe Blob in einer zweiten Fassung wird abgelehnt, der erste Besitzer bleibt', async () => {
      const { dateiId, versionId, blobId } = await neueDatei(fam.parent);
      expect(codes(await fam.parent.sync([version(randomUUID(), dateiId, blobId, { nr: 2 })]))).toEqual(['invalid_reference']);
      expect((await blobRow(blobId))?.claim_id).toBe(versionId);
      // auch in einer anderen Datei
      const d2 = randomUUID();
      const res = await fam.parent.sync([datei(d2), version(randomUUID(), d2, blobId)]);
      expect(codes(res)).toEqual(['invalid_reference']);
    });

    it('Atomik im Stapel: zwei Fassungen mit demselben Blob in einem Aufruf: genau eine gewinnt', async () => {
      const blobId = await hoch(fam.parent);
      const d = randomUUID();
      const res = await fam.parent.sync([datei(d), version(randomUUID(), d, blobId, { nr: 1 }), version(randomUUID(), d, blobId, { nr: 2 })]);
      expect(acked(res)).toBe(2); // Datei + erste Fassung
      expect(codes(res)).toEqual(['invalid_reference']);
      expect(await rows(sql`select 1 from datei_versionen where datei_id = ${d}`)).toHaveLength(1);
    });

    it('fremder Upload (andere Person derselben Familie): abgelehnt, bleibt frei für den Besitzer', async () => {
      const blobId = await hoch(fam.admin);
      const d = randomUUID();
      const res = await fam.parent.sync([datei(d), version(randomUUID(), d, blobId)]);
      expect(codes(res)).toEqual(['invalid_reference']);
      expect(await blobRow(blobId)).toMatchObject({ state: 'ready', claim_id: null });
      const mine = randomUUID();
      expect(acked(await fam.admin.sync([datei(mine), version(randomUUID(), mine, blobId)]))).toBe(2);
    });

    it('unbekannte oder fremde Blob-ID, falsche Art, falscher Modus: invalid_reference', async () => {
      const d = randomUUID();
      await fam.parent.sync([datei(d)]);
      expect(codes(await fam.parent.sync([version(randomUUID(), d, randomUUID())]))).toEqual(['invalid_reference']);
      const thumb = (await upload(fam.parent.client, png(), { kind: 'thumb' })).id;
      const e2ee = await hochE2ee(fam.parent);
      const gut = await hoch(fam.parent);
      expect(codes(await fam.parent.sync([version(randomUUID(), d, thumb)]))).toEqual(['invalid_reference']); // Vorschaubild als Inhalt
      expect(codes(await fam.parent.sync([version(randomUUID(), d, e2ee)]))).toEqual(['invalid_reference']); // verschlüsselter Blob in einer Server-Datei
      expect(codes(await fam.parent.sync([version(randomUUID(), d, gut, { thumbBlobId: gut })]))).toEqual(['invalid_reference']); // Inhalt als Vorschau
      expect(codes(await fam.parent.sync([version(randomUUID(), d, gut, { thumbBlobId: e2ee })]))).toEqual(['invalid_reference']);
      // nichts davon blieb beansprucht (auch der erste Blob nicht, der vor der Ablehnung schon dran war)
      for (const b of [thumb, e2ee, gut]) expect((await blobRow(b))?.state).toBe('ready');
      expect(acked(await fam.parent.sync([version(randomUUID(), d, gut, { thumbBlobId: thumb })]))).toBe(1);
    });

    it('Fremde Familie: ein Blob einer anderen Familie lässt sich nicht beanspruchen', async () => {
      const fremd = randomUUID();
      const user = randomUUID();
      const blob = randomUUID();
      await world().db.execute(sql`insert into families (id, name) values (${fremd}, 'Fremd')`);
      await world().db.execute(sql`insert into users (id, email, display_name) values (${user}, 'g@example.org', 'G')`);
      await world().db.execute(sql`insert into datei_blob (id, family_id, uploader_id, modus, kind, size, disk_size, sha256, dek_wrap, kid) values (${blob}, ${fremd}, ${user}, 'server', 'datei', 1, 33, 'x', '\\x00', 1)`);
      const d = randomUUID();
      await fam.parent.sync([datei(d)]);
      expect(codes(await fam.parent.sync([version(randomUUID(), d, blob)]))).toEqual(['invalid_reference']);
      expect((await blobRow(blob))?.state).toBe('ready');
      await world().db.execute(sql`delete from families where id = ${fremd}`);
      await world().db.execute(sql`delete from users where id = ${user}`);
    });

    it('Zurückrollen: scheitert das Anlegen nach dem Beanspruchen (doppelte Nummer), bleibt der Blob frei und ist wieder verwendbar', async () => {
      const { dateiId } = await neueDatei(fam.parent);
      const b2 = await hoch(fam.parent);
      const res = await fam.parent.sync([version(randomUUID(), dateiId, b2, { nr: 1 })]); // Nummer 1 gibt es schon
      expect(codes(res)).toEqual(['not_found']);
      expect(await blobRow(b2)).toMatchObject({ state: 'ready', claim_entity: null, claim_id: null, claimed_at: null });
      expect(acked(await fam.parent.sync([version(randomUUID(), dateiId, b2, { nr: 2 })]))).toBe(1);
    });

    it('Fassung ohne Datei, für gelöschte Datei, mit Serverfeldern, ohne Blob: nichts wird beansprucht', async () => {
      const blobId = await hoch(fam.parent);
      expect(codes(await fam.parent.sync([version(randomUUID(), randomUUID(), blobId)]))).toEqual(['not_found']);
      const d = randomUUID();
      await fam.parent.sync([datei(d)]);
      expect(codes(await fam.parent.sync([version(randomUUID(), d, blobId, { size: 5 })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([version(randomUUID(), d, blobId, { sha256: 'x' })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('datei_version', randomUUID(), { dateiId: d, nr: 1 })]))).toEqual(['invalid']);
      await fam.parent.sync([remove('datei', d, await revOf('dateien', d))]);
      expect(codes(await fam.parent.sync([version(randomUUID(), d, blobId)]))).toEqual(['parent_deleted']);
      expect((await blobRow(blobId))?.state).toBe('ready');
    });

    it('Fassungen sind unveränderlich; weitere Fassung mit neuem Blob; Löschen der Datei löscht die Fassungen', async () => {
      const { dateiId, versionId } = await neueDatei(fam.parent);
      expect(codes(await fam.parent.sync([upsert('datei_version', versionId, { nr: 2 }, await revOf('datei_versionen', versionId))]))).toEqual(['forbidden']);
      const b2 = await hoch(fam.parent, pdfLike(500));
      expect(acked(await fam.parent.sync([version(randomUUID(), dateiId, b2, { nr: 2 })]))).toBe(1);
      expect(acked(await fam.parent.sync([remove('datei', dateiId, await revOf('dateien', dateiId))]))).toBe(1);
      expect(await rows(sql`select 1 from datei_versionen where datei_id = ${dateiId} and deleted_at is null`)).toHaveLength(0);
    });

    it('Kind: Fassung nur für eigene Dateien; der Upload bleibt bei einer Ablehnung frei', async () => {
      const elternDatei = await neueDatei(fam.parent);
      const blobId = await hoch(fam.child);
      const res = await fam.child.sync([version(randomUUID(), elternDatei.dateiId, blobId, { nr: 2 })]);
      expect(codes(res)).toEqual(['forbidden']);
      expect((await blobRow(blobId))?.state).toBe('ready');
      const d = randomUUID();
      expect(acked(await fam.child.sync([datei(d), version(randomUUID(), d, blobId)]))).toBe(2);
      // verborgen anlegen darf das Kind nicht
      const b2 = await hoch(fam.child);
      expect(codes(await fam.child.sync([datei(randomUUID(), { audience: 'parents' })]))).toEqual(['forbidden']);
      expect((await blobRow(b2))?.state).toBe('ready');
    });
  });

  describe('Auslieferung folgt dem Datensatz', () => {
    it('verborgene Datei: nur Eltern/Admins lesen; Freigabe an die Familie öffnet sie für das Kind; Löschen sperrt alle', async () => {
      const { dateiId, blobId, versionId } = await neueDatei(fam.parent, pdfLike(1500), { audience: 'parents', name: 'Müll Plan "2026".pdf' });
      expect(ids(await fam.child.pull(), 'datei_version')).toEqual([]);
      expect((await get(fam.child, blobId)).status).toBe(404);
      for (const d of [fam.parent, fam.admin, papa]) {
        const r = await get(d, blobId);
        expect(r.status, d.userId).toBe(200);
        expect(String(r.headers['content-disposition'])).toBe('attachment; filename="M_ll Plan _2026_.pdf"; filename*=UTF-8\'\'M%C3%BCll%20Plan%20%222026%22.pdf');
        expect(r.headers['content-type']).toBe('application/octet-stream');
      }
      expect(acked(await fam.parent.sync([upsert('datei', dateiId, { audience: 'family' }, await revOf('dateien', dateiId))]))).toBe(1);
      expect((await get(fam.child, blobId)).status).toBe(200);
      // die Fassung kommt mit der Freigabe beim Kind an (sie wird neu angestoßen)
      expect(ids(await fam.child.pull(), 'datei_version')).toEqual([versionId]);
      expect(acked(await fam.parent.sync([upsert('datei', dateiId, { audience: 'parents' }, await revOf('dateien', dateiId))]))).toBe(1);
      expect((await get(fam.child, blobId)).status).toBe(404);
      await fam.parent.sync([remove('datei', dateiId, await revOf('dateien', dateiId))]);
      for (const d of [fam.parent, fam.admin, fam.child]) expect((await get(d, blobId)).status).toBe(404);
    });

    it('Vorschaubild: als Bild mit Cache-Header für alle, die die Datei sehen; der Inhalt bleibt ein Anhang', async () => {
      const thumb = (await upload(fam.parent.client, png(8, 8), { kind: 'thumb' })).id;
      const blobId = await hoch(fam.parent, png(64, 64), { mime: 'image/png' });
      const d = randomUUID();
      expect(acked(await fam.parent.sync([datei(d, { name: 'Foto.png' }), version(randomUUID(), d, blobId, { thumbBlobId: thumb })]))).toBe(2);
      const t = await get(fam.child, thumb);
      expect(t.status).toBe(200);
      expect(t.headers['content-type']).toBe('image/png');
      expect(t.headers['cache-control']).toBe('private, max-age=31536000, immutable');
      expect(String(t.headers['content-disposition'])).toMatch(/^inline;/);
      expect(t.headers['x-content-type-options']).toBe('nosniff');
      expect(t.headers['content-security-policy']).toBe("sandbox; default-src 'none'");
      const o = await get(fam.child, blobId);
      expect(o.headers['content-type']).toBe('application/octet-stream');
      expect(String(o.headers['content-disposition'])).toMatch(/^attachment;/);
    });

    it('Datei eines Kindes (Stufe family) lesen alle; ein Fremder aus derselben Familie ohne Sicht nie', async () => {
      const { blobId } = await neueDatei(fam.child);
      for (const d of [fam.parent, fam.admin, papa, fam.child]) expect((await get(d, blobId)).status).toBe(200);
    });
  });

  describe('Tresor-Anhang (Modus e2ee)', () => {
    const K = () => tresorChatId(fam.familyId);
    const konv = (teilnehmer: Device[]) => upsert('konversation', K(), { art: 'tresor', teilnehmer: teilnehmer.map((t) => t.userId) });
    const anhang = (id: string, blobId: string, fields: Json = {}) => upsert('tresor_anhang', id, { konversationId: K(), blobId, inhalt: E1(), ...fields });
    async function tresor(): Promise<void> {
      const res = await fam.parent.sync([konv([fam.parent, fam.admin])]);
      expect(res.json.rejected, JSON.stringify(res.json)).toEqual([]);
    }

    it('Anhang anlegen: Größe vom Server, Blob gehört dem Anhang; nur Teilnehmer lesen ihn (Bytes unverändert)', async () => {
      await tresor();
      const bytes = randomBytes(4321);
      const blobId = await hochE2ee(fam.parent, bytes);
      const id = randomUUID();
      expect(acked(await fam.parent.sync([anhang(id, blobId)]))).toBe(1);
      expect((await rows(sql`select size::int as size, blob_id from tresor_anhaenge where id = ${id}`))[0]).toMatchObject({ size: 4321, blob_id: blobId });
      expect(await blobRow(blobId)).toMatchObject({ state: 'claimed', claim_entity: 'tresor_anhang', claim_id: id, modus: 'e2ee' });
      for (const d of [fam.parent, fam.admin]) {
        const r = await get(d, blobId);
        expect(r.status).toBe(200);
        expect(Buffer.from(r.body).equals(bytes)).toBe(true);
      }
      // Elternteil ohne Teilnehmerplatz, Kind: nichts, auch kein Hinweis darauf
      for (const d of [papa, fam.child]) expect((await get(d, blobId)).status, d.userId).toBe(404);
      expect(ids(await papa.pull(), 'tresor_anhang')).toEqual([]);
      expect(ids(await fam.child.pull(), 'tresor_anhang')).toEqual([]);
      expect(ids(await fam.admin.pull(), 'tresor_anhang')).toEqual([id]);
    });

    it('Rechte: Kind nie, Nicht-Teilnehmer nie; Claim nur durch die hochladende Person; falscher Modus/Art abgelehnt; unveränderlich', async () => {
      await tresor();
      const blobId = await hochE2ee(fam.parent);
      expect(codes(await fam.child.sync([anhang(randomUUID(), blobId)]))).not.toEqual([]);
      expect(codes(await papa.sync([anhang(randomUUID(), blobId)]))).toEqual(['not_found']);
      expect(codes(await fam.admin.sync([anhang(randomUUID(), blobId)]))).toEqual(['invalid_reference']); // Teilnehmer, aber nicht der Uploader
      expect((await blobRow(blobId))?.state).toBe('ready');
      expect(codes(await fam.parent.sync([anhang(randomUUID(), await hoch(fam.parent))]))).toEqual(['invalid_reference']); // Server-Blob
      expect(codes(await fam.parent.sync([anhang(randomUUID(), randomUUID())]))).toEqual(['invalid_reference']);
      expect(codes(await fam.parent.sync([anhang(randomUUID(), blobId, { inhalt: 'klartext' })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([anhang(randomUUID(), blobId, { size: 3 })]))).toEqual(['invalid']);
      const id = randomUUID();
      expect(acked(await fam.parent.sync([anhang(id, blobId)]))).toBe(1);
      expect(codes(await fam.parent.sync([anhang(randomUUID(), blobId)]))).toEqual(['invalid_reference']); // schon vergeben
      expect(codes(await fam.parent.sync([upsert('tresor_anhang', id, { inhalt: E1(170) }, await revOf('tresor_anhaenge', id))]))).toEqual(['forbidden']); // Anhänge sind unveränderlich
    });

    it('ohne Tresor-Konversation kein Anhang; die Teilnehmerliste entscheidet über die Sicht (Entfernen sperrt den Blob)', async () => {
      const blobId = await hochE2ee(fam.parent);
      expect(codes(await fam.parent.sync([anhang(randomUUID(), blobId)]))).toEqual(['not_found']);
      await tresor();
      const id = randomUUID();
      expect(acked(await fam.parent.sync([anhang(id, blobId)]))).toBe(1);
      expect((await get(fam.admin, blobId)).status).toBe(200);
      const rev = await revOf('konversationen', K());
      expect(acked(await fam.parent.sync([upsert('konversation', K(), { teilnehmer: [fam.parent.userId] }, rev)]))).toBe(1);
      expect((await get(fam.admin, blobId)).status).toBe(404);
      expect((await get(fam.parent, blobId)).status).toBe(200);
    });

    it('Löschen des Anhangs sperrt den Blob sofort, der Blob wird verwaist, nach der Karenz gelöscht', async () => {
      await tresor();
      const blobId = await hochE2ee(fam.parent);
      const id = randomUUID();
      await fam.parent.sync([anhang(id, blobId)]);
      const datei = `${fw.dir}/blobs/${blobId.slice(0, 2)}/${blobId}`;
      expect(existsSync(datei)).toBe(true);
      expect(acked(await fam.admin.sync([remove('tresor_anhang', id, await revOf('tresor_anhaenge', id))]))).toBe(1);
      for (const d of [fam.parent, fam.admin]) expect((await get(d, blobId)).status).toBe(404);
      const usedVorher = (await world().app.inject({ method: 'GET', url: '/api/v1/files/usage', headers: { 'x-forwarded-for': fam.parent.client.ip, cookie: fam.parent.client.cookie ?? '' } })).json().usedBytes;
      expect(usedVorher).toBeGreaterThan(0);
      let r = await runFilesMaintenance(ctx());
      expect(r.orphansMarked).toBe(1);
      expect(existsSync(datei)).toBe(true); // Karenz
      expect((await blobRow(blobId))?.orphaned_at).not.toBeNull();
      // zählt nicht mehr fürs Kontingent
      const usedNachher = (await world().app.inject({ method: 'GET', url: '/api/v1/files/usage', headers: { 'x-forwarded-for': fam.parent.client.ip, cookie: fam.parent.client.cookie ?? '' } })).json().usedBytes;
      expect(usedNachher).toBe(0);
      await world().db.execute(sql`update datei_blob set orphaned_at = orphaned_at - interval '8 days' where id = ${blobId}`);
      r = await runFilesMaintenance(ctx());
      expect(r.blobsDeleted).toBe(1);
      expect(existsSync(datei)).toBe(false);
      expect(await blobRow(blobId)).toBeUndefined();
    });
  });

  describe('Aufräumen verwaister Blobs', () => {
    it('Datei gelöscht -> Blob verwaist (zählt nicht mehr) -> nach 7 Tagen weg; Blobs lebender Dateien bleiben', async () => {
      const a = await neueDatei(fam.parent, pdfLike(800));
      const b = await neueDatei(fam.parent, pdfLike(900));
      await fam.parent.sync([remove('datei', a.dateiId, await revOf('dateien', a.dateiId))]);
      let r = await runFilesMaintenance(ctx());
      expect(r.orphansMarked).toBe(1);
      expect(r.blobsDeleted).toBe(0);
      expect((await blobRow(a.blobId))?.orphaned_at).not.toBeNull();
      expect((await blobRow(b.blobId))?.orphaned_at).toBeNull();
      await world().db.execute(sql`update datei_blob set orphaned_at = orphaned_at - interval '8 days'`);
      r = await runFilesMaintenance(ctx());
      expect(r.blobsDeleted).toBe(1);
      expect(await blobRow(a.blobId)).toBeUndefined();
      expect((await get(fam.parent, b.blobId)).status).toBe(200);
      // ein bereinigter Tombstone (Zeile weg) verwaist den Blob ebenso
      await world().db.execute(sql`delete from datei_versionen where blob_id = ${b.blobId}`);
      r = await runFilesMaintenance(ctx());
      expect(r.orphansMarked).toBe(1);
    });

    it('Blob eines unbekannten Datensatz-Typs bleibt unberührt', async () => {
      const blob = randomUUID();
      const famId = fam.familyId;
      await world().db.execute(sql`insert into datei_blob (id, family_id, uploader_id, modus, kind, size, disk_size, sha256, state, claim_entity, claim_id) values (${blob}, ${famId}, ${fam.parent.userId}, 'e2ee', 'opak', 1, 1, 'x', 'claimed', 'zukunft_typ', ${randomUUID()})`);
      const r = await runFilesMaintenance(ctx());
      expect(r.orphansMarked).toBe(0);
      expect((await blobRow(blob))?.orphaned_at).toBeNull();
    });
  });

  it('Kind kann einen Upload nicht für einen fremden Datensatz benutzen: Upload-Rechte folgen der Person, nicht der Rolle', async () => {
    const c = fam.child.client;
    const id = uploadIdOf(await createUpload(c, 100));
    expect((await patchUpload(fam.parent.client, id, 0, Buffer.alloc(100))).status).toBe(404);
    expect((await patchUpload(c, id, 0, pdfLike(100))).status).toBe(204);
  });
});

describe.each(backends)('Dateien im Sync ohne Schalter (%s)', (backend) => {
  it('Ordner, Dateien, Fassungen und Anhänge werden abgelehnt', async () => {
    const harness = await backend.open();
    const { World } = await import('./helpers.js');
    const world = await World.create(harness.db, {});
    try {
      const f = await createFamily(world);
      for (const op of [upsert('ordner', randomUUID(), { name: 'X' }), upsert('datei', randomUUID(), { name: 'X' })]) {
        expect((await f.parent.sync([op])).json.rejected.map((r: { code: string }) => r.code)).toEqual(['invalid']);
      }
      expect((await f.parent.sync([upsert('datei_version', randomUUID(), { dateiId: randomUUID(), nr: 1, blobId: randomUUID() })])).json.rejected.map((r: { code: string }) => r.code)).toEqual(['not_found']);
    } finally {
      await world.close();
      await harness.close();
    }
  }, 120_000);
});
