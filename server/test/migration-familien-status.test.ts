// Migration 0038 (Familien-Status: Tabelle familien_status) ist additiv und idempotent; Altdaten bleiben unberührt.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

describe('Migration 0038 (Familien-Status)', () => {
  it('PGlite: Altdaten bleiben, erneutes Ausführen wirft nicht, eine Zeile je Person', async () => {
    const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Array<{ tag: string }> };
    const davor = journal.entries.findIndex((e) => e.tag.startsWith('0038'));
    expect(davor).toBeGreaterThan(0);
    const dir = mkdtempSync(`${tmpdir()}/lx-mig-status-`);
    mkdirSync(`${dir}/meta`);
    const kept = journal.entries.slice(0, davor);
    for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
    writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...journal, entries: kept }));
    const client = new PGlite();
    const db = drizzleLite(client);
    try {
      await migrateLite(db, { migrationsFolder: dir });
      const fam = randomUUID();
      const user = randomUUID();
      await db.execute(sql.raw(`insert into families (id, name) values ('${fam}', 'Alt')`));
      await db.execute(sql.raw(`insert into users (id, email, display_name) values ('${user}', 'a@example.org', 'A')`));
      await db.execute(sql.raw(`insert into memberships (family_id, user_id, role) values ('${fam}', '${user}', 'admin')`));
      await migrateLite(db, { migrationsFolder });
      expect((await db.execute(sql.raw(`select count(*)::int as n from familien_status`))).rows[0]).toEqual({ n: 0 });
      expect((await db.execute(sql.raw(`select count(*)::int as n from memberships`))).rows[0]).toEqual({ n: 1 });
      const datei = readFileSync(`${migrationsFolder}/0038_familien_status.sql`, 'utf8');
      for (const s of datei.split('--> statement-breakpoint').map((x) => x.trim()).filter(Boolean)) await db.execute(sql.raw(s));
      const ins = (id: string): string => `insert into familien_status (id, family_id, user_id, text, rev) values ('${id}', '${fam}', '${user}', 'Beim Sport', 1)`;
      await db.execute(sql.raw(ins(randomUUID())));
      await expect(db.execute(sql.raw(ins(randomUUID())))).rejects.toThrow();
    } finally {
      await client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});
