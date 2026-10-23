// Medikamenten-Plan im Sync (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6i): verborgene Konversation je Person (Art `meds`), Medikamente und Einnahmen als Kinder.
// Gesundheitsdaten: Erwachsene sehen NIE die eines anderen Erwachsenen (auch Admins nicht), Eltern und Admins sehen zusätzlich die ihrer Kinder, Kinder nur die eigenen.
// Der Server sieht nur undurchsichtige e1-Hüllen; geprüft werden Teilnehmer-Grenze, Rollen-Regel, feste IDs, Kaskade, Konflikte, Limits, Wecker und die 120 Tage.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../src/auth/types.js';
import { grantOperator } from '../src/operator/service.js';
import { applyOp } from '../src/sync/engine.js';
import { medsChatId, uuidAusSchluessel } from '../src/sync/entities/chat-ids.js';
import { einnahmeEntity, medikamentEntity, MAX_EINNAHMEN, MAX_MEDIKAMENTE } from '../src/sync/entities/medikamente.js';
import { medsTeilnehmerBereinigt, medsTeilnehmerGueltig } from '../src/sync/entities/meds-regeln.js';
import { defaultRegistry } from '../src/sync/index.js';
import { runSyncMaintenance } from '../src/sync/maintenance.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const E1 = (marker: string) => `e1:${marker.replace(/[^A-Za-z0-9_-]/g, '_')}${'A'.repeat(160)}`;
const actor = (role: Role, userId: string): Actor => ({ role, userId });
const DAY = 86_400_000;

describe('Medikamenten-Konversation: feste ID (Known-Answer wie in der App)', () => {
  it('leitet die ID aus der Person ab', () => {
    const u = '22222222-2222-4222-8222-222222222222';
    expect(medsChatId(u)).toBe(uuidAusSchluessel(`meds:${u}`));
    expect(medsChatId(u.toUpperCase())).toBe(medsChatId(u));
    // Known-Answer: muss exakt app/test/medikament_ids_test.dart entsprechen
    expect(medsChatId(u)).toBe(KAT_MEDS);
  });
});
const KAT_MEDS = '9a34c21c-7257-562d-b9c3-eb7b59ff6244';

describe('Medikamenten-Konversation: Rollen-Regel der Teilnehmer (rein)', () => {
  const rollen = (o: Record<string, Role>) => new Map(Object.entries(o));
  const R = rollen({ a1: 'admin', p1: 'parent', k1: 'child', k2: 'child' });

  it.each([
    ['Erwachsener allein', 'p1', ['p1'], true],
    ['Erwachsener mit anderem Erwachsenen', 'p1', ['p1', 'a1'], false],
    ['Admin mit Elternteil', 'a1', ['a1', 'p1'], false],
    ['Erwachsener mit Kind', 'p1', ['p1', 'k1'], false],
    ['Kind allein', 'k1', ['k1'], true],
    ['Kind mit Elternteil und Admin', 'k1', ['k1', 'p1', 'a1'], true],
    ['Kind mit Geschwister', 'k1', ['k1', 'k2'], false],
    ['Kind ohne sich selbst', 'k1', ['p1', 'a1'], false],
    ['unbekannte Person (nicht aktiv)', 'k1', ['k1', 'x'], false],
    ['Subjekt nicht aktiv', 'x', ['x'], false],
  ] as const)('%s', (_n, subjekt, liste, erwartet) => {
    expect(medsTeilnehmerGueltig(subjekt, liste, R)).toBe(erwartet);
  });

  it('bereinigt nach einem Rollenwechsel', () => {
    // Kind wird Erwachsener: nur es selbst bleibt
    expect(medsTeilnehmerBereinigt('k1', ['k1', 'p1', 'a1'], rollen({ a1: 'admin', p1: 'parent', k1: 'parent' }))).toEqual(['k1']);
    // Elternteil wird Kind: es verschwindet aus der Liste des Kindes
    expect(medsTeilnehmerBereinigt('k1', ['k1', 'p1', 'a1'], rollen({ a1: 'admin', p1: 'child', k1: 'child' }))).toEqual(['a1', 'k1']);
    // unverändert gültig bleibt gleich
    expect(medsTeilnehmerBereinigt('k1', ['k1', 'p1'], R)).toEqual(['k1', 'p1']);
  });
});

