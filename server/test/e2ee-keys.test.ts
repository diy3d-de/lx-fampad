// E2EE Phase 1: öffentliche Personenschlüssel, opake Sicherung, Geräte-Übertragung (PGlite und echtes PostgreSQL).
import { randomBytes } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { runMaintenance } from '../src/auth/maintenance.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const MIN = 60_000;
const key = () => randomBytes(32).toString('base64url');
const blob = (n = 120) => randomBytes(n).toString('base64url');

describe.each(backends)('E2EE-Schlüssel ($name)', (backend) => {
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

  const keys = () => ({ publicEncKey: key(), publicSignKey: key() });

  async function two() {
    const a = await adminPassword(world);
    const b = await addMember(world, a.client, 'parent', 'mama@example.org');
    return { a: a.client, b: b.client };
  }

  it('legt das Schlüsselpaar an, ein zweites Anlegen scheitert, /members liefert die öffentlichen Schlüssel', async () => {
    const { a, b } = await two();
    expect((await a.get('/api/v1/me/keys')).json).toEqual({ keys: null, hasBackup: false });
    const k = keys();
    const made = await a.post('/api/v1/me/keys', k);
    expect(made.status).toBe(200);
    expect(made.json.keys).toEqual({ ...k, keyVersion: 1 });
    const again = await a.post('/api/v1/me/keys', keys());
    expect(again.status).toBe(409);
    expect(again.json.error).toBe('keys_exist');
    const list = (await b.get('/api/v1/members')).json.members as Array<Record<string, unknown>>;
    const admin = list.find((m) => m.displayName === 'Admin');
    const mama = list.find((m) => m.displayName === 'mama');
    expect(admin).toMatchObject({ ...k, keyVersion: 1 });
    expect(mama).toMatchObject({ publicEncKey: null, publicSignKey: null, keyVersion: null });
    expect(await auditEvents(world)).toContain('key_created');
  });

  it('prüft die Form der Schlüssel streng', async () => {
    const { a } = await two();
    for (const bad of [
      { publicEncKey: 'kurz', publicSignKey: key() },
      { publicEncKey: key(), publicSignKey: `${key()}=` },
      { publicEncKey: key(), publicSignKey: `${key().slice(0, 42)}+` },
      { publicEncKey: key() },
      { publicEncKey: key(), publicSignKey: key(), extra: 1 },
      // nicht kanonisch: das letzte Zeichen trägt Bits, die bei 32 Byte nicht vorkommen
      { publicEncKey: `${key().slice(0, 42)}B`, publicSignKey: key() },
    ]) {
      const r = await a.post('/api/v1/me/keys', bad);
      expect(r.status, JSON.stringify(bad)).toBe(400);
    }
    expect((await world.client().post('/api/v1/me/keys', keys())).status).toBe(401);
  });

  it('Schlüsselwechsel verlangt Step-up', async () => {
    const { a } = await two();
    await a.post('/api/v1/me/keys', keys());
    expect((await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
    expect((await a.post('/api/v1/me/key-transfer', { lookup: key(), blob: blob() , keyVersion: 1 })).status).toBe(200);
    world.advance(6 * MIN);
    const denied = await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 });
    expect(denied.status).toBe(403);
    expect(denied.json.error).toBe('step_up_required');
    expect(await world.count('key_backups')).toBe(1);

  });

  it('Schlüsselwechsel mit frischem Step-up', async () => {
    const { a } = await two();
    await a.post('/api/v1/me/keys', keys());
    await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 });
    await a.post('/api/v1/me/key-transfer', { lookup: key(), blob: blob() , keyVersion: 1 });
    const k2 = keys();
    const r = await a.put('/api/v1/me/keys', { ...k2, expectedKeyVersion: 1 });
    expect(r.status).toBe(200);
    expect(r.json.keys).toEqual({ ...k2, keyVersion: 2 });
    expect(await world.count('key_backups')).toBe(0);
    expect(await world.count('key_transfers')).toBe(0);
    expect((await a.get('/api/v1/me/keys')).json).toEqual({ keys: { ...k2, keyVersion: 2 }, hasBackup: false });
    expect(await auditEvents(world)).toContain('key_rotated');
  });

  it('Wechsel ohne vorhandenen Schlüssel: 404', async () => {
    const { a } = await two();
    expect((await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 })).status).toBe(404);
  });

  it('Sicherung: nur mit Schlüssel und passender Version, Step-up für Ablegen und Abrufen, Abruf wird protokolliert', async () => {
    const { a, b } = await two();
    expect((await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).json.error).toBe('no_keys');
    await a.post('/api/v1/me/keys', keys());
    expect((await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 2 })).json.error).toBe('key_version_mismatch');
    expect((await a.get('/api/v1/me/key-backup')).status).toBe(404);
    const bl = blob();
    expect((await a.put('/api/v1/me/key-backup', { blob: bl, keyVersion: 1 })).status).toBe(200);
    expect((await a.get('/api/v1/me/keys')).json.hasBackup).toBe(true);
    const bl2 = blob();
    expect((await a.put('/api/v1/me/key-backup', { blob: bl2, keyVersion: 1 })).status).toBe(200);
    expect((await a.get('/api/v1/me/key-backup')).json).toEqual({ blob: bl2, keyVersion: 1 });
    const ev = await auditEvents(world);
    expect(ev).toContain('backup_set');
    expect(ev).toContain('key_backup_read');
    // eine andere Person sieht die Sicherung nie (eigene Zeile je Person)
    expect((await b.get('/api/v1/me/key-backup')).status).toBe(404);
    // zu großer oder ungültiger Blob
    expect((await a.put('/api/v1/me/key-backup', { blob: 'a'.repeat(2049), keyVersion: 1 })).status).toBe(400);
    expect((await a.put('/api/v1/me/key-backup', { blob: 'ungültig!!', keyVersion: 1 })).status).toBe(400);
    world.advance(6 * MIN);
    expect((await a.get('/api/v1/me/key-backup')).json.error).toBe('step_up_required');
    expect((await a.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).json.error).toBe('step_up_required');
  });

  it('Übertragung: Einmaligkeit, Ablauf nach 2 Minuten, nur dieselbe Person, einheitliche Fehler', async () => {
    const { a, b } = await two();
    await a.post('/api/v1/me/keys', keys());
    await b.post('/api/v1/me/keys', keys());
    const lookup = key();
    const bl = blob();
    const made = await a.post('/api/v1/me/key-transfer', { lookup, blob: bl , keyVersion: 1 });
    expect(made.status).toBe(200);
    expect(made.json.ttlSec).toBe(120);
    // in der Datenbank steht nur der Hash der Suchkennung
    const rows = await harness.db.execute<{ lookup_hash: string }>(sql`select lookup_hash from key_transfers`);
    expect(JSON.stringify(rows.rows)).not.toContain(lookup);
    // fremde Person: gleiche Antwort wie "unbekannt", der Eintrag bleibt
    const foreign = await b.post('/api/v1/me/key-transfer/claim', { lookup });
    const unknown = await b.post('/api/v1/me/key-transfer/claim', { lookup: key() });
    expect(foreign.status).toBe(404);
    expect(foreign.json).toEqual(unknown.json);
    expect(await world.count('key_transfers')).toBe(1);
    // einlösen: genau einmal
    const ok = await a.post('/api/v1/me/key-transfer/claim', { lookup });
    expect(ok.status).toBe(200);
    expect(ok.json).toEqual({ blob: bl, keyVersion: 1 });
    expect((await a.post('/api/v1/me/key-transfer/claim', { lookup })).status).toBe(404);
    expect(await auditEvents(world)).toContain('transfer_claimed');
    // Ablauf
    await a.post('/api/v1/me/key-transfer', { lookup, blob: bl , keyVersion: 1 });
    world.advance(121_000);
    expect((await a.post('/api/v1/me/key-transfer/claim', { lookup })).status).toBe(404);
    const report = await runMaintenance(world.auth.ctx);
    expect(report.keyTransfersDeleted).toBe(1);
    expect(await world.count('key_transfers')).toBe(0);
  });

  it('Übertragung: eine neue ersetzt die offene; ohne Schlüssel nicht möglich; ohne Anmeldung 401', async () => {
    const { a } = await two();
    expect((await a.post('/api/v1/me/key-transfer', { lookup: key(), blob: blob() , keyVersion: 1 })).json.error).toBe('no_keys');
    await a.post('/api/v1/me/keys', keys());
    const l1 = key();
    const l2 = key();
    await a.post('/api/v1/me/key-transfer', { lookup: l1, blob: blob() , keyVersion: 1 });
    await a.post('/api/v1/me/key-transfer', { lookup: l2, blob: blob() , keyVersion: 1 });
    expect(await world.count('key_transfers')).toBe(1);
    expect((await a.post('/api/v1/me/key-transfer/claim', { lookup: l1 })).status).toBe(404);
    expect((await a.post('/api/v1/me/key-transfer/claim', { lookup: l2 })).status).toBe(200);
    expect((await world.client().post('/api/v1/me/key-transfer/claim', { lookup: l2 })).status).toBe(401);
  });

  it('gleichzeitiges Einlösen: genau einer gewinnt', async () => {
    const { a } = await two();
    await a.post('/api/v1/me/keys', keys());
    const lookup = key();
    await a.post('/api/v1/me/key-transfer', { lookup, blob: blob() , keyVersion: 1 });
    const res = await Promise.all(Array.from({ length: 6 }, () => a.post('/api/v1/me/key-transfer/claim', { lookup })));
    expect(res.filter((r) => r.status === 200)).toHaveLength(1);
    expect(res.filter((r) => r.status === 404)).toHaveLength(5);
  });

  it('Schlüsselmaterial erscheint nie in Audit-Details', async () => {
    const { a } = await two();
    const k = keys();
    await a.post('/api/v1/me/keys', k);
    const bl = blob();
    await a.put('/api/v1/me/key-backup', { blob: bl, keyVersion: 1 });
    const audit = JSON.stringify((await harness.db.execute(sql`select detail from audit_log`)).rows);
    expect(audit).not.toContain(k.publicEncKey);
    expect(audit).not.toContain(bl);
  });

  it('Schlüsselwechsel: erwartete Version nötig, Abweichung ergibt 409 und ändert nichts', async () => {
    const { a } = await two();
    const k1 = keys();
    await a.post('/api/v1/me/keys', k1);
    expect((await a.put('/api/v1/me/keys', keys())).status).toBe(400);
    const r = await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 5 });
    expect(r.status).toBe(409);
    expect(r.json.error).toBe('key_version_mismatch');
    expect((await a.get('/api/v1/me/keys')).json.keys).toEqual({ ...k1, keyVersion: 1 });
    expect(await world.count('person_key_history')).toBe(0);
  });

  it('Schlüsselhistorie: jeder Wechsel hängt den alten Stand an; /members liefert nur den aktuellen', async () => {
    const { a, b } = await two();
    const k1 = keys();
    const k2 = keys();
    const k3 = keys();
    await a.post('/api/v1/me/keys', k1);
    await a.put('/api/v1/me/keys', { ...k2, expectedKeyVersion: 1 });
    await a.put('/api/v1/me/keys', { ...k3, expectedKeyVersion: 2 });
    expect(await world.count('person_key_history')).toBe(2);
    const members = (await b.get('/api/v1/members')).json.members as Array<Record<string, unknown>>;
    const adminRow = members.find((m) => m.displayName === 'Admin');
    expect(adminRow).toMatchObject({ ...k3, keyVersion: 3 });
    const id = adminRow?.id as string;
    // andere Familienmitglieder prüfen alte Signaturen gegen die damalige Version
    const v1 = await b.get(`/api/v1/members/${id}/keys?version=1`);
    expect(v1.status).toBe(200);
    expect(v1.json.keys).toHaveLength(1);
    expect(v1.json.keys[0]).toMatchObject({ ...k1, keyVersion: 1 });
    expect(v1.json.keys[0].validUntil).not.toBeNull();
    expect((await b.get(`/api/v1/members/${id}/keys?version=2`)).json.keys[0]).toMatchObject({ ...k2, keyVersion: 2 });
    const aktuell = (await b.get(`/api/v1/members/${id}/keys?version=3`)).json.keys[0];
    expect(aktuell).toMatchObject({ ...k3, keyVersion: 3, validUntil: null });
    const alle = (await b.get(`/api/v1/members/${id}/keys`)).json.keys as Array<{ keyVersion: number }>;
    expect(alle.map((k) => k.keyVersion)).toEqual([1, 2, 3]);
    // Zeiträume schließen lückenlos aneinander an
    const [x, y] = alle as unknown as Array<{ validFrom: string; validUntil: string }>;
    expect(x?.validUntil).toBe(y?.validFrom);
  });

  it('Mitglieder-Schlüssel: nur Familie (IDOR), unbekannte ID/Version 404, ungültige Eingabe 400, Anmeldung nötig', async () => {
    const { a, b } = await two();
    await a.post('/api/v1/me/keys', keys());
    const id = ((await a.get('/api/v1/members')).json.members as Array<{ id: string; displayName: string }>).find((m) => m.displayName === 'Admin')!.id;
    expect((await b.get(`/api/v1/members/${id}/keys?version=9`)).status).toBe(404);
    expect((await b.get('/api/v1/members/00000000-0000-4000-8000-000000000000/keys')).status).toBe(404);
    expect((await b.get(`/api/v1/members/${id}/keys?version=0`)).status).toBe(400);
    expect((await b.get(`/api/v1/members/${id}/keys?version=abc`)).status).toBe(400);
    expect((await b.get(`/api/v1/members/${id}/keys?x=1`)).status).toBe(400);
    expect((await b.get('/api/v1/members/nichtuuid/keys')).status).toBe(400);
    expect((await world.client().get(`/api/v1/members/${id}/keys`)).status).toBe(401);
    // wer nicht mehr zur Familie gehört, liefert nichts mehr
    const mamaId = ((await a.get('/api/v1/members')).json.members as Array<{ id: string; displayName: string }>).find((m) => m.displayName === 'mama')!.id;
    await b.post('/api/v1/me/keys', keys());
    expect((await a.get(`/api/v1/members/${mamaId}/keys`)).status).toBe(200);
    expect((await a.del(`/api/v1/members/${mamaId}`)).status).toBe(200);
    expect((await a.get(`/api/v1/members/${mamaId}/keys`)).status).toBe(404);
  });

  it('Übertragung: keyVersion muss zum Server passen (409), Kollision der Suchkennung ergibt 409 statt 500', async () => {
    const { a, b } = await two();
    await a.post('/api/v1/me/keys', keys());
    await b.post('/api/v1/me/keys', keys());
    const falsch = await a.post('/api/v1/me/key-transfer', { lookup: key(), blob: blob(), keyVersion: 2 });
    expect(falsch.status).toBe(409);
    expect(falsch.json.error).toBe('key_version_mismatch');
    expect(await world.count('key_transfers')).toBe(0);
    expect((await a.post('/api/v1/me/key-transfer', { lookup: key(), blob: blob() })).status).toBe(400);
    const gleich = key();
    expect((await a.post('/api/v1/me/key-transfer', { lookup: gleich, blob: blob(), keyVersion: 1 })).status).toBe(200);
    const kollision = await b.post('/api/v1/me/key-transfer', { lookup: gleich, blob: blob(), keyVersion: 1 });
    expect(kollision.status).toBe(409);
    expect(kollision.json.error).toBe('transfer_conflict');
    // Annahme des Wechsels: Übertragung der alten Version ist danach weg
    await a.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 });
    expect(await world.count('key_transfers')).toBe(0);
  });

  it('Rate-Limit: strenge Grenze auf den Schlüssel-Endpunkten', async () => {
    await world.close();
    world = await World.create(harness.db, { AUTH_RATE_LIMIT_MAX: '5' });
    const a = await adminPassword(world);
    const c: Client = a.client;
    const codes: number[] = [];
    for (let i = 0; i < 12; i++) codes.push((await c.post('/api/v1/me/key-transfer/claim', { lookup: key() })).status);
    expect(codes).toContain(429);
  });
});
