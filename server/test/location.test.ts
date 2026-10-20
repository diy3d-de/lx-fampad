// Standort teilen: flüchtiger, opaker Kanal über den WebSocket (Rechte, Familiengrenze, Limits, nichts persistiert, nichts im Log).
import type { FastifyInstance } from 'fastify';
import type { AddressInfo } from 'node:net';
import { Writable } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { buildApp } from '../src/app.js';
import type { AuthService, Principal, Role } from '../src/auth/types.js';
import { loadConfig } from '../src/config.js';
import { locationRecipients } from '../src/sync/permissions.js';
import { TEST_KEY } from './helpers.js';

const uid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const ALICE = uid(1);
const BOB = uid(2);
const KID = uid(3);
const EVE = uid(4); // andere Familie
const SHARE = uid(100);

const principals: Record<string, Principal> = {
  alice: { userId: ALICE, familyId: 'f1', role: 'admin', deviceId: 'dev-alice-1' },
  alice2: { userId: ALICE, familyId: 'f1', role: 'admin', deviceId: 'dev-alice-2' },
  bob: { userId: BOB, familyId: 'f1', role: 'parent', deviceId: 'dev-bob' },
  kid: { userId: KID, familyId: 'f1', role: 'child', deviceId: 'dev-kid' },
  eve: { userId: EVE, familyId: 'f2', role: 'admin', deviceId: 'dev-eve' },
};
const auth: AuthService = { authenticate: async () => null, redeemWsTicket: async (t) => principals[t] ?? null };

type Msg = Record<string, unknown>;
interface Conn {
  ws: WebSocket;
  messages: Msg[];
  of(type: string): Msg[];
}

let app: FastifyInstance | undefined;
const sockets: WebSocket[] = [];
let clock = 1_000_000;
let members: Array<{ userId: string; role: Role }> = [];
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function start(env: NodeJS.ProcessEnv = {}, logStream?: Writable) {
  clock = 1_000_000;
  members = [
    { userId: ALICE, role: 'admin' },
    { userId: BOB, role: 'parent' },
    { userId: KID, role: 'child' },
  ];
  app = await buildApp({
    config: loadConfig({ NODE_ENV: 'test', LOG_LEVEL: logStream ? 'trace' : 'silent', AUTH_SECRET_KEY: TEST_KEY, LOC_SWEEP_MS: '3600000', WS_AUTH_TIMEOUT_MS: '60000', WS_PING_INTERVAL_MS: '600000', ...env }),
    auth,
    memberDirectory: async (familyId) => (familyId === 'f1' ? members : []),
    locationClock: () => clock,
    ...(logStream ? { logStream } : {}),
  });
  await app.listen({ host: '127.0.0.1', port: 0 });
  return app;
}

