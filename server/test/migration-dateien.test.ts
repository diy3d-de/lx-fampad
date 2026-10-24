// Migration 0035 (Dateiablage: Tabellen ordner, dateien, datei_versionen, tresor_anhaenge, datei_blob, datei_upload; Altlast files/messages.file_id entfernt) ist idempotent:
// Zweimal ausgeführt ändert sie nichts und wirft nicht; die Prüfungen der Datenbank greifen (Modus/Schlüssel, Beanspruchung, Längen, Fremdschlüssel, Kaskade).
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

describe('Migration 0035 (Dateiablage) idempotent', () => {
  it('PGlite: erneutes Ausführen wirft nicht und ändert nichts, Prüfungen greifen, Altlast ist weg', async () => {
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

      const datei = readFileSync(`${migrationsFolder}/0035_dateien.sql`, 'utf8');
      const schritte = datei.split('--> statement-breakpoint').map((s) => s.trim()).filter(Boolean);
      expect(schritte.length).toBeGreaterThan(20);
      const tabellen = "'ordner','dateien','datei_versionen','tresor_anhaenge','datei_blob','datei_upload','messages'";
      const stand = async () =>
        JSON.stringify((await db.execute(sql.raw(`select table_name, column_name, data_type, is_nullable from information_schema.columns where table_schema = 'public' and table_name in (${tabellen}) order by 1, 2`))).rows) +
        JSON.stringify((await db.execute(sql.raw(`select conname from pg_constraint where conrelid in (select oid from pg_class where relname in (${tabellen})) order by 1`))).rows) +
        JSON.stringify((await db.execute(sql.raw(`select indexname from pg_indexes where tablename in (${tabellen}) order by 1`))).rows);
      const vorher = await stand();
      for (const s of schritte) await db.execute(sql.raw(s));
      expect(await stand()).toBe(vorher);

      // Altlast entfernt: Tabelle files, Spalte messages.file_id, Enum file_kind
      expect((await db.execute(sql`select count(*)::int as n from pg_tables where schemaname = 'public' and tablename = 'files'`)).rows[0]).toEqual({ n: 0 });
      expect((await db.execute(sql`select count(*)::int as n from information_schema.columns where table_name = 'messages' and column_name = 'file_id'`)).rows[0]).toEqual({ n: 0 });
      expect((await db.execute(sql`select count(*)::int as n from pg_type where typname = 'file_kind'`)).rows[0]).toEqual({ n: 0 });

      // Blob: Modus und Schlüssel passen zusammen, Beanspruchung vollständig oder gar nicht, Art/Zustand aus der Liste
      const blob = (extra: string) =>
        db.execute(sql.raw(`insert into datei_blob (id, family_id, modus, kind, size, disk_size, sha256${extra.split('|')[0]}) values ('${randomUUID()}', '${familyId}', ${extra.split('|')[1]})`));
      await blob(", dek_wrap, kid|'server', 'datei', 1, 33, 'x', '\\x00', 1");
      await blob("|'e2ee', 'opak', 1, 1, 'x'");
      await expect(blob("|'server', 'datei', 1, 33, 'x'")).rejects.toThrow(); // Server-Modus ohne Schlüssel
      await expect(blob(", dek_wrap, kid|'e2ee', 'opak', 1, 1, 'x', '\\x00', 1")).rejects.toThrow(); // e2ee mit Schlüssel
      await expect(blob("|'anders', 'opak', 1, 1, 'x'")).rejects.toThrow();
      await expect(blob("|'e2ee', 'bild', 1, 1, 'x'")).rejects.toThrow();
      await expect(blob("|'e2ee', 'opak', -1, 1, 'x'")).rejects.toThrow();
      await expect(blob(", state|'e2ee', 'opak', 1, 1, 'x', 'claimed'")).rejects.toThrow(); // beansprucht ohne Datensatz
      await expect(blob(", claim_entity, claim_id|'e2ee', 'opak', 1, 1, 'x', 'datei_version', '" + randomUUID() + "'")).rejects.toThrow(); // Datensatz ohne Zustand claimed
      await blob(", state, claim_entity, claim_id|'e2ee', 'opak', 1, 1, 'x', 'claimed', 'tresor_anhang', '" + randomUUID() + "'");

      // Upload: Versatz höchstens Länge, Zustand aus der Liste, Fremdschlüssel auf Familie und Person
      const up = (extra: string) =>
        db.execute(sql.raw(`insert into datei_upload (id, family_id, uploader_id, modus, kind, length, expires_at${extra.split('|')[0]}) values ('${randomUUID()}', '${familyId}', '${admin}', 'e2ee', 'opak', 10, now()${extra.split('|')[1] ? `, ${extra.split('|')[1]}` : ''})`));
      await up('|');
      await up(', "offset"|10');
      await expect(up(', "offset"|11')).rejects.toThrow();
      await expect(up(', status|\'kaputt\'')).rejects.toThrow();
      await expect(db.execute(sql`insert into datei_upload (id, family_id, uploader_id, modus, kind, length, expires_at) values (${randomUUID()}, ${randomUUID()}, ${admin}, 'e2ee', 'opak', 1, now())`)).rejects.toThrow();

      // Sync-Tabellen: Fassung gehört zu einer Datei derselben Familie (Kaskade), Nummer je Datei eindeutig, Namenslänge
      const d = randomUUID();
      await db.execute(sql`insert into dateien (id, family_id, name, rev) values (${d}, ${familyId}, 'a.pdf', 1)`);
      await expect(db.execute(sql`insert into dateien (family_id, name, rev) values (${familyId}, ${'x'.repeat(201)}, 1)`)).rejects.toThrow();
      await db.execute(sql`insert into datei_versionen (family_id, datei_id, nr, blob_id, rev) values (${familyId}, ${d}, 1, ${randomUUID()}, 1)`);
      await expect(db.execute(sql`insert into datei_versionen (family_id, datei_id, nr, blob_id, rev) values (${familyId}, ${d}, 1, ${randomUUID()}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into datei_versionen (family_id, datei_id, nr, blob_id, rev) values (${familyId}, ${d}, 0, ${randomUUID()}, 1)`)).rejects.toThrow();
      await expect(db.execute(sql`insert into datei_versionen (family_id, datei_id, nr, blob_id, rev) values (${familyId}, ${randomUUID()}, 2, ${randomUUID()}, 1)`)).rejects.toThrow();
      await db.execute(sql`delete from dateien where id = ${d}`);
      expect((await db.execute(sql`select count(*)::int as n from datei_versionen`)).rows[0]).toEqual({ n: 0 });

      // Ordner: Elternordner ohne Fremdschlüssel (ein bereinigter Tombstone darf nie am Kind hängen)
      const o = randomUUID();
      await db.execute(sql`insert into ordner (id, family_id, parent_id, name, rev) values (${o}, ${familyId}, ${randomUUID()}, 'x', 1)`);
      await db.execute(sql`delete from ordner where id = ${o}`);
    } finally {
      await world?.close();
      await client.close();
    }
  }, 120_000);
});
