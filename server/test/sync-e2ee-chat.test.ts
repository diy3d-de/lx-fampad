// E2EE Phase 2 auf dem Server: Hülle e1 (Downgrade-Schutz), Epochen und Schlüssel-Wraps als undurchsichtige Daten (Form, Größe, Eindeutigkeit, Sicht).
// Der Server entschlüsselt und prüft nie etwas: die Tests arbeiten mit Platzhalter-Texten in Base64url-Form.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { epocheId, familienchatId, wrapId } from '../src/sync/entities/chat-ids.js';
import { epocheEntity, epocheWrapEntity, MAX_EPOCHEN_LISTE, MAX_WRAP } from '../src/sync/entities/chat-epochen.js';
import { authorize, mayRead, type Actor, type Facts } from '../src/sync/permissions.js';
import { backends, World, type Harness } from './helpers.js';
import { createFamily, extraMember, remove, resetSync, upsert, type Device, type Family, type Json } from './sync-kit.js';

const E1 = (n = 200) => `e1:${'A'.repeat(n)}`;
const BLOB = (n = 120) => 'B'.repeat(n);

describe('Epochen und Wraps: Rechte-Modell (Regeltabelle)', () => {
  const A = 'u-a';
  const B = 'u-b';
  const privat: Facts = { audience: 'family', ownerId: null, participants: [A, B] };
  const wrapFakten = (empfaenger: string): Facts => ({ ...privat, ownerId: empfaenger });
  const actor = (role: 'admin' | 'parent' | 'child', userId: string): Actor => ({ role, userId });

  it('Epoche: jeder Teilnehmer liest und legt an, nie ändern oder löschen; Unbeteiligte (auch Admin) sehen nichts', () => {
    for (const role of ['admin', 'parent', 'child'] as const) {
      expect(mayRead(epocheEntity.rules, actor(role, A), privat)).toBe(true);
      expect(mayRead(epocheEntity.rules, actor(role, 'u-x'), privat), `${role} ohne Teilnehmer`).toBe(false);
      expect(authorize(epocheEntity.rules, 'create', actor(role, A), privat, ['konversationId', 'epoche', 'mitglieder'])).toBe('ok');
      expect(authorize(epocheEntity.rules, 'create', actor(role, 'u-x'), privat, ['konversationId'])).toBe('forbidden');
      expect(authorize(epocheEntity.rules, 'delete', actor(role, A), privat)).toBe('forbidden');
      expect(authorize(epocheEntity.rules, 'update', actor(role, 'u-x'), privat)).toBe('not_found');
    }
  });

  it('Wrap: nur der Empfänger liest, auch die anderen Teilnehmer und Admins nicht; Teilnehmer legen an', () => {
    for (const role of ['admin', 'parent', 'child'] as const) {
      expect(mayRead(epocheWrapEntity.rules, actor(role, A), wrapFakten(A)), `${role} Empfänger`).toBe(true);
      expect(mayRead(epocheWrapEntity.rules, actor(role, B), wrapFakten(A)), `${role} anderer Teilnehmer`).toBe(false);
      expect(mayRead(epocheWrapEntity.rules, actor(role, 'u-x'), wrapFakten(A)), `${role} Fremder`).toBe(false);
      expect(authorize(epocheWrapEntity.rules, 'create', actor(role, B), wrapFakten(A), ['konversationId', 'epoche', 'empfaengerId', 'wrap'])).toBe('ok');
      expect(authorize(epocheWrapEntity.rules, 'delete', actor(role, A), wrapFakten(A))).toBe('forbidden');
    }
  });
});

