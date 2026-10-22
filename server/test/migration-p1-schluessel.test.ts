// Migration 0022 (P1 Schlüssel-Paket: Soft-Delete der Mitglieder, `users.removed_at`/`removed_by`) ist rein additiv: Auf einer Datenbank im Stand 0021 (hier: Bestand anlegen,
// die Objekte von 0022 wieder entfernen) bleibt jede Zeile unverändert, bestehende Personen sind "nicht entfernt" (null), und die Prüfung der Datenbank greift
// (entfernt ohne gesperrt ist verboten).
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, migrationsFolder, World } from './helpers.js';

const key = () => randomBytes(32).toString('base64url');

describe('Migration 0022 (P1 Schlüssel-Paket) additiv auf Stand 0021', () => {
  it('PGlite: Bestand unverändert, nichts ist entfernt, die Prüfung greift, Entfernen und Wiederherstellen laufen danach', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      expect((await m.client.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
      const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' order by 1`)).rows).map((r) => r.tablename);
      const ohne: Record<string, string> = { users: " - 'removed_at' - 'removed_by'" };
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${ohne[t] ?? ''})::text, '|' order by (to_jsonb(x)${ohne[t] ?? ''})::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      const uhr = world.clock;
      const adminCookie = { cookie: a.client.cookie, csrf: a.client.csrf, ip: a.client.ip };
      await world.close();
      world = undefined;

      // zurück in den Stand 0021: die Objekte von 0022 weg, ihr Eintrag im Migrationsprotokoll weg (die Daten bleiben)
      await db.execute(sql`drop table operator_metrics`); // Migration 0025 (Betrieb Paket 3)
      await db.execute(sql`alter table weather_credentials drop column error_count`);
      await db.execute(sql`drop table operator_settings`); // Migration 0023 (Betreiber Paket 2b) liegt über 0022 und wird beim erneuten Migrieren wieder angelegt
      await db.execute(sql`drop table guardian_escrows, guardian_recoveries, key_backups_prf`); // Migration 0026 (Passkey-Sicherung, Eltern-Wiederherstellung), wird beim erneuten Migrieren wieder angelegt
      await db.execute(sql`alter table credentials drop column device_type, drop column backed_up`); // Migration 0026 (Art des Passkeys)
      await db.execute(sql`alter table users drop constraint users_removed_ck`);
      await db.execute(sql`alter table users drop column removed_at, drop column removed_by`);
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0022_'));
      if (!meine) throw new Error('Journal ohne 0022');
      await db.execute(sql`drop table if exists waste_events, waste_years, waste_state`); // Migration 0027 (Abfuhrtermine) liegt darüber und wird beim erneuten Migrieren wieder angelegt
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect((await db.execute(sql`select count(*)::int as n, count(removed_at)::int as r, count(removed_by)::int as b from users`)).rows[0]).toMatchObject({ n: 2, r: 0, b: 0 });
      // Prüfung der Datenbank: entfernt ist immer auch gesperrt
      await expect(db.execute(sql`update users set removed_at = now() where email = 'mama@example.org'`)).rejects.toThrow();
      await db.execute(sql`update users set removed_at = now(), disabled_at = now() where email = 'mama@example.org'`);
      await db.execute(sql`update users set removed_at = null, disabled_at = null where email = 'mama@example.org'`);

      // die alte Sitzung gilt weiter, Entfernen und Wiederherstellen laufen auf dem Bestand
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      world.clock = uhr;
      const admin = world.client(adminCookie.ip);
      admin.cookie = adminCookie.cookie;
      admin.csrf = adminCookie.csrf;
      expect((await admin.get('/api/v1/me')).status).toBe(200);
      expect((await admin.get('/api/v1/members/removed')).json.members).toEqual([]);
      expect((await admin.get('/api/v1/me/key-status')).status).toBe(200);
    } finally {
      await world?.close().catch(() => undefined);
      await client.close();
    }
  }, 180_000);
});
