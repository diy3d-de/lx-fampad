// Test-Hilfen: Datenbank-Backends (PGlite immer, echtes PostgreSQL bei TEST_DATABASE_URL) und eine "Welt" mit
// Fastify-App, steuerbarer Uhr und Browser-/App-Clients.
import { PGlite } from '@electric-sql/pglite';
import { sql } from 'drizzle-orm';
import { drizzle as drizzlePg } from 'drizzle-orm/node-postgres';
import { migrate as migratePg } from 'drizzle-orm/node-postgres/migrator';
import { drizzle as drizzleLite } from 'drizzle-orm/pglite';
import { migrate as migrateLite } from 'drizzle-orm/pglite/migrator';
import type { FastifyInstance } from 'fastify';
import { generate } from 'otplib';
import { createHash, randomUUID } from 'node:crypto';
import type { Writable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { buildApp } from '../src/app.js';
import type { Db } from '../src/auth/context.js';
import { bootstrapFamily } from '../src/auth/bootstrap.js';
import { Auth } from '../src/auth/service.js';
import type { Probes } from '../src/operator/probes.js';
import { loadConfig, type Config } from '../src/config.js';
import * as schema from '../src/db/schema.js';
import { TestAuthenticator } from './authenticator.js';

export const migrationsFolder = fileURLToPath(new URL('../drizzle', import.meta.url));
export const TEST_KEY = createHash('sha256').update('lx-fampad-test-key').digest('base64');
export const ORIGIN = 'https://familie.lx-labs.dev';

export interface Harness {
  db: Db;
  /** Leert alle Tabellen (schneller als eine neue Datenbank je Test). */
  reset(): Promise<void>;
  close(): Promise<void>;
}

export interface Backend {
  name: string;
  open(): Promise<Harness>;
}

async function truncateAll(db: Db): Promise<void> {
  const rows = await db.execute<{ tablename: string }>(sql`select tablename from pg_tables where schemaname = 'public'`);
  const names = rows.rows.map((r) => `"${r.tablename}"`);
  if (names.length > 0) await db.execute(sql.raw(`truncate table ${names.join(', ')} restart identity cascade`));
}

const pglite: Backend = {
  name: 'PGlite',
  async open() {
    const client = new PGlite();
    const db = drizzleLite(client, { schema });
    await migrateLite(db, { migrationsFolder });
    const typed = db as unknown as Db;
    return { db: typed, reset: () => truncateAll(typed), close: () => client.close() };
  },
};

function postgres(adminUrl: string): Backend {
  return {
    name: 'PostgreSQL',
    async open() {
      const name = `lx_auth_${randomUUID().replaceAll('-', '')}`;
      let closing = false;
      const unexpected: Error[] = [];
      const onError = (err: Error & { code?: string }) => {
        if (closing && err.code === '57P01') return;
        unexpected.push(err);
      };
      const admin = new pg.Client({ connectionString: adminUrl });
      admin.on('error', onError);
      await admin.connect();
      await admin.query(`create database ${name}`);
      const url = new URL(adminUrl);
      url.pathname = `/${name}`;
      const pool = new pg.Pool({ connectionString: url.toString(), max: 8 });
      pool.on('error', onError);
      const db = drizzlePg(pool, { schema });
      await migratePg(db, { migrationsFolder });
      const typed = db as unknown as Db;
      return {
        db: typed,
        reset: () => truncateAll(typed),
        close: async () => {
          closing = true;
          try {
            await pool.end();
            await admin.query(`drop database ${name} with (force)`);
          } finally {
            await admin.end();
          }
          if (unexpected.length > 0) throw new AggregateError(unexpected, 'Unerwartete Verbindungsfehler in der Test-Datenbank');
        },
      };
    },
  };
}

export const backends: Backend[] = [pglite, ...(process.env.TEST_DATABASE_URL ? [postgres(process.env.TEST_DATABASE_URL)] : [])];

export interface Res {
  status: number;
  json: Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
  headers: Record<string, string | string[] | number | undefined>;
}

export interface RequestOptions {
  body?: unknown;
  headers?: Record<string, string>;
  ip?: string;
}

/** Ein Client mit Cookie-Speicher (Browser) oder Bearer-Token (App). */
export class Client {
  cookie: string | undefined;
  csrf: string | undefined;
  bearer: string | undefined;
  /** Mit Origin-Header wie ein Browser. */
  origin: string | undefined = ORIGIN;

  constructor(
    private readonly world: World,
    readonly ip = '203.0.113.10',
  ) {}

  async request(method: string, url: string, options: RequestOptions & { noCsrf?: boolean; noOrigin?: boolean } = {}): Promise<Res> {
    const headers: Record<string, string> = { 'x-forwarded-for': options.ip ?? this.ip, 'user-agent': 'Mozilla/5.0 (Windows NT 10.0) Chrome/130 Safari/537.36', ...options.headers };
    if (this.origin && !options.noOrigin) headers.origin = this.origin;
    if (this.cookie) headers.cookie = this.cookie;
    if (this.csrf && !options.noCsrf) headers['x-csrf-token'] = this.csrf;
    if (this.bearer) headers.authorization = `Bearer ${this.bearer}`;
    const res = await this.world.app.inject({ method: method as 'GET', url, headers, ...(options.body !== undefined ? { payload: options.body as object } : {}) });
    const setCookie = res.headers['set-cookie'];
    if (typeof setCookie === 'string') {
      const pair = setCookie.split(';')[0] ?? '';
      this.cookie = /Max-Age=0/i.test(setCookie) ? undefined : pair;
    }
    let json: Record<string, unknown> = {};
    try {
      json = res.json();
    } catch {
      /* leere Antwort */
    }
    return { status: res.statusCode, json, headers: res.headers };
  }

  get = (url: string, o?: RequestOptions) => this.request('GET', url, o);
  post = (url: string, body?: unknown, o: RequestOptions = {}) => this.request('POST', url, { ...o, body: body ?? {} });
  put = (url: string, body?: unknown) => this.request('PUT', url, { body: body ?? {} });
  patch = (url: string, body?: unknown) => this.request('PATCH', url, { body: body ?? {} });
  del = (url: string) => this.request('DELETE', url);

  /** Übernimmt eine Sitzungsantwort (`session` aus der API). */
  adopt(session: Record<string, any>): void { // eslint-disable-line @typescript-eslint/no-explicit-any
    if (session.kind === 'web') this.csrf = session.csrfToken;
    else this.bearer = session.accessToken;
  }
}

export class World {
  clock = Date.parse('2026-10-19T08:00:00Z');
  readonly now = () => new Date(this.clock);

  private constructor(
    readonly app: FastifyInstance,
    readonly auth: Auth,
    readonly db: Db,
    readonly config: Config,
  ) {}

  static async create(db: Db, env: NodeJS.ProcessEnv = {}, extra: { logStream?: Writable; pushMinIntervalMs?: number; weatherFetch?: typeof fetch; operatorProbes?: Partial<Probes> } = {}): Promise<World> {
    const config = loadConfig({
      NODE_ENV: 'test',
      LOG_LEVEL: 'silent',
      AUTH_SECRET_KEY: TEST_KEY,
      PUBLIC_URL: ORIGIN,
      AUTH_RATE_LIMIT_MAX: '100000',
      RATE_LIMIT_MAX: '100000',
      // Mengenbegrenzung des Sync je Gerät/Person: in Tests weit offen (die Test-Uhr läuft nicht von selbst), Grenzentests setzen eigene Werte
      SYNC_OPS_BURST: '100000',
      SYNC_OPS_PER_MINUTE: '100000',
      SYNC_REQ_BURST: '100000',
      SYNC_REQ_PER_MINUTE: '100000',
      SYNC_OPS_PER_DAY: '100000',
      ...env,
    });
    const holder: { world?: World } = {};
    const app = await buildApp({ config, db, now: () => new Date(holder.world?.clock ?? Date.now()), ...(extra.logStream ? { logStream: extra.logStream } : {}), ...(extra.pushMinIntervalMs !== undefined ? { pushMinIntervalMs: extra.pushMinIntervalMs } : {}), ...(extra.weatherFetch ? { weatherFetch: extra.weatherFetch } : {}), ...(extra.operatorProbes ? { operatorProbes: extra.operatorProbes } : {}) });
    await app.ready();
    const authCore = app.authCore;
    if (!authCore) throw new Error('Auth fehlt');
    const world = new World(app, authCore, db, config);
    holder.world = world;
    return world;
  }

  advance(ms: number): void {
    this.clock += ms;
  }

  client(ip?: string): Client {
    return new Client(this, ip);
  }

  async close(): Promise<void> {
    await this.app.close();
  }

  /** TOTP-Code für den aktuellen Zeitschritt der Test-Uhr. */
  totp(secret: string, offsetSteps = 0): Promise<string> {
    return generate({ secret, epoch: Math.floor(this.clock / 1000) + offsetSteps * 30 });
  }

  /** Erstinstallation: Familie + Admin-Einladung (wie das CLI). */
  async bootstrap(withPin = false) {
    const invite = await bootstrapFamily(this.auth.ctx, { familyName: 'Familie Test', withPin });
    return invite;
  }

  /** Neues Mitglied per Passwort + TOTP registrieren (zwei Schritte). */
  async registerPassword(
    token: string,
    input: { email: string; displayName?: string; password?: string; pin?: string; client?: Client },
  ) {
    const c = input.client ?? this.client();
    const password = input.password ?? 'ein-sehr-langes-passwort-123';
    const start = await c.post('/api/v1/auth/invites/password/start', {
      token,
      email: input.email,
      displayName: input.displayName ?? 'Test Person',
      password,
      ...(input.pin ? { pin: input.pin } : {}),
    });
    if (start.status !== 200) return { client: c, start, complete: undefined, password, totpSecret: '', recoveryCodes: [] as string[] };
    const secret = start.json.totpSecret as string;
    const complete = await c.post('/api/v1/auth/invites/password/complete', { challengeId: start.json.challengeId, code: await this.totp(secret) });
    if (complete.status === 200 && complete.json.session) c.adopt(complete.json.session);
    return { client: c, start, complete, password, totpSecret: secret, recoveryCodes: (complete.json.recoveryCodes ?? []) as string[] };
  }

  /** Neues Mitglied per Passkey registrieren (zwei Schritte, simulierter Authenticator). */
  async registerPasskey(token: string, input: { email: string; displayName?: string; pin?: string; client?: Client; authenticator?: TestAuthenticator }) {
    const c = input.client ?? this.client();
    const authn = input.authenticator ?? new TestAuthenticator();
    const start = await c.post('/api/v1/auth/invites/passkey/options', {
      token,
      email: input.email,
      displayName: input.displayName ?? 'Passkey Person',
      ...(input.pin ? { pin: input.pin } : {}),
    });
    if (start.status !== 200) return { client: c, start, complete: undefined, authenticator: authn, recoveryCodes: [] as string[] };
    const response = authn.register(start.json.options);
    const complete = await c.post('/api/v1/auth/invites/passkey/complete', { challengeId: start.json.challengeId, response });
    if (complete.status === 200 && complete.json.session) c.adopt(complete.json.session);
    return { client: c, start, complete, authenticator: authn, recoveryCodes: (complete.json.recoveryCodes ?? []) as string[] };
  }

  /** Meldet per Passkey an (zwei Schritte). */
  async loginPasskey(client: Client, authenticator: TestAuthenticator, extra: Record<string, unknown> = {}) {
    const opts = await client.post('/api/v1/auth/login/passkey/options');
    const res = await client.post('/api/v1/auth/login/passkey/verify', { challengeId: opts.json.challengeId, response: authenticator.assert(opts.json.options), ...extra });
    if (res.status === 200) client.adopt(res.json.session);
    return res;
  }

  /** Zeilen in einer Tabelle (Name wie in der Datenbank, z. B. 'audit_log'). */
  async count(table: string): Promise<number> {
    const r = await this.db.execute<{ n: number }>(sql.raw(`select count(*)::int as n from "${table}"`));
    return r.rows[0]?.n ?? 0;
  }
}

// ---- Bausteine für Szenarien ----

/** Erstinstallation + Admin per Passwort/TOTP. */
export async function adminPassword(world: World, email = 'admin@example.org') {
  const boot = await world.bootstrap();
  const reg = await world.registerPassword(boot.token, { email, displayName: 'Admin' });
  if (reg.complete?.status !== 200) throw new Error(`Admin-Registrierung fehlgeschlagen: ${JSON.stringify(reg.complete?.json)}`);
  return { ...reg, boot, email };
}

/** Erstinstallation + Admin per Passkey. */
export async function adminPasskey(world: World, email = 'admin@example.org') {
  const boot = await world.bootstrap();
  const reg = await world.registerPasskey(boot.token, { email, displayName: 'Admin' });
  if (reg.complete?.status !== 200) throw new Error(`Admin-Registrierung fehlgeschlagen: ${JSON.stringify(reg.complete?.json)}`);
  return { ...reg, boot, email };
}

/** Einladung erzeugen (als `by`) und per Passwort einlösen. */
export async function addMember(world: World, by: Client, role: 'admin' | 'parent' | 'child', email: string, extra: Record<string, unknown> = {}) {
  const inv = await by.post('/api/v1/invites', { role, ...extra });
  if (inv.status !== 200) throw new Error(`Einladung fehlgeschlagen: ${JSON.stringify(inv.json)}`);
  const reg = await world.registerPassword(inv.json.invite.token, { email, displayName: email.split('@')[0] });
  return { ...reg, invite: inv.json.invite, email };
}

export const auditEvents = async (world: World) => (await world.db.select().from(schema.auditLog)).map((a) => a.event);

/**
 * Historische Migrationstests legen Daten mit dem AKTUELLEN Code auf einem älteren Schema an. Dort fehlen die Spalte `invites.kind`
 * (Migration 0019), die jede Einladung schreibt, und `sessions.origin`/`origin_at` (Migration 0020), die jede Sitzung schreibt: sie werden für die Dauer
 * der Anlage ergänzt und vor dem Weitermigrieren wieder entfernt.
 */
export const kindSpalteErgaenzen = async (db: Db) => {
  await db.execute(sql`alter table invites add column if not exists kind text not null default 'standard'`);
  await db.execute(sql`alter table sessions add column if not exists origin text not null default 'login'`);
  await db.execute(sql`alter table sessions add column if not exists origin_at timestamptz`);
};
export const kindSpalteEntfernen = async (db: Db) => {
  await db.execute(sql`alter table invites drop column if exists kind`);
  await db.execute(sql`alter table sessions drop column if exists origin`);
  await db.execute(sql`alter table sessions drop column if exists origin_at`);
};
