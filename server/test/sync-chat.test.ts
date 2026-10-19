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
import { direktChatId, familienchatId, lesestandId, uuidAusSchluessel } from '../src/sync/entities/chat-ids.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const actor = (role: Role, userId: string): Actor => ({ role, userId });

/** Konversation anlegen/ändern (neue Konversationen sind immer verschlüsselt, `e1`). */
const upsertK = (id: string, fields: Json, baseRev = 0, opId?: string) => upsert('konversation', id, fields, baseRev, opId);
/** Verschlüsselte Hülle `e1:` (nur die Form zählt für den Server; der Marker macht den Text im Test auffindbar). */
const E1 = (marker: string) => `e1:${marker.replace(/[^A-Za-z0-9_-]/g, '_')}${'A'.repeat(160)}`;

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
    const mitglieder = [actor('admin', ADMIN), actor('parent', 'u-p'), actor('child', A), actor('child', B)];
    // Familienchat: ausdrücklich alle Mitglieder mit Sicht (keine Mehrdeutigkeit)
    expect(usersThatMayRead(konversationEntity.rules, familie, mitglieder)).toEqual([ADMIN, 'u-p', A, B]);
  });

  it('Benachrichtigung: privat nur an Teilnehmer (keine Rollen)', () => {
    expect(rolesThatMayRead(konversationEntity.rules, privat)).toEqual([]);
    // je Person über mayRead gefiltert: nur Teilnehmer, Admin und Eltern nie; Nichtmitglieder gar nicht
    expect(usersThatMayRead(konversationEntity.rules, privat, [actor('admin', ADMIN), actor('parent', 'u-p'), actor('child', A), actor('child', B), actor('child', 'u-x')])).toEqual([A, B]);
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
    for (const d of [fam.admin, fam.parent, fam.child]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const revOf = async (table: 'konversationen' | 'nachrichten' | 'lesestand', id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);
  const rejectedOf = (res: { json: Json }) => res.json.rejected as Array<{ opId: string; code: string }>;
  const codes = (res: { json: Json }) => rejectedOf(res).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);

  async function familienchat(by: Device = fam.admin): Promise<string> {
    const id = familienchatId(fam.familyId);
    const res = await by.sync([upsertK(id, { art: 'family' })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  async function direkt(by: Device, other: Device): Promise<string> {
    const id = direktChatId(by.userId, other.userId);
    const res = await by.sync([upsertK(id, { art: 'direct', teilnehmer: [by.userId, other.userId] })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  async function gruppe(by: Device, members: Device[], titel = 'p1:Gruppe'): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsertK(id, { art: 'group', titel, teilnehmer: [by.userId, ...members.map((m) => m.userId)] })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  const nachricht = async (by: Device, konv: string, text = E1('Hallo'), extra: Json = {}) => {
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
      const zweiter = await fam.admin.sync([upsertK(randomUUID(), { art: 'family' })]);
      expect(codes(zweiter)).toEqual(['invalid']); // andere ID als die abgeleitete: ungültig, nie ein Hinweis darauf, dass es ihn schon gibt
      // dieselbe ID noch einmal (zweites Gerät, gleiche Op): ohne Wirkung
      const noch = await fam.parent.sync([upsertK(id, { art: 'family' })]);
      expect(noch.json.rejected).toEqual([]);
      expect(await rows(sql`select count(*)::int as n from konversationen where art = 'family'`)).toEqual([{ n: 1 }]);
    });

    it('Familienchat hat weder Namen noch Teilnehmer, ist unveränderlich und nicht löschbar', async () => {
      expect(codes(await fam.admin.sync([upsertK(randomUUID(), { art: 'family', titel: 'x' })]))).toEqual(['invalid']);
      expect(codes(await fam.admin.sync([upsertK(randomUUID(), { art: 'family', teilnehmer: [fam.admin.userId] })]))).toEqual(['invalid']);
      const id = await familienchat();
      const rev = await revOf('konversationen', id);
      expect(codes(await fam.admin.sync([upsertK(id, { titel: 'Umbenannt' }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.admin.sync([remove('konversation', id, rev)]))).toEqual(['forbidden']);
    });

    it('neue Mitglieder sehen ihn und seinen Verlauf (alle aktiven Mitglieder implizit)', async () => {
      const id = await familienchat();
      const { id: mid } = await nachricht(fam.admin, id, E1('Willkommen'));
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
      expect(codes(await fam.admin.sync([upsert('nachricht', mid, { text: E1('geändert') }, rev)]))).toEqual(['forbidden']);
      expect((await fam.admin.sync([remove('nachricht', mid, rev)])).json.acked).toHaveLength(1);
    });
  });

  describe('Direktchats', () => {
    it('Admin sieht den Direktchat von Eltern und Kind nicht: nicht im Strom, Ändern/Löschen/Nachricht = not_found', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const { id: mid } = await nachricht(fam.child, konv, E1('GEHEIMER-TEXT'));
      expect(ids(await fam.parent.pull())).toEqual(expect.arrayContaining([konv, mid]));
      expect(ids(await fam.child.pull())).toEqual(expect.arrayContaining([konv, mid]));
      // auch ein Admin, der sinceRev 0 neu beginnt, bekommt nichts
      expect(await fam.admin.pull()).toEqual([]);
      const rev = await revOf('konversationen', konv);
      const mrev = await revOf('nachrichten', mid);
      const res = await fam.admin.sync([
        upsertK(konv, { titel: 'x' }, rev),
        remove('konversation', konv, rev),
        upsert('nachricht', mid, { text: E1('x') }, mrev),
        remove('nachricht', mid, mrev),
        upsert('nachricht', randomUUID(), { konversationId: konv, text: E1('Einschleusen') }),
        upsert('lesestand', lesestandId(konv, fam.admin.userId), { konversationId: konv, userId: fam.admin.userId, gelesenBis: '2026-10-19T08:00:00.000Z' }),
      ]);
      expect(codes(res)).toEqual(['not_found', 'not_found', 'not_found', 'not_found', 'not_found', 'not_found']);
      expect(JSON.stringify(res.json)).not.toContain('GEHEIMER-TEXT');
      expect(await rows(sql`select count(*)::int as n from nachrichten`)).toEqual([{ n: 1 }]);
    });

    it('je Paar genau ein Direktchat (auch mit vertauschter Reihenfolge); Teilnehmer werden sortiert gespeichert', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const zweiter = await fam.child.sync([upsertK(randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId] })]);
      expect(codes(zweiter)).toEqual(['invalid']);
      const [row] = await rows(sql`select teilnehmer from konversationen where id = ${konv}`);
      expect([...(row?.teilnehmer as string[])]).toEqual([fam.parent.userId, fam.child.userId].sort());
      // dieselbe ID von der anderen Seite (zweites Gerät, gleicher Paar-Schlüssel): ohne Wirkung
      const gleich = await fam.child.sync([upsertK(konv, { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId] })]);
      expect(gleich.json.rejected).toEqual([]);
      // anderes Paar geht
      await direkt(fam.child, fam.admin);
    });

    it('Prüfung bei der Anlage: Ersteller muss dabei sein, genau zwei, nur Familienmitglieder, kein Name', async () => {
      const ohneMich = await fam.child.sync([upsertK(direktChatId(fam.parent.userId, fam.admin.userId), { art: 'direct', teilnehmer: [fam.parent.userId, fam.admin.userId] })]);
      expect(codes(ohneMich)).toEqual(['forbidden']);
      const drei = await fam.child.sync([upsertK(randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId, fam.admin.userId] })]);
      expect(codes(drei)).toEqual(['invalid']);
      const allein = await fam.child.sync([upsertK(randomUUID(), { art: 'direct', teilnehmer: [fam.child.userId, fam.child.userId] })]);
      expect(codes(allein)).toEqual(['invalid']);
      const fremd = await fam.child.sync([upsertK(direktChatId(fam.child.userId, 'ffffffff-0000-4000-8000-0000000000aa'), { art: 'direct', teilnehmer: [fam.child.userId, 'ffffffff-0000-4000-8000-0000000000aa'] })]);
      expect(codes(fremd)).toEqual(['invalid_reference']);
      const mitName = await fam.child.sync([upsertK(direktChatId(fam.child.userId, fam.parent.userId), { art: 'direct', titel: 'p1:x', teilnehmer: [fam.child.userId, fam.parent.userId] })]);
      expect(codes(mitName)).toEqual(['invalid']);
      expect(await rows(sql`select count(*)::int as n from konversationen`)).toEqual([{ n: 0 }]);
    });

    it('Direktchat ist unveränderlich und wird nicht gelöscht', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const rev = await revOf('konversationen', konv);
      expect(codes(await fam.parent.sync([upsertK(konv, { teilnehmer: [fam.parent.userId, fam.admin.userId] }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([remove('konversation', konv, rev)]))).toEqual(['forbidden']);
    });
  });

  describe('Nachrichten', () => {
    it('Senden, Bearbeiten (Zeit setzt der Server), Löschen nur durch den Autor; opaker Text bleibt unverändert', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const text = E1('Hallo_html_https');
      const { id: erste } = await nachricht(fam.child, konv, E1('Frage'));
      const { id, res } = await nachricht(fam.parent, konv, text, { antwortAuf: erste });
      expect(res.json.rejected).toEqual([]);
      const [row] = await rows(sql`select text, autor_id, bearbeitet_at, antwort_auf from nachrichten where id = ${id}`);
      expect(row).toMatchObject({ text, autor_id: fam.parent.userId, bearbeitet_at: null });
      const change = (await fam.child.pull()).find((c) => c.id === id);
      expect(change?.fields).toMatchObject({ text, autorId: fam.parent.userId, konversationId: konv, bearbeitetAt: null });
      expect(change?.fields.createdAt).toBeTruthy();

      const rev = await revOf('nachrichten', id);
      expect(codes(await fam.child.sync([upsert('nachricht', id, { text: E1('Gefälscht') }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([remove('nachricht', id, rev)]))).toEqual(['forbidden']);
      world.advance(60_000);
      expect((await fam.parent.sync([upsert('nachricht', id, { text: E1('neu') }, rev)])).json.acked).toHaveLength(1);
      const [edited] = await rows(sql`select text, bearbeitet_at from nachrichten where id = ${id}`);
      expect(edited?.text).toBe(E1('neu'));
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
      expect((await nachricht(fam.admin, konv, 'e1:' + 'x'.repeat(MAX_NACHRICHT - 3))).res.json.acked).toHaveLength(1);
      expect(codes((await nachricht(fam.admin, konv, 'x'.repeat(MAX_NACHRICHT + 1))).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.admin, konv, '')).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.admin, konv, 'a\u0000b')).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.admin, konv, E1('x'), { autorId: fam.child.userId })).res)).toEqual(['invalid']);
    });

    it(`Rate: höchstens ${NACHRICHTEN_PRO_MINUTE} Nachrichten je Person und Minute`, async () => {
      const konv = await familienchat();
      const batch = (n: number) => Array.from({ length: n }, () => upsert('nachricht', randomUUID(), { konversationId: konv, text: E1('x') }));
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
      const id = lesestandId(konv, fam.child.userId);
      const ok = await fam.child.sync([upsert('lesestand', id, { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      expect(ok.json.rejected).toEqual([]);
      // der Elternteil ist Teilnehmer, sieht die Zeile des Kindes aber nicht
      expect(ids(await fam.parent.pull(), 'lesestand')).toEqual([]);
      expect(ids(await fam.child.pull(), 'lesestand')).toEqual([id]);
      const rev = await revOf('lesestand', id);
      expect(codes(await fam.parent.sync([upsert('lesestand', id, { gelesenBis: '2026-10-19T09:00:00.000Z' }, rev)]))).toEqual(['not_found']);
      const fuerAndere = await fam.parent.sync([upsert('lesestand', lesestandId(konv, fam.child.userId), { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      // die Zeile des Kindes (feste ID) gibt es für die andere Person nicht
      expect(codes(fuerAndere)).toEqual(['not_found']);
      // Fortschreiben der eigenen Zeile
      expect((await fam.child.sync([upsert('lesestand', id, { gelesenBis: '2026-10-19T09:00:00.000Z' }, rev)])).json.acked).toHaveLength(1);
    });

    it('im Familienchat sieht auch der Admin den Lesestand anderer nicht', async () => {
      const konv = await familienchat();
      await fam.child.sync([upsert('lesestand', lesestandId(konv, fam.child.userId), { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' })]);
      expect(ids(await fam.admin.pull(), 'lesestand')).toEqual([]);
    });

    it('eine Zeile je Person und Konversation (feste ID): dieselbe ID noch einmal ist eine Wiederholung, eine andere ID ist ungültig', async () => {
      const konv = await familienchat();
      const mk = (id: string) => upsert('lesestand', id, { konversationId: konv, userId: fam.child.userId, gelesenBis: '2026-10-19T08:00:00.000Z' });
      const fest = lesestandId(konv, fam.child.userId);
      expect((await fam.child.sync([mk(fest)])).json.rejected).toEqual([]);
      expect((await fam.child.sync([mk(fest)])).json.rejected).toEqual([]);
      expect(codes(await fam.child.sync([mk(randomUUID())]))).toEqual(['invalid']);
      expect(await rows(sql`select count(*)::int as n from lesestand`)).toEqual([{ n: 1 }]);
    });
  });

  describe('Gruppen', () => {
    it('nur Teilnehmer sehen sie; Unbeteiligte (auch Admin) erfahren nichts, auch nicht bei Änderungen', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      await nachricht(fam.child, konv);
      expect(await fam.admin.pull()).toEqual([]);
      await fam.parent.sync([upsertK(konv, { titel: 'p1:Neu' }, await revOf('konversationen', konv))], { sinceRev: 0 });
      expect(await fam.admin.pull()).toEqual([]);
      const snapshot = await (await fam.admin.sync([], { sinceRev: 0 })).json;
      expect(JSON.stringify(snapshot)).not.toContain(konv);
    });

    it('Teilnehmer hinzufügen: die neue Person bekommt Konversation und Verlauf; entfernen: nur sie bekommt den hidden-Tombstone', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const { id: mid } = await nachricht(fam.parent, konv, E1('Vor dem Beitritt'));
      await fam.child.pull();
      expect(await fam.admin.pull()).toEqual([]);

      // Admin wird aufgenommen
      const teilnehmer = [fam.parent.userId, fam.child.userId, fam.admin.userId];
      expect((await fam.parent.sync([upsertK(konv, { teilnehmer }, await revOf('konversationen', konv))])).json.acked).toHaveLength(1);
      const joined = await fam.admin.pull();
      expect(ids(joined, 'konversation')).toEqual([konv]);
      expect(ids(joined, 'nachricht')).toEqual([mid]);

      // Kind verlässt die Gruppe (entfernt sich selbst)
      await fam.child.pull();
      const rest = [fam.parent.userId, fam.admin.userId];
      expect((await fam.child.sync([upsertK(konv, { teilnehmer: rest }, await revOf('konversationen', konv))])).json.acked).toHaveLength(1);
      const childView = await fam.child.pull();
      expect(childView).toEqual([expect.objectContaining({ entity: 'konversation', id: konv, tombstone: true, hidden: true, fields: {} })]);
      // wer nie drin war, bekommt keinen hidden-Tombstone: ein Außenstehender sieht nichts
      const outsider = await extraMember(world, fam.admin, 'child', 'aussen@example.org');
      expect(await outsider.pull()).toEqual([]);
      // das Kind kann nicht mehr schreiben und nichts mehr ändern
      expect(codes(await fam.child.sync([upsert('nachricht', randomUUID(), { konversationId: konv, text: E1('x') })]))).toEqual(['not_found']);
      // Admin (inzwischen Teilnehmer) und Elternteil sehen die Gruppe weiter
      expect(ids(await fam.admin.pull(), 'konversation')).toEqual([konv]);
      expect(await rows(sql`select teilnehmer from konversationen where id = ${konv}`)).toEqual([{ teilnehmer: [...rest].sort() }]);
    });

    it('Gruppe: Teilnehmer ändern den Namen; löschen nur die anlegende Person; Obergrenze 20 Teilnehmer', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      await fam.child.pull();
      const rev = await revOf('konversationen', konv);
      expect((await fam.child.sync([upsertK(konv, { titel: 'p1:Von Kind' }, rev)])).json.acked).toHaveLength(1);
      expect(codes(await fam.child.sync([remove('konversation', konv, rev + 1)]))).toEqual(['forbidden']);
      expect((await fam.parent.sync([remove('konversation', konv, rev + 1)])).json.acked).toHaveLength(1);
      // Tombstone erreicht die Teilnehmer, nicht den Admin
      expect((await fam.child.pull()).filter((c) => c.id === konv).map((c) => c.tombstone)).toEqual([true]);
      expect(await fam.admin.pull()).toEqual([]);

      const viele = Array.from({ length: 20 }, () => randomUUID());
      const zuViele = await fam.parent.sync([upsertK(randomUUID(), { art: 'group', teilnehmer: [fam.parent.userId, ...viele] })]);
      expect(codes(zuViele)).toEqual(['invalid']);
    });

    it('Kinder dürfen Gruppen anlegen; Gruppe mit weniger als zwei Personen nicht; Obergrenze je Person', async () => {
      await gruppe(fam.child, [fam.parent, fam.admin]);
      expect(codes(await fam.child.sync([upsertK(randomUUID(), { art: 'group', teilnehmer: [fam.child.userId] })]))).toEqual(['invalid']);
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
      await nachricht(fam.parent, konv, E1('GEHEIM'));
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
      const { id: famMsg } = await nachricht(opa, fk, E1('Hallo'));
      const ls = lesestandId(g3, opa.userId);
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
      expect(byId(famMsg)[0]?.fields).toMatchObject({ autorId: null, text: E1('Hallo') });
      expect(await rows(sql`select count(*)::int as n from lesestand where user_id = ${opa.userId}`)).toEqual([{ n: 0 }]);
      // Admin sieht von all dem nichts Privates
      expect(ids(await fam.admin.pull()).filter((i) => [dm, g2, g3].includes(i))).toEqual([]);
      // die entfernte Person ist kein gültiger Teilnehmer mehr
      const wieder = await fam.child.sync([upsertK(direktChatId(fam.child.userId, opa.userId), { art: 'direct', teilnehmer: [fam.child.userId, opa.userId] })]);
      expect(codes(wieder)).toEqual(['invalid_reference']);
    });
  });

  describe('Korrekturrunde: feste IDs, Verlauf, Grenzen', () => {
    const lsFelder = (konv: string, user: string, bis = '2026-10-19T08:00:00.000Z') => ({ konversationId: konv, userId: user, gelesenBis: bis });

    it('Known-Answer: abgeleitete IDs stimmen mit denen der App überein (feste Vektoren)', () => {
      const A = 'aaaaaaaa-0000-4000-8000-000000000001';
      const B = 'bbbbbbbb-0000-4000-8000-000000000002';
      expect(uuidAusSchluessel('probe')).toBe('81574b3c-f2b4-59af-819d-78a1be8fc7d4');
      expect(familienchatId('ffffffff-0000-4000-8000-00000000000f')).toBe('d75c7bdb-240f-5445-80e0-1a0e0cebb5a5');
      expect(direktChatId(A, B)).toBe('c410b67b-94c8-5ea8-bb7b-782f4c0ebcbc');
      expect(direktChatId(B, A)).toBe('c410b67b-94c8-5ea8-bb7b-782f4c0ebcbc');
      expect(lesestandId('k1', A)).toBe('9a36a4d2-7fa9-5a56-9d92-e8db827e177c');
    });

    it('Squatting: nur die abgeleitete ID ist gültig (immer invalid, kein Hinweis auf vorhandene Datensätze)', async () => {
      // Familienchat mit der ID einer anderen Familie, Direktchat mit der ID eines anderen Paares, Lesestand mit fremder ID, Gruppe mit reserviertem Nibble 5
      const fremdPaar = direktChatId(fam.parent.userId, fam.admin.userId);
      expect(codes(await fam.child.sync([upsertK(familienchatId('ffffffff-0000-4000-8000-00000000000f'), { art: 'family' })]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([upsertK(fremdPaar, { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([upsertK(uuidAusSchluessel('egal'), { art: 'group', teilnehmer: [fam.child.userId, fam.parent.userId] })]))).toEqual(['invalid']);
      // das Paar Eltern/Admin selbst kann das Kind auch mit der richtigen ID nicht anlegen (nicht dabei)
      expect(codes(await fam.child.sync([upsertK(fremdPaar, { art: 'direct', teilnehmer: [fam.parent.userId, fam.admin.userId] })]))).toEqual(['forbidden']);
      // ... und belegen kann es die ID des Paares auch nicht vorab: das Paar legt später seinen Chat an
      expect(await direkt(fam.parent, fam.admin)).toBe(fremdPaar);
      const konv = await familienchat();
      expect(codes(await fam.child.sync([upsert('lesestand', randomUUID(), lsFelder(konv, fam.child.userId))]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([upsert('lesestand', lesestandId(konv, fam.parent.userId), lsFelder(konv, fam.child.userId))]))).toEqual(['invalid']);
    });

    it('Direktchat und Lesestand mit fester ID leben nach dem Löschen durch erneutes Anlegen wieder auf (Kinder bleiben gelöscht)', async () => {
      const konv = await direkt(fam.child, fam.parent);
      const { id: mid } = await nachricht(fam.parent, konv, E1('alt'));
      const lid = lesestandId(konv, fam.child.userId);
      await fam.child.sync([upsert('lesestand', lid, lsFelder(konv, fam.child.userId))]);
      // wie nach "Person entfernt": Konversation, Nachricht und Lesestand sind Tombstones
      await world.db.execute(sql`update nachrichten set deleted_at = now(), text = '', rev = rev + 10 where id = ${mid}`);
      await world.db.execute(sql`update lesestand set deleted_at = now(), rev = rev + 10 where id = ${lid}`);
      await world.db.execute(sql`update konversationen set deleted_at = now(), rev = rev + 10 where id = ${konv}`);
      const neu = upsertK(konv, { art: 'direct', teilnehmer: [fam.child.userId, fam.parent.userId] });
      expect((await fam.child.sync([neu])).json.acked).toEqual([neu.opId]);
      expect((await rows(sql`select deleted_at from konversationen where id = ${konv}`))[0]?.deleted_at).toBeNull();
      const lneu = upsert('lesestand', lid, lsFelder(konv, fam.child.userId, '2026-10-19T09:00:00.000Z'));
      expect((await fam.child.sync([lneu])).json.acked).toEqual([lneu.opId]);
      expect((await rows(sql`select deleted_at from lesestand where id = ${lid}`))[0]?.deleted_at).toBeNull();
      // die alte Nachricht bleibt gelöscht, der Verlauf beginnt neu
      expect((await rows(sql`select deleted_at from nachrichten where id = ${mid}`))[0]?.deleted_at).not.toBeNull();
      const { res } = await nachricht(fam.parent, konv, E1('neu'));
      expect(res.json.rejected).toEqual([]);
      const sicht = await fam.parent.pull();
      expect(ids(sicht, 'konversation')).toContain(konv);
      // eine Gruppe wird nicht wiederbelebt (ihre ID ist zufällig)
      const g = await gruppe(fam.child, [fam.parent]);
      await fam.child.sync([remove('konversation', g, await revOf('konversationen', g))]);
      expect(codes(await fam.child.sync([upsertK(g, { art: 'group', teilnehmer: [fam.child.userId, fam.parent.userId] })]))).toEqual(['deleted']);
    });

    it('Aufnehmen in eine Gruppe schreibt keine Nachricht neu; die neue Person bekommt nur die jüngsten 500 (Historie), die anderen nichts doppelt', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      await world.db.execute(sql`
        insert into nachrichten (id, family_id, konversation_id, text, rev, field_revs, created_at)
        select gen_random_uuid(), ${fam.familyId}::uuid, ${konv}::uuid, 'p1:n' || g, 1, '{}'::jsonb, now() - (600 - g) * interval '1 second' from generate_series(1, 600) g`);
      const maxVorher = await rows(sql`select max(rev)::int as r, count(*)::int as n from nachrichten where konversation_id = ${konv}`);
      await fam.parent.pull();
      expect((await fam.parent.sync([upsertK(konv, { teilnehmer: [fam.parent.userId, fam.child.userId, fam.admin.userId] }, await revOf('konversationen', konv))])).json.acked).toHaveLength(1);
      expect(await rows(sql`select max(rev)::int as r, count(*)::int as n from nachrichten where konversation_id = ${konv}`)).toEqual(maxVorher);
      const kind = fam.child;
      await kind.pull();
      const bobby = await extraMember(world, fam.admin, 'child', 'neu2@example.org');
      await bobby.pull();
      const rev = await revOf('konversationen', konv);
      expect((await fam.parent.sync([upsertK(konv, { teilnehmer: [fam.parent.userId, fam.child.userId, fam.admin.userId, bobby.userId] }, rev)])).json.acked).toHaveLength(1);
      const verlauf = (await bobby.pull()).filter((c) => c.entity === 'nachricht');
      expect(verlauf).toHaveLength(500);
      // keiner der anderen bekommt die Nachrichten noch einmal
      expect((await kind.pull()).filter((c) => c.entity === 'nachricht')).toEqual([]);
    });

    it('Obergrenzen: 20 000 Nachrichten je Konversation, 10 Teilnehmerwechsel je Person und Minute, Text-Kontingent je Stunde', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      await world.db.execute(sql`
        insert into nachrichten (id, family_id, konversation_id, text, rev, field_revs, created_at)
        select gen_random_uuid(), ${fam.familyId}::uuid, ${konv}::uuid, 'p1:x', 1, '{}'::jsonb, now() - interval '2 days' from generate_series(1, 20000)`);
      expect(codes((await nachricht(fam.child, konv)).res)).toEqual(['limit_reached']);
      await world.db.execute(sql`delete from nachrichten where konversation_id = ${konv}`);

      // Teilnehmerwechsel
      let rev = await revOf('konversationen', konv);
      const mit = [fam.parent.userId, fam.child.userId];
      const ohne = [fam.parent.userId, fam.child.userId, fam.admin.userId];
      let letztes: string[] = [];
      for (let i = 0; i < 11; i++) {
        const res = await fam.parent.sync([upsertK(konv, { teilnehmer: i % 2 === 0 ? ohne : mit }, rev)]);
        letztes = codes(res);
        if (letztes.length === 0) rev = await revOf('konversationen', konv);
      }
      expect(letztes).toEqual(['limit_reached']);
      world.advance(61_000);
      expect((await fam.parent.sync([upsertK(konv, { teilnehmer: mit }, rev)])).json.rejected).toEqual([]);
    });

    it('Text-Kontingent: je Person höchstens 1 MiB in der Stunde', async () => {
      const konv = await familienchat();
      const text = 'e1:' + 'A'.repeat(14_000); // ca. 14 KB
      const batch = (n: number) => Array.from({ length: n }, () => upsert('nachricht', randomUUID(), { konversationId: konv, text }));
      expect((await fam.child.sync(batch(50))).json.rejected).toEqual([]);
      world.advance(61_000);
      const zweite = await fam.child.sync(batch(40));
      // 50 x 14 KB = 700 KB, danach passen noch rund 24 weitere hinein
      expect(codes(zweite).length).toBeGreaterThan(10);
      expect(new Set(codes(zweite))).toEqual(new Set(['limit_reached']));
      // andere Person unberührt, nach einer Stunde wieder frei
      expect((await fam.parent.sync(batch(5))).json.rejected).toEqual([]);
      world.advance(3_700_000);
      expect((await fam.child.sync(batch(5))).json.rejected).toEqual([]);
    });

    it('Bearbeiten entfernt den alten Text aus dem Änderungsprotokoll', async () => {
      const konv = await familienchat();
      const { id } = await nachricht(fam.child, konv, E1('ERSTER-TEXT'));
      world.advance(1000);
      expect((await fam.child.sync([upsert('nachricht', id, { text: E1('ZWEITER-TEXT') }, await revOf('nachrichten', id))])).json.acked).toHaveLength(1);
      world.advance(1000);
      expect((await fam.child.sync([upsert('nachricht', id, { text: E1('DRITTER-TEXT') }, await revOf('nachrichten', id))])).json.acked).toHaveLength(1);
      const log = JSON.stringify(await rows(sql`select changes from change_log where entity = 'nachricht' and entity_id = ${id} and rev < (select rev from nachrichten where id = ${id})`));
      expect(log).not.toContain('ERSTER-TEXT');
      expect(log).not.toContain('ZWEITER-TEXT');
    });

    it('Nachrichten: passende Hülle der Konversation, Antwort nur auf eine Nachricht derselben Konversation, Version unveränderlich', async () => {
      const a = await gruppe(fam.parent, [fam.child]);
      const b = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes((await nachricht(fam.parent, a, 'ohne Präfix')).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.parent, a, 'e1:QUJD')).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.parent, a, 'p1:Klartext')).res)).toEqual(['invalid']);
      const { id: ma } = await nachricht(fam.parent, a, E1('in A'));
      expect(codes((await nachricht(fam.parent, b, E1('Antwort'), { antwortAuf: ma })).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.parent, a, E1('Antwort'), { antwortAuf: ma })).res)).toEqual([]);
      expect(codes((await nachricht(fam.parent, a, E1('Antwort'), { antwortAuf: randomUUID() })).res)).toEqual(['invalid']);
      // Bearbeiten ohne Hülle ist ebenfalls ungültig
      expect(codes(await fam.parent.sync([upsert('nachricht', ma, { text: 'Klartext' }, await revOf('nachrichten', ma))]))).toEqual(['invalid']);
      // Konversationen gibt es nur verschlüsselt: p1 und unbekannte Versionen lassen sich nicht anlegen, die Version nachträglich nicht ändern
      for (const enc of ['p1', 'e9']) {
        expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'group', encVersion: enc, teilnehmer: [fam.parent.userId, fam.child.userId] })]))).toEqual(['invalid']);
      }
      expect((await rows(sql`select enc_version from konversationen where id = ${a}`))[0]?.enc_version).toBe('e1');
      expect(codes(await fam.parent.sync([upsertK(a, { encVersion: 'p1' }, await revOf('konversationen', a))]))).toEqual(['invalid']);
    });

    it('Altbestand p1: lesbar, aber der Server nimmt nichts Neues mehr an (Nachricht, Bearbeiten); Wiederbeleben setzt die Hülle nicht neu', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const { id } = await nachricht(fam.parent, konv, E1('vorher'));
      // Altbestand simulieren: die Zeile stammt aus einer Zeit, in der Klartext-Chats noch angelegt werden durften
      await world.db.execute(sql`update konversationen set enc_version = 'p1' where id = ${konv}`);
      await world.db.execute(sql`update nachrichten set text = 'p1:alt' where id = ${id}`);
      expect(codes((await nachricht(fam.parent, konv, E1('neu'))).res)).toEqual(['invalid']);
      expect(codes((await nachricht(fam.parent, konv, 'p1:neu')).res)).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('nachricht', id, { text: 'p1:geändert' }, await revOf('nachrichten', id))]))).toEqual(['invalid']);
      // Direktchat gelöscht (Person entfernt) und neu angelegt: bleibt p1, wird nicht heimlich zu e1
      await world.db.execute(sql`update konversationen set deleted_at = now(), rev = rev + 1 where id = ${konv}`);
      const neuAnlage = await fam.parent.sync([upsertK(konv, { art: 'direct', teilnehmer: [fam.parent.userId, fam.child.userId] })]);
      expect(neuAnlage.json.rejected).toEqual([]);
      expect((await rows(sql`select enc_version from konversationen where id = ${konv}`))[0]?.enc_version).toBe('p1');
    });

    it('Lesestand geht nie zurück', async () => {
      const konv = await familienchat();
      const id = lesestandId(konv, fam.child.userId);
      expect((await fam.child.sync([upsert('lesestand', id, lsFelder(konv, fam.child.userId, '2026-10-19T09:00:00.000Z'))])).json.rejected).toEqual([]);
      expect((await fam.child.sync([upsert('lesestand', id, { gelesenBis: '2026-10-19T08:00:00.000Z' }, await revOf('lesestand', id))])).json.rejected).toEqual([]);
      expect(new Date((await rows(sql`select gelesen_bis from lesestand where id = ${id}`))[0]?.gelesen_bis as string).toISOString()).toBe('2026-10-19T09:00:00.000Z');
      expect((await fam.child.sync([upsert('lesestand', id, { gelesenBis: '2026-10-19T10:00:00.000Z' }, await revOf('lesestand', id))])).json.acked).toHaveLength(1);
      expect(new Date((await rows(sql`select gelesen_bis from lesestand where id = ${id}`))[0]?.gelesen_bis as string).toISOString()).toBe('2026-10-19T10:00:00.000Z');
    });

    it('entfernt, dann Gruppe gelöscht: wer die Sicht verloren hatte und offline war, bekommt trotzdem den hidden-Tombstone', async () => {
      const konv = await gruppe(fam.child, [fam.parent, fam.admin]);
      await fam.admin.pull();
      await nachricht(fam.child, konv, E1('Text'));
      const rev = await revOf('konversationen', konv);
      expect((await fam.child.sync([upsertK(konv, { teilnehmer: [fam.child.userId, fam.parent.userId] }, rev)])).json.acked).toHaveLength(1);
      expect((await fam.child.sync([remove('konversation', konv, await revOf('konversationen', konv))])).json.acked).toHaveLength(1);
      const spaeter = await fam.admin.pull();
      expect(spaeter.filter((c) => c.id === konv)).toEqual([expect.objectContaining({ tombstone: true, hidden: true })]);
      // Unbeteiligte erfahren auch jetzt nichts
      const aussen = await extraMember(world, fam.admin, 'child', 'aussen2@example.org');
      await aussen.pull();
      expect(JSON.stringify(await aussen.sync([], { sinceRev: 0 }).then((r) => r.json))).not.toContain(konv);
    });

    it('Bestätigt eine Person ihren Lesestand, erfahren das nur ihre Geräte (WebSocket) und niemand sonst', async () => {
      const konv = await direkt(fam.parent, fam.child);
      const { port } = world.app.server.address() as AddressInfo;
      const verbinden = async (d: Device) => {
        const messages: Json[] = [];
        const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': '203.0.113.52' } });
        sockets.push(ws);
        ws.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8'))));
        await new Promise<void>((resolve, reject) => {
          ws.once('open', () => resolve());
          ws.once('error', reject);
        });
        const ticket = (await d.client.post('/api/v1/ws-ticket')).json.ticket as string;
        ws.send(JSON.stringify({ type: 'auth', ticket }));
        for (let i = 0; i < 40 && !messages.some((m) => m.type === 'ready'); i++) await wait(50);
        return messages;
      };
      const eltern = await verbinden(fam.parent);
      const kind = await verbinden(fam.child);
      const admin = await verbinden(fam.admin);
      await fam.child.sync([upsert('lesestand', lesestandId(konv, fam.child.userId), lsFelder(konv, fam.child.userId))]);
      await wait(150);
      const revs = (m: Json[]) => m.filter((x) => x.type === 'rev').map((x) => x.rev);
      expect(revs(kind)).toHaveLength(1);
      expect(revs(eltern)).toEqual([]);
      expect(revs(admin)).toEqual([]);
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
        upsert('nachricht', randomUUID(), { konversationId: konvId, text: E1('x') }),
        upsert('lesestand', lesestandId(konvId, fam.admin.userId), { konversationId: konvId, userId: fam.admin.userId, gelesenBis: '2026-10-19T08:00:00.000Z' }),
        upsertK(konvId, { titel: 'x' }, 5),
        remove('konversation', konvId, 5),
        upsertK(konvId, { art: 'direct', teilnehmer: [fam.admin.userId, fam.child.userId] }),
      ]);
      // die fünfte Op belegt eine fremde ID: ungültig (die ID ist nicht die aus dem Paar abgeleitete), nie ein Hinweis auf den fremden Datensatz
      expect(codes(res)).toEqual(['not_found', 'not_found', 'not_found', 'not_found', 'invalid']);
      // Verweis auf ein Mitglied einer fremden Familie
      expect(codes(await fam.admin.sync([upsertK(direktChatId(fam.admin.userId, userId), { art: 'direct', teilnehmer: [fam.admin.userId, userId] })]))).toEqual(['invalid_reference']);
      await world.db.execute(sql`delete from families where name = 'Fremd2'`);
      await world.db.execute(sql`delete from users where email = 'fremd2@example.org'`);

      // Obergrenze je Person (100): ab der 101. Gruppe limit_reached
      const mk = () => upsertK(randomUUID(), { art: 'group', teilnehmer: [fam.child.userId, fam.parent.userId] });
      for (let i = 0; i < 100; i += 50) expect((await fam.child.sync(Array.from({ length: 50 }, mk))).json.rejected).toEqual([]);
      expect(codes(await fam.child.sync([mk()]))).toEqual(['limit_reached']);
    });
  });
});
