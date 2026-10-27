// Familien-Status im Sync (Abschnitt 6o): feste ID (Known-Answer wie in der App), Rechte-Regeltabelle, IDOR, Validierung, Zeitgrenze, Sicht der Familie.
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { statusId, uuidAusSchluessel } from '../src/sync/entities/chat-ids.js';
import { statusEntity } from '../src/sync/entities/status.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import type { Role } from '../src/auth/types.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, remove, resetSync, upsert, type Family, type Json } from './sync-kit.js';

const U = '22222222-2222-4222-8222-222222222222';
// Known-Answer: muss exakt app/test/status_test.dart entsprechen
const KAT = 'c3d1a94a-9984-5393-8cfe-8b4475df5371';

describe('Familien-Status: feste ID', () => {
  it('leitet die ID aus der Person ab (Known-Answer wie in der App)', () => {
    expect(statusId(U)).toBe(uuidAusSchluessel(`status:${U}`));
    expect(statusId(U.toUpperCase())).toBe(statusId(U));
    expect(statusId(U)).toBe(KAT);
    expect(statusId('33333333-3333-4333-8333-333333333333')).not.toBe(KAT);
  });
});

const actor = (role: Role, userId: string): Actor => ({ role, userId });
const facts = (ownerId: string): Facts => ({ audience: 'family', ownerId });

describe('Rechte-Regeltabelle: Familien-Status', () => {
  it('alle Rollen lesen jeden Status; schreiben und löschen nur der eigene, auch Admins nicht fremd', () => {
    for (const role of ['admin', 'parent', 'child'] as const) {
      expect(mayRead(statusEntity.rules, actor(role, 'me'), facts('other'))).toBe(true);
      expect(authorize(statusEntity.rules, 'create', actor(role, 'me'), facts('me'), [], {})).toBe('ok');
      expect(authorize(statusEntity.rules, 'create', actor(role, 'me'), facts('other'), [], {})).toBe('forbidden');
      expect(authorize(statusEntity.rules, 'update', actor(role, 'me'), facts('me'), ['text', 'bis'], {})).toBe('ok');
      expect(authorize(statusEntity.rules, 'update', actor(role, 'me'), facts('other'), ['text'], {})).toBe('forbidden');
      expect(authorize(statusEntity.rules, 'delete', actor(role, 'me'), facts('me'), [], {})).toBe('ok');
      expect(authorize(statusEntity.rules, 'delete', actor(role, 'me'), facts('other'), [], {})).toBe('forbidden');
    }
  });
});

