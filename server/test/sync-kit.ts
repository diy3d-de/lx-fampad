// Bausteine für die Sync-Tests: Familie mit allen Rollen, "Geräte" (Client + Geräte-ID) und Hilfen für Ops.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { TestAuthenticator } from './authenticator.js';
import { adminPasskey, Client, type Res, type World } from './helpers.js';

export type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface Op {
  opId: string;
  op: 'upsert' | 'delete';
  entity: string;
  id: string;
  fields?: Json;
  baseRev: number;
}

export const upsert = (entity: string, id: string, fields: Json, baseRev = 0, opId: string = randomUUID()): Op => ({ opId, op: 'upsert', entity, id, fields, baseRev });
export const remove = (entity: string, id: string, baseRev = 0, opId: string = randomUUID()): Op => ({ opId, op: 'delete', entity, id, baseRev });

/** Ein Gerät einer Person: Client (Cookie + CSRF) mit Geräte-ID und dem, was es vom Server schon kennt. */
export class Device {
  sinceRev = 0;
  /** Ziel-Revision eines laufenden mehrseitigen Snapshots (aus der Antwort der Seite davor). */
  snapshotRev: number | undefined;
  constructor(
    readonly world: World,
    readonly client: Client,
    readonly deviceId: string,
    readonly userId: string,
    readonly role: string,
  ) {}

  /** Roher Aufruf mit frei wählbarem Körper (Standard: dieses Gerät, aktueller Stand). */
  async raw(body: Json): Promise<Res> {
    return this.client.post('/api/v1/sync', body);
  }

  /** Sync mit Ops; `sinceRev` ist der Stand dieses Geräts und wird nicht automatisch fortgeschrieben (außer mit follow). */
  async sync(ops: Op[] = [], opts: { sinceRev?: number; limit?: number; follow?: boolean; protocolVersion?: number; snapshotRev?: number } = {}): Promise<Res> {
    const res = await this.raw({
      protocolVersion: opts.protocolVersion ?? 1,
      deviceId: this.deviceId,
      sinceRev: opts.sinceRev ?? this.sinceRev,
      ...(opts.limit ? { limit: opts.limit } : {}),
      ...((opts.snapshotRev ?? this.snapshotRev) !== undefined ? { snapshotRev: opts.snapshotRev ?? this.snapshotRev } : {}),
      ops,
    });
    if (opts.follow && res.status === 200 && res.json.status === 'ok') {
      this.sinceRev = res.json.hasMore ? res.json.next : res.json.rev;
      this.snapshotRev = res.json.snapshotRev;
    }
    return res;
  }

  /** Holt alle Änderungen seit sinceRev seitenweise und schreibt den Stand fort. Liefert alle Änderungen. */
  async pull(limit = 500): Promise<Json[]> {
    const all: Json[] = [];
    for (let i = 0; i < 100; i++) {
      const res = await this.sync([], { limit, follow: true });
      if (res.status !== 200) throw new Error(`Sync fehlgeschlagen: ${res.status} ${JSON.stringify(res.json)}`);
      if (res.json.status === 'resync_required') {
        this.snapshotRev = undefined;
        throw new Error('resync_required');
      }
      all.push(...res.json.changes);
      if (!res.json.hasMore) return all;
    }
    throw new Error('zu viele Seiten');
  }
}

/** Gerät aus einem angemeldeten Client (Geräte-ID und Person aus GET /me). */
export async function deviceOf(world: World, client: Client): Promise<Device> {
  const me = await client.get('/api/v1/me');
  if (me.status !== 200) throw new Error(`/me fehlgeschlagen: ${me.status}`);
  return new Device(world, client, me.json.session.deviceId as string, me.json.user.id as string, me.json.user.role as string);
}

export interface Family {
  admin: Device;
  adminKey: TestAuthenticator;
  parent: Device;
  child: Device;
  familyId: string;
  /** Meldet die Person (Passkey) auf einem weiteren Gerät an. */
  secondDevice(person: 'admin' | 'parent' | 'child'): Promise<Device>;
}

async function passkeyMember(world: World, by: Client, role: 'parent' | 'child', email: string) {
  const inv = await by.post('/api/v1/invites', { role });
  if (inv.status !== 200) throw new Error(`Einladung fehlgeschlagen: ${JSON.stringify(inv.json)}`);
  const reg = await world.registerPasskey(inv.json.invite.token, { email, displayName: email.split('@')[0] ?? email });
  if (reg.complete?.status !== 200) throw new Error(`Registrierung fehlgeschlagen: ${JSON.stringify(reg.complete?.json)}`);
  if (reg.complete.json.status === 'pending') {
    const id = reg.complete.json.member.id as string;
    const ok = await by.post(`/api/v1/members/${id}/approve`);
    if (ok.status !== 200) throw new Error('Freigabe fehlgeschlagen');
    await world.loginPasskey(reg.client, reg.authenticator);
  }
  return reg;
}

/** Weiteres Mitglied (Passkey) mit eigenem Gerät, z. B. für Tests, die Mitglieder entfernen. */
export async function extraMember(world: World, admin: Device, role: 'parent' | 'child', email: string): Promise<Device> {
  const reg = await passkeyMember(world, admin.client, role, email);
  return deviceOf(world, reg.client);
}

/** Familie mit Admin, Elternteil und Kind (alle per Passkey, damit sich Geräte beliebig oft anmelden lassen). */
export async function createFamily(world: World): Promise<Family> {
  const a = await adminPasskey(world);
  const parent = await passkeyMember(world, a.client, 'parent', 'mama@example.org');
  const child = await passkeyMember(world, a.client, 'child', 'kind@example.org');
  const keys = { admin: a.authenticator, parent: parent.authenticator, child: child.authenticator };
  const admin = await deviceOf(world, a.client);
  const me = await a.client.get('/api/v1/me');
  const family: Family = {
    admin,
    adminKey: a.authenticator,
    parent: await deviceOf(world, parent.client),
    child: await deviceOf(world, child.client),
    familyId: me.json.familyId as string,
    async secondDevice(person) {
      const c = world.client('203.0.113.77');
      const res = await world.loginPasskey(c, keys[person]);
      if (res.status !== 200) throw new Error(`Anmeldung fehlgeschlagen: ${JSON.stringify(res.json)}`);
      return deviceOf(world, c);
    },
  };
  return family;
}

/** Leert alle Sync-Daten und setzt die Zähler zurück (die Familie und ihre Mitglieder bleiben). */
export async function resetSync(world: World): Promise<void> {
  await world.db.execute(sql`truncate table change_log, applied_ops, familien_status, vorsorge_eintraege, vorsorge_profile, einnahmen, medikamente, tresor_anhaenge, tresor_eintraege, datei_versionen, dateien, ordner, datei_blob, datei_upload, zaehlerstaende, zaehler, reaktionen, stimmen, pins, epoche_wraps, konversation_epochen, lesestand, aufgabe_punkte, aufgaben, nachrichten, konversationen, list_items, lists, termin_ausnahmen, termin_teilnehmer, termine`);
  await world.db.execute(sql`update families set current_rev = 0, purged_rev = 0`);
  await world.db.execute(sql`update devices set last_rev = 0, resync_required = false`);
}

export const items = (changes: Json[]) => changes.filter((c) => c.entity === 'list_item');
export const listsOf = (changes: Json[]) => changes.filter((c) => c.entity === 'list');
