// Push-Wecker (UnifiedPush über das eigene ntfy). Der Wecker hat KEINEN Inhalt: fester Minimal-Body, keine Titel, keine Tags.
// Das Gerät holt sich daraufhin per Sync, was es sehen darf, und zeigt selbst eine lokale Benachrichtigung.
//
// Ablauf von weckeGeraete(): Familien-Revision gestiegen -> Empfänger bestimmen (Geräte mit Endpunkt, aktive Mitglieder, deren Rolle die
// Änderung sehen darf; nicht das auslösende GERÄT; zusätzliche Filter) -> je Gerät entprellt senden (höchstens ein Wecker je Gerät und
// Mindestabstand; was dazwischen anfällt, wird zu einem zusammengefasst).
//
// Entscheidungen:
//  - Absender: Ausgeschlossen wird nur das auslösende Gerät. Die anderen Geräte derselben Person werden geweckt und gleichen ab; ob
//    daraufhin eine Anzeige erscheint, entscheidet der EreignisBenachrichtiger der App (eigene Änderungen zeigt er nicht an).
//  - Offene WebSocket-Verbindung: Ein Gerät, dessen Verbindung kürzlich Lebenszeichen zeigte (Pong/Nachricht innerhalb von
//    `liveFensterMs`), bekommt den Rev-Hinweis über den Socket und keinen Push. Damit ein halbtoter Socket (Funkloch, Standby) keinen
//    Wecker verschluckt, wird nach Ablauf der Ping-Frist (`nachpruefenMs`) einmal nachgeprüft und dann gesendet, wenn keine lebendige
//    Verbindung mehr da ist.
//  - Fehler von ntfy: Netz, Zeitlimit und 5xx sind Störungen des ntfy, nicht des Geräts: globale Pause (kein Zählen je Endpunkt, damit
//    ein ntfy-Neustart nicht alle Endpunkte deaktiviert). Nur 404/410 deaktivieren sofort, übrige 4xx zählen (5 in Folge).
//
// ERWEITERUNGSSTELLE (Chat, später Kalender/Aufgaben): Die Rollen-Sicht (Audience) kennt jeder Datensatz über die Sync-Regeltabelle und
// kommt als `roles` in das Ereignis. Was Rollen nicht ausdrücken können (Privatchats: nur Teilnehmer), liefert ein Empfängerfilter:
//   push.addRecipientFilter(async (ev) => teilnehmerUserIds)   // null = keine Einschränkung
// Alle Filter wirken als Schnitt. Der Chat registriert seinen Filter beim Aufbau der App (app.ts) und bekommt dafür familyId, rev und
// die Absender-Angabe; er liefert die userIds, die die Änderungen dieser Revision sehen dürfen (z. B. Teilnehmer der betroffenen Chats).
import { and, eq, inArray, isNull, ne, or, sql } from 'drizzle-orm';
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
  /** Zusätzlich genannte Personen (Chat: Teilnehmer; `usersThatMayRead` der Sync-Regeltabelle). Gilt zusätzlich zu `roles`; ohne `roles` keine Einschränkung. */
  users?: readonly string[] | undefined;
  /** Auslöser: dessen Gerät wird nicht geweckt (die anderen Geräte der Person schon). */
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
  /** Hat das Gerät eine lebendige WebSocket-Verbindung (mit Lebenszeichen innerhalb von `maxIdleMs`)? */
  hasLiveSocket: (deviceId: string, maxIdleMs: number) => boolean;
  fetch?: typeof fetch;
  /** Mindestabstand zwischen zwei Weckern an dasselbe Gerät (Standard 10 s). */
  minIntervalMs?: number;
  /** Zeitlimit eines Sendeversuchs (Standard 5 s). */
  timeoutMs?: number;
  /** Eine Verbindung gilt als lebendig, wenn sie in diesem Zeitraum ein Lebenszeichen zeigte (Standard 45 s = 1,5 Ping-Intervalle). */
  liveFensterMs?: number;
  /** Wartezeit bis zur Nachprüfung eines wegen offener Verbindung nicht gesendeten Weckers (Standard 46 s). */
  nachpruefenMs?: number;
}

/** Aufeinanderfolgende gezielte 4xx-Fehler, ab denen ein Endpunkt deaktiviert wird. */
export const MAX_FAILS = 5;
const DEFAULT_MIN_INTERVAL_MS = 10_000;
const DEFAULT_TIMEOUT_MS = 5000;
const DEFAULT_BACKOFF_MS = 60_000;
const MAX_BACKOFF_MS = 10 * 60_000;
/** Neue Planungen eines Weckers nach einer Pause (429, 401/403), je ursprünglichem Auslöser. */
const MAX_RETRIES = 2;
const STATE_MAX_AGE_MS = 60_000;

type SendOutcome = 'ok' | 'gone' | 'client' | 'rate_limited' | 'auth' | 'pause';

interface DeviceState {
  lastSent: number;
  timer?: NodeJS.Timeout | undefined;
  recheck?: NodeJS.Timeout | undefined;
}

