// Migration 0039 (termine.erinnerung_min erlaubt zusätzlich -1 = bewusst keine Erinnerung) ist idempotent und lässt Altdaten unberührt.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

describe('Migration 0039 (Termin: Erinnerung -1)', () => {
  it('PGlite: Altdaten unverändert, erneutes Ausführen wirft nicht, -1 gültig, -2 und 40321 abgelehnt', async () => {
    const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Array<{ tag: string }> };
    const davor = journal.entries.findIndex((e) => e.tag.startsWith('0039'));
    expect(davor).toBeGreaterThan(0);
    const dir = mkdtempSync(`${tmpdir()}/lx-mig-erinnerung-`);
    mkdirSync(`${dir}/meta`);
    const kept = journal.entries.slice(0, davor);
    for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
    writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...journal, entries: kept }));
    const client = new PGlite();
    const db = drizzleLite(client);
    const run = (s: string) => db.execute(sql.raw(s));
    try {
      await migrateLite(db, { migrationsFolder: dir });
      const fam = randomUUID();
      const t1 = randomUUID();
      const t2 = randomUUID();
      await run(`insert into families (id, name) values ('${fam}', 'Alt')`);
      await run(`insert into termine (id, family_id, rev, titel, ganztaegig, start_date, end_date, erinnerung_min) values ('${t1}', '${fam}', 1, 'Alt', true, '2026-01-01', '2026-01-02', 15)`);
      await run(`insert into termine (id, family_id, rev, titel, ganztaegig, start_date, end_date) values ('${t2}', '${fam}', 1, 'Alt2', true, '2026-01-01', '2026-01-02')`);
      await expect(run(`update termine set erinnerung_min = -1 where id = '${t1}'`)).rejects.toThrow(); // vorher nicht erlaubt
      await migrateLite(db, { migrationsFolder });
      expect((await run(`select erinnerung_min from termine where id = '${t1}'`)).rows[0]).toEqual({ erinnerung_min: 15 });
      expect((await run(`select erinnerung_min from termine where id = '${t2}'`)).rows[0]).toEqual({ erinnerung_min: null });
      const datei = readFileSync(`${migrationsFolder}/0039_termin_erinnerung_keine.sql`, 'utf8');
      for (const s of datei.split('--> statement-breakpoint').map((x) => x.trim()).filter(Boolean)) await run(s);
      await run(`update termine set erinnerung_min = -1 where id = '${t1}'`);
      await run(`update termine set erinnerung_min = 40320 where id = '${t1}'`);
      await expect(run(`update termine set erinnerung_min = -2 where id = '${t1}'`)).rejects.toThrow();
      await expect(run(`update termine set erinnerung_min = 40321 where id = '${t1}'`)).rejects.toThrow();
    } finally {
      await client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});
