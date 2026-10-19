// Kalender im Sync: RRULE-Prüfung, Zeitmodell, Rechte-Regeltabelle, Konflikte, Kaskade, Ausnahmen, Teilnehmer, Mitglieder entfernen.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { isValidRrule } from '../src/sync/rrule.js';
import { authorize, mayRead, type Actor, type Audience, type Decision, type Facts } from '../src/sync/permissions.js';
import { ausnahmeValid, terminAusnahmeEntity, terminEntity, terminTeilnehmerEntity, terminTimesValid } from '../src/sync/entities/termine.js';
import type { Role } from '../src/auth/types.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Family, type Json } from './sync-kit.js';

const rows = async (world: World, query: ReturnType<typeof sql>): Promise<Json[]> => (await world.db.execute(query)).rows as Json[];

describe('RRULE-Prüfung', () => {
  it('akzeptiert die Regeln der Oberfläche', () => {
    for (const r of [
      'FREQ=DAILY',
      'FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2',
      'FREQ=MONTHLY;BYMONTHDAY=15;COUNT=12',
      'FREQ=MONTHLY;BYDAY=2MO',
      'FREQ=MONTHLY;BYDAY=MO;BYSETPOS=-1',
      'FREQ=YEARLY;BYMONTH=12;BYMONTHDAY=24;UNTIL=20301231T225959Z',
      'FREQ=YEARLY;UNTIL=20301231',
      'FREQ=WEEKLY;WKST=MO;COUNT=1000',
    ]) expect(isValidRrule(r), r).toBe(true);
  });

  it('lehnt Sekunden-/Minuten-/Stundenserien und absurde Werte ab', () => {
    for (const r of [
      '',
      'FREQ=SECONDLY',
      'FREQ=MINUTELY;INTERVAL=1',
      'FREQ=HOURLY',
      'RRULE:FREQ=DAILY',
      'freq=daily',
      'FREQ=DAILY;COUNT=1001',
      'FREQ=DAILY;COUNT=99999999',
      'FREQ=DAILY;COUNT=0',
      'FREQ=DAILY;INTERVAL=0',
      'FREQ=DAILY;INTERVAL=1000',
      'FREQ=DAILY;COUNT=5;UNTIL=20301231',
      'FREQ=DAILY;FREQ=WEEKLY',
      'FREQ=DAILY;BYHOUR=1',
      'FREQ=DAILY;BYYEARDAY=1',
      'FREQ=WEEKLY;BYDAY=2MO',
      'FREQ=WEEKLY;BYMONTHDAY=3',
      'FREQ=MONTHLY;BYMONTHDAY=0',
      'FREQ=MONTHLY;BYMONTHDAY=32',
      'FREQ=MONTHLY;BYDAY=6MO',
      'FREQ=MONTHLY;BYDAY=XX',
      'FREQ=YEARLY;BYMONTH=13',
      'FREQ=DAILY;UNTIL=20301301',
      'FREQ=DAILY;UNTIL=1999-01-01',
      'FREQ=DAILY;UNTIL=20301231T225959',
      'FREQ=DAILY;',
      'FREQ',
      'FREQ=',
      ';;;',
      'FREQ=DAILY;' + 'X=1;'.repeat(100),
    ])
      expect(isValidRrule(r), r).toBe(false);
  });

  it('bleibt bei bösartigen Eingaben schnell (kein ReDoS)', () => {
    const start = Date.now();
    for (const r of ['FREQ=WEEKLY;BYDAY=' + 'MO,'.repeat(5000), 'FREQ=DAILY;' + 'A'.repeat(100_000), '1'.repeat(200_000) + '=', 'FREQ=MONTHLY;BYMONTHDAY=' + '-1,'.repeat(100_000)]) {
      expect(isValidRrule(r)).toBe(false);
    }
    expect(Date.now() - start).toBeLessThan(500);
  });
});

