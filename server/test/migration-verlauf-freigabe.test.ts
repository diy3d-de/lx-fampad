// Migration 0024 (Wrap-ID v2 für "Verlauf freigeben": `epoche_wraps.key_version`, Eindeutigkeit je Schlüsselversion) ist rein additiv: Auf einer Datenbank im Stand 0023
// (hier: Bestand mit Chat, Epochen und Wraps anlegen, die Objekte von 0024 wieder entfernen) bleibt jede Zeile unverändert, bestehende Wraps haben keine Version
// (null) und gelten weiter, und die Eindeutigkeit gilt danach je (Konversation, Epoche, Empfänger, Schlüsselversion). Die Migration ist wiederholbar.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { Db } from '../src/auth/context.js';
import * as schema from '../src/db/schema.js';
import { epocheId, wrapId, wrapIdV2 } from '../src/sync/entities/chat-ids.js';
import { migrationsFolder, World } from './helpers.js';
import { createFamily, upsert } from './sync-kit.js';

const BLOB = (n = 120) => 'B'.repeat(n);

describe('Migration 0024 (Wrap-ID v2) additiv auf Stand 0023', () => {
  it('PGlite: Wraps unverändert und ohne Version, Eindeutigkeit je Version, wiederholbar, danach nehmen v1 und v2 Wraps an', async () => {
    const client = new PGlite();
    const db = drizzleLite(client, { schema }) as unknown as Db;
    let world: World | undefined;
    try {
      await migrateLite(db as never, { migrationsFolder });
      world = await World.create(db, { SYNC_RATE_LIMIT_MAX: '100000', E2EE_WRAP_KEY_VERSION: 'true' });
      const fam = await createFamily(world);
      // Bestand wie bei v0.7.0: Gruppe mit zwei Epochen und je einem Wrap (ID v1) für Elternteil und Kind
      const konv = randomUUID();
      const sync = async (d: typeof fam.parent, ops: ReturnType<typeof upsert>[]) => {
        const r = await d.sync(ops);
        expect(r.json.rejected, JSON.stringify(r.json.rejected)).toEqual([]);
      };
      await sync(fam.parent, [upsert('konversation', konv, { art: 'group', teilnehmer: [fam.parent.userId, fam.child.userId] })]);
      for (const n of [1, 2]) {
        await sync(fam.parent, [
          upsert('epoche', epocheId(konv, n), { konversationId: konv, epoche: n, mitglieder: BLOB(200 + n) }),
          upsert('epoche_wrap', wrapId(konv, n, fam.parent.userId), { konversationId: konv, epoche: n, empfaengerId: fam.parent.userId, wrap: BLOB(100 + n) }),
          upsert('epoche_wrap', wrapId(konv, n, fam.child.userId), { konversationId: konv, epoche: n, empfaengerId: fam.child.userId, wrap: BLOB(110 + n) }),
        ]);
      }
      const tabellen = ((await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' order by 1`)).rows).map((r) => r.tablename);
      const ohne: Record<string, string> = { epoche_wraps: " - 'key_version'", credentials: " - 'device_type' - 'backed_up'" };
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x)${ohne[t] ?? ''})::text, '|' order by (to_jsonb(x)${ohne[t] ?? ''})::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));
      await world.close();
      world = undefined;

      // die Objekte von 0025 (Betrieb Paket 3) liegen über 0024 und werden beim erneuten Migrieren wieder angelegt
      // Migration 0026 (Passkey-Sicherung, Eltern-Wiederherstellung; neuer als 0025, also zuerst zurück)
      await db.execute(sql`drop table guardian_escrows, guardian_recoveries, key_backups_prf`);
      await db.execute(sql`alter table credentials drop column device_type, drop column backed_up`);
      await db.execute(sql`drop table operator_metrics`);
      await db.execute(sql`alter table weather_credentials drop column error_count`);
      // zurück in den Stand 0023: die Objekte von 0024 weg (alter Index ohne Version), ihr Eintrag im Migrationsprotokoll weg (die Daten bleiben)
      await db.execute(sql`drop index epoche_wraps_uq`);
      await db.execute(sql`alter table epoche_wraps drop constraint epoche_wraps_key_version_ck`);
      await db.execute(sql`alter table epoche_wraps drop column key_version`);
      await db.execute(sql`create unique index epoche_wraps_uq on epoche_wraps (family_id, konversation_id, epoche, empfaenger_id) where deleted_at is null`);
      const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: { tag: string; when: number }[] };
      const meine = journal.entries.find((e) => e.tag.startsWith('0024_'));
      if (!meine) throw new Error('Journal ohne 0024');
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);

      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      expect((await db.execute(sql`select count(*)::int as n, count(key_version)::int as v from epoche_wraps`)).rows[0]).toMatchObject({ n: 4, v: 0 });

      // zweite Anwendung (Tests stellen frühere Stände nach und wenden alles erneut an): kein Fehler, nichts verändert
      // (die Objekte von 0025 sind nicht wiederholbar angelegt und gehen deshalb vorher wieder weg)
      // Migration 0026 (Passkey-Sicherung, Eltern-Wiederherstellung; neuer als 0025, also zuerst zurück)
      await db.execute(sql`drop table guardian_escrows, guardian_recoveries, key_backups_prf`);
      await db.execute(sql`alter table credentials drop column device_type, drop column backed_up`);
      await db.execute(sql`drop table operator_metrics`);
      await db.execute(sql`alter table weather_credentials drop column error_count`);
      await db.execute(sql`delete from drizzle.__drizzle_migrations where created_at >= ${meine.when}`);
      await migrateLite(db as never, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));

      // Eindeutigkeit: ohne Version genau einer je (Konversation, Epoche, Empfänger); mit Version mehrere (je Verteiler eine); Version 0 oder negativ gibt es nicht
      const einfuegen = (version: number | null, empfaenger: string) =>
        db.execute(sql`insert into epoche_wraps (id, family_id, konversation_id, epoche, empfaenger_id, wrap, key_version, rev, field_revs, created_at)
          values (${randomUUID()}::uuid, ${fam.familyId}::uuid, ${konv}::uuid, 1, ${empfaenger}::uuid, ${BLOB(90)}, ${version}, 1, '{}'::jsonb, now())`);
      await expect(einfuegen(null, fam.child.userId)).rejects.toThrow();
      await expect(einfuegen(0, fam.child.userId)).rejects.toThrow();
      await expect(einfuegen(-3, fam.child.userId)).rejects.toThrow();
      await einfuegen(2, fam.child.userId);
      await einfuegen(2, fam.child.userId); // ein zweiter Verteiler derselben Version (die ID enthält den Verteiler)
      await einfuegen(3, fam.child.userId);

      // der Server startet auf dem migrierten Bestand und meldet die Fähigkeit
      world = await World.create(db, { SYNC_RATE_LIMIT_MAX: '100000', E2EE_WRAP_KEY_VERSION: 'true' });
      expect((await world.client().get('/api/v1/version')).json.features).toMatchObject({ wrapKeyVersion: true });
    } finally {
      await world?.close().catch(() => undefined);
      await client.close();
    }
  }, 180_000);

  it('die abgeleiteten IDs sind je Version verschieden (Schutz vor Verwechslung in der Datenbank)', () => {
    const konv = randomUUID();
    const person = randomUUID();
    const ids = new Set([wrapId(konv, 1, person), wrapIdV2(konv, 1, person, 1, person), wrapIdV2(konv, 1, person, 2, person), wrapIdV2(konv, 2, person, 1, person), wrapIdV2(konv, 1, person, 1, konv)]);
    expect(ids.size).toBe(5);
  });
});
