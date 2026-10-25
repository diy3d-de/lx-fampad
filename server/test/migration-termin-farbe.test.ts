// Migration 0036 (Termin-Farbe: termine.farbe smallint, nullable, CHECK 0 bis 10) ist idempotent und lässt Altdaten unberührt.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

describe('Migration 0036 (Termin-Farbe)', () => {
  it('PGlite: Altdaten bekommen farbe null, erneutes Ausführen wirft nicht, Prüfung greift', async () => {
    const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Array<{ tag: string }> };
    const davor = journal.entries.findIndex((e) => e.tag.startsWith('0036'));
    expect(davor).toBeGreaterThan(0);
    const dir = mkdtempSync(`${tmpdir()}/lx-mig-farbe-`);
    mkdirSync(`${dir}/meta`);
    const kept = journal.entries.slice(0, davor);
    for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
    writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...journal, entries: kept }));
    const client = new PGlite();
    const db = drizzleLite(client);
    try {
      await migrateLite(db, { migrationsFolder: dir });
      const fam = randomUUID();
      const tid = randomUUID();
      await db.execute(sql.raw(`insert into families (id, name) values ('${fam}', 'Alt')`));
      await db.execute(sql.raw(`insert into termine (id, family_id, rev, titel, ganztaegig, start_date, end_date) values ('${tid}', '${fam}', 1, 'Alt', true, '2026-01-01', '2026-01-02')`));
      await migrateLite(db, { migrationsFolder });
      expect((await db.execute(sql.raw(`select farbe from termine where id = '${tid}'`))).rows[0]).toEqual({ farbe: null });
      const datei = readFileSync(`${migrationsFolder}/0036_termin_farbe.sql`, 'utf8');
      for (const s of datei.split('--> statement-breakpoint').map((x) => x.trim()).filter(Boolean)) await db.execute(sql.raw(s));
      await db.execute(sql.raw(`update termine set farbe = 10 where id = '${tid}'`));
      await expect(db.execute(sql.raw(`update termine set farbe = 11 where id = '${tid}'`))).rejects.toThrow();
    } finally {
      await client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});
