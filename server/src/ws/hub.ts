import type { WebSocket } from 'ws';

/** Server -> Client. Der WebSocket meldet nur "neue Revision N"; Daten holt der Client per /api/v1/sync. */
export type ServerMessage =
  | { type: 'hello'; protocolVersion: number; serverVersion: string }
  | { type: 'ready' }
  | { type: 'pong' }
  | { type: 'rev'; rev: number }
  | { type: 'error'; code: string };

/** Verwaltet die offenen Verbindungen je Familie (Phase 0: nur Gerüst, noch ohne Anmeldung genutzt). */
export class Hub {
  private readonly byFamily = new Map<string, Set<WebSocket>>();

  add(familyId: string, socket: WebSocket): void {
    let set = this.byFamily.get(familyId);
    if (!set) this.byFamily.set(familyId, (set = new Set()));
    set.add(socket);
    socket.once('close', () => this.remove(familyId, socket));
  }

  remove(familyId: string, socket: WebSocket): void {
    const set = this.byFamily.get(familyId);
    if (!set) return;
    set.delete(socket);
    if (set.size === 0) this.byFamily.delete(familyId);
  }

  /** Meldet allen Geräten der Familie die neue Revision. */
  notifyRev(familyId: string, rev: number): void {
    const msg = JSON.stringify({ type: 'rev', rev } satisfies ServerMessage);
    for (const s of this.byFamily.get(familyId) ?? []) {
      if (s.readyState === s.OPEN) s.send(msg);
    }
  }

  get size(): number {
    let n = 0;
    for (const set of this.byFamily.values()) n += set.size;
    return n;
  }
}
