// Push-Wecker (UnifiedPush über das eigene ntfy). Der Wecker hat KEINEN Inhalt: fester Minimal-Body, keine Titel, keine Tags.
// Das Gerät holt sich daraufhin per Sync, was es sehen darf, und zeigt selbst eine lokale Benachrichtigung.
//
// Ablauf von weckeGeraete(): Familien-Revision gestiegen -> Empfänger bestimmen (Geräte mit Endpunkt, aktive Mitglieder, deren Rolle die
// Änderung sehen darf; nicht die Person, die sie ausgelöst hat; keine Geräte mit offener WebSocket-Verbindung; zusätzliche Filter) ->
// je Gerät entprellt senden (höchstens ein Wecker je Gerät und Mindestabstand; was dazwischen anfällt, wird zu einem zusammengefasst).
//
// ERWEITERUNGSSTELLE (Chat, später Kalender/Aufgaben): Die Rollen-Sicht (Audience) kennt jeder Datensatz über die Sync-Regeltabelle und
// kommt als `roles` in das Ereignis. Was Rollen nicht ausdrücken können (Privatchats: nur Teilnehmer), liefert ein Empfängerfilter:
//   push.addRecipientFilter(async (ev) => teilnehmerUserIds)   // null = keine Einschränkung
// Alle Filter wirken als Schnitt. Der Chat registriert seinen Filter beim Aufbau der App (app.ts) und bekommt dafür familyId, rev und
// die Absender-Angabe; er liefert die userIds, die die Änderungen dieser Revision sehen dürfen (z. B. Teilnehmer der betroffenen Chats).
import { and, eq, inArray, isNull, ne } from 'drizzle-orm';
import type { Db, Logger, RevOrigin } from '../auth/context.js';
import type { Role } from '../auth/types.js';
import type { Config } from '../config.js';
import { devices, memberships, pushEndpoints } from '../db/schema.js';

/** Fester Inhalt des Weckers: keine Daten, nur "es gibt Neues". */
export const WAKE_BODY = 'wecker';

export interface WakeEvent {
  familyId: string;
  rev: number;
  /** Rollen, die die Änderung sehen dürfen (fehlt: alle). */
  roles?: readonly Role[] | undefined;
  /** Auslöser: dessen Person (und damit alle ihre Geräte) wird nicht geweckt. */
  origin?: RevOrigin | undefined;
}

/** Liefert die userIds, die diese Änderung sehen dürfen; null = keine Einschränkung. */
export type RecipientFilter = (ev: WakeEvent) => Promise<ReadonlySet<string> | null> | ReadonlySet<string> | null;

export type TestResult = 'sent' | 'push_off' | 'no_endpoint' | 'disabled' | 'failed' | 'rate_limited';

export interface PushOptions {
  db: Db;
  config: Config;
  log: Logger;
  now: () => Date;
  /** Hat das Gerät eine offene WebSocket-Verbindung? */
  hasLiveSocket: (deviceId: string) => boolean;
  fetch?: typeof fetch;
  /** Mindestabstand zwischen zwei Weckern an dasselbe Gerät (Standard 10 s). */
  minIntervalMs?: number;
  /** Zeitlimit eines Sendeversuchs (Standard 5 s). */
  timeoutMs?: number;
}

/** Aufeinanderfolgende Fehlschläge, ab denen ein Endpunkt deaktiviert wird. */
export const MAX_FAILS = 5;
const DEFAULT_MIN_INTERVAL_MS = 10_000;
const DEFAULT_TIMEOUT_MS = 5000;
const DEFAULT_BACKOFF_MS = 60_000;
const MAX_BACKOFF_MS = 10 * 60_000;
const CONFIG_BACKOFF_MS = 5 * 60_000;

type SendOutcome = 'ok' | 'gone' | 'fail' | 'rate_limited' | 'config';

interface DeviceState {
  lastSent: number;
  timer?: NodeJS.Timeout | undefined;
}

export class PushService {
  private readonly filters: RecipientFilter[] = [];
  private readonly state = new Map<string, DeviceState>();
  /** Mindestabstand der Wecker je Gerät (Tests stellen ihn um). */
  minIntervalMs: number;
  private readonly timeout: number;
  private readonly doFetch: typeof fetch;
  private backoffUntil = 0;
  private warnedOff = false;
  private closed = false;

