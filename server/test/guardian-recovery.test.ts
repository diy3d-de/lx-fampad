// E2EE, Eltern-Wiederherstellung für Kinder (Schalter E2EE_PARENT_RECOVERY): Hinterlegung, Anfrage mit Wartefrist, Übernahme durch ein Elternteil, Offenlegung, Übergabe,
// Abbruch, Ablehnung, Ablauf, Rechte (nur Kinder, nur hinterlegte Eltern, nie fremde Kinder), Schlüsselwechsel, Benachrichtigung, Aufräumen (PGlite und echtes PostgreSQL).
// Der Server rechnet nichts davon nach: die Blobs sind hier Zufallstext.
import { randomBytes } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { runMaintenance } from '../src/auth/maintenance.js';
import { markAccessChanged } from '../src/auth/sessions.js';
import { addMember, adminPassword, auditEvents, backends, World, type Client, type Harness } from './helpers.js';

const HOUR = 3_600_000;
const key = () => randomBytes(32).toString('base64url');
const blob = (n = 112) => randomBytes(n).toString('base64url');
const sig = () => randomBytes(64).toString('base64url');
const keys = () => ({ publicEncKey: key(), publicSignKey: key() });
const nonce = () => randomBytes(16).toString('base64url');

describe.each(backends)('Eltern-Wiederherstellung ($name)', (backend) => {
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
  });

  type Person = { client: Client; totpSecret: string; id: string };
  async function start(env: Record<string, string> = { E2EE_PARENT_RECOVERY: 'true' }) {
    world = await World.create(harness.db, env);
    const a = await adminPassword(world);
    const m = await addMember(world, a.client, 'parent', 'mama@example.org');
    const k = await addMember(world, a.client, 'child', 'kind@example.org');
    const g = await addMember(world, a.client, 'child', 'geschwister@example.org');
    const id = async (email: string) => ((await harness.db.execute<{ id: string }>(sql`select id from users where email = ${email}`)).rows[0] as { id: string }).id;
    const mk = async (r: { client: Client; totpSecret: string }, email: string): Promise<Person> => ({ client: r.client, totpSecret: r.totpSecret, id: await id(email) });
    const f = { papa: await mk(a, 'admin@example.org'), mama: await mk(m, 'mama@example.org'), kind: await mk(k, 'kind@example.org'), geschwister: await mk(g, 'geschwister@example.org') };
    for (const p of Object.values(f)) await p.client.post('/api/v1/me/keys', keys());
    return f;
  }
  type Fam = Awaited<ReturnType<typeof start>>;

  const stepUp = async (p: Person) => {
    world.advance(31_000);
    expect((await p.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(p.totpSecret) })).status).toBe(200);
  };
  const entry = (p: Person) => ({ guardianId: p.id, guardianKeyVersion: 1, blob: blob(), sig: sig() });
  const escrow = (f: Fam, who: Person[] = [f.papa, f.mama], over: Record<string, unknown> = {}) => f.kind.client.put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: who.map(entry), ...over });
  const request = (f: Fam) => f.kind.client.post('/api/v1/me/guardian-recovery', { commit: key() });
  const mine = async (f: Fam) => (await f.kind.client.get('/api/v1/me/guardian-recovery')).json.recovery as Record<string, any> | null; // eslint-disable-line @typescript-eslint/no-explicit-any
  const overview = async (p: Person) => (await p.client.get('/api/v1/guardian/recoveries')).json as Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
  const kinds = async (p: Person) => ((await p.client.get('/api/v1/me/security-events')).json.events as Array<{ kind: string }>).map((e) => e.kind);
  const dbStates = async () => (await harness.db.execute<{ state: string }>(sql`select state from guardian_recoveries order by created_at`)).rows.map((r) => r.state);
  const wait = () => world.advance(24 * HOUR + 1000);

  /** Bis zum Zustand `revealed` (Kurzcode steht), Step-up des Elternteils am Ende frisch. */
  async function bisOffengelegt(f: Fam, bearbeiter: Person = f.papa) {
    expect((await escrow(f)).status).toBe(200);
    const r = await request(f);
    expect(r.status).toBe(200);
    const id = r.json.recovery.id as string;
    wait();
    await stepUp(bearbeiter);
    expect((await bearbeiter.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() })).status).toBe(200);
    expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).status).toBe(200);
    return id;
  }

  describe('Schalter aus (Standard)', () => {
    it('Routen gibt es nicht (404, auch mit Anmeldung)', async () => {
      const f = await start({});
      expect((await f.kind.client.get('/api/v1/me/guardian-escrow')).status).toBe(404);
      expect((await escrow(f)).status).toBe(404);
      expect((await request(f)).status).toBe(404);
      expect((await f.papa.client.get('/api/v1/guardian/recoveries')).status).toBe(404);
      expect(await world.count('guardian_escrows')).toBe(0);
    });
  });

  describe('Hinterlegung', () => {
    it('nur Kinder: Erwachsene bekommen 403 (Eltern und Admin), Status meldet eligible=false', async () => {
      const f = await start();
      await stepUp(f.papa);
      await stepUp(f.mama);
      for (const p of [f.papa, f.mama]) {
        const r = await p.client.put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: [entry(p === f.papa ? f.mama : f.papa)] });
        expect(r.status, 'Erwachsene dürfen nie hinterlegen').toBe(403);
        expect((await p.client.post('/api/v1/me/guardian-recovery', { commit: key() })).status).toBe(403);
        expect((await p.client.get('/api/v1/me/guardian-escrow')).json).toMatchObject({ eligible: false, enabled: false });
      }
      expect((await f.kind.client.get('/api/v1/me/guardian-escrow')).json).toMatchObject({ eligible: true, enabled: false, guardians: [] });
      expect(await world.count('guardian_escrows')).toBe(0);
    });

    it('legt Einträge an (Step-up), Status nennt Namen und Versionen, nie Blobs; Audit und Ereignis ohne Inhalt', async () => {
      const f = await start();
      await stepUp(f.kind);
      const r = await escrow(f);
      expect(r.status).toBe(200);
      const s = (await f.kind.client.get('/api/v1/me/guardian-escrow')).json;
      expect(s).toMatchObject({ eligible: true, enabled: true, keyVersion: 1 });
      expect(s.guardians.map((g: { id: string }) => g.id).sort()).toEqual([f.papa.id, f.mama.id].sort());
      expect(JSON.stringify(s)).not.toMatch(/blob|sig"/);
      expect(await auditEvents(world)).toContain('guardian_escrow_set');
      expect(await kinds(f.kind)).toContain('guardian_escrow_set');
      expect(JSON.stringify((await harness.db.execute(sql`select detail from audit_log`)).rows)).not.toMatch(/[A-Za-z0-9_-]{100,}/);
    });

    it('verlangt Anmeldung, Step-up und strenge Form; Version und Eltern werden geprüft (409)', async () => {
      const f = await start();
      expect((await world.client().put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: [entry(f.papa)] })).status).toBe(401);
      world.advance(6 * 60_000);
      expect((await escrow(f)).json.error).toBe('step_up_required');
      await stepUp(f.kind);
      for (const bad of [
        { keyVersion: 0, entries: [entry(f.papa)] },
        { keyVersion: 1, entries: [] },
        { keyVersion: 1, entries: [{ ...entry(f.papa), blob: 'kurz' }] },
        { keyVersion: 1, entries: [{ ...entry(f.papa), sig: 'kurz' }] },
        { keyVersion: 1, entries: [{ ...entry(f.papa), extra: 1 }] },
        { keyVersion: 1, entries: [{ ...entry(f.papa), guardianId: 'keine-uuid' }] },
        { keyVersion: 1, entries: [entry(f.papa), entry(f.papa)] }, // doppelt
        { keyVersion: 1, entries: Array.from({ length: 9 }, () => entry(f.papa)) },
      ]) {
        expect((await f.kind.client.put('/api/v1/me/guardian-escrow', bad)).status, JSON.stringify(bad).slice(0, 70)).toBe(400);
      }
      expect((await escrow(f, [f.papa], { keyVersion: 2 })).json.error).toBe('key_version_mismatch');
      expect((await f.kind.client.put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: [{ ...entry(f.papa), guardianKeyVersion: 2 }] })).json.error).toBe('guardian_key_changed');
      expect((await escrow(f, [f.geschwister])).json.error).toBe('guardian_invalid'); // ein Kind ist kein Elternteil
      expect((await escrow(f, [f.kind])).status).toBe(400); // nie sich selbst
      expect(await world.count('guardian_escrows')).toBe(0);
    });

    it('Aktualisieren ersetzt die Liste: nicht mehr gewählte Eltern verlieren ihren Eintrag; Zurücknehmen löscht alles und beendet eine offene Anfrage', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f, [f.papa, f.mama]);
      await escrow(f, [f.mama]);
      // nie überschrieben oder hart gelöscht: Papa (nicht mehr gewählt) ist revoked, der ersetzte Eintrag von Mama superseded, der neue active
      const zustaende = async () => (await harness.db.execute<{ state: string }>(sql`select state from guardian_escrows order by state`)).rows.map((x) => x.state);
      expect(await zustaende()).toEqual(['active', 'revoked', 'superseded']);
      expect((await f.kind.client.get('/api/v1/me/guardian-escrow')).json.guardians.map((g: { id: string }) => g.id)).toEqual([f.mama.id]);
      const r = await request(f);
      expect(r.status).toBe(200);
      expect((await f.kind.client.del('/api/v1/me/guardian-escrow')).json.removed).toBe(true);
      expect(await zustaende()).toEqual(['revoked', 'revoked', 'superseded']);
      expect((await f.kind.client.get('/api/v1/me/guardian-escrow')).json).toMatchObject({ enabled: false, guardians: [] });
      expect(await dbStates()).toEqual(['cancelled']);
      await stepUp(f.kind);
      expect((await f.kind.client.del('/api/v1/me/guardian-escrow')).json.removed).toBe(false);
      expect(await kinds(f.kind)).toContain('guardian_escrow_removed');
    });
  });

  describe('Hinterlegung: Löschfrist', () => {
    it('Ersetzte und zurückgenommene Hinterlegungen verschwinden erst nach der Löschfrist von 30 Tagen (Aufräumjob), vorher nie', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f, [f.papa]);
      await escrow(f, [f.papa]);
      expect((await f.kind.client.del('/api/v1/me/guardian-escrow')).status).toBe(200);
      expect(await world.count('guardian_escrows')).toBe(2);
      world.advance(29 * 24 * HOUR);
      await runMaintenance(world.auth.ctx);
      expect(await world.count('guardian_escrows')).toBe(2);
      world.advance(2 * 24 * HOUR);
      await runMaintenance(world.auth.ctx);
      expect(await world.count('guardian_escrows')).toBe(0);
    });
  });

  describe('Anfrage und Ablauf', () => {
    it('ohne Hinterlegung keine Anfrage (409), ohne Step-up 403; eine Anfrage legt Frist fest und benachrichtigt Kind und Eltern', async () => {
      const f = await start();
      await stepUp(f.kind);
      expect((await request(f)).json.error).toBe('no_escrow');
      await escrow(f, [f.papa, f.mama]);
      world.advance(6 * 60_000);
      expect((await request(f)).json.error).toBe('step_up_required');
      await stepUp(f.kind);
      const r = await request(f);
      expect(r.status).toBe(200);
      const rec = r.json.recovery;
      expect(rec).toMatchObject({ state: 'pending', keyVersion: 1, guardianId: null, challenge: null, releaseBlob: null });
      expect(Date.parse(rec.readyAt) - world.clock).toBe(24 * HOUR);
      expect(Date.parse(rec.expiresAt) - Date.parse(rec.readyAt)).toBe(72 * HOUR);
      // zweite offene Anfrage: nein
      await stepUp(f.kind);
      expect((await request(f)).json.error).toBe('recovery_open');
      // Hinweise: Kind (andere Geräte) und beide Eltern, ohne Inhalt
      expect(await kinds(f.kind)).toContain('guardian_recovery_requested');
      expect(await kinds(f.papa)).toContain('guardian_recovery_asked');
      expect(await kinds(f.mama)).toContain('guardian_recovery_asked');
      const ev = (await f.papa.client.get('/api/v1/me/security-events')).json.events as Array<{ kind: string; subjectName: string | null }>;
      expect(ev.find((e) => e.kind === 'guardian_recovery_asked')?.subjectName).toBe('kind');
      expect(await auditEvents(world)).toContain('guardian_recovery_requested');
    });

    it('die Wartefrist gilt: vor Ablauf kann kein Elternteil übernehmen; danach genau eines (atomar)', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      const id = (await request(f)).json.recovery.id as string;
      await stepUp(f.papa);
      const early = await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() });
      expect(early.status).toBe(409);
      expect(early.json.error).toBe('recovery_wait');
      wait();
      await stepUp(f.papa);
      await stepUp(f.mama);
      const [x, y] = await Promise.all([
        f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() }),
        f.mama.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() }),
      ]);
      expect([x.status, y.status].sort()).toEqual([200, 409]);
      const [{ guardian_id }] = (await harness.db.execute<{ guardian_id: string }>(sql`select guardian_id from guardian_recoveries`)).rows as [{ guardian_id: string }];
      expect([f.papa.id, f.mama.id]).toContain(guardian_id);
      expect((await mine(f))?.state).toBe('challenged');
      expect(await kinds(f.kind)).toContain('guardian_recovery_challenged');
    });

    it('Übernahme verlangt Step-up und einen Eintrag für dieses Elternteil (sonst 404, auch für Erwachsene ohne Eintrag und Kinder)', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f, [f.papa]); // nur Papa
      const id = (await request(f)).json.recovery.id as string;
      wait();
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() })).json.error).toBe('step_up_required');
      await stepUp(f.mama);
      expect((await f.mama.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() })).status).toBe(404); // kein Eintrag
      await stepUp(f.geschwister);
      expect((await f.geschwister.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() })).status).toBe(403); // ein Kind ist kein Elternteil
      expect((await f.mama.client.post(`/api/v1/guardian/recoveries/${id}/decline`)).status).toBe(404);
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: 'kurz' })).status).toBe(400);
      expect(await dbStates()).toEqual(['pending']);
    });

    it('voller Ablauf: Übernahme, Offenlegung, Übergabe, Abholen; die Übergabe sieht nur das Kind, danach sind alle Übergabedaten gelöscht', async () => {
      const f = await start();
      await stepUp(f.kind);
      const id = await bisOffengelegt(f);
      // Sicht der Eltern: Bearbeiter sieht Offenlegung und seinen Eintrag, ein anderes Elternteil nur den Zustand
      const ovPapa = await overview(f.papa);
      expect(ovPapa.requests).toHaveLength(1);
      expect(ovPapa.requests[0]).toMatchObject({ id, state: 'revealed', childName: 'kind', guardianId: f.papa.id });
      expect(typeof ovPapa.requests[0].revealPub).toBe('string');
      expect(typeof ovPapa.requests[0].escrow.blob).toBe('string');
      expect(ovPapa.requests[0].releaseBlob).toBeNull();
      const ovMama = await overview(f.mama);
      expect(ovMama.requests[0]).toMatchObject({ id, state: 'revealed', challenge: null, revealPub: null, revealNonce: null, escrow: null });
      expect(ovMama.children.map((c: { id: string }) => c.id)).toEqual([f.kind.id]);
      // Übergabe: nur der Bearbeiter, nur mit Step-up
      const rel = { blob: blob(), sig: sig() };
      await stepUp(f.mama);
      expect((await f.mama.client.post(`/api/v1/guardian/recoveries/${id}/release`, rel)).json.error).toBe('recovery_state');
      world.advance(6 * 60_000);
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/release`, rel)).json.error).toBe('step_up_required');
      await stepUp(f.papa);
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/release`, rel)).status).toBe(200);
      const m = await mine(f);
      expect(m).toMatchObject({ state: 'released', releaseBlob: rel.blob, releaseSig: rel.sig, guardianId: f.papa.id, guardianName: 'Admin' });
      expect((await overview(f.papa)).requests[0].releaseBlob).toBeNull(); // auch der Bearbeiter bekommt die Übergabe nie zurück
      expect(await kinds(f.kind)).toContain('guardian_recovery_released');
      // Abholen
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/done`)).status).toBe(200);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/done`)).status).toBe(200); // verlorene Antwort: folgenlos
      expect(await dbStates()).toEqual(['done']);
      const row = (await harness.db.execute<Record<string, unknown>>(sql`select release_blob, release_sig, reveal_pub, reveal_nonce, challenge from guardian_recoveries`)).rows[0];
      expect(Object.values(row ?? {}).every((v) => v === null)).toBe(true);
      expect((await mine(f))?.state).toBe('done');
    });

    it('Reihenfolge der Zustände wird erzwungen (Offenlegung nur nach Übernahme, Übergabe nur nach Offenlegung)', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      const id = (await request(f)).json.recovery.id as string;
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).json.error).toBe('recovery_state');
      wait();
      await stepUp(f.papa);
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/release`, { blob: blob(), sig: sig() })).json.error).toBe('recovery_state');
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/done`)).json.error).toBe('recovery_state');
      await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() });
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/release`, { blob: blob(), sig: sig() })).json.error).toBe('recovery_state'); // noch nicht offengelegt
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: 'kurz', nonce: nonce() })).status).toBe(400);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).status).toBe(200);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).json.error).toBe('recovery_state'); // nur einmal
    });

    it('Abbrechen: das Kind von jedem Gerät ohne Step-up, Übergabedaten verschwinden, die Eltern erfahren es', async () => {
      const f = await start();
      await stepUp(f.kind);
      const id = await bisOffengelegt(f);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/cancel`)).status).toBe(200);
      expect(await dbStates()).toEqual(['cancelled']);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/cancel`)).json.error).toBe('recovery_state');
      expect((await f.geschwister.client.post(`/api/v1/me/guardian-recovery/${id}/cancel`)).status).toBe(404); // fremde Anfrage
      expect(await kinds(f.papa)).toContain('guardian_recovery_ended');
      expect(await kinds(f.kind)).toContain('guardian_recovery_ended');
      expect((await overview(f.papa)).requests).toHaveLength(0);
      // danach geht eine neue Anfrage
      await stepUp(f.kind);
      expect((await request(f)).status).toBe(200);
    });

    it('Ablehnen: jedes hinterlegte Elternteil ohne Step-up (zum Beispiel bei falschem Kurzcode); das Kind bekommt einen Hinweis', async () => {
      const f = await start();
      await stepUp(f.kind);
      const id = await bisOffengelegt(f);
      expect((await f.mama.client.post(`/api/v1/guardian/recoveries/${id}/decline`)).status).toBe(200);
      expect(await dbStates()).toEqual(['declined']);
      expect(await kinds(f.kind)).toContain('guardian_recovery_ended');
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/decline`)).json.error).toBe('recovery_state');
    });

    it('Verfall: nach Wartefrist plus drei Tagen endet die Anfrage (Aufräumjob und beim Abfragen), Daten gelöscht, Zeile als Spur', async () => {
      const f = await start();
      await stepUp(f.kind);
      const id = await bisOffengelegt(f);
      world.advance(73 * HOUR);
      await runMaintenance(world.auth.ctx);
      expect(await dbStates()).toEqual(['expired']);
      expect((await mine(f))?.state).toBe('expired');
      const row = (await harness.db.execute<Record<string, unknown>>(sql`select reveal_pub, challenge from guardian_recoveries`)).rows[0];
      expect(Object.values(row ?? {}).every((v) => v === null)).toBe(true);
      await stepUp(f.papa);
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/release`, { blob: blob(), sig: sig() })).json.error).toBe('recovery_state');
      // beim Abfragen ohne Aufräumjob: dasselbe
      await stepUp(f.kind);
      const id2 = (await request(f)).json.recovery.id as string;
      world.advance(24 * HOUR + 73 * HOUR);
      expect((await mine(f))?.state).toBe('expired');
      expect(id2).not.toBe(id);
    });

    it('Schlüsselwechsel des Kindes: Einträge veralten (bleiben liegen), offene Anfrage endet, neue Anfrage braucht eine neue Hinterlegung', async () => {
      const f = await start();
      await stepUp(f.kind);
      await bisOffengelegt(f);
      await stepUp(f.kind);
      expect((await f.kind.client.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 })).status).toBe(200);
      expect(await dbStates()).toEqual(['cancelled']);
      expect((await harness.db.execute<{ state: string }>(sql`select distinct state from guardian_escrows`)).rows.map((r) => r.state)).toEqual(['stale']);
      expect((await f.kind.client.get('/api/v1/me/guardian-escrow')).json.guardians.every((g: { stale: boolean }) => g.stale)).toBe(true);
      await stepUp(f.kind);
      expect((await request(f)).json.error).toBe('no_escrow');
    });

    it('Schlüsselwechsel eines Elternteils macht dessen Eintrag unbrauchbar (nur das andere Elternteil zählt)', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      await stepUp(f.papa);
      await f.papa.client.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 });
      const s = (await f.kind.client.get('/api/v1/me/guardian-escrow')).json.guardians as Array<{ id: string; stale: boolean }>;
      expect(s.find((g) => g.id === f.papa.id)?.stale).toBe(true);
      expect(s.find((g) => g.id === f.mama.id)?.stale).toBe(false);
      await stepUp(f.kind);
      const id = (await request(f)).json.recovery.id as string;
      wait();
      await stepUp(f.papa);
      expect((await f.papa.client.get('/api/v1/guardian/recoveries')).json.children.find((c: { id: string }) => c.id === f.kind.id).stale).toBe(true);
      // das Elternteil mit geändertem Schlüssel kann nicht übernehmen (es könnte die Hinterlegung nicht öffnen): die Anfrage bliebe sonst hängen
      await stepUp(f.papa);
      const papa = await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() });
      expect(papa.status).toBe(409);
      expect(papa.json.error).toBe('escrow_stale');
      await stepUp(f.mama);
      expect((await f.mama.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() })).status).toBe(200);
    });

    it('Rechte (IDOR): fremde Kinder und fremde Anfragen sind unsichtbar; ein zweites Kind sieht nichts vom ersten', async () => {
      const f = await start();
      await stepUp(f.kind);
      const id = await bisOffengelegt(f);
      expect((await f.geschwister.client.get('/api/v1/me/guardian-recovery')).json.recovery).toBeNull();
      expect((await f.geschwister.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).status).toBe(404);
      expect((await f.geschwister.client.post(`/api/v1/me/guardian-recovery/${id}/done`)).status).toBe(404);
      // ein Elternteil ohne Eintrag für dieses Kind sieht die Anfrage nicht
      await stepUp(f.kind);
      expect((await escrow(f, [f.papa])).status).toBe(200);
      expect((await overview(f.mama)).requests).toHaveLength(0);
      expect((await overview(f.mama)).children).toHaveLength(0);
    });

    it('Nach dem Entfernen eines Elternteils bzw. Kindes verschwinden die Hinterlegungen (Kaskade); Datenbank erzwingt Zustände', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      const ids = (await harness.db.execute<{ family_id: string }>(sql`select family_id from memberships limit 1`)).rows[0] as { family_id: string };
      await expect(
        harness.db.execute(sql`insert into guardian_recoveries (family_id, child_id, state, key_version, commit, ready_at, expires_at) values (${ids.family_id}, ${f.kind.id}, 'kaputt', 1, ${key()}, now(), now())`),
      ).rejects.toThrow();
      await expect(
        harness.db.execute(sql`insert into guardian_escrows (family_id, child_id, guardian_id, key_version, guardian_key_version, blob, sig) values (${ids.family_id}, ${f.kind.id}, ${f.kind.id}, 1, 1, ${blob()}, ${sig()})`),
      ).rejects.toThrow(); // nie sich selbst
      await world.db.execute(sql`delete from memberships where user_id = ${f.mama.id}`);
      expect(await world.count('guardian_escrows')).toBe(1);
    });
  });

  describe('Reset, Sperrfrist, Rollenwechsel (ein übernommenes Kinder-Konto bekommt nie den Schlüssel)', () => {
    const escrowStates = async () => (await harness.db.execute<{ state: string }>(sql`select state from guardian_escrows order by state`)).rows.map((r) => r.state);

    it('Komplett-Reset des Kindes: Hinterlegungen werden veraltet (nie gelöscht), offene Anfragen enden, danach keine Anfrage möglich', async () => {
      const f = await start();
      await stepUp(f.kind);
      const id = await bisOffengelegt(f);
      expect(id).toBeTruthy();
      await stepUp(f.papa);
      const r = await f.papa.client.post(`/api/v1/members/${f.kind.id}/reset`, {});
      expect(r.status).toBe(200);
      expect(await escrowStates()).toEqual(['stale', 'stale']);
      expect(await dbStates()).toEqual(['cancelled']);
      const row = (await harness.db.execute<Record<string, unknown>>(sql`select release_blob, reveal_pub, challenge from guardian_recoveries`)).rows[0];
      expect(Object.values(row ?? {}).every((v) => v === null)).toBe(true);
      expect(await world.count('guardian_escrows')).toBe(2);
      // die Eltern sehen das Kind mit veralteter Hinterlegung, nicht als Hilfsfall
      expect((await overview(f.papa)).children[0]).toMatchObject({ stale: true });
      expect((await overview(f.papa)).requests).toHaveLength(0);
    });

    it('Änderung der Anmeldedaten (markAccessChanged): Hinterlegung veraltet, Anfrage endet; ebenso der Rollenwechsel zum Elternteil', async () => {
      const f = await start();
      await stepUp(f.kind);
      await bisOffengelegt(f);
      await markAccessChanged(world.auth.ctx, harness.db, f.kind.id);
      expect(await escrowStates()).toEqual(['stale', 'stale']);
      expect(await dbStates()).toEqual(['cancelled']);
      // Rollenwechsel: Hinterlegungen als Kind UND als Elternteil werden veraltet
      await harness.db.execute(sql`update guardian_escrows set state = 'active'`);
      await stepUp(f.papa);
      expect((await f.papa.client.patch(`/api/v1/members/${f.kind.id}/role`, { role: 'parent' })).status).toBe(200);
      expect(await escrowStates()).toEqual(['stale', 'stale']);
      await harness.db.execute(sql`update guardian_escrows set state = 'active'`);
      await stepUp(f.papa);
      expect((await f.papa.client.patch(`/api/v1/members/${f.mama.id}/role`, { role: 'child' })).status).toBe(200);
      expect(await escrowStates()).toEqual(['active', 'stale']);
    });

    it('Nach Anmeldung mit Wiederherstellungscode, Reset oder Änderung der Anmeldedaten sind Hinterlegen, Zurücknehmen und Anfragen 24 Stunden gesperrt', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      await harness.db.execute(sql`update sessions set origin = 'recovery_code', origin_at = ${new Date(world.clock).toISOString()} where user_id = ${f.kind.id}`);
      await stepUp(f.kind);
      for (const r of [await escrow(f), await request(f), await f.kind.client.del('/api/v1/me/guardian-escrow')]) {
        expect(r.status).toBe(403);
        expect(r.json.error).toBe('destructive_locked');
      }
      expect(await escrowStates()).toEqual(['active', 'active']);
      expect(await dbStates()).toEqual([]);
      world.advance(25 * HOUR);
      await stepUp(f.kind);
      expect((await request(f)).status).toBe(200);
    });

    it('Registrierung nach einem Komplett-Reset (Reset-Einladung): die neue Sitzung ist 24 Stunden gesperrt (Hinterlegen, Anfragen, Schlüsselwechsel), danach frei', async () => {
      const f = await start();
      await stepUp(f.kind);
      expect((await escrow(f)).status).toBe(200);
      await stepUp(f.papa);
      const reset = await f.papa.client.post(`/api/v1/members/${f.kind.id}/reset`, { hours: 2, pin: false });
      expect(reset.status).toBe(200);
      world.advance(31_000);
      const neu = await world.registerPassword(reset.json.invite.token, { email: 'kind@example.org' });
      expect(neu.complete?.status).toBe(200);
      const origin = (await harness.db.execute<{ origin: string }>(sql`select origin from sessions where user_id = ${f.kind.id} and revoked_at is null`)).rows;
      expect(origin.map((r) => r.origin)).toEqual(['password_reset']);
      const c = neu.client;
      await stepUp({ ...f.kind, client: c, totpSecret: neu.totpSecret });
      for (const r of [
        await c.put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: [entry(f.papa)] }),
        await c.post('/api/v1/me/guardian-recovery', { commit: key() }),
        await c.put('/api/v1/me/keys', { ...keys(), expectedKeyVersion: 1 }),
      ]) {
        expect(r.status).toBe(403);
        expect(r.json.error).toBe('destructive_locked');
      }
      // auch eine spätere normale Anmeldung binnen 24 h erbt die Sperre (Änderung der Anmeldedaten)
      world.advance(31_000);
      const c2 = world.client('203.0.113.170');
      const l = await c2.post('/api/v1/auth/login/password', { email: 'kind@example.org', password: neu.password, totp: await world.totp(neu.totpSecret) });
      expect(l.status).toBe(200);
      c2.adopt(l.json.session);
      expect((await c2.put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: [entry(f.papa)] })).json.error).toBe('destructive_locked');
      world.advance(25 * HOUR);
      await stepUp({ ...f.kind, client: c2, totpSecret: neu.totpSecret });
      expect((await c2.put('/api/v1/me/guardian-escrow', { keyVersion: 1, entries: [entry(f.papa)] })).status).toBe(200);
    });

    it('Offenlegen bindet die Zufallszahl, die das Kind gesehen hat: eine ausgetauschte wird nicht offengelegt (409), die gesehene schon', async () => {
      const f = await start();
      await stepUp(f.kind);
      expect((await escrow(f)).status).toBe(200);
      const id = (await request(f)).json.recovery.id as string;
      wait();
      await stepUp(f.papa);
      const ch = nonce();
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: ch })).status).toBe(200);
      const falsch = (await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce(), challenge: nonce() }));
      expect(falsch.status).toBe(409);
      expect(falsch.json.error).toBe('recovery_state');
      expect(await dbStates()).toEqual(['challenged']);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce(), challenge: ch })).status).toBe(200);
      expect(await dbStates()).toEqual(['revealed']);
    });

    it('Gerätebindung: Zufallszahl, Übergabe und Abschluss nur auf dem Gerät, das die Anfrage gestellt hat; Abbrechen von jedem Gerät', async () => {
      const f = await start();
      const appLogin = async (ip: string) => {
        world.advance(31_000);
        const c = world.client(ip);
        const r = await c.post('/api/v1/auth/login/password', { email: 'kind@example.org', password: 'ein-sehr-langes-passwort-123', totp: await world.totp(f.kind.totpSecret), client: 'app', device: { name: 'Handy', platform: 'android' } });
        expect(r.status).toBe(200);
        c.adopt(r.json.session);
        return c;
      };
      const a = await appLogin('203.0.113.51');
      const b = await appLogin('203.0.113.52');
      await stepUp(f.kind);
      await escrow(f);
      world.advance(31_000);
      expect((await a.post('/api/v1/auth/step-up/code', { totp: await world.totp(f.kind.totpSecret) })).status).toBe(200);
      const id = (await a.post('/api/v1/me/guardian-recovery', { commit: key() })).json.recovery.id as string;
      // die Wartefrist ist vorbei (Zugangstoken der Geräte laufen sonst ab: die Uhr bleibt stehen)
      await harness.db.execute(sql`update guardian_recoveries set ready_at = ${new Date(world.clock - HOUR).toISOString()}`);
      await stepUp(f.papa);
      await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() });
      const vonA = (await a.get('/api/v1/me/guardian-recovery')).json.recovery;
      const vonB = (await b.get('/api/v1/me/guardian-recovery')).json.recovery;
      expect(vonA.challenge).toEqual(expect.any(String));
      expect(vonB.state).toBe('challenged');
      expect(vonB.challenge).toBeNull();
      // ein anderes Gerät kann weder offenlegen noch abschließen
      expect((await b.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).status).toBe(409);
      expect((await a.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).status).toBe(200);
      await stepUp(f.papa);
      expect((await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/release`, { blob: blob(), sig: sig() })).status).toBe(200);
      expect((await b.get('/api/v1/me/guardian-recovery')).json.recovery.releaseBlob).toBeNull();
      expect((await a.get('/api/v1/me/guardian-recovery')).json.recovery.releaseBlob).toEqual(expect.any(String));
      const done = await b.post(`/api/v1/me/guardian-recovery/${id}/done`);
      expect(done.status).toBe(409);
      expect(done.json.error).toBe('recovery_device');
      // abbrechen geht von jedem Gerät
      expect((await b.post(`/api/v1/me/guardian-recovery/${id}/cancel`)).status).toBe(200);
      expect(await dbStates()).toEqual(['cancelled']);
    });

    it('Eine übernommene Anfrage ohne Fortschritt hängt nicht fest: nach 12 Stunden wieder frei; nach der Offenlegung endet sie (nie ein zweites Offenlegen)', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      const id = (await request(f)).json.recovery.id as string;
      wait();
      await stepUp(f.papa);
      await f.papa.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() });
      world.advance(11 * HOUR);
      expect((await mine(f))?.state).toBe('challenged');
      world.advance(2 * HOUR);
      const frei = await mine(f);
      expect(frei).toMatchObject({ state: 'pending', guardianId: null, challenge: null });
      await stepUp(f.mama);
      expect((await f.mama.client.post(`/api/v1/guardian/recoveries/${id}/challenge`, { challenge: nonce() })).status).toBe(200);
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/reveal`, { pub: key(), nonce: nonce() })).status).toBe(200);
      world.advance(13 * HOUR);
      expect((await mine(f))?.state).toBe('expired');
      const row = (await harness.db.execute<Record<string, unknown>>(sql`select reveal_pub, reveal_nonce, challenge from guardian_recoveries`)).rows[0];
      expect(Object.values(row ?? {}).every((v) => v === null)).toBe(true);
    });

    it('Eine beendete Anfrage zeigt das Kind höchstens 24 Stunden lang', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      const id = (await request(f)).json.recovery.id as string;
      expect((await f.kind.client.post(`/api/v1/me/guardian-recovery/${id}/cancel`)).status).toBe(200);
      expect((await mine(f))?.state).toBe('cancelled');
      world.advance(25 * HOUR);
      expect(await mine(f)).toBeNull();
      expect(await world.count('guardian_recoveries')).toBe(1);
    });

    it('Die Anfrage nennt dem Kind seine eigene Verpflichtung (zum Zuordnen nach verlorener Antwort)', async () => {
      const f = await start();
      await stepUp(f.kind);
      await escrow(f);
      const commit = key();
      const r = await f.kind.client.post('/api/v1/me/guardian-recovery', { commit });
      expect(r.json.recovery.commit).toBe(commit);
      expect((await mine(f))?.commit).toBe(commit);
    });
  });
});
