// Drizzle wendet eine Migration nur an, wenn ihr "when" größer ist als das der zuletzt angewendeten. Sind die Werte nicht streng
// aufsteigend (z. B. nach dem Zusammenführen zweier Branches), wird eine Migration auf bestehenden Datenbanken stillschweigend übersprungen.
import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

interface Entry {
  idx: number;
  tag: string;
  when: number;
}

describe('Migrations-Journal', () => {
  const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Entry[] };

  it('"when" ist streng aufsteigend (in Journal-Reihenfolge)', () => {
    for (let i = 1; i < journal.entries.length; i++) {
      const a = journal.entries[i - 1] as Entry;
      const b = journal.entries[i] as Entry;
      expect(b.when, `${b.tag} muss nach ${a.tag} liegen`).toBeGreaterThan(a.when);
    }
  });

  it('Tags sind eindeutig und entsprechen den SQL-Dateien (Nummern aufsteigend)', () => {
    const tags = journal.entries.map((e) => e.tag);
    expect(new Set(tags).size).toBe(tags.length);
    const files = readdirSync(migrationsFolder).filter((f) => f.endsWith('.sql')).map((f) => f.replace(/\.sql$/, '')).sort();
    expect([...tags].sort()).toEqual(files);
    const nummern = tags.map((t) => Number(t.slice(0, 4)));
    for (let i = 1; i < nummern.length; i++) expect(nummern[i] as number).toBeGreaterThan(nummern[i - 1] as number);
  });

  // Die Snapshot-Kette muss lückenlos sein (prevId = id des Vorgängers in Journal-Reihenfolge). Nach dem Zusammenführen zweier
  // Branches mit je einer Migration neu erzeugen: Snapshot der späteren Migration kopieren, `prevId` auf die id des Vorgängers setzen.
  it('Snapshot-Kette ist lückenlos (prevId zeigt auf den Vorgänger), ids sind eindeutig', () => {
    const snaps = journal.entries.map((e) => JSON.parse(readFileSync(`${migrationsFolder}/meta/${e.tag.slice(0, 4)}_snapshot.json`, 'utf8')) as { id: string; prevId: string });
    expect(new Set(snaps.map((s) => s.id)).size).toBe(snaps.length);
    expect(snaps[0]?.prevId).toBe('00000000-0000-0000-0000-000000000000');
    for (let i = 1; i < snaps.length; i++) expect(snaps[i]?.prevId, `prevId von ${journal.entries[i]?.tag}`).toBe(snaps[i - 1]?.id);
  });
});

// ---- Aktualisierung bestehender Datenbanken: 0004 bis 0014, einzeln angewendet, behält Daten und wendet jede Migration an ----
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzlePg } from 'drizzle-orm/node-postgres';
import { migrate as migratePg } from 'drizzle-orm/node-postgres/migrator';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import pg from 'pg';

/** Kopie des Migrationsordners, die nur die ersten `anzahl` Einträge des Journals kennt. */
function teilordner(anzahl: number): string {
  const dir = mkdtempSync(`${tmpdir()}/lx-mig-`);
  mkdirSync(`${dir}/meta`);
  const kept = journalRaw.entries.slice(0, anzahl);
  for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
  writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...journalRaw, entries: kept }));
  return dir;
}
const journalRaw = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Entry[] };

