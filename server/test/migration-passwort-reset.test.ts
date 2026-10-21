// Migration 0019 (invites.kind, security_events) ist rein additiv: Auf einer Datenbank im Stand 0018 (hier: Bestand anlegen, die Objekte von 0019 wieder entfernen) mit echten Konten, Schlüsseln, Passwort-Sicherung,
// offenen Einladungen (auch einem Komplett-Reset-Link) bleiben alle Zeilen unverändert; alte Einladungen sind danach `standard` und funktionieren
// wie vorher; der neue Passwort-Reset greift auf demselben Bestand.
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

describe('Migration 0019 (Passwort-Reset) additiv auf Stand 0018', () => {
  it('PGlite: Bestand unverändert, alte Einladungen standard und einlösbar, Passwort-Reset und Sicherung danach', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      await m.client.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() });
      const put = await m.client.put('/api/v1/me/key-backup-pw', { blob: randomBytes(160).toString('base64url'), keyVersion: 1, kdf: { id: 'argon2id-v1', memKiB: 65536, ops: 3 } });
      await m.client.post('/api/v1/me/key-backup-pw/verified', { id: put.json.id });
      // Bestandsmitglied Papa: Schlüssel, bestätigte Sicherung (active) UND eine unbestätigte (pending), Wiederherstellungscodes unberührt
      const p = await addMember(world, a.client, 'parent', 'papa@example.org');
      const kdf = { id: 'argon2id-v1', memKiB: 65536, ops: 3 };
      await p.client.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() });
      const papaPut = await p.client.put('/api/v1/me/key-backup-pw', { blob: randomBytes(160).toString('base64url'), keyVersion: 1, kdf });
      await p.client.post('/api/v1/me/key-backup-pw/verified', { id: papaPut.json.id });
      await p.client.put('/api/v1/me/key-backup-pw', { blob: randomBytes(160).toString('base64url'), keyVersion: 1, kdf });
      const papaId = (await db.execute<{ id: string }>(sql`select id from users where email = 'papa@example.org'`)).rows[0]?.id as string;
      const offen = await a.client.post('/api/v1/invites', { role: 'child' });
      const kind = (await db.execute<{ id: string }>(sql`select id from users where email = 'mama@example.org'`)).rows[0]?.id as string;
      world.advance(31_000);
      await a.client.post('/api/v1/auth/step-up/code', { totp: await world.totp(a.totpSecret) });
      const komplett = await a.client.post(`/api/v1/members/${kind}/reset`, {});
      expect(komplett.status).toBe(200);

      const summe = async (t: string, ohne = '') =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${ohne})::text, '|' order by (to_jsonb(x)${ohne})::text), '')) as h from ${t} x`))).rows[0] as { h: string }).h;
      const tabellen = ['users', 'memberships', 'credentials', 'person_keys', 'key_backups_pw', 'sessions', 'recovery_codes', 'password_authkeys'];
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      vorher.set('invites', await summe('invites', " - 'kind'"));
      await world.close();
      world = undefined;
      // zurück in den Stand 0018: die Objekte der Migration 0019 weg, ihr Eintrag im Migrationsprotokoll weg (die Daten bleiben)
      await db.execute(sql`alter table invites drop constraint invites_kind_ck`);
      await db.execute(sql`alter table invites drop column kind`);
      await db.execute(sql`drop table security_events`);
      // genau die Zeile der Migration 0019 (nach Zeitstempel des Journals, nicht "die letzte")
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0019_'));
      if (!meine) throw new Error('Journal ohne 0019');
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at = ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect(await summe('invites', " - 'kind'")).toBe(vorher.get('invites'));
      expect((await db.execute(sql`select kind, count(*)::int as n from invites group by kind`)).rows).toEqual([{ kind: 'standard', n: 5 }]);
      expect((await db.execute(sql`select count(*)::int as n from security_events`)).rows[0]).toMatchObject({ n: 0 });
      // die Prüfung der Datenbank: Passwort-Reset-Einladung nur mit Konto
      await expect(db.execute(sql`insert into invites (family_id, role, token_hash, expires_at, kind) select id, 'child', 'x', now(), 'password_reset' from families limit 1`)).rejects.toThrow();

      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      // die alte Einladung (neues Mitglied) und der Komplett-Reset-Link funktionieren wie vorher
      const look = await world.client('203.0.113.200').post('/api/v1/auth/invites/lookup', { token: offen.json.invite.token });
      expect(look.json.invite).toMatchObject({ kind: 'standard', reset: false });
      const look2 = await world.client('203.0.113.201').post('/api/v1/auth/invites/lookup', { token: komplett.json.invite.token });
      expect(look2.json.invite).toMatchObject({ kind: 'standard', reset: true });
      const reg = await world.registerPasskey(offen.json.invite.token, { email: 'kind@example.org', displayName: 'Kind' });
      expect(reg.complete?.status).toBe(200);
      // Passwort-Reset auf dem Bestand: Sicherung wird stale, nichts gelöscht, Schlüssel unverändert
      const keysVorher = await summe('person_keys');
      world.advance(31_000);
      const zeilen = async () => (await db.execute<{ state: string }>(sql`select state from key_backups_pw where user_id = ${papaId} order by state`)).rows.map((x) => x.state);
      expect(await zeilen()).toEqual(['active', 'pending']);
      const gesamt = (await db.execute<{ n: number }>(sql`select count(*)::int as n from key_backups_pw`)).rows[0]?.n;
      const falsch = await world.client('203.0.113.202').post('/api/v1/auth/password-reset/recovery', { email: 'papa@example.org', code: 'AAAA-BBBB-CCCC', authKey: key(), client: 'app' });
      expect(falsch.status).toBe(401);
      expect(await zeilen()).toEqual(['active', 'pending']);
      const rec = await world.client('203.0.113.203').post('/api/v1/auth/password-reset/recovery', { email: 'papa@example.org', code: p.recoveryCodes[0], authKey: key(), client: 'app' });
      expect(rec.status).toBe(200);
      expect(rec.json.recoveryCodesRemaining).toBe(9);
      expect(await zeilen()).toEqual(['stale', 'superseded']);
      expect((await db.execute(sql`select count(*)::int as n from key_backups_pw`)).rows[0]?.n).toBe(gesamt); // nichts gelöscht
      expect(await summe('person_keys')).toBe(keysVorher);
    } finally {
      await world?.close().catch(() => undefined);
      await client.close();
    }
  }, 180_000);
});
