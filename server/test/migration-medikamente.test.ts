// Migration 0030 (Medikamenten-Plan: Konversationsart `meds`, konversationen.subjekt_id, Tabellen medikamente und einnahmen) ist additiv und idempotent:
// Zweimal ausgeführt ändert sie nichts und wirft nicht; die Prüfungen der Datenbank greifen (Subjekt nur bei meds, ein Teilnehmer reicht nur dort, Kaskaden).
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

describe('Migration 0030 (Medikamenten-Plan) additiv und idempotent', () => {
  it('PGlite: erneutes Ausführen wirft nicht und ändert nichts, Prüfungen greifen, Kaskade über Konversation und Familie', async () => {
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

      // Bestand: eine Gruppe (bleibt von der Migration unberührt)
      const gruppe = randomUUID();
      await db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${gruppe}, ${familyId}, 'group', array[${admin}, ${randomUUID()}]::uuid[], 1)`);

      const datei = readFileSync(`${migrationsFolder}/0030_medikamente.sql`, 'utf8');
      const schritte = datei.split('--> statement-breakpoint').map((s) => s.trim()).filter(Boolean);
      expect(schritte.length).toBeGreaterThan(10);
      const stand = async () =>
        JSON.stringify((await db.execute(sql`select table_name, column_name, data_type from information_schema.columns where table_schema = 'public' and table_name in ('konversationen','medikamente','einnahmen') order by 1, 2`)).rows) +
        JSON.stringify((await db.execute(sql`select conname from pg_constraint where conrelid in ('konversationen'::regclass, 'medikamente'::regclass, 'einnahmen'::regclass) order by 1`)).rows) +
        JSON.stringify((await db.execute(sql`select indexname from pg_indexes where tablename in ('konversationen','medikamente','einnahmen') order by 1`)).rows);
      const vorher = await stand();
      for (const s of schritte) await db.execute(sql.raw(s));
      expect(await stand()).toBe(vorher);

      // Prüfungen: Subjekt nur bei meds, meds mit genau einem Teilnehmer erlaubt, group mit einem Teilnehmer nicht
      const meds = randomUUID();
      await expect(db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${randomUUID()}, ${familyId}, 'meds', array[${admin}]::uuid[], 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, subjekt_id, rev) values (${randomUUID()}, ${familyId}, 'group', array[${admin}, ${randomUUID()}]::uuid[], ${admin}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${randomUUID()}, ${familyId}, 'group', array[${admin}]::uuid[], 1)`)).rejects.toThrow();
      await db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, subjekt_id, rev) values (${meds}, ${familyId}, 'meds', array[${admin}]::uuid[], ${admin}, 1)`);
      // Subjekt muss ein Mitglied der Familie sein
      await expect(db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, subjekt_id, rev) values (${randomUUID()}, ${familyId}, 'meds', array[${admin}]::uuid[], ${randomUUID()}, 1)`)).rejects.toThrow();
      const m = randomUUID();
      await db.execute(sql`insert into medikamente (id, family_id, konversation_id, inhalt, rev) values (${m}, ${familyId}, ${meds}, 'e1:x', 1)`);
      await db.execute(sql`insert into einnahmen (family_id, konversation_id, medikament_id, inhalt, rev) values (${familyId}, ${meds}, ${m}, 'e1:x', 1)`);
      await expect(db.execute(sql`insert into medikamente (family_id, konversation_id, inhalt, rev) values (${familyId}, ${meds}, ${'e1:' + 'x'.repeat(17000)}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into einnahmen (family_id, konversation_id, medikament_id, inhalt, rev) values (${familyId}, ${randomUUID()}, ${m}, 'e1:x', 1)`)).rejects.toThrow();

      // Kaskade: Konversation weg -> Medikamente und Einnahmen weg
      await db.execute(sql`delete from konversationen where id = ${meds}`);
      expect((await db.execute(sql`select (select count(*) from medikamente)::int as m, (select count(*) from einnahmen)::int as e`)).rows[0]).toEqual({ m: 0, e: 0 });
    } finally {
      await world?.close();
      await client.close();
    }
  }, 120_000);
});
