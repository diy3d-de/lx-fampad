// Einwurf: Weitergabe des Postfach-Schlüssels an ein weiteres Gerät derselben Person (Mehrgeräte-Abholen). Der Server reicht nur einen undurchsichtigen Blob weiter:
// nur Eltern/Admins (Kinder 404), 2 Minuten, genau einmal, nur dieselbe Person, einheitliches 404, Schalter aus = 404, Wartungsmodus, Aufräumen, Audit ohne Blob.
import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { runMaintenance } from '../src/auth/maintenance.js';
import { sha256Hex } from '../src/auth/crypto.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, backends, World, type Harness } from './helpers.js';

const ENV = { INGEST_ENABLED: 'true' };
const lookup = (): string => randomBytes(32).toString('base64url');
const blob = (n = 300): string => randomBytes(n).toString('base64url');

describe.each(backends)('Postfach-Weitergabe ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  beforeAll(async () => {
    harness = await backend.open();
  });
  afterAll(async () => {
    await harness.close();
  });
  async function neu(env: NodeJS.ProcessEnv = ENV) {
    await world?.close();
    await harness.reset();
    world = await World.create(harness.db, env);
  }
  beforeEach(async () => {
    await neu();
  });
  async function familie() {
    const a = await adminPassword(world);
    const eltern = await addMember(world, a.client, 'parent', 'mama@example.org');
    const eltern2 = await addMember(world, a.client, 'parent', 'papa@example.org');
    const kind = await addMember(world, a.client, 'child', 'kind@example.org');
    return { a, eltern, eltern2, kind };
  }
  const anlegen = (p: { client: { post: (u: string, b: unknown) => Promise<{ status: number; json: Record<string, unknown> }> } }, l: string, b = blob()) => p.client.post('/api/v1/ingest/postfach-transfer', { lookup: l, blob: b });
  const einloesen = (p: { client: { post: (u: string, b: unknown) => Promise<{ status: number; json: Record<string, unknown> }> } }, l: string) => p.client.post('/api/v1/ingest/postfach-transfer/claim', { lookup: l });

  it('Eltern und Admins legen an und lösen genau einmal ein; der Server hält nur den Hash der Suchkennung', async () => {
    const f = await familie();
    for (const p of [f.eltern, f.a]) {
      const l = lookup();
      const b = blob();
      const res = await anlegen(p, l, b);
      expect(res.status, JSON.stringify(res.json)).toBe(200);
      expect(res.json.ttlSec).toBe(120);
      const rows = await world.db.select().from(schema.ingestPostfachTransfers);
      expect(rows.find((r) => r.lookupHash === sha256Hex(l))?.blob).toBe(b);
      expect(JSON.stringify(rows)).not.toContain(l);
      const ein = await einloesen(p, l);
      expect(ein.status).toBe(200);
      expect(ein.json).toEqual({ blob: b });
      expect((await einloesen(p, l)).status).toBe(404); // nur einmal
    }
    expect(await world.count('ingest_postfach_transfers')).toBe(0);
  });

  it('Kinder und Anonyme: nie (404 bzw. 401)', async () => {
    const f = await familie();
    expect((await anlegen(f.kind, lookup())).status).toBe(404);
    expect((await einloesen(f.kind, lookup())).status).toBe(404);
    expect((await world.client().post('/api/v1/ingest/postfach-transfer', { lookup: lookup(), blob: blob() })).status).toBe(401);
    expect((await world.client().post('/api/v1/ingest/postfach-transfer/claim', { lookup: lookup() })).status).toBe(401);
    expect(await world.count('ingest_postfach_transfers')).toBe(0);
  });

  it('Eine andere Person löst nie ein (auch nicht im selben Haushalt); der Fehlversuch verbraucht nichts', async () => {
    const f = await familie();
    const l = lookup();
    expect((await anlegen(f.eltern, l)).status).toBe(200);
    expect((await einloesen(f.eltern2, l)).status).toBe(404);
    expect((await einloesen(f.a, l)).status).toBe(404);
    expect((await einloesen(f.eltern, lookup())).status).toBe(404); // falsche Kennung
    expect((await einloesen(f.eltern, l)).status).toBe(200); // der Besitzer kommt weiter durch
  });

  it('Abgelaufen nach 2 Minuten: einheitliches 404; das Aufräumen entfernt die Zeile', async () => {
    const f = await familie();
    const l = lookup();
    expect((await anlegen(f.eltern, l)).status).toBe(200);
    world.advance(121_000);
    const res = await einloesen(f.eltern, l);
    expect(res.status).toBe(404);
    expect(await world.count('ingest_postfach_transfers')).toBe(1);
    await runMaintenance(world.auth.ctx);
    expect(await world.count('ingest_postfach_transfers')).toBe(0);
  });

  it('Ein neues Angebot ersetzt das offene derselben Person (das alte ist ungültig)', async () => {
    const f = await familie();
    const l1 = lookup();
    const l2 = lookup();
    expect((await anlegen(f.eltern, l1)).status).toBe(200);
    expect((await anlegen(f.eltern, l2)).status).toBe(200);
    expect(await world.count('ingest_postfach_transfers')).toBe(1);
    expect((await einloesen(f.eltern, l1)).status).toBe(404);
    expect((await einloesen(f.eltern, l2)).status).toBe(200);
  });

  it('Form: Suchkennung 43 Zeichen, Blob 32 bis 1024 Zeichen Base64url, keine Zusatzfelder', async () => {
    const f = await familie();
    expect((await f.eltern.client.post('/api/v1/ingest/postfach-transfer', { lookup: 'kurz', blob: blob() })).status).toBe(400);
    expect((await anlegen(f.eltern, lookup(), 'x'.repeat(31))).status).toBe(400);
    expect((await anlegen(f.eltern, lookup(), 'x'.repeat(1025))).status).toBe(400);
    expect((await anlegen(f.eltern, lookup(), 'a b'.repeat(20))).status).toBe(400);
    expect((await anlegen(f.eltern, lookup(), 'x'.repeat(1024))).status).toBe(200);
    expect((await f.eltern.client.post('/api/v1/ingest/postfach-transfer', { lookup: lookup(), blob: blob(), extra: 1 })).status).toBe(400);
    expect((await f.eltern.client.post('/api/v1/ingest/postfach-transfer/claim', { lookup: lookup(), extra: 1 })).status).toBe(400);
  });

  it('Audit ohne Blob und Suchkennung; kein Sicherheitsereignis zu Personenschlüsseln', async () => {
    const f = await familie();
    const l = lookup();
    const b = blob();
    await anlegen(f.eltern, l, b);
    await einloesen(f.eltern, l);
    const audit = JSON.stringify(await world.db.select().from(schema.auditLog));
    expect(audit).toContain('ingest_postfach_transfer_created');
    expect(audit).toContain('ingest_postfach_transfer_claimed');
    expect(audit).not.toContain(b);
    expect(audit).not.toContain(l);
    expect(audit).not.toContain('key_transfer');
  });

  it('Die Geräte-Übertragung des Personenschlüssels bleibt davon unberührt (eigene Tabelle)', async () => {
    const f = await familie();
    await anlegen(f.eltern, lookup());
    expect(await world.count('key_transfers')).toBe(0);
  });

  it('Schalter aus = 404 auf beiden Routen', async () => {
    await neu({});
    const a = await adminPassword(world);
    expect((await anlegen(a, lookup())).status).toBe(404);
    expect((await einloesen(a, lookup())).status).toBe(404);
  });
});
