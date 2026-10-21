// Migration 0018 (operators) ist rein additiv: Auf einer Datenbank im Stand 0017 mit echten Konten, Sitzungen und Audit-Einträgen bleiben alle
// Zeilen unverändert; es gibt danach keinen Betreiber (die Ansicht "Betrieb" bleibt für alle 404), erst die CLI-Logik setzt die Rolle.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { grantOperator } from '../src/operator/service.js';
import { addMember, adminPassword, migrationsFolder, World } from './helpers.js';

function ordnerBis0017(): string {
  const raw = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string }[] };
  const dir = mkdtempSync(`${tmpdir()}/lx-mig-betreiber-`);
  mkdirSync(`${dir}/meta`);
  const kept = raw.entries.filter((e) => e.tag.slice(0, 4) <= '0017');
  for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
  writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...raw, entries: kept }));
  return dir;
}

describe('Migration 0018 (Betreiber) additiv auf Stand 0017', () => {
  it('PGlite: Bestand unverändert, kein Betreiber, danach Vergabe und Zugriff', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    const alt = ordnerBis0017();
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder: alt });
      world = await World.create(db);
      const a = await adminPassword(world);
      await addMember(world, a.client, 'child', 'kind@example.org');
      const summe = async (t: string) => ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as h from ${t} x`))).rows[0] as { h: string }).h;
      const tabellen = ['users', 'memberships', 'credentials', 'sessions', 'audit_log', 'devices'];
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      await world.close();
      world = undefined;

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect((await db.execute(sql`select count(*)::int as n from operators`)).rows[0]).toMatchObject({ n: 0 });

      world = await World.create(db);
      const login = world.client('203.0.113.201');
      const res = await login.post('/api/v1/auth/login/password', { email: a.email, password: a.password, totp: await world.totp(a.totpSecret, 1) });
      expect(res.status).toBe(200);
      login.adopt(res.json.session);
      expect((await login.get('/api/v1/admin/status')).status).toBe(404);
      expect((await login.get('/api/v1/me')).json.operator).toBe(false);
      await grantOperator(world.auth.ctx, a.email);
      expect((await login.get('/api/v1/admin/status')).status).toBe(200);
    } finally {
      await world?.close();
      await client.close();
      rmSync(alt, { recursive: true, force: true });
    }
  }, 120_000);
});
