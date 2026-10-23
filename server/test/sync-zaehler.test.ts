// Zähler im Sync (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6l): EINE verborgene Konversation je Familie (Art `zaehler`), Zähler und Zählerstände als Kinder.
// Verbrauchsdaten verraten Anwesenheit: Zugriff NUR für Eltern und Admins, Kinder sehen nichts und sind nie Teilnehmer. Der Server sieht nur undurchsichtige e1-Hüllen;
// geprüft werden Teilnehmer-Grenze, Rollen-Regel, feste ID, Kaskade, Konflikte, Limits, Wecker und das Protokoll.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../src/auth/types.js';
import { grantOperator } from '../src/operator/service.js';
import { applyOp } from '../src/sync/engine.js';
import { uuidAusSchluessel, zaehlerChatId } from '../src/sync/entities/chat-ids.js';
import { zaehlerTeilnehmerBereinigt, zaehlerTeilnehmerGueltig } from '../src/sync/entities/zaehler-regeln.js';
import { MAX_STAENDE, MAX_ZAEHLER_JE_HAUSHALT, zaehlerEntity, zaehlerstandEntity } from '../src/sync/entities/zaehler.js';
import { defaultRegistry } from '../src/sync/index.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const E1 = (marker: string) => `e1:${marker.replace(/[^A-Za-z0-9_-]/g, '_')}${'A'.repeat(160)}`;
const actor = (role: Role, userId: string): Actor => ({ role, userId });
// Known-Answer: muss exakt app/test/zaehler_ids_test.dart entsprechen
const FAMILIE_KAT = '11111111-1111-4111-8111-111111111111';
const KAT_ZAEHLER = 'ed088537-4d78-5bb2-9826-6bb598e1f202';

describe('Zähler-Konversation: feste ID (Known-Answer wie in der App)', () => {
  it('leitet die ID aus der Familie ab', () => {
    expect(zaehlerChatId(FAMILIE_KAT)).toBe(uuidAusSchluessel(`zaehler:${FAMILIE_KAT}`));
    expect(zaehlerChatId(FAMILIE_KAT.toUpperCase())).toBe(zaehlerChatId(FAMILIE_KAT));
    expect(zaehlerChatId(FAMILIE_KAT)).toBe(KAT_ZAEHLER);
    expect(zaehlerChatId('22222222-2222-4222-8222-222222222222')).not.toBe(KAT_ZAEHLER);
  });
});

describe('Zähler-Konversation: Rollen-Regel der Teilnehmer (rein)', () => {
  const rollen = (o: Record<string, Role>) => new Map(Object.entries(o));
  const R = rollen({ a1: 'admin', p1: 'parent', k1: 'child' });

  it.each([
    ['Admin allein', ['a1'], true],
    ['Elternteil allein', ['p1'], true],
    ['Admin und Elternteil', ['a1', 'p1'], true],
    ['mit Kind', ['a1', 'k1'], false],
    ['nur ein Kind', ['k1'], false],
    ['leer', [], false],
    ['unbekannte Person (nicht aktiv)', ['a1', 'x'], false],
    ['doppelt', ['a1', 'A1'], false],
  ] as const)('%s', (_n, liste, erwartet) => {
    expect(zaehlerTeilnehmerGueltig(liste, R)).toBe(erwartet);
  });

  it('bereinigt nach einem Rollenwechsel', () => {
    expect(zaehlerTeilnehmerBereinigt(['a1', 'p1'], rollen({ a1: 'admin', p1: 'child' }), ['a1'])).toEqual(['a1']);
    expect(zaehlerTeilnehmerBereinigt(['a1', 'p1'], R, ['a1', 'p1'])).toEqual(['a1', 'p1']);
    // niemand übrig: ersatzweise alle aktiven Erwachsenen, nie ein Kind
    expect(zaehlerTeilnehmerBereinigt(['p1'], rollen({ a1: 'admin', p1: 'child' }), ['a1'])).toEqual(['a1']);
  });
});

