// Schema-Test: Die Migrationen laufen durch, Tabellen, Spalten und Regeln stimmen.
// Läuft immer gegen PGlite (PostgreSQL als WASM, keine lokale Datenbank nötig) und zusätzlich gegen ein echtes
// PostgreSQL, wenn TEST_DATABASE_URL gesetzt ist (CI: PostgreSQL 17; lokal z. B. postgres://postgres@127.0.0.1:54329/postgres).
// Für die echte Datenbank wird je Lauf eine frische Datenbank angelegt und danach gelöscht.
import { PGlite } from '@electric-sql/pglite';
import { eq, sql } from 'drizzle-orm';
import { drizzle as drizzlePg, type NodePgDatabase } from 'drizzle-orm/node-postgres';
import { migrate as migratePg } from 'drizzle-orm/node-postgres/migrator';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as schema from '../src/db/schema.js';

const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url));

type TestDb = NodePgDatabase<typeof schema>;

interface Backend {
  db: TestDb;
  close: () => Promise<void>;
}

/** Genau eine Zeile erwartet (noUncheckedIndexedAccess). */
function one<T>(list: T[]): T {
  const [first] = list;
  if (first === undefined) throw new Error('Zeile erwartet');
  return first;
}

async function openPglite(): Promise<Backend> {
  const client = new PGlite();
  const db = drizzleLite(client, { schema });
  await migrateLite(db, { migrationsFolder });
  return { db: db as unknown as TestDb, close: () => client.close() };
}

/** PG-Fehlercode "terminating connection due to administrator command" (admin_shutdown). */
const ADMIN_SHUTDOWN = '57P01';

async function openPostgres(adminUrl: string): Promise<Backend> {
  const name = `lx_test_${randomUUID().replaceAll('-', '')}`;
  // Fehler von Verbindungen duerfen nie unbehandelt bleiben (sonst "Uncaught Exception" im Vitest-Lauf).
  // Beim Aufraeumen ist 57P01 erwartet: pool.end() wartet nicht, bis der Server die Backends beendet hat,
  // und DROP DATABASE ... WITH (FORCE) beendet sie dann selbst. Alle anderen Fehler werden gesammelt
  // und beim Schliessen als Testfehler gemeldet.
  let closing = false;
  const unexpected: Error[] = [];
  const onError = (err: Error & { code?: string }) => {
    if (closing && err.code === ADMIN_SHUTDOWN) return;
    unexpected.push(err);
  };
  const admin = new pg.Client({ connectionString: adminUrl });
  admin.on('error', onError);
  await admin.connect();
  await admin.query(`create database ${name}`);
  const url = new URL(adminUrl);
  url.pathname = `/${name}`;
  const pool = new pg.Pool({ connectionString: url.toString(), max: 4 });
  pool.on('error', onError);
  const db = drizzlePg(pool, { schema });
  await migratePg(db, { migrationsFolder });
  return {
    db: db as unknown as TestDb,
    close: async () => {
      closing = true;
      try {
        await pool.end();
        await admin.query(`drop database ${name} with (force)`);
      } finally {
        await admin.end();
      }
      if (unexpected.length > 0) {
        throw new AggregateError(unexpected, 'Unerwartete Verbindungsfehler in der Test-Datenbank');
      }
    },
  };
}

const TABLES = [
  'families',
  'users',
  'memberships',
  'webauthn_challenges',
  'login_attempts',
  'ws_tickets',
  'credentials',
  'recovery_codes',
  'audit_log',
  'invites',
  'sessions',
  'devices',
  'applied_ops',
  'change_log',
  'termine',
  'termin_teilnehmer',
  'termin_ausnahmen',
  'lists',
  'list_items',
  'tasks',
  'messages',
  'message_reactions',
  'message_reads',
  'files',
];

const backends: [string, () => Promise<Backend>][] = [['PGlite', openPglite]];
const realUrl = process.env.TEST_DATABASE_URL;
if (realUrl) backends.push(['PostgreSQL (echt)', () => openPostgres(realUrl)]);

