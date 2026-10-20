// Standort teilen: flüchtiger, vom Server nur weitergereichter Kanal (siehe docs/API.md, Abschnitt "Standort", und docs/PROJEKTBESCHREIBUNG.md, 6f).
//
// Grundsätze:
//  - **Nur Prozessspeicher.** Keine Datenbank, keine Datei, kein Backup, keine Historie; ein Neustart des Dienstes beendet alle Freigaben.
//  - **Opak.** Der Server sieht nur Kennung, Absender, Empfänger, Ablaufzeit und Größe. Schlüssel (Wraps) und Positionen sind für ihn
//    undurchsichtige Base64url-Zeichenketten; er prüft nur Form und Länge. Nichts davon landet im Log.
//  - **Rechte** stehen in sync/permissions.ts (`locationRecipients`): nur aktive Mitglieder der eigenen Familie, nie die Person selbst.
//  - **Auto-Ende:** Ablauf, Verbindungsverlust des Senders (Schonfrist), Entfernen oder Sperren des Senders, ausdrückliches Beenden.
import type { WebSocket } from 'ws';
import type { Principal, Role } from '../auth/types.js';
import { locationRecipients } from '../sync/permissions.js';
import type { Hub, ServerMessage } from '../ws/hub.js';

/** Aktive Mitglieder einer Familie (Rolle nur für die Rechteprüfung; kommt aus der Datenbank, nie vom Client). */
export type MemberDirectory = (familyId: string) => Promise<Array<{ userId: string; role: Role }>>;

export const MAX_RECIPIENTS = 30;
export const MAX_WRAP_LENGTH = 1024;
export const MAX_PACKET_LENGTH = 1024;
/** Freigaben, die ein Mitglied in diesem Zeitraum starten darf (Missbrauchsschutz gegen Dauerfeuer). */
const START_WINDOW_MS = 10 * 60 * 1000;
const START_MAX = 10;
/** Pause, bevor dieselbe Person dieselben Empfänger wieder per Push wecken darf (eine Freigabe, die neu startet oder ersetzt wird, weckt nicht erneut). */
const WAKE_COOLDOWN_MS = 10 * 60 * 1000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE64URL = /^[A-Za-z0-9_-]+$/;

export type EndReason = 'stopped' | 'expired' | 'disconnected' | 'removed' | 'replaced';

interface Share {
  id: string;
  familyId: string;
  ownerId: string;
  /** Gerät des Senders (nur dieses darf Positionen senden); ohne Gerätekennung die Sitzung bzw. die Person. */
  ownerKey: string;
  ownerSessionId: string | undefined;
  endsAt: number;
  recipients: Map<string, string>;
  /** Letztes Paket nur im Arbeitsspeicher, damit ein später verbundener Empfänger nicht leer ausgeht. */
  lastPacket: string | null;
  senderSockets: Set<WebSocket>;
  graceUntil: number | null;
  lastPosAt: number;
  /** Zeitpunkte der Positionen der letzten Minute (Obergrenze je Freigabe). */
  posZeiten: number[];
  lastRecheckAt: number;
}

export interface LocationDeps {
  hub: Hub;
  directory: MemberDirectory;
  now?: () => number;
  maxDurationMs: number;
  maxSharesPerFamily: number;
  minIntervalMs: number;
  maxPerMinute: number;
  graceMs: number;
  sweepMs: number;
  log?: { warn(obj: unknown, msg?: string): void };
}

export type LocationResult = { ok: true } | { ok: false; code: string };

const ownerKeyOf = (p: Principal): string => p.deviceId ?? p.sessionId ?? p.userId;
const sendTo = (socket: WebSocket, msg: ServerMessage): void => {
  if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(msg));
};

export class LocationService {
  private readonly shares = new Map<string, Share>();
  private readonly byOwner = new Map<string, Share>();
  private readonly starts = new Map<string, number[]>();
  /** Letzter Wecker je Sender und Empfänger (`Familie:Sender:Empfänger` -> Zeit), nur im Arbeitsspeicher. */
  private readonly lastWake = new Map<string, number>();

  /**
   * Haken für den Push-Wecker (app.ts): wird nur beim Start einer Freigabe mit den Empfängern aufgerufen, die in den letzten 10 Minuten nicht schon von dieser
   * Person geweckt wurden. Nie bei Verlängern, Wiederverbinden, Ende; nie mit Inhalt (nur Familie und Empfänger).
   */
  onWake: ((familyId: string, userIds: string[]) => void) | undefined;
  private timer: NodeJS.Timeout | null = null;
  private readonly now: () => number;

  constructor(private readonly deps: LocationDeps) {
    this.now = deps.now ?? Date.now;
  }

