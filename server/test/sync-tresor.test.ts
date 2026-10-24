// Tresor im Sync (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6m): EINE verborgene Konversation je Familie (Art `tresor`), Einträge als Kinder. Ein gemeinsamer Tresor für alle Eltern und Admins:
// Zugriff NUR für sie, Kinder sehen nichts und sind nie Teilnehmer. Der Server sieht nur undurchsichtige e1-Hüllen; geprüft werden Teilnehmer-Grenze, Rollen-Regel, feste ID, Kaskade,
// Konflikte, Limits, Wecker und das Protokoll.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../src/auth/types.js';
import { grantOperator } from '../src/operator/service.js';
import { applyOp } from '../src/sync/engine.js';
import { tresorChatId, uuidAusSchluessel, zaehlerChatId } from '../src/sync/entities/chat-ids.js';
import { tresorTeilnehmerBereinigt, tresorTeilnehmerGueltig } from '../src/sync/entities/tresor-regeln.js';
import { MAX_TRESOR_EINTRAEGE, tresorEintragEntity } from '../src/sync/entities/tresor.js';
import { defaultRegistry } from '../src/sync/index.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const E1 = (marker: string, laenge = 160) => `e1:${marker.replace(/[^A-Za-z0-9_-]/g, '_')}${'A'.repeat(laenge)}`;
const actor = (role: Role, userId: string): Actor => ({ role, userId });
// Known-Answer: muss exakt app/test/tresor_ids_test.dart entsprechen
const FAMILIE_KAT = '11111111-1111-4111-8111-111111111111';
const KAT_TRESOR = 'af79b489-d893-5427-9eae-468c85917458';

describe('Tresor-Konversation: feste ID (Known-Answer wie in der App)', () => {
  it('leitet die ID aus der Familie ab', () => {
    expect(tresorChatId(FAMILIE_KAT)).toBe(uuidAusSchluessel(`tresor:${FAMILIE_KAT}`));
    expect(tresorChatId(FAMILIE_KAT.toUpperCase())).toBe(tresorChatId(FAMILIE_KAT));
    expect(tresorChatId(FAMILIE_KAT)).toBe(KAT_TRESOR);
    expect(tresorChatId('22222222-2222-4222-8222-222222222222')).not.toBe(KAT_TRESOR);
    expect(tresorChatId(FAMILIE_KAT)).not.toBe(zaehlerChatId(FAMILIE_KAT));
  });
});

describe('Tresor-Konversation: Rollen-Regel der Teilnehmer (rein)', () => {
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
    expect(tresorTeilnehmerGueltig(liste, R)).toBe(erwartet);
  });

  it('bereinigt nach einem Rollenwechsel', () => {
    expect(tresorTeilnehmerBereinigt(['a1', 'p1'], rollen({ a1: 'admin', p1: 'child' }), ['a1'])).toEqual(['a1']);
    expect(tresorTeilnehmerBereinigt(['a1', 'p1'], R, ['a1', 'p1'])).toEqual(['a1', 'p1']);
    // niemand übrig: ersatzweise alle aktiven Erwachsenen, nie ein Kind
    expect(tresorTeilnehmerBereinigt(['p1'], rollen({ a1: 'admin', p1: 'child' }), ['a1'])).toEqual(['a1']);
  });
});