describe.each(backends)('Schema-Migration (%s)', (_name, open) => {
  let backend: Backend;
  let db: TestDb;

  beforeAll(async () => {
    backend = await open();
    db = backend.db;
  });
  afterAll(async () => {
    await backend?.close();
  });

  async function rows<T>(query: ReturnType<typeof sql>): Promise<T[]> {
    return (await db.execute(query)).rows as T[];
  }

  /** Legt Familie, Person und Gerät an. */
  async function seed() {
    const family = one(await db.insert(schema.families).values({ name: `F ${randomUUID()}` }).returning());
    const user = one(await db
      .insert(schema.users)
      .values({ email: `${randomUUID()}@example.org`, displayName: 'Anna' })
      .returning());
    await db.insert(schema.memberships).values({ familyId: family.id, userId: user.id, role: 'parent' });
    const device = one(await db
      .insert(schema.devices)
      .values({ familyId: family.id, userId: user.id, name: 'Handy', platform: 'android' })
      .returning());
    return { familyId: family.id as string, userId: user.id as string, deviceId: device.id as string };
  }

  async function seedMessage(familyId: string) {
    const m = one(await db.insert(schema.messages).values({ familyId, body: 'Hallo', rev: 1 }).returning());
    return m.id as string;
  }

  it('legt alle Tabellen an', async () => {
    const found = await rows<{ table_name: string }>(
      sql`select table_name from information_schema.tables where table_schema = 'public'`,
    );
    const names = found.map((r) => r.table_name);
    for (const t of TABLES) expect(names).toContain(t);
  });

  it('versieht fachliche Tabellen mit family_id', async () => {
    const withFamily = TABLES.filter((t) => !['families', 'users', 'credentials', 'recovery_codes', 'login_attempts', 'webauthn_challenges'].includes(t));
    const cols = await rows<{ table_name: string }>(
      sql`select table_name from information_schema.columns where table_schema = 'public' and column_name = 'family_id'`,
    );
    const names = cols.map((r) => r.table_name);
    for (const t of withFamily) expect(names, `family_id in ${t}`).toContain(t);
  });

  it('versieht änderbare Tabellen mit Sync-Spalten', async () => {
    const syncTables = ['termine', 'termin_teilnehmer', 'termin_ausnahmen', 'lists', 'list_items', 'tasks', 'files', 'messages', 'message_reactions', 'message_reads'];
    for (const t of syncTables) {
      const cols = (
        await rows<{ column_name: string }>(
          sql`select column_name from information_schema.columns where table_schema = 'public' and table_name = ${t}`,
        )
      ).map((r) => r.column_name);
      for (const c of ['rev', 'field_revs', 'updated_at', 'deleted_at']) expect(cols, `${c} in ${t}`).toContain(c);
    }
  });

  it('speichert Reaktionen und Lesebestätigungen nicht mehr als JSON in messages', async () => {
    const cols = (
      await rows<{ column_name: string }>(
        sql`select column_name from information_schema.columns where table_schema = 'public' and table_name = 'messages'`,
      )
    ).map((r) => r.column_name);
    expect(cols).not.toContain('reactions');
    expect(cols).not.toContain('read_by');
    const eventCols = (
      await rows<{ column_name: string }>(
        sql`select column_name from information_schema.columns where table_schema = 'public' and table_name = 'termine'`,
      )
    ).map((r) => r.column_name);
    expect(eventCols).not.toContain('teilnehmer_ids');
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

  it('legt die verlangten Indizes an', async () => {
    const idx = (await rows<{ indexname: string }>(sql`select indexname from pg_indexes where schemaname = 'public'`)).map(
      (r) => r.indexname,
    );
    expect(idx).toContain('memberships_user_idx');
    expect(idx).toContain('devices_family_idx');
  });

  it('erzwingt eindeutige Revisionen je Familie', async () => {
    const { familyId } = await seed();
    const entry = { familyId, rev: 1, entity: 'termin', entityId: randomUUID(), tombstone: true };
    await db.insert(schema.changeLog).values(entry);
    await expect(db.insert(schema.changeLog).values(entry)).rejects.toThrow();
  });

  it('erzwingt eindeutige E-Mail-Adressen unabhängig von der Schreibweise', async () => {
    const mail = `Anna-${randomUUID()}@Example.org`;
    await db.insert(schema.users).values({ email: mail, displayName: 'Anna' });
    await expect(db.insert(schema.users).values({ email: mail.toLowerCase(), displayName: 'Anna 2' })).rejects.toThrow();
  });

  it('löscht abhängige Daten beim Löschen der Familie (cascade)', async () => {
    const { familyId } = await seed();
    await db.insert(schema.lists).values({ familyId, name: 'Einkauf', kind: 'shopping', rev: 1 });
    await db.delete(schema.families).where(sql`id = ${familyId}`);
    expect(await rows(sql`select 1 from lists where family_id = ${familyId}`)).toHaveLength(0);
    expect(await rows(sql`select 1 from devices where family_id = ${familyId}`)).toHaveLength(0);
  });

  describe('Reaktionen und Lesebestätigungen', () => {
    it('speichert je Person und Emoji genau eine aktive Reaktion', async () => {
      const { familyId, userId } = await seed();
      const messageId = await seedMessage(familyId);
      const reaction = { familyId, messageId, userId, emoji: '👍', rev: 2 };
      await db.insert(schema.messageReactions).values(reaction);
      await expect(db.insert(schema.messageReactions).values(reaction)).rejects.toThrow();
      // anderes Emoji derselben Person ist erlaubt
      await db.insert(schema.messageReactions).values({ ...reaction, emoji: '❤️' });
    });

    it('erlaubt dieselbe Reaktion erneut, nachdem sie als Tombstone entfernt wurde', async () => {
      const { familyId, userId } = await seed();
      const messageId = await seedMessage(familyId);
      const reaction = { familyId, messageId, userId, emoji: '😀', rev: 2 };
      await db.insert(schema.messageReactions).values(reaction);
      await db.update(schema.messageReactions).set({ deletedAt: new Date(), rev: 3 }).where(sql`message_id = ${messageId}`);
      await db.insert(schema.messageReactions).values({ ...reaction, rev: 4 });
    });

    it('lehnt leere und überlange Emoji ab', async () => {
      const { familyId, userId } = await seed();
      const messageId = await seedMessage(familyId);
      const base = { familyId, messageId, userId, rev: 2 };
      await expect(db.insert(schema.messageReactions).values({ ...base, emoji: '' })).rejects.toThrow();
      await expect(db.insert(schema.messageReactions).values({ ...base, emoji: 'x'.repeat(33) })).rejects.toThrow();
    });

    it('speichert je Person und Nachricht genau eine Lesebestätigung', async () => {
      const { familyId, userId } = await seed();
      const messageId = await seedMessage(familyId);
      const read = { familyId, messageId, userId, rev: 2 };
      await db.insert(schema.messageReads).values(read);
      await expect(db.insert(schema.messageReads).values(read)).rejects.toThrow();
    });

    it('löscht Reaktionen und Lesebestätigungen mit der Nachricht', async () => {
      const { familyId, userId } = await seed();
      const messageId = await seedMessage(familyId);
      await db.insert(schema.messageReactions).values({ familyId, messageId, userId, emoji: '👍', rev: 2 });
      await db.insert(schema.messageReads).values({ familyId, messageId, userId, rev: 2 });
      await db.delete(schema.messages).where(sql`id = ${messageId}`);
      expect(await rows(sql`select 1 from message_reactions where message_id = ${messageId}`)).toHaveLength(0);
      expect(await rows(sql`select 1 from message_reads where message_id = ${messageId}`)).toHaveLength(0);
    });
  });

  describe('zusammengesetzte Fremdschlüssel (family_id, id)', () => {
    it('verhindert Reaktionen mit family_id einer anderen Familie', async () => {
      const a = await seed();
      const b = await seed();
      const messageId = await seedMessage(a.familyId);
      await expect(
        db.insert(schema.messageReactions).values({ familyId: b.familyId, messageId, userId: b.userId, emoji: '👍', rev: 1 }),
      ).rejects.toThrow();
    });

    it('verhindert Listeneinträge in der Liste einer fremden Familie', async () => {
      const a = await seed();
      const b = await seed();
      const list = one(await db.insert(schema.lists).values({ familyId: a.familyId, name: 'Einkauf', rev: 1 }).returning());
      await expect(
        db.insert(schema.listItems).values({ familyId: b.familyId, listId: list.id, text: 'Milch', rev: 1 }),
      ).rejects.toThrow();
      await db.insert(schema.listItems).values({ familyId: a.familyId, listId: list.id, text: 'Milch', rev: 1 });
    });

    it('Sync (Migration 0002): Standardwerte, Freigabe-Stufe, Kommazahlen und Längengrenzen', async () => {
      const a = await seed();
      const family = one(await db.select().from(schema.families).where(eq(schema.families.id, a.familyId)));
      expect(family.purgedRev).toBe(0);
      const list = one(await db.insert(schema.lists).values({ familyId: a.familyId, name: 'Einkauf', rev: 1 }).returning());
      expect(list.audience).toBe('family');
      expect(list.ownerId).toBeNull();
      await expect(db.insert(schema.lists).values({ familyId: a.familyId, name: 'x', rev: 1, audience: 'alle' as never })).rejects.toThrow();
      await expect(db.insert(schema.lists).values({ familyId: a.familyId, name: 'x'.repeat(101), rev: 1 })).rejects.toThrow();
      const item = one(await db.insert(schema.listItems).values({ familyId: a.familyId, listId: list.id, text: 'Milch', position: 1.5, rev: 1 }).returning());
      expect(item.position).toBe(1.5);
      await expect(db.insert(schema.listItems).values({ familyId: a.familyId, listId: list.id, text: 'x'.repeat(501), rev: 1 })).rejects.toThrow();
      await expect(db.insert(schema.listItems).values({ familyId: a.familyId, listId: list.id, text: 'x', position: 1e13, rev: 1 })).rejects.toThrow();
      const log = one(await db.insert(schema.changeLog).values({ familyId: a.familyId, rev: 1, entity: 'list', entityId: list.id }).returning());
      expect(log.created).toBe(false);
      const op = one(await db.insert(schema.appliedOps).values({ familyId: a.familyId, opId: randomUUID() }).returning());
      expect(op).toMatchObject({ status: 'acked', code: null, conflicts: [] });
      await expect(db.insert(schema.appliedOps).values({ familyId: a.familyId, opId: randomUUID(), status: 'vielleicht' })).rejects.toThrow();
    });

    it('verhindert Sitzungen mit Gerät einer fremden Familie', async () => {
      const a = await seed();
      const b = await seed();
      await expect(
        db.insert(schema.sessions).values({
          familyId: b.familyId,
          userId: b.userId,
          deviceId: a.deviceId,
          tokenHash: randomUUID(),
          expiresAt: new Date(Date.now() + 1000),
        }),
      ).rejects.toThrow();
    });

    it('verhindert Ordner-Zuordnung über Familiengrenzen', async () => {
      const a = await seed();
      const b = await seed();
      const folder = one(await db
        .insert(schema.files)
        .values({ familyId: a.familyId, kind: 'folder', name: 'Fotos', rev: 1 })
        .returning());
      await expect(
        db.insert(schema.files).values({ familyId: b.familyId, parentId: folder.id, name: 'x.jpg', rev: 1 }),
      ).rejects.toThrow();
    });
  });

  describe('Termine', () => {
    const base = { titel: 'Termin', rev: 1 };
    const zeit = { ganztaegig: false, startUtc: new Date('2026-10-18T08:00:00Z'), endUtc: new Date('2026-10-18T09:00:00Z'), tzid: 'Europe/Berlin' };

    it('speichert ganztägige Termine als Datum ohne Uhrzeit und Zeitzone (Ende exklusiv)', async () => {
      const { familyId } = await seed();
      const e = one(await db
        .insert(schema.termine)
        .values({ ...base, familyId, ganztaegig: true, startDate: '2026-12-24', endDate: '2026-12-27' })
        .returning());
      expect(e.startDate).toBe('2026-12-24');
      expect(e.startUtc).toBeNull();
      const t = await rows<{ data_type: string }>(
        sql`select data_type from information_schema.columns where table_name = 'termine' and column_name = 'start_date'`,
      );
      expect(t[0]?.data_type).toBe('date');
    });

    it('speichert zeitgebundene Termine mit Zeitpunkten und Zeitzone', async () => {
      const { familyId } = await seed();
      const e = one(await db.insert(schema.termine).values({ ...base, familyId, ...zeit }).returning());
      expect(e.tzid).toBe('Europe/Berlin');
    });

    it('lehnt widersprüchliche Termine ab', async () => {
      const { familyId } = await seed();
      // ganztägig ohne Datum
      await expect(db.insert(schema.termine).values({ ...base, familyId, ganztaegig: true })).rejects.toThrow();
      // ganztägig mit Ende am selben Tag (Ende ist exklusiv)
      await expect(
        db.insert(schema.termine).values({ ...base, familyId, ganztaegig: true, startDate: '2026-12-24', endDate: '2026-12-24' }),
      ).rejects.toThrow();
      // zeitgebunden ohne Zeitpunkt oder ohne Zeitzone
      await expect(db.insert(schema.termine).values({ ...base, familyId })).rejects.toThrow();
      await expect(db.insert(schema.termine).values({ ...base, familyId, ...zeit, tzid: null })).rejects.toThrow();
      // Ende vor Beginn
      await expect(db.insert(schema.termine).values({ ...base, familyId, ...zeit, endUtc: new Date('2026-10-18T07:00:00Z') })).rejects.toThrow();
    });

    it('speichert Teilnehmer je Person und entfernt sie mit dem Termin', async () => {
      const { familyId, userId } = await seed();
      const e = one(await db.insert(schema.termine).values({ ...base, familyId, ...zeit }).returning());
      const row = { familyId, terminId: e.id, userId, rev: 2 };
      await db.insert(schema.terminTeilnehmer).values(row);
      await expect(db.insert(schema.terminTeilnehmer).values(row)).rejects.toThrow();
      await db.delete(schema.termine).where(sql`id = ${e.id}`);
      expect(await rows(sql`select 1 from termin_teilnehmer where termin_id = ${e.id}`)).toHaveLength(0);
    });

    it('speichert je Vorkommen einer Serie höchstens eine Ausnahme', async () => {
      const { familyId } = await seed();
      const e = one(await db.insert(schema.termine).values({ ...base, familyId, ...zeit, rrule: 'FREQ=WEEKLY' }).returning());
      const row = { familyId, terminId: e.id, originalStart: '2026-10-25T08:00:00Z', abgesagt: true, rev: 2 };
      await db.insert(schema.terminAusnahmen).values(row);
      await expect(db.insert(schema.terminAusnahmen).values(row)).rejects.toThrow();
      await db.insert(schema.terminAusnahmen).values({ ...row, originalStart: '2026-11-01T08:00:00Z' });
      await db.delete(schema.termine).where(sql`id = ${e.id}`);
      expect(await rows(sql`select 1 from termin_ausnahmen where termin_id = ${e.id}`)).toHaveLength(0);
    });
  });

  describe('Sitzungen und Wiederherstellungs-Codes', () => {
    it('merkt sich Einlösung und Nachfolge-Sitzung eines Refresh-Tokens', async () => {
      const { familyId, userId, deviceId } = await seed();
      const expiresAt = new Date(Date.now() + 3600_000);
      const tokenFamily = randomUUID();
      const first = one(await db
        .insert(schema.sessions)
        .values({ familyId, userId, deviceId, tokenHash: randomUUID(), tokenFamily, expiresAt })
        .returning());
      const second = one(await db
        .insert(schema.sessions)
        .values({ familyId, userId, deviceId, tokenHash: randomUUID(), tokenFamily, expiresAt })
        .returning());
      await db.update(schema.sessions).set({ usedAt: new Date(), rotatedTo: second.id }).where(sql`id = ${first.id}`);
      const reloaded = (
        await rows<{ used_at: Date | null; rotated_to: string }>(sql`select used_at, rotated_to from sessions where id = ${first.id}`)
      )[0];
      expect(reloaded?.used_at).not.toBeNull();
      expect(reloaded?.rotated_to).toBe(second.id);
      // Nachfolge-Sitzung weg: Verweis wird leer, die ursprüngliche Sitzung bleibt
      await db.delete(schema.sessions).where(sql`id = ${second.id}`);
      const after = (await rows<{ rotated_to: string | null }>(sql`select rotated_to from sessions where id = ${first.id}`))[0];
      expect(after?.rotated_to).toBeNull();
    });

    it('speichert Wiederherstellungs-Codes nur als eindeutigen Hash mit Einlösezeitpunkt', async () => {
      const { userId } = await seed();
      const codeHash = randomUUID().replaceAll('-', '');
      const code = one(await db.insert(schema.recoveryCodes).values({ userId, codeHash }).returning());
      expect(code.usedAt).toBeNull();
      await expect(db.insert(schema.recoveryCodes).values({ userId, codeHash })).rejects.toThrow();
      await db.update(schema.recoveryCodes).set({ usedAt: new Date() }).where(sql`id = ${code.id}`);
    });

    it('führt ein Audit-Log, das die Familie überdauert', async () => {
      const { familyId, userId } = await seed();
      const entry = one(await db
        .insert(schema.auditLog)
        .values({ familyId, actorId: userId, event: 'login_ok', ip: '203.0.113.7' })
        .returning());
      await db.delete(schema.families).where(sql`id = ${familyId}`);
      const left = (await rows<{ family_id: string | null }>(sql`select family_id from audit_log where id = ${entry.id}`))[0];
      expect(left).toBeDefined();
      expect(left?.family_id).toBeNull();
    });
  });

  describe('Geräte und idempotente Ops', () => {
    it('führt die zuletzt bestätigte Revision je Gerät (Standard 0)', async () => {
      const { deviceId } = await seed();
      const d = (await rows<{ last_rev: string | number }>(sql`select last_rev from devices where id = ${deviceId}`))[0];
      expect(Number(d?.last_rev)).toBe(0);
      await db.update(schema.devices).set({ lastRev: 42 }).where(sql`id = ${deviceId}`);
      const d2 = (await rows<{ last_rev: string | number }>(sql`select last_rev from devices where id = ${deviceId}`))[0];
      expect(Number(d2?.last_rev)).toBe(42);
    });

    it('übernimmt eine Op mit derselben op_id nur einmal', async () => {
      const { familyId, deviceId } = await seed();
      const opId = randomUUID();
      const first = await db
        .insert(schema.appliedOps)
        .values({ familyId, opId, deviceId, rev: 5 })
        .onConflictDoNothing()
        .returning();
      expect(first).toHaveLength(1);
      // wiederholter Upload: kein neuer Eintrag, der Server beantwortet mit der gemerkten Revision
      const again = await db
        .insert(schema.appliedOps)
        .values({ familyId, opId, deviceId, rev: 6 })
        .onConflictDoNothing()
        .returning();
      expect(again).toHaveLength(0);
      const kept = (await rows<{ rev: string | number }>(sql`select rev from applied_ops where op_id = ${opId}`))[0];
      expect(Number(kept?.rev)).toBe(5);
    });

    it('trennt op_ids zwischen Familien', async () => {
      const a = await seed();
      const b = await seed();
      const opId = randomUUID();
      await db.insert(schema.appliedOps).values({ familyId: a.familyId, opId, rev: 1 });
      await db.insert(schema.appliedOps).values({ familyId: b.familyId, opId, rev: 1 });
    });
  });
});

describe('Eingecheckte Migrationen', () => {
  it('0000_init.sql ist unverändert (bereits deployt, nur neue Migrationen anhängen)', async () => {
    const { createHash } = await import('node:crypto');
    const { readFileSync } = await import('node:fs');
    const text = readFileSync(new URL('../drizzle/0000_init.sql', import.meta.url), 'utf8').replaceAll('\r\n', '\n');
    expect(createHash('sha256').update(text).digest('hex')).toBe('913701818d34e72121485178a8ed78caf765d14b76ae71a90eb5c460252ee361');
  });
});
