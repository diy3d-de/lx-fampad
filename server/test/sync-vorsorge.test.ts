// Vorsorge und Impfungen im Sync (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 6p): Profil und Einträge als Kinder der Medikamenten-Konversation (`meds`) einer Person.
// Gesundheitsdaten: Sicht wie bei den Medikamenten (Erwachsene nie die eines anderen Erwachsenen, auch Admins nicht; Eltern/Admins zusätzlich die ihrer Kinder; Kinder nur die
// eigenen). Der Server sieht nur undurchsichtige e1-Hüllen.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Role } from '../src/auth/types.js';
import { grantOperator } from '../src/operator/service.js';
import { applyOp } from '../src/sync/engine.js';
import { medsChatId, uuidAusSchluessel, vorsorgeProfilId } from '../src/sync/entities/chat-ids.js';
import { MAX_VORSORGE_EINTRAEGE, vorsorgeEintragEntity, vorsorgeProfilEntity } from '../src/sync/entities/vorsorge.js';
import { defaultRegistry } from '../src/sync/index.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const E1 = (marker: string) => `e1:${marker.replace(/[^A-Za-z0-9_-]/g, '_')}${'A'.repeat(160)}`;
const actor = (role: Role, userId: string): Actor => ({ role, userId });

describe('Vorsorge-Profil: feste ID (Known-Answer wie in der App)', () => {
  it('leitet die ID aus der Konversation ab', () => {
    const k = '9a34c21c-7257-562d-b9c3-eb7b59ff6244';
    expect(vorsorgeProfilId(k)).toBe(uuidAusSchluessel(`vorsorge-profil:${k}`));
    expect(vorsorgeProfilId(k.toUpperCase())).toBe(vorsorgeProfilId(k));
    // Known-Answer: muss exakt app/test/vorsorge_ids_test.dart entsprechen
    expect(vorsorgeProfilId(k)).toBe('02dfdb56-dbdd-583b-ab94-86a5ea105baa');
    expect(medsChatId('22222222-2222-4222-8222-222222222222')).toBe(k);
  });
});

