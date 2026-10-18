// Schema-Test gegen PGlite (PostgreSQL 17 als WASM): Migrationen laufen durch, Tabellen und Spalten stimmen.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/pglite';
import { migrate } from 'drizzle-orm/pglite/migrator';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';

const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url));
const client = new PGlite();
const db = drizzle(client, { schema });

beforeAll(async () => {
  await migrate(db, { migrationsFolder });
});
afterAll(async () => {
  await client.close();
});

async function rows<T>(query: ReturnType<typeof sql>): Promise<T[]> {
  return (await db.execute(query)).rows as T[];
}

const TABLES = [
  'families',
  'users',
  'memberships',
  'credentials',
  'invites',
  'sessions',
  'devices',
  'change_log',
  'events',
  'lists',
  'list_items',
  'tasks',
  'messages',
  'files',
];

describe('Schema-Migration', () => {
  it('legt alle Tabellen an', async () => {
    const found = await rows<{ table_name: string }>(
      sql`select table_name from information_schema.tables where table_schema = 'public'`,
    );
    const names = found.map((r) => r.table_name);
    for (const t of TABLES) expect(names).toContain(t);
  });

  it('versieht fachliche Tabellen mit family_id', async () => {
    const withFamily = TABLES.filter((t) => !['families', 'users', 'credentials'].includes(t));
    const cols = await rows<{ table_name: string }>(
      sql`select table_name from information_schema.columns where table_schema = 'public' and column_name = 'family_id'`,
    );
    const names = cols.map((r) => r.table_name);
    for (const t of withFamily) expect(names, `family_id in ${t}`).toContain(t);
  });

  it('kennt die Rollen admin, parent, child, guest', async () => {
    const roles = await rows<{ enumlabel: string }>(
      sql`select e.enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'member_role' order by e.enumsortorder`,
    );
    expect(roles.map((r) => r.enumlabel)).toEqual(['admin', 'parent', 'child', 'guest']);
  });

  it('kennt die Anmeldearten passkey, totp, password', async () => {
    const types = await rows<{ enumlabel: string }>(
      sql`select e.enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'credential_type' order by e.enumsortorder`,
    );
    expect(types.map((r) => r.enumlabel)).toEqual(['passkey', 'totp', 'password']);
  });

  it('speichert Datensätze und erzwingt eindeutige Revisionen je Familie', async () => {
    const [family] = await db.insert(schema.families).values({ name: 'Test' }).returning();
    expect(family).toBeDefined();
    const familyId = family!.id;
    const entry = { familyId, rev: 1, entity: 'events', entityId: crypto.randomUUID(), tombstone: true };
    await db.insert(schema.changeLog).values(entry);
    await expect(db.insert(schema.changeLog).values(entry)).rejects.toThrow();
  });

  it('erzwingt eindeutige E-Mail-Adressen unabhängig von der Schreibweise', async () => {
    await db.insert(schema.users).values({ email: 'Anna@Example.org', displayName: 'Anna' });
    await expect(db.insert(schema.users).values({ email: 'anna@example.org', displayName: 'Anna 2' })).rejects.toThrow();
  });

  it('löscht abhängige Daten beim Löschen der Familie (cascade)', async () => {
    const [family] = await db.insert(schema.families).values({ name: 'Weg' }).returning();
    await db.insert(schema.lists).values({ familyId: family!.id, name: 'Einkauf', kind: 'shopping', rev: 1 });
    await db.delete(schema.families).where(sql`id = ${family!.id}`);
    const left = await rows(sql`select 1 from lists where family_id = ${family!.id}`);
    expect(left).toHaveLength(0);
  });
});