describe('Medikament und Einnahme: Rechte-Modell (Regeltabelle)', () => {
  const S = 'u-subjekt';
  const E = 'u-eltern';
  const privat = (owner: string | null, teilnehmer: string[]): Facts => ({ audience: 'family', ownerId: owner, participants: teilnehmer, quiet: true });

  it('nur Teilnehmer lesen, anlegen, ändern, löschen; jede Rolle, aber nie als Unbeteiligter (kein Rollen-Durchgriff)', () => {
    for (const def of [medikamentEntity, einnahmeEntity]) {
      for (const role of ['admin', 'parent', 'child'] as const) {
        const f = privat(S, [S, E]);
        for (const teil of [S, E]) {
          expect(mayRead(def.rules, actor(role, teil), f), `${def.name} ${role} Teilnehmer lesen`).toBe(true);
          expect(authorize(def.rules, 'create', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'update', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'delete', actor(role, teil), f)).toBe('ok');
        }
        expect(mayRead(def.rules, actor(role, 'u-fremd'), f), `${def.name} ${role} Fremder`).toBe(false);
        expect(authorize(def.rules, 'create', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('forbidden');
        expect(authorize(def.rules, 'update', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('not_found');
        expect(authorize(def.rules, 'delete', actor(role, 'u-fremd'), f)).toBe('not_found');
        // Bezüge sind unveränderlich
        expect(authorize(def.rules, 'update', actor(role, S), f, ['konversationId'])).toBe('forbidden');
      }
    }
  });

  it('wecken nie per Push', () => {
    expect(medikamentEntity.noWake).toBe(true);
    expect(einnahmeEntity.noWake).toBe(true);
  });
});

describe.each(backends)('Medikamenten-Plan im Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  let kind2: Device;
  let admin2: Device;

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
    fam = await createFamily(world);
    kind2 = await extraMember(world, fam.admin, 'child', 'schwester@example.org');
    admin2 = await extraMember(world, fam.admin, 'parent', 'papa@example.org');
  }, 180_000);
  afterAll(async () => {
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    await world.db.execute(sql`truncate table einnahmen, medikamente`);
    for (const d of [fam.admin, fam.parent, fam.child, kind2, admin2]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const codes = (res: { json: Json }) => (res.json.rejected as Array<{ code: string }>).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);
  const revOf = async (table: string, id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);

  /** Medikamenten-Konversation von [subjekt] mit den Teilnehmern, angelegt von [by]. */
  const konv = (subjekt: Device, teilnehmer: Device[], extra: Json = {}) =>
    upsert('konversation', medsChatId(subjekt.userId), { art: 'meds', subjektId: subjekt.userId, teilnehmer: teilnehmer.map((t) => t.userId), ...extra });
  async function plan(by: Device, subjekt: Device, teilnehmer: Device[]): Promise<string> {
    const res = await by.sync([konv(subjekt, teilnehmer)]);
    expect(res.json.rejected, JSON.stringify(res.json)).toEqual([]);
    return medsChatId(subjekt.userId);
  }
  const medikament = (k: string, id: string = randomUUID(), inhalt = E1('m')) => upsert('medikament', id, { konversationId: k, inhalt });
  const einnahme = (k: string, mid: string, id: string = randomUUID(), inhalt = E1('n')) => upsert('einnahme', id, { konversationId: k, medikamentId: mid, inhalt });
  async function med(by: Device, k: string): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([medikament(k, id)]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }

  describe('Anlegen der Konversation: Rollen-Regel und feste ID', () => {
    it('Kind legt seine eigene an (allein oder mit Eltern/Admins); Eltern legen die des Kindes an', async () => {
      expect((await fam.child.sync([konv(fam.child, [fam.child])])).json.rejected).toEqual([]);
      await resetSync(world);
      expect((await fam.child.sync([konv(fam.child, [fam.child, fam.parent, fam.admin])])).json.rejected).toEqual([]);
      await resetSync(world);
      expect((await fam.parent.sync([konv(fam.child, [fam.child, fam.parent, fam.admin, admin2])])).json.rejected).toEqual([]);
    });

    it('Erwachsene: nur sie selbst; nie ein anderer Erwachsener (auch kein Admin), nie ein Kind', async () => {
      expect(codes(await fam.parent.sync([konv(fam.parent, [fam.parent, fam.admin])]))).toEqual(['invalid']);
      expect(codes(await fam.admin.sync([konv(fam.admin, [fam.admin, fam.parent])]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([konv(fam.parent, [fam.parent, fam.child])]))).toEqual(['invalid']);
      expect((await fam.parent.sync([konv(fam.parent, [fam.parent])])).json.rejected).toEqual([]);
      expect((await fam.admin.sync([konv(fam.admin, [fam.admin])])).json.rejected).toEqual([]);
    });

    it('Kind: nie ein Geschwister in der Liste', async () => {
      expect(codes(await fam.child.sync([konv(fam.child, [fam.child, kind2])]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([konv(fam.child, [fam.child, fam.parent, kind2])]))).toEqual(['invalid']);
    });

    it('niemand legt die Konversation einer anderen Person ohne sich selbst als Teilnehmer an; das Subjekt muss in der Liste stehen', async () => {
      // Elternteil nicht in der Liste: kein Recht
      expect(codes(await fam.parent.sync([konv(fam.child, [fam.child])]))).toEqual(['forbidden']);
      // anderer Erwachsener für ein Elternteil: er steht nie in der Liste
      expect(codes(await fam.admin.sync([konv(fam.parent, [fam.parent])]))).toEqual(['forbidden']);
      // Subjekt fehlt in der Liste
      expect(codes(await fam.parent.sync([upsert('konversation', medsChatId(fam.child.userId), { art: 'meds', subjektId: fam.child.userId, teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      // Subjekt fehlt ganz, oder eine Nicht-meds-Konversation nennt eines
      expect(codes(await fam.parent.sync([upsert('konversation', medsChatId(fam.parent.userId), { art: 'meds', teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'group', subjektId: fam.parent.userId, teilnehmer: [fam.parent.userId, fam.admin.userId] })]))).toEqual(['invalid']);
    });

    it('nur die feste ID der Person (niemand belegt die einer anderen vorab), keine Zufalls-ID', async () => {
      expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'meds', subjektId: fam.parent.userId, teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', medsChatId(fam.child.userId), { art: 'meds', subjektId: fam.parent.userId, teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
    });

    it('ist nie löschbar, Name und Subjekt sind unveränderlich; ohne Verschlüsselung (p1) gibt es keine', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const rev = await revOf('konversationen', k);
      expect(codes(await fam.child.sync([remove('konversation', k, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([upsert('konversation', k, { titel: 'x' }, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([upsert('konversation', k, { subjektId: fam.parent.userId }, rev)]))).toEqual(['invalid']);
      await resetSync(world);
      expect(codes(await fam.child.sync([konv(fam.child, [fam.child], { encVersion: 'p1' })]))).toEqual(['invalid']);
    });

    it('Nachrichten gibt es dort nie', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      expect(codes(await fam.child.sync([upsert('nachricht', randomUUID(), { konversationId: k, text: E1('hallo') })]))).toEqual(['invalid']);
    });
  });

  describe('Sicht: wer welche Medikamente sieht', () => {
    it('Erwachsener sieht nie das eines anderen Erwachsenen (auch Admin nicht), Kind sieht keinen Erwachsenen und kein Geschwister', async () => {
      const kMama = await plan(fam.parent, fam.parent, [fam.parent]);
      const kPapa = await plan(admin2, admin2, [admin2]);
      const kAdmin = await plan(fam.admin, fam.admin, [fam.admin]);
      const kKind = await plan(fam.child, fam.child, [fam.child]);
      const kKind2 = await plan(kind2, kind2, [kind2]);
      for (const [d, k] of [[fam.parent, kMama], [admin2, kPapa], [fam.admin, kAdmin], [fam.child, kKind], [kind2, kKind2]] as const) await med(d, k);
      const sicht = async (d: Device) => ids(await d.pull(), 'konversation').sort();
      expect(await sicht(fam.parent)).toEqual([kMama]);
      expect(await sicht(admin2)).toEqual([kPapa]);
      expect(await sicht(fam.admin)).toEqual([kAdmin]);
      expect(await sicht(fam.child)).toEqual([kKind]);
      expect(await sicht(kind2)).toEqual([kKind2]);
      // auch die Medikamente darunter: genau eines je Person
      for (const d of [fam.parent, admin2, fam.admin, fam.child, kind2]) {
        d.sinceRev = 0;
        expect(ids(await d.pull(), 'medikament'), d.userId).toHaveLength(1);
      }
    });

    it('Eltern und Admins sehen zusätzlich die Medikamente ihrer Kinder, nur wenn sie Teilnehmer sind; Geschwister nie', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent, fam.admin]);
      const m = await med(fam.parent, k);
      await fam.child.sync([einnahme(k, m)]);
      for (const d of [fam.child, fam.parent, fam.admin]) {
        d.sinceRev = 0;
        const c = await d.pull();
        expect(ids(c, 'medikament'), d.userId).toEqual([m]);
        expect(ids(c, 'einnahme'), d.userId).toHaveLength(1);
      }
      // anderer Erwachsener (nicht in der Liste) und Geschwister: nichts, auch keine ID
      for (const d of [admin2, kind2]) {
        const c = await d.pull();
        expect(ids(c).filter((i) => [k, m].includes(i)), d.userId).toEqual([]);
        expect(c.filter((x) => ['medikament', 'einnahme'].includes(x.entity as string))).toEqual([]);
      }
    });

    it('das Betreiber-Flag ändert nichts an der Sicht', async () => {
      const k = await plan(fam.parent, fam.parent, [fam.parent]);
      await med(fam.parent, k);
      await grantOperator(world.auth.ctx, 'admin@example.org');
      expect(ids(await fam.admin.pull(), 'medikament')).toEqual([]);
      expect(ids(await fam.admin.pull(), 'konversation')).toEqual([]);
    });

    it('Unbeteiligte können nichts lesen oder anlegen: not_found (IDOR), fremde Änderungen und Löschungen ebenso', async () => {
      const k = await plan(fam.parent, fam.parent, [fam.parent]);
      const m = await med(fam.parent, k);
      const e = randomUUID();
      expect((await fam.parent.sync([einnahme(k, m, e)])).json.rejected).toEqual([]);
      for (const fremd of [fam.admin, admin2, fam.child]) {
        expect(codes(await fremd.sync([medikament(k)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([einnahme(k, m)])), fremd.userId).toEqual(['not_found']);
        const rev = await revOf('medikamente', m);
        expect(codes(await fremd.sync([upsert('medikament', m, { inhalt: E1('x') }, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([remove('medikament', m, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([remove('einnahme', e, await revOf('einnahmen', e))])), fremd.userId).toEqual(['not_found']);
        // auch die Konversation selbst: Teilnehmer ändern ist nicht möglich
        expect(codes(await fremd.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fremd.userId] }, await revOf('konversationen', k))])), fremd.userId).toEqual(['not_found']);
      }
      // nichts hat sich verändert
      expect((await rows(sql`select inhalt from medikamente where id = ${m}`))[0]?.inhalt).toBe(E1('m'));
    });

    it('fremde Familie: nicht sichtbar (IDs gehören der Familie)', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const res = await fam.child.sync([medikament(k)]);
      expect(res.json.rejected).toEqual([]);
      const anderswo = await rows(sql`select count(*)::int as n from medikamente where family_id <> ${fam.familyId}`);
      expect(anderswo[0]?.n).toBe(0);
    });
  });

  describe('Medikament und Einnahme', () => {
    it('Teilnehmer legen an und ändern; der Server setzt den Bearbeiter (Signierer) und prüft nur Form und Größe', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const id = await med(fam.child, k);
      expect((await rows(sql`select bearbeiter_id from medikamente where id = ${id}`))[0]?.bearbeiter_id).toBe(fam.child.userId);
      const rev = await revOf('medikamente', id);
      expect((await fam.parent.sync([upsert('medikament', id, { inhalt: E1('geaendert') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select bearbeiter_id, inhalt from medikamente where id = ${id}`))[0]).toMatchObject({ bearbeiter_id: fam.parent.userId, inhalt: E1('geaendert') });
      // Klartext, kurze, falsche und zu große Hüllen
      for (const inhalt of ['Ibuprofen 400', 'm1:{}', 'e1:kurz', `e1:${'A'.repeat(100)}!${'A'.repeat(100)}`, `e1:${'A'.repeat(17_000)}`, '']) {
        expect(codes(await fam.child.sync([medikament(k, randomUUID(), inhalt)])), inhalt.slice(0, 12)).toEqual(['invalid']);
      }
      expect(codes(await fam.child.sync([einnahme(k, id, randomUUID(), `e1:${'A'.repeat(2100)}`)]))).toEqual(['invalid']);
    });

    it('Zufalls-IDs (UUID v4); eine abgeleitete ID, ein Bezug auf eine fremde Konversation oder ein fremdes Medikament wird abgelehnt', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const kMama = await plan(fam.parent, fam.parent, [fam.parent]);
      expect(codes(await fam.child.sync([medikament(k, uuidAusSchluessel('irgendwas'))]))).toEqual(['invalid']);
      const m = await med(fam.child, k);
      const mMama = await med(fam.parent, kMama);
      // Einnahme: Medikament gehört nicht zur genannten Konversation
      expect(codes(await fam.child.sync([einnahme(k, mMama)]))).toEqual(['not_found']);
      expect(codes(await fam.parent.sync([einnahme(kMama, m)]))).toEqual(['not_found']);
      expect(codes(await fam.parent.sync([einnahme(k, mMama)]))).toEqual(['invalid']); // Medikament gehört zu einer anderen Konversation
      // Konversation einer gewöhnlichen Gruppe: kein Medikament dort
      const gruppe = randomUUID();
      await fam.parent.sync([upsert('konversation', gruppe, { art: 'group', teilnehmer: [fam.parent.userId, fam.admin.userId] })]);
      expect(codes(await fam.parent.sync([medikament(gruppe)]))).toEqual(['invalid']);
    });

    it('Einnahme: anlegen, nachtragen (ändern), zurücknehmen (löschen), je Teilnehmer', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const m = await med(fam.parent, k);
      const e = randomUUID();
      expect((await fam.child.sync([einnahme(k, m, e)])).json.rejected).toEqual([]);
      const rev = await revOf('einnahmen', e);
      expect((await fam.parent.sync([upsert('einnahme', e, { inhalt: E1('nachgetragen') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select bearbeiter_id from einnahmen where id = ${e}`))[0]?.bearbeiter_id).toBe(fam.parent.userId);
      expect((await fam.child.sync([remove('einnahme', e, await revOf('einnahmen', e))])).json.acked).toHaveLength(1);
      expect((await rows(sql`select inhalt, deleted_at from einnahmen where id = ${e}`))[0]).toMatchObject({ inhalt: '' });
    });

    it('Konflikte je Feld: zwei Geräte ändern denselben Inhalt, das spätere verliert (Serverreihenfolge)', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const m = await med(fam.parent, k);
      const rev = await revOf('medikamente', m);
      expect((await fam.parent.sync([upsert('medikament', m, { inhalt: E1('eins') }, rev)])).json.conflicts).toEqual([]);
      const zweite = await fam.child.sync([upsert('medikament', m, { inhalt: E1('zwei') }, rev)]);
      expect(zweite.json.conflicts).toHaveLength(1);
      expect(zweite.json.conflicts[0].fields.inhalt).toBe(E1('eins'));
      expect((await rows(sql`select inhalt, bearbeiter_id from medikamente where id = ${m}`))[0]).toMatchObject({ inhalt: E1('eins'), bearbeiter_id: fam.parent.userId });
    });

    it('Löschen eines Medikaments nimmt seine Einnahmen mit (Kaskade, Tombstones für die Geräte)', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const m = await med(fam.parent, k);
      const e1 = randomUUID();
      const e2 = randomUUID();
      await fam.child.sync([einnahme(k, m, e1), einnahme(k, m, e2)]);
      await fam.child.pull();
      expect((await fam.parent.sync([remove('medikament', m, await revOf('medikamente', m))])).json.acked).toHaveLength(1);
      const c = await fam.child.pull();
      expect(c.filter((x) => x.tombstone).map((x) => x.id).sort()).toEqual([m, e1, e2].sort());
      expect(codes(await fam.child.sync([einnahme(k, m)]))).toEqual(['parent_deleted']);
    });

    it('Obergrenzen: höchstens so viele Medikamente je Person und Einnahmen je Medikament', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const m = await med(fam.child, k);
      await world.db.execute(sql`insert into medikamente (family_id, konversation_id, inhalt, rev) select ${fam.familyId}, ${k}, ${E1('x')}, 1 from generate_series(1, ${MAX_MEDIKAMENTE - 1})`);
      expect(codes(await fam.child.sync([medikament(k)]))).toEqual(['limit_reached']);
      await world.db.execute(sql`insert into einnahmen (family_id, konversation_id, medikament_id, inhalt, rev) select ${fam.familyId}, ${k}, ${m}, ${E1('x')}, 1 from generate_series(1, ${MAX_EINNAHMEN})`);
      expect(codes(await fam.child.sync([einnahme(k, m)]))).toEqual(['limit_reached']);
    });

    it('Mengenbegrenzung je Person und Minute für neue Einnahmen', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const m = await med(fam.child, k);
      let abgelehnt = 0;
      for (let i = 0; i < 70; i++) {
        const r = await fam.child.sync([einnahme(k, m)]);
        if ((r.json.rejected as unknown[]).length > 0) abgelehnt++;
      }
      expect(abgelehnt).toBeGreaterThan(0);
    });
  });

  describe('Teilnehmerwechsel, Rollenwechsel und Entfernen', () => {
    it('Eltern kommen und gehen: der Server verlangt weiter die Rollen-Regel (nie ein Geschwister, nie ein Erwachsenen-Subjekt mit zweiter Person)', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      let rev = await revOf('konversationen', k);
      expect((await fam.child.sync([upsert('konversation', k, { teilnehmer: [fam.child.userId, fam.parent.userId] }, rev)])).json.acked).toHaveLength(1);
      rev = await revOf('konversationen', k);
      expect(codes(await fam.child.sync([upsert('konversation', k, { teilnehmer: [fam.child.userId, fam.parent.userId, kind2.userId] }, rev)]))).toEqual(['invalid']);
      // das Elternteil nimmt sich selbst heraus; das Kind bleibt
      await fam.parent.pull();
      expect((await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.child.userId] }, rev)])).json.acked).toHaveLength(1);
      expect((await fam.parent.pull()).find((x) => x.id === k)).toMatchObject({ tombstone: true, hidden: true }); // Verlust der Sicht
      // das Subjekt kann sich nicht herausnehmen (das Subjekt fehlt in der Liste)
      rev = await revOf('konversationen', k);
      expect(codes(await fam.child.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId] }, rev)]))).toEqual(['invalid']);
      const kMama = await plan(fam.parent, fam.parent, [fam.parent]);
      expect(codes(await fam.parent.sync([upsert('konversation', kMama, { teilnehmer: [fam.parent.userId, fam.admin.userId] }, await revOf('konversationen', kMama))]))).toEqual(['invalid']);
    });

    it('Kind wird Erwachsener: die Eltern fliegen aus seiner Liste (Rollenwechsel), der neue Erwachsene sieht nur noch seine eigene', async () => {
      const k = await plan(fam.parent, kind2, [kind2, fam.parent, fam.admin]);
      await med(fam.parent, k);
      expect(ids(await fam.parent.pull(), 'medikament')).toHaveLength(1);
      const res = await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'parent' });
      expect(res.status, JSON.stringify(res.json)).toBe(200);
      const t = (await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[];
      expect(t).toEqual([kind2.userId]);
      // die Eltern bekommen den Entzug als hidden-Tombstone und nichts mehr
      const c = await fam.parent.pull();
      expect(c.find((x) => x.entity === 'konversation' && x.id === k)).toMatchObject({ tombstone: true, hidden: true });
      expect(ids(await fam.parent.pull(), 'medikament')).toEqual([]);
      // nachziehen ist auch ohne Zutun der Geräte gültig: der Server akzeptiert die Liste jetzt als Erwachsenen-Liste
      expect(await rows(sql`select 1 from konversationen where id = ${k} and cardinality(teilnehmer) = 1`)).toHaveLength(1);
      // zurück zum Kind (Rolle child): die frühere Eltern-Teilnahme kommt nicht von selbst wieder
      await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'child' });
      expect((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer).toEqual([kind2.userId]);
    });

    it('Elternteil wird Kind: es verschwindet aus den Listen fremder Kinder; seine eigene Liste bleibt', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent, admin2]);
      const kEigen = await plan(admin2, admin2, [admin2]);
      expect((await fam.admin.client.patch(`/api/v1/members/${admin2.userId}/role`, { role: 'child' })).status).toBe(200);
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).sort()).toEqual([fam.child.userId, fam.parent.userId].sort());
      expect(await rows(sql`select 1 from konversationen where id = ${kEigen} and deleted_at is null and teilnehmer = array[${admin2.userId}]::uuid[]`)).toHaveLength(1);
    });

    it('Person entfernt: ihre Konversation samt Medikamenten und Einnahmen verschwindet (Tombstone); als Elternteil nur aus den Listen der Kinder', async () => {
      const x = await extraMember(world, fam.admin, 'child', 'weg@example.org');
      const kWeg = await plan(x, x, [x]);
      const mWeg = await med(x, kWeg);
      await x.sync([einnahme(kWeg, mWeg)]);
      const eltern = await extraMember(world, fam.admin, 'parent', 'weg2@example.org');
      const k = await plan(eltern, fam.child, [fam.child, eltern]);
      await med(eltern, k);
      const res = await fam.admin.client.del(`/api/v1/members/${x.userId}`);
      expect(res.status, JSON.stringify(res.json)).toBe(200);
      expect(await rows(sql`select 1 from konversationen where id = ${kWeg} and deleted_at is null`)).toHaveLength(0);
      expect(await rows(sql`select 1 from medikamente where id = ${mWeg} and deleted_at is null`)).toHaveLength(0);
      expect(await rows(sql`select 1 from einnahmen where medikament_id = ${mWeg} and deleted_at is null`)).toHaveLength(0);
      // das Elternteil entfernen: das Kind behält seine Konversation
      const res2 = await fam.admin.client.del(`/api/v1/members/${eltern.userId}`);
      expect(res2.status, JSON.stringify(res2.json)).toBe(200);
      expect((await rows(sql`select teilnehmer from konversationen where id = ${k} and deleted_at is null`))[0]?.teilnehmer).toEqual([fam.child.userId]);
    });
  });

  describe('kein Wecker, kein Inhalt im Log', () => {
    it('weder die Konversation noch Epochen, Medikamente oder Einnahmen lösen einen Push-Wecker aus', async () => {
      const mk = (op: ReturnType<typeof upsert>, by: Device) => applyOp(world.auth.ctx, defaultRegistry, { actor: { userId: by.userId, role: by.role as Role }, familyId: fam.familyId, deviceId: by.deviceId, op });
      const k = medsChatId(fam.child.userId);
      const a = await mk(konv(fam.child, [fam.child]), fam.child);
      expect(a.outcome.status, JSON.stringify(a.outcome)).toBe('acked');
      expect(a.outcome.wake).toBe(false);
      expect(a.outcome.users).toEqual([fam.child.userId]);
      const m = randomUUID();
      const b = await mk(medikament(k, m), fam.child);
      expect(b.outcome.wake).toBe(false);
      const c = await mk(einnahme(k, m), fam.child);
      expect(c.outcome.wake).toBe(false);
      // gegenprobe: eine gewöhnliche Gruppe weckt weiter
      const g = await mk(upsert('konversation', randomUUID(), { art: 'group', teilnehmer: [fam.child.userId, fam.parent.userId] }), fam.child);
      expect(g.outcome.wake).not.toBe(false);
    });

    it('das Änderungsprotokoll hält nach Änderungen keine alten Inhalte (scrub), nach dem Löschen nichts', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const m = await med(fam.child, k);
      await fam.child.sync([upsert('medikament', m, { inhalt: E1('neu') }, await revOf('medikamente', m))]);
      const alt = await rows(sql`select changes from change_log where entity = 'medikament' and entity_id = ${m} order by rev`);
      expect(alt.filter((r) => JSON.stringify(r.changes).includes(E1('m')))).toHaveLength(0);
      await fam.child.sync([remove('medikament', m, await revOf('medikamente', m))]);
      const nach = await rows(sql`select changes from change_log where entity = 'medikament' and entity_id = ${m}`);
      expect(nach.every((r) => JSON.stringify(r.changes) === '{}')).toBe(true);
    });
  });

  describe('Aufbewahrung: 120 Tage', () => {
    it('der Wartungsjob löscht ältere Einnahmen (mit Tombstone), jüngere und Medikamente bleiben', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const m = await med(fam.parent, k);
      const alt = randomUUID();
      const grenznah = randomUUID();
      const neu = randomUUID();
      expect((await fam.child.sync([einnahme(k, m, alt), einnahme(k, m, grenznah), einnahme(k, m, neu)])).json.rejected).toEqual([]);
      const jetzt = world.clock;
      const vor = (tage: number) => new Date(jetzt - tage * DAY).toISOString();
      await world.db.execute(sql`update einnahmen set created_at = ${vor(121)}::timestamptz where id = ${alt}`);
      await world.db.execute(sql`update einnahmen set created_at = ${vor(119)}::timestamptz where id = ${grenznah}`);
      await fam.child.pull();
      const report = await runSyncMaintenance(world.auth.ctx);
      expect(report.einnahmenPurged).toBe(1);
      const lebend = (await rows(sql`select id from einnahmen where deleted_at is null`)).map((r) => r.id);
      expect(lebend.sort()).toEqual([grenznah, neu].sort());
      expect(await rows(sql`select 1 from medikamente where id = ${m} and deleted_at is null`)).toHaveLength(1);
      // die Geräte erfahren es als Tombstone
      const c = await fam.child.pull();
      expect(c.filter((x) => x.tombstone).map((x) => x.id)).toEqual([alt]);
      // wiederholt: nichts mehr zu tun
      expect((await runSyncMaintenance(world.auth.ctx)).einnahmenPurged).toBe(0);
    });
  });
});