describe('Tresor-Eintrag: Rechte-Modell (Regeltabelle)', () => {
  const A = 'u-admin';
  const E = 'u-eltern';
  const K = 'u-kind';
  const privat = (owner: string | null, teilnehmer: string[]): Facts => ({ audience: 'family', ownerId: owner, participants: teilnehmer, quiet: true });
  const def = tresorEintragEntity;

  it('Eltern und Admins (als Teilnehmer): lesen, anlegen, ändern, löschen, auch Einträge der anderen; nie als Unbeteiligte', () => {
    for (const role of ['admin', 'parent'] as const) {
      // der Eintrag gehört (zuletzt) der anderen Person: der Tresor ist gemeinsam, es gibt keine Einträge "nur ich"
      for (const owner of [A, E, null]) {
        const f = privat(owner, [A, E]);
        for (const teil of [A, E]) {
          expect(mayRead(def.rules, actor(role, teil), f), `${role} lesen`).toBe(true);
          expect(authorize(def.rules, 'create', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'update', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'delete', actor(role, teil), f)).toBe('ok');
        }
      }
      const f = privat(A, [A, E]);
      expect(mayRead(def.rules, actor(role, 'u-fremd'), f)).toBe(false);
      expect(authorize(def.rules, 'create', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('forbidden');
      expect(authorize(def.rules, 'update', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('not_found');
      expect(authorize(def.rules, 'delete', actor(role, 'u-fremd'), f)).toBe('not_found');
      expect(authorize(def.rules, 'update', actor(role, A), f, ['konversationId'])).toBe('forbidden');
    }
  });

  it('Kinder: kein Recht, auch nicht als (hypothetischer) Teilnehmer', () => {
    for (const f of [privat(A, [A, E]), privat(A, [A, E, K]), { audience: 'family', ownerId: K, participants: undefined } as Facts]) {
      expect(mayRead(def.rules, actor('child', K), f)).toBe(false);
      expect(authorize(def.rules, 'create', actor('child', K), f, ['inhalt'])).toBe('forbidden');
      expect(authorize(def.rules, 'update', actor('child', K), f, ['inhalt'])).toBe('not_found');
      expect(authorize(def.rules, 'delete', actor('child', K), f)).toBe('not_found');
    }
  });

  it('weckt nie per Push', () => {
    expect(def.noWake).toBe(true);
  });
});

describe.each(backends)('Tresor im Sync ($name)', (backend) => {
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
    await world.db.execute(sql`truncate table tresor_eintraege`);
    for (const d of [fam.admin, fam.parent, fam.child, kind2, papa]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const codes = (res: { json: Json }) => (res.json.rejected as Array<{ code: string }>).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);
  const revOf = async (table: string, id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);

  const K = () => tresorChatId(fam.familyId);
  /** Tresor-Konversation mit den Teilnehmern. */
  const konv = (teilnehmer: Device[], extra: Json = {}) => upsert('konversation', K(), { art: 'tresor', teilnehmer: teilnehmer.map((t) => t.userId), ...extra });
  async function tresor(by: Device, teilnehmer: Device[]): Promise<string> {
    const res = await by.sync([konv(teilnehmer)]);
    expect(res.json.rejected, JSON.stringify(res.json)).toEqual([]);
    return K();
  }
  const eintrag = (k: string, id: string = randomUUID(), inhalt = E1('t')) => upsert('tresor_eintrag', id, { konversationId: k, inhalt });
  async function eint(by: Device, k: string): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([eintrag(k, id)]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }

  describe('Anlegen der Konversation: Rollen-Regel und feste ID', () => {
    it('Elternteil und Admin legen sie an (allein oder gemeinsam)', async () => {
      expect((await fam.parent.sync([konv([fam.parent, fam.admin, papa])])).json.rejected).toEqual([]);
      expect(await rows(sql`select 1 from konversationen where id = ${K()} and art::text = 'tresor' and subjekt_id is null`)).toHaveLength(1);
    });

    it('Kind kann sie nie anlegen (kein Teilnehmer, kein Recht); ein Kind in der Liste wird abgelehnt', async () => {
      expect(codes(await fam.child.sync([konv([fam.parent])]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([konv([fam.child])]))).not.toEqual([]);
      expect(codes(await fam.parent.sync([konv([fam.parent, fam.child])]))).toEqual(['invalid']);
      expect(codes(await fam.admin.sync([konv([fam.admin, kind2])]))).toEqual(['invalid']);
      expect(await rows(sql`select 1 from konversationen where art::text = 'tresor'`)).toHaveLength(0);
    });

    it('ohne sich selbst als Teilnehmer: kein Recht; Subjekt, Name, Klartext, Zufalls-ID und fremde oder Zähler-ID werden abgelehnt', async () => {
      expect(codes(await fam.parent.sync([konv([fam.admin])]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([konv([fam.parent], { subjektId: fam.parent.userId })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'tresor', teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', tresorChatId(randomUUID()), { art: 'tresor', teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('konversation', zaehlerChatId(fam.familyId), { art: 'tresor', teilnehmer: [fam.parent.userId] })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([konv([fam.parent], { titel: 'Tresor' })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([konv([fam.parent], { encVersion: 'p1' })]))).toEqual(['invalid']);
    });

    it('ist nie löschbar, Name unveränderlich', async () => {
      const k = await tresor(fam.parent, [fam.parent, fam.admin]);
      const rev = await revOf('konversationen', k);
      expect(codes(await fam.parent.sync([remove('konversation', k, rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.parent.sync([upsert('konversation', k, { titel: 'x' }, rev)]))).toEqual(['forbidden']);
    });

    it('Nachrichten gibt es dort nie', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      expect(codes(await fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: k, text: E1('hallo') })]))).toEqual(['invalid']);
    });
  });

  describe('Sicht: nur Eltern und Admins, alle gemeinsam', () => {
    it('alle Teilnehmer sehen Konversation und alle Einträge (auch die der anderen); Kinder sehen nichts, auch keine IDs oder hidden-Spuren', async () => {
      const k = await tresor(fam.parent, [fam.parent, fam.admin]);
      const e1 = await eint(fam.parent, k);
      const e2 = await eint(fam.admin, k);
      for (const d of [fam.parent, fam.admin]) {
        d.sinceRev = 0;
        const c = await d.pull();
        expect(ids(c, 'konversation'), d.userId).toEqual([k]);
        expect(ids(c, 'tresor_eintrag').sort(), d.userId).toEqual([e1, e2].sort());
      }
      for (const d of [fam.child, kind2]) {
        const c = await d.pull();
        expect(c.filter((x) => [k, e1, e2].includes(x.id as string)), d.userId).toEqual([]);
        expect(c.filter((x) => x.entity === 'tresor_eintrag')).toEqual([]);
      }
      // auch ein Elternteil, das (noch) nicht in der Liste steht, sieht nichts (Teilnehmer-Grenze, kein Rollen-Durchgriff)
      expect(ids(await papa.pull(), 'tresor_eintrag')).toEqual([]);
    });

    it('das Betreiber-Flag und die Familienrolle ändern nichts', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      await eint(fam.parent, k);
      await grantOperator(world.auth.ctx, 'admin@example.org');
      expect(ids(await fam.admin.pull(), 'tresor_eintrag')).toEqual([]);
      expect(ids(await fam.admin.pull(), 'konversation')).toEqual([]);
      await world.db.execute(sql`update memberships set family_role = 'vater' where user_id = ${fam.child.userId}`);
      expect(ids(await fam.child.pull(), 'tresor_eintrag')).toEqual([]);
    });

    it('Unbeteiligte (auch Kinder) können nichts lesen, anlegen, ändern, löschen: not_found (IDOR)', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      const e = await eint(fam.parent, k);
      for (const fremd of [fam.admin, papa, fam.child, kind2]) {
        expect(codes(await fremd.sync([eintrag(k)])), fremd.userId).toEqual(['not_found']);
        const rev = await revOf('tresor_eintraege', e);
        expect(codes(await fremd.sync([upsert('tresor_eintrag', e, { inhalt: E1('x') }, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([remove('tresor_eintrag', e, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fremd.userId] }, await revOf('konversationen', k))])), fremd.userId).toEqual(['not_found']);
      }
      expect((await rows(sql`select inhalt from tresor_eintraege where id = ${e}`))[0]?.inhalt).toBe(E1('t'));
    });

    it('ein Kind kann sich nicht in die Liste schreiben oder schreiben lassen', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      const rev = await revOf('konversationen', k);
      expect(codes(await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.child.userId] }, rev)]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.child.userId] }, rev)]))).toEqual(['not_found']);
      expect((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer).toEqual([fam.parent.userId]);
    });
  });

  describe('Eintrag', () => {
    it('Teilnehmer legen an und ändern (auch fremde Einträge); der Server setzt den Bearbeiter und prüft nur Form und Größe', async () => {
      const k = await tresor(fam.parent, [fam.parent, fam.admin]);
      const id = await eint(fam.parent, k);
      expect((await rows(sql`select bearbeiter_id from tresor_eintraege where id = ${id}`))[0]?.bearbeiter_id).toBe(fam.parent.userId);
      const rev = await revOf('tresor_eintraege', id);
      expect((await fam.admin.sync([upsert('tresor_eintrag', id, { inhalt: E1('geaendert') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select bearbeiter_id, inhalt from tresor_eintraege where id = ${id}`))[0]).toMatchObject({ bearbeiter_id: fam.admin.userId, inhalt: E1('geaendert') });
      // Klartext, andere Formate, zu kurz, falscher Zeichensatz, zu lang, leer
      for (const inhalt of ['WLAN geheim123', 't1:{}', 'e1:kurz', `e1:${'A'.repeat(100)}!${'A'.repeat(100)}`, `e1:${'A'.repeat(25_000)}`, '']) {
        expect(codes(await fam.parent.sync([eintrag(k, randomUUID(), inhalt)])), inhalt.slice(0, 12)).toEqual(['invalid']);
      }
      // 16 KB Klartext = rund 21 700 Zeichen Hülle gehen durch
      expect(codes(await fam.parent.sync([eintrag(k, randomUUID(), E1('gross', 22_000))]))).toEqual([]);
    });

    it('Zufalls-IDs (UUID v4); abgeleitete ID, fremde Konversation oder Gruppe werden abgelehnt', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      expect(codes(await fam.parent.sync([eintrag(k, uuidAusSchluessel('irgendwas'))]))).toEqual(['invalid']);
      const gruppe = randomUUID();
      await fam.parent.sync([upsert('konversation', gruppe, { art: 'group', teilnehmer: [fam.parent.userId, fam.admin.userId] })]);
      expect(codes(await fam.parent.sync([eintrag(gruppe)]))).toEqual(['invalid']);
      // die Zähler-Konversation ist kein Tresor
      const zk = zaehlerChatId(fam.familyId);
      await fam.parent.sync([upsert('konversation', zk, { art: 'zaehler', teilnehmer: [fam.parent.userId] })]);
      expect(codes(await fam.parent.sync([eintrag(zk)]))).toEqual(['invalid']);
    });

    it('der Server löscht nie von selbst; Löschen durch ein anderes Elternteil mit Tombstone für die Geräte', async () => {
      const k = await tresor(fam.parent, [fam.parent, fam.admin]);
      const e = await eint(fam.parent, k);
      await world.db.execute(sql`update tresor_eintraege set created_at = now() - interval '5 years' where id = ${e}`);
      const { runSyncMaintenance } = await import('../src/sync/maintenance.js');
      await runSyncMaintenance(world.auth.ctx);
      expect(await rows(sql`select 1 from tresor_eintraege where id = ${e} and deleted_at is null`)).toHaveLength(1);
      await fam.parent.pull();
      expect((await fam.admin.sync([remove('tresor_eintrag', e, await revOf('tresor_eintraege', e))])).json.acked).toHaveLength(1);
      expect((await fam.parent.pull()).find((x) => x.id === e)).toMatchObject({ tombstone: true });
    });

    it('Konflikte je Feld: zwei Geräte ändern denselben Inhalt, das spätere verliert (Serverreihenfolge)', async () => {
      const k = await tresor(fam.parent, [fam.parent, fam.admin]);
      const e = await eint(fam.parent, k);
      const rev = await revOf('tresor_eintraege', e);
      expect((await fam.parent.sync([upsert('tresor_eintrag', e, { inhalt: E1('eins') }, rev)])).json.conflicts).toEqual([]);
      const zweite = await fam.admin.sync([upsert('tresor_eintrag', e, { inhalt: E1('zwei') }, rev)]);
      expect(zweite.json.conflicts).toHaveLength(1);
      expect(zweite.json.conflicts[0].fields.inhalt).toBe(E1('eins'));
    });

    it('Kaskade: Löschen der Konversation nimmt die Einträge mit (Datenbank)', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      await eint(fam.parent, k);
      await world.db.execute(sql`delete from konversationen where id = ${k}`);
      expect(await rows(sql`select 1 from tresor_eintraege`)).toHaveLength(0);
    });

    it('Obergrenze: höchstens so viele Einträge je Tresor', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      await world.db.execute(sql`insert into tresor_eintraege (family_id, konversation_id, inhalt, rev) select ${fam.familyId}, ${k}, ${E1('x')}, 1 from generate_series(1, ${MAX_TRESOR_EINTRAEGE})`);
      expect(codes(await fam.parent.sync([eintrag(k)]))).toEqual(['limit_reached']);
    });

    it('Mengenbegrenzung je Person und Minute für neue Einträge', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      let abgelehnt = 0;
      for (let i = 0; i < 40; i++) {
        const r = await fam.parent.sync([eintrag(k)]);
        if ((r.json.rejected as unknown[]).length > 0) abgelehnt++;
      }
      expect(abgelehnt).toBeGreaterThan(0);
    });
  });

  describe('Teilnehmerwechsel, Rollenwechsel und Entfernen', () => {
    it('Eltern kommen und gehen: nie ein Kind; die Liste darf nie leer werden', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
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

    it('Elternteil wird Kind: es fliegt sofort aus der Liste und bekommt hidden, ohne Inhalt; Kind wird Elternteil: nicht von selbst aufgenommen, die App tut es', async () => {
      const k = await tresor(fam.parent, [fam.parent, papa, fam.admin]);
      const e = await eint(fam.parent, k);
      expect(ids(await papa.pull(), 'tresor_eintrag')).toEqual([e]);
      expect((await fam.admin.client.patch(`/api/v1/members/${papa.userId}/role`, { role: 'child' })).status).toBe(200);
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).sort()).toEqual([fam.parent.userId, fam.admin.userId].sort());
      // der Entzug der Sicht steht im Änderungsprotokoll (daraus entsteht `hidden`, nur die ID), ohne Inhalt; das Gerät muss neu synchronisieren
      const log = (await rows(sql`select changes from change_log where entity = 'konversation' and entity_id = ${k} order by rev desc limit 1`))[0]?.changes as Json;
      expect(JSON.stringify(log)).toContain(papa.userId);
      expect(JSON.stringify(log)).not.toContain(E1('t'));
      expect((await rows(sql`select resync_required from devices where user_id = ${papa.userId}`)).every((r) => r.resync_required === true)).toBe(true);
      // Kind wird Elternteil: der Server nimmt es nicht von selbst auf (das macht die App mit Schlüssel)
      expect((await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'parent' })).status).toBe(200);
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).includes(kind2.userId)).toBe(false);
      // die App nimmt es mit einer Änderung der Liste auf: jetzt gültig, die Person steht in der Liste (ihre Sitzung endete beim Rollenwechsel)
      const rev = await revOf('konversationen', k);
      expect((await fam.parent.sync([upsert('konversation', k, { teilnehmer: [fam.parent.userId, fam.admin.userId, kind2.userId] }, rev)])).json.acked).toHaveLength(1);
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).includes(kind2.userId)).toBe(true);
      // zurück zum Kind: wieder entfernt
      await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'child' });
      expect(((await rows(sql`select teilnehmer from konversationen where id = ${k}`))[0]?.teilnehmer as string[]).includes(kind2.userId)).toBe(false);
    });

    it('Person entfernt: sie fliegt aus der Liste, die Einträge bleiben', async () => {
      const eltern = await extraMember(world, fam.admin, 'parent', 'weg@example.org');
      const k = await tresor(fam.parent, [fam.parent, eltern]);
      const e = await eint(fam.parent, k);
      const res = await fam.admin.client.del(`/api/v1/members/${eltern.userId}`);
      expect(res.status, JSON.stringify(res.json)).toBe(200);
      expect((await rows(sql`select teilnehmer from konversationen where id = ${k} and deleted_at is null`))[0]?.teilnehmer).toEqual([fam.parent.userId]);
      expect(await rows(sql`select 1 from tresor_eintraege where id = ${e} and deleted_at is null`)).toHaveLength(1);
    });
  });

  describe('kein Wecker, kein Inhalt im Log', () => {
    it('weder die Konversation noch Einträge lösen einen Push-Wecker aus', async () => {
      const mk = (op: ReturnType<typeof upsert>, by: Device) => applyOp(world.auth.ctx, defaultRegistry, { actor: { userId: by.userId, role: by.role as Role }, familyId: fam.familyId, deviceId: by.deviceId, op });
      const a = await mk(konv([fam.parent]), fam.parent);
      expect(a.outcome.status, JSON.stringify(a.outcome)).toBe('acked');
      expect(a.outcome.wake).toBe(false);
      expect(a.outcome.users).toEqual([fam.parent.userId]);
      expect((await mk(eintrag(K()), fam.parent)).outcome.wake).toBe(false);
      const g = await mk(upsert('konversation', randomUUID(), { art: 'group', teilnehmer: [fam.parent.userId, fam.admin.userId] }), fam.parent);
      expect(g.outcome.wake).not.toBe(false);
    });

    it('das Änderungsprotokoll hält nach Änderungen keine alten Inhalte (scrub), nach dem Löschen nichts', async () => {
      const k = await tresor(fam.parent, [fam.parent]);
      const e = await eint(fam.parent, k);
      await fam.parent.sync([upsert('tresor_eintrag', e, { inhalt: E1('neu') }, await revOf('tresor_eintraege', e))]);
      const alt = await rows(sql`select changes from change_log where entity = 'tresor_eintrag' and entity_id = ${e} order by rev`);
      expect(alt.filter((r) => JSON.stringify(r.changes).includes(E1('t')))).toHaveLength(0);
      await fam.parent.sync([remove('tresor_eintrag', e, await revOf('tresor_eintraege', e))]);
      const nach = await rows(sql`select changes from change_log where entity = 'tresor_eintrag' and entity_id = ${e}`);
      expect(nach.every((r) => JSON.stringify(r.changes) === '{}')).toBe(true);
    });
  });
});
