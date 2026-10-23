// Migration 0031 (Zähler: Konversationsart `zaehler`, Tabellen zaehler und zaehlerstaende) ist additiv und idempotent:
// Zweimal ausgeführt ändert sie nichts und wirft nicht; die Prüfungen der Datenbank greifen (Teilnehmerzahl, Kaskaden).
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

describe('Migration 0031 (Zähler) additiv und idempotent', () => {
  it('PGlite: erneutes Ausführen wirft nicht und ändert nichts, Prüfungen greifen, Kaskade über Konversation', async () => {
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

      const datei = readFileSync(`${migrationsFolder}/0031_zaehler.sql`, 'utf8');
      const schritte = datei.split('--> statement-breakpoint').map((s) => s.trim()).filter(Boolean);
      expect(schritte.length).toBeGreaterThan(10);
      const stand = async () =>
        JSON.stringify((await db.execute(sql`select table_name, column_name, data_type from information_schema.columns where table_schema = 'public' and table_name in ('konversationen','zaehler','zaehlerstaende') order by 1, 2`)).rows) +
        JSON.stringify((await db.execute(sql`select conname from pg_constraint where conrelid in ('konversationen'::regclass, 'zaehler'::regclass, 'zaehlerstaende'::regclass) order by 1`)).rows) +
        JSON.stringify((await db.execute(sql`select indexname from pg_indexes where tablename in ('konversationen','zaehler','zaehlerstaende') order by 1`)).rows);
      const vorher = await stand();
      for (const s of schritte) await db.execute(sql.raw(s));
      expect(await stand()).toBe(vorher);

      // Teilnehmerzahl 1..20, kein Subjekt nötig (die Eindeutigkeit je Familie sichert die feste ID, kein Index: ein Enum-Wert ist im Indexprädikat nicht IMMUTABLE)
      const k = randomUUID();
      await db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${k}, ${familyId}, 'zaehler', array[${admin}]::uuid[], 1)`);
      await expect(db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${randomUUID()}, ${familyId}, 'zaehler', array[]::uuid[], 1)`)).rejects.toThrow();
      const z = randomUUID();
      await db.execute(sql`insert into zaehler (id, family_id, konversation_id, inhalt, rev) values (${z}, ${familyId}, ${k}, 'e1:x', 1)`);
      await db.execute(sql`insert into zaehlerstaende (family_id, konversation_id, zaehler_id, inhalt, rev) values (${familyId}, ${k}, ${z}, 'e1:x', 1)`);
      await expect(db.execute(sql`insert into zaehler (family_id, konversation_id, inhalt, rev) values (${familyId}, ${k}, ${'e1:' + 'x'.repeat(17000)}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into zaehlerstaende (family_id, konversation_id, zaehler_id, inhalt, rev) values (${familyId}, ${randomUUID()}, ${z}, 'e1:x', 1)`)).rejects.toThrow();

      await db.execute(sql`delete from konversationen where id = ${k}`);
      expect((await db.execute(sql`select (select count(*) from zaehler)::int as z, (select count(*) from zaehlerstaende)::int as s`)).rows[0]).toEqual({ z: 0, s: 0 });
    } finally {
      await world?.close();
      await client.close();
    }
  }, 120_000);
});
