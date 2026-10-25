// Migration 0025 (Betrieb Paket 3: Fehlerzähler des Wetter-Dienstes, tägliche Messpunkte) ist rein additiv: Auf einer Datenbank im Stand 0023 (hier: Bestand anlegen, die Objekte
// von 0025 wieder entfernen) mit einer Familie, Konten und gespeicherten Wetter-Zugangsdaten bleibt jede Zeile unverändert, der Fehlerzähler beginnt bei 0, die neue Tabelle ist leer,
// und die Prüfungen der Datenbank greifen.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { adminPassword, migrationsFolder, World } from './helpers.js';

describe('Migration 0025 (Betrieb Paket 3) additiv auf Stand 0023', () => {
  it('PGlite: Bestand unverändert, Fehlerzähler 0, Messpunkte-Tabelle leer und geprüft', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, {});
      await adminPassword(world);
      await db.execute(sql`insert into weather_credentials (id, client_id_enc, client_secret_enc, refresh_token_enc, last_error_code) values (1, 'v1.a', 'v1.b', 'v1.c', 'http_500')`);
      await world.close();
      world = undefined;

      const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' and tablename <> 'files' and tablename <> 'operator_metrics' order by 1`)).rows).map((r) => r.tablename);
      const ohne: Record<string, string> = { weather_credentials: " - 'error_count'" };
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${ohne[t] ?? ''})::text, '|' order by (to_jsonb(x)${ohne[t] ?? ''})::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));

      // zurück in den Stand 0023: die Objekte der Migration 0025 weg, ihr Eintrag im Migrationsprotokoll weg (die Daten bleiben)
      // Migration 0027 (Abfuhrtermine) ist die neueste und geht zuerst zurück
      await db.execute(sql`drop table if exists waste_events, waste_years, waste_state`);
      // Migration 0026 (Passkey-Sicherung, Eltern-Wiederherstellung; neuer als 0025, also zuerst zurück)
      await db.execute(sql`drop table guardian_escrows, guardian_recoveries, key_backups_prf`);
      await db.execute(sql`alter table credentials drop column device_type, drop column backed_up`);
      await db.execute(sql`drop table operator_metrics`);
      await db.execute(sql`alter table weather_credentials drop column error_count`);
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0025_'));
      if (!meine) throw new Error('Journal ohne 0025');
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect((await db.execute(sql`select error_count, last_error_code from weather_credentials`)).rows).toEqual([{ error_count: 0, last_error_code: 'http_500' }]);
      expect((await db.execute(sql`select count(*)::int as n from operator_metrics`)).rows[0]).toMatchObject({ n: 0 });
      // die Prüfungen der Datenbank: Tabelle verlangt eine Familie, Zähler dürfen nicht negativ sein, je Tag eine Zeile
      const [fam] = (await db.execute<{ id: string }>(sql`select id from families limit 1`)).rows as [{ id: string }];
      await db.execute(sql`insert into operator_metrics (family_id, day) values (${fam.id}, '2026-10-20')`);
      await expect(db.execute(sql`insert into operator_metrics (family_id, day) values (${fam.id}, '2026-10-20')`)).rejects.toThrow();
      await expect(db.execute(sql`insert into operator_metrics (family_id, day, sync_runs) values (${fam.id}, '2026-10-21', -1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into operator_metrics (family_id, day) values ('00000000-0000-4000-8000-000000000000', '2026-10-21')`)).rejects.toThrow();
      // beim Löschen der Familie verschwinden die Messpunkte mit
      await db.execute(sql`delete from families where id = ${fam.id}`);
      expect((await db.execute(sql`select count(*)::int as n from operator_metrics`)).rows[0]).toMatchObject({ n: 0 });
    } finally {
      await world?.close().catch(() => undefined);
      await client.close();
    }
  }, 180_000);
});