describe('Migration auf bestehender Datenbank', () => {
  type Exec = (q: string) => Promise<Array<Record<string, unknown>>>;
  async function pruefen(partial: (dir: string) => Promise<void>, voll: () => Promise<void>, q: Exec) {
    const bis4 = journalRaw.entries.findIndex((e) => e.tag.startsWith('0004')) + 1;
    const ordner: string[] = [];
    try {
      const d4 = teilordner(bis4);
      ordner.push(d4);
      await partial(d4); // Stand 0004 (Gäste-Rolle noch vorhanden)
      const uid = randomUUID();
      const fid = randomUUID();
      await q(`insert into users (id, email, display_name) values ('${uid}', 'alt@example.org', 'Alt')`);
      await q(`insert into families (id, name) values ('${fid}', 'Altfamilie')`);
      await q(`insert into memberships (family_id, user_id, role) values ('${fid}', '${uid}', 'child')`);
      // jede weitere Migration einzeln (0005 bis zuletzt), die Altdaten bleiben jedes Mal erhalten
      const tags = journalRaw.entries.slice(bis4).map((e) => e.tag);
      expect(tags.map((x) => x.slice(0, 4))).toEqual(['0005', '0006', '0007', '0008', '0009', '0010', '0011', '0012', '0013', '0014', '0015']);
      for (let i = 1; i < tags.length; i++) {
        const d = teilordner(bis4 + i);
        ordner.push(d);
        await partial(d);
        const m = await q(`select display_name from users where id = '${uid}'`);
        expect(m[0]?.display_name, tags[i - 1]).toBe('Alt');
      }
      await voll();
      const rows = await q(`select display_name, avatar_kind, avatar_preset, avatar_version from users where id = '${uid}'`);
      expect(rows[0]).toMatchObject({ display_name: 'Alt', avatar_kind: null, avatar_preset: null, avatar_version: 0 });
      const mem = await q(`select role from memberships where family_id = '${fid}' and user_id = '${uid}'`);
      expect(mem[0]?.role).toBe('child');
      // die Familienrolle (0007) ist neben den Chat-, Push- und Schlüssel-Tabellen erhalten
      expect((await q(`select family_role from memberships where family_id = '${fid}' and user_id = '${uid}'`))[0]).toEqual({ family_role: null });
      for (const tabelle of ['user_avatars', 'konversationen', 'nachrichten', 'lesestand', 'push_endpoints', 'person_keys', 'person_key_history', 'key_backups', 'key_transfers', 'konversation_epochen', 'epoche_wraps', 'reaktionen', 'stimmen', 'pins', 'account_kdf', 'key_backups_pw', 'weather_credentials', 'weather_samples']) {
        const r = await q(`select to_regclass('public.${tabelle}') as t`);
        expect(r[0]?.t, tabelle).toBe(tabelle);
      }
    } finally {
      for (const d of ordner) rmSync(d, { recursive: true, force: true });
    }
  }

  it('PGlite: 0004 -> 0005 -> … -> 0015 (je Schritt mit Altdaten)', async () => {
    const client = new PGlite();
    const db = drizzleLite(client);
    try {
      await pruefen(
        (dir) => migrateLite(db, { migrationsFolder: dir }),
        () => migrateLite(db, { migrationsFolder }),
        async (q) => (await db.execute(sql.raw(q))).rows as Array<Record<string, unknown>>,
      );
    } finally {
      await client.close();
    }
  }, 60_000);

  it.skipIf(!process.env.TEST_DATABASE_URL)('PostgreSQL: 0004 -> 0005 -> … -> 0015 (je Schritt mit Altdaten)', async () => {
    const name = `lx_mig_${randomUUID().replaceAll('-', '')}`;
    const admin = new pg.Client({ connectionString: process.env.TEST_DATABASE_URL });
    admin.on('error', () => undefined); // 57P01 beim Aufräumen ist erwartet
    await admin.connect();
    await admin.query(`create database ${name}`);
    const url = new URL(process.env.TEST_DATABASE_URL as string);
    url.pathname = `/${name}`;
    const pool = new pg.Pool({ connectionString: url.toString(), max: 2 });
    pool.on('error', () => undefined);
    const db = drizzlePg(pool);
    try {
      await pruefen(
        (dir) => migratePg(db, { migrationsFolder: dir }),
        () => migratePg(db, { migrationsFolder }),
        async (q) => (await pool.query(q)).rows as Array<Record<string, unknown>>,
      );
    } finally {
      await pool.end();
      await admin.query(`drop database ${name} with (force)`);
      await admin.end();
    }
  }, 60_000);
});

describe('Migration 0007 (Familienrolle) auf bestehender Datenbank', () => {
  async function pruefen(partial: (dir: string) => Promise<void>, voll: () => Promise<void>, q: (s: string) => Promise<Array<Record<string, unknown>>>) {
    const davor = journalRaw.entries.findIndex((e) => e.tag.startsWith('0007'));
    const dir = teilordner(davor);
    try {
      await partial(dir);
      const fam = randomUUID();
      const uid = randomUUID();
      await q(`insert into families (id, name) values ('${fam}', 'Alt')`);
      await q(`insert into users (id, email, display_name) values ('${uid}', 'alt12@example.org', 'Alt')`);
      await q(`insert into memberships (family_id, user_id, role) values ('${fam}', '${uid}', 'admin')`);
      await voll();
      const rows = await q(`select role, family_role from memberships where user_id = '${uid}'`);
      expect(rows[0]).toMatchObject({ role: 'admin', family_role: null });
      await q(`update memberships set family_role = 'elternteil' where user_id = '${uid}'`);
      await expect(q(`update memberships set family_role = 'chef' where user_id = '${uid}'`)).rejects.toThrow();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  it('PGlite: Altdaten bleiben, family_role ist null, CHECK greift', async () => {
    const client = new PGlite();
    const db = drizzleLite(client);
    try {
      await pruefen(
        (dir) => migrateLite(db, { migrationsFolder: dir }),
        () => migrateLite(db, { migrationsFolder }),
        async (q) => (await db.execute(sql.raw(q))).rows as Array<Record<string, unknown>>,
      );
    } finally {
      await client.close();
    }
  }, 60_000);

  it.skipIf(!process.env.TEST_DATABASE_URL)('PostgreSQL: Altdaten bleiben, family_role ist null, CHECK greift', async () => {
    const name = `lx_mig_${randomUUID().replaceAll('-', '')}`;
    const admin = new pg.Client({ connectionString: process.env.TEST_DATABASE_URL });
    admin.on('error', () => undefined); // 57P01 beim Aufräumen ist erwartet
    await admin.connect();
    await admin.query(`create database ${name}`);
    const url = new URL(process.env.TEST_DATABASE_URL as string);
    url.pathname = `/${name}`;
    const pool = new pg.Pool({ connectionString: url.toString(), max: 2 });
    pool.on('error', () => undefined);
    const db = drizzlePg(pool);
    try {
      await pruefen(
        (dir) => migratePg(db, { migrationsFolder: dir }),
        () => migratePg(db, { migrationsFolder }),
        async (q) => (await pool.query(q)).rows as Array<Record<string, unknown>>,
      );
    } finally {
      await pool.end();
      await admin.query(`drop database ${name} with (force)`);
      await admin.end();
    }
  }, 60_000);
});
