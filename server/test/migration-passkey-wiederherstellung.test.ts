// Migration 0026 (Passkey-Sicherung, Eltern-Wiederherstellung) ist rein additiv: Auf einer Datenbank im Stand 0023 mit Bestand (Familie, Personen, Schlüssel, Sicherheitsereignisse)
// bleibt jede Zeile unverändert, die neuen Tabellen sind leer, die alten Arten der Sicherheitsereignisse gelten weiter und die neuen kommen dazu.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomUUID } from 'node:crypto';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { describe, expect, it } from 'vitest';
import { migrationsFolder } from './helpers.js';

interface Entry {
  idx: number;
  tag: string;
  when: number;
}

describe('Migration 0026 additiv auf Stand 0023', () => {
  it('PGlite: Bestand unverändert, neue Tabellen leer, Prüfungen der Datenbank greifen', async () => {
    const journal = JSON.parse(readFileSync(`${migrationsFolder}/meta/_journal.json`, 'utf8')) as { entries: Entry[] };
    const bis = journal.entries.findIndex((e) => e.tag.startsWith('0023')) + 1;
    const dir = mkdtempSync(`${tmpdir()}/lx-mig26-`);
    mkdirSync(`${dir}/meta`);
    const kept = journal.entries.slice(0, bis);
    for (const e of kept) cpSync(`${migrationsFolder}/${e.tag}.sql`, `${dir}/${e.tag}.sql`);
    writeFileSync(`${dir}/meta/_journal.json`, JSON.stringify({ ...journal, entries: kept }));
    const client = new PGlite();
    const db = drizzleLite(client);
    try {
      await migrateLite(db, { migrationsFolder: dir });
      const fid = randomUUID();
      const kind = randomUUID();
      const mama = randomUUID();
      await db.execute(sql`insert into families (id, name) values (${fid}, 'Altfamilie')`);
      await db.execute(sql`insert into users (id, email, display_name) values (${kind}, 'kind@example.org', 'Kind'), (${mama}, 'mama@example.org', 'Mama')`);
      await db.execute(sql`insert into memberships (family_id, user_id, role) values (${fid}, ${kind}, 'child'), (${fid}, ${mama}, 'parent')`);
      await db.execute(sql`insert into person_keys (user_id, public_enc_key, public_sign_key, key_version) values (${kind}, 'a', 'b', 1)`);
      await db.execute(sql`insert into security_events (family_id, user_id, kind, via) values (${fid}, ${kind}, 'key_rotated', 'password')`);
      const tabellen = (await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public' order by 1`)).rows.map((r) => r.tablename);
      const summe = async (t: string) =>
        ((await db.execute<{ h: string }>(sql.raw(`select md5(coalesce(string_agg((to_jsonb(x))::text, '|' order by (to_jsonb(x))::text), '')) as h from "${t}" x`))).rows[0] as { h: string }).h;
      const vorher = new Map<string, string>();
      for (const t of tabellen) vorher.set(t, await summe(t));

      await migrateLite(db, { migrationsFolder });
      for (const t of tabellen) expect(await summe(t), t).toBe(vorher.get(t));
      for (const t of ['key_backups_prf', 'guardian_escrows', 'guardian_recoveries']) {
        expect((await db.execute<{ n: number }>(sql.raw(`select count(*)::int as n from "${t}"`))).rows[0]?.n, t).toBe(0);
      }
      // alte und neue Arten der Sicherheitsereignisse
      await db.execute(sql`insert into security_events (family_id, user_id, kind, via) values (${fid}, ${kind}, 'key_backup_pw_read', 'password')`);
      for (const k of ['key_backup_prf_read', 'guardian_escrow_set', 'guardian_escrow_removed', 'guardian_recovery_requested', 'guardian_recovery_asked', 'guardian_recovery_challenged', 'guardian_recovery_released', 'guardian_recovery_ended']) {
        await db.execute(sql`insert into security_events (family_id, user_id, kind, via) values (${fid}, ${kind}, ${k}, 'password')`);
      }
      await expect(db.execute(sql`insert into security_events (family_id, user_id, kind, via) values (${fid}, ${kind}, 'unbekannt', 'password')`)).rejects.toThrow();
      // Prüfungen der neuen Tabellen
      await expect(
        db.execute(sql`insert into guardian_escrows (family_id, child_id, guardian_id, key_version, guardian_key_version, blob, sig) values (${fid}, ${kind}, ${kind}, 1, 1, ${'x'.repeat(100)}, ${'y'.repeat(86)})`),
      ).rejects.toThrow();
      await db.execute(sql`insert into guardian_escrows (family_id, child_id, guardian_id, key_version, guardian_key_version, blob, sig) values (${fid}, ${kind}, ${mama}, 1, 1, ${'x'.repeat(100)}, ${'y'.repeat(86)})`);
      await expect(
        db.execute(sql`insert into guardian_escrows (family_id, child_id, guardian_id, key_version, guardian_key_version, blob, sig) values (${fid}, ${kind}, ${mama}, 1, 1, ${'x'.repeat(100)}, ${'y'.repeat(86)})`),
      ).rejects.toThrow(); // höchstens ein AKTUELLER Eintrag je Kind und Elternteil
      // frühere Einträge bleiben als superseded/revoked erhalten (nie löschen), daneben darf ein neuer aktueller stehen
      await db.execute(sql`update guardian_escrows set state = 'superseded' where child_id = ${kind} and guardian_id = ${mama}`);
      await db.execute(sql`insert into guardian_escrows (family_id, child_id, guardian_id, key_version, guardian_key_version, blob, sig) values (${fid}, ${kind}, ${mama}, 2, 1, ${'x'.repeat(100)}, ${'y'.repeat(86)})`);
      await expect(db.execute(sql`update guardian_escrows set state = 'unbekannt' where child_id = ${kind}`)).rejects.toThrow();
      await db.execute(sql`insert into security_events (family_id, user_id, kind, via) values (${fid}, ${kind}, 'key_backup_prf_set', 'password')`);
      // Mitglied weg: Hinterlegung verschwindet mit (Kaskade)
      await db.execute(sql`delete from memberships where user_id = ${mama}`);
      expect((await db.execute<{ n: number }>(sql`select count(*)::int as n from guardian_escrows`)).rows[0]?.n).toBe(0);
    } finally {
      await client.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 120_000);
});
