// Migration 0014 (Passwort-Sicherung) ist rein additiv: Auf einer Datenbank im Stand 0012 mit echten Daten (Schlüssel, Historie, Sicherung,
// Übertragung, Chat mit Epoche, Wraps, Nachricht) bleibt jede alte Tabelle unverändert, und die alten Routen antworten vorher und
// nachher (Schalter aus und an) gleich.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzlePg } from 'drizzle-orm/node-postgres';
import { migrate as migratePg } from 'drizzle-orm/node-postgres/migrator';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import pg from 'pg';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { epocheId, wrapId } from '../src/sync/entities/chat-ids.js';
import { Client, migrationsFolder, World, kindSpalteEntfernen, kindSpalteErgaenzen } from './helpers.js';
import { createFamily, Device, upsert, type Json } from './sync-kit.js';

const key = () => randomBytes(32).toString('base64url');
const blob = (n = 120) => randomBytes(n).toString('base64url');

interface Entry {
  tag: string;
}

/** Kopie des Migrationsordners bis einschließlich 0012 (Stand v0.5.4). */
function ordnerBis0012(): string {
  const raw = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Entry[] };
  const dir = mkdtempSync(`${tmpdir()}/lx-mig-pw-`);
  mkdirSync(`${dir}/meta`);
  const kept = raw.entries.filter((e) => e.tag.slice(0, 4) <= '0012');
  for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
  writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...raw, entries: kept }));
  return dir;
}

