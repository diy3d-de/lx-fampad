// Rechte-Modell des Sync: Regeltabelle (rein), Rollen je Aktion, Freigabe-Stufen, fremde Familie (IDOR), Verweise auf Mitglieder.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { listEntity, listItemEntity } from '../src/sync/entities/lists.js';
import { authorize, AUDIENCES, mayRead, ROLES, sees, type Actor, type Audience, type Decision, type Facts } from '../src/sync/permissions.js';
import { defaultRegistry } from '../src/sync/index.js';
import type { Role } from '../src/auth/types.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, resetSync, remove, upsert, type Family, type Json } from './sync-kit.js';

const actor = (role: Role, userId = 'u-self'): Actor => ({ role, userId });
const facts = (audience: Audience, ownerId: string | null = null): Facts => ({ audience, ownerId });

describe('Rechte-Modell (Regeltabelle)', () => {
  it('Freigabe-Stufen: Eltern sehen alles, Kinder nicht "nur Eltern"; Gäste und die Stufe "all" gibt es nicht', () => {
    const seen = Object.fromEntries(AUDIENCES.map((a) => [a, ROLES.filter((r) => sees(r, a))]));
    expect(seen).toEqual({
      parents: ['admin', 'parent'],
      family: ['admin', 'parent', 'child'],
    });
    expect([...ROLES]).toEqual(['admin', 'parent', 'child']);
    for (const def of defaultRegistry.list()) expect(Object.keys(def.rules).sort(), def.name).toEqual(['admin', 'child', 'parent']);
  });

  const act = (entity: typeof listEntity, action: 'create' | 'update' | 'delete', role: Role, f: Facts, fields: string[] = [], values: Json = {}): Decision =>
    authorize(entity.rules, action, actor(role), f, fields, values);

  it('Listen: Admin und Eltern dürfen alles', () => {
    for (const role of ['admin', 'parent'] as const) {
      for (const a of AUDIENCES) {
        expect(mayRead(listEntity.rules, actor(role), facts(a))).toBe(true);
        expect(act(listEntity, 'create', role, facts(a), ['name', 'audience'], { audience: a })).toBe('ok');
        expect(act(listEntity, 'update', role, facts(a), ['name', 'audience'], { audience: 'parents' })).toBe('ok');
        expect(act(listEntity, 'delete', role, facts(a))).toBe('ok');
      }
    }
  });

  it('Listen: Kinder legen nur "family"-Listen an und ändern/löschen nur eigene (ohne Freigabe zu ändern)', () => {
    expect(act(listEntity, 'create', 'child', facts('family', 'u-self'), ['name'], { audience: 'family' })).toBe('ok');
    expect(act(listEntity, 'create', 'child', facts('parents', 'u-self'), ['name', 'audience'], { audience: 'parents' })).toBe('forbidden');
    expect(act(listEntity, 'update', 'child', facts('family', 'u-self'), ['name', 'kind'], { name: 'x' })).toBe('ok');
    expect(act(listEntity, 'update', 'child', facts('family', 'u-self'), ['audience'], { audience: 'parents' })).toBe('forbidden');
    expect(act(listEntity, 'update', 'child', facts('family', 'u-other'), ['name'])).toBe('forbidden');
    expect(act(listEntity, 'update', 'child', facts('parents', 'u-self'), ['name'])).toBe('not_found');
    expect(act(listEntity, 'delete', 'child', facts('family', 'u-self'))).toBe('ok');
    expect(act(listEntity, 'delete', 'child', facts('family', 'u-other'))).toBe('forbidden');
    expect(act(listEntity, 'delete', 'child', facts('parents', 'u-other'))).toBe('not_found');
    expect(mayRead(listEntity.rules, actor('child'), facts('parents'))).toBe(false);
    expect(mayRead(listEntity.rules, actor('child'), facts('family'))).toBe(true);
  });

  it('Einträge erben die Freigabe; Kinder dürfen in sichtbaren Listen alles', () => {
    expect(act(listItemEntity, 'create', 'child', facts('family'), ['listId', 'text'])).toBe('ok');
    expect(act(listItemEntity, 'create', 'child', facts('parents'), ['listId', 'text'])).toBe('forbidden');
    expect(act(listItemEntity, 'update', 'child', facts('parents'), ['text'])).toBe('not_found');
    expect(act(listItemEntity, 'delete', 'child', facts('family'))).toBe('ok');
  });

  it('jede Entität im Register hat für jede Rolle eine vollständige Regel', () => {
    for (const def of defaultRegistry.list()) {
      for (const role of ROLES) {
        const rule = def.rules[role];
        expect(rule, `${def.name}/${role}`).toBeDefined();
        for (const action of ['read', 'create', 'update', 'delete'] as const) expect(['none', 'all', 'shared', 'own']).toContain(rule[action]);
        // Lesen ist Voraussetzung für Ändern und Löschen
        if (rule.read === 'none') expect([rule.update, rule.delete]).toEqual(['none', 'none']);
      }
    }
  });
});

