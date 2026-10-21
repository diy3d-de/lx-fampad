// Migration 0020 (Archiv der Schlüsselsicherungen, Herkunft der Sitzungen, Sicherheitsereignisse für Schlüsselvorgänge) ist rein additiv: Auf einer Datenbank im
// Stand 0019 (hier: Bestand anlegen, die Objekte von 0020 wieder entfernen) mit echten Konten, Schlüsseln, Wiederherstellungs- und Passwort-Sicherungen, Sitzungen und
// alten Sicherheitsereignissen bleibt jede Zeile unverändert; die alten Sitzungen gelten weiter (Herkunft `login`), und der Schlüsselwechsel auf dem Bestand archiviert.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, Client, migrationsFolder, World } from './helpers.js';

const key = () => randomBytes(32).toString('base64url');
const blob = () => randomBytes(160).toString('base64url');
const kdf = { id: 'argon2id-v1', memKiB: 65536, ops: 3 };

describe('Migration 0020 (Kein Datenverlust) additiv auf Stand 0019', () => {
  it('PGlite: Bestand unverändert, alte Sitzungen gelten weiter, Wechsel archiviert den Bestand', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      const p = await addMember(world, a.client, 'child', 'papa@example.org');
      const id = async (email: string) => (await db.execute<{ id: string }>(sql`select id from users where email = ${email}`)).rows[0]?.id as string;
      // Bestand: Schlüssel für alle; Admin mit Wiederherstellungssicherung; Mama mit bestätigter Passwort-Sicherung; Papa mit bestätigter UND unbestätigter
      const adminBlob = blob();
      const mamaBlob = blob();
      const papaBlob = blob();
      for (const c of [a.client, m.client, p.client]) expect((await c.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
      expect((await a.client.put('/api/v1/me/key-backup', { blob: adminBlob, keyVersion: 1 })).status).toBe(200);
      const mamaPut = await m.client.put('/api/v1/me/key-backup-pw', { blob: mamaBlob, keyVersion: 1, kdf });
      expect((await m.client.post('/api/v1/me/key-backup-pw/verified', { id: mamaPut.json.id })).status).toBe(200);
      const papaPut = await p.client.put('/api/v1/me/key-backup-pw', { blob: papaBlob, keyVersion: 1, kdf });
      expect((await p.client.post('/api/v1/me/key-backup-pw/verified', { id: papaPut.json.id })).status).toBe(200);
      await p.client.put('/api/v1/me/key-backup-pw', { blob: blob(), keyVersion: 1, kdf });
      // ein altes Sicherheitsereignis (Stand 0019)
      await db.execute(sql`insert into security_events (family_id, user_id, kind, via) select family_id, user_id, 'password_reset_done', 'recovery_code' from memberships where user_id = ${await id('mama@example.org')}`);

      const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' and tablename <> 'key_backup_archive' order by 1`)).rows).map((r) => r.tablename);
      const ohne: Record<string, string> = { sessions: " - 'origin' - 'origin_at'", security_events: " - 'subject_id'" };
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${ohne[t] ?? ''})::text, '|' order by (to_jsonb(x)${ohne[t] ?? ''})::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      const uhr = world.clock;
      const personen = [a, m, p].map((x) => ({ cookie: x.client.cookie, csrf: x.client.csrf, bearer: x.client.bearer, ip: x.client.ip }));
      await world.close();
      world = undefined;

      // zurück in den Stand 0019: die Objekte der Migration 0020 weg, ihr Eintrag im Migrationsprotokoll weg (die Daten bleiben)
      await db.execute(sql`drop table key_backup_archive`);
      await db.execute(sql`alter table sessions drop column origin, drop column origin_at`);
      await db.execute(sql`alter table security_events drop constraint security_events_kind_ck, drop constraint security_events_via_ck`);
      await db.execute(sql`alter table security_events drop column subject_id`);
      await db.execute(sql`alter table security_events add constraint security_events_kind_ck check (kind in ('password_reset_requested', 'password_reset_done', 'account_reset_requested'))`);
      await db.execute(sql`alter table security_events add constraint security_events_via_ck check (via in ('admin', 'recovery_code', 'passkey'))`);
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0020_'));
      if (!meine) throw new Error('Journal ohne 0020');
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect((await db.execute(sql`select count(*)::int as n from key_backup_archive`)).rows[0]).toMatchObject({ n: 0 });
      // alle bestehenden Sitzungen: Herkunft `login`, kein Zeitpunkt (nie gesperrt)
      expect((await db.execute(sql`select origin, count(*)::int as n, count(origin_at)::int as mit from sessions group by origin`)).rows).toEqual([{ origin: 'login', n: 3, mit: 0 }]);
      // die Prüfungen der Datenbank: neue Ereignisarten gültig, andere nicht; Herkunft nur aus der festen Liste
      await db.execute(sql`insert into security_events (family_id, user_id, kind, via) select family_id, user_id, 'key_rotated', 'password' from memberships limit 1`);
      await expect(db.execute(sql`insert into security_events (family_id, user_id, kind, via) select family_id, user_id, 'beliebig', 'password' from memberships limit 1`)).rejects.toThrow();
      await expect(db.execute(sql`update sessions set origin = 'beliebig'`)).rejects.toThrow();
      await db.execute(sql`delete from security_events where kind = 'key_rotated'`);

      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      world.clock = uhr;
      const [admin, mama, papa] = personen.map((x) => {
        const c = new Client(world as World, x.ip);
        c.cookie = x.cookie;
        c.csrf = x.csrf;
        c.bearer = x.bearer;
        return c;
      }) as [Client, Client, Client];
      // die alten Sitzungen gelten weiter, die Antworten zeigen den Bestand (nur die neuen Felder kommen dazu)
      expect((await admin.get('/api/v1/me/keys')).json).toMatchObject({ keys: { keyVersion: 1 }, hasBackup: true, pwBackupVerifiedAt: null, archiveCount: 0 });
      expect((await mama.get('/api/v1/me/keys')).json).toMatchObject({ hasBackup: false, pwBackupVerifiedAt: expect.any(String), archiveCount: 0 });
      const alteEreignisse = (await mama.get('/api/v1/me/security-events')).json.events as Array<{ kind: string; subjectName: string | null }>;
      expect(alteEreignisse).toHaveLength(1);
      expect(alteEreignisse[0]).toMatchObject({ kind: 'password_reset_done', subjectName: null });

      // Schlüsselwechsel auf dem Bestand: nichts geht verloren, alles ist über das Archiv erreichbar
      const wechsel = await admin.put('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key(), expectedKeyVersion: 1 });
      expect(wechsel.status).toBe(200);
      const l = (await admin.get('/api/v1/me/key-backups/archive')).json.entries as Array<{ id: string; kind: string }>;
      expect(l).toHaveLength(1);
      expect((await admin.get(`/api/v1/me/key-backups/archive/${l[0]?.id}`)).json.blob).toBe(adminBlob);
      const wechselPapa = await papa.put('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key(), expectedKeyVersion: 1 });
      expect(wechselPapa.status).toBe(200);
      const pl = (await papa.get('/api/v1/me/key-backups/archive')).json.entries as Array<{ id: string; kind: string; verified: boolean }>;
      expect(pl.map((e) => e.verified).sort()).toEqual([false, true]); // bestätigte und unbestätigte Zeile, beide erreichbar
      expect((await papa.get(`/api/v1/me/key-backups/archive/${papaPut.json.id}`)).json.blob).toBe(papaBlob);
      expect(await world.count('key_backups_pw')).toBe(3); // nichts gelöscht
    } finally {
      await world?.close().catch(() => undefined);
      await client.close();
    }
  }, 180_000);
});
