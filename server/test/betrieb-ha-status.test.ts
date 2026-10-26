// Betrieb: Block `ingest` in GET /admin/status (Home Assistant): nur Zahlen und Zeiten, nie Token, Päckchen, Namen oder Werte; nur für Betreiber.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';
import { grantOperator } from '../src/operator/service.js';
import { addMember, adminPassword, backends, World, type Client, type Harness } from './helpers.js';

const DAY = 86_400_000;

describe.each(backends)('Betrieb, Einwurf-Status ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv) {
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db, { E2EE_PW_BACKUP: 'true', ...env });
  }
  beforeEach(async () => {
    await neu({ INGEST_ENABLED: 'true' });
  });

  async function einrichten() {
    const a = await adminPassword(world);
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    await grantOperator(world.auth.ctx, a.email);
    const familyId = (await world.db.select().from(schema.families))[0]!.id;
    return { a, kind, familyId };
  }
  async function token(familyId: string, lastUsedMs: number | null) {
    const id = randomUUID();
    const used = lastUsedMs === null ? null : new Date(lastUsedMs).toISOString();
    await world.db.execute(sql`insert into ingest_tokens (id, family_id, name, token_hash, last_used_at) values (${id}, ${familyId}, 'Geheimname', ${'hash-' + id}, ${used})`);
    return id;
  }
  async function paket(familyId: string, tokenId: string, k: string, receivedMs: number) {
    await world.db.execute(sql`insert into ingest_inbox (family_id, token_id, k, box, received_at) values (${familyId}, ${tokenId}, ${k}, ${Buffer.from('geheime-box')}, ${new Date(receivedMs).toISOString()})`);
  }
  const status = async (c: Client) => c.get('/api/v1/admin/status?fresh=1');

  it('liefert Zähler und Zeiten, keine Geheimnisse; Nicht-Betreiber bekommt 404', async () => {
    const f = await einrichten();
    const jetzt = world.clock;
    const t = await token(f.familyId, jetzt - 3_600_000);
    await paket(f.familyId, t, 'k1', jetzt - 5 * 3_600_000);
    await paket(f.familyId, t, 'k2', jetzt - 1_000);
    const res = await status(f.a.client);
    expect(res.status).toBe(200);
    expect(res.json.ingest).toMatchObject({ enabled: true, state: 'ok', tokensActive: 1, inboxCount: 2, inboxLimit: 3000, oldestAgeHours: 5 });
    expect(Date.parse(res.json.ingest.lastDropAt)).toBe(jetzt - 3_600_000);
    expect(Object.keys(res.json.ingest).sort()).toEqual(['enabled', 'inboxCount', 'inboxLimit', 'lastDropAt', 'oldestAgeHours', 'state', 'tokensActive']);
    expect(JSON.stringify(res.json)).not.toMatch(/Geheimname|hash-|geheime-box|"k1"/);
    expect((await status(f.kind.client)).status).toBe(404);
  });

  it('ohne Daten: Zähler 0, Alter null; widerrufene Token zählen nicht; fremde Familien bleiben außen vor', async () => {
    const f = await einrichten();
    const widerrufen = await token(f.familyId, null);
    await world.db.execute(sql`update ingest_tokens set revoked_at = now() where id = ${widerrufen}`);
    const fremd = randomUUID();
    await world.db.execute(sql`insert into families (id, name) values (${fremd}, 'Fremd')`);
    const ft = await token(fremd, world.clock);
    await paket(fremd, ft, 'x', world.clock - 20 * DAY);
    const res = await status(f.a.client);
    expect(res.json.ingest).toMatchObject({ tokensActive: 0, inboxCount: 0, oldestAgeHours: null, lastDropAt: null, state: 'ok' });
  });

  it('Hinweis gelb: ältestes Päckchen über 7 Tage', async () => {
    const f = await einrichten();
    const t = await token(f.familyId, null);
    await paket(f.familyId, t, 'alt', world.clock - 8 * DAY);
    expect((await status(f.a.client)).json.ingest.state).toBe('warn');
  });

  it('Hinweis gelb: Postfach über 80 % der Grenze', async () => {
    const f = await einrichten();
    const t = await token(f.familyId, null);
    await world.db.execute(sql`insert into ingest_inbox (family_id, token_id, k, box, received_at) select ${f.familyId}, ${t}, 'k' || g, ${Buffer.from('b')}, now() from generate_series(1, 2401) g`);
    const res = await status(f.a.client);
    expect(res.json.ingest).toMatchObject({ inboxCount: 2401, state: 'warn' });
  });

  it('Einwurf aus und leer: state off', async () => {
    await neu({});
    const f = await einrichten();
    expect((await status(f.a.client)).json.ingest).toMatchObject({ enabled: false, state: 'off', tokensActive: 0, inboxCount: 0 });
  });
});
