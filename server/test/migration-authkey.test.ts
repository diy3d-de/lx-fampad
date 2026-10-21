// Migration 0017 (password_authkeys) ist rein additiv: Auf einer Datenbank im Stand 0016 mit echten Konten (Passwort + TOTP, Passkey),
// Schlüsseln, Passwort-Sicherung und Sitzungen bleiben alle Zeilen unverändert; alle Konten sind danach "legacy" und melden sich weiter
// mit dem Klartext-Passwort an; erst der Upgrade beim Login schaltet auf authKey.
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

const key = () => randomBytes(32).toString('base64url');

function ordnerBis0016(): string {
  const raw = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string }[] };
  const dir = mkdtempSync(`${tmpdir()}/lx-mig-authkey-`);
  mkdirSync(`${dir}/meta`);
  const kept = raw.entries.filter((e) => e.tag.slice(0, 4) <= '0016');
  for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
  writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...raw, entries: kept }));
  return dir;
}

describe('Migration 0017 (authKey) additiv auf Stand 0016', () => {
  it('PGlite: Bestand unverändert, alle Konten legacy, Klartext-Login geht, Upgrade und authKey-Login danach', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    const alt = ordnerBis0016();
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder: alt });
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const a = await adminPassword(world);
      await a.client.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() });
      const put = await a.client.put('/api/v1/me/key-backup-pw', { blob: randomBytes(160).toString('base64url'), keyVersion: 1, kdf: { id: 'argon2id-v1', memKiB: 65536, ops: 3 } });
      await a.client.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id });
      const inv = await a.client.post('/api/v1/invites', { role: 'parent' });
      await world.registerPasskey(inv.json.invite.token, { email: 'papa@example.org', displayName: 'Papa' });

      const summe = async (t: string) => ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as h from ${t} x`))).rows[0] as { h: string }).h;
      const tabellen = ['users', 'memberships', 'credentials', 'person_keys', 'key_backups_pw', 'sessions', 'recovery_codes'];
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      await world.close();
      world = undefined;

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect((await db.execute(sql`select count(*)::int as n from password_authkeys`)).rows[0]).toMatchObject({ n: 0 });

      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const login = async (body: Record<string, unknown>) => {
        world!.advance(31_000);
        return world!.client('203.0.113.200').post('/api/v1/auth/login/password', { email: a.email, totp: await world!.totp(a.totpSecret), ...body });
      };
      expect((await login({ authKey: key() })).status).toBe(401); // legacy: authKey geht noch nicht
      const ak = key();
      expect((await login({ password: 'ein-sehr-langes-passwort-123', upgradeAuthKey: ak })).status).toBe(200);
      expect((await login({ authKey: ak })).status).toBe(200);
      expect((await login({ password: 'ein-sehr-langes-passwort-123' })).status).toBe(200);
      // Sicherung und Schlüssel unberührt vom Upgrade
      expect(await summe('key_backups_pw')).toBe(vorher.get('key_backups_pw'));
      expect(await summe('person_keys')).toBe(vorher.get('person_keys'));
      // das Passkey-Konto hat nie einen Prüfwert
      expect((await db.execute(sql`select count(*)::int as n from password_authkeys`)).rows[0]).toMatchObject({ n: 1 });
    } finally {
      await world?.close().catch(() => undefined);
      rmSync(alt, { recursive: true, force: true });
      await client.close();
    }
  }, 120_000);
});

