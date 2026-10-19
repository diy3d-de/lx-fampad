import type { WebSocket } from 'ws';
import type { Role } from '../auth/types.js';

/** Server -> Client. Der WebSocket meldet nur "neue Revision N"; Daten holt der Client per /api/v1/sync. */
export type ServerMessage =
  | { type: 'hello'; protocolVersion: number; serverVersion: string }
  | { type: 'ready' }
  | { type: 'pong' }
  | { type: 'rev'; rev: number }
  | { type: 'error'; code: string };

/** Wer hinter einer Verbindung steckt (für gezieltes Schließen bei Abmeldung, Widerruf, Rollenwechsel). */
export interface Subject {
  userId: string;
  sessionId?: string | undefined;
  deviceId?: string | null | undefined;
  role?: Role | undefined;
}

interface Entry extends Subject {
  familyId: string;
  socket: WebSocket;
  /** Zeitpunkt der letzten Lebenszeichen (Anmeldung, Nachricht, Pong): eine tote Verbindung gilt für Push bald nicht mehr als offen. */
  lastActivity: number;
}

function addTo<K>(map: Map<K, Set<Entry>>, key: K, entry: Entry): void {
  let set = map.get(key);
  if (!set) map.set(key, (set = new Set()));
  set.add(entry);
}

function removeFrom<K>(map: Map<K, Set<Entry>>, key: K, entry: Entry): void {
  const set = map.get(key);
  if (!set) return;
  set.delete(entry);
  if (set.size === 0) map.delete(key);
}

/** Verwaltet die offenen Verbindungen je Familie, Person, Sitzung und Gerät. */
export class Hub {
  private readonly byFamily = new Map<string, Set<Entry>>();
  private readonly byUser = new Map<string, Set<Entry>>();
  private readonly bySession = new Map<string, Set<Entry>>();
  private readonly byDevice = new Map<string, Set<Entry>>();
  private readonly entries = new Map<WebSocket, Entry>();

  add(familyId: string, socket: WebSocket, subject: Subject): void {
    const entry: Entry = { ...subject, familyId, socket, lastActivity: Date.now() };
    this.entries.set(socket, entry);
    addTo(this.byFamily, familyId, entry);
    addTo(this.byUser, subject.userId, entry);
    if (subject.sessionId) addTo(this.bySession, subject.sessionId, entry);
    if (subject.deviceId) addTo(this.byDevice, subject.deviceId, entry);
    socket.once('close', () => this.remove(socket));
  }

  remove(socket: WebSocket): void {
    const entry = this.entries.get(socket);
    if (!entry) return;
    this.entries.delete(socket);
    removeFrom(this.byFamily, entry.familyId, entry);
    removeFrom(this.byUser, entry.userId, entry);
    if (entry.sessionId) removeFrom(this.bySession, entry.sessionId, entry);
    if (entry.deviceId) removeFrom(this.byDevice, entry.deviceId, entry);
  }

  private closeAll(set: Set<Entry> | undefined, code: number, reason: string, skip?: (e: Entry) => boolean): number {
    let n = 0;
    // Kopie: close() kann 'close'-Ereignisse auslösen, die das Set verändern
    for (const e of [...(set ?? [])]) {
      if (skip?.(e)) continue;
      e.socket.close(code, reason);
      n++;
    }
    return n;
  }

  /** Schließt alle Verbindungen einer Sitzung. */
  closeSession(sessionId: string, code: number, reason: string): number {
    return this.closeAll(this.bySession.get(sessionId), code, reason);
  }

  /** Schließt alle Verbindungen eines Geräts. */
  closeDevice(deviceId: string, code: number, reason: string): number {
    return this.closeAll(this.byDevice.get(deviceId), code, reason);
  }

  /** Schließt alle Verbindungen einer Person, optional ohne die einer Sitzung. */
  closeUser(userId: string, code: number, reason: string, exceptSessionId?: string): number {
    return this.closeAll(this.byUser.get(userId), code, reason, exceptSessionId ? (e) => e.sessionId === exceptSessionId : undefined);
  }

  /** Hat das Gerät gerade eine offene (angemeldete) WebSocket-Verbindung? Dann braucht es keinen Push. */
  hasDevice(deviceId: string, maxIdleMs?: number): boolean {
    const now = Date.now();
    for (const e of this.byDevice.get(deviceId) ?? []) if (maxIdleMs === undefined || now - e.lastActivity <= maxIdleMs) return true;
    return false;
  }

  /** Merkt ein Lebenszeichen der Verbindung (Pong, Nachricht). */
  touch(socket: WebSocket): void {
    const e = this.entries.get(socket);
    if (e) e.lastActivity = Date.now();
  }

  /** Aktualisiert die gemerkte Rolle einer Verbindung. */
  setRole(socket: WebSocket, role: Role): void {
    const e = this.entries.get(socket);
    if (e) e.role = role;
  }

  /** Meldet den Geräten der Familie die neue Revision; mit `roles` nur denen, deren Rolle die Änderung sehen darf (unbekannte Rolle: im Zweifel ja). */
  notifyRev(familyId: string, rev: number, roles?: readonly Role[]): void {
    const msg = JSON.stringify({ type: 'rev', rev } satisfies ServerMessage);
    for (const e of this.byFamily.get(familyId) ?? []) {
      if (roles && e.role && !roles.includes(e.role)) continue;
      if (e.socket.readyState === e.socket.OPEN) e.socket.send(msg);
    }
  }

  /** Für Tests und Diagnose: wer ist verbunden (ohne Sockets). */
  snapshot(): Array<Subject & { familyId: string }> {
    return [...this.entries.values()].map(({ socket: _socket, ...rest }) => rest);
  }

  get size(): number {
    return this.entries.size;
  }
}
