// Migration 0027 (Abfuhrtermine: waste_events, waste_years, waste_state) ist rein additiv: Auf einer Datenbank im Stand davor (hier: Bestand anlegen, die drei
// Tabellen wieder entfernen) bleibt jede Zeile unverändert, die neuen Tabellen sind leer, ihre Prüfungen greifen und ein Löschen der Familie räumt sie auf.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { adminPassword, migrationsFolder, World } from './helpers.js';

describe('Migration 0027 (Abfuhrtermine) additiv', () => {
  it('PGlite: Bestand unverändert, neue Tabellen leer, Prüfungen greifen, Kaskade über die Familie', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, {});
      await adminPassword(world);
      const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' and tablename not like 'waste_%' order by 1`)).rows).map((r) => r.tablename);
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg(to_jsonb(x)::text, '|' order by to_jsonb(x)::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      await world.close();
      world = undefined;

      // zurück in den Stand davor: die drei Tabellen weg, ihr Eintrag im Migrationsprotokoll weg
      await db.execute(sql`drop table waste_events, waste_years, waste_state`);
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0027_'));
      if (!meine) throw new Error('Journal ohne 0027');
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      for (const t of ['waste_events', 'waste_years', 'waste_state']) expect((await db.execute(sql.raw(`select count(*)::int as n from ${t}`))).rows[0], t).toEqual({ n: 0 });

      const fam = ((await db.execute<{ id: string }>(sql`select id from families limit 1`)).rows[0] as { id: string }).id;
      await db.execute(sql.raw(`insert into waste_events (family_id, day, kind) values ('${fam}', '2026-10-28', 'bio')`));
      await db.execute(sql.raw(`insert into waste_years (family_id, year, status, event_count) values ('${fam}', 2026, 'loaded', 1)`));
      await db.execute(sql.raw(`insert into waste_state (family_id) values ('${fam}')`));
      // feste Liste der Arten und Zustände, ein Termin nur einmal je Tag und Art
      await expect(db.execute(sql.raw(`insert into waste_events (family_id, day, kind) values ('${fam}', '2026-10-29', 'gift')`))).rejects.toThrow();
      await expect(db.execute(sql.raw(`insert into waste_events (family_id, day, kind) values ('${fam}', '2026-10-28', 'bio')`))).rejects.toThrow();
      await expect(db.execute(sql.raw(`insert into waste_years (family_id, year, status) values ('${fam}', 2027, 'kaputt')`))).rejects.toThrow();
      await expect(db.execute(sql.raw(`insert into waste_years (family_id, year, status) values ('${fam}', 1999, 'loaded')`))).rejects.toThrow();
      await db.execute(sql.raw(`delete from families where id = '${fam}'`));
      for (const t of ['waste_events', 'waste_years', 'waste_state']) expect((await db.execute(sql.raw(`select count(*)::int as n from ${t}`))).rows[0], t).toEqual({ n: 0 });
    } finally {
      await world?.close();
      await client.close();
    }
  }, 60_000);
});