export class PushService {
  private readonly filters: RecipientFilter[] = [];
  private readonly state = new Map<string, DeviceState>();
  private readonly testSent = new Map<string, number>();
  private readonly timeout: number;
  private readonly doFetch: typeof fetch;
  private backoffUntil = 0;
  private warnedOff = false;
  private closed = false;

  /** Mindestabstand der Wecker je Gerät (Tests stellen ihn um). */
  minIntervalMs: number;
  liveFensterMs: number;
  nachpruefenMs: number;
  /** Globale Pause nach Netz-/5xx-Fehlern bzw. nach 401/403 (Tests stellen sie um). */
  fehlerPauseMs = 30_000;
  authPauseMs = 5 * 60_000;

  constructor(private readonly o: PushOptions) {
    this.minIntervalMs = o.minIntervalMs ?? DEFAULT_MIN_INTERVAL_MS;
    this.timeout = o.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.liveFensterMs = o.liveFensterMs ?? 45_000;
    this.nachpruefenMs = o.nachpruefenMs ?? 46_000;
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
    for (const s of this.state.values()) {
      if (s.timer) clearTimeout(s.timer);
      if (s.recheck) clearTimeout(s.recheck);
    }
    this.state.clear();
    this.testSent.clear();
    this.backoffUntil = 0;
  }

  /** Beim Herunterfahren: offene Timer löschen. */
  close(): void {
    this.closed = true;
    this.reset();
  }

  /** Entfernt Zustände von Geräten, die lange nichts mehr bekamen (die Map wächst sonst mit jedem je geweckten Gerät). */
  private prune(): void {
    const now = Date.now();
    const alt = Math.max(this.minIntervalMs, STATE_MAX_AGE_MS);
    for (const [id, s] of this.state) if (!s.timer && !s.recheck && now - s.lastSent > alt) this.state.delete(id);
    for (const [id, t] of this.testSent) if (now - t > alt) this.testSent.delete(id);
  }

