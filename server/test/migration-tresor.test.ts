// Migration 0032 (Tresor: Konversationsart `tresor`, Tabelle tresor_eintraege) ist additiv und idempotent:
// Zweimal ausgeführt ändert sie nichts und wirft nicht; die Prüfungen der Datenbank greifen (Teilnehmerzahl, Größe, Kaskade).
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

describe('Migration 0032 (Tresor) additiv und idempotent', () => {
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

      const datei = readFileSync(`${migrationsFolder}/0032_tresor.sql`, 'utf8');
      const schritte = datei.split('--> statement-breakpoint').map((s) => s.trim()).filter(Boolean);
      expect(schritte.length).toBeGreaterThan(10);
      const stand = async () =>
        JSON.stringify((await db.execute(sql`select table_name, column_name, data_type from information_schema.columns where table_schema = 'public' and table_name in ('konversationen','tresor_eintraege') order by 1, 2`)).rows) +
        JSON.stringify((await db.execute(sql`select conname from pg_constraint where conrelid in ('konversationen'::regclass, 'tresor_eintraege'::regclass) order by 1`)).rows) +
        JSON.stringify((await db.execute(sql`select indexname from pg_indexes where tablename in ('konversationen','tresor_eintraege') order by 1`)).rows);
      const vorher = await stand();
      for (const s of schritte) await db.execute(sql.raw(s));
      expect(await stand()).toBe(vorher);

      // Teilnehmerzahl 1..20, kein Subjekt nötig (die Eindeutigkeit je Familie sichert die feste ID, kein Index: ein Enum-Wert ist im Indexprädikat nicht IMMUTABLE)
      const k = randomUUID();
      await db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${k}, ${familyId}, 'tresor', array[${admin}]::uuid[], 1)`);
      await expect(db.execute(sql`insert into konversationen (id, family_id, art, teilnehmer, rev) values (${randomUUID()}, ${familyId}, 'tresor', array[]::uuid[], 1)`)).rejects.toThrow();
      await db.execute(sql`insert into tresor_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${k}, 'e1:x', 1)`);
      // 16000 Byte Klartext passen (rund 21 700 Zeichen), mehr als 24576 Zeichen nicht
      await db.execute(sql`insert into tresor_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${k}, ${'e1:' + 'x'.repeat(22000)}, 1)`);
      await expect(db.execute(sql`insert into tresor_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${k}, ${'e1:' + 'x'.repeat(25000)}, 1)`)).rejects.toThrow();
      // fremde Konversation: Fremdschlüssel greift
      await expect(db.execute(sql`insert into tresor_eintraege (family_id, konversation_id, inhalt, rev) values (${familyId}, ${randomUUID()}, 'e1:x', 1)`)).rejects.toThrow();

      await db.execute(sql`delete from konversationen where id = ${k}`);
      expect((await db.execute(sql`select count(*)::int as n from tresor_eintraege`)).rows[0]).toEqual({ n: 0 });
    } finally {
      await world?.close();
      await client.close();
    }
  }, 120_000);
});