describe('Zähler und Stand: Rechte-Modell (Regeltabelle)', () => {
  const A = 'u-admin';
  const E = 'u-eltern';
  const K = 'u-kind';
  const privat = (owner: string | null, teilnehmer: string[]): Facts => ({ audience: 'family', ownerId: owner, participants: teilnehmer, quiet: true });

  it('Eltern und Admins (als Teilnehmer): lesen, anlegen, ändern, löschen; nie als Unbeteiligte', () => {
    for (const def of [zaehlerEntity, zaehlerstandEntity]) {
      for (const role of ['admin', 'parent'] as const) {
        const f = privat(A, [A, E]);
        for (const teil of [A, E]) {
          expect(mayRead(def.rules, actor(role, teil), f), `${def.name} ${role} lesen`).toBe(true);
          expect(authorize(def.rules, 'create', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'update', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'delete', actor(role, teil), f)).toBe('ok');
        }
        expect(mayRead(def.rules, actor(role, 'u-fremd'), f)).toBe(false);
        expect(authorize(def.rules, 'create', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('forbidden');
        expect(authorize(def.rules, 'update', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('not_found');
        expect(authorize(def.rules, 'delete', actor(role, 'u-fremd'), f)).toBe('not_found');
        expect(authorize(def.rules, 'update', actor(role, A), f, ['konversationId'])).toBe('forbidden');
      }
    }
  });

  it('Kinder: kein Recht, auch nicht als (hypothetischer) Teilnehmer', () => {
    for (const def of [zaehlerEntity, zaehlerstandEntity]) {
      for (const f of [privat(A, [A, E]), privat(A, [A, E, K]), { audience: 'family', ownerId: K, participants: undefined } as Facts]) {
        expect(mayRead(def.rules, actor('child', K), f), def.name).toBe(false);
        expect(authorize(def.rules, 'create', actor('child', K), f, ['inhalt'])).toBe('forbidden');
        expect(authorize(def.rules, 'update', actor('child', K), f, ['inhalt'])).toBe('not_found');
        expect(authorize(def.rules, 'delete', actor('child', K), f)).toBe('not_found');
      }
    }
  });

  it('wecken nie per Push', () => {
    expect(zaehlerEntity.noWake).toBe(true);
    expect(zaehlerstandEntity.noWake).toBe(true);
  });
});

describe.each(backends)('Zähler im Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;
  let kind2: Device;
  let papa: Device;

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000', WS_PING_INTERVAL_MS: '600000', WS_AUTH_TIMEOUT_MS: '60000' });
    fam = await createFamily(world);
    kind2 = await extraMember(world, fam.admin, 'child', 'schwester@example.org');
    papa = await extraMember(world, fam.admin, 'parent', 'papa@example.org');
  }, 180_000);
  afterAll(async () => {
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    await world.db.execute(sql`truncate table zaehlerstaende, zaehler`);
    for (const d of [fam.admin, fam.parent, fam.child, kind2, papa]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const codes = (res: { json: Json }) => (res.json.rejected as Array<{ code: string }>).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);
  const revOf = async (table: string, id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);

  const K = () => zaehlerChatId(fam.familyId);
  /** Zähler-Konversation mit den Teilnehmern. */
  const konv = (teilnehmer: Device[], extra: Json = {}) => upsert('konversation', K(), { art: 'zaehler', teilnehmer: teilnehmer.map((t) => t.userId), ...extra });
  async function haushalt(by: Device, teilnehmer: Device[]): Promise<string> {
    const res = await by.sync([konv(teilnehmer)]);
    expect(res.json.rejected, JSON.stringify(res.json)).toEqual([]);
    return K();
  }
  const zaehler = (k: string, id: string = randomUUID(), inhalt = E1('z')) => upsert('zaehler', id, { konversationId: k, inhalt });
  const stand = (k: string, zid: string, id: string = randomUUID(), inhalt = E1('s')) => upsert('zaehlerstand', id, { konversationId: k, zaehlerId: zid, inhalt });
  async function zae(by: Device, k: string): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([zaehler(k, id)]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }

  describe('Anlegen der Konversation: Rollen-Regel und feste ID', () => {
    it('Elternteil und Admin legen sie an (allein oder gemeinsam), die zweite Anlage ist nur eine Änderung/Wiederholung', async () => {
      expect((await fam.parent.sync([konv([fam.parent, fam.admin, papa])])).json.rejected).toEqual([]);
      expect(await rows(sql`select 1 from konversationen where id = ${K()} and art::text = 'zaehler' and subjekt_id is null`)).toHaveLength(1);
    });

    it('Kind kann sie nie anlegen (kein Teilnehmer, kein Recht); ein Kind in der Liste wird abgelehnt', async () => {
      expect(codes(await fam.child.sync([konv([fam.parent])]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([konv([fam.child])]))).not.toEqual([]);
      expect(codes(await fam.parent.sync([konv([fam.parent, fam.child])]))).toEqual(['invalid']);
      expect(codes(await fam.admin.sync([konv([fam.admin, kind2])]))).toEqual(['invalid']);
      expect(await rows(sql`select 1 from konversationen where art::text = 'zaehler'`)).toHaveLength(0);
    });

    it('Familie ohne sich selbst als Teilnehmer: kein Recht; Subjekt wird nie akzeptiert; Zufalls-ID und fremde ID werden abgelehnt', async () => {
      expect(codes(await fam.parent.sync([konv([fam.admin])]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([konv([fam.parent], { subjektId: fam.parent.userId })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'zaehler', teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', zaehlerChatId(randomUUID()), { art: 'zaehler', teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([konv([fam.parent], { titel: 'Strom' })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([konv([fam.parent], { encVersion: 'p1' })]))).toEqual(['invalid']);
    });

    it('ist nie löschbar, Name unveränderlich', async () => {
      const k = await haushalt(fam.parent, [fam.parent, fam.admin]);
      const rev = await revOf('konversationen', k);
      expect(codes(await fam.parent.sync([remove('konversation', k, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([upsert('konversation', k, { titel: 'x' }, rev)]))).toEqual(['forbidden']);
    });

    it('Nachrichten gibt es dort nie', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      expect(codes(await fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: k, text: E1('hallo') })]))).toEqual(['invalid']);
    });
  });

  describe('Sicht: nur Eltern und Admins', () => {
    it('Teilnehmer sehen Konversation, Zähler und Stände; Kinder sehen nichts, auch keine IDs oder hidden-Spuren', async () => {
      const k = await haushalt(fam.parent, [fam.parent, fam.admin]);
      const z = await zae(fam.parent, k);
      await fam.admin.sync([stand(k, z)]);
      for (const d of [fam.parent, fam.admin]) {
        d.sinceRev = 0;
        const c = await d.pull();
        expect(ids(c, 'konversation'), d.userId).toEqual([k]);
        expect(ids(c, 'zaehler'), d.userId).toEqual([z]);
        expect(ids(c, 'zaehlerstand'), d.userId).toHaveLength(1);
      }
      for (const d of [fam.child, kind2]) {
        const c = await d.pull();
        expect(c.filter((x) => [k, z].includes(x.id as string)), d.userId).toEqual([]);
        expect(c.filter((x) => ['zaehler', 'zaehlerstand'].includes(x.entity as string))).toEqual([]);
      }
      // auch ein Elternteil, das nicht in der Liste steht, sieht nichts (Teilnehmer-Grenze, kein Rollen-Durchgriff)
      expect(ids(await papa.pull(), 'zaehler')).toEqual([]);
    });

    it('das Betreiber-Flag und die Familienrolle ändern nichts', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      await zae(fam.parent, k);
      await grantOperator(world.auth.ctx, 'admin@example.org');
      expect(ids(await fam.admin.pull(), 'zaehler')).toEqual([]);
      expect(ids(await fam.admin.pull(), 'konversation')).toEqual([]);
    });

    it('Unbeteiligte (auch Kinder) können nichts lesen, anlegen, ändern, löschen: not_found (IDOR)', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      const z = await zae(fam.parent, k);
      const e = randomUUID();
      expect((await fam.parent.sync([stand(k, z, e)])).json.rejected).toEqual([]);
      for (const fremd of [fam.admin, papa, fam.child, kind2]) {
        expect(codes(await fremd.sync([zaehler(k)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([stand(k, z)])), fremd.userId).toEqual(['not_found']);
        const rev = await revOf('zaehler', z);
        expect(codes(await fremd.sync([upsert('zaehler', z, { inhalt: E1('x') }, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([remove('zaehler', z, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([remove('zaehlerstand', e, await revOf('zaehlerstaende', e))])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fremd.userId] }, await revOf('konversationen', k))])), fremd.userId).toEqual(['not_found']);
      }
      expect((await rows(sql`select inhalt from zaehler where id = ${z}`))[0]?.inhalt).toBe(E1('z'));
    });

    it('ein Kind kann sich nicht in die Liste schreiben oder schreiben lassen', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      const rev = await revOf('konversationen', k);
      expect(codes(await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.child.userId] }, rev)]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.child.userId] }, rev)]))).toEqual(['not_found']);
      expect((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer).toEqual([fam.parent.userId]);
    });
  });

  describe('Zähler und Stand', () => {
    it('Teilnehmer legen an und ändern; der Server setzt den Bearbeiter und prüft nur Form und Größe', async () => {
      const k = await haushalt(fam.parent, [fam.parent, fam.admin]);
      const id = await zae(fam.parent, k);
      expect((await rows(sql`select bearbeiter_id from zaehler where id = ${id}`))[0]?.bearbeiter_id).toBe(fam.parent.userId);
      const rev = await revOf('zaehler', id);
      expect((await fam.admin.sync([upsert('zaehler', id, { inhalt: E1('geaendert') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select bearbeiter_id, inhalt from zaehler where id = ${id}`))[0]).toMatchObject({ bearbeiter_id: fam.admin.userId, inhalt: E1('geaendert') });
      for (const inhalt of ['Strom 1234', 'z1:{}', 'e1:kurz', `e1:${'A'.repeat(100)}!${'A'.repeat(100)}`, `e1:${'A'.repeat(17_000)}`, '']) {
        expect(codes(await fam.parent.sync([zaehler(k, randomUUID(), inhalt)])), inhalt.slice(0, 12)).toEqual(['invalid']);
      }
      expect(codes(await fam.parent.sync([stand(k, id, randomUUID(), `e1:${'A'.repeat(2100)}`)]))).toEqual(['invalid']);
    });

    it('Zufalls-IDs (UUID v4); abgeleitete ID, fremde Konversation oder fremder Zähler werden abgelehnt; nur in der Zähler-Konversation', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      expect(codes(await fam.parent.sync([zaehler(k, uuidAusSchluessel('irgendwas'))]))).toEqual(['invalid']);
      const z = await zae(fam.parent, k);
      const gruppe = randomUUID();
      await fam.parent.sync([upsert('konversation', gruppe, { art: 'group', teilnehmer: [fam.parent.userId, fam.admin.userId] })]);
      expect(codes(await fam.parent.sync([zaehler(gruppe)]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([stand(gruppe, z)]))).not.toEqual([]);
    });

    it('Stand: anlegen, ändern (korrigieren), löschen; der Server löscht nie von selbst', async () => {
      const k = await haushalt(fam.parent, [fam.parent, fam.admin]);
      const z = await zae(fam.parent, k);
      const e = randomUUID();
      expect((await fam.admin.sync([stand(k, z, e)])).json.rejected).toEqual([]);
      const rev = await revOf('zaehlerstaende', e);
      expect((await fam.parent.sync([upsert('zaehlerstand', e, { inhalt: E1('korrigiert') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select bearbeiter_id from zaehlerstaende where id = ${e}`))[0]?.bearbeiter_id).toBe(fam.parent.userId);
      // ein sehr alter Stand bleibt (keine automatische Löschung, Jahresvergleiche brauchen Jahre)
      await world.db.execute(sql`update zaehlerstaende set created_at = now() - interval '5 years' where id = ${e}`);
      const { runSyncMaintenance } = await import('../src/sync/maintenance.js');
      await runSyncMaintenance(world.auth.ctx);
      expect(await rows(sql`select 1 from zaehlerstaende where id = ${e} and deleted_at is null`)).toHaveLength(1);
      expect((await fam.admin.sync([remove('zaehlerstand', e, await revOf('zaehlerstaende', e))])).json.acked).toHaveLength(1);
    });

    it('Konflikte je Feld: zwei Geräte ändern denselben Inhalt, das spätere verliert (Serverreihenfolge)', async () => {
      const k = await haushalt(fam.parent, [fam.parent, fam.admin]);
      const z = await zae(fam.parent, k);
      const rev = await revOf('zaehler', z);
      expect((await fam.parent.sync([upsert('zaehler', z, { inhalt: E1('eins') }, rev)])).json.conflicts).toEqual([]);
      const zweite = await fam.admin.sync([upsert('zaehler', z, { inhalt: E1('zwei') }, rev)]);
      expect(zweite.json.conflicts).toHaveLength(1);
      expect(zweite.json.conflicts[0].fields.inhalt).toBe(E1('eins'));
    });

    it('Löschen eines Zählers nimmt seine Stände mit (Kaskade, Tombstones für die Geräte)', async () => {
      const k = await haushalt(fam.parent, [fam.parent, fam.admin]);
      const z = await zae(fam.parent, k);
      const e1 = randomUUID();
      const e2 = randomUUID();
      await fam.admin.sync([stand(k, z, e1), stand(k, z, e2)]);
      await fam.admin.pull();
      expect((await fam.parent.sync([remove('zaehler', z, await revOf('zaehler', z))])).json.acked).toHaveLength(1);
      const c = await fam.admin.pull();
      expect(c.filter((x) => x.tombstone).map((x) => x.id).sort()).toEqual([z, e1, e2].sort());
      expect(codes(await fam.admin.sync([stand(k, z)]))).toEqual(['parent_deleted']);
    });

    it('Obergrenzen: höchstens so viele Zähler je Haushalt und Stände je Zähler', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      const z = await zae(fam.parent, k);
      await world.db.execute(sql`insert into zaehler (family_id, konversation_id, inhalt, rev) select ${fam.familyId}, ${k}, ${E1('x')}, 1 from generate_series(1, ${MAX_ZAEHLER_JE_HAUSHALT - 1})`);
      expect(codes(await fam.parent.sync([zaehler(k)]))).toEqual(['limit_reached']);
      await world.db.execute(sql`insert into zaehlerstaende (family_id, konversation_id, zaehler_id, inhalt, rev) select ${fam.familyId}, ${k}, ${z}, ${E1('x')}, 1 from generate_series(1, ${MAX_STAENDE})`);
      expect(codes(await fam.parent.sync([stand(k, z)]))).toEqual(['limit_reached']);
    });

    it('Mengenbegrenzung je Person und Minute für neue Stände', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      const z = await zae(fam.parent, k);
      let abgelehnt = 0;
      for (let i = 0; i < 70; i++) {
        const r = await fam.parent.sync([stand(k, z)]);
        if ((r.json.rejected as unknown[]).length > 0) abgelehnt++;
      }
      expect(abgelehnt).toBeGreaterThan(0);
    });
  });

  describe('Teilnehmerwechsel, Rollenwechsel und Entfernen', () => {
    it('Eltern kommen und gehen: nie ein Kind; die Liste darf nie leer werden', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      let rev = await revOf('konversationen', k);
      expect((await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.admin.userId] }, rev)])).json.acked).toHaveLength(1);
      rev = await revOf('konversationen', k);
      expect(codes(await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, kind2.userId] }, rev)]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', k, { teilnehmer: [] }, rev)]))).toEqual(['invalid']);
      // der Admin nimmt sich selbst heraus: er verliert die Sicht (hidden)
      await fam.admin.pull();
      expect((await fam.admin.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId] }, rev)])).json.acked).toHaveLength(1);
      expect((await fam.admin.pull()).find((x) => x.id === k)).toMatchObject({ tombstone: true, hidden: true });
    });

    it('Elternteil wird Kind: es fliegt sofort aus der Liste und bekommt hidden, ohne Inhalt; Kind wird Elternteil: nicht von selbst aufgenommen', async () => {
      const k = await haushalt(fam.parent, [fam.parent, papa, fam.admin]);
      const z = await zae(fam.parent, k);
      expect(ids(await papa.pull(), 'zaehler')).toEqual([z]);
      expect((await fam.admin.client.patch(`/api/v1/members/${papa.userId}/role`, { role: 'child' })).status).toBe(200);
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).sort()).toEqual([fam.parent.userId, fam.admin.userId].sort());
      // die Sitzung der Person endet beim Rollenwechsel; der Entzug der Sicht steht im Änderungsprotokoll (daraus entsteht `hidden`, nur die ID) und ihr Gerät muss neu synchronisieren
      const log = (await rows(sql`select changes from change_log where entity = 'konversation' and entity_id = ${k} order by rev desc limit 1`))[0]?.changes as Json;
      expect(JSON.stringify(log)).toContain(papa.userId);
      expect(JSON.stringify(log)).not.toContain(E1('z'));
      expect((await rows(sql`select resync_required from devices where user_id = ${papa.userId}`)).every((r) => r.resync_required === true)).toBe(true);
      // Kind wird Elternteil: der Server nimmt es nicht von selbst auf (das macht die App mit Schlüssel)
      expect((await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'parent' })).status).toBe(200);
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).includes(kind2.userId)).toBe(false);
      // die App nimmt es mit einer Änderung der Liste auf: jetzt gültig
      const rev = await revOf('konversationen', k);
      expect((await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.admin.userId, kind2.userId] }, rev)])).json.acked).toHaveLength(1);
      // zurück zum Kind: wieder entfernt
      await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'child' });
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).includes(kind2.userId)).toBe(false);
    });

    it('Person entfernt: sie fliegt aus der Liste, Zähler und Stände bleiben; die Konversation endet erst mit der letzten Person', async () => {
      const eltern = await extraMember(world, fam.admin, 'parent', 'weg@example.org');
      const k = await haushalt(fam.parent, [fam.parent, eltern]);
      const z = await zae(fam.parent, k);
      const res = await fam.admin.client.del(`/api/v1/members/${eltern.userId}`);
      expect(res.status, JSON.stringify(res.json)).toBe(200);
      expect((await rows(sql`select teilnehmer from konversationen where id = ${k} and deleted_at is null`))[0]?.teilnehmer).toEqual([fam.parent.userId]);
      expect(await rows(sql`select 1 from zaehler where id = ${z} and deleted_at is null`)).toHaveLength(1);
    });
  });

  describe('kein Wecker, kein Inhalt im Log', () => {
    it('weder die Konversation noch Zähler oder Stände lösen einen Push-Wecker aus', async () => {
      const mk = (op: ReturnType<typeof upsert>, by: Device) => applyOp(world.auth.ctx, defaultRegistry, { actor: { userId: by.userId, role: by.role as Role }, familyId: fam.familyId, deviceId: by.deviceId, op });
      const a = await mk(konv([fam.parent]), fam.parent);
      expect(a.outcome.status, JSON.stringify(a.outcome)).toBe('acked');
      expect(a.outcome.wake).toBe(false);
      expect(a.outcome.users).toEqual([fam.parent.userId]);
      const z = randomUUID();
      expect((await mk(zaehler(K(), z), fam.parent)).outcome.wake).toBe(false);
      expect((await mk(stand(K(), z), fam.parent)).outcome.wake).toBe(false);
      const g = await mk(upsert('konversation', randomUUID(), { art: 'group', teilnehmer: [fam.parent.userId, fam.admin.userId] }), fam.parent);
      expect(g.outcome.wake).not.toBe(false);
    });

    it('das Änderungsprotokoll hält nach Änderungen keine alten Inhalte (scrub), nach dem Löschen nichts', async () => {
      const k = await haushalt(fam.parent, [fam.parent]);
      const z = await zae(fam.parent, k);
      await fam.parent.sync([upsert('zaehler', z, { inhalt: E1('neu') }, await revOf('zaehler', z))]);
      const alt = await rows(sql`select changes from change_log where entity = 'zaehler' and entity_id = ${z} order by rev`);
      expect(alt.filter((r) => JSON.stringify(r.changes).includes(E1('z')))).toHaveLength(0);
      await fam.parent.sync([remove('zaehler', z, await revOf('zaehler', z))]);
      const nach = await rows(sql`select changes from change_log where entity = 'zaehler' and entity_id = ${z}`);
      expect(nach.every((r) => JSON.stringify(r.changes) === '{}')).toBe(true);
    });
  });
});
