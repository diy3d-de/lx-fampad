// Aufgaben im Sync: Rechte-Regeltabelle, Zeitmodell, Validierung, Konflikte, Kaskade der Unteraufgaben, Mitglieder entfernen, Limits, IDOR.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { aufgabeEntity, aufgabeFaelligValid, aufgabePunktEntity } from '../src/sync/entities/aufgaben.js';
import { authorize, mayRead, type Actor, type Audience, type Decision, type Facts } from '../src/sync/permissions.js';
import type { Role } from '../src/auth/types.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Family, type Json } from './sync-kit.js';

const rows = async (world: World, query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];

describe('Aufgaben: Stimmigkeit der Fälligkeit', () => {
  it('Tag oder Zeitpunkt (mit Zeitzone), nie beides', () => {
    expect(aufgabeFaelligValid({})).toBe(true);
    expect(aufgabeFaelligValid({ faelligDate: '2026-10-20' })).toBe(true);
    expect(aufgabeFaelligValid({ faelligUtc: new Date(), tzid: 'Europe/Berlin' })).toBe(true);
    expect(aufgabeFaelligValid({ faelligUtc: new Date(), tzid: null })).toBe(false);
    expect(aufgabeFaelligValid({ faelligDate: '2026-10-20', faelligUtc: new Date(), tzid: 'Europe/Berlin' })).toBe(false);
  });
});

const actor = (role: Role, userId = 'u-self'): Actor => ({ role, userId });
const facts = (audience: Audience, ownerId: string | null = null): Facts => ({ audience, ownerId });
const act = (def: typeof aufgabeEntity, action: 'create' | 'update' | 'delete', role: Role, f: Facts, fields: string[] = [], values: Json = {}): Decision =>
  authorize(def.rules, action, actor(role), f, fields, values);

describe('Rechte-Regeltabelle: Aufgaben', () => {
  it('Admin und Eltern dürfen alles', () => {
    for (const role of ['admin', 'parent'] as const) {
      for (const a of ['parents', 'family'] as const) {
        for (const def of [aufgabeEntity, aufgabePunktEntity]) {
          expect(mayRead(def.rules, actor(role), facts(a))).toBe(true);
          expect(act(def, 'create', role, facts(a), [], { audience: a })).toBe('ok');
          expect(act(def, 'update', role, facts(a), ['audience'], { audience: 'parents' })).toBe('ok');
          expect(act(def, 'delete', role, facts(a))).toBe('ok');
        }
      }
    }
  });

  it('Kinder: sehen keine Eltern-Aufgaben, legen nur "family" an, ändern/löschen nur eigene ohne die Freigabe', () => {
    expect(mayRead(aufgabeEntity.rules, actor('child'), facts('parents'))).toBe(false);
    expect(mayRead(aufgabeEntity.rules, actor('child'), facts('family'))).toBe(true);
    expect(act(aufgabeEntity, 'create', 'child', facts('family', 'u-self'), ['titel'], { audience: 'family' })).toBe('ok');
    expect(act(aufgabeEntity, 'create', 'child', facts('parents', 'u-self'), ['titel', 'audience'], { audience: 'parents' })).toBe('forbidden');
    expect(act(aufgabeEntity, 'update', 'child', facts('family', 'u-self'), ['titel', 'erledigtAt'], { titel: 'x' })).toBe('ok');
    expect(act(aufgabeEntity, 'update', 'child', facts('family', 'u-self'), ['audience'], { audience: 'parents' })).toBe('forbidden');
    expect(act(aufgabeEntity, 'update', 'child', facts('family', 'u-other'), ['titel'])).toBe('forbidden');
    expect(act(aufgabeEntity, 'update', 'child', facts('parents', 'u-self'), ['titel'])).toBe('not_found');
    expect(act(aufgabeEntity, 'delete', 'child', facts('family', 'u-self'))).toBe('ok');
    expect(act(aufgabeEntity, 'delete', 'child', facts('family', 'u-other'))).toBe('forbidden');
    expect(act(aufgabeEntity, 'delete', 'child', facts('parents', 'u-other'))).toBe('not_found');
  });

  it('Unteraufgaben: Kinder nur an eigenen Aufgaben (geerbt)', () => {
    expect(act(aufgabePunktEntity, 'create', 'child', facts('family', 'u-self'))).toBe('ok');
    expect(act(aufgabePunktEntity, 'create', 'child', facts('family', 'u-other'))).toBe('forbidden');
    expect(act(aufgabePunktEntity, 'delete', 'child', facts('family', 'u-other'))).toBe('forbidden');
    expect(act(aufgabePunktEntity, 'update', 'child', facts('parents', 'u-self'))).toBe('not_found');
    expect(mayRead(aufgabePunktEntity.rules, actor('child'), facts('parents'))).toBe(false);
  });
});

