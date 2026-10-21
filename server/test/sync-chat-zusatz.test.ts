// Chat-Erweiterungen im Sync: Reaktionen, Umfrage-Stimmen und angeheftete Nachrichten (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6c).
// Der Server sieht nur undurchsichtige e1-Hüllen (Form, Größe); geprüft werden Teilnehmer-Grenze, Besitzerprinzip, feste IDs, Kaskade, Limits.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { familienchatId, pinId, reaktionId, stimmeId, uuidAusSchluessel } from '../src/sync/entities/chat-ids.js';
import { pinEntity, reaktionEntity, stimmeEntity, MAX_PINS } from '../src/sync/entities/chat-zusatz.js';
import type { Role } from '../src/auth/types.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const E1 = (marker: string) => `e1:${marker.replace(/[^A-Za-z0-9_-]/g, '_')}${'A'.repeat(160)}`;
const actor = (role: Role, userId: string): Actor => ({ role, userId });

describe('Chat-Erweiterungen: feste IDs (Known-Answer wie in der App)', () => {
  it('leitet die IDs aus Nachricht und Person ab', () => {
    const n = '11111111-1111-4111-8111-111111111111';
    const u = '22222222-2222-4222-8222-222222222222';
    expect(reaktionId(n, u)).toBe(uuidAusSchluessel(`reaktion:${n}:${u}`));
    expect(reaktionId(n.toUpperCase(), u.toUpperCase())).toBe(reaktionId(n, u));
    expect(new Set([reaktionId(n, u), stimmeId(n, u), pinId(n)]).size).toBe(3);
    // Known-Answer: muss exakt app/test/chat_zusatz_test.dart entsprechen
    expect(reaktionId(n, u)).toBe(KAT.reaktion);
    expect(stimmeId(n, u)).toBe(KAT.stimme);
    expect(pinId(n)).toBe(KAT.pin);
  });
});
const KAT = { reaktion: '1f6d9a38-b4c2-5edf-9a56-3634e15796d7', stimme: 'a1a4a139-9cf0-5c6c-bb21-e656b8a3aae7', pin: '386a4ae1-93c5-5827-9be5-6f547d343bc6' };

describe('Chat-Erweiterungen: Rechte-Modell (Regeltabelle)', () => {
  const A = 'u-a';
  const B = 'u-b';
  const privat = (owner: string | null): Facts => ({ audience: 'family', ownerId: owner, participants: [A, B] });
  const familie = (owner: string | null): Facts => ({ audience: 'family', ownerId: owner });

  it('Reaktion und Stimme: Teilnehmer lesen, nur die eigene Zeile anlegen, ändern, löschen; Unbeteiligte (auch Admin) sehen nichts', () => {
    for (const def of [reaktionEntity, stimmeEntity]) {
      for (const role of ['admin', 'parent', 'child'] as const) {
        expect(mayRead(def.rules, actor(role, B), privat(A)), `${def.name} ${role} Teilnehmer`).toBe(true);
        expect(mayRead(def.rules, actor(role, 'u-x'), privat(A)), `${def.name} ${role} Fremder`).toBe(false);
        expect(authorize(def.rules, 'create', actor(role, A), privat(A), ['inhalt'])).toBe('ok');
        expect(authorize(def.rules, 'create', actor(role, B), privat(A), ['inhalt'])).toBe('forbidden');
        expect(authorize(def.rules, 'update', actor(role, A), privat(A), ['inhalt'])).toBe('ok');
        expect(authorize(def.rules, 'update', actor(role, B), privat(A), ['inhalt'])).toBe('forbidden');
        expect(authorize(def.rules, 'update', actor(role, 'u-x'), privat(A), ['inhalt'])).toBe('not_found');
        expect(authorize(def.rules, 'delete', actor(role, B), privat(A))).toBe('forbidden');
        expect(authorize(def.rules, 'delete', actor(role, A), privat(A))).toBe('ok');
        // im Familienchat lesen alle, ändern aber nur die eigene
        expect(mayRead(def.rules, actor(role, 'u-x'), familie(A))).toBe(true);
        expect(authorize(def.rules, 'update', actor(role, 'u-x'), familie(A), ['inhalt'])).toBe('forbidden');
      }
      // Bezüge sind unveränderlich
      expect(authorize(def.rules, 'update', actor('parent', A), privat(A), ['nachrichtId'])).toBe('forbidden');
    }
  });

  it('Pin: Teilnehmer heften an, Eltern lösen alles, Kinder nur ihre eigenen, nie ändern; Unbeteiligte sehen nichts', () => {
    for (const role of ['admin', 'parent', 'child'] as const) {
      expect(mayRead(pinEntity.rules, actor(role, B), privat(A))).toBe(true);
      expect(mayRead(pinEntity.rules, actor(role, 'u-x'), privat(A))).toBe(false);
      expect(authorize(pinEntity.rules, 'create', actor(role, B), privat(B), [])).toBe('ok');
      expect(authorize(pinEntity.rules, 'create', actor(role, 'u-x'), privat(B), [])).toBe('forbidden');
      expect(authorize(pinEntity.rules, 'update', actor(role, A), privat(A), ['konversationId'])).toBe('forbidden');
    }
    expect(authorize(pinEntity.rules, 'delete', actor('parent', B), privat(A))).toBe('ok');
    expect(authorize(pinEntity.rules, 'delete', actor('admin', B), privat(A))).toBe('ok');
    expect(authorize(pinEntity.rules, 'delete', actor('child', B), privat(A))).toBe('forbidden');
    expect(authorize(pinEntity.rules, 'delete', actor('child', A), privat(A))).toBe('ok');
    expect(authorize(pinEntity.rules, 'delete', actor('parent', 'u-x'), privat(A))).toBe('not_found');
  });

  it('Reaktionen, Stimmen und Pins wecken nie per Push', () => {
    for (const def of [reaktionEntity, stimmeEntity, pinEntity]) expect(def.noWake).toBe(true);
  });
});

