// Migration 0005 (Gäste entfallen): Stand von 0004 mit Gast-Daten anlegen, 0005 anwenden, Ergebnis prüfen.
// Läuft gegen PGlite und, mit TEST_DATABASE_URL, gegen ein echtes PostgreSQL (frische Datenbank je Lauf).
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzlePg } from 'drizzle-orm/node-postgres';
import { migrate as migratePg } from 'drizzle-orm/node-postgres/migrator';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomUUID } from 'node:crypto';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const full = fileURLToPath(new URL('../drizzle', import.meta.url));

interface Backend {
  /** Wendet die Migrationen aus dem Ordner an (bereits angewendete werden übersprungen). */
  migrate(folder: string): Promise<void>;
  rows<T = Record<string, unknown>>(q: ReturnType<typeof sql>): Promise<T[]>;
  close(): Promise<void>;
}

async function pglite(): Promise<Backend> {
  const client = new PGlite();
  const db = drizzleLite(client);
  return {
    migrate: (folder) => migrateLite(db, { migrationsFolder: folder }),
    rows: async <T>(q: ReturnType<typeof sql>) => (await db.execute(q)).rows as T[],
    close: () => client.close(),
  };
}

async function postgres(adminUrl: string): Promise<Backend> {
  const name = `lx_test_${randomUUID().replaceAll('-', '')}`;
  const admin = new pg.Client({ connectionString: adminUrl });
  admin.on('error', () => undefined);
  await admin.connect();
  await admin.query(`create database ${name}`);
  const url = new URL(adminUrl);
  url.pathname = `/${name}`;
  const pool = new pg.Pool({ connectionString: url.toString(), max: 2 });
  pool.on('error', () => undefined);
  const db = drizzlePg(pool);
  return {
    migrate: (folder) => migratePg(db, { migrationsFolder: folder }),
    rows: async <T>(q: ReturnType<typeof sql>) => (await db.execute(q)).rows as T[],
    close: async () => {
      await pool.end();
      await admin.query(`drop database ${name} with (force)`);
      await admin.end();
    },
  };
}

const targets: [string, () => Promise<Backend>][] = [['PGlite', pglite]];
if (process.env.TEST_DATABASE_URL) targets.push(['PostgreSQL (echt)', () => postgres(process.env.TEST_DATABASE_URL as string)]);

const id = () => randomUUID();
const F = id();
const [A, P, C, G, H] = [id(), id(), id(), id(), id()];
const [L1, L2, L3, L4, I1, T1, T2, TN1, TN2] = [id(), id(), id(), id(), id(), id(), id(), id(), id()];

