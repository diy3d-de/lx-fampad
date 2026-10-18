import type { FastifyInstance } from 'fastify';
import type { Config } from '../config.js';

/** Phase 0: Schnittstellen existieren, haben aber noch keine Fachlogik (501). Umsetzung in Phase 1. */
export function registerPlaceholderRoutes(app: FastifyInstance, config: Config): void {
  const handler = async (_req: unknown, reply: { code(n: number): { send(b: unknown): unknown } }) =>
    reply.code(501).send({ error: 'not_implemented', message: 'Kommt in Phase 1' });

  // Anmeldung und Ticket-Ausgabe: deutlich strenger begrenzt als der Rest (Brute Force, Ticket-Flut)
  const strikt = { config: { rateLimit: { max: config.authRateLimitMax, timeWindow: '1 minute' } } };

  app.post('/api/v1/sync', handler);
  app.post('/api/v1/auth/login', strikt, handler);
  app.post('/api/v1/auth/logout', strikt, handler);
  app.post('/api/v1/ws-ticket', strikt, handler);
}
