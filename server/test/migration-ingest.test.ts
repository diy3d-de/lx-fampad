// Migration 0037 (Einwurf-Postfach: ingest_tokens, ingest_inbox) ist rein additiv und idempotent: Bestand bleibt unverändert, erneutes Ausführen wirft nicht,
// die Prüfungen (Längen, Eindeutigkeit, zusammengesetzter Fremdschlüssel) greifen und ein Löschen der Familie räumt auf.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomUUID } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

describe('Migration 0037 (Einwurf-Postfach)', () => {
  it('PGlite: Bestand unverändert, wiederholbar, Prüfungen und Kaskade greifen', async () => {
    const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Array<{ tag: string }> };
    const davor = journal.entries.findIndex((e) => e.tag.startsWith('0037'));
    expect(davor).toBeGreaterThan(0);
    const dir = mkdtempSync(`${tmpdir()}/lx-mig-ingest-`);
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
      const fam2 = randomUUID();
      await run(`insert into families (id, name) values ('${fam}', 'Alt'), ('${fam2}', 'Fremd')`);
      await migrateLite(db, { migrationsFolder });
      expect((await run('select count(*)::int as n from ingest_tokens')).rows[0]).toEqual({ n: 0 });
      expect((await run('select count(*)::int as n from ingest_inbox')).rows[0]).toEqual({ n: 0 });
      expect((await run('select count(*)::int as n from families')).rows[0]).toEqual({ n: 2 });

      // erneutes Ausführen der Datei wirft nicht
      const datei = readFileSync(`${migrationsFolder}/0037_ingest_postfach.sql`, 'utf8');
      for (const s of datei.split('--> statement-breakpoint').map((x) => x.trim()).filter(Boolean)) await run(s);

      const tok = randomUUID();
      const tok2 = randomUUID();
      await run(`insert into ingest_tokens (id, family_id, name, token_hash) values ('${tok}', '${fam}', 'HA', 'h1'), ('${tok2}', '${fam2}', 'HA', 'h2')`);
      await expect(run(`insert into ingest_tokens (family_id, name, token_hash) values ('${fam}', 'x', 'h1')`)).rejects.toThrow(); // Hash eindeutig
      await expect(run(`insert into ingest_tokens (family_id, name, token_hash) values ('${fam}', '', 'h3')`)).rejects.toThrow(); // Name 1 bis 40
      await expect(run(`insert into ingest_tokens (family_id, name, token_hash) values ('${fam}', '${'x'.repeat(41)}', 'h4')`)).rejects.toThrow();

      await run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', 'a', '\\x01')`);
      await expect(run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', 'a', '\\x02')`)).rejects.toThrow(); // (token, k) eindeutig
      await expect(run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', '', '\\x01')`)).rejects.toThrow();
      await expect(run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', '${'k'.repeat(65)}', '\\x01')`)).rejects.toThrow();
      await expect(run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', 'b', '\\x')`)).rejects.toThrow(); // leer
      await expect(run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', 'c', '\\x${'00'.repeat(1025)}')`)).rejects.toThrow();
      await run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok}', 'd', '\\x${'00'.repeat(1024)}')`);
      // Token einer anderen Familie: zusammengesetzter Fremdschlüssel
      await expect(run(`insert into ingest_inbox (family_id, token_id, k, box) values ('${fam}', '${tok2}', 'e', '\\x01')`)).rejects.toThrow();

      // Reihenfolge: seq steigt mit dem Einfügen
      const seqs = (await run(`select seq::int as s from ingest_inbox order by seq`)).rows.map((r) => (r as { s: number }).s);
      expect(seqs).toEqual([...seqs].sort((a, b) => a - b));

      await run(`delete from families where id = '${fam}'`);
      expect((await run('select count(*)::int as n from ingest_inbox')).rows[0]).toEqual({ n: 0 });
      expect((await run('select count(*)::int as n from ingest_tokens')).rows[0]).toEqual({ n: 1 });
    } finally {
      await client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);
});