  /** Geräte der Familie wecken, die die Änderung betrifft. Wirft nie (Fehler gehen ins Log). */
  async weckeGeraete(ev: WakeEvent): Promise<void> {
    if (this.closed) return;
    if (!this.enabled) return this.logStatusOnce();
    try {
      this.prune();
      // Sicht wie beim WebSocket-Hinweis: Rolle sieht die Änderung ODER die Person ist ausdrücklich genannt (Privatchat: nur Teilnehmer, nie über Rollen)
      const sicht = ev.roles
        ? (or(ev.roles.length > 0 ? inArray(memberships.role, [...ev.roles]) : undefined, ev.users?.length ? inArray(devices.userId, [...ev.users]) : undefined) ?? sql`false`)
        : undefined;
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
            sicht,
            // nur das auslösende GERÄT (ohne Geräteangabe wird niemand ausgenommen)
            ev.origin?.deviceId ? ne(devices.id, ev.origin.deviceId) : undefined,
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
        if (this.live(row.deviceId)) this.nachpruefen(row.deviceId);
        else this.schedule(row.deviceId);
      }
    } catch (err: unknown) {
      this.o.log.error({ err }, 'Push: Empfänger konnten nicht bestimmt werden');
    }
  }

  private live(deviceId: string): boolean {
    return this.o.hasLiveSocket(deviceId, this.liveFensterMs);
  }

  /** Ein wegen offener Verbindung nicht gesendeter Wecker wird nach Ablauf der Ping-Frist einmal nachgeprüft (genau ein Timer je Gerät). */
  private nachpruefen(deviceId: string): void {
    const st = this.state.get(deviceId) ?? { lastSent: 0 };
    this.state.set(deviceId, st);
    if (st.recheck) return;
    st.recheck = setTimeout(() => {
      st.recheck = undefined;
      if (this.closed) return;
      if (!this.live(deviceId)) this.schedule(deviceId);
    }, this.nachpruefenMs);
    st.recheck.unref();
  }

  /** Entprellt: sofort senden, wenn Mindestabstand und globale Pause es erlauben, sonst genau einen Wecker später (zusammengefasst). */
  private schedule(deviceId: string, versuch = 0): void {
    const st = this.state.get(deviceId) ?? { lastSent: 0 };
    this.state.set(deviceId, st);
    if (st.timer) return; // es ist schon einer geplant: zusammenfassen
    const warten = () => Math.max(0, st.lastSent + this.minIntervalMs - Date.now(), this.backoffUntil - Date.now());
    const w = warten();
    if (w === 0) {
      st.lastSent = Date.now();
      void this.deliver(deviceId, versuch);
      return;
    }
    const aufruf = () => {
      // die Pause kann sich verlängert haben (neue Fehler, größeres Retry-After): mit der Restdauer neu planen
      const rest = warten();
      if (rest > 0) {
        st.timer = setTimeout(aufruf, rest);
        st.timer.unref();
        return;
      }
      st.timer = undefined;
      st.lastSent = Date.now();
      void this.deliver(deviceId, versuch);
    };
    st.timer = setTimeout(aufruf, w);
    st.timer.unref();
  }

  /** Sendet an ein Gerät (liest den aktuellen Endpunkt) und verbucht das Ergebnis. */
  private async deliver(deviceId: string, versuch: number): Promise<void> {
    try {
      if (this.closed) return;
      if (this.live(deviceId)) return this.nachpruefen(deviceId);
      const [ep] = await this.o.db
        .select({ topic: pushEndpoints.topic, failCount: pushEndpoints.failCount })
        .from(pushEndpoints)
        .where(and(eq(pushEndpoints.deviceId, deviceId), isNull(pushEndpoints.disabledAt)));
      if (!ep) return;
      const outcome = await this.send(ep.topic);
      await this.record(deviceId, outcome, ep.failCount);
      // nach einer Pause (429, 401/403) genau ein zusammengefasster Wecker; Netz-/5xx-Fehler einmal nach der Pause
      if ((outcome === 'rate_limited' || outcome === 'auth') && versuch < MAX_RETRIES) this.schedule(deviceId, versuch + 1);
      // Netzfehler und 5xx (ntfy-Neustart): nach der globalen Pause genau einmal erneut, sonst ginge ein Wecker verloren, bis der nächste Auslöser kommt
      else if (outcome === 'pause' && versuch === 0) this.schedule(deviceId, 1);
    } catch (err: unknown) {
      this.o.log.error({ err }, 'Push: Versand fehlgeschlagen');
    }
  }

  private pause(ms: number): void {
    this.backoffUntil = Math.max(this.backoffUntil, Date.now() + Math.min(ms, MAX_BACKOFF_MS));
  }

  /** POST an die Loopback-URL (nie an die vom Gerät gemeldete URL) mit Token; das Topic wurde beim Anmelden streng geprüft. */
  private async send(topic: string): Promise<SendOutcome> {
    const { ntfyUrl, ntfyToken } = this.o.config;
    if (!ntfyUrl || !ntfyToken) return 'auth';
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
        this.pause(Number.isFinite(ra) && ra > 0 ? ra * 1000 : DEFAULT_BACKOFF_MS);
        return 'rate_limited';
      }
      if (res.status === 401 || res.status === 403) {
        // Token/ACL falsch: Fehler des Betriebs, nicht des Geräts; Endpunkte bleiben, der Versand pausiert
        this.pause(this.authPauseMs);
        this.o.log.error({ status: res.status }, 'Push: ntfy lehnt das Token ab (Rechte auf up* prüfen)');
        return 'auth';
      }
      if (res.status >= 500) {
        this.pause(this.fehlerPauseMs);
        return 'pause';
      }
      return 'client'; // übrige 4xx: kein Retry, zählt gegen den Endpunkt
    } catch {
      // Netzwerkfehler oder Zeitlimit: Störung des ntfy (Neustart), nicht des Endpunkts
      this.pause(this.fehlerPauseMs);
      return 'pause';
    }
  }

  private async record(deviceId: string, outcome: SendOutcome, failCount: number): Promise<void> {
    const now = this.o.now();
    const where = eq(pushEndpoints.deviceId, deviceId);
    if (outcome === 'ok') {
      await this.o.db.update(pushEndpoints).set({ lastOkAt: now, failCount: 0 }).where(where);
    } else if (outcome === 'gone') {
      await this.o.db.update(pushEndpoints).set({ disabledAt: now, lastErrorAt: now, failCount: failCount + 1 }).where(where);
    } else if (outcome === 'client') {
      const next = failCount + 1;
      await this.o.db
        .update(pushEndpoints)
        .set({ lastErrorAt: now, failCount: next, ...(next >= MAX_FAILS ? { disabledAt: now } : {}) })
        .where(where);
    } else if (outcome === 'pause') {
      // nur zur Anzeige, ohne den Zähler zu erhöhen
      await this.o.db.update(pushEndpoints).set({ lastErrorAt: now }).where(where);
    }
    // rate_limited und auth: kein Fehler des Endpunkts
  }

  /** Test-Wecker für das Gerät der Sitzung (Einstellungen): sofort, höchstens einer je Mindestabstand und Gerät, nicht während einer Pause. */
  async sendeTest(deviceId: string, familyId: string): Promise<TestResult> {
    if (!this.enabled) return 'push_off';
    const [ep] = await this.o.db
      .select({ topic: pushEndpoints.topic, disabledAt: pushEndpoints.disabledAt, failCount: pushEndpoints.failCount })
      .from(pushEndpoints)
      .where(and(eq(pushEndpoints.deviceId, deviceId), eq(pushEndpoints.familyId, familyId)));
    if (!ep) return 'no_endpoint';
    if (ep.disabledAt) return 'disabled';
    const now = Date.now();
    if (now < this.backoffUntil) return 'failed';
    const letzter = this.testSent.get(deviceId) ?? 0;
    if (now - letzter < this.minIntervalMs) return 'rate_limited';
    this.testSent.set(deviceId, now);
    const outcome = await this.send(ep.topic);
    await this.record(deviceId, outcome, ep.failCount);
    return outcome === 'ok' ? 'sent' : 'failed';
  }
}