  /** Startet die periodische Prüfung (Ablauf, Schonfrist, Mitgliedschaft). */
  startTimer(): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.sweep().catch((err: unknown) => this.deps.log?.warn({ err }, 'Standort-Prüfung fehlgeschlagen')), this.deps.sweepMs);
    this.timer.unref();
  }

  close(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.shares.clear();
    this.byOwner.clear();
    this.starts.clear();
    this.lastWake.clear();
  }

  /** Anzahl aktiver Freigaben (Tests, Diagnose; nie Inhalte). */
  get size(): number {
    return this.shares.size;
  }

  private ownerIndex(familyId: string, userId: string): string {
    return `${familyId}:${userId}`;
  }

  private allowStart(userId: string, now: number): boolean {
    const recent = (this.starts.get(userId) ?? []).filter((t) => now - t < START_WINDOW_MS);
    if (recent.length >= START_MAX) {
      this.starts.set(userId, recent);
      return false;
    }
    recent.push(now);
    this.starts.set(userId, recent);
    return true;
  }

  private checkEndsAt(value: unknown, now: number): number | null {
    if (typeof value !== 'number' || !Number.isSafeInteger(value)) return null;
    if (value <= now || value > now + this.deps.maxDurationMs) return null;
    return value;
  }

  async start(p: Principal, socket: WebSocket, msg: { shareId?: unknown; endsAt?: unknown; recipients?: unknown }): Promise<LocationResult> {
    const now = this.now();
    if (typeof msg.shareId !== 'string' || !UUID.test(msg.shareId)) return { ok: false, code: 'bad_request' };
    const endsAt = this.checkEndsAt(msg.endsAt, now);
    if (endsAt === null) return { ok: false, code: 'bad_duration' };
    if (!Array.isArray(msg.recipients) || msg.recipients.length === 0 || msg.recipients.length > MAX_RECIPIENTS) return { ok: false, code: 'bad_recipients' };
    const wraps = new Map<string, string>();
    for (const r of msg.recipients as unknown[]) {
      const rec = (typeof r === 'object' && r !== null ? r : {}) as { userId?: unknown; wrap?: unknown };
      if (typeof rec.userId !== 'string' || !UUID.test(rec.userId) || wraps.has(rec.userId)) return { ok: false, code: 'bad_recipients' };
      if (typeof rec.wrap !== 'string' || rec.wrap.length === 0 || rec.wrap.length > MAX_WRAP_LENGTH || !BASE64URL.test(rec.wrap)) return { ok: false, code: 'bad_recipients' };
      wraps.set(rec.userId, rec.wrap);
    }
    if (this.shares.has(msg.shareId)) return { ok: false, code: 'share_exists' };
    if (!this.allowStart(p.userId, now)) return { ok: false, code: 'rate_limited' };

    // Empfänger gegen die Mitglieder der Familie der Sitzung prüfen (nie gegen Angaben des Clients)
    const members = await this.deps.directory(p.familyId);
    if (!members.some((m) => m.userId === p.userId)) return { ok: false, code: 'forbidden' };
    const { allowed, rejected } = locationRecipients({ userId: p.userId, role: p.role }, members, [...wraps.keys()]);
    if (rejected.length > 0 || allowed.length === 0) return { ok: false, code: 'bad_recipients' };

    // ab hier kein await mehr: prüfen und eintragen in einem Schritt
    if (this.shares.has(msg.shareId)) return { ok: false, code: 'share_exists' };
    const idx = this.ownerIndex(p.familyId, p.userId);
    const old = this.byOwner.get(idx);
    const familyCount = [...this.shares.values()].filter((s) => s.familyId === p.familyId).length - (old ? 1 : 0);
    if (familyCount >= this.deps.maxSharesPerFamily) return { ok: false, code: 'too_many_shares' };
    if (old) this.end(old, 'replaced');
    const share: Share = {
      id: msg.shareId,
      familyId: p.familyId,
      ownerId: p.userId,
      ownerKey: ownerKeyOf(p),
      ownerSessionId: p.sessionId,
      endsAt,
      recipients: new Map(allowed.map((id) => [id, wraps.get(id) as string])),
      lastPacket: null,
      // schloss sich die Verbindung während der Prüfung der Mitglieder, gibt es keinen Sender-Socket mehr: die Schonfrist läuft sofort
      senderSockets: new Set(socket.readyState === socket.OPEN ? [socket] : []),
      graceUntil: socket.readyState === socket.OPEN ? null : now + this.deps.graceMs,
      lastPosAt: 0,
      posZeiten: [],
      lastRecheckAt: now,
    };
    this.shares.set(share.id, share);
    this.byOwner.set(idx, share);
    sendTo(socket, { type: 'loc_started', shareId: share.id, endsAt });
    for (const [userId, wrap] of share.recipients) {
      this.deps.hub.sendToUsers(share.familyId, [userId], { type: 'loc_start', from: share.ownerId, shareId: share.id, endsAt, wrap });
    }
    this.weckeEmpfaenger(share, now);
    return { ok: true };
  }

  /** Push-Wecker an die Empfänger, die nicht schon vor Kurzem von diesem Sender geweckt wurden (Entprellung 10 Minuten je Sender und Empfänger). */
  private weckeEmpfaenger(s: Share, now: number): void {
    if (!this.onWake) return;
    const ids: string[] = [];
    for (const userId of s.recipients.keys()) {
      const key = `${s.familyId}:${s.ownerId}:${userId}`;
      const letzter = this.lastWake.get(key);
      if (letzter !== undefined && now - letzter < WAKE_COOLDOWN_MS) continue;
      this.lastWake.set(key, now);
      ids.push(userId);
    }
    if (ids.length === 0) return;
    try {
      this.onWake(s.familyId, ids);
    } catch (err: unknown) {
      this.deps.log?.warn({ err }, 'Standort-Wecker fehlgeschlagen');
    }
  }

  /** Die Freigabe, wenn sie dieser Sitzung (Person und Gerät) gehört; sonst null (für Fremde gibt es sie nicht). */
  private own(p: Principal, shareId: unknown): Share | null {
    if (typeof shareId !== 'string') return null;
    const s = this.shares.get(shareId);
    return s && s.familyId === p.familyId && s.ownerId === p.userId && s.ownerKey === ownerKeyOf(p) ? s : null;
  }

  position(p: Principal, msg: { shareId?: unknown; packet?: unknown }): LocationResult {
    const s = this.own(p, msg.shareId);
    if (!s) return { ok: false, code: 'unknown_share' };
    const now = this.now();
    if (now >= s.endsAt) {
      this.end(s, 'expired');
      return { ok: false, code: 'unknown_share' };
    }
    if (typeof msg.packet !== 'string' || msg.packet.length === 0 || msg.packet.length > MAX_PACKET_LENGTH || !BASE64URL.test(msg.packet)) return { ok: false, code: 'bad_request' };
    if (now - s.lastPosAt < this.deps.minIntervalMs) return { ok: false, code: 'rate_limited' };
    s.posZeiten = s.posZeiten.filter((t) => now - t < 60_000);
    if (s.posZeiten.length >= this.deps.maxPerMinute) return { ok: false, code: 'rate_limited' };
    s.posZeiten.push(now);
    s.lastPosAt = now;
    s.lastPacket = msg.packet;
    this.deps.hub.sendToUsers(s.familyId, [...s.recipients.keys()], { type: 'loc_pos', from: s.ownerId, shareId: s.id, packet: msg.packet });
    return { ok: true };
  }

  stop(p: Principal, msg: { shareId?: unknown }): LocationResult {
    const s = this.own(p, msg.shareId);
    if (!s) return { ok: false, code: 'unknown_share' };
    this.end(s, 'stopped');
    return { ok: true };
  }

  extend(p: Principal, socket: WebSocket, msg: { shareId?: unknown; endsAt?: unknown }): LocationResult {
    const s = this.own(p, msg.shareId);
    if (!s) return { ok: false, code: 'unknown_share' };
    if (this.now() >= s.endsAt) {
      this.end(s, 'expired');
      return { ok: false, code: 'unknown_share' };
    }
    const endsAt = this.checkEndsAt(msg.endsAt, this.now());
    if (endsAt === null) return { ok: false, code: 'bad_duration' };
    s.endsAt = endsAt;
    sendTo(socket, { type: 'loc_active', shareId: s.id, endsAt });
    // auch die Empfänger erfahren das neue Ende (sonst ließen sie den Eintrag lokal zum alten Ende ablaufen)
    this.deps.hub.sendToUsers(s.familyId, [...s.recipients.keys()], { type: 'loc_extend', from: s.ownerId, shareId: s.id, endsAt });
    return { ok: true };
  }

  /** Neue angemeldete Verbindung: Empfänger bekommen laufende Freigaben nachgereicht, der Sender (dasselbe Gerät) übernimmt die Freigabe wieder. */
  onConnect(p: Principal, socket: WebSocket): void {
    for (const s of this.shares.values()) {
      if (s.familyId !== p.familyId) continue;
      const wrap = s.recipients.get(p.userId);
      if (wrap !== undefined) {
        sendTo(socket, { type: 'loc_start', from: s.ownerId, shareId: s.id, endsAt: s.endsAt, wrap });
        if (s.lastPacket) sendTo(socket, { type: 'loc_pos', from: s.ownerId, shareId: s.id, packet: s.lastPacket });
      }
      if (s.ownerId === p.userId && s.ownerKey === ownerKeyOf(p)) {
        s.senderSockets.add(socket);
        s.graceUntil = null;
        sendTo(socket, { type: 'loc_active', shareId: s.id, endsAt: s.endsAt });
      }
    }
  }

  /** Verbindung geschlossen: war es die letzte des Senders, läuft die Schonfrist; danach endet die Freigabe. */
  onClose(socket: WebSocket): void {
    for (const s of this.shares.values()) {
      if (!s.senderSockets.delete(socket)) continue;
      if (s.senderSockets.size === 0) s.graceUntil = this.now() + this.deps.graceMs;
    }
  }

  /** Beendet die Freigabe und sagt es Empfängern und den Sockets des Senders. */
  private end(s: Share, reason: EndReason): void {
    if (this.shares.get(s.id) !== s) return;
    this.shares.delete(s.id);
    const idx = this.ownerIndex(s.familyId, s.ownerId);
    if (this.byOwner.get(idx) === s) this.byOwner.delete(idx);
    const msg: ServerMessage = { type: 'loc_stop', from: s.ownerId, shareId: s.id, reason };
    this.deps.hub.sendToUsers(s.familyId, [...s.recipients.keys()], msg);
    for (const sock of s.senderSockets) sendTo(sock, msg);
    s.recipients.clear();
    s.lastPacket = null;
  }

  /** Widerruf (Abmelden, Gerät entfernen, Mitglied entfernen, Rollenwechsel): beendet die betroffenen Freigaben sofort, nicht erst nach der Schonfrist. */
  revoke(e: { kind: 'user'; userId: string; exceptSessionId?: string | undefined } | { kind: 'device'; deviceId: string } | { kind: 'session'; sessionId: string }): void {
    for (const s of [...this.shares.values()]) {
      const hit =
        e.kind === 'user' ? s.ownerId === e.userId && (e.exceptSessionId === undefined || s.ownerSessionId !== e.exceptSessionId) : e.kind === 'device' ? s.ownerKey === e.deviceId : s.ownerSessionId === e.sessionId;
      if (hit) this.end(s, 'removed');
    }
  }

  /** Periodische Prüfung: Ablauf, Schonfrist des Senders und (alle `recheckMs`) die Mitgliedschaft von Sender und Empfängern. */
  async sweep(opts: { recheckMs?: number } = {}): Promise<void> {
    // nicht überlappen: ein langsamer Datenbankzugriff darf keine zweite Prüfung auslösen
    if (this.sweeping) return;
    this.sweeping = true;
    try {
      await this.sweepInnen(opts);
    } finally {
      this.sweeping = false;
    }
  }

  private sweeping = false;

  private async sweepInnen(opts: { recheckMs?: number }): Promise<void> {
    const recheckMs = opts.recheckMs ?? this.deps.sweepMs * 12;
    const now = this.now();
    for (const [id, zeiten] of this.starts) if (zeiten.every((t) => now - t >= START_WINDOW_MS)) this.starts.delete(id);
    for (const [key, t] of this.lastWake) if (now - t >= WAKE_COOLDOWN_MS) this.lastWake.delete(key);
    const toCheck: Share[] = [];
    for (const s of [...this.shares.values()]) {
      if (now >= s.endsAt) this.end(s, 'expired');
      else if (s.graceUntil !== null && now >= s.graceUntil) this.end(s, 'disconnected');
      else if (now - s.lastRecheckAt >= recheckMs) toCheck.push(s);
    }
    const families = new Map<string, Awaited<ReturnType<MemberDirectory>>>();
    for (const s of toCheck) {
      if (!families.has(s.familyId)) families.set(s.familyId, await this.deps.directory(s.familyId));
      const members = families.get(s.familyId) as Awaited<ReturnType<MemberDirectory>>;
      if (this.shares.get(s.id) !== s) continue;
      s.lastRecheckAt = now;
      if (!members.some((m) => m.userId === s.ownerId)) {
        this.end(s, 'removed');
        continue;
      }
      // entfernte Empfänger bekommen nichts mehr (auch keine Nachreichung bei erneutem Beitritt)
      const { allowed } = locationRecipients({ userId: s.ownerId, role: 'child' }, members, [...s.recipients.keys()]);
      for (const id of [...s.recipients.keys()]) if (!allowed.includes(id)) s.recipients.delete(id);
      if (s.recipients.size === 0) this.end(s, 'removed');
    }
  }
}