describe.each(targets)('Migration 0005: Gäste entfallen (%s)', (_name, open) => {
  let b: Backend;
  let tmp: string;

  beforeAll(async () => {
    b = await open();
    // Stand 0004: Journal ohne 0005
    tmp = mkdtempSync(join(tmpdir(), 'lx-mig-'));
    cpSync(full, tmp, { recursive: true });
    const journalPath = join(tmp, 'meta', '_journal.json');
    const journal = JSON.parse(readFileSync(journalPath, 'utf8')) as { entries: Array<{ tag: string }> };
    journal.entries = journal.entries.filter((e) => !e.tag.startsWith('0005'));
    writeFileSync(journalPath, JSON.stringify(journal));
    await b.migrate(tmp);

    const q = (s: ReturnType<typeof sql>) => b.rows(s);
    await q(sql`insert into families (id, name, current_rev) values (${F}, 'Familie', 20)`);
    for (const [uid, mail] of [[A, 'a'], [P, 'p'], [C, 'c'], [G, 'oma'], [H, 'wartend']] as const) {
      await q(sql`insert into users (id, email, display_name) values (${uid}, ${`${mail}@example.org`}, ${mail})`);
    }
    await q(sql`insert into memberships (family_id, user_id, role) values (${F}, ${A}, 'admin'), (${F}, ${P}, 'parent'), (${F}, ${C}, 'child'), (${F}, ${G}, 'guest')`);
    await q(sql`insert into memberships (family_id, user_id, role, status) values (${F}, ${H}, 'guest', 'pending')`);
    const dev = id();
    await q(sql`insert into devices (id, family_id, user_id, name, platform) values (${dev}, ${F}, ${G}, 'Omas Handy', 'android')`);
    await q(sql`insert into sessions (family_id, user_id, device_id, token_hash, expires_at) values (${F}, ${G}, ${dev}, ${'hash-g'}, now() + interval '1 day')`);
    // Einladungen: offen für Gast, offen von Gast, verbraucht (Verlauf), offen für Kind
    await q(sql`insert into invites (family_id, role, token_hash, expires_at, created_by) values (${F}, 'guest', 'i1', now() + interval '1 day', ${A})`);
    await q(sql`insert into invites (family_id, role, token_hash, expires_at, created_by) values (${F}, 'child', 'i2', now() + interval '1 day', ${G})`);
    await q(sql`insert into invites (family_id, role, token_hash, expires_at, created_by, used_at, used_by) values (${F}, 'guest', 'i3', now() + interval '1 day', ${A}, now(), ${G})`);
    await q(sql`insert into invites (family_id, role, token_hash, expires_at, created_by) values (${F}, 'child', 'i4', now() + interval '1 day', ${A})`);
    // Listen: freigegeben (Besitzer Gast), Familie, gelöscht+freigegeben, nur Eltern
    await q(sql`insert into lists (id, family_id, name, audience, owner_id, rev, field_revs) values (${L1}, ${F}, 'Grillfest', 'all', ${G}, 1, '{"name":1}')`);
    await q(sql`insert into lists (id, family_id, name, audience, rev, field_revs) values (${L2}, ${F}, 'Einkauf', 'family', 2, '{"name":2}')`);
    await q(sql`insert into lists (id, family_id, name, audience, rev, field_revs, deleted_at) values (${L3}, ${F}, '', 'all', 3, '{}', now())`);
    await q(sql`insert into lists (id, family_id, name, audience, rev, field_revs) values (${L4}, ${F}, 'Geschenke', 'parents', 4, '{"name":4}')`);
    await q(sql`insert into list_items (id, family_id, list_id, text, assignee_id, rev, field_revs) values (${I1}, ${F}, ${L1}, 'Salat', ${G}, 5, '{"text":5}')`);
    // Termine: freigegeben mit Gast als Besitzer und Teilnehmer, Familie
    await q(sql`insert into termine (id, family_id, titel, ganztaegig, start_date, end_date, audience, owner_id, rev, field_revs) values (${T1}, ${F}, 'Oma-Besuch', true, '2026-10-20', '2026-10-21', 'all', ${G}, 6, '{"titel":6}')`);
    await q(sql`insert into termine (id, family_id, titel, ganztaegig, start_date, end_date, audience, rev, field_revs) values (${T2}, ${F}, 'Zahnarzt', true, '2026-10-22', '2026-10-23', 'family', 7, '{"titel":7}')`);
    await q(sql`insert into termin_teilnehmer (id, family_id, termin_id, user_id, rev, field_revs) values (${TN1}, ${F}, ${T1}, ${G}, 8, '{}')`);
    await q(sql`insert into termin_teilnehmer (id, family_id, termin_id, user_id, rev, field_revs) values (${TN2}, ${F}, ${T1}, ${P}, 9, '{}')`);

    await b.migrate(full); // 0005
  }, 120_000);

  afterAll(async () => {
    await b?.close();
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('Aufzählungstypen: keine Rolle "guest", keine Freigabestufe "all"', async () => {
    const labels = async (t: string) =>
      (await b.rows<{ enumlabel: string }>(sql`select e.enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = ${t} order by e.enumsortorder`)).map((r) => r.enumlabel);
    expect(await labels('member_role')).toEqual(['admin', 'parent', 'child']);
    expect(await labels('list_audience')).toEqual(['parents', 'family']);
  });

  it('Gast-Konten samt Geräten und Sitzungen sind entfernt, die übrigen Mitglieder bleiben', async () => {
    const members = await b.rows<{ user_id: string }>(sql`select user_id from memberships where family_id = ${F}`);
    expect(members.map((m) => m.user_id).sort()).toEqual([A, P, C].sort());
    expect(await b.rows(sql`select 1 from users where id in (${G}, ${H})`)).toHaveLength(0);
    expect(await b.rows(sql`select 1 from users where id in (${A}, ${P}, ${C})`)).toHaveLength(3);
    expect(await b.rows(sql`select 1 from sessions where user_id = ${G}`)).toHaveLength(0);
    expect(await b.rows(sql`select 1 from devices where user_id = ${G}`)).toHaveLength(0);
  });

  it('Audit-Eintrag je entferntem Gast', async () => {
    const audit = await b.rows<{ detail: { target: string; role: string } }>(sql`select detail from audit_log where family_id = ${F} and event = 'member_removed'`);
    expect(audit.map((a) => a.detail.target).sort()).toEqual([G, H].sort());
    expect(audit.every((a) => a.detail.role === 'guest')).toBe(true);
  });

  it('Einladungen: offene für/von Gästen widerrufen, Verlauf behält eine gültige Rolle', async () => {
    const inv = await b.rows<{ token_hash: string; role: string; revoked: boolean }>(sql`select token_hash, role, revoked_at is not null as revoked from invites order by token_hash`);
    expect(inv.find((i) => i.token_hash === 'i1')).toMatchObject({ revoked: true });
    expect(inv.find((i) => i.token_hash === 'i2')).toMatchObject({ revoked: true });
    expect(inv.find((i) => i.token_hash === 'i3')?.role).toBe('child');
    expect(inv.find((i) => i.token_hash === 'i4')).toMatchObject({ role: 'child', revoked: false });
  });

  it('Freigabe "all" wird "family" mit Revision und Änderungseintrag, Verweise der Gäste werden gelöst', async () => {
    const audience = await b.rows<{ audience: string }>(sql`select audience from lists union all select audience from termine`);
    expect(audience.every((r) => r.audience === 'family' || r.audience === 'parents')).toBe(true);
    const [l1] = await b.rows<{ audience: string; owner_id: string | null; rev: string; field_revs: Record<string, number> }>(
      sql`select audience, owner_id, rev, field_revs from lists where id = ${L1}`,
    );
    expect(l1).toMatchObject({ audience: 'family', owner_id: null });
    expect(Number(l1?.rev)).toBeGreaterThan(20);
    expect(l1?.field_revs.audience).toBeGreaterThan(20);
    expect(l1?.field_revs.ownerId).toBeGreaterThan(20);
    expect((await b.rows<{ assignee_id: string | null }>(sql`select assignee_id from list_items where id = ${I1}`))[0]?.assignee_id).toBeNull();
    const log = await b.rows<{ rev: string; entity: string; entity_id: string; tombstone: boolean; changes: Record<string, unknown> }>(
      sql`select rev, entity, entity_id, tombstone, changes from change_log where family_id = ${F} order by rev`,
    );
    const of = (entity: string, eid: string) => log.filter((e) => e.entity === entity && e.entity_id === eid);
    expect(of('list', L1).map((e) => e.changes)).toEqual(expect.arrayContaining([{ audience: 'family' }, { ownerId: null }]));
    expect(of('list_item', I1).map((e) => e.changes)).toEqual([{ assigneeId: null }]);
    expect(of('termin', T1).map((e) => e.changes)).toEqual(expect.arrayContaining([{ audience: 'family' }, { ownerId: null }]));
    expect(of('list', L2)).toHaveLength(0); // unverändert
    expect(of('list', L3)).toHaveLength(0); // gelöscht: nur der Wert wird angepasst
    // Teilnahme des Gastes: Tombstone mit Änderungseintrag, die der Eltern bleibt
    expect(of('termin_teilnehmer', TN1).map((e) => e.tombstone)).toEqual([true]);
    expect(await b.rows(sql`select 1 from termin_teilnehmer where id = ${TN2} and deleted_at is null`)).toHaveLength(1);
    // Revisionen eindeutig und lückenlos fortgeschrieben, Familienzähler = höchste vergebene Revision
    const revs = log.map((e) => Number(e.rev));
    expect(new Set(revs).size).toBe(revs.length);
    const [fam] = await b.rows<{ current_rev: string }>(sql`select current_rev from families where id = ${F}`);
    expect(Number(fam?.current_rev)).toBe(Math.max(...revs));
    expect(Math.min(...revs)).toBe(21);
  });

  it('neue Datensätze: Standard "family"; die Rolle "guest" und die Stufe "all" lassen sich nicht mehr speichern', async () => {
    await expect(b.rows(sql`insert into lists (family_id, name, audience, rev) values (${F}, 'x', 'all', 99)`)).rejects.toThrow();
    await expect(b.rows(sql`insert into invites (family_id, role, token_hash, expires_at) values (${F}, 'guest', 'neu', now())`)).rejects.toThrow();
    await b.rows(sql`insert into lists (family_id, name, rev) values (${F}, 'ok', 99)`);
    expect((await b.rows<{ audience: string }>(sql`select audience from lists where name = 'ok'`))[0]?.audience).toBe('family');
  });
});