describe.each(backends)('Familien-Status-Sync ($name)', (backend) => {
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

  const in2h = (): string => new Date(world.clock + 2 * 3_600_000).toISOString();
  const mein = (d: { userId: string }, extra: Json = {}): Json => ({ userId: d.userId, text: 'Beim Sport', bis: in2h(), ...extra });

  it('legt den eigenen Status mit fester ID an; die ganze Familie sieht ihn, Kinder auch', async () => {
    const id = statusId(fam.child.userId);
    const res = await fam.child.sync([upsert('status', id, mein(fam.child))]);
    expect(res.json.rejected).toEqual([]);
    for (const d of [fam.admin, fam.parent, fam.child]) {
      const c = (await d.pull()).find((x) => x.id === id);
      expect(c?.fields).toMatchObject({ userId: fam.child.userId, text: 'Beim Sport' });
    }
  });

  it('lehnt eine fremde oder falsche ID und fremde Personen ab (IDOR)', async () => {
    const fremd = upsert('status', statusId(fam.parent.userId), mein(fam.parent));
    const falsch = upsert('status', statusId(fam.child.userId), mein(fam.parent));
    const zufall = upsert('status', '44444444-4444-4444-8444-444444444444', mein(fam.child));
    for (const op of [fremd, falsch, zufall]) {
      const r = await fam.child.sync([op]);
      expect(r.json.rejected.map((x: Json) => x.opId)).toEqual([op.opId]);
    }
    expect((await world.db.execute(sql`select count(*)::int as n from familien_status`)).rows[0]).toEqual({ n: 0 });
  });

  it('Admin und Eltern ändern oder löschen keinen fremden Status', async () => {
    const id = statusId(fam.child.userId);
    await fam.child.sync([upsert('status', id, mein(fam.child))]);
    for (const d of [fam.admin, fam.parent]) {
      const u = await d.sync([upsert('status', id, { text: 'Hallo' }, 1)]);
      expect(u.json.rejected).toHaveLength(1);
      const x = await d.sync([remove('status', id, 1)]);
      expect(x.json.rejected).toHaveLength(1);
    }
    expect((await world.db.execute(sql`select text from familien_status`)).rows[0]).toEqual({ text: 'Beim Sport' });
  });

  it('ändert und löscht den eigenen Status und belebt ihn wieder', async () => {
    const id = statusId(fam.parent.userId);
    await fam.parent.sync([upsert('status', id, mein(fam.parent))]);
    expect((await fam.parent.sync([upsert('status', id, { text: 'Lernen', bis: null }, 1)])).json.rejected).toEqual([]);
    expect((await fam.parent.sync([remove('status', id, 2)])).json.rejected).toEqual([]);
    expect((await fam.parent.sync([upsert('status', id, mein(fam.parent, { text: 'Unterwegs' }), 0)])).json.rejected).toEqual([]);
    expect((await world.db.execute(sql`select text, deleted_at from familien_status`)).rows).toEqual([{ text: 'Unterwegs', deleted_at: null }]);
  });

  it('prüft Text und Ablauf (invalid)', async () => {
    const id = statusId(fam.admin.userId);
    const lang = new Date(world.clock + 8 * 86_400_000).toISOString();
    const knapp = new Date(world.clock + 6 * 86_400_000).toISOString();
    const bad: Json[] = [
      mein(fam.admin, { text: '' }),
      mein(fam.admin, { text: '   ' }),
      mein(fam.admin, { text: 'x'.repeat(61) }),
      mein(fam.admin, { text: 'Zeile\nZwei' }),
      mein(fam.admin, { text: 'Tab\tstopp' }),
      mein(fam.admin, { text: 'Unsicht\u200Bbar' }),
      mein(fam.admin, { text: 'Rück\u202Ewärts' }),
      mein(fam.admin, { bis: lang }),
      mein(fam.admin, { bis: 'morgen' }),
      mein(fam.admin, { unbekannt: 1 }),
    ];
    for (const fields of bad) {
      const op = upsert('status', id, fields);
      const res = await fam.admin.sync([op]);
      expect(res.status, JSON.stringify(fields)).toBe(200);
      expect(res.json.rejected, JSON.stringify(fields)).toEqual([{ opId: op.opId, code: 'invalid' }]);
    }
    expect((await world.db.execute(sql`select count(*)::int as n from familien_status`)).rows[0]).toEqual({ n: 0 });
    const gut = upsert('status', id, mein(fam.admin, { text: 'Mädchen-Abend 🎉', bis: knapp }));
    expect((await fam.admin.sync([gut])).json.rejected).toEqual([]);
    // auch nach dem Zusammenführen einer Änderung
    const spaeter = upsert('status', id, { bis: lang }, 1);
    expect((await fam.admin.sync([spaeter])).json.rejected).toEqual([{ opId: spaeter.opId, code: 'invalid' }]);
    // ohne Ende und mit schon abgelaufenem Ende sind erlaubt (die App zeigt Abgelaufenes nicht)
    expect((await fam.admin.sync([upsert('status', id, { bis: null }, 1)])).json.rejected).toEqual([]);
    expect((await fam.admin.sync([upsert('status', id, { bis: '2020-01-01T00:00:00.000Z' }, 2)])).json.rejected).toEqual([]);
  });

  it('weckt nie per Push (noWake)', () => {
    expect(statusEntity.noWake).toBe(true);
  });
});