describe.each(backends)('Aufgaben-Sync ($name)', (backend) => {
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

  const aufgabe = (extra: Json = {}): Json => ({ titel: 'Müll rausbringen', ...extra });

  async function anlegen(by = fam.admin, fields: Json = aufgabe()): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('aufgabe', id, fields)]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }

  it('legt Aufgaben mit Tag und mit Zeitpunkt an; die Antwort trägt Standardwerte, Ersteller und Freigabe', async () => {
    const a = await anlegen(fam.admin, aufgabe({ faelligDate: '2026-10-25', prioritaet: 3, wiederholung: 'weekly', assigneeId: fam.child.userId }));
    const b = await anlegen(fam.admin, aufgabe({ faelligUtc: '2026-10-25T08:00:00.000Z', tzid: 'Europe/Berlin', erinnerungMin: 30 }));
    const changes = await fam.parent.pull();
    expect(changes.find((c) => c.id === a)?.fields).toMatchObject({
      titel: 'Müll rausbringen',
      beschreibung: '',
      faelligDate: '2026-10-25',
      faelligUtc: null,
      prioritaet: 3,
      wiederholung: 'weekly',
      assigneeId: fam.child.userId,
      erledigtAt: null,
      erledigtVon: null,
      audience: 'family',
      ownerId: fam.admin.userId,
    });
    expect(changes.find((c) => c.id === b)?.fields).toMatchObject({ faelligUtc: '2026-10-25T08:00:00.000Z', tzid: 'Europe/Berlin', erinnerungMin: 30, faelligDate: null });
  });

  it('lehnt ungültige Angaben ab (invalid), ohne Datenbankfehler', async () => {
    const utc = '2026-10-25T08:00:00Z';
    const bad: Json[] = [
      aufgabe({ faelligDate: '2026-02-30' }),
      aufgabe({ faelligDate: '2026-10-25', faelligUtc: utc, tzid: 'Europe/Berlin' }),
      aufgabe({ faelligUtc: utc }),
      aufgabe({ faelligUtc: utc, tzid: 'Mars/Olympus' }),
      aufgabe({ titel: '   ' }),
      aufgabe({ titel: 'x'.repeat(201) }),
      aufgabe({ beschreibung: 'x'.repeat(4001) }),
      aufgabe({ prioritaet: 4 }),
      aufgabe({ prioritaet: -1 }),
      aufgabe({ prioritaet: 1.5 }),
      aufgabe({ wiederholung: 'yearly' }),
      aufgabe({ wiederholung: 'FREQ=DAILY' }),
      aufgabe({ erinnerungMin: -1 }),
      aufgabe({ erinnerungMin: 40321 }),
      aufgabe({ audience: 'jeder' }),
      aufgabe({ ownerId: fam.admin.userId }),
      aufgabe({ unbekannt: 1 }),
    ];
    for (const fields of bad) {
      const op = upsert('aufgabe', randomUUID(), fields);
      const res = await fam.admin.sync([op]);
      expect(res.status, JSON.stringify(fields)).toBe(200);
      expect(res.json.rejected, JSON.stringify(fields)).toEqual([{ opId: op.opId, code: 'invalid' }]);
    }
    expect((await rows(world, sql`select count(*)::int as n from aufgaben`))[0]?.n).toBe(0);
  });

  it('prüft die Fälligkeit auch nach dem Zusammenführen einer Änderung', async () => {
    const id = await anlegen(fam.admin, aufgabe({ faelligDate: '2026-10-25' }));
    const beides = upsert('aufgabe', id, { faelligUtc: '2026-10-25T08:00:00Z', tzid: 'Europe/Berlin' }, 1);
    expect((await fam.admin.sync([beides])).json.rejected).toEqual([{ opId: beides.opId, code: 'invalid' }]);
    const wechsel = upsert('aufgabe', id, { faelligDate: null, faelligUtc: '2026-10-25T08:00:00Z', tzid: 'Europe/Berlin' }, 1);
    expect((await fam.admin.sync([wechsel])).json.rejected).toEqual([]);
  });

  it('Zuständige und Erledigt-von müssen aktive Mitglieder der Familie sein', async () => {
    const op = upsert('aufgabe', randomUUID(), aufgabe({ assigneeId: randomUUID() }));
    expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'invalid_reference' }]);
    const op2 = upsert('aufgabe', randomUUID(), aufgabe({ erledigtVon: randomUUID(), erledigtAt: '2026-10-20T08:00:00Z' }));
    expect((await fam.admin.sync([op2])).json.rejected).toEqual([{ opId: op2.opId, code: 'invalid_reference' }]);
  });

  it('Abhaken und Umbenennen auf verschiedenen Geräten werden zusammengeführt, dasselbe Feld: letzte Änderung gewinnt', async () => {
    const id = await anlegen();
    const eltern2 = await fam.secondDevice('parent');
    expect((await fam.admin.sync([upsert('aufgabe', id, { erledigtAt: '2026-10-20T08:00:00Z', erledigtVon: fam.admin.userId }, 1)])).json.conflicts).toEqual([]);
    expect((await eltern2.sync([upsert('aufgabe', id, { titel: 'Papiermüll' }, 1)])).json.conflicts).toEqual([]);
    const r = await fam.parent.sync([upsert('aufgabe', id, { prioritaet: 2, titel: 'Altglas' }, 1)]);
    expect(r.json.conflicts).toHaveLength(1);
    expect(r.json.conflicts[0].fields).toEqual({ titel: 'Papiermüll' });
    const [row] = await rows(world, sql`select titel, prioritaet, erledigt_at is not null as erledigt from aufgaben where id = ${id}`);
    expect(row).toEqual({ titel: 'Papiermüll', prioritaet: 2, erledigt: true });
  });

  it('Unteraufgaben: Kaskade beim Löschen der Aufgabe (niedrigere Revisionen vor der Aufgabe), Limit 100 je Aufgabe', async () => {
    const id = await anlegen();
    const p1 = randomUUID();
    expect((await fam.admin.sync([upsert('aufgabe_punkt', p1, { aufgabeId: id, text: 'Tonne raus', position: 1 })])).json.rejected).toEqual([]);
    expect((await fam.admin.sync([upsert('aufgabe_punkt', p1, { doneAt: '2026-10-20T08:00:00Z' }, 2)])).json.rejected).toEqual([]);
    const umbiegen = upsert('aufgabe_punkt', p1, { aufgabeId: randomUUID() }, 3);
    expect((await fam.admin.sync([umbiegen])).json.rejected).toEqual([{ opId: umbiegen.opId, code: 'invalid' }]);
    await fam.admin.pull();
    expect((await fam.admin.sync([remove('aufgabe', id, 1)])).json.rejected).toEqual([]);
    const tombs = (await fam.admin.pull()).filter((c) => c.tombstone);
    expect(tombs.map((c) => c.entity)).toEqual(['aufgabe_punkt', 'aufgabe']);
    const spaet = upsert('aufgabe_punkt', randomUUID(), { aufgabeId: id, text: 'zu spät' });
    expect((await fam.admin.sync([spaet])).json.rejected).toEqual([{ opId: spaet.opId, code: 'parent_deleted' }]);

    const id2 = await anlegen();
    const ops = Array.from({ length: 101 }, (_, i) => upsert('aufgabe_punkt', randomUUID(), { aufgabeId: id2, text: `P${i}`, position: i }));
    const rejected: Json[] = [];
    for (let i = 0; i < ops.length; i += 50) rejected.push(...(await fam.admin.sync(ops.slice(i, i + 50))).json.rejected);
    expect(rejected.map((r) => r.code)).toEqual(['limit_reached']);
  }, 60_000);

  it('Rechte: Kinder legen "family"-Aufgaben an, ändern/löschen nur eigene; fremde und Eltern-Aufgaben sind (IDOR) nicht vorhanden bzw. verboten', async () => {
    const eigen = await anlegen(fam.child);
    const vonEltern = await anlegen(fam.admin);
    const nurEltern = await anlegen(fam.admin, aufgabe({ audience: 'parents' }));
    const fremd = upsert('aufgabe', vonEltern, { erledigtAt: '2026-10-20T08:00:00Z' }, 2);
    expect((await fam.child.sync([fremd])).json.rejected).toEqual([{ opId: fremd.opId, code: 'forbidden' }]);
    const geheim = upsert('aufgabe', nurEltern, { titel: 'Hack' }, 3);
    expect((await fam.child.sync([geheim])).json.rejected).toEqual([{ opId: geheim.opId, code: 'not_found' }]);
    const del = remove('aufgabe', nurEltern, 3);
    expect((await fam.child.sync([del])).json.rejected).toEqual([{ opId: del.opId, code: 'not_found' }]);
    const frei = upsert('aufgabe', eigen, { audience: 'parents' }, 1);
    expect((await fam.child.sync([frei])).json.rejected).toEqual([{ opId: frei.opId, code: 'forbidden' }]);
    const eltern = await fam.child.sync([upsert('aufgabe', randomUUID(), aufgabe({ audience: 'parents' }))]);
    expect(eltern.json.rejected).toHaveLength(1);
    expect((await fam.child.sync([upsert('aufgabe', eigen, { erledigtAt: '2026-10-20T08:00:00Z', erledigtVon: fam.child.userId }, 1)])).json.rejected).toEqual([]);
    expect((await fam.child.pull()).map((c) => c.id).sort()).toEqual([eigen, vonEltern].sort());
    const punkt = upsert('aufgabe_punkt', randomUUID(), { aufgabeId: vonEltern, text: 'x' });
    expect((await fam.child.sync([punkt])).json.rejected).toEqual([{ opId: punkt.opId, code: 'forbidden' }]);
  });

  it('Freigabe zurücknehmen: das Kind bekommt einen Tombstone (hidden), Unteraufgaben verschwinden mit', async () => {
    const id = await anlegen();
    await fam.admin.sync([upsert('aufgabe_punkt', randomUUID(), { aufgabeId: id, text: 'a' })]);
    expect((await fam.child.pull()).filter((c) => c.entity === 'aufgabe_punkt')).toHaveLength(1);
    expect((await fam.admin.sync([upsert('aufgabe', id, { audience: 'parents' }, 1)])).json.rejected).toEqual([]);
    expect((await fam.child.pull()).filter((c) => c.hidden).map((c) => c.entity)).toContain('aufgabe');
  });

  it('Mitglied entfernt: Zuständige, Erledigt-von und Ersteller werden bereinigt (mit Änderungseintrag), die Aufgabe bleibt', async () => {
    const extra = await extraMember(world, fam.admin, 'parent', 'papa@example.org');
    const id = await anlegen(extra, aufgabe({ assigneeId: extra.userId, erledigtAt: '2026-10-20T08:00:00Z', erledigtVon: extra.userId }));
    const res = await fam.admin.client.del(`/api/v1/members/${extra.userId}`);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const [t] = await rows(world, sql`select owner_id, assignee_id, erledigt_von from aufgaben where id = ${id}`);
    expect(t).toEqual({ owner_id: null, assignee_id: null, erledigt_von: null });
    const f = (await fam.admin.pull()).find((c) => c.id === id)?.fields;
    expect(f).toMatchObject({ ownerId: null, assigneeId: null, erledigtVon: null });
  });

  it('Kinder: höchstens 500 lebende Aufgaben je Besitzer; Eltern nicht begrenzt', async () => {
    const zeilen = Array.from({ length: 500 }, (_, i) => `('${randomUUID()}', '${fam.familyId}', 'K${i}', '${fam.child.userId}', ${i + 1})`);
    await world.db.execute(sql.raw(`insert into aufgaben (id, family_id, titel, owner_id, rev) values ${zeilen.join(',')}`));
    const op = upsert('aufgabe', randomUUID(), aufgabe());
    expect((await fam.child.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'limit_reached' }]);
    expect((await fam.admin.sync([upsert('aufgabe', randomUUID(), aufgabe())])).json.rejected).toEqual([]);
  }, 60_000);

  it('feste ID einer Folgeaufgabe von zwei Geräten: die zweite Op ist eine Änderung, keine Doppelung', async () => {
    const id = randomUUID();
    const fields = aufgabe({ faelligDate: '2026-11-01', wiederholung: 'daily' });
    expect((await fam.admin.sync([upsert('aufgabe', id, fields)])).json.rejected).toEqual([]);
    expect((await fam.parent.sync([upsert('aufgabe', id, fields)])).json.rejected).toEqual([]);
    expect((await rows(world, sql`select count(*)::int as n from aufgaben`))[0]?.n).toBe(1);
  });
});