describe.each(backends)('Reaktionen, Stimmen, Pins im Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
    fam = await createFamily(world);
  }, 180_000);
  afterAll(async () => {
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    for (const d of [fam.admin, fam.parent, fam.child]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const codes = (res: { json: Json }) => (res.json.rejected as Array<{ code: string }>).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);
  const revOf = async (table: string, id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);

  async function gruppe(by: Device, members: Device[]): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('konversation', id, { art: 'group', teilnehmer: [by.userId, ...members.map((m) => m.userId)] })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  async function nachricht(by: Device, konv: string): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('nachricht', id, { konversationId: konv, text: E1('Hallo') })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  const reaktion = (by: Device, konv: string, nid: string, inhalt = E1('r'), userId = by.userId) =>
    upsert('reaktion', reaktionId(nid, userId), { konversationId: konv, nachrichtId: nid, userId, inhalt });
  const stimme = (by: Device, konv: string, nid: string, inhalt = E1('s'), userId = by.userId) =>
    upsert('stimme', stimmeId(nid, userId), { konversationId: konv, nachrichtId: nid, userId, inhalt });
  const pin = (konv: string, nid: string) => upsert('pin', pinId(nid), { konversationId: konv, nachrichtId: nid });

  describe('Reaktion', () => {
    it('Teilnehmer reagieren und sehen sich gegenseitig, Unbeteiligte (auch Admin) bekommen nichts und können nichts anlegen', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      expect((await fam.child.sync([reaktion(fam.child, konv, nid)])).json.acked).toHaveLength(1);
      expect((await fam.parent.sync([reaktion(fam.parent, konv, nid, E1('x'))])).json.acked).toHaveLength(1);
      const sicht = await fam.parent.pull();
      expect(ids(sicht, 'reaktion').sort()).toEqual([reaktionId(nid, fam.child.userId), reaktionId(nid, fam.parent.userId)].sort());
      expect(ids(await fam.child.pull(), 'reaktion')).toHaveLength(2);
      expect(ids(await fam.admin.pull(), 'reaktion')).toEqual([]);
      expect(codes(await fam.admin.sync([reaktion(fam.admin, konv, nid)]))).toEqual(['not_found']);
    });

    it('nur die eigene Reaktion: fremde ID, fremde Person, fremde Änderung und Löschung werden abgelehnt', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      await fam.child.sync([reaktion(fam.child, konv, nid)]);
      // beliebige ID
      expect(codes(await fam.child.sync([upsert('reaktion', randomUUID(), { konversationId: konv, nachrichtId: nid, userId: fam.child.userId, inhalt: E1('a') })]))).toEqual(['invalid']);
      // im Namen einer anderen Person: ID passt, aber der Besitzer ist nicht der Akteur
      expect(codes(await fam.child.sync([reaktion(fam.child, konv, nid, E1('b'), fam.parent.userId)]))).toEqual(['forbidden']);
      // fremde Reaktion ändern oder löschen
      const rev = await revOf('reaktionen', reaktionId(nid, fam.child.userId));
      expect(codes(await fam.parent.sync([upsert('reaktion', reaktionId(nid, fam.child.userId), { inhalt: E1('c') }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([remove('reaktion', reaktionId(nid, fam.child.userId), rev)]))).toEqual(['forbidden']);
      // Bezug ändern: unveränderlich (ungleicher Wert = invalid)
      expect(codes(await fam.child.sync([upsert('reaktion', reaktionId(nid, fam.child.userId), { nachrichtId: randomUUID() }, rev)]))).toEqual(['invalid']);
    });

    it('ändern, löschen und erneut reagieren (dieselbe feste ID wird wiederbelebt)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      const id = reaktionId(nid, fam.child.userId);
      await fam.child.sync([reaktion(fam.child, konv, nid)]);
      let rev = await revOf('reaktionen', id);
      expect((await fam.child.sync([upsert('reaktion', id, { inhalt: E1('anderes') }, rev)])).json.acked).toHaveLength(1);
      rev = await revOf('reaktionen', id);
      expect((await fam.child.sync([remove('reaktion', id, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select inhalt, deleted_at from reaktionen where id = ${id}`))[0]).toMatchObject({ inhalt: '' });
      expect((await fam.child.sync([reaktion(fam.child, konv, nid, E1('neu'))])).json.rejected).toEqual([]);
      expect((await rows(sql`select deleted_at from reaktionen where id = ${id}`))[0]?.deleted_at).toBeNull();
    });

    it('nimmt nur verschlüsselte Hüllen in Form an (kein Klartext-Emoji) und prüft den Bezug zur Nachricht', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const anderer = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      for (const inhalt of ['👍', 'r1:👍', 'e1:kurz', `e1:${'A'.repeat(100)}!${'A'.repeat(100)}`, `e1:${'A'.repeat(600)}`, '']) {
        expect(codes(await fam.child.sync([reaktion(fam.child, konv, nid, inhalt)])), inhalt).toEqual(['invalid']);
      }
      // Nachricht einer anderen Konversation, unbekannte Nachricht
      expect(codes(await fam.child.sync([reaktion(fam.child, anderer, nid)]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([reaktion(fam.child, konv, randomUUID())]))).toEqual(['not_found']);
      expect(await rows(sql`select count(*)::int as n from reaktionen`)).toEqual([{ n: 0 }]);
    });

    it('der Server speichert keinen Klartext (nur die undurchsichtige Hülle)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      await fam.child.sync([reaktion(fam.child, konv, nid, E1('Geheim'))]);
      const [r] = await rows(sql`select inhalt from reaktionen`);
      expect(String(r?.inhalt).startsWith('e1:')).toBe(true);
    });

    it('Kaskade: wird die Nachricht gelöscht, verschwinden Reaktion, Stimme und Pin mit Tombstone (Kinder vor dem Elternteil)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      await fam.child.sync([reaktion(fam.child, konv, nid), stimme(fam.child, konv, nid)]);
      await fam.parent.sync([pin(konv, nid)]);
      await fam.child.pull();
      const rev = await revOf('nachrichten', nid);
      expect((await fam.parent.sync([remove('nachricht', nid, rev)])).json.acked).toHaveLength(1);
      const changes = await fam.child.pull();
      const tombs = changes.filter((c) => c.tombstone);
      expect(tombs.map((c) => c.entity).sort()).toEqual(['nachricht', 'pin', 'reaktion', 'stimme']);
      const nachrichtRev = tombs.find((c) => c.entity === 'nachricht')?.rev as number;
      for (const t of tombs.filter((c) => c.entity !== 'nachricht')) expect(t.rev).toBeLessThan(nachrichtRev);
      expect(await rows(sql`select inhalt from reaktionen`)).toEqual([{ inhalt: '' }]);
      // an einer gelöschten Nachricht gibt es nichts mehr anzulegen
      expect(codes(await fam.child.sync([reaktion(fam.child, konv, nid)]))).toEqual(['parent_deleted']);
    });

    it('Konversation weg (Person entfernt) und Mitglied entfernen: Reaktionen und Stimmen der Person verschwinden mit Tombstone', async () => {
      const opa = await extraMember(world, fam.admin, 'parent', 'opa-zusatz@example.org');
      const konv = await gruppe(fam.parent, [fam.child, opa]);
      const nid = await nachricht(fam.parent, konv);
      await opa.sync([reaktion(opa, konv, nid), stimme(opa, konv, nid)]);
      await fam.child.pull();
      expect((await fam.admin.client.del(`/api/v1/members/${opa.userId}`)).status).toBe(200);
      const changes = await fam.child.pull();
      expect(changes.filter((c) => c.tombstone).map((c) => c.entity).sort()).toEqual(['reaktion', 'stimme']);
      expect(await rows(sql`select count(*)::int as n from reaktionen`)).toEqual([{ n: 0 }]);
    });

    it('in eine Gruppe Aufgenommene bekommen mit dem Verlauf auch Reaktionen, Stimmen und Pins der Nachrichten (nicht die der Unbeteiligten)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      await fam.child.sync([reaktion(fam.child, konv, nid), stimme(fam.child, konv, nid)]);
      await fam.parent.sync([pin(konv, nid)]);
      await fam.admin.pull();
      const rev = Number((await rows(sql`select rev from konversationen where id = ${konv}`))[0]?.rev);
      const teilnehmer = [fam.parent.userId, fam.child.userId, fam.admin.userId];
      expect((await fam.parent.sync([upsert('konversation', konv, { teilnehmer }, rev)])).json.acked).toHaveLength(1);
      const changes = await fam.admin.pull();
      expect(ids(changes, 'nachricht')).toEqual([nid]);
      expect(ids(changes, 'reaktion')).toEqual([reaktionId(nid, fam.child.userId)]);
      expect(ids(changes, 'stimme')).toEqual([stimmeId(nid, fam.child.userId)]);
      expect(ids(changes, 'pin')).toEqual([pinId(nid)]);
    });

    it('Verlauf für neu Aufgenommene: Familienchat, Reaktionen sind für alle Mitglieder sichtbar', async () => {
      const konv = familienchatId(fam.familyId);
      expect((await fam.admin.sync([upsert('konversation', konv, { art: 'family' })])).json.rejected).toEqual([]);
      const nid = await nachricht(fam.admin, konv);
      await fam.child.sync([reaktion(fam.child, konv, nid)]);
      const neu = await extraMember(world, fam.admin, 'child', 'neu-zusatz@example.org');
      expect(ids(await neu.pull(), 'reaktion')).toEqual([reaktionId(nid, fam.child.userId)]);
    });
  });

  describe('Stimme', () => {
    it('legt an, ändert (Server setzt den Zeitpunkt der Änderung), löscht; nur die eigene', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      const id = stimmeId(nid, fam.child.userId);
      expect((await fam.child.sync([stimme(fam.child, konv, nid)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select geaendert_at, created_at from stimmen where id = ${id}`))[0]?.geaendert_at).not.toBeNull(); // beim Anlegen gesetzt
      const rev = await revOf('stimmen', id);
      expect(codes(await fam.parent.sync([upsert('stimme', id, { inhalt: E1('fremd') }, rev)]))).toEqual(['forbidden']);
      expect((await fam.child.sync([upsert('stimme', id, { inhalt: E1('neu') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select geaendert_at from stimmen where id = ${id}`))[0]?.geaendert_at).not.toBeNull();
      // der Wert der Änderung geht an alle Teilnehmer
      const sicht = (await fam.parent.pull()).find((c) => c.entity === 'stimme');
      expect(sicht?.fields.geaendertAt).toEqual(expect.any(String));
      expect((await fam.child.sync([remove('stimme', id, await revOf('stimmen', id))])).json.acked).toHaveLength(1);
    });

    it('Unbeteiligte können nicht abstimmen und bekommen nichts', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      expect(codes(await fam.admin.sync([stimme(fam.admin, konv, nid)]))).toEqual(['not_found']);
      await fam.child.sync([stimme(fam.child, konv, nid)]);
      expect(ids(await fam.admin.pull(), 'stimme')).toEqual([]);
      expect(codes(await fam.child.sync([stimme(fam.child, konv, nid, 'e1:kurz')]))).toEqual(['invalid']);
    });
  });

  describe('Stimme: Zeit und Mengenbegrenzung', () => {
    it('der Server setzt die Zeit der Stimme bei jedem Anlegen UND Wiederbeleben neu (Ende einer Umfrage lässt sich nicht durch Löschen und neu Abstimmen umgehen)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      const id = stimmeId(nid, fam.child.userId);
      const zeit = async () => (await rows(sql`select geaendert_at, created_at from stimmen where id = ${id}`))[0] as Json;
      await fam.child.sync([stimme(fam.child, konv, nid)]);
      const erste = await zeit();
      expect(erste.geaendert_at).not.toBeNull();
      world.advance(30_000);
      expect((await fam.child.sync([upsert('stimme', id, { inhalt: E1('b') }, await revOf('stimmen', id))])).json.acked).toHaveLength(1);
      const geaendert = await zeit();
      expect(new Date(geaendert.geaendert_at).getTime()).toBeGreaterThan(new Date(erste.geaendert_at).getTime());
      expect((await fam.child.sync([remove('stimme', id, await revOf('stimmen', id))])).json.acked).toHaveLength(1);
      world.advance(30_000);
      expect((await fam.child.sync([stimme(fam.child, konv, nid, E1('c'))])).json.rejected).toEqual([]);
      const neu = await zeit();
      expect(new Date(neu.geaendert_at).getTime()).toBeGreaterThan(new Date(geaendert.geaendert_at).getTime());
      expect(new Date(neu.geaendert_at).getTime()).toBeGreaterThanOrEqual(new Date(neu.created_at).getTime());
      // der Wert geht an die Teilnehmer
      expect((await fam.parent.pull()).find((c) => c.entity === 'stimme')?.fields.geaendertAt).toEqual(expect.any(String));
    });

    it('Löschen und erneutes Anlegen derselben Zeile zählt für die Mengenbegrenzung jedes Mal (Protokoll statt Zeilen)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      const id = stimmeId(nid, fam.child.userId);
      let abgelehnt = 0;
      for (let i = 0; i < 31 && abgelehnt === 0; i++) {
        const res = await fam.child.sync([stimme(fam.child, konv, nid, E1(`s${i}`))]);
        if (codes(res).length > 0) abgelehnt++;
        else await fam.child.sync([remove('stimme', id, await revOf('stimmen', id))]);
      }
      expect(abgelehnt).toBe(1);
    });
  });

  describe('Pin', () => {
    it('Teilnehmer heften an, alle Teilnehmer sehen es; Eltern lösen jeden Pin, Kinder nur ihre eigenen', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const n1 = await nachricht(fam.parent, konv);
      const n2 = await nachricht(fam.parent, konv);
      expect((await fam.child.sync([pin(konv, n1)])).json.acked).toHaveLength(1);
      expect((await fam.parent.sync([pin(konv, n2)])).json.acked).toHaveLength(1);
      expect(ids(await fam.parent.pull(), 'pin').sort()).toEqual([pinId(n1), pinId(n2)].sort());
      expect(ids(await fam.admin.pull(), 'pin')).toEqual([]);
      // Kind löst fremden Pin nicht, eigenen schon; Elternteil löst den des Kindes
      expect(codes(await fam.child.sync([remove('pin', pinId(n2), await revOf('pins', pinId(n2)))]))).toEqual(['forbidden']);
      expect((await fam.parent.sync([remove('pin', pinId(n1), await revOf('pins', pinId(n1)))])).json.acked).toHaveLength(1);
      expect((await fam.child.sync([pin(konv, n1)])).json.rejected).toEqual([]);
      expect((await fam.child.sync([remove('pin', pinId(n1), await revOf('pins', pinId(n1)))])).json.acked).toHaveLength(1);
    });

    it('feste ID, Bezug zur Nachricht, kein Ändern; höchstens fünf je Konversation', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const anderer = await gruppe(fam.parent, [fam.child]);
      const nid = await nachricht(fam.parent, konv);
      expect(codes(await fam.parent.sync([upsert('pin', randomUUID(), { konversationId: konv, nachrichtId: nid })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([pin(anderer, nid)]))).toEqual(['invalid']);
      expect((await fam.parent.sync([pin(konv, nid)])).json.acked).toHaveLength(1);
      expect(codes(await fam.parent.sync([upsert('pin', pinId(nid), { konversationId: anderer }, await revOf('pins', pinId(nid)))]))).toEqual(['forbidden']);
      const mehr: string[] = [];
      for (let i = 0; i < MAX_PINS; i++) mehr.push(await nachricht(fam.parent, konv));
      const antworten: string[][] = [];
      for (const m of mehr) antworten.push(codes(await fam.parent.sync([pin(konv, m)])));
      expect(antworten.filter((c) => c.length === 0)).toHaveLength(MAX_PINS - 1);
      expect(antworten.filter((c) => c[0] === 'invalid')).toHaveLength(1);
    });

    it('die Grenze von fünf Pins hält auch bei gleichzeitigem Anheften (Konversation wird gesperrt)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const nids: string[] = [];
      for (let i = 0; i < 8; i++) nids.push(await nachricht(fam.parent, konv));
      const antworten = await Promise.all(nids.map((n, i) => (i % 2 === 0 ? fam.parent : fam.child).sync([pin(konv, n)])));
      expect(antworten.filter((r) => (r.json.rejected as unknown[]).length === 0)).toHaveLength(MAX_PINS);
      expect(await rows(sql`select count(*)::int as n from pins where deleted_at is null`)).toEqual([{ n: MAX_PINS }]);
    });

    it('im Familienchat heften nur Eltern und Admins an; alle sehen den Pin', async () => {
      const konv = familienchatId(fam.familyId);
      expect((await fam.admin.sync([upsert('konversation', konv, { art: 'family' })])).json.rejected).toEqual([]);
      const nid = await nachricht(fam.admin, konv);
      expect(codes(await fam.child.sync([pin(konv, nid)]))).toEqual(['invalid']);
      expect((await fam.parent.sync([pin(konv, nid)])).json.acked).toHaveLength(1);
      expect(ids(await fam.child.pull(), 'pin')).toEqual([pinId(nid)]);
      // das Kind löst ihn nicht, ein Elternteil schon
      expect(codes(await fam.child.sync([remove('pin', pinId(nid), await revOf('pins', pinId(nid)))]))).toEqual(['forbidden']);
      expect((await fam.admin.sync([remove('pin', pinId(nid), await revOf('pins', pinId(nid)))])).json.acked).toHaveLength(1);
    });

    it('verlässt die anheftende Person die Familie, bleibt der Pin ohne Zuordnung bestehen', async () => {
      const opa = await extraMember(world, fam.admin, 'parent', 'opa-pin@example.org');
      const konv = await gruppe(fam.parent, [fam.child, opa]);
      const nid = await nachricht(fam.parent, konv);
      await opa.sync([pin(konv, nid)]);
      expect((await fam.admin.client.del(`/api/v1/members/${opa.userId}`)).status).toBe(200);
      expect((await rows(sql`select gepinnt_von, deleted_at from pins`))[0]).toMatchObject({ gepinnt_von: null, deleted_at: null });
    });
  });
});
