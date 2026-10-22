// Migration 0021 (Betreiber Paket 2a: Schlüsselstand am Gerät, Warn-Schalter am Betreiber, Zustand der Warnungen) ist rein additiv: Auf einer Datenbank im Stand 0020
// (hier: Bestand anlegen, die Objekte von 0021 wieder entfernen) mit Konten, Geräten, Schlüsseln und einem Betreiber bleibt jede Zeile unverändert, die alten Geräte
// haben "nie gemeldet" (null), der bestehende Betreiber hat die Warnungen an, und die Prüfungen der Datenbank greifen.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import { grantOperator } from '../src/operator/service.js';
import * as schema from '../src/db/schema.js';
import { addMember, adminPassword, Client, migrationsFolder, World } from './helpers.js';

const key = () => randomBytes(32).toString('base64url');

describe('Migration 0021 (Betreiber Paket 2a) additiv auf Stand 0020', () => {
  it('PGlite: Bestand unverändert, alte Geräte "nie gemeldet", Betreiber mit Warnungen an, Ampel und Prüfer laufen danach', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      const a = await adminPassword(world);
      const m = await addMember(world, a.client, 'parent', 'mama@example.org');
      await grantOperator(world.auth.ctx, a.email);
      for (const c of [a.client, m.client]) expect((await c.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);

      const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' and tablename <> 'operator_alert_state' order by 1`)).rows).map((r) => r.tablename);
      const ohne: Record<string, string> = { devices: " - 'key_version' - 'key_reported_at'", operators: " - 'alerts_enabled'" };
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${ohne[t] ?? ''})::text, '|' order by (to_jsonb(x)${ohne[t] ?? ''})::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      const uhr = world.clock;
      const personen = [a, m].map((x) => ({ cookie: x.client.cookie, csrf: x.client.csrf, bearer: x.client.bearer, ip: x.client.ip }));
      await world.close();
      world = undefined;

      // zurück in den Stand 0020: die Objekte der Migration 0021 weg, ihr Eintrag im Migrationsprotokoll weg (die Daten bleiben)
      await db.execute(sql`drop table operator_metrics`); // Migration 0025 (Betrieb Paket 3)
      await db.execute(sql`alter table weather_credentials drop column error_count`);
      await db.execute(sql`drop table operator_settings`); // Migration 0023 (Betreiber Paket 2b), wird beim erneuten Migrieren wieder angelegt
      await db.execute(sql`drop table guardian_escrows, guardian_recoveries, key_backups_prf`); // Migration 0026 (Passkey-Sicherung, Eltern-Wiederherstellung), wird beim erneuten Migrieren wieder angelegt
      await db.execute(sql`alter table credentials drop column device_type, drop column backed_up`); // Migration 0026 (Art des Passkeys)
      // ... und die Objekte der Migration 0022 (P1 Schlüssel-Paket, Soft-Delete der Mitglieder; sie gilt hier als noch nicht angewendet)
      await db.execute(sql`alter table users drop constraint users_removed_ck`);
      await db.execute(sql`alter table users drop column removed_at, drop column removed_by`);
      await db.execute(sql`drop table operator_alert_state`);
      await db.execute(sql`alter table operators drop column alerts_enabled`);
      await db.execute(sql`alter table devices drop constraint devices_key_version_ck`);
      await db.execute(sql`alter table devices drop column key_version, drop column key_reported_at`);
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0021_'));
      if (!meine) throw new Error('Journal ohne 0021');
      await db.execute(sql`drop table if exists waste_events, waste_years, waste_state`); // Migration 0027 (Abfuhrtermine) liegt darüber und wird beim erneuten Migrieren wieder angelegt
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      // neue Spalten: alte Geräte haben nie gemeldet, der Betreiber hat die Warnungen an, der Zustand ist leer
      expect((await db.execute(sql`select count(*)::int as n, count(key_version)::int as v, count(key_reported_at)::int as t from devices`)).rows[0]).toMatchObject({ n: 2, v: 0, t: 0 });
      expect((await db.execute(sql`select alerts_enabled from operators`)).rows).toEqual([{ alerts_enabled: true }]);
      expect((await db.execute(sql`select count(*)::int as n from operator_alert_state`)).rows[0]).toMatchObject({ n: 0 });
      // die Prüfungen der Datenbank
      await expect(db.execute(sql`update devices set key_version = -1`)).rejects.toThrow();
      await db.execute(sql`update devices set key_version = 0`);
      await db.execute(sql`update devices set key_version = null`);
      await expect(db.execute(sql`insert into operator_alert_state (family_id, kind) select id, '' from families limit 1`)).rejects.toThrow();

      // die alten Sitzungen gelten weiter; ein Gerät ohne Bericht heißt "unbekannt", die Ampel läuft auf dem Bestand
      world = await World.create(db, { E2EE_PW_BACKUP: 'true' });
      world.clock = uhr;
      const [admin, mama] = personen.map((x) => {
        const c = new Client(world as World, x.ip);
        c.cookie = x.cookie;
        c.csrf = x.csrf;
        c.bearer = x.bearer;
        return c;
      }) as [Client, Client];
      const ks = await admin.get('/api/v1/admin/key-status');
      expect(ks.status).toBe(200);
      expect(ks.json).toMatchObject({ overall: 'red', ready: false, counts: { green: 0, yellow: 0, red: 2 } });
      expect((await mama.put('/api/v1/me/device-key', { keyVersion: 1 })).status).toBe(200);
      expect((await admin.get('/api/v1/admin/key-status')).json.counts).toMatchObject({ yellow: 1, red: 1 });
      expect((await admin.get('/api/v1/admin/warnings')).json).toMatchObject({ enabled: true, active: [] });
      // der Prüfer läuft auf dem Bestand (zwei rote Schlüssel-Ampeln, aber kein Push eingerichtet: kein Fehler)
      const r = await world.app.operatorMonitor!.runOnce();
      expect(r.families).toBe(1);
    } finally {
      await world?.close().catch(() => undefined);
      await client.close();
    }
  }, 180_000);
});