async function connect(who: keyof typeof principals): Promise<Conn> {
  const { port } = (app as FastifyInstance).server.address() as AddressInfo;
  const messages: Msg[] = [];
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`, { headers: { 'x-forwarded-for': `203.0.113.${10 + sockets.length}` } });
  sockets.push(ws);
  ws.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8'))));
  await new Promise<void>((resolve, reject) => {
    ws.once('open', () => resolve());
    ws.once('error', reject);
  });
  ws.send(JSON.stringify({ type: 'auth', ticket: who }));
  for (let i = 0; i < 100 && !messages.some((m) => m.type === 'ready'); i++) await wait(10);
  expect(messages.some((m) => m.type === 'ready')).toBe(true);
  return { ws, messages, of: (type) => messages.filter((m) => m.type === type) };
}

const send = async (c: Conn, msg: Msg) => {
  c.ws.send(JSON.stringify(msg));
  await wait(60);
};
const startMsg = (recipients: Array<[string, string]>, extra: Msg = {}): Msg => ({
  type: 'loc_start',
  shareId: SHARE,
  endsAt: clock + 60 * 60 * 1000,
  recipients: recipients.map(([userId, wrap]) => ({ userId, wrap })),
  ...extra,
});

afterEach(async () => {
  for (const s of sockets.splice(0)) s.terminate();
  await app?.close();
  app = undefined;
});

describe('Rechte-Regel locationRecipients', () => {
  const actor = { userId: 'a', role: 'child' as const };
  const family = [
    { userId: 'a', role: 'child' as const },
    { userId: 'b', role: 'parent' as const },
    { userId: 'c', role: 'admin' as const },
  ];
  it('erlaubt aktive Mitglieder, nie sich selbst und nie Fremde; keine Rolle ist ausgenommen', () => {
    expect(locationRecipients(actor, family, ['b', 'c'])).toEqual({ allowed: ['b', 'c'], rejected: [] });
    expect(locationRecipients(actor, family, ['a', 'x', 'b'])).toEqual({ allowed: ['b'], rejected: ['a', 'x'] });
    expect(locationRecipients({ userId: 'b', role: 'parent' }, family, ['a'])).toEqual({ allowed: ['a'], rejected: [] });
    expect(locationRecipients(actor, [], ['b'])).toEqual({ allowed: [], rejected: ['b'] });
  });
});

describe('Push-Wecker-Haken (onWake)', () => {
  const wakes: Array<{ familyId: string; userIds: string[] }> = [];
  const spy = (a: FastifyInstance) => {
    wakes.length = 0;
    (a.location as { onWake?: (f: string, u: string[]) => void }).onWake = (familyId, userIds) => wakes.push({ familyId, userIds });
  };

  it('Start meldet die Empfänger (nur Familie und Personen); Verlängern, Position, Beenden und Wiederverbinden melden nichts', async () => {
    const a = await start();
    spy(a);
    const [alice, , kid] = [await connect('alice'), await connect('bob'), await connect('kid')];
    await send(alice, startMsg([[BOB, 'w1'], [KID, 'w2']]));
    expect(wakes).toEqual([{ familyId: 'f1', userIds: [BOB, KID] }]);
    clock += 2000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'AAAA_bbbb-1' });
    await send(alice, { type: 'loc_extend', shareId: SHARE, endsAt: clock + 7_200_000 });
    await connect('alice2'); // Wiederverbinden eines Geräts
    await send(kid, { type: 'loc_hello' });
    await send(alice, { type: 'loc_stop', shareId: SHARE });
    expect(wakes).toHaveLength(1);
  });

  it('Entprellung: je Sender und Empfänger höchstens alle 10 Minuten; neue Empfänger werden trotzdem geweckt', async () => {
    const a = await start();
    spy(a);
    const alice = await connect('alice');
    await send(alice, startMsg([[BOB, 'w1']]));
    await send(alice, { type: 'loc_stop', shareId: SHARE });
    clock += 5 * 60_000;
    const share2 = uid(101);
    await send(alice, startMsg([[BOB, 'w1'], [KID, 'w2']], { shareId: share2, endsAt: clock + 3_600_000 }));
    expect(wakes.map((w) => w.userIds)).toEqual([[BOB], [KID]]); // Bob wurde vor 5 Minuten geweckt, Kid noch nie
    await send(alice, { type: 'loc_stop', shareId: share2 });
    clock += 6 * 60_000; // Bob: 11 Minuten her, Kid: 6 Minuten
    const share3 = uid(102);
    await send(alice, startMsg([[BOB, 'w1'], [KID, 'w2']], { shareId: share3, endsAt: clock + 3_600_000 }));
    expect(wakes.map((w) => w.userIds)).toEqual([[BOB], [KID], [BOB]]);
  });

  it('abgelehnte Starts (falsche Empfänger) wecken niemanden', async () => {
    const a = await start();
    spy(a);
    const alice = await connect('alice');
    await send(alice, startMsg([[EVE, 'w']]));
    await send(alice, startMsg([[ALICE, 'w']]));
    expect(wakes).toHaveLength(0);
  });

  it('ein Fehler im Wecker-Haken lässt die Freigabe gelten', async () => {
    const a = await start();
    (a.location as { onWake?: () => void }).onWake = () => {
      throw new Error('kaputt');
    };
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w1']]));
    expect(alice.of('loc_started')).toHaveLength(1);
    expect(bob.of('loc_start')).toHaveLength(1);
  });
});

describe('WebSocket-Kanal "loc"', () => {
  it('Start: nur die gewählten Empfänger bekommen ihren eigenen Wrap, Unbeteiligte und andere Familien nichts', async () => {
    await start();
    const [alice, bob, kid, eve] = [await connect('alice'), await connect('bob'), await connect('kid'), await connect('eve')];
    await send(alice, startMsg([[BOB, 'wrapBob']]));
    expect(alice.of('loc_started')).toEqual([{ type: 'loc_started', shareId: SHARE, endsAt: clock + 3_600_000 }]);
    expect(bob.of('loc_start')).toEqual([{ type: 'loc_start', from: ALICE, shareId: SHARE, endsAt: clock + 3_600_000, wrap: 'wrapBob' }]);
    expect(kid.of('loc_start')).toEqual([]);
    expect(eve.messages.filter((m) => String(m.type).startsWith('loc_'))).toEqual([]);
    expect(alice.of('loc_error')).toEqual([]);
  });

  it('Positionen gehen nur an die Empfänger der Freigabe, nicht zurück an den Sender', async () => {
    await start();
    const [alice, bob, kid] = [await connect('alice'), await connect('bob'), await connect('kid')];
    await send(alice, startMsg([[BOB, 'w1']]));
    clock += 2000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'AAAA_bbbb-1' });
    expect(bob.of('loc_pos')).toEqual([{ type: 'loc_pos', from: ALICE, shareId: SHARE, packet: 'AAAA_bbbb-1' }]);
    expect(kid.of('loc_pos')).toEqual([]);
    expect(alice.of('loc_pos')).toEqual([]);
  });

  it('Empfänger außerhalb der Familie, die Person selbst, Doppelte und Formfehler werden abgelehnt; nichts wird weitergereicht', async () => {
    await start();
    const [alice, bob, eve] = [await connect('alice'), await connect('bob'), await connect('eve')];
    const bad: Msg[] = [
      startMsg([[EVE, 'w']]),
      startMsg([[ALICE, 'w']]),
      startMsg([[BOB, 'w'], [BOB, 'w2']]),
      startMsg([[uid(999), 'w']]),
      startMsg([[BOB, 'zu groß '.repeat(200)]]),
      startMsg([[BOB, 'nicht base64!']]),
      startMsg([]),
      startMsg([[BOB, 'w']], { shareId: 'keine-uuid' }),
      startMsg([[BOB, 'w']], { endsAt: clock - 1 }),
      startMsg([[BOB, 'w']], { endsAt: clock + 13 * 3_600_000 }),
      startMsg([[BOB, 'w']], { endsAt: 'bald' }),
    ];
    for (const m of bad) await send(alice, m);
    expect(alice.of('loc_error').map((m) => m.code)).toEqual([
      'bad_recipients',
      'bad_recipients',
      'bad_recipients',
      'bad_recipients',
      'bad_recipients',
      'bad_recipients',
      'bad_recipients',
      'bad_request',
      'bad_duration',
      'bad_duration',
      'bad_duration',
    ]);
    expect(alice.of('loc_started')).toEqual([]);
    expect([...bob.messages, ...eve.messages].filter((m) => String(m.type).startsWith('loc_'))).toEqual([]);
    expect(app?.location.size).toBe(0);
  });

  it('Fremde und andere Geräte können weder Positionen senden noch beenden (unknown_share, nichts gelangt zu den Empfängern)', async () => {
    await start();
    const [alice, alice2, bob, kid, eve] = [await connect('alice'), await connect('alice2'), await connect('bob'), await connect('kid'), await connect('eve')];
    await send(alice, startMsg([[BOB, 'w'], [KID, 'w']]));
    clock += 2000;
    for (const intruder of [bob, kid, eve, alice2]) {
      await send(intruder, { type: 'loc_pos', shareId: SHARE, packet: 'FAKE' });
      await send(intruder, { type: 'loc_stop', shareId: SHARE });
      await send(intruder, { type: 'loc_extend', shareId: SHARE, endsAt: clock + 1000 });
      expect(intruder.of('loc_error').map((m) => m.code)).toEqual(['unknown_share', 'unknown_share', 'unknown_share']);
    }
    expect(bob.of('loc_pos')).toEqual([]);
    expect(kid.of('loc_pos')).toEqual([]);
    expect(app?.location.size).toBe(1);
  });

  it('Mindestabstand der Positionen und Größenlimit', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    clock += 2000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'p1' });
    clock += 200;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'p2' });
    clock += 1000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'p3' });
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'x'.repeat(1025) });
    expect(bob.of('loc_pos').map((m) => m.packet)).toEqual(['p1', 'p3']);
    expect(alice.of('loc_error').map((m) => m.code)).toEqual(['rate_limited', 'bad_request']);
  });

  it('Obergrenze je Minute: auch bei erlaubtem Mindestabstand höchstens LOC_MAX_PER_MINUTE Positionen, danach wieder frei', async () => {
    await start({ LOC_MAX_PER_MINUTE: '5' });
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    for (let i = 0; i < 7; i++) {
      clock += 2000;
      await send(alice, { type: 'loc_pos', shareId: SHARE, packet: `p${i}` });
    }
    expect(bob.of('loc_pos')).toHaveLength(5);
    expect(alice.of('loc_error').map((m) => m.code)).toEqual(['rate_limited', 'rate_limited']);
    clock += 61_000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'pn' });
    expect(bob.of('loc_pos')).toHaveLength(6);
  });

  it('Ablauf: nach der Endzeit endet die Freigabe von selbst (Empfänger und Sender erfahren es)', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']], { endsAt: clock + 15 * 60_000 }));
    clock += 15 * 60_000 - 1;
    await app?.location.sweep();
    expect(app?.location.size).toBe(1);
    clock += 2;
    await app?.location.sweep();
    await wait(60);
    expect(app?.location.size).toBe(0);
    expect(bob.of('loc_stop')).toEqual([{ type: 'loc_stop', from: ALICE, shareId: SHARE, reason: 'expired' }]);
    expect(alice.of('loc_stop')).toHaveLength(1);
    // danach ist die Freigabe für alle unbekannt
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'p' });
    expect(alice.of('loc_error').map((m) => m.code)).toEqual(['unknown_share']);
  });

  it('Start-Race: schließt der Sender während der Mitgliederprüfung, läuft sofort die Schonfrist', async () => {
    await start({ LOC_GRACE_MS: '30000' });
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    const echt = app!.location as unknown as { deps: { directory: (familyId: string) => Promise<unknown> } };
    const orig = echt.deps.directory;
    echt.deps.directory = async () => {
      alice.ws.close();
      await wait(80);
      return orig('f1');
    };
    await send(alice, startMsg([[BOB, 'w']]));
    await wait(150);
    expect(app?.location.size).toBe(1);
    clock += 31_000;
    await app?.location.sweep();
    await wait(60);
    expect(app?.location.size).toBe(0);
    expect(bob.of('loc_stop').map((m) => m.reason)).toEqual(['disconnected']);
  });

  it('loc_hello: eine Standort-Verbindung zählt nicht als lebendiges Gerät (Push) und bekommt keine Revisionshinweise', async () => {
    await start();
    const alice = await connect('alice');
    expect(app?.hub.hasDevice('dev-alice-1')).toBe(true);
    await send(alice, { type: 'loc_hello' });
    expect(app?.hub.hasDevice('dev-alice-1')).toBe(false);
    app?.hub.notifyRev('f1', 5);
    await wait(50);
    expect(alice.of('rev')).toEqual([]);
    const zweite = await connect('alice');
    expect(app?.hub.hasDevice('dev-alice-1')).toBe(true);
    app?.hub.notifyRev('f1', 6);
    await wait(50);
    expect(zweite.of('rev')).toHaveLength(1);
  });

  it('loc_stop direkt nach loc_start überholt es nicht: die Freigabe entsteht nicht', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    const echt = app!.location as unknown as { deps: { directory: (familyId: string) => Promise<unknown> } };
    const orig = echt.deps.directory;
    echt.deps.directory = async (f: string) => {
      await wait(100);
      return orig(f);
    };
    alice.ws.send(JSON.stringify(startMsg([[BOB, 'w']])));
    alice.ws.send(JSON.stringify({ type: 'loc_stop', shareId: SHARE }));
    await wait(350);
    expect(alice.of('loc_error')).toEqual([]);
    expect(app?.location.size).toBe(0);
    expect(bob.of('loc_start')).toHaveLength(1);
    expect(bob.of('loc_stop')).toHaveLength(1);
  });

  it('Verlängern: auch die Empfänger erfahren das neue Ende', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    await send(alice, { type: 'loc_extend', shareId: SHARE, endsAt: clock + 2 * 3_600_000 });
    expect(bob.of('loc_extend')).toEqual([{ type: 'loc_extend', from: ALICE, shareId: SHARE, endsAt: clock + 7_200_000 }]);
  });

  it('Verlängern nach Ablauf: unknown_share, die Freigabe endet', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']], { endsAt: clock + 60_000 }));
    clock += 61_000;
    await send(alice, { type: 'loc_extend', shareId: SHARE, endsAt: clock + 3_600_000 });
    expect(alice.of('loc_error').map((m) => m.code)).toEqual(['unknown_share']);
    expect(app?.location.size).toBe(0);
    expect(bob.of('loc_stop').map((m) => m.reason)).toEqual(['expired']);
  });

  it('Verlängern geht nur bis zur Obergrenze', async () => {
    await start();
    const alice = await connect('alice');
    await send(alice, startMsg([[BOB, 'w']]));
    await send(alice, { type: 'loc_extend', shareId: SHARE, endsAt: clock + 2 * 3_600_000 });
    expect(alice.of('loc_active')).toEqual([{ type: 'loc_active', shareId: SHARE, endsAt: clock + 7_200_000 }]);
    await send(alice, { type: 'loc_extend', shareId: SHARE, endsAt: clock + 24 * 3_600_000 });
    expect(alice.of('loc_error').map((m) => m.code)).toEqual(['bad_duration']);
  });

  it('Beenden: Empfänger bekommen loc_stop, danach gibt es nichts mehr', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    await send(alice, { type: 'loc_stop', shareId: SHARE });
    expect(bob.of('loc_stop')).toEqual([{ type: 'loc_stop', from: ALICE, shareId: SHARE, reason: 'stopped' }]);
    expect(app?.location.size).toBe(0);
    const late = await connect('bob');
    expect(late.of('loc_start')).toEqual([]);
  });

  it('Spät verbundene Empfänger bekommen Wrap und letzte Position nachgereicht (nur im Arbeitsspeicher)', async () => {
    await start();
    const alice = await connect('alice');
    await send(alice, startMsg([[BOB, 'w-bob']]));
    clock += 2000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'last1' });
    const bob = await connect('bob');
    const kid = await connect('kid');
    expect(bob.of('loc_start')).toHaveLength(1);
    expect(bob.of('loc_pos').map((m) => m.packet)).toEqual(['last1']);
    expect(kid.messages.filter((m) => String(m.type).startsWith('loc_'))).toEqual([]);
  });

  it('Verbindungsverlust des Senders: Schonfrist, Wiederverbinden mit demselben Gerät setzt fort, sonst Ende', async () => {
    await start({ LOC_GRACE_MS: '30000' });
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    alice.ws.close();
    await wait(80);
    clock += 29_000;
    await app?.location.sweep();
    expect(app?.location.size).toBe(1);
    const again = await connect('alice');
    expect(again.of('loc_active')).toHaveLength(1);
    clock += 60_000;
    await app?.location.sweep();
    expect(app?.location.size).toBe(1);
    // ein anderes Gerät derselben Person übernimmt die Freigabe nicht
    const other = await connect('alice2');
    expect(other.of('loc_active')).toEqual([]);
    again.ws.close();
    await wait(80);
    clock += 31_000;
    await app?.location.sweep();
    await wait(60);
    expect(app?.location.size).toBe(0);
    expect(bob.of('loc_stop').map((m) => m.reason)).toEqual(['disconnected']);
  });

  it('eine neue Freigabe ersetzt die alte derselben Person', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w1']]));
    await send(alice, startMsg([[BOB, 'w2']], { shareId: uid(101) }));
    expect(bob.of('loc_stop').map((m) => m.reason)).toEqual(['replaced']);
    expect(bob.of('loc_start')).toHaveLength(2);
    expect(app?.location.size).toBe(1);
  });

  it('Widerruf (Abmelden, Entfernen) beendet die Freigabe sofort', async () => {
    await start();
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    app?.location.revoke({ kind: 'user', userId: ALICE });
    await wait(60);
    expect(bob.of('loc_stop')).toHaveLength(1);
    expect(app?.location.size).toBe(0);
  });

  it('Mitgliedschaft wird erneut geprüft: entfernte Empfänger bekommen nichts mehr, ein entfernter Sender beendet', async () => {
    await start();
    const [alice, bob, kid] = [await connect('alice'), await connect('bob'), await connect('kid')];
    await send(alice, startMsg([[BOB, 'w'], [KID, 'w']]));
    members = members.filter((m) => m.userId !== BOB);
    await app?.location.sweep({ recheckMs: 0 });
    clock += 2000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'p1' });
    expect(bob.of('loc_pos')).toEqual([]);
    expect(kid.of('loc_pos')).toHaveLength(1);
    // auch ein neu verbundener, wieder aufgenommener Empfänger bekommt den alten Wrap nicht nachgereicht
    members.push({ userId: BOB, role: 'parent' });
    expect((await connect('bob')).of('loc_start')).toEqual([]);
    members = members.filter((m) => m.userId !== ALICE);
    await app?.location.sweep({ recheckMs: 0 });
    await wait(60);
    expect(kid.of('loc_stop').map((m) => m.reason)).toEqual(['removed']);
    expect(app?.location.size).toBe(0);
  });

  it('Grenzen: Freigaben je Familie und Starts je Person', async () => {
    await start({ LOC_MAX_SHARES_PER_FAMILY: '1' });
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'w']]));
    await send(bob, startMsg([[ALICE, 'w']], { shareId: uid(102) }));
    expect(bob.of('loc_error').map((m) => m.code)).toEqual(['too_many_shares']);
    // Ersetzen der eigenen Freigabe zählt nicht doppelt
    await send(alice, startMsg([[BOB, 'w']], { shareId: uid(103) }));
    expect(alice.of('loc_error')).toEqual([]);
    await app?.close();
    sockets.splice(0).forEach((s) => s.terminate());
    await start();
    const a = await connect('alice');
    for (let i = 0; i < 11; i++) await send(a, startMsg([[BOB, 'w']], { shareId: uid(200 + i) }));
    expect(a.of('loc_error').map((m) => m.code)).toEqual(['rate_limited']);
  });

  it('flüchtig: nach einem Neustart ist nichts mehr da; das Log enthält weder Wraps noch Positionen', async () => {
    const lines: string[] = [];
    const logStream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(String(chunk));
        cb();
      },
    });
    await start({}, logStream);
    const [alice, bob] = [await connect('alice'), await connect('bob')];
    await send(alice, startMsg([[BOB, 'GEHEIMER-WRAP-12345']]));
    clock += 2000;
    await send(alice, { type: 'loc_pos', shareId: SHARE, packet: 'GEHEIMES-PAKET-67890' });
    await send(alice, { type: 'loc_pos', shareId: uid(555), packet: 'GEHEIMES-PAKET-FALSCH' });
    expect(bob.of('loc_pos')).toHaveLength(1);
    await app?.close();
    for (const s of sockets.splice(0)) s.terminate();
    const log = lines.join('');
    expect(log).not.toContain('GEHEIM');
    expect(log).not.toContain(SHARE);
    await start();
    expect(app?.location.size).toBe(0);
    expect((await connect('bob')).messages.filter((m) => String(m.type).startsWith('loc_'))).toEqual([]);
  });

  it('ohne Anmeldung: keine loc-Nachrichten', async () => {
    await start();
    const { port } = (app as FastifyInstance).server.address() as AddressInfo;
    const messages: Msg[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    sockets.push(ws);
    ws.on('message', (raw: Buffer) => messages.push(JSON.parse(raw.toString('utf8'))));
    await new Promise<void>((resolve) => ws.once('open', () => resolve()));
    ws.send(JSON.stringify(startMsg([[BOB, 'w']])));
    await wait(80);
    expect(messages).toContainEqual({ type: 'error', code: 'unauthenticated' });
    expect(app?.location.size).toBe(0);
  });
});
