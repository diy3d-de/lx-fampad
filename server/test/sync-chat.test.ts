// Chat im Sync: Teilnehmer-Sichtbarkeit (Admins/Eltern lesen private Chats nicht), Familienchat, Direktchat-Eindeutigkeit, Nachrichten,
// Lesestand, Gruppen (Teilnehmer ändern, hidden-Tombstone), WebSocket ohne Hinweis an Unbeteiligte, Mitglied entfernen, Obergrenzen.
import { randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { konversationEntity, nachrichtEntity, lesestandEntity, MAX_NACHRICHT, NACHRICHTEN_PRO_MINUTE } from '../src/sync/entities/chat.js';
import { authorize, mayRead, rolesThatMayRead, ROLES, usersThatMayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import type { Role } from '../src/auth/types.js';
import { Hub } from '../src/ws/hub.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const actor = (role: Role, userId: string): Actor => ({ role, userId });

describe('Chat: Rechte-Modell (Regeltabelle)', () => {
  const ADMIN = 'u-admin';
  const A = 'u-a';
  const B = 'u-b';
  const privat: Facts = { audience: 'family', ownerId: A, participants: [A, B] };
  const familie: Facts = { audience: 'family', ownerId: null };
  const nachricht = (f: Facts, autor: string | null): Facts => ({ ...f, ownerId: autor });

  it('Privatchat: nur Teilnehmer lesen, auch Admin und Eltern nicht (kein Rollen-Durchgriff)', () => {
    for (const role of ['admin', 'parent', 'child'] as const) {
      expect(mayRead(konversationEntity.rules, actor(role, A), privat), `${role} als Teilnehmer`).toBe(true);
      expect(mayRead(konversationEntity.rules, actor(role, ADMIN), privat), `${role} ohne Teilnehmer`).toBe(false);
      expect(mayRead(nachrichtEntity.rules, actor(role, ADMIN), nachricht(privat, A)), `${role} Nachricht`).toBe(false);
      expect(mayRead(lesestandEntity.rules, actor(role, ADMIN), privat), `${role} Lesestand`).toBe(false);
    }
    // jede Aktion eines Nichtteilnehmers ist "nicht auffindbar", nie "verboten"
    for (const action of ['update', 'delete'] as const) {
      expect(authorize(konversationEntity.rules, action, actor('admin', ADMIN), privat, ['titel'])).toBe('not_found');
      expect(authorize(nachrichtEntity.rules, action, actor('admin', ADMIN), nachricht(privat, A), ['text'])).toBe('not_found');
    }
    expect(authorize(nachrichtEntity.rules, 'create', actor('admin', ADMIN), nachricht(privat, A), ['konversationId', 'text'])).toBe('forbidden');
  });

  it('Familienchat: alle Rollen außer Gästen lesen und schreiben; ohne Teilnehmerliste', () => {
    for (const role of ['admin', 'parent', 'child'] as const) {
      expect(mayRead(konversationEntity.rules, actor(role, ADMIN), familie)).toBe(true);
      expect(authorize(nachrichtEntity.rules, 'create', actor(role, ADMIN), nachricht(familie, ADMIN), ['konversationId', 'text'])).toBe('ok');
    }
    expect(rolesThatMayRead(konversationEntity.rules, familie)).toEqual(expect.arrayContaining(['admin', 'parent', 'child']));
    expect(usersThatMayRead(familie)).toBeUndefined();
  });

  it('Benachrichtigung: privat nur an Teilnehmer (keine Rollen)', () => {
    expect(rolesThatMayRead(konversationEntity.rules, privat)).toEqual([]);
    expect(usersThatMayRead(privat)).toEqual([A, B]);
  });

  it('Nachrichten: bearbeiten und löschen nur der Autor; Admin löscht fremde nur im Familienchat', () => {
    expect(authorize(nachrichtEntity.rules, 'update', actor('child', A), nachricht(privat, A), ['text'])).toBe('ok');
    expect(authorize(nachrichtEntity.rules, 'update', actor('child', B), nachricht(privat, A), ['text'])).toBe('forbidden');
    expect(authorize(nachrichtEntity.rules, 'update', actor('admin', ADMIN), nachricht(familie, A), ['text'])).toBe('forbidden');
    expect(authorize(nachrichtEntity.rules, 'delete', actor('child', A), nachricht(privat, A))).toBe('ok');
    expect(authorize(nachrichtEntity.rules, 'delete', actor('parent', B), nachricht(privat, A))).toBe('forbidden');
    // Admin als Teilnehmer eines Privatchats hat keine Sonderrechte: fremde Nachrichten löscht er dort nicht
    expect(authorize(nachrichtEntity.rules, 'delete', actor('admin', B), nachricht(privat, A))).toBe('forbidden');
    expect(authorize(nachrichtEntity.rules, 'delete', actor('admin', ADMIN), nachricht(familie, A))).toBe('ok');
    expect(authorize(nachrichtEntity.rules, 'delete', actor('parent', ADMIN), nachricht(familie, A))).toBe('forbidden');
    expect(authorize(nachrichtEntity.rules, 'delete', actor('child', ADMIN), nachricht(familie, A))).toBe('forbidden');
    expect(authorize(nachrichtEntity.rules, 'delete', actor('admin', ADMIN), nachricht(privat, A))).toBe('not_found');
  });

  it('Lesestand: nur die eigene Zeile', () => {
    const eigen = { ...privat, ownerId: A };
    expect(authorize(lesestandEntity.rules, 'update', actor('child', A), eigen, ['gelesenBis'])).toBe('ok');
    // die Zeile eines anderen gibt es für die Person nicht (auch nicht als Teilnehmer)
    expect(authorize(lesestandEntity.rules, 'update', actor('child', B), eigen, ['gelesenBis'])).toBe('not_found');
    expect(authorize(lesestandEntity.rules, 'update', actor('admin', ADMIN), eigen, ['gelesenBis'])).toBe('not_found');
    expect(authorize(lesestandEntity.rules, 'create', actor('child', B), eigen, ['konversationId', 'userId', 'gelesenBis'])).toBe('forbidden');
    // im Familienchat sieht auch der Admin die Zeile eines anderen nicht (Regel "own")
    expect(mayRead(lesestandEntity.rules, actor('admin', ADMIN), { ...familie, ownerId: A })).toBe(false);
  });

  it('jede Rolle hat für jede Aktion der Chat-Entitäten eine Regel', () => {
    for (const def of [konversationEntity, nachrichtEntity, lesestandEntity]) {
      for (const role of ROLES) for (const a of ['read', 'create', 'update', 'delete'] as const) expect(def.rules[role][a], `${def.name}/${role}/${a}`).toBeDefined();
    }
  });
});

describe('Hub: Hinweis nach Person (Privatchats)', () => {
  const aufbau = () => {
    const hub = new Hub();
    const sent: Record<string, string[]> = { admin: [], eltern: [], kind: [], fremd: [] };
    const socket = (name: string) => ({ OPEN: 1, readyState: 1, send: (m: string) => sent[name]?.push(m), once: () => undefined });
    hub.add('fam', socket('admin') as never, { userId: 'u-admin', role: 'admin' });
    hub.add('fam', socket('eltern') as never, { userId: 'u-eltern', role: 'parent' });
    hub.add('fam', socket('kind') as never, { userId: 'u-kind', role: 'child' });
    hub.add('other', socket('fremd') as never, { userId: 'u-kind', role: 'child' });
    return { hub, sent };
  };

  it('mit Personen und leeren Rollen geht der Hinweis nur an diese Personen (auch nicht an Admin oder Familienfremde)', () => {
    const { hub, sent } = aufbau();
    hub.notifyRev('fam', 7, [], ['u-eltern', 'u-kind']);
    expect(sent).toEqual({ admin: [], eltern: ['{"type":"rev","rev":7}'], kind: ['{"type":"rev","rev":7}'], fremd: [] });
  });

  it('Rollen und Personen ergänzen sich; ohne Personen bleibt es bei der Sicht nach Rollen', () => {
    const { hub, sent } = aufbau();
    hub.notifyRev('fam', 8, ['admin'], ['u-kind']);
    expect([sent.admin?.length, sent.eltern?.length, sent.kind?.length]).toEqual([1, 0, 1]);
    hub.notifyRev('fam', 9, ['parent']);
    expect([sent.admin?.length, sent.eltern?.length, sent.kind?.length]).toEqual([1, 1, 1]);
  });
});

describe.each(backends)('Chat im Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
    await world.app.listen({ host: '127.0.0.1', port: 0 });
    fam = await createFamily(world);
  }, 180_000);
  afterAll(async () => {
    for (const s of sockets.splice(0)) s.terminate();
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    for (const d of [fam.admin, fam.parent, fam.child, fam.guest]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const revOf = async (table: 'konversationen' | 'nachrichten' | 'lesestand', id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);
  const rejectedOf = (res: { json: Json }) => res.json.rejected as Array<{ opId: string; code: string }>;
  const codes = (res: { json: Json }) => rejectedOf(res).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);

  async function familienchat(by: Device = fam.admin): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('konversation', id, { art: 'family' })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  async function direkt(by: Device, other: Device): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('konversation', id, { art: 'direct', teilnehmer: [by.userId, other.userId] })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  async function gruppe(by: Device, members: Device[], titel = 'p1:Gruppe'): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('konversation', id, { art: 'group', titel, teilnehmer: [by.userId, ...members.map((m) => m.userId)] })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  const nachricht = async (by: Device, konv: string, text = 'p1:Hallo', extra: Json = {}) => {
    const id = randomUUID();
    const res = await by.sync([upsert('nachricht', id, { konversationId: konv, text, ...extra })]);
    return { id, res };
  };

  describe('Familienchat', () => {
    it('jede Person legt ihn an, er ist für alle sichtbar; ein zweiter wird abgelehnt, dieselbe ID ist idempotent', async () => {
      const id = await familienchat(fam.child);
      expect((await fam.admin.pull()).filter((c) => c.entity === 'konversation').map((c) => c.id)).toEqual([id]);
      expect(ids(await fam.parent.pull(), 'konversation')).toEqual([id]);
      // zweiter Familienchat mit anderer ID: eindeutiger Index, antwortet wie "gibt es schon" (not_found)
      const zweiter = await fam.admin.sync([upsert('konversation', randomUUID(), { art: 'family' })]);
      expect(codes(zweiter)).toEqual(['not_found']);
      // dieselbe ID noch einmal (zweites Gerät, gleiche Op): ohne Wirkung
      const noch = await fam.parent.sync([upsert('konversation', id, { art: 'family' })]);
      expect(noch.json.rejected).toEqual([]);
      expect(await rows(sql`select count(*)::int as n from konversationen where art = 'family'`)).toEqual([{ n: 1 }]);
    });

    it('Familienchat hat weder Namen noch Teilnehmer, ist unveränderlich und nicht löschbar', async () => {
      expect(codes(await fam.admin.sync([upsert('konversation', randomUUID(), { art: 'family', titel: 'x' })]))).toEqual(['invalid']);
      expect(codes(await fam.admin.sync([upsert('konversation', randomUUID(), { art: 'family', teilnehmer: [fam.admin.userId] })]))).toEqual(['invalid']);
      const id = await familienchat();
      const rev = await revOf('konversationen', id);
      expect(codes(await fam.admin.sync([upsert('konversation', id, { titel: 'Umbenannt' }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.admin.sync([remove('konversation', id, rev)]))).toEqual(['forbidden']);
    });

    it('neue Mitglieder sehen ihn und seinen Verlauf (alle aktiven Mitglieder implizit)', async () => {
      const id = await familienchat();
      const { id: mid } = await nachricht(fam.admin, id, 'p1:Willkommen');
      const neu = await extraMember(world, fam.admin, 'child', 'neu@example.org');
      const changes = await neu.pull();
      expect(ids(changes, 'konversation')).toEqual([id]);
      expect(ids(changes, 'nachricht')).toEqual([mid]);
    });

    it('Admin darf fremde Nachrichten im Familienchat löschen, Eltern und Kinder nicht', async () => {
      const id = await familienchat();
      const { id: mid } = await nachricht(fam.child, id);
      const rev = await revOf('nachrichten', mid);
      expect(codes(await fam.parent.sync([remove('nachricht', mid, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.admin.sync([upsert('nachricht', mid, { text: 'p1:geändert' }, rev)]))).toEqual(['forbidden']);
      expect((await fam.admin.sync([remove('nachricht', mid, rev)])).json.acked).toHaveLength(1);
    });
  });

  describe('Direktchats', () => {
    it('Admin sieht den Direktchat von Eltern und Kind nicht: nicht im Strom, Ändern/Löschen/Nachricht = not_found', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const { id: mid } = await nachricht(fam.child, konv, 'p1:GEHEIMER-TEXT');
      expect(ids(await fam.parent.pull())).toEqual(expect.arrayContaining([konv, mid]));
      expect(ids(await fam.child.pull())).toEqual(expect.arrayContaining([konv, mid]));
      // auch ein Admin, der sinceRev 0 neu beginnt, bekommt nichts
      expect(await fam.admin.pull()).toEqual([]);
      const rev = await revOf('konversationen', konv);
      const mrev = await revOf('nachrichten', mid);
      const res = await fam.admin.sync([
        upsert('konversation', konv, { titel: 'x' }, rev),
        remove('konversation', konv, rev),
        upsert('nachricht', mid, { text: 'p1:x' }, mrev),
        remove('nachricht', mid, mrev),
        upsert('nachricht', randomUUID(), { konversationId: konv, text: 'p1:Einschleusen' }),
        upsert('lesestand', randomUUID(), { konversationId: konv, userId: fam.admin.userId, gelesenBis: '2026-10-19T08:00:00.000Z' }),
      ]);
      expect(codes(res)).toEqual(['not_found', 'not_found', 'not_found', 'not_found', 'not_found', 'not_found']);
      expect(JSON.stringify(res.json)).not.toContain('GEHEIMER-TEXT');
      expect(await rows(sql`select count(*)::int as n from nachrichten`)).toEqual([{ n: 1 }]);
    });

    it('je Paar genau ein Direktchat (auch mit vertauschter Reihenfolge); Teilnehmer werden sortiert gespeichert', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const zweiter = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId] })]);
      expect(codes(zweiter)).toEqual(['not_found']);
      const [row] = await rows(sql`select teilnehmer from konversationen where id = ${konv}`);
      expect([...(row?.teilnehmer as string[])]).toEqual([fam.parent.userId, fam.child.userId].sort());
      // dieselbe ID von der anderen Seite (zweites Gerät, gleicher Paar-Schlüssel): ohne Wirkung
      const gleich = await fam.child.sync([upsert('konversation', konv, { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId] })]);
      expect(gleich.json.rejected).toEqual([]);
      // anderes Paar geht
      await direkt(fam.child, fam.admin);
    });

    it('Prüfung bei der Anlage: Ersteller muss dabei sein, genau zwei, nur Familienmitglieder, kein Name', async () => {
      const ohneMich = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.parent.userId, fam.admin.userId] })]);
      expect(codes(ohneMich)).toEqual(['forbidden']);
      const drei = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId, fam.admin.userId] })]);
      expect(codes(drei)).toEqual(['invalid']);
      const allein = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, fam.child.userId] })]);
      expect(codes(allein)).toEqual(['invalid']);
      const fremd = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, randomUUID()] })]);
      expect(codes(fremd)).toEqual(['invalid_reference']);
      const mitName = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', titel: 'p1:x', teilnehmer: [fam.child.userId, fam.parent.userId] })]);
      expect(codes(mitName)).toEqual(['invalid']);
      expect(await rows(sql`select count(*)::int as n from konversationen`)).toEqual([{ n: 0 }]);
    });

    it('Direktchat ist unveränderlich und wird nicht gelöscht', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const rev = await revOf('konversationen', konv);
      expect(codes(await fam.parent.sync([upsert('konversation', konv, { teilnehmer: [fam.parent.userId, fam.admin.userId] }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([remove('konversation', konv, rev)]))).toEqual(['forbidden']);
    });
  });

  describe('Nachrichten', () => {
    it('Senden, Bearbeiten (Zeit setzt der Server), Löschen nur durch den Autor; opaker Text bleibt unverändert', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const text = '  p1:Hallo 👋 <b>kein html</b> https://example.org  ';
      const { id, res } = await nachricht(fam.parent, konv, text, { antwortAuf: randomUUID() });
      expect(res.json.rejected).toEqual([]);
      const [row] = await rows(sql`select text, autor_id, bearbeitet_at, antwort_auf from nachrichten where id = ${id}`);
      expect(row).toMatchObject({ text, autor_id: fam.parent.userId, bearbeitet_at: null });
      const change = (await fam.child.pull()).find((c) => c.id === id);
      expect(change?.fields).toMatchObject({ text, autorId: fam.parent.userId, konversationId: konv, bearbeitetAt: null });
      expect(change?.fields.createdAt).toBeTruthy();

      const rev = await revOf('nachrichten', id);
      expect(codes(await fam.child.sync([upsert('nachricht', id, { text: 'p1:Gefälscht' }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([remove('nachricht', id, rev)]))).toEqual(['forbidden']);
      world.advance(60_000);
      expect((await fam.parent.sync([upsert('nachricht', id, { text: 'p1:neu' }, rev)])).json.acked).toHaveLength(1);
      const [edited] = await rows(sql`select text, bearbeitet_at from nachrichten where id = ${id}`);
      expect(edited?.text).toBe('p1:neu');
      expect(edited?.bearbeitet_at).not.toBeNull();
      // Autor, Konversation und Antwort-Verweis lassen sich nachträglich nicht ändern
      const r2 = await revOf('nachrichten', id);
      expect(codes(await fam.parent.sync([upsert('nachricht', id, { konversationId: randomUUID() }, r2)]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('nachricht', id, { autorId: fam.child.userId }, r2)]))).toEqual(['invalid']);
      expect((await fam.parent.sync([remove('nachricht', id, r2)])).json.acked).toHaveLength(1);
      const tomb = (await fam.child.pull()).find((c) => c.id === id && c.tombstone);
      expect(tomb).toMatchObject({ tombstone: true, fields: {} });
      expect((await rows(sql`select text from nachrichten where id = ${id}`))[0]?.text).toBe('');
    });

    it('Länge: 16384 Zeichen gehen, mehr nicht; leer und ungültige Zeichen nicht; Autor kann nicht gesetzt werden', async () => {
      const konv = await familienchat();
      expect((await nachricht(fam.admin, konv, 'p1:' + 'x'.repeat(MAX_NACHRICHT - 3))).res.json.acked).toHaveLength(1);
      expect(codes((await nachricht(fam.admin, konv, 'x'.repeat(MAX_NACHRICHT + 1))).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.admin, konv, '')).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.admin, konv, 'a\u0000b')).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.admin, konv, 'p1:x', { autorId: fam.child.userId })).res)).toEqual(['invalid']);
    });

    it(`Rate: höchstens ${NACHRICHTEN_PRO_MINUTE} Nachrichten je Person und Minute`, async () => {
      const konv = await familienchat();
      const batch = (n: number) => Array.from({ length: n }, () => upsert('nachricht', randomUUID(), { konversationId: konv, text: 'p1:x' }));
      expect((await fam.child.sync(batch(NACHRICHTEN_PRO_MINUTE - 10))).json.rejected).toEqual([]);
      const second = await fam.child.sync(batch(20));
      expect(codes(second)).toEqual(Array(10).fill('limit_reached'));
      // eine andere Person ist nicht betroffen, nach einer Minute geht es wieder
      expect((await fam.parent.sync(batch(5))).json.rejected).toEqual([]);
      world.advance(61_000);
      expect((await fam.child.sync(batch(5))).json.rejected).toEqual([]);
    });
  });

  describe('Lesestand', () => {
    it('nur die eigene Zeile: andere sehen sie nicht und können sie nicht schreiben, für andere kann man keine anlegen', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const id = randomUUID();
      const ok = await fam.child.sync([upsert('lesestand', id, { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      expect(ok.json.rejected).toEqual([]);
      // der Elternteil ist Teilnehmer, sieht die Zeile des Kindes aber nicht
      expect(ids(await fam.parent.pull(), 'lesestand')).toEqual([]);
      expect(ids(await fam.child.pull(), 'lesestand')).toEqual([id]);
      const rev = await revOf('lesestand', id);
      expect(codes(await fam.parent.sync([upsert('lesestand', id, { gelesenBis: '2026-10-19T09:00:00.000Z' }, rev)]))).toEqual(['not_found']);
      const fuerAndere = await fam.parent.sync([upsert('lesestand', randomUUID(), { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      expect(codes(fuerAndere)).toEqual(['forbidden']);
      // Fortschreiben der eigenen Zeile
      expect((await fam.child.sync([upsert('lesestand', id, { gelesenBis: '2026-10-19T09:00:00.000Z' }, rev)])).json.acked).toHaveLength(1);
    });

    it('im Familienchat sieht auch der Admin den Lesestand anderer nicht', async () => {
      const konv = await familienchat();
      await fam.child.sync([upsert('lesestand', randomUUID(), { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      expect(ids(await fam.admin.pull(), 'lesestand')).toEqual([]);
    });

    it('eine Zeile je Person und Konversation: dieselbe Person kann keine zweite anlegen', async () => {
      const konv = await familienchat();
      const mk = () => upsert('lesestand', randomUUID(), { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' });
      expect((await fam.child.sync([mk()])).json.rejected).toEqual([]);
      expect(codes(await fam.child.sync([mk()]))).toEqual(['not_found']);
    });
  });

  describe('Gruppen', () => {
    it('nur Teilnehmer sehen sie; Unbeteiligte (auch Admin) erfahren nichts, auch nicht bei Änderungen', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      await nachricht(fam.child, konv);
      expect(await fam.admin.pull()).toEqual([]);
      await fam.parent.sync([upsert('konversation', konv, { titel: 'p1:Neu' }, await revOf('konversationen', konv))], { sinceRev: 0 });
      expect(await fam.admin.pull()).toEqual([]);
      const snapshot = await (await fam.admin.sync([], { sinceRev: 0 })).json;
      expect(JSON.stringify(snapshot)).not.toContain(konv);
    });

    it('Teilnehmer hinzufügen: die neue Person bekommt Konversation und Verlauf; entfernen: nur sie bekommt den hidden-Tombstone', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const { id: mid } = await nachricht(fam.parent, konv, 'p1:Vor dem Beitritt');
      await fam.child.pull();
      expect(await fam.admin.pull()).toEqual([]);

      // Admin wird aufgenommen
      const teilnehmer = [fam.parent.userId, fam.child.userId, fam.admin.userId];
      expect((await fam.parent.sync([upsert('konversation', konv, { teilnehmer }, await revOf('konversationen', konv))])).json.acked).toHaveLength(1);
      const joined = await fam.admin.pull();
      expect(ids(joined, 'konversation')).toEqual([konv]);
      expect(ids(joined, 'nachricht')).toEqual([mid]);

      // Kind verlässt die Gruppe (entfernt sich selbst)
      await fam.child.pull();
      const rest = [fam.parent.userId, fam.admin.userId];
      expect((await fam.child.sync([upsert('konversation', konv, { teilnehmer: rest }, await revOf('konversationen', konv))])).json.acked).toHaveLength(1);
      const childView = await fam.child.pull();
      expect(childView).toEqual([expect.objectContaining({ entity: 'konversation', id: konv, tombstone: true, hidden: true, fields: {} })]);
      // wer nie drin war, bekommt keinen hidden-Tombstone: ein Außenstehender sieht nichts
      const outsider = await extraMember(world, fam.admin, 'child', 'aussen@example.org');
      expect(await outsider.pull()).toEqual([]);
      // das Kind kann nicht mehr schreiben und nichts mehr ändern
      expect(codes(await fam.child.sync([upsert('nachricht', randomUUID(), { konversationId: konv, text: 'p1:x' })]))).toEqual(['not_found']);
      // Admin (inzwischen Teilnehmer) und Elternteil sehen die Gruppe weiter
      expect(ids(await fam.admin.pull(), 'konversation')).toEqual([konv]);
      expect(await rows(sql`select teilnehmer from konversationen where id = ${konv}`)).toEqual([{ teilnehmer: [...rest].sort() }]);
    });

    it('Gruppe: Teilnehmer ändern den Namen; löschen nur die anlegende Person; Obergrenze 20 Teilnehmer', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      await fam.child.pull();
      const rev = await revOf('konversationen', konv);
      expect((await fam.child.sync([upsert('konversation', konv, { titel: 'p1:Von Kind' }, rev)])).json.acked).toHaveLength(1);
      expect(codes(await fam.child.sync([remove('konversation', konv, rev + 1)]))).toEqual(['forbidden']);
      expect((await fam.parent.sync([remove('konversation', konv, rev + 1)])).json.acked).toHaveLength(1);
      // Tombstone erreicht die Teilnehmer, nicht den Admin
      expect((await fam.child.pull()).filter((c) => c.id === konv).map((c) => c.tombstone)).toEqual([true]);
      expect(await fam.admin.pull()).toEqual([]);

      const viele = Array.from({ length: 20 }, () => randomUUID());
      const zuViele = await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'group', teilnehmer: [fam.parent.userId, ...viele] })]);
      expect(codes(zuViele)).toEqual(['invalid']);
    });

    it('Kinder dürfen Gruppen anlegen; Gruppe mit weniger als zwei Personen nicht; Obergrenze je Person', async () => {
      await gruppe(fam.child, [fam.parent, fam.admin]);
      expect(codes(await fam.child.sync([upsert('konversation', randomUUID(), { art: 'group', teilnehmer: [fam.child.userId] })]))).toEqual(['invalid']);
    });
  });

  describe('WebSocket-Hinweis', () => {
    async function connect(d: Device) {
      const { port } = world.app.server.address() as AddressInfo;
      const messages: Json[] = [];
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.51' } });
      sockets.push(ws);
      ws.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8'))));
      await new Promise<void>((resolve, reject) => {
        ws.once('open', () => resolve());
        ws.once('error', reject);
      });
      const ticket = (await d.client.post('/api/v1/ws-ticket')).json.ticket as string;
      ws.send(JSON.stringify({ type: 'auth', ticket }));
      for (let i = 0; i < 40 && !messages.some((m) => m.type === 'ready'); i++) await wait(50);
      expect(messages.some((m) => m.type === 'ready')).toBe(true);
      return messages;
    }
    const revs = (messages: Json[]) => messages.filter((m) => m.type === 'rev').map((m) => m.rev);

    it('eine Nachricht im Privatchat meldet sich nur bei den Teilnehmern (kein Leak an Admin und Dritte); im Familienchat bei allen', async () => {
      const parent = await connect(fam.parent);
      const child = await connect(fam.child);
      const admin = await connect(fam.admin);
      const konv = await direkt(fam.parent, fam.child);
      await wait(150);
      expect(revs(parent.slice())).toEqual([1]);
      expect(revs(child.slice())).toEqual([1]);
      expect(revs(admin)).toEqual([]);
      await nachricht(fam.parent, konv, 'p1:GEHEIM');
      await wait(150);
      expect(revs(child)).toEqual([1, 2]);
      expect(revs(admin)).toEqual([]);
      expect(JSON.stringify(admin)).not.toContain('GEHEIM');

      const fk = await familienchat();
      await nachricht(fam.child, fk);
      await wait(150);
      expect(revs(admin)).toEqual([3, 4]);
      expect(revs(parent)).toEqual([1, 2, 3, 4]);
    });
  });

  describe('Mitglied entfernen', () => {
    it('Direktchats der Person werden gelöscht, Gruppen verlieren sie, Nachrichten im Familienchat bleiben ohne Autor, Lesestand verschwindet', async () => {
      const opa = await extraMember(world, fam.admin, 'parent', 'opa@example.org');
      const fk = await familienchat();
      const dm = await direkt(opa, fam.child);
      const g3 = await gruppe(opa, [fam.child, fam.parent]);
      const g2 = await gruppe(opa, [fam.child]);
      const { id: famMsg } = await nachricht(opa, fk, 'p1:Hallo');
      const ls = randomUUID();
      await opa.sync([upsert('lesestand', ls, { konversationId: g3, userId: opa.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      await fam.child.pull();
      expect(ids(await fam.child.pull())).toEqual([]); // Stand aktuell

      expect((await fam.admin.client.del(`/api/v1/members/${opa.userId}`)).status).toBe(200);
      const changes = await fam.child.pull();
      const byId = (id: string) => changes.filter((c) => c.id === id);
      // Direktchat und die Gruppe mit nur zwei Personen: gelöscht (Tombstone, für das Kind sichtbar)
      expect(byId(dm)).toEqual([expect.objectContaining({ tombstone: true })]);
      expect(byId(g2)).toEqual([expect.objectContaining({ tombstone: true })]);
      // Gruppe mit drei Personen: Teilnehmerliste ohne die Person
      expect(byId(g3)[0]?.fields.teilnehmer).toEqual([fam.child.userId, fam.parent.userId].sort());
      // Nachricht im Familienchat bleibt, Autor ist leer
      expect(byId(famMsg)[0]?.fields).toMatchObject({ autorId: null, text: 'p1:Hallo' });
      expect(await rows(sql`select count(*)::int as n from lesestand where user_id = ${opa.userId}`)).toEqual([{ n: 0 }]);
      // Admin sieht von all dem nichts Privates
      expect(ids(await fam.admin.pull()).filter((i) => [dm, g2, g3].includes(i))).toEqual([]);
      // die entfernte Person ist kein gültiger Teilnehmer mehr
      const wieder = await fam.child.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, opa.userId] })]);
      expect(codes(wieder)).toEqual(['invalid_reference']);
    });
  });

  describe('Obergrenzen und Sicherheit', () => {
    it('Konversationen je Person begrenzt (100), Verweis auf fremde Familie wird abgelehnt', async () => {
      await world.db.execute(sql`delete from families where name = 'Fremd2'`);
      await world.db.execute(sql`delete from users where email = 'fremd2@example.org'`);
      const familyId = randomUUID();
      const userId = randomUUID();
      await world.db.execute(sql`insert into families (id, name, current_rev) values (${familyId}, 'Fremd2', 5)`);
      await world.db.execute(sql`insert into users (id, email, display_name) values (${userId}, 'fremd2@example.org', 'Fremd')`);
      await world.db.execute(sql`insert into memberships (family_id, user_id, role) values (${familyId}, ${userId}, 'admin')`);
      const konvId = randomUUID();
      await world.db.execute(
        sql`insert into konversationen (id, family_id, art, teilnehmer, rev, field_revs) values (${konvId}, ${familyId}, 'direct', ${sql.raw(`ARRAY['${userId}','${randomUUID()}']::uuid[]`)}, 5, '{}')`,
      );
      // IDOR: fremde Konversations-ID in Nachricht, Lesestand, Änderung, Löschung
      const res = await fam.admin.sync([
        upsert('nachricht', randomUUID(), { konversationId: konvId, text: 'p1:x' }),
        upsert('lesestand', randomUUID(), { konversationId: konvId, userId: fam.admin.userId, gelesenBis: '2026-10-19T08:00:00.000Z' }),
        upsert('konversation', konvId, { titel: 'x' }, 5),
        remove('konversation', konvId, 5),
        upsert('konversation', konvId, { art: 'direct', teilnehmer: [fam.admin.userId, fam.child.userId] }),
      ]);
      expect(codes(res)).toEqual(Array(5).fill('not_found'));
      // Verweis auf ein Mitglied einer fremden Familie
      expect(codes(await fam.admin.sync([upsert('konversation', randomUUID(), { art: 'direct', teilnehmer: [fam.admin.userId, userId] })]))).toEqual(['invalid_reference']);
      await world.db.execute(sql`delete from families where name = 'Fremd2'`);
      await world.db.execute(sql`delete from users where email = 'fremd2@example.org'`);

      // Obergrenze je Person (100): ab der 101. Gruppe limit_reached
      const mk = () => upsert('konversation', randomUUID(), { art: 'group', teilnehmer: [fam.child.userId, fam.parent.userId] });
      for (let i = 0; i < 100; i += 50) expect((await fam.child.sync(Array.from({ length: 50 }, mk))).json.rejected).toEqual([]);
      expect(codes(await fam.child.sync([mk()]))).toEqual(['limit_reached']);
    });
  });
});