async function pruefen(db: Db, migrateTo: (folder: string) => Promise<void>) {
  const alt = ordnerBis0012();
  const welten: World[] = [];
  try {
    await migrateTo(alt);
    expect((await db.execute(sql`select to_regclass('public.key_backups_pw') as t`)).rows[0]).toEqual({ t: null });
    await kindSpalteErgaenzen(db);

    // ----- Stand v0.5.4 mit Daten -----
    const w1 = await World.create(db, { SYNC_RATE_LIMIT_MAX: '100000' });
    welten.push(w1);
    const fam = await createFamily(w1);
    const personen = [fam.admin, fam.parent, fam.child];
    for (const d of personen) expect((await d.client.post('/api/v1/me/keys', { publicEncKey: key(), publicSignKey: key() })).status).toBe(200);
    expect((await fam.admin.client.put('/api/v1/me/key-backup', { blob: blob(), keyVersion: 1 })).status).toBe(200);
    expect((await fam.parent.client.post('/api/v1/me/key-transfer', { lookup: key(), blob: blob(), keyVersion: 1 })).status).toBe(200);
    // Schlüsselwechsel des Kindes direkt in der Datenbank (die neue Rotation braucht schon die Tabelle von 0014): Historie und Version 2
    await db.execute(sql`insert into person_key_history (user_id, key_version, enc_key, sign_key, valid_from, valid_until) select user_id, key_version, public_enc_key, public_sign_key, updated_at, now() from person_keys where user_id = ${fam.child.userId}`);
    await db.execute(sql`update person_keys set public_enc_key = ${key()}, public_sign_key = ${key()}, key_version = 2, updated_at = now() where user_id = ${fam.child.userId}`);
    const konv = randomUUID();
    const nachricht = `e1:${'A'.repeat(200)}`;
    for (const op of [
      upsert('konversation', konv, { art: 'group', teilnehmer: [fam.parent.userId, fam.child.userId] }),
      upsert('epoche', epocheId(konv, 1), { konversationId: konv, epoche: 1, mitglieder: 'B'.repeat(200) }),
      upsert('epoche_wrap', wrapId(konv, 1, fam.parent.userId), { konversationId: konv, epoche: 1, empfaengerId: fam.parent.userId, wrap: 'C'.repeat(120) }),
      upsert('epoche_wrap', wrapId(konv, 1, fam.child.userId), { konversationId: konv, epoche: 1, empfaengerId: fam.child.userId, wrap: 'D'.repeat(120) }),
      upsert('nachricht', randomUUID(), { konversationId: konv, text: nachricht }),
    ]) {
      const r = await fam.parent.sync([op]);
      expect(r.json.rejected, JSON.stringify(r.json.rejected)).toEqual([]);
    }

    /** Antworten der alten Routen (Sync-Abruf zuletzt, damit er nichts davor verändert). */
    const antworten = async (w: World, ds: Device[]): Promise<Json> => {
      const [admin, parent, child] = ds as [Device, Device, Device];
      const out: Json = {
        keysAdmin: (await admin.client.get('/api/v1/me/keys')).json,
        keysChild: (await child.client.get('/api/v1/me/keys')).json,
        members: (await admin.client.get('/api/v1/members')).json,
        historie: (await parent.client.get(`/api/v1/members/${child.userId}/keys`)).json,
        sicherung: (await admin.client.get('/api/v1/me/key-backup')).json,
      };
      void w;
      for (const [name, d] of [['admin', admin], ['parent', parent], ['child', child]] as const) out[`pull_${name}`] = await d.pull();
      return out;
    };
    const r1 = await antworten(w1, personen);
    expect(r1.pull_parent.length).toBeGreaterThan(0);

    /** Prüfsumme je Tabelle (alle Spalten, alle Zeilen). */
    const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' order by 1`)).rows).map((r) => r.tablename);
    const summen = async () => {
      const out: Record<string, string> = {};
      for (const t of tabellen) out[t] = ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${t === 'invites' ? " - 'kind'" : ''})::text, '|' order by (to_jsonb(x)${t === 'invites' ? " - 'kind'" : ''})::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      return out;
    };
    const vorher = await summen();
    const uhr = w1.clock;
    await w1.close();
    welten.pop();

    // ----- Migration 0014 (und alle späteren) -----
    await kindSpalteEntfernen(db);
    await migrateTo(migrationsFolder);
    const nachher = await summen();
    for (const t of tabellen) expect(nachher[t], `Tabelle ${t} unverändert`).toBe(vorher[t]);
    for (const neu of ['account_kdf', 'key_backups_pw']) {
      expect((await db.execute(sql.raw(`select count(*)::int as n from "${neu}"`))).rows[0]).toEqual({ n: 0 });
    }

    // ----- alte Routen antworten gleich (Schalter aus und an), dieselben Sitzungen gelten weiter -----
    for (const flag of [undefined, 'true']) {
      const w = await World.create(db, { SYNC_RATE_LIMIT_MAX: '100000', ...(flag ? { E2EE_PW_BACKUP: flag } : {}) });
      welten.push(w);
      w.clock = uhr;
      const ds = personen.map((d) => {
        const c = new Client(w, d.client.ip);
        c.cookie = d.client.cookie;
        c.csrf = d.client.csrf;
        c.bearer = d.client.bearer;
        return new Device(w, c, d.deviceId, d.userId, d.role);
      });
      const r = await antworten(w, ds);
      expect(r, `Schalter ${flag ?? 'aus'}`).toEqual(r1);
      await w.close();
      welten.pop();
    }
  } finally {
    for (const w of welten) await w.close().catch(() => undefined);
    rmSync(alt, { recursive: true, force: true });
  }
}

describe('Migration 0014 (Passwort-Sicherung) additiv auf Stand 0012', () => {
  it('PGlite', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema });
    try {
      await pruefen(db as unknown as Db, (folder) => migrateLite(db, { migrationsFolder: folder }));
    } finally {
      await client.close();
    }
  }, 120_000);

  it.skipIf(!process.env.TEST_DATABASE_URL)('PostgreSQL', async () => {
    const name = `lx_mig_${randomUUID().replaceAll('-', '')}`;
    const admin = new pg.Client({ connectionString: process.env.TEST_DATABASE_URL });
    admin.on('error', () => undefined);
    await admin.connect();
    await admin.query(`create database ${name}`);
    const url = new URL(process.env.TEST_DATABASE_URL as string);
    url.pathname = `/${name}`;
    const pool = new pg.Pool({ connectionString: url.toString(), max: 4 });
    pool.on('error', () => undefined);
    const db = drizzlePg(pool, { schema });
    try {
      await pruefen(db as unknown as Db, (folder) => migratePg(db, { migrationsFolder: folder }));
    } finally {
      await pool.end();
      await admin.query(`drop database ${name} with (force)`);
      await admin.end();
    }
  }, 120_000);
});
