// Migration 0041 (Vorsorge: Tabellen vorsorge_profile und vorsorge_eintraege) ist additiv und idempotent; die Prüfungen der Datenbank greifen, Kaskade über die Konversation.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { adminPassword, migrationsFolder, World } from './helpers.js';

describe('Migration 0041 (Vorsorge) additiv und idempotent', () => {
  it('PGlite: erneutes Ausführen wirft nicht und ändert nichts, Prüfungen und Kaskade greifen', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, {});
      await adminPassword(world);
      const [fam] = (await db.execute<{ id: string }>(sql`select id from families limit 1`)).rows;
      const [adm] = (await db.execute<{ id: string }>(sql`select user_id as id from memberships limit 1`)).rows;
      const familyId = fam!.id;
      const admin = adm!.id;

      const datei = readFileSync(`${migrationsFolder}/0041_vorsorge.sql`, 'utf8');
      const schritte = datei.split('--> statement-breakpoint').map((s) => s.trim()).filter(Boolean);
      expect(schritte.length).toBeGreaterThan(10);
      const stand = async () =>
        JSON.stringify((await db.execute(sql`select table_name, column_name, data_type from information_schema.columns where table_schema = 'public' and table_name in ('vorsorge_profile','vorsorge_eintraege') order by 1, 2`)).rows) +
        JSON.stringify((await db.execute(sql`select conname from pg_constraint where conrelid in ('vorsorge_profile'::regclass, 'vorsorge_eintraege'::regclass) order by 1`)).rows) +
        JSON.stringify((await db.execute(sql`select indexname from pg_indexes where tablename in ('vorsorge_profile','vorsorge_eintraege') order by 1`)).rows);
      const vorher = await stand();
      for (const s of schritte) await db.execute(sql.raw(s));
      expect(await stand()).toBe(vorher);

      const meds = randomUUID();
      await db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, subjekt_id, rev) values (${meds}, ${familyId}, 'meds', array[${admin}]::uuid[], ${admin}, 1)`);
      await db.execute(sql`insert into vorsorge_profile (family_id, konversation_id, inhalt, rev) values (${familyId}, ${meds}, 'e1:x', 1)`);
      await db.execute(sql`insert into vorsorge_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${meds}, 'e1:x', 1)`);
      await expect(db.execute(sql`insert into vorsorge_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${meds}, ${'e1:' + 'x'.repeat(9000)}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into vorsorge_profile (family_id, konversation_id, inhalt, rev) values (${familyId}, ${meds}, ${'e1:' + 'x'.repeat(2100)}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into vorsorge_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${randomUUID()}, 'e1:x', 1)`)).rejects.toThrow();

      await db.execute(sql`delete from konversationen where id = ${meds}`);
      expect((await db.execute(sql`select (select count(*) from vorsorge_profile)::int as p, (select count(*) from vorsorge_eintraege)::int as e`)).rows[0]).toEqual({ p: 0, e: 0 });
    } finally {
      await world?.close();
      await client.close();
    }
  }, 120_000);
});