  constructor(private readonly o: PushOptions) {
    this.minIntervalMs = o.minIntervalMs ?? DEFAULT_MIN_INTERVAL_MS;
    this.timeout = o.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.doFetch = o.fetch ?? fetch;
  }

  /** Push ist nur an, wenn NTFY_URL und NTFY_TOKEN gesetzt sind. */
  get enabled(): boolean {
    return !!this.o.config.ntfyUrl && !!this.o.config.ntfyToken;
  }

  /** Einmaliger Hinweis im Log, wenn Push aus ist (kein Fehler). */
  logStatusOnce(): void {
    if (this.enabled || this.warnedOff) return;
    this.warnedOff = true;
    this.o.log.warn({}, 'Push ist aus (NTFY_URL/NTFY_TOKEN fehlen)');
  }

  addRecipientFilter(filter: RecipientFilter): void {
    this.filters.push(filter);
  }

  /** Verwirft Entprellung und Backoff (Tests). */
  reset(): void {
    for (const s of this.state.values()) if (s.timer) clearTimeout(s.timer);
    this.state.clear();
    this.backoffUntil = 0;
  }

  /** Beim Herunterfahren: offene Timer löschen. */
  close(): void {
    this.closed = true;
    for (const s of this.state.values()) if (s.timer) clearTimeout(s.timer);
    this.state.clear();
  }

  /** Geräte der Familie wecken, die die Änderung betrifft. Wirft nie (Fehler gehen ins Log). */
  async weckeGeraete(ev: WakeEvent): Promise<void> {
    if (this.closed) return;
    if (!this.enabled) return this.logStatusOnce();
    try {
      const rows = await this.o.db
        .select({ deviceId: pushEndpoints.deviceId, userId: devices.userId })
        .from(pushEndpoints)
        .innerJoin(devices, and(eq(devices.familyId, pushEndpoints.familyId), eq(devices.id, pushEndpoints.deviceId)))
        .innerJoin(memberships, and(eq(memberships.familyId, devices.familyId), eq(memberships.userId, devices.userId)))
        .where(
          and(
            eq(pushEndpoints.familyId, ev.familyId),
            isNull(pushEndpoints.disabledAt),
            isNull(devices.revokedAt),
            eq(memberships.status, 'active'),
            ev.roles ? inArray(memberships.role, [...ev.roles]) : undefined,
            ev.origin ? ne(devices.userId, ev.origin.userId) : undefined,
          ),
        );
      let allowed = undefined as ReadonlySet<string> | undefined;
      for (const f of this.filters) {
        const r = await f(ev);
        if (r === null) continue;
        const prev: ReadonlySet<string> | undefined = allowed;
        allowed = prev === undefined ? r : new Set([...prev].filter((u) => r.has(u)));
      }
      for (const row of rows) {
        if (allowed && !allowed.has(row.userId)) continue;
        if (this.o.hasLiveSocket(row.deviceId)) continue;
        this.schedule(row.deviceId);
      }
    } catch (err: unknown) {
      this.o.log.error({ err }, 'Push: Empfänger konnten nicht bestimmt werden');
    }
  }

  /** Entprellt: sofort senden, wenn der Mindestabstand eingehalten ist, sonst genau einen Wecker später (zusammengefasst). */
  private schedule(deviceId: string): void {
    const now = Date.now();
    const st = this.state.get(deviceId) ?? { lastSent: 0 };
    this.state.set(deviceId, st);
    if (st.timer) return; // es ist schon einer geplant: zusammenfassen
    const wait = Math.max(0, st.lastSent + this.minIntervalMs - now, this.backoffUntil - now);
    if (wait === 0) {
      st.lastSent = now;
      void this.deliver(deviceId);
      return;
    }
    st.timer = setTimeout(() => {
      st.timer = undefined;
      st.lastSent = Date.now();
      void this.deliver(deviceId);
    }, wait);
    st.timer.unref();
  }

  /** Sendet an ein Gerät (liest den aktuellen Endpunkt, prüft nochmals auf offene Verbindung) und verbucht das Ergebnis. */
  private async deliver(deviceId: string): Promise<void> {
    try {
      if (this.closed || this.o.hasLiveSocket(deviceId)) return;
      const [ep] = await this.o.db
        .select({ topic: pushEndpoints.topic, failCount: pushEndpoints.failCount })
        .from(pushEndpoints)
        .where(and(eq(pushEndpoints.deviceId, deviceId), isNull(pushEndpoints.disabledAt)));
      if (!ep) return;
      const outcome = await this.send(ep.topic);
      await this.record(deviceId, outcome, ep.failCount);
      if (outcome === 'rate_limited') this.schedule(deviceId); // ein zusammengefasster Wecker nach dem Backoff
    } catch (err: unknown) {
      this.o.log.error({ err }, 'Push: Versand fehlgeschlagen');
    }
  }