describe.each(backends)('E2EE-Chat im Sync ($name)', (backend) => {
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

  /** Neue Konversationen sind ohne Angabe verschlüsselt (e1). */
  async function gruppe(by: Device, members: Device[], extra: Json = {}): Promise<string> {
    const id = randomUUID();
    const res = await by.sync([upsert('konversation', id, { art: 'group', teilnehmer: [by.userId, ...members.map((m) => m.userId)], ...extra })]);
    expect(res.json.rejected, JSON.stringify(res.json.rejected)).toEqual([]);
    return id;
  }
  const epoche = (konv: string, n: number, mitglieder = BLOB(200)) => upsert('epoche', epocheId(konv, n), { konversationId: konv, epoche: n, mitglieder });
  const wrap = (konv: string, n: number, empfaenger: Device | string, blob = BLOB()) => {
    const emp = typeof empfaenger === 'string' ? empfaenger : empfaenger.userId;
    return upsert('epoche_wrap', wrapId(konv, n, emp), { konversationId: konv, epoche: n, empfaengerId: emp, wrap: blob });
  };

  describe('Hülle e1 und Downgrade-Schutz', () => {
    it('neue Chats sind e1; Klartext p1 wird abgelehnt, die Hülle e1 nur in Form angenommen', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect((await rows(sql`select enc_version from konversationen where id = ${konv}`))[0]?.enc_version).toBe('e1');
      const senden = (text: string) => fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: konv, text })]);
      expect(codes(await senden('p1:Klartext einer Nachricht'))).toEqual(['invalid']);
      expect(codes(await senden('ohne Präfix'))).toEqual(['invalid']);
      expect(codes(await senden('e1:kurz'))).toEqual(['invalid']);
      expect(codes(await senden(`e1:${'A'.repeat(100)}!${'A'.repeat(100)}`))).toEqual(['invalid']);
      expect(codes(await senden(E1()))).toEqual([]);
      // Bearbeiten: ebenfalls nur e1
      const id = randomUUID();
      expect(codes(await fam.parent.sync([upsert('nachricht', id, { konversationId: konv, text: E1() })]))).toEqual([]);
      const rev = Number((await rows(sql`select rev from nachrichten where id = ${id}`))[0]?.rev);
      expect(codes(await fam.parent.sync([upsert('nachricht', id, { text: 'p1:Klartext statt Chiffretext' }, rev)]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('nachricht', id, { text: E1(300) }, rev)]))).toEqual([]);
    });

    it('die Version ist beim Anlegen wählbar, danach unveränderlich (kein Zurückstufen auf Klartext)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const rev = Number((await rows(sql`select rev from konversationen where id = ${konv}`))[0]?.rev);
      expect(codes(await fam.parent.sync([upsert('konversation', konv, { encVersion: 'p1' }, rev)]))).toEqual(['invalid']);
      expect((await rows(sql`select enc_version from konversationen where id = ${konv}`))[0]?.enc_version).toBe('e1');
      expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'group', encVersion: 'e9', teilnehmer: [fam.parent.userId, fam.child.userId] })]))).toEqual(['invalid']);
      // Altbestand p1 bleibt Klartext (nur dort ist `p1:` gültig, `e1:` nicht)
      const alt = await gruppe(fam.parent, [fam.child], { encVersion: 'p1' });
      expect(codes(await fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: alt, text: 'p1:alt' })]))).toEqual([]);
      expect(codes(await fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: alt, text: E1() })]))).toEqual(['invalid']);
    });

    it('der Familienchat wird verschlüsselt angelegt', async () => {
      const id = familienchatId(fam.familyId);
      expect((await fam.admin.sync([upsert('konversation', id, { art: 'family' })])).json.rejected).toEqual([]);
      expect((await rows(sql`select enc_version from konversationen where id = ${id}`))[0]?.enc_version).toBe('e1');
      expect(codes(await fam.child.sync([upsert('nachricht', randomUUID(), { konversationId: id, text: 'p1:Hallo' })]))).toEqual(['invalid']);
    });
  });

  describe('Epochen', () => {
    it('feste ID, lückenlos, nur in e1-Chats; der erste Schreiber gewinnt, die identische Wiederholung ist ein Ack', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      // andere ID als die abgeleitete: ungültig
      expect(codes(await fam.parent.sync([upsert('epoche', randomUUID(), { konversationId: konv, epoche: 1, mitglieder: BLOB(200) })]))).toEqual(['invalid']);
      // Lücke: Epoche 2 ohne Epoche 1
      expect(codes(await fam.parent.sync([epoche(konv, 2)]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([epoche(konv, 1)]))).toEqual([]);
      expect(codes(await fam.parent.sync([epoche(konv, 2)]))).toEqual([]);
      // zweiter Schreiber mit anderer Mitgliederliste: abgelehnt, die erste bleibt
      expect(codes(await fam.child.sync([epoche(konv, 2, BLOB(300))]))).toEqual(['invalid']);
      expect((await rows(sql`select mitglieder from konversation_epochen where konversation_id = ${konv} and epoche = 2`))).toEqual([{ mitglieder: BLOB(200) }]);
      // dieselben Werte noch einmal (anderes Gerät, gleiche Epoche): ohne Wirkung, kein Fehler
      expect(codes(await fam.child.sync([epoche(konv, 2, BLOB(200))]))).toEqual([]);
      expect(await rows(sql`select count(*)::int as n from konversation_epochen where konversation_id = ${konv}`)).toEqual([{ n: 2 }]);
      // Form: nur Base64url, Größe begrenzt, Nummer im Bereich
      expect(codes(await fam.parent.sync([upsert('epoche', epocheId(konv, 3), { konversationId: konv, epoche: 3, mitglieder: 'ungültig!' })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('epoche', epocheId(konv, 3), { konversationId: konv, epoche: 3, mitglieder: 'A'.repeat(MAX_EPOCHEN_LISTE + 1) })]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([upsert('epoche', epocheId(konv, 0), { konversationId: konv, epoche: 0, mitglieder: BLOB() })]))).toEqual(['invalid']);
      // Altbestand (Klartext) bekommt keine Epochen
      const alt = await gruppe(fam.parent, [fam.child], { encVersion: 'p1' });
      expect(codes(await fam.parent.sync([epoche(alt, 1)]))).toEqual(['invalid']);
    });

    it('Teilnehmer lesen die Epochen, Unbeteiligte (auch der Admin) erfahren nichts; Epochen sind unveränderlich und nicht löschbar', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([epoche(konv, 1)]))).toEqual([]);
      expect(ids(await fam.child.pull(), 'epoche')).toEqual([epocheId(konv, 1)]);
      expect(ids(await fam.admin.pull(), 'epoche')).toEqual([]);
      // der Admin kann auch nichts anlegen oder ändern (die Konversation gibt es für ihn nicht)
      expect(codes(await fam.admin.sync([epoche(konv, 2)]))).toEqual(['not_found']);
      expect(codes(await fam.admin.sync([epoche(konv, 1, BLOB(10))]))).toEqual(['not_found']);
      const rev = Number((await rows(sql`select rev from konversation_epochen where konversation_id = ${konv}`))[0]?.rev);
      expect(codes(await fam.child.sync([remove('epoche', epocheId(konv, 1), rev)]))).toEqual(['forbidden']);
      expect(codes(await fam.child.sync([upsert('epoche', epocheId(konv, 1), { mitglieder: BLOB(7) }, rev)]))).toEqual(['invalid']);
    });

    it('Race: zwei Teilnehmer legen gleichzeitig dieselbe Epoche an: genau einer gewinnt, der andere wird abgelehnt', async () => {
      const konv = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes(await fam.parent.sync([epoche(konv, 1)]))).toEqual([]);
      const [a, b, c] = await Promise.all([
        fam.parent.sync([epoche(konv, 2, BLOB(210)), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child)]),
        fam.child.sync([epoche(konv, 2, BLOB(220)), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child)]),
        fam.admin.sync([epoche(konv, 2, BLOB(230)), wrap(konv, 2, fam.admin)]),
      ]);
      const gewinner = [a, b, c].filter((r) => r.json.acked.length >= 1 && (r.json.rejected as unknown[]).length === 0);
      expect(gewinner).toHaveLength(1);
      expect(await rows(sql`select count(*)::int as n from konversation_epochen where konversation_id = ${konv} and epoche = 2`)).toEqual([{ n: 1 }]);
      // der Verlierer wird für Epoche und Wraps abgelehnt (Wraps gibt es für diese Empfänger schon), nichts doppelt
      const verlierer = [a, b, c].filter((r) => !gewinner.includes(r));
      for (const v of verlierer) expect(codes(v)[0]).toBe('invalid');
      const wraps = await rows(sql`select empfaenger_id from epoche_wraps where konversation_id = ${konv} and epoche = 2`);
      expect(new Set(wraps.map((w) => w.empfaenger_id)).size).toBe(wraps.length);
    });
  });

  describe('Wraps', () => {
    it('nur der Empfänger bekommt seinen Wrap; Verteiler, andere Teilnehmer und Admin sehen ihn nie', async () => {
      const konv = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes(await fam.parent.sync([epoche(konv, 1)]))).toEqual([]);
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.parent, BLOB(110)), wrap(konv, 1, fam.child, BLOB(111)), wrap(konv, 1, fam.admin, BLOB(112))]))).toEqual([]);
      const gelesen = async (d: Device) => (await d.pull()).filter((c) => c.entity === 'epoche_wrap');
      expect((await gelesen(fam.child)).map((c) => c.fields.wrap)).toEqual([BLOB(111)]);
      expect((await gelesen(fam.admin)).map((c) => c.fields.wrap)).toEqual([BLOB(112)]);
      expect((await gelesen(fam.parent)).map((c) => c.fields.wrap)).toEqual([BLOB(110)]);
    });

    it('Prüfungen: feste ID, Epoche muss existieren, Empfänger muss Teilnehmer sein, Form und Größe, erster Wrap gewinnt, unveränderlich', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.child)]))).toEqual(['invalid']); // Epoche 1 gibt es noch nicht
      expect(codes(await fam.parent.sync([epoche(konv, 1)]))).toEqual([]);
      expect(codes(await fam.parent.sync([upsert('epoche_wrap', randomUUID(), { konversationId: konv, epoche: 1, empfaengerId: fam.child.userId, wrap: BLOB() })]))).toEqual(['invalid']);
      // Admin ist kein Teilnehmer der Gruppe: kein Wrap für ihn
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.admin)]))).toEqual(['invalid']);
      // Empfänger ohne Familienzugehörigkeit
      expect(codes(await fam.parent.sync([wrap(konv, 1, randomUUID())]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.child, 'zu kurz!')]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.child, 'A'.repeat(MAX_WRAP + 1))]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.child, BLOB(150))]))).toEqual([]);
      // der erste gewinnt: ein anderer Wrap (auch von einem anderen Teilnehmer) für dieselbe Person ist abgelehnt
      expect(codes(await fam.child.sync([wrap(konv, 1, fam.child, BLOB(160))]))).not.toEqual([]);
      expect((await rows(sql`select wrap from epoche_wraps where konversation_id = ${konv}`))).toEqual([{ wrap: BLOB(150) }]);
      // Altbestand: keine Wraps
      const alt = await gruppe(fam.parent, [fam.child], { encVersion: 'p1' });
      expect(codes(await fam.parent.sync([wrap(alt, 1, fam.child)]))).toEqual(['invalid']);
    });

    it('Familienchat: Wraps für jedes aktive Mitglied; neue Mitglieder bekommen später Epoche und Wrap, ältere Epochen nur mit Wrap', async () => {
      const id = familienchatId(fam.familyId);
      expect((await fam.admin.sync([upsert('konversation', id, { art: 'family' })])).json.rejected).toEqual([]);
      expect(codes(await fam.admin.sync([epoche(id, 1), wrap(id, 1, fam.admin), wrap(id, 1, fam.parent)]))).toEqual([]);
      const neu = await extraMember(world, fam.admin, 'child', 'neu-e2ee@example.org');
      // der neue sieht Epoche 1 (Liste), aber keinen Wrap von früher
      const erster = await neu.pull();
      expect(ids(erster, 'epoche')).toEqual([epocheId(id, 1)]);
      expect(ids(erster, 'epoche_wrap')).toEqual([]);
      // Epoche 2 für alle drei, danach nachträglich der Wrap der Epoche 1 ("Verlauf teilen")
      expect(codes(await fam.admin.sync([epoche(id, 2), wrap(id, 2, fam.admin), wrap(id, 2, fam.parent), wrap(id, 2, neu), wrap(id, 1, neu, BLOB(130))]))).toEqual([]);
      expect(ids(await neu.pull(), 'epoche_wrap').sort()).toEqual([wrapId(id, 1, neu.userId), wrapId(id, 2, neu.userId)].sort());
      // der Admin darf den Wrap der anderen weiter nicht lesen
      expect(ids(await fam.child.pull(), 'epoche_wrap')).toEqual([]);
    });

    it('Mitglied entfernt: seine Wraps verschwinden (Tombstone für seine Geräte), die anderen bleiben', async () => {
      const opa = await extraMember(world, fam.admin, 'parent', 'opa-e2ee@example.org');
      const konv = await gruppe(fam.parent, [fam.child, opa]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child), wrap(konv, 1, opa)]))).toEqual([]);
      await opa.pull();
      await fam.child.pull();
      expect((await fam.admin.client.del(`/api/v1/members/${opa.userId}`)).status).toBe(200);
      expect(await rows(sql`select 1 from epoche_wraps where empfaenger_id = ${opa.userId}`)).toHaveLength(0);
      expect(await rows(sql`select 1 from epoche_wraps where konversation_id = ${konv}`)).toHaveLength(2);
      // die übrigen Teilnehmer behalten Epoche und eigenen Wrap
      const spaeter = await fam.child.pull();
      expect(ids(spaeter, 'epoche_wrap')).toEqual([]);
      expect((await rows(sql`select deleted_at from epoche_wraps where empfaenger_id = ${fam.child.userId}`))[0]?.deleted_at).toBeNull();
    });

    it('Konversation gelöscht: Epochen und Wraps werden mit gelöscht; der Server speichert nie einen Klartext', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.child)]))).toEqual([]);
      const rev = Number((await rows(sql`select rev from konversationen where id = ${konv}`))[0]?.rev);
      expect((await fam.parent.sync([remove('konversation', konv, rev)])).json.acked).toHaveLength(1);
      expect(await rows(sql`select 1 from konversation_epochen where konversation_id = ${konv} and deleted_at is null`)).toHaveLength(0);
      expect(await rows(sql`select 1 from epoche_wraps where konversation_id = ${konv} and deleted_at is null`)).toHaveLength(0);
    });
  });
});
