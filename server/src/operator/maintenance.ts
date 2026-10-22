// Wartungsmodus: Während er an ist, nehmen Schreib-Anfragen, der Sync und neue Anmeldungen eine feste, deutsche Antwort ("maintenance", HTTP 503) statt eines
// Fehlers. Das Lesen (GET), bestehende Sitzungen (Refresh, Abmelden, Step-up, WebSocket-Ticket) und alle Betreiber-Routen (/api/v1/admin/*) bleiben erreichbar:
// So kann der Betreiber die Wartung selbst wieder ausschalten. Zusätzlich gilt der Notausgang auf dem Server (cli/operator.ts maintenance off) und ein optionales
// automatisches Ende ("until"). Fällt die Datenbank aus oder ist der Zustand nicht lesbar, gilt der zuletzt bekannte Stand (nie "gesperrt" ohne Grund).
import { eq } from 'drizzle-orm';
import type { FastifyRequest } from 'fastify';
import type { Db, Logger } from '../auth/context.js';
import { operatorSettings } from '../db/schema.js';
import { AppError } from '../errors.js';

/** Wie lange ein gelesener Stand gilt (Echtzeit, nicht die Uhr der Tests); das Schalten selbst leert den Zwischenspeicher sofort. */
const CACHE_MS = 2000;

/** Feste Meldung der Antwort (die App ordnet dem Code "maintenance" ihren eigenen Text zu). */
export const MAINTENANCE_MESSAGE = 'Die Familienzentrale ist gerade in Wartung. Bitte versuche es später noch einmal.';

/** Abfragen, die auch im Wartungsmodus durchgehen, obwohl sie ändern: bestehende Sitzungen erhalten und beenden, bestätigen (Step-up), WebSocket-Ticket. */
const EXEMPT_ROUTES = new Set([
  '/api/v1/auth/refresh',
  '/api/v1/auth/logout',
  '/api/v1/auth/logout-all',
  '/api/v1/auth/step-up/passkey/options',
  '/api/v1/auth/step-up/passkey/verify',
  '/api/v1/auth/step-up/code',
  '/api/v1/ws-ticket',
]);

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

/**
 * Sperrt der Wartungsmodus diese Anfrage (wenn er an ist)? Maßgeblich ist die aufgelöste Route (nicht der rohe Pfad): unbekannte Routen
 * ergeben 404 wie sonst, Lesen ist frei, Betreiber-Routen und die Ausnahmen oben auch.
 */
export function blockedDuringMaintenance(req: Pick<FastifyRequest, 'method' | 'routeOptions'>): boolean {
  if (SAFE_METHODS.has(req.method)) return false;
  const route = req.routeOptions?.url;
  if (!route || !route.startsWith('/api/')) return false;
  if (route.startsWith('/api/v1/admin/')) return false;
  return !EXEMPT_ROUTES.has(route);
}

export interface MaintenanceState {
  /** Automatisches Ende (null: bis der Betreiber ausschaltet). */
  until: Date | null;
}

export class MaintenanceGate {
  private rows: Array<{ until: Date | null }> = [];
  private readAt = 0;
  private loading: Promise<void> | null = null;
  private warned = false;
  /** Zählt die Schaltungen: ein Lesevorgang, der vor einem `invalidate()` begann, liefert evtl. den alten Stand und darf ihn nicht festschreiben. */
  private generation = 0;

  constructor(private readonly deps: { db: Db; now: () => Date; log: Logger }) {}

  /** Der Zustand ist nicht mehr aktuell (der Betreiber hat geschaltet): beim nächsten Zugriff neu lesen, auch wenn gerade ein Lesevorgang läuft. */
  invalidate(): void {
    this.generation++;
    this.readAt = 0;
  }

  private async load(): Promise<void> {
    const gen = this.generation;
    try {
      const rows = await this.deps.db
        .select({ until: operatorSettings.maintenanceUntil })
        .from(operatorSettings)
        .where(eq(operatorSettings.maintenanceActive, true));
      // zwischenzeitlich geschaltet: dieses Ergebnis kann veraltet sein, nicht übernehmen (readAt bleibt 0, der nächste Durchlauf liest neu)
      if (gen !== this.generation) return;
      this.rows = rows;
      this.warned = false;
    } catch (err) {
      // behält den zuletzt bekannten Stand; ohne Datenbank scheitern die Anfragen ohnehin an anderer Stelle
      if (!this.warned) this.deps.log.warn({ err }, 'Wartungsmodus nicht lesbar, der letzte Stand gilt');
      this.warned = true;
      if (gen !== this.generation) return;
    }
    this.readAt = Date.now();
  }

  /** Ist der Wartungsmodus an (und nicht durch "until" abgelaufen)? Mehrere gleichzeitige Aufrufe teilen sich eine Abfrage. */
  async current(): Promise<MaintenanceState | null> {
    // höchstens drei Durchläufe: wird währenddessen geschaltet, liest der nächste Durchlauf den neuen Stand
    for (let i = 0; i < 3 && (this.readAt === 0 || Date.now() - this.readAt >= CACHE_MS); i++) {
      this.loading ??= this.load().finally(() => {
        this.loading = null;
      });
      await this.loading;
    }
    const now = this.deps.now().getTime();
    const live = this.rows.filter((r) => r.until === null || r.until.getTime() > now);
    if (live.length === 0) return null;
    // mehrere Familien (nicht vorgesehen): gilt das späteste Ende, "bis auf Weiteres" geht vor
    return { until: live.some((r) => r.until === null) ? null : live.reduce((m, r) => (r.until!.getTime() > m.getTime() ? r.until! : m), live[0]!.until!) };
  }

  /** Wirft die feste Wartungs-Antwort, wenn die Anfrage gesperrt ist. */
  async check(req: Pick<FastifyRequest, 'method' | 'routeOptions'>): Promise<void> {
    if (!blockedDuringMaintenance(req)) return;
    const state = await this.current();
    if (state) throw maintenanceError(state.until, this.deps.now());
  }
}

/** `Retry-After`: höchstens 60 Sekunden, endet die Wartung früher, nur bis dahin (mindestens 1). */
export function retryAfterSeconds(until: Date | null, now: Date): number {
  if (until === null) return 60;
  return Math.min(60, Math.max(1, Math.ceil((until.getTime() - now.getTime()) / 1000)));
}

export function maintenanceError(until: Date | null = null, now: Date = new Date()): AppError {
  return new AppError(503, 'maintenance', MAINTENANCE_MESSAGE, { 'retry-after': String(retryAfterSeconds(until, now)) }, { maintenance: true });
}