describe.each(backends)('Rechte im Sync ($name)', (backend) => {
  let harness: Harness;
  let world: World;
  let fam: Family;

  beforeAll(async () => {
    harness = await backend.open();
    world = await World.create(harness.db, { SYNC_RATE_LIMIT_MAX: '100000' });
    fam = await createFamily(world);
  }, 120_000);
  afterAll(async () => {
    await world.close();
    await harness.close();
  });
  beforeEach(async () => {
    await resetSync(world);
    for (const d of [fam.admin, fam.parent, fam.child]) d.sinceRev = 0;
  });

  const list = async (by = fam.admin, fields: Json = {}) => {
    const id = randomUUID();
    const res = await by.sync([upsert('list', id, { name: 'Liste', ...fields })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  };
  const rejection = async (by: typeof fam.admin, op: ReturnType<typeof upsert>) => (await by.sync([op])).json.rejected as Array<{ opId: string; code: string }>;

  describe('Listen', () => {
    it('Kind legt eine Familienliste an, ändert und löscht sie; Freigabe darf es nicht ändern', async () => {
      const id = randomUUID();
      expect((await fam.child.sync([upsert('list', id, { name: 'Kinderliste' })])).json.acked).toHaveLength(1);
      const owner = (await fam.child.pull()).find((c) => c.id === id)?.fields.ownerId;
      expect(owner).toBe(fam.child.userId);
      expect((await fam.child.sync([upsert('list', id, { name: 'Umbenannt' }, 1)], { sinceRev: 1 })).json.acked).toHaveLength(1);
      const op = upsert('list', id, { audience: 'parents' }, 2);
      expect(await rejection(fam.child, op)).toEqual([{ opId: op.opId, code: 'forbidden' }]);
      expect((await fam.child.sync([remove('list', id, 2)], { sinceRev: 2 })).json.acked).toHaveLength(1);
    });

    it('Kind darf keine Listen "nur für Eltern" anlegen', async () => {
      const op = upsert('list', randomUUID(), { name: 'x', audience: 'parents' });
      expect(await rejection(fam.child, op)).toEqual([{ opId: op.opId, code: 'forbidden' }]);
    });

    it('alte Apps senden die Stufe "all": sie wird als "family" gespeichert und ausgeliefert (Liste; Termin siehe sync-kalender.test.ts), Ändern ebenso', async () => {
      const id = randomUUID();
      const res = await fam.parent.sync([upsert('list', id, { name: 'Alt', audience: 'all' })]);
      expect(res.json.rejected).toEqual([]);
      expect((await rows(world, sql`select audience from lists where id = ${id}`))[0]?.audience).toBe('family');
      expect((await fam.child.pull()).find((c) => c.id === id)?.fields.audience).toBe('family');
      await fam.parent.sync([upsert('list', id, { audience: 'parents' }, 1)], { sinceRev: 1 });
      const back = await fam.parent.sync([upsert('list', id, { audience: 'all' }, 2)], { sinceRev: 2 });
      expect(back.json.rejected).toEqual([]);
      expect((await rows(world, sql`select audience from lists where id = ${id}`))[0]?.audience).toBe('family');
      // ein Kind darf mit der alten Eingabe "all" (= family) eine eigene Liste anlegen
      const own = randomUUID();
      expect((await fam.child.sync([upsert('list', own, { name: 'Kind alt', audience: 'all' })])).json.rejected).toEqual([]);
      // unbekannte Stufen bleiben ungültig
      const bad = upsert('list', randomUUID(), { name: 'x', audience: 'guests' });
      expect(await rejection(fam.parent, bad)).toEqual([{ opId: bad.opId, code: 'invalid' }]);
    });

    it('Kind darf fremde Listen weder umbenennen noch löschen, sieht sie aber; Besitzer kann nicht gesetzt werden', async () => {
      const id = await list(fam.parent);
      expect((await fam.child.pull()).map((c) => c.id)).toContain(id);
      const rename = upsert('list', id, { name: 'Meins' }, 1);
      expect(await rejection(fam.child, rename)).toEqual([{ opId: rename.opId, code: 'forbidden' }]);
      const del = remove('list', id, 1);
      expect(await rejection(fam.child, del)).toEqual([{ opId: del.opId, code: 'forbidden' }]);
      const owner = upsert('list', randomUUID(), { name: 'x', ownerId: fam.child.userId });
      expect(await rejection(fam.child, owner)).toEqual([{ opId: owner.opId, code: 'invalid' }]);
    });

    it('Sichtbarkeit im Änderungsstrom: nur Eltern / Familie', async () => {
      const onlyParents = await list(fam.admin, { audience: 'parents', name: 'Geschenke' });
      const family = await list(fam.admin, { audience: 'family', name: 'Einkauf' });
      const ids = async (d: typeof fam.admin) => {
        d.sinceRev = 0;
        return (await d.pull()).map((c) => c.id).sort();
      };
      expect(await ids(fam.parent)).toEqual([onlyParents, family].sort());
      expect(await ids(fam.child)).toEqual([family]);
    });

    it('nicht sichtbare Datensätze sind für die Rolle nicht auffindbar: Ändern, Löschen, Eintrag anlegen ergeben not_found', async () => {
      const secret = await list(fam.admin, { audience: 'parents' });
      for (const who of [fam.child]) {
        const ops = [upsert('list', secret, { name: 'x' }, 1), remove('list', secret, 1), upsert('list_item', randomUUID(), { listId: secret, text: 'x' })];
        const rejected = (await who.sync(ops)).json.rejected as Array<{ code: string }>;
        expect(rejected.map((r) => r.code)).toEqual(['not_found', 'not_found', 'not_found']);
      }
      expect((await rows(world, sql`select name, deleted_at from lists where id = ${secret}`))[0]).toMatchObject({ name: 'Liste', deleted_at: null });
    });
  });

  describe('Einträge', () => {
    it('Kind legt in Familienlisten Einträge an, ändert und löscht sie; in Elternlisten nicht', async () => {
      const lid = await list(fam.admin, { audience: 'family' });
      const iid = randomUUID();
      expect((await fam.child.sync([upsert('list_item', iid, { listId: lid, text: 'Eis' })])).json.acked).toHaveLength(1);
      expect((await fam.child.sync([upsert('list_item', iid, { text: 'Eis (Vanille)', assigneeId: fam.child.userId }, 2)], { sinceRev: 2 })).json.acked).toHaveLength(1);
      expect((await fam.child.sync([remove('list_item', iid, 3)], { sinceRev: 3 })).json.acked).toHaveLength(1);
      const secret = await list(fam.admin, { audience: 'parents' });
      const op = upsert('list_item', randomUUID(), { listId: secret, text: 'x' });
      expect(await rejection(fam.child, op)).toEqual([{ opId: op.opId, code: 'not_found' }]);
    });

    it('Freigabe zurückgenommen: das Gerät bekommt einen "hidden"-Tombstone, bei erneuter Freigabe wieder alles', async () => {
      const lid = await list(fam.admin, { audience: 'family', name: 'Grillfest' });
      const iid = randomUUID();
      await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Würstchen' })]);
      expect((await fam.child.pull()).map((c) => c.entity).sort()).toEqual(['list', 'list_item']);

      await fam.admin.sync([upsert('list', lid, { audience: 'parents' }, 1)], { sinceRev: 2 });
      const hidden = await fam.child.pull();
      expect(hidden).toEqual([{ rev: 3, entity: 'list', id: lid, tombstone: true, hidden: true, fields: {} }]);

      // spätere Änderungen an der unsichtbaren Liste verraten nichts
      await fam.admin.sync([upsert('list', lid, { name: 'Geheim' }, 3)], { sinceRev: 4 });
      expect(await fam.child.pull()).toEqual([]);

      await fam.admin.sync([upsert('list', lid, { audience: 'family' }, 5)], { sinceRev: 5 });
      const back = await fam.child.pull();
      expect(back.map((c) => [c.entity, c.tombstone])).toEqual([
        ['list', false],
        ['list_item', false],
      ]);
      expect(back[0]?.fields.name).toBe('Geheim');
    });

    it('ein Gerät, das eine nie sichtbare Liste nicht kannte, bekommt bei sinceRev 0 keine Tombstones', async () => {
      const lid = await list(fam.admin, { audience: 'family' });
      await fam.admin.sync([upsert('list', lid, { audience: 'parents' }, 1)], { sinceRev: 1 });
      expect(await fam.child.pull()).toEqual([]);
    });
  });

  describe('Fremde Familie (IDOR über die ID)', () => {
    let foreign: { listId: string; itemId: string; familyId: string; userId: string };

    const cleanup = async () => {
      await world.db.execute(sql`delete from families where name = 'Fremd'`);
      await world.db.execute(sql`delete from users where email in ('fremd@example.org', 'wartet@example.org')`);
    };
    afterEach(cleanup);
    beforeEach(async () => {
      await cleanup();
      const familyId = randomUUID();
      const userId = randomUUID();
      const listId = randomUUID();
      const itemId = randomUUID();
      await world.db.execute(sql`insert into families (id, name, current_rev) values (${familyId}, 'Fremd', 7)`);
      await world.db.execute(sql`insert into users (id, email, display_name) values (${userId}, 'fremd@example.org', 'Fremd')`);
      await world.db.execute(sql`insert into memberships (family_id, user_id, role) values (${familyId}, ${userId}, 'admin')`);
      await world.db.execute(sql`insert into lists (id, family_id, name, audience, rev, field_revs) values (${listId}, ${familyId}, 'Geheim', 'family', 7, '{"name":7}')`);
      await world.db.execute(sql`insert into list_items (id, family_id, list_id, text, rev, field_revs) values (${itemId}, ${familyId}, ${listId}, 'Fremder Eintrag', 7, '{"text":7}')`);
      foreign = { listId, itemId, familyId, userId };
    });

    it('Ändern, Löschen und Anlegen mit IDs einer fremden Familie: nichts passiert, keine Auskunft', async () => {
      for (const who of [fam.admin, fam.parent, fam.child]) {
        const ops = [
          upsert('list', foreign.listId, { name: 'Gehackt' }, 7),
          remove('list', foreign.listId, 7),
          upsert('list_item', foreign.itemId, { text: 'Gehackt' }, 7),
          remove('list_item', foreign.itemId, 7),
          upsert('list_item', randomUUID(), { listId: foreign.listId, text: 'Einschleusen' }),
        ];
        const res = await who.sync(ops);
        expect((res.json.rejected as Array<{ code: string }>).map((r) => r.code), who.role).toEqual(['not_found', 'not_found', 'not_found', 'not_found', 'not_found']);
        expect(res.json.conflicts).toEqual([]);
      }
      const [l] = await rows(world, sql`select name, rev, deleted_at from lists where id = ${foreign.listId}`);
      expect(l).toMatchObject({ name: 'Geheim', deleted_at: null });
      expect(Number(l?.rev)).toBe(7);
      expect((await rows(world, sql`select text from list_items where id = ${foreign.itemId}`))[0]?.text).toBe('Fremder Eintrag');
    });

    it('Anlegen mit einer ID, die einer fremden Familie gehört: not_found (verrät nichts)', async () => {
      const op = upsert('list', foreign.listId, { name: 'Meins' });
      const res = await fam.admin.sync([op]);
      expect(res.json.rejected).toEqual([{ opId: op.opId, code: 'not_found' }]);
      expect(JSON.stringify(res.json)).not.toContain('Geheim');
      // keine Revision verbraucht, keine Lücke
      expect(res.json.rev).toBe(0);
    });

    it('fremde Datensätze erscheinen nie im Änderungsstrom, auch nicht mit sinceRev 0', async () => {
      for (const who of [fam.admin, fam.child]) {
        const all = await who.sync([], { sinceRev: 0 });
        expect(JSON.stringify(all.json)).not.toContain('Geheim');
        expect(JSON.stringify(all.json)).not.toContain('Fremder');
      }
    });

    it('die Familie kommt aus der Sitzung, nie aus dem Körper', async () => {
      const res = await fam.admin.raw({ protocolVersion: 1, deviceId: fam.admin.deviceId, sinceRev: 0, familyId: foreign.familyId, ops: [] });
      expect(res.status).toBe(400);
      const op = { ...upsert('list', randomUUID(), { name: 'x' }), familyId: foreign.familyId };
      const res2 = await fam.admin.sync([op]);
      expect(res2.json.rejected).toEqual([{ opId: op.opId, code: 'invalid' }]);
    });

    it('Verweis auf ein Mitglied einer fremden Familie wird abgelehnt', async () => {
      const lid = await list(fam.admin);
      const op = upsert('list_item', randomUUID(), { listId: lid, text: 'x', assigneeId: foreign.userId });
      expect(await rejection(fam.admin, op)).toEqual([{ opId: op.opId, code: 'invalid_reference' }]);
      const unknown = upsert('list_item', randomUUID(), { listId: lid, text: 'x', assigneeId: randomUUID() });
      expect(await rejection(fam.admin, unknown)).toEqual([{ opId: unknown.opId, code: 'invalid_reference' }]);
    });

    it('ein wartendes Mitglied ist kein gültiger Verweis', async () => {
      const lid = await list(fam.admin);
      const pendingUser = randomUUID();
      const familyId = fam.familyId;
      await world.db.execute(sql`insert into users (id, email, display_name) values (${pendingUser}, 'wartet@example.org', 'Wartet')`);
      await world.db.execute(sql`insert into memberships (family_id, user_id, role, status) values (${familyId}, ${pendingUser}, 'child', 'pending')`);
      const op = upsert('list_item', randomUUID(), { listId: lid, text: 'x', assigneeId: pendingUser });
      expect(await rejection(fam.admin, op)).toEqual([{ opId: op.opId, code: 'invalid_reference' }]);
    });
  });

  describe('Mitglied entfernen', () => {
    it('Zuständigkeit und Besitzer werden mit Änderungseintrag auf NULL gesetzt; die Familie wird benachrichtigt', async () => {
      const oma = await extraMember(world, fam.admin, 'parent', 'opa@example.org');
      const lid = randomUUID();
      const iid = randomUUID();
      const mine = randomUUID();
      await oma.sync([upsert('list', mine, { name: 'Omas Liste' })]);
      await fam.admin.sync([upsert('list', lid, { name: 'Einkauf' }), upsert('list_item', iid, { listId: lid, text: 'Kaffee', assigneeId: oma.userId })]);
      await fam.parent.pull();
      const rev = fam.parent.sinceRev;

      const notified: Array<[string, number]> = [];
      const prev = world.auth.ctx.onRev;
      world.auth.ctx.onRev = (f, r) => {
        notified.push([f, r]);
        prev(f, r);
      };
      const res = await fam.admin.client.del(`/api/v1/members/${oma.userId}`);
      world.auth.ctx.onRev = prev;
      expect(res.status).toBe(200);
      expect(notified).toEqual([[fam.familyId, rev + 2]]);

      const changes = await fam.parent.pull();
      expect(changes.map((c) => [c.entity, c.id])).toEqual([
        ['list', mine],
        ['list_item', iid],
      ]);
      expect(changes[0]?.fields.ownerId).toBeNull();
      expect(changes[1]?.fields.assigneeId).toBeNull();
      // das Mitglied ist weg, der Eintrag bleibt
      expect(await world.count('list_items')).toBe(1);
    });

    it('nach dem Entfernen ist die Person kein gültiger Verweis mehr', async () => {
      const opa = await extraMember(world, fam.admin, 'child', 'enkel@example.org');
      const lid = randomUUID();
      await fam.admin.sync([upsert('list', lid, { name: 'Einkauf' })]);
      const ok = upsert('list_item', randomUUID(), { listId: lid, text: 'a', assigneeId: opa.userId });
      expect((await fam.admin.sync([ok])).json.acked).toHaveLength(1);
      expect((await fam.admin.client.del(`/api/v1/members/${opa.userId}`)).status).toBe(200);
      const op = upsert('list_item', randomUUID(), { listId: lid, text: 'b', assigneeId: opa.userId });
      expect(await rejection(fam.admin, op)).toEqual([{ opId: op.opId, code: 'invalid_reference' }]);
    });
  });
});

async function rows(world: World, query: ReturnType<typeof sql>): Promise<Json[]> {
  return (await world.db.execute(query)).rows as Json[];
}
