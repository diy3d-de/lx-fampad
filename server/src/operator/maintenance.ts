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

  constructor(private readonly deps: { db: Db; now: () => Date; log: Logger }) {}

  /** Der Zustand ist nicht mehr aktuell (der Betreiber hat geschaltet): beim nächsten Zugriff neu lesen. */
  invalidate(): void {
    this.readAt = 0;
  }

  private async load(): Promise<void> {
    try {
      this.rows = await this.deps.db
        .select({ until: operatorSettings.maintenanceUntil })
        .from(operatorSettings)
        .where(eq(operatorSettings.maintenanceActive, true));
      this.warned = false;
    } catch (err) {
      // behält den zuletzt bekannten Stand; ohne Datenbank scheitern die Anfragen ohnehin an anderer Stelle
      if (!this.warned) this.deps.log.warn({ err }, 'Wartungsmodus nicht lesbar, der letzte Stand gilt');
      this.warned = true;
    }
    this.readAt = Date.now();
  }

  /** Ist der Wartungsmodus an (und nicht durch "until" abgelaufen)? Mehrere gleichzeitige Aufrufe teilen sich eine Abfrage. */
  async current(): Promise<MaintenanceState | null> {
    if (Date.now() - this.readAt >= CACHE_MS) {
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
    if (await this.current()) throw maintenanceError();
  }
}

export function maintenanceError(): AppError {
  return new AppError(503, 'maintenance', MAINTENANCE_MESSAGE, { 'retry-after': '60' }, { maintenance: true });
}