describe('Zeitmodell (Stimmigkeit)', () => {
  it('Zeittermine brauchen Zeitpunkte, Ende nicht vor Beginn und Zeitzone; ganztägige ein Ende nach dem Beginn', () => {
    const d = (s: string) => new Date(s);
    expect(terminTimesValid({ ganztaegig: false, startUtc: d('2026-10-20T08:00:00Z'), endUtc: d('2026-10-20T08:00:00Z'), tzid: 'Europe/Berlin' })).toBe(true);
    expect(terminTimesValid({ ganztaegig: false, startUtc: d('2026-10-20T08:00:00Z'), endUtc: d('2026-10-20T07:00:00Z'), tzid: 'Europe/Berlin' })).toBe(false);
    expect(terminTimesValid({ ganztaegig: false, startUtc: d('2026-10-20T08:00:00Z'), endUtc: d('2026-10-20T09:00:00Z'), tzid: null })).toBe(false);
    expect(terminTimesValid({ ganztaegig: false, startUtc: null, endUtc: null, tzid: 'Europe/Berlin' })).toBe(false);
    expect(terminTimesValid({ ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-21' })).toBe(true);
    expect(terminTimesValid({ ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-20' })).toBe(false);
    expect(terminTimesValid({ ganztaegig: true, startDate: null, endDate: '2026-10-20' })).toBe(false);
  });

  it('Ausnahmen: Beginn/Ende haben die Art des ursprünglichen Vorkommens', () => {
    expect(ausnahmeValid({ originalStart: '2026-10-20T08:00:00Z', start: '2026-10-20T09:00:00Z', ende: '2026-10-20T10:00:00Z' })).toBe(true);
    expect(ausnahmeValid({ originalStart: '2026-10-20T08:00:00Z', start: '2026-10-21', ende: null })).toBe(false);
    expect(ausnahmeValid({ originalStart: '2026-10-20', start: '2026-10-21', ende: '2026-10-22' })).toBe(true);
    expect(ausnahmeValid({ originalStart: '2026-10-20', start: '2026-10-22', ende: '2026-10-21' })).toBe(false);
  });
});

const actor = (role: Role, userId = 'u-self'): Actor => ({ role, userId });
const facts = (audience: Audience, ownerId: string | null = null): Facts => ({ audience, ownerId });
const act = (def: typeof terminEntity, action: 'create' | 'update' | 'delete', role: Role, f: Facts, fields: string[] = [], values: Json = {}): Decision =>
  authorize(def.rules, action, actor(role), f, fields, values);

describe('Rechte-Regeltabelle: Termine', () => {
  it('Admin und Eltern dürfen alles', () => {
    for (const role of ['admin', 'parent'] as const) {
      for (const a of ['parents', 'family', 'all'] as const) {
        for (const def of [terminEntity, terminTeilnehmerEntity, terminAusnahmeEntity]) {
          expect(mayRead(def.rules, actor(role), facts(a))).toBe(true);
          expect(act(def, 'create', role, facts(a), [], { audience: a })).toBe('ok');
          expect(act(def, 'update', role, facts(a), ['audience'], { audience: 'all' })).toBe('ok');
          expect(act(def, 'delete', role, facts(a))).toBe('ok');
        }
      }
    }
  });

  it('Kinder: sehen keine Eltern-Termine, legen nur "family" an, ändern/löschen nur eigene ohne die Freigabe', () => {
    expect(mayRead(terminEntity.rules, actor('child'), facts('parents'))).toBe(false);
    expect(mayRead(terminEntity.rules, actor('child'), facts('family'))).toBe(true);
    expect(act(terminEntity, 'create', 'child', facts('family', 'u-self'), ['titel'], { audience: 'family' })).toBe('ok');
    expect(act(terminEntity, 'create', 'child', facts('all', 'u-self'), ['titel', 'audience'], { audience: 'all' })).toBe('forbidden');
    expect(act(terminEntity, 'update', 'child', facts('family', 'u-self'), ['titel', 'startUtc'], { titel: 'x' })).toBe('ok');
    expect(act(terminEntity, 'update', 'child', facts('family', 'u-self'), ['audience'], { audience: 'all' })).toBe('forbidden');
    expect(act(terminEntity, 'update', 'child', facts('family', 'u-other'), ['titel'])).toBe('forbidden');
    expect(act(terminEntity, 'update', 'child', facts('parents', 'u-self'), ['titel'])).toBe('not_found');
    expect(act(terminEntity, 'delete', 'child', facts('family', 'u-self'))).toBe('ok');
    expect(act(terminEntity, 'delete', 'child', facts('family', 'u-other'))).toBe('forbidden');
    expect(act(terminEntity, 'delete', 'child', facts('parents', 'u-other'))).toBe('not_found');
  });

  it('Teilnehmer und Ausnahmen: Kinder nur an eigenen Terminen (geerbt), Gäste nie', () => {
    for (const def of [terminTeilnehmerEntity, terminAusnahmeEntity]) {
      expect(act(def, 'create', 'child', facts('family', 'u-self'))).toBe('ok');
      expect(act(def, 'create', 'child', facts('family', 'u-other'))).toBe('forbidden');
      expect(act(def, 'delete', 'child', facts('family', 'u-other'))).toBe('forbidden');
      expect(act(def, 'update', 'child', facts('parents', 'u-self'))).toBe('not_found');
      expect(act(def, 'create', 'guest', facts('all', 'u-self'))).toBe('forbidden');
      expect(act(def, 'update', 'guest', facts('all'))).toBe('forbidden');
      expect(act(def, 'delete', 'guest', facts('all'))).toBe('forbidden');
    }
  });

  it('Gäste sehen nur freigegebene Termine und ändern nichts', () => {
    expect(mayRead(terminEntity.rules, actor('guest'), facts('all'))).toBe(true);
    expect(mayRead(terminEntity.rules, actor('guest'), facts('family'))).toBe(false);
    expect(act(terminEntity, 'create', 'guest', facts('family', 'u-self'), ['titel'])).toBe('forbidden');
    expect(act(terminEntity, 'update', 'guest', facts('all'), ['titel'])).toBe('forbidden');
    expect(act(terminEntity, 'update', 'guest', facts('family'), ['titel'])).toBe('not_found');
    expect(act(terminEntity, 'delete', 'guest', facts('all'))).toBe('forbidden');
  });
});

describe.each(backends)('Kalender-Sync ($name)', (backend) => {
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
    fam.admin.sinceRev = fam.parent.sinceRev = fam.child.sinceRev = fam.guest.sinceRev = 0;
  });

  const zeit = (extra: Json = {}): Json => ({
    titel: 'Zahnarzt',
    ganztaegig: false,
    startUtc: '2026-10-20T08:00:00.000Z',
    endUtc: '2026-10-20T09:00:00.000Z',
    tzid: 'Europe/Berlin',
    ...extra,
  });
  const tag = (extra: Json = {}): Json => ({ titel: 'Ferien', ganztaegig: true, startDate: '2026-12-24', endDate: '2026-12-27', ...extra });

  async function anlegen(by = fam.admin, fields: Json = zeit()): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('termin', id, fields)]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }

  it('legt Zeit- und ganztägige Termine an; die Antwort trägt Zeitpunkte als ISO, Datum als Text, Ersteller und Freigabe', async () => {
    const a = await anlegen();
    const b = await anlegen(fam.admin, tag({ rrule: 'FREQ=YEARLY', erinnerungMin: 60, icalUid: 'abc@example.org' }));
    const changes = await fam.parent.pull();
    const ta = changes.find((c) => c.id === a);
    const tb = changes.find((c) => c.id === b);
    expect(ta?.fields).toMatchObject({
      titel: 'Zahnarzt',
      ort: '',
      beschreibung: '',
      ganztaegig: false,
      startUtc: '2026-10-20T08:00:00.000Z',
      tzid: 'Europe/Berlin',
      startDate: null,
      rrule: null,
      erinnerungMin: null,
      audience: 'family',
      ownerId: fam.admin.userId,
    });
    expect(tb?.fields).toMatchObject({ ganztaegig: true, startDate: '2026-12-24', endDate: '2026-12-27', startUtc: null, rrule: 'FREQ=YEARLY', erinnerungMin: 60, icalUid: 'abc@example.org' });
  });

  it('lehnt ungültige Zeiten, Zeitzonen, Regeln und Längen ab (invalid), ohne Datenbankfehler', async () => {
    const bad: Json[] = [
      zeit({ endUtc: '2026-10-20T07:00:00.000Z' }),
      zeit({ tzid: null }),
      zeit({ tzid: 'Mars/Olympus' }),
      zeit({ tzid: '../etc/passwd' }),
      zeit({ startUtc: null }),
      zeit({ rrule: 'FREQ=SECONDLY' }),
      zeit({ rrule: 'FREQ=DAILY;COUNT=5000' }),
      zeit({ titel: 'x'.repeat(201) }),
      zeit({ titel: '   ' }),
      zeit({ beschreibung: 'x'.repeat(4001) }),
      zeit({ erinnerungMin: -1 }),
      zeit({ erinnerungMin: 40321 }),
      zeit({ erinnerungMin: 1.5 }),
      tag({ endDate: '2026-12-24' }),
      tag({ startDate: '2026-02-30' }),
      tag({ startDate: '24.12.2026' }),
      tag({ startDate: null }),
      zeit({ ownerId: fam.admin.userId }),
      zeit({ audience: 'jeder' }),
      zeit({ unbekannt: 1 }),
    ];
    for (const fields of bad) {
      const op = upsert('termin', randomUUID(), fields);
      const res = await fam.admin.sync([op]);
      expect(res.status, JSON.stringify(fields)).toBe(200);
      expect(res.json.rejected, JSON.stringify(fields)).toEqual([{ opId: op.opId, code: 'invalid' }]);
    }
    expect((await rows(world, sql`select count(*)::int as n from termine`))[0]?.n).toBe(0);
  });

  it('prüft die Stimmigkeit auch nach dem Zusammenführen einer Änderung (Update)', async () => {
    const id = await anlegen();
    const op = upsert('termin', id, { endUtc: '2026-10-20T07:00:00.000Z' }, 1);
    expect((await fam.admin.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'invalid' }]);
    const umschalten = upsert('termin', id, { ganztaegig: true }, 1); // ohne Datum: ungültig
    expect((await fam.admin.sync([umschalten])).json.rejected).toEqual([{ opId: umschalten.opId, code: 'invalid' }]);
    const ok = upsert('termin', id, { ganztaegig: true, startDate: '2026-10-20', endDate: '2026-10-21' }, 1);
    expect((await fam.admin.sync([ok])).json.rejected).toEqual([]);
  });

  it('Felder verschiedener Geräte werden zusammengeführt, dasselbe Feld: letzte Änderung gewinnt (Konflikt gemeldet)', async () => {
    const id = await anlegen();
    const eltern2 = await fam.secondDevice('parent');
    const r1 = await fam.admin.sync([upsert('termin', id, { ort: 'Praxis' }, 1)]);
    expect(r1.json.conflicts).toEqual([]);
    const r2 = await eltern2.sync([upsert('termin', id, { titel: 'Kontrolle' }, 1)]);
    expect(r2.json.conflicts).toEqual([]);
    const r3 = await fam.parent.sync([upsert('termin', id, { ort: 'Zuhause' }, 1)]);
    expect(r3.json.conflicts).toHaveLength(1);
    expect(r3.json.conflicts[0].fields).toEqual({ ort: 'Praxis' });
    const [row] = await rows(world, sql`select titel, ort from termine where id = ${id}`);
    expect(row).toEqual({ titel: 'Kontrolle', ort: 'Praxis' });
  });

  it('Teilnehmer: je Person eine Zeile, doppelte und fremde Personen werden abgelehnt, Entfernen ist ein Tombstone', async () => {
    const id = await anlegen();
    const t1 = randomUUID();
    const res = await fam.admin.sync([upsert('termin_teilnehmer', t1, { terminId: id, userId: fam.child.userId })]);
    expect(res.json.rejected).toEqual([]);
    const dup = upsert('termin_teilnehmer', randomUUID(), { terminId: id, userId: fam.child.userId });
    expect((await fam.admin.sync([dup])).json.rejected).toEqual([{ opId: dup.opId, code: 'not_found' }]);
    const fremd = upsert('termin_teilnehmer', randomUUID(), { terminId: id, userId: randomUUID() });
    expect((await fam.admin.sync([fremd])).json.rejected).toEqual([{ opId: fremd.opId, code: 'invalid_reference' }]);
    // unveränderlich
    const umbiegen = upsert('termin_teilnehmer', t1, { userId: fam.parent.userId }, 2);
    expect((await fam.admin.sync([umbiegen])).json.rejected).toEqual([{ opId: umbiegen.opId, code: 'invalid' }]);
    expect((await fam.admin.sync([remove('termin_teilnehmer', t1, 2)])).json.rejected).toEqual([]);
    // danach darf die Person erneut eingetragen werden
    expect((await fam.admin.sync([upsert('termin_teilnehmer', randomUUID(), { terminId: id, userId: fam.child.userId })])).json.rejected).toEqual([]);
  });

  it('Ausnahmen: eine Zeile je Vorkommen, original_start normalisiert und unveränderlich, Art muss passen', async () => {
    const id = await anlegen(fam.admin, zeit({ rrule: 'FREQ=WEEKLY' }));
    const a1 = randomUUID();
    const res = await fam.admin.sync([upsert('termin_ausnahmen', a1, { terminId: id, originalStart: '2026-10-27T09:00:00+01:00', abgesagt: true })]);
    expect(res.json.rejected).toEqual([]);
    const ch = res.json.changes.find((c: Json) => c.id === a1);
    expect(ch.fields).toMatchObject({ originalStart: '2026-10-27T08:00:00Z', abgesagt: true, titel: null, start: null });
    const dup = upsert('termin_ausnahmen', randomUUID(), { terminId: id, originalStart: '2026-10-27T08:00:00Z' });
    expect((await fam.admin.sync([dup])).json.rejected).toEqual([{ opId: dup.opId, code: 'not_found' }]);
    const verschieben = upsert('termin_ausnahmen', a1, { originalStart: '2026-11-03T08:00:00Z' }, 2);
    expect((await fam.admin.sync([verschieben])).json.rejected).toEqual([{ opId: verschieben.opId, code: 'invalid' }]);
    const falscheArt = upsert('termin_ausnahmen', randomUUID(), { terminId: id, originalStart: '2026-11-03T08:00:00Z', start: '2026-11-03' });
    expect((await fam.admin.sync([falscheArt])).json.rejected).toEqual([{ opId: falscheArt.opId, code: 'invalid' }]);
    const ueber = upsert('termin_ausnahmen', a1, { start: '2026-10-27T10:00:00Z', ende: '2026-10-27T11:00:00Z', titel: 'Später', ort: '' }, 2);
    expect((await fam.admin.sync([ueber])).json.rejected).toEqual([]);
    const [row] = await rows(world, sql`select start, ende, titel, ort, abgesagt from termin_ausnahmen where id = ${a1}`);
    expect(row).toEqual({ start: '2026-10-27T10:00:00Z', ende: '2026-10-27T11:00:00Z', titel: 'Später', ort: '', abgesagt: true });
  });

  it('gleicher Ausnahme-Schlüssel von zwei Geräten mit fester ID: die zweite Op wird zur Änderung (Feldkonflikt, kein Fehler)', async () => {
    const id = await anlegen(fam.admin, zeit({ rrule: 'FREQ=WEEKLY' }));
    const aid = randomUUID();
    const fields = { terminId: id, originalStart: '2026-10-27T08:00:00Z' };
    expect((await fam.admin.sync([upsert('termin_ausnahmen', aid, { ...fields, abgesagt: true })])).json.rejected).toEqual([]);
    const res = await fam.parent.sync([upsert('termin_ausnahmen', aid, { ...fields, titel: 'Anders' })]);
    expect(res.json.rejected).toEqual([]);
    expect(res.json.conflicts).toHaveLength(1); // beim Anlegen gelten alle Felder als geschrieben: der Stand des Servers bleibt
    const [row] = await rows(world, sql`select abgesagt, titel from termin_ausnahmen where id = ${aid}`);
    expect(row).toEqual({ abgesagt: true, titel: null });
  });

  it('Löschen eines Termins räumt Teilnehmer und Ausnahmen mit auf (Kaskade, niedrigere Revisionen vor dem Termin)', async () => {
    const id = await anlegen();
    await fam.admin.sync([
      upsert('termin_teilnehmer', randomUUID(), { terminId: id, userId: fam.child.userId }),
      upsert('termin_ausnahmen', randomUUID(), { terminId: id, originalStart: '2026-10-27T08:00:00Z', abgesagt: true }),
    ]);
    await fam.admin.pull();
    const res = await fam.admin.sync([remove('termin', id, 1)]);
    expect(res.json.rejected).toEqual([]);
    const tombs = (await fam.admin.pull()).filter((c: Json) => c.tombstone);
    expect(tombs.map((c: Json) => c.entity)).toEqual(['termin_teilnehmer', 'termin_ausnahmen', 'termin']);
    const live = await rows(
      world,
      sql`select (select count(*) from termin_teilnehmer where deleted_at is null)::int as a, (select count(*) from termin_ausnahmen where deleted_at is null)::int as b`,
    );
    expect(live[0]).toEqual({ a: 0, b: 0 });
    // Inhalte sind überschrieben
    const [t] = await rows(world, sql`select titel, rrule from termine where id = ${id}`);
    expect(t).toEqual({ titel: '', rrule: null });
    // neue Teilnehmer an gelöschten Terminen: abgelehnt
    const spaet = upsert('termin_teilnehmer', randomUUID(), { terminId: id, userId: fam.child.userId });
    expect((await fam.admin.sync([spaet])).json.rejected).toEqual([{ opId: spaet.opId, code: 'parent_deleted' }]);
  });

  describe('Rechte über die Schnittstelle', () => {
    it('Kinder legen "family"-Termine an, ändern/löschen nur eigene; fremde und Eltern-Termine sind für sie nicht vorhanden', async () => {
      const eigen = await anlegen(fam.child);
      const vonEltern = await anlegen(fam.admin);
      const nurEltern = await anlegen(fam.admin, zeit({ audience: 'parents' }));
      const opFremd = upsert('termin', vonEltern, { titel: 'Hack' }, 2);
      expect((await fam.child.sync([opFremd])).json.rejected).toEqual([{ opId: opFremd.opId, code: 'forbidden' }]);
      const opGeheim = upsert('termin', nurEltern, { titel: 'Hack' }, 3);
      expect((await fam.child.sync([opGeheim])).json.rejected).toEqual([{ opId: opGeheim.opId, code: 'not_found' }]);
      const opDel = remove('termin', nurEltern, 3);
      expect((await fam.child.sync([opDel])).json.rejected).toEqual([{ opId: opDel.opId, code: 'not_found' }]);
      const frei = upsert('termin', eigen, { audience: 'all' }, 1);
      expect((await fam.child.sync([frei])).json.rejected).toEqual([{ opId: frei.opId, code: 'forbidden' }]);
      expect((await fam.child.sync([upsert('termin', eigen, { titel: 'Fußball' }, 1)])).json.rejected).toEqual([]);
      const mine = await fam.child.pull();
      expect(mine.map((c) => c.id).sort()).toEqual([eigen, vonEltern].sort());
      // Teilnehmer an fremdem Termin: verboten
      const tn = upsert('termin_teilnehmer', randomUUID(), { terminId: vonEltern, userId: fam.child.userId });
      expect((await fam.child.sync([tn])).json.rejected).toEqual([{ opId: tn.opId, code: 'forbidden' }]);
      // am eigenen: erlaubt
      expect((await fam.child.sync([upsert('termin_teilnehmer', randomUUID(), { terminId: eigen, userId: fam.admin.userId })])).json.rejected).toEqual([]);
    });

    it('Gäste sehen nur freigegebene Termine (samt Teilnehmern) und ändern nichts', async () => {
      const privat = await anlegen(fam.admin);
      const frei = await anlegen(fam.admin, zeit({ audience: 'all', titel: 'Oma-Besuch' }));
      await fam.admin.sync([upsert('termin_teilnehmer', randomUUID(), { terminId: frei, userId: fam.guest.userId })]);
      const seen = await fam.guest.pull();
      expect(seen.filter((c) => c.entity === 'termin').map((c) => c.id)).toEqual([frei]);
      expect(seen.filter((c) => c.entity === 'termin_teilnehmer')).toHaveLength(1);
      const op = upsert('termin', frei, { titel: 'x' }, 2);
      expect((await fam.guest.sync([op])).json.rejected).toEqual([{ opId: op.opId, code: 'forbidden' }]);
      const op2 = upsert('termin', privat, { titel: 'x' }, 1);
      expect((await fam.guest.sync([op2])).json.rejected).toEqual([{ opId: op2.opId, code: 'not_found' }]);
      const neu = upsert('termin', randomUUID(), zeit());
      expect((await fam.guest.sync([neu])).json.rejected).toEqual([{ opId: neu.opId, code: 'forbidden' }]);
    });

    it('Freigabe zurücknehmen: Gäste bekommen einen Tombstone (hidden) für den Termin; Kinder-Datensätze verwirft die App mit ihm', async () => {
      const frei = await anlegen(fam.admin, zeit({ audience: 'all' }));
      await fam.admin.sync([upsert('termin_ausnahmen', randomUUID(), { terminId: frei, originalStart: '2026-10-27T08:00:00Z', abgesagt: true })]);
      expect((await fam.guest.pull()).filter((c) => c.entity === 'termin_ausnahmen')).toHaveLength(1);
      const res = await fam.admin.sync([upsert('termin', frei, { audience: 'family' }, 1)]);
      expect(res.json.rejected).toEqual([]);
      const guestView = await fam.guest.pull();
      expect(guestView.filter((c) => c.hidden).map((c) => c.entity)).toEqual(['termin']);
    });
  });

  it('Mitglied entfernt: Ersteller-Verweis wird bereinigt (mit Änderungseintrag), der Termin bleibt', async () => {
    const extra = await extraMember(world, fam.admin, 'parent', 'papa@example.org');
    const id = await anlegen(extra);
    const res = await fam.admin.client.del(`/api/v1/members/${extra.userId}`);
    expect(res.status, JSON.stringify(res.json)).toBe(200);
    const [t] = await rows(world, sql`select owner_id from termine where id = ${id}`);
    expect(t?.owner_id).toBeNull();
    const changes = await fam.admin.pull();
    expect(changes.find((c) => c.id === id)?.fields.ownerId).toBeNull();
  });

  it('Obergrenze: höchstens 500 Ausnahmen je Serie', async () => {
    const id = await anlegen(fam.admin, zeit({ rrule: 'FREQ=DAILY' }));
    const ops = Array.from({ length: 501 }, (_, i) =>
      upsert('termin_ausnahmen', randomUUID(), { terminId: id, originalStart: new Date(Date.UTC(2026, 0, 1) + i * 86_400_000).toISOString(), abgesagt: true }),
    );
    const rejected: Json[] = [];
    for (let i = 0; i < ops.length; i += 50) {
      const r = await fam.admin.sync(ops.slice(i, i + 50));
      rejected.push(...r.json.rejected);
    }
    expect(rejected).toHaveLength(1);
    expect(rejected[0]?.code).toBe('limit_reached');
  }, 60_000);
});
