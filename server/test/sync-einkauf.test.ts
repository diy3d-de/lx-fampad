// Einkaufsliste: Kategorie der Einträge (Gang im Supermarkt) und die Listenart "Vorlage".
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, remove, resetSync, upsert, type Family, type Json } from './sync-kit.js';

describe.each(backends)('Einkauf: Kategorie und Vorlage ($name)', (backend) => {
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
    fam.admin.sinceRev = fam.parent.sinceRev = fam.child.sinceRev = 0;
  });

  const liste = async (extra: Json = {}) => {
    const id = randomUUID();
    expect((await fam.admin.sync([upsert('list', id, { name: 'Einkauf', kind: 'shopping', ...extra })])).json.acked).toHaveLength(1);
    return id;
  };

  it('Eintrag ohne Kategorie (alte Apps) bleibt gültig und liefert null', async () => {
    const lid = await liste();
    const iid = randomUUID();
    await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Milch' })]);
    const z = (await fam.parent.pull()).find((c) => c.id === iid) as Json;
    expect(z.fields.category ?? null).toBeNull();
  });

  it('Kategorie setzen, ändern und zurücksetzen', async () => {
    const lid = await liste();
    const iid = randomUUID();
    await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Äpfel', category: 'obst_gemuese' })]);
    await fam.admin.sync([upsert('list_item', iid, { category: 'getraenke' }, 2)]);
    expect(((await fam.parent.pull()).find((c) => c.id === iid) as Json).fields.category).toBe('getraenke');
    await fam.admin.sync([upsert('list_item', iid, { category: null }, 3)]);
    expect(((await fam.parent.pull()).find((c) => c.id === iid) as Json).fields.category ?? null).toBeNull();
  });

  it('Konflikt pro Feld: Kategorie und Text zweier Geräte kollidieren nicht, dieselbe Kategorie schon', async () => {
    const lid = await liste();
    const iid = randomUUID();
    await fam.admin.sync([upsert('list_item', iid, { listId: lid, text: 'Brot' })]);
    await fam.parent.pull();
    const a = await fam.admin.sync([upsert('list_item', iid, { category: 'brot_backwaren' }, 2)]);
    const b = await fam.parent.sync([upsert('list_item', iid, { text: 'Brot (Vollkorn)' }, 2)]);
    expect(a.json.conflicts).toEqual([]);
    expect(b.json.conflicts).toEqual([]);
    const c = await fam.child.sync([upsert('list_item', iid, { category: 'sonstiges' }, 2)]);
    expect(c.json.conflicts).toHaveLength(1);
    expect(c.json.conflicts[0].fields).toEqual({ category: 'brot_backwaren' });
    const z = ((await fam.admin.pull()).find((x) => x.id === iid) as Json).fields;
    expect(z).toMatchObject({ text: 'Brot (Vollkorn)', category: 'brot_backwaren' });
  });

  it('ungültige Kategorien werden abgelehnt', async () => {
    const lid = await liste();
    for (const category of ['Obst', '', 5, 'obst_gemuese '] as unknown[]) {
      const op = upsert('list_item', randomUUID(), { listId: lid, text: 'x', category });
      expect((await fam.admin.sync([op])).json.rejected, String(category)).toEqual([{ opId: op.opId, code: 'invalid' }]);
    }
  });

  it('Rechte wie bei den übrigen Eintragsfeldern: Kind darf in Familienlisten, nicht in Elternlisten', async () => {
    const offen = await liste();
    const geheim = await liste({ audience: 'parents' });
    const iid = randomUUID();
    expect((await fam.child.sync([upsert('list_item', iid, { listId: offen, text: 'Eis', category: 'tiefkuehl' })])).json.acked).toHaveLength(1);
    expect((await fam.child.sync([upsert('list_item', iid, { category: 'getraenke' }, 1)], { sinceRev: 99 })).json.acked).toHaveLength(1);
    const op = upsert('list_item', randomUUID(), { listId: geheim, text: 'x', category: 'tiefkuehl' });
    expect((await fam.child.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'not_found' }]);
    expect((await fam.child.sync([remove('list_item', iid, 2)])).json.acked).toHaveLength(1);
  });

  it('Listenart "template" (Vorlage) wird angenommen, unbekannte Arten nicht', async () => {
    const lid = await liste({ kind: 'template', name: 'Standard-Einkauf' });
    expect(((await fam.child.pull()).find((c) => c.id === lid) as Json).fields.kind).toBe('template');
    const op = upsert('list', randomUUID(), { name: 'x', kind: 'vorlage' });
    expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'invalid' }]);
  });
});