  /** POST an die Loopback-URL (nie an die vom Gerät gemeldete URL) mit Token; das Topic wurde beim Anmelden streng geprüft. */
  private async send(topic: string): Promise<SendOutcome> {
    const { ntfyUrl, ntfyToken } = this.o.config;
    if (!ntfyUrl || !ntfyToken) return 'config';
    try {
      const res = await this.doFetch(`${ntfyUrl}/${topic}`, {
        method: 'POST',
        headers: { authorization: `Bearer ${ntfyToken}`, 'x-unifiedpush': '1', firebase: 'no', 'content-type': 'text/plain; charset=utf-8' },
        body: WAKE_BODY,
        redirect: 'manual',
        signal: AbortSignal.timeout(this.timeout),
      });
      await res.body?.cancel().catch(() => undefined);
      if (res.status >= 200 && res.status < 300) return 'ok';
      if (res.status === 404 || res.status === 410) return 'gone';
      if (res.status === 429) {
        const ra = Number(res.headers.get('retry-after'));
        const ms = Number.isFinite(ra) && ra > 0 ? ra * 1000 : DEFAULT_BACKOFF_MS;
        this.backoffUntil = Math.max(this.backoffUntil, Date.now() + Math.min(ms, MAX_BACKOFF_MS));
        return 'rate_limited';
      }
      if (res.status === 401 || res.status === 403) {
        // Token/ACL falsch: Fehler des Betriebs, nicht des Geräts; Endpunkte bleiben, Versand pausiert
        this.backoffUntil = Math.max(this.backoffUntil, Date.now() + CONFIG_BACKOFF_MS);
        this.o.log.error({ status: res.status }, 'Push: ntfy lehnt das Token ab (Rechte auf up* prüfen)');
        return 'config';
      }
      return 'fail'; // übrige 4xx und 5xx: kein Retry
    } catch {
      return 'fail'; // Netzwerkfehler, Zeitlimit
    }
  }

  private async record(deviceId: string, outcome: SendOutcome, failCount: number): Promise<void> {
    const now = this.o.now();
    const where = eq(pushEndpoints.deviceId, deviceId);
    if (outcome === 'ok') {
      await this.o.db.update(pushEndpoints).set({ lastOkAt: now, failCount: 0 }).where(where);
    } else if (outcome === 'gone') {
      await this.o.db.update(pushEndpoints).set({ disabledAt: now, lastErrorAt: now, failCount: failCount + 1 }).where(where);
    } else if (outcome === 'fail') {
      const next = failCount + 1;
      await this.o.db
        .update(pushEndpoints)
        .set({ lastErrorAt: now, failCount: next, ...(next >= MAX_FAILS ? { disabledAt: now } : {}) })
        .where(where);
    }
    // rate_limited und config: kein Fehler des Endpunkts
  }

  /** Test-Wecker für das Gerät der Sitzung (Einstellungen): sofort, aber höchstens einer je Mindestabstand und Gerät. */
  async sendeTest(deviceId: string, familyId: string): Promise<TestResult> {
    if (!this.enabled) return 'push_off';
    const [ep] = await this.o.db
      .select({ topic: pushEndpoints.topic, disabledAt: pushEndpoints.disabledAt, failCount: pushEndpoints.failCount })
      .from(pushEndpoints)
      .where(and(eq(pushEndpoints.deviceId, deviceId), eq(pushEndpoints.familyId, familyId)));
    if (!ep) return 'no_endpoint';
    if (ep.disabledAt) return 'disabled';
    const st = this.state.get(deviceId) ?? { lastSent: 0 };
    this.state.set(deviceId, st);
    const now = Date.now();
    if (now - st.lastSent < this.minIntervalMs) return 'rate_limited';
    st.lastSent = now;
    const outcome = await this.send(ep.topic);
    await this.record(deviceId, outcome, ep.failCount);
    return outcome === 'ok' ? 'sent' : 'failed';
  }
}
