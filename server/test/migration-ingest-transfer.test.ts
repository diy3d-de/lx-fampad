// Migration 0040 (Weitergabe des Postfach-Schlüssels: ingest_postfach_transfers) ist rein additiv und idempotent: Bestand bleibt unverändert, erneutes Ausführen wirft nicht,
// die Prüfungen (Länge des Blobs, eindeutige Suchkennung, eine Zeile je Person) greifen und ein Löschen der Person räumt auf.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomUUID } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

describe('Migration 0040 (Postfach-Weitergabe)', () => {
  it('PGlite: Bestand unverändert, wiederholbar, Prüfungen und Kaskade greifen', async () => {
    const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Array<{ tag: string }> };
    const davor = journal.entries.findIndex((e) => e.tag.startsWith('0040'));
    expect(davor).toBeGreaterThan(0);
    const dir = mkdtempSync(`${tmpdir()}/lx-mig-ingest-transfer-`);
    mkdirSync(`${dir}/meta`);
    const kept = journal.entries.slice(0, davor);
    for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
    writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...journal, entries: kept }));
    const client = new PGlite();
    const db = drizzleLite(client);
    const run = (s: string) => db.execute(sql.raw(s));
    try {
      await migrateLite(db, { migrationsFolder: dir });
      const u1 = randomUUID();
      const u2 = randomUUID();
      await run(`insert into users (id, email, display_name) values ('${u1}', 'a@example.org', 'A'), ('${u2}', 'b@example.org', 'B')`);
      await migrateLite(db, { migrationsFolder });
      expect((await run('select count(*)::int as n from ingest_postfach_transfers')).rows[0]).toEqual({ n: 0 });
      expect((await run('select count(*)::int as n from users')).rows[0]).toEqual({ n: 2 });

      // erneutes Ausführen der Datei wirft nicht
      const datei = readFileSync(`${migrationsFolder}/0040_ingest_postfach_transfer.sql`, 'utf8');
      for (const s of datei.split('--> statement-breakpoint').map((x) => x.trim()).filter(Boolean)) await run(s);

      const exp = `now() + interval '2 minutes'`;
      const blob = 'x'.repeat(40);
      await run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${u1}', 'h1', '${blob}', ${exp})`);
      await expect(run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${u1}', 'h2', '${blob}', ${exp})`)).rejects.toThrow(); // eine je Person
      await expect(run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${u2}', 'h1', '${blob}', ${exp})`)).rejects.toThrow(); // Suchkennung eindeutig
      await expect(run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${u2}', 'h3', '${'x'.repeat(31)}', ${exp})`)).rejects.toThrow(); // zu kurz
      await expect(run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${u2}', 'h4', '${'x'.repeat(1025)}', ${exp})`)).rejects.toThrow(); // zu lang
      await run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${u2}', 'h5', '${'x'.repeat(1024)}', ${exp})`);
      await expect(run(`insert into ingest_postfach_transfers (user_id, lookup_hash, blob, expires_at) values ('${randomUUID()}', 'h6', '${blob}', ${exp})`)).rejects.toThrow(); // Person muss existieren

      await run(`delete from users where id = '${u1}'`);
      expect((await run('select count(*)::int as n from ingest_postfach_transfers')).rows[0]).toEqual({ n: 1 });
    } finally {
      await client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});