describe('Vorsorge: Rechte-Modell (Regeltabelle)', () => {
  const S = 'u-subjekt';
  const E = 'u-eltern';
  const privat = (owner: string | null, teilnehmer: string[]): Facts => ({ audience: 'family', ownerId: owner, participants: teilnehmer, quiet: true });

  it('nur Teilnehmer lesen, anlegen, ändern, löschen; nie ein Unbeteiligter (kein Rollen-Durchgriff, auch Admin nicht)', () => {
    for (const def of [vorsorgeProfilEntity, vorsorgeEintragEntity]) {
      for (const role of ['admin', 'parent', 'child'] as const) {
        const f = privat(S, [S, E]);
        for (const teil of [S, E]) {
          expect(mayRead(def.rules, actor(role, teil), f), `${def.name} ${role} lesen`).toBe(true);
          expect(authorize(def.rules, 'create', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'update', actor(role, teil), f, ['inhalt'])).toBe('ok');
          expect(authorize(def.rules, 'delete', actor(role, teil), f)).toBe('ok');
        }
        expect(mayRead(def.rules, actor(role, 'u-fremd'), f), `${def.name} ${role} Fremder`).toBe(false);
        expect(authorize(def.rules, 'create', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('forbidden');
        expect(authorize(def.rules, 'update', actor(role, 'u-fremd'), f, ['inhalt'])).toBe('not_found');
        expect(authorize(def.rules, 'delete', actor(role, 'u-fremd'), f)).toBe('not_found');
        expect(authorize(def.rules, 'update', actor(role, S), f, ['konversationId'])).toBe('forbidden');
      }
      expect(def.noWake).toBe(true);
    }
  });
});

describe.each(backends)('Vorsorge im Sync ($name)', (backend) => {
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
    for (const d of [fam.admin, fam.parent, fam.child, kind2, admin2]) d.sinceRev = 0;
  });

  const rows = async (query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];
  const codes = (res: { json: Json }) => (res.json.rejected as Array<{ code: string }>).map((r) => r.code);
  const ids = (changes: Json[], entity?: string) => changes.filter((c) => !entity || c.entity === entity).map((c) => c.id as string);
  const revOf = async (table: string, id: string) => Number((await rows(sql`select rev from ${sql.raw(table)} where id = ${id}`))[0]?.rev);

  const konv = (subjekt: Device, teilnehmer: Device[]) => upsert('konversation', medsChatId(subjekt.userId), { art: 'meds', subjektId: subjekt.userId, teilnehmer: teilnehmer.map((t) => t.userId) });
  async function plan(by: Device, subjekt: Device, teilnehmer: Device[]): Promise<string> {
    const res = await by.sync([konv(subjekt, teilnehmer)]);
    expect(res.json.rejected, JSON.stringify(res.json)).toEqual([]);
    return medsChatId(subjekt.userId);
  }
  const profil = (k: string, inhalt = E1('p')) => upsert('vorsorge_profil', vorsorgeProfilId(k), { konversationId: k, inhalt });
  const eintrag = (k: string, id: string = randomUUID(), inhalt = E1('v')) => upsert('vorsorge_eintrag', id, { konversationId: k, inhalt });
  async function beide(by: Device, k: string): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([profil(k), eintrag(k, id)]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }

  describe('Sicht: wer welche Vorsorge-Daten sieht', () => {
    it('Erwachsener sieht nie die Daten eines anderen Erwachsenen (auch Admin nicht), Kind weder Erwachsene noch Geschwister', async () => {
      const ks = [
        [fam.parent, await plan(fam.parent, fam.parent, [fam.parent])],
        [admin2, await plan(admin2, admin2, [admin2])],
        [fam.admin, await plan(fam.admin, fam.admin, [fam.admin])],
        [fam.child, await plan(fam.child, fam.child, [fam.child])],
        [kind2, await plan(kind2, kind2, [kind2])],
      ] as const;
      for (const [d, k] of ks) await beide(d, k);
      for (const d of [fam.parent, admin2, fam.admin, fam.child, kind2]) {
        d.sinceRev = 0;
        const c = await d.pull();
        expect(ids(c, 'vorsorge_eintrag'), d.userId).toHaveLength(1);
        expect(ids(c, 'vorsorge_profil'), d.userId).toHaveLength(1);
      }
    });

    it('Eltern und Admins sehen zusätzlich die Daten ihrer Kinder (nur als Teilnehmer); andere Erwachsene und Geschwister nie', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent, fam.admin]);
      const e = await beide(fam.parent, k);
      for (const d of [fam.child, fam.parent, fam.admin]) {
        d.sinceRev = 0;
        const c = await d.pull();
        expect(ids(c, 'vorsorge_eintrag'), d.userId).toEqual([e]);
        expect(ids(c, 'vorsorge_profil'), d.userId).toEqual([vorsorgeProfilId(k)]);
      }
      for (const d of [admin2, kind2]) {
        const c = await d.pull();
        expect(c.filter((x) => ['vorsorge_eintrag', 'vorsorge_profil'].includes(x.entity as string)), d.userId).toEqual([]);
      }
    });

    it('das Betreiber-Flag ändert nichts an der Sicht', async () => {
      const k = await plan(fam.parent, fam.parent, [fam.parent]);
      await beide(fam.parent, k);
      await grantOperator(world.auth.ctx, 'admin@example.org');
      expect(ids(await fam.admin.pull(), 'vorsorge_eintrag')).toEqual([]);
    });

    it('Unbeteiligte: not_found (IDOR) beim Anlegen, Ändern und Löschen', async () => {
      const k = await plan(fam.parent, fam.parent, [fam.parent]);
      const e = await beide(fam.parent, k);
      for (const fremd of [fam.admin, admin2, fam.child]) {
        expect(codes(await fremd.sync([eintrag(k)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([profil(k)])), fremd.userId).toEqual(['not_found']);
        const rev = await revOf('vorsorge_eintraege', e);
        expect(codes(await fremd.sync([upsert('vorsorge_eintrag', e, { inhalt: E1('x') }, rev)])), fremd.userId).toEqual(['not_found']);
        expect(codes(await fremd.sync([remove('vorsorge_eintrag', e, rev)])), fremd.userId).toEqual(['not_found']);
      }
      expect((await rows(sql`select inhalt from vorsorge_eintraege where id = ${e}`))[0]?.inhalt).toBe(E1('v'));
    });
  });

  describe('Profil und Eintrag', () => {
    it('Teilnehmer legen an und ändern; der Server setzt den Bearbeiter und prüft nur Form und Größe', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const id = await beide(fam.child, k);
      expect((await rows(sql`select bearbeiter_id from vorsorge_eintraege where id = ${id}`))[0]?.bearbeiter_id).toBe(fam.child.userId);
      const rev = await revOf('vorsorge_eintraege', id);
      expect((await fam.parent.sync([upsert('vorsorge_eintrag', id, { inhalt: E1('neu') }, rev)])).json.acked).toHaveLength(1);
      expect((await rows(sql`select bearbeiter_id from vorsorge_eintraege where id = ${id}`))[0]?.bearbeiter_id).toBe(fam.parent.userId);
      for (const inhalt of ['Impfung', 'v1:{}', 'e1:kurz', `e1:${'A'.repeat(100)}!`, `e1:${'A'.repeat(9000)}`, '']) {
        expect(codes(await fam.child.sync([eintrag(k, randomUUID(), inhalt)])), inhalt.slice(0, 12)).toEqual(['invalid']);
      }
      expect(codes(await fam.child.sync([profil(k, `e1:${'A'.repeat(2100)}`)]))).toEqual(['invalid']);
    });

    it('Profil: nur die feste ID dieser Konversation (nie Zufalls-ID, nie die einer anderen Person), je Person genau eines', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const kMama = await plan(fam.parent, fam.parent, [fam.parent]);
      expect(codes(await fam.child.sync([upsert('vorsorge_profil', randomUUID(), { konversationId: k, inhalt: E1('p') })]))).toEqual(['invalid']);
      expect(codes(await fam.child.sync([upsert('vorsorge_profil', vorsorgeProfilId(kMama), { konversationId: k, inhalt: E1('p') })]))).toEqual(['invalid']);
      expect((await fam.child.sync([profil(k)])).json.rejected).toEqual([]);
      expect((await rows(sql`select count(*)::int as n from vorsorge_profile where konversation_id = ${k}`))[0]?.n).toBe(1);
    });

    it('Eintrag: Zufalls-IDs (UUID v4); Bezug nur auf eine verschlüsselte meds-Konversation', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      expect(codes(await fam.child.sync([eintrag(k, uuidAusSchluessel('irgendwas'))]))).toEqual(['invalid']);
      const gruppe = randomUUID();
      await fam.parent.sync([upsert('konversation', gruppe, { art: 'group', teilnehmer: [fam.parent.userId, fam.admin.userId] })]);
      expect(codes(await fam.parent.sync([eintrag(gruppe)]))).toEqual(['invalid']);
    });

    it('Einträge sind löschbar und es gibt keine automatische Löschung; Konflikte je Feld', async () => {
      const k = await plan(fam.parent, fam.child, [fam.child, fam.parent]);
      const e = await beide(fam.parent, k);
      const rev = await revOf('vorsorge_eintraege', e);
      expect((await fam.parent.sync([upsert('vorsorge_eintrag', e, { inhalt: E1('eins') }, rev)])).json.conflicts).toEqual([]);
      const zweite = await fam.child.sync([upsert('vorsorge_eintrag', e, { inhalt: E1('zwei') }, rev)]);
      expect(zweite.json.conflicts).toHaveLength(1);
      await world.db.execute(sql`update vorsorge_eintraege set created_at = now() - interval '5 years' where id = ${e}`);
      await fam.child.pull();
      const { runSyncMaintenance } = await import('../src/sync/maintenance.js');
      await runSyncMaintenance(world.auth.ctx);
      expect(await rows(sql`select 1 from vorsorge_eintraege where id = ${e} and deleted_at is null`)).toHaveLength(1);
      expect((await fam.child.sync([remove('vorsorge_eintrag', e, await revOf('vorsorge_eintraege', e))])).json.acked).toHaveLength(1);
    });

    it('Obergrenze je Person', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      await world.db.execute(sql`insert into vorsorge_eintraege (family_id, konversation_id, inhalt, rev) select ${fam.familyId}, ${k}, ${E1('x')}, 1 from generate_series(1, ${MAX_VORSORGE_EINTRAEGE})`);
      expect(codes(await fam.child.sync([eintrag(k)]))).toEqual(['limit_reached']);
    });
  });

  describe('Rollenwechsel und Entfernen ziehen die Sicht nach', () => {
    it('Kind wird Erwachsener: die Eltern verlieren die Sicht (hidden), nichts bleibt sichtbar', async () => {
      const k = await plan(fam.parent, kind2, [kind2, fam.parent, fam.admin]);
      await beide(fam.parent, k);
      expect(ids(await fam.parent.pull(), 'vorsorge_eintrag')).toHaveLength(1);
      expect((await fam.admin.client.patch(`/api/v1/members/${kind2.userId}/role`, { role: 'parent' })).status).toBe(200);
      const c = await fam.parent.pull();
      expect(c.find((x) => x.entity === 'konversation' && x.id === k)).toMatchObject({ tombstone: true, hidden: true });
      fam.parent.sinceRev = 0;
      expect(ids(await fam.parent.pull(), 'vorsorge_eintrag')).toEqual([]);
    });

    it('Person entfernt: Profil und Einträge verschwinden mit der Konversation', async () => {
      const x = await extraMember(world, fam.admin, 'child', 'weg@example.org');
      const kWeg = await plan(x, x, [x]);
      const e = await beide(x, kWeg);
      expect((await fam.admin.client.del(`/api/v1/members/${x.userId}`)).status).toBe(200);
      expect(await rows(sql`select 1 from vorsorge_eintraege where id = ${e} and deleted_at is null`)).toHaveLength(0);
      expect(await rows(sql`select 1 from vorsorge_profile where konversation_id = ${kWeg} and deleted_at is null`)).toHaveLength(0);
    });
  });

  describe('kein Wecker, kein Inhalt im Log', () => {
    it('weder Profil noch Eintrag lösen einen Push-Wecker aus', async () => {
      const mk = (op: ReturnType<typeof upsert>, by: Device) => applyOp(world.auth.ctx, defaultRegistry, { actor: { userId: by.userId, role: by.role as Role }, familyId: fam.familyId, deviceId: by.deviceId, op });
      const k = medsChatId(fam.child.userId);
      expect((await mk(konv(fam.child, [fam.child]), fam.child)).outcome.status).toBe('acked');
      expect((await mk(profil(k), fam.child)).outcome.wake).toBe(false);
      expect((await mk(eintrag(k), fam.child)).outcome.wake).toBe(false);
    });

    it('das Änderungsprotokoll hält nach Änderungen keine alten Inhalte', async () => {
      const k = await plan(fam.child, fam.child, [fam.child]);
      const e = await beide(fam.child, k);
      await fam.child.sync([upsert('vorsorge_eintrag', e, { inhalt: E1('neu') }, await revOf('vorsorge_eintraege', e))]);
      const alt = await rows(sql`select changes from change_log where entity = 'vorsorge_eintrag' and entity_id = ${e} order by rev`);
      expect(alt.filter((r) => JSON.stringify(r.changes).includes(E1('v')))).toHaveLength(0);
    });
  });
});
