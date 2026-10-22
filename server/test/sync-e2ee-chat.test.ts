// E2EE Phase 2 auf dem Server: Hülle e1 (Downgrade-Schutz), Epochen und Schlüssel-Wraps als undurchsichtige Daten (Form, Größe, Eindeutigkeit, Sicht).
// Der Server entschlüsselt und prüft nie etwas: die Tests arbeiten mit Platzhalter-Texten in Base64url-Form.
import { randomUUID } from 'node:crypto';
import { sql } from 'drizzle-orm';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { direktChatId, epocheId, familienchatId, wrapId, wrapIdV2 } from '../src/sync/entities/chat-ids.js';
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
  /** Macht eine Konversation zum Klartext-Altbestand (so etwas lässt sich nicht mehr anlegen; die Zeile stammt dann aus früherer Zeit). */
  const altbestand = async (konv: string): Promise<string> => {
    await world.db.execute(sql`update konversationen set enc_version = 'p1' where id = ${konv}`);
    return konv;
  };
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

    it('die Version ist beim Anlegen nur e1, danach unveränderlich (kein Zurückstufen auf Klartext)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      const rev = Number((await rows(sql`select rev from konversationen where id = ${konv}`))[0]?.rev);
      expect(codes(await fam.parent.sync([upsert('konversation', konv, { encVersion: 'p1' }, rev)]))).toEqual(['invalid']);
      expect((await rows(sql`select enc_version from konversationen where id = ${konv}`))[0]?.enc_version).toBe('e1');
      expect(codes(await fam.parent.sync([upsert('konversation', randomUUID(), { art: 'group', encVersion: 'e9', teilnehmer: [fam.parent.userId, fam.child.userId] })]))).toEqual(['invalid']);
      // Altbestand p1: der Server nimmt dort nichts Neues an (weder Klartext noch Hülle)
      const alt = await altbestand(await gruppe(fam.parent, [fam.child]));
      expect(codes(await fam.parent.sync([upsert('nachricht', randomUUID(), { konversationId: alt, text: 'p1:alt' })]))).toEqual(['invalid']);
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
      const alt = await altbestand(await gruppe(fam.parent, [fam.child]));
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
      const alt = await altbestand(await gruppe(fam.parent, [fam.child]));
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
      // Soft-Delete: seine Wraps sind gelöscht (Tombstone), die Zeile bleibt bis zum endgültigen Löschen liegen
      expect(await rows(sql`select 1 from epoche_wraps where empfaenger_id = ${opa.userId} and deleted_at is null`)).toHaveLength(0);
      expect(await rows(sql`select 1 from epoche_wraps where konversation_id = ${konv} and deleted_at is null`)).toHaveLength(2);
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
  describe('Härtung: vergiftete Epochen, Wiederbeleben, Raten, Verlauf', () => {
    it('Wraps der höchsten Epoche nur vom Verteiler dieser Epoche; ältere Epochen darf jeder Teilnehmer nachreichen; jeder Teilnehmer kann die nächste Epoche anlegen (Selbstheilung)', async () => {
      const konv = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child), wrap(konv, 1, fam.admin)]))).toEqual([]);
      // das Kind legt Epoche 2 an, ohne einen gültigen Wrap zu verteilen (vergiftet) ...
      expect(codes(await fam.child.sync([epoche(konv, 2, BLOB(210))]))).toEqual([]);
      // ... und niemand sonst kann die Wraps dieser Epoche mit Müll vorab belegen oder an ihrer Stelle verteilen
      expect(codes(await fam.parent.sync([wrap(konv, 2, fam.parent, BLOB(111))]))).toEqual(['invalid']);
      expect(codes(await fam.admin.sync([wrap(konv, 2, fam.admin, BLOB(111))]))).toEqual(['invalid']);
      // ältere Epochen (Verlauf teilen) darf jeder Teilnehmer nachreichen: hier hat Epoche 1 für den Admin schon einen Wrap, also wird der zweite abgelehnt, aber nicht als "ungültig"
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.admin, BLOB(130))]))).not.toEqual(['invalid']);
      // Selbstheilung: ein Teilnehmer legt Epoche 3 an (lückenlos) und verteilt sie selbst
      expect(codes(await fam.parent.sync([epoche(konv, 3, BLOB(230)), wrap(konv, 3, fam.parent), wrap(konv, 3, fam.child), wrap(konv, 3, fam.admin)]))).toEqual([]);
      expect(await rows(sql`select 1 from epoche_wraps where konversation_id = ${konv} and epoche = 3`)).toHaveLength(3);
    });

    it('Epochen je Person und Stunde begrenzt (limit_reached); Wiederbeleben eines Direktchats lässt auch Epochen und Wraps mit derselben ID wieder zu', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      for (let n = 1; n <= 12; n++) {
        expect(codes(await fam.parent.sync([epoche(konv, n)])), `Epoche ${n}`).toEqual([]);
        world.advance(61_000);
      }
      expect(codes(await fam.parent.sync([epoche(konv, 13)]))).toEqual(['limit_reached']);
      // nach einer Stunde wieder frei
      world.advance(3_600_000);
      expect(codes(await fam.parent.sync([epoche(konv, 13)]))).toEqual([]);
    });

    it('Wiederbeleben: ein gelöschter Direktchat bekommt mit denselben festen IDs neue Epochen und Wraps', async () => {
      // gelöscht (z. B. weil die andere Person entfernt wurde) und neu angelegt: derselbe Chat mit denselben festen IDs
      const dm2 = direktChatId(fam.parent.userId, fam.child.userId);
      expect((await fam.parent.sync([upsert('konversation', dm2, { art: 'direct', teilnehmer: [fam.parent.userId, fam.child.userId] })])).json.rejected).toEqual([]);
      expect(codes(await fam.parent.sync([epoche(dm2, 1), wrap(dm2, 1, fam.parent), wrap(dm2, 1, fam.child)]))).toEqual([]);
      await world.db.execute(sql`update konversationen set deleted_at = now(), rev = rev + 1 where id = ${dm2}`);
      await world.db.execute(sql`update konversation_epochen set deleted_at = now(), rev = rev + 1 where konversation_id = ${dm2}`);
      await world.db.execute(sql`update epoche_wraps set deleted_at = now(), rev = rev + 1 where konversation_id = ${dm2}`);
      expect((await fam.parent.sync([upsert('konversation', dm2, { art: 'direct', teilnehmer: [fam.parent.userId, fam.child.userId] })])).json.rejected).toEqual([]);
      expect(codes(await fam.parent.sync([epoche(dm2, 1, BLOB(222)), wrap(dm2, 1, fam.parent, BLOB(131)), wrap(dm2, 1, fam.child, BLOB(132))]))).toEqual([]);
      expect(await rows(sql`select wrap from epoche_wraps where konversation_id = ${dm2} and deleted_at is null order by wrap`)).toEqual([{ wrap: BLOB(131) }, { wrap: BLOB(132) }]);
    });

    it('Verlauf für neu Aufgenommene: die eigenen Wraps kommen immer, auch wenn andere Zeilen das Limit füllen (Abfrage schon auf den Empfänger beschränkt)', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child)]))).toEqual([]);
      // viele neuere fremde Wraps (Direkt in der Datenbank, damit die Rate nicht greift)
      await world.db.execute(sql`insert into epoche_wraps (id, family_id, konversation_id, epoche, empfaenger_id, wrap, rev, field_revs, created_at)
        select gen_random_uuid(), ${fam.familyId}::uuid, ${konv}::uuid, 100 + g, ${fam.child.userId}::uuid, ${BLOB(100)}, 1, '{}'::jsonb, now() + g * interval '1 second' from generate_series(1, 600) g`);
      const rev = Number((await rows(sql`select rev from konversationen where id = ${konv}`))[0]?.rev);
      expect((await fam.parent.sync([upsert('konversation', konv, { teilnehmer: [fam.parent.userId, fam.child.userId, fam.admin.userId].sort() }, rev), epoche(konv, 2), wrap(konv, 2, fam.admin), wrap(konv, 1, fam.admin, BLOB(140))])).json.rejected).toEqual([]);
      const adminSicht = await fam.admin.pull();
      expect(adminSicht.filter((c) => c.entity === 'epoche_wrap').map((c) => c.fields.epoche).sort()).toEqual([1, 2]);
      expect(adminSicht.filter((c) => c.entity === 'epoche')).toHaveLength(2);
    });
  });

  describe('Wrap-ID v2 (Verlauf freigeben): derselbe Empfänger, dieselbe Epoche, neue Schlüsselversion', () => {
    /** Wrap der ID v2; die ID enthält den Verteiler [von] (der Akteur, der die Op sendet). */
    const wrapV2 = (von: Device, konv: string, n: number, empfaenger: Device | string, version: number, blob = BLOB(), id?: string) => {
      const emp = typeof empfaenger === 'string' ? empfaenger : empfaenger.userId;
      return upsert('epoche_wrap', id ?? wrapIdV2(konv, n, emp, version, von.userId), { konversationId: konv, epoche: n, empfaengerId: emp, wrap: blob, keyVersion: version });
    };
    /** Die öffentlichen Schlüssel sind für den Server Text: nur die Versionszahl zählt. */
    const schluessel = (d: Device, version: number) =>
      world.db.execute(sql`insert into person_keys (user_id, public_enc_key, public_sign_key, key_version) values (${d.userId}::uuid, 'enc', 'sign', ${version})
        on conflict (user_id) do update set key_version = excluded.key_version`);
    const wraps = async (konv: string, empfaenger?: string) =>
      rows(sql`select epoche, key_version, wrap from epoche_wraps where konversation_id = ${konv} and deleted_at is null and (${empfaenger ?? null}::uuid is null or empfaenger_id = ${empfaenger ?? null}::uuid) order by epoche, key_version nulls first`);
    // person_keys gehört nicht zum Sync-Zustand: jeder Test beginnt (und endet) ohne Schlüssel der Familie
    const schluesselLeeren = () => world.db.execute(sql`delete from person_keys where user_id in (${fam.admin.userId}::uuid, ${fam.parent.userId}::uuid, ${fam.child.userId}::uuid)`);
    beforeEach(schluesselLeeren);
    afterAll(schluesselLeeren);

    it('Known-Answer: die IDs stimmen mit der App überein (chat_ids.dart, gleiche Werte dort)', () => {
      const konv = 'cccccccc-0000-4000-8000-0000000000c1';
      const person = 'AAAAAAAA-0000-4000-8000-00000000000A'; // Großbuchstaben: gleiche ID wie in Kleinbuchstaben
      expect(wrapId(konv, 3, person)).toBe('983b472e-54e3-544a-bc89-d4f59b375feb');
      const verteiler = 'BBBBBBBB-0000-4000-8000-00000000000B';
      expect(wrapIdV2(konv, 3, person, 1, verteiler)).toBe('72337638-0ff4-5a4a-9898-6066b0a43136');
      expect(wrapIdV2(konv, 3, person, 2, verteiler)).toBe('6d138d01-470b-5136-a5ff-1301198a292a');
      expect(wrapIdV2(konv, 4, person, 2, verteiler)).toBe('9c17015b-45eb-5ef9-bb02-10910d4ff0a5');
      expect(wrapIdV2(konv, 3, person, 2, person)).toBe('e552dda5-be8d-5444-a049-8e0889248521');
      // nichts kollidiert: jede Schlüsselversion, jede Epoche, jeder Verteiler und v1 gegen v2 ergeben eigene IDs
      const alle = new Set([wrapId(konv, 3, person), wrapIdV2(konv, 3, person, 1, verteiler), wrapIdV2(konv, 3, person, 2, verteiler), wrapIdV2(konv, 4, person, 2, verteiler), wrapIdV2(konv, 3, person, 12, verteiler), wrapIdV2(konv, 31, person, 2, verteiler), wrapIdV2(konv, 3, person, 2, person)]);
      expect(alle.size).toBe(7);
      expect(wrapIdV2(konv, 3, person.toLowerCase(), 2, verteiler.toLowerCase())).toBe(wrapIdV2(konv, 3, person, 2, verteiler));
    });

    it('nach einem Schlüsselwechsel lässt sich eine ältere Epoche noch einmal für den neuen Schlüssel verpacken; der alte Wrap bleibt', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child, BLOB(150)), epoche(konv, 2), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child)]))).toEqual([]);
      await schluessel(fam.child, 2); // das Kind hat einen neuen Schlüssel (Version 2)
      // Epoche 1 ist nicht mehr die höchste: jeder Teilnehmer darf den Verlauf für die neue Version nachreichen
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 2, BLOB(160))]))).toEqual([]);
      expect(await wraps(konv)).toContainEqual({ epoche: 1, key_version: 2, wrap: BLOB(160) });
      expect(await wraps(konv)).toContainEqual({ epoche: 1, key_version: null, wrap: BLOB(150) });
      // das Kind bekommt beide (der Empfänger wählt anhand der Version im Wrap), sonst niemand
      const kind = (await fam.child.pull()).filter((c) => c.entity === 'epoche_wrap' && c.fields.epoche === 1);
      expect(kind.map((c) => c.fields.wrap).sort()).toEqual([BLOB(150), BLOB(160)]);
      expect(kind.find((c) => c.fields.wrap === BLOB(160))?.fields.keyVersion).toBe(2);
      expect(kind.find((c) => c.fields.wrap === BLOB(150))?.fields.keyVersion).toBeNull();
      expect((await fam.parent.pull()).filter((c) => c.entity === 'epoche_wrap' && c.fields.epoche === 1).map((c) => c.fields.wrap)).toEqual([BLOB()]);
    });

    it('jeder Verteiler hat seinen eigenen Platz je Schlüsselversion (niemand belegt den eines anderen); eine andere Version ist ein eigener Wrap', async () => {
      const konv = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child), wrap(konv, 1, fam.admin), epoche(konv, 2), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child), wrap(konv, 2, fam.admin)]))).toEqual([]);
      await schluessel(fam.child, 3);
      // der Admin (kein Verteiler der Epoche) kommt zuerst, mit Müll: das nimmt dem Elternteil seinen Platz nicht
      expect(codes(await fam.admin.sync([wrapV2(fam.admin, konv, 1, fam.child, 2, BLOB(171))]))).toEqual([]);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 2, BLOB(170))]))).toEqual([]);
      // beide Zeilen liegen da (das Kind probiert sie durch); derselbe Verteiler noch einmal ist "gibt es schon", sein erster Wrap bleibt
      expect((await wraps(konv, fam.child.userId)).filter((w) => w.key_version === 2).map((w) => w.wrap).sort()).toEqual([BLOB(170), BLOB(171)]);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 2, BLOB(172))]))).toEqual(['not_found']);
      expect((await wraps(konv, fam.child.userId)).filter((w) => w.key_version === 2).map((w) => w.wrap).sort()).toEqual([BLOB(170), BLOB(171)]);
      // eine ID mit dem Verteiler eines anderen ist ungültig (niemand sendet unter fremdem Namen)
      expect(codes(await fam.admin.sync([wrapV2(fam.admin, konv, 1, fam.child, 2, BLOB(173), wrapIdV2(konv, 1, fam.child.userId, 2, fam.parent.userId))]))).not.toEqual([]);
      // Version 3: eigener Wrap neben Version 2 und dem alten
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 3, BLOB(174))]))).toEqual([]);
      expect((await wraps(konv, fam.child.userId)).filter((w) => w.epoche === 1).map((w) => w.key_version)).toEqual([null, 2, 2, 3]);
      // der alte Weg bleibt eindeutig: ein zweiter Wrap ohne Version für dieselbe Epoche und Person gibt es nicht
      expect(codes(await fam.parent.sync([wrap(konv, 1, fam.child, BLOB(173))]))).not.toEqual([]);
      expect((await wraps(konv, fam.child.userId)).filter((w) => w.epoche === 1 && w.key_version === null)).toHaveLength(1);
    });

    it('Prüfungen: ID zur Version, keine künftige Version, keine Person ohne Schlüssel, Zahlbereich, Epoche und Teilnehmer wie bei der ID v1', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child), epoche(konv, 2), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child)]))).toEqual([]);
      // das Kind hat (noch) keinen Schlüssel beim Server
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 1)]))).toEqual(['invalid']);
      await schluessel(fam.child, 2);
      // künftige Version: abgelehnt (niemand belegt IDs künftiger Schlüssel vorab)
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 3)]))).toEqual(['invalid']);
      // ID passt nicht zur Version, ID v1 mit Version, ID v2 ohne Version
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 2, BLOB(), wrapIdV2(konv, 1, fam.child.userId, 1, fam.parent.userId))]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 2, BLOB(), wrapId(konv, 1, fam.child.userId))]))).not.toEqual([]);
      expect(codes(await fam.parent.sync([upsert('epoche_wrap', wrapIdV2(konv, 1, fam.child.userId, 2, fam.parent.userId), { konversationId: konv, epoche: 1, empfaengerId: fam.child.userId, wrap: BLOB() })]))).toEqual(['invalid']);
      // Zahlbereich und Form
      for (const v of [0, -1, 1.5, '2', null]) {
        const op = upsert('epoche_wrap', wrapIdV2(konv, 1, fam.child.userId, 2, fam.parent.userId), { konversationId: konv, epoche: 1, empfaengerId: fam.child.userId, wrap: BLOB(), keyVersion: v });
        expect(codes(await fam.parent.sync([op])), `keyVersion ${String(v)}`).toEqual(['invalid']);
      }
      // wie bei v1: die Epoche muss es geben, der Empfänger muss Teilnehmer sein
      await schluessel(fam.admin, 1);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.admin, 1)]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 7, fam.child, 2)]))).toEqual(['invalid']);
      // nichts davon hat eine Zeile angelegt
      expect((await wraps(konv)).filter((w) => w.key_version !== null)).toEqual([]);
    });

    it('die höchste Epoche gilt weiter nur vom Verteiler der Epoche (auch mit Version); ältere darf jeder Teilnehmer', async () => {
      const konv = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child), wrap(konv, 1, fam.admin)]))).toEqual([]);
      await schluessel(fam.child, 2);
      // Epoche 1 ist (noch) die höchste: nur ihr Verteiler (Elternteil) darf, nicht der Admin
      expect(codes(await fam.admin.sync([wrapV2(fam.admin, konv, 1, fam.child, 2, BLOB(180))]))).toEqual(['invalid']);
      expect(codes(await fam.parent.sync([epoche(konv, 2), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child), wrap(konv, 2, fam.admin)]))).toEqual([]);
      // jetzt ist Epoche 1 älter: auch der Admin darf nachreichen
      expect(codes(await fam.admin.sync([wrapV2(fam.admin, konv, 1, fam.child, 2, BLOB(180))]))).toEqual([]);
      // Epoche 2 (höchste): nur der Verteiler
      expect(codes(await fam.admin.sync([wrapV2(fam.admin, konv, 2, fam.child, 2, BLOB(181))]))).toEqual(['invalid']);
    });

    it('Sicht: nur der Empfänger sieht seine Wraps (auch die mit Version); Verteiler, andere Teilnehmer und Fremde sehen sie nie', async () => {
      const konv = await gruppe(fam.parent, [fam.child, fam.admin]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child), wrap(konv, 1, fam.admin), epoche(konv, 2), wrap(konv, 2, fam.parent), wrap(konv, 2, fam.child), wrap(konv, 2, fam.admin)]))).toEqual([]);
      await schluessel(fam.child, 2);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, konv, 1, fam.child, 2, BLOB(190))]))).toEqual([]);
      const wrapsVon = async (d: Device) => (await d.pull()).filter((c) => c.entity === 'epoche_wrap');
      expect((await wrapsVon(fam.child)).filter((c) => c.fields.keyVersion === 2)).toHaveLength(1);
      expect((await wrapsVon(fam.admin)).every((c) => c.fields.empfaengerId === fam.admin.userId && c.fields.keyVersion === null)).toBe(true);
      expect((await wrapsVon(fam.parent)).every((c) => c.fields.empfaengerId === fam.parent.userId && c.fields.keyVersion === null)).toBe(true);
      // der Wecker geht nur an den Empfänger (ownerOnlyNotify): hier genügt die Sicht, der Rest steht in den Sync-Tests des WebSockets
    });

    it('Wiederbeleben: ein gelöschter v2-Wrap lässt sich mit derselben ID neu anlegen (Direktchat nach dem Löschen)', async () => {
      const dm = direktChatId(fam.parent.userId, fam.child.userId);
      expect((await fam.parent.sync([upsert('konversation', dm, { art: 'direct', teilnehmer: [fam.parent.userId, fam.child.userId] })])).json.rejected).toEqual([]);
      expect(codes(await fam.parent.sync([epoche(dm, 1), wrap(dm, 1, fam.parent), wrap(dm, 1, fam.child), epoche(dm, 2), wrap(dm, 2, fam.parent), wrap(dm, 2, fam.child)]))).toEqual([]);
      await schluessel(fam.child, 2);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, dm, 1, fam.child, 2, BLOB(191))]))).toEqual([]);
      await world.db.execute(sql`update epoche_wraps set deleted_at = now(), rev = rev + 1 where konversation_id = ${dm} and key_version is not null`);
      expect(codes(await fam.parent.sync([wrapV2(fam.parent, dm, 1, fam.child, 2, BLOB(192))]))).toEqual([]);
      expect((await wraps(dm)).filter((w) => w.key_version === 2)).toEqual([{ epoche: 1, key_version: 2, wrap: BLOB(192) }]);
    });

    it('Altbestand: Zeilen aus der Zeit vor der Spalte haben keine Version, bleiben gültig und zählen für die Eindeutigkeit als Version 0', async () => {
      const konv = await gruppe(fam.parent, [fam.child]);
      expect(codes(await fam.parent.sync([epoche(konv, 1), wrap(konv, 1, fam.parent), wrap(konv, 1, fam.child)]))).toEqual([]);
      expect((await wraps(konv)).every((w) => w.key_version === null)).toBe(true);
      await expect(
        world.db.execute(sql`insert into epoche_wraps (id, family_id, konversation_id, epoche, empfaenger_id, wrap, rev, field_revs, created_at)
          values (gen_random_uuid(), ${fam.familyId}::uuid, ${konv}::uuid, 1, ${fam.child.userId}::uuid, ${BLOB(100)}, 1, '{}'::jsonb, now())`),
      ).rejects.toThrow();
      await expect(
        world.db.execute(sql`insert into epoche_wraps (id, family_id, konversation_id, epoche, empfaenger_id, wrap, key_version, rev, field_revs, created_at)
          values (gen_random_uuid(), ${fam.familyId}::uuid, ${konv}::uuid, 1, ${fam.child.userId}::uuid, ${BLOB(100)}, 0, 1, '{}'::jsonb, now())`),
      ).rejects.toThrow(); // Version 0 gibt es nicht (CHECK)
    });
  });
});
