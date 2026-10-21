// Migration 0016 (Zustand `pending` der Passwort-Sicherung) ist rein additiv: Auf einer Datenbank im Stand 0014 mit echten Zeilen
// (aktuell/verifiziert, veraltet, ersetzt) bleiben alle Zeilen unverändert; danach ist `pending` erlaubt (höchstens eine je Person).
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomBytes } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { adminPassword, migrationsFolder, World } from './helpers.js';

const blob = () => randomBytes(160).toString('base64url');

function ordnerBis0014(): string {
  const raw = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string }[] };
  const dir = mkdtempSync(`${tmpdir()}/lx-mig-pending-`);
  mkdirSync(`${dir}/meta`);
  const kept = raw.entries.filter((e) => e.tag.slice(0, 4) <= '0014');
  for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
  writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...raw, entries: kept }));
  return dir;
}

describe('Migration 0016 (pending) additiv auf Stand 0014', () => {
  it('PGlite', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    const alt = ordnerBis0014();
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder: alt });
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const a = (await adminPassword(world)).client;
      await a.post('/api/v1/me/keys', { publicEncKey: randomBytes(32).toString('base64url'), publicSignKey: randomBytes(32).toString('base64url') });
      const m = (await db.execute<{ user_id: string; family_id: string }>(sql`select user_id, family_id from memberships limit 1`)).rows[0] as { user_id: string; family_id: string };
      await db.execute(sql`insert into account_kdf (user_id) values (${m.user_id})`);
      const zeile = (state: string, verified: boolean) =>
        db.execute(
          sql`insert into key_backups_pw (user_id, family_id, blob, key_version, kdf_id, mem_kib, ops, salt_generation, state, verified_at) values (${m.user_id}, ${m.family_id}, ${blob()}, 1, 'argon2id-v1', 65536, 3, 1, ${state}, ${verified ? sql`now()` : null})`,
        );
      await zeile('superseded', true);
      await zeile('active', true);
      await expect(zeile('pending', false)).rejects.toThrow(); // vor 0016 nicht erlaubt
      const summe = async () => ((await db.execute<{ h: string }>(sql`select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as h from key_backups_pw x`)).rows[0] as { h: string }).h;
      const vorher = await summe();
      await world.close();
      world = undefined;

      await migrateLite(db as never, { migrationsFolder });
      expect(await summe()).toBe(vorher);
      await zeile('pending', false);
      await expect(zeile('pending', false)).rejects.toThrow(); // höchstens eine unbestätigte je Person
      await expect(zeile('active', true)).rejects.toThrow(); // höchstens eine aktuelle (Index von 0014 gilt weiter)
      await expect(zeile('unbekannt', false)).rejects.toThrow();
      await zeile('superseded', false); // beliebig viele ersetzte
      expect((await db.execute(sql`select state from key_backups_pw order by state, created_at`)).rows.map((r) => (r as { state: string }).state)).toEqual(['active', 'pending', 'superseded', 'superseded']);
    } finally {
      await world?.close().catch(() => undefined);
      rmSync(alt, { recursive: true, force: true });
      await client.close();
    }
  }, 120_000);
});
