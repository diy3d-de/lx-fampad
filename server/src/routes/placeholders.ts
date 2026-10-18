import type { FastifyInstance } from 'fastify';

/** Phase 0: Schnittstellen existieren, haben aber noch keine Fachlogik (501). Umsetzung in Phase 1. */
export function registerPlaceholderRoutes(app: FastifyInstance): void {
  const handler = async (_req: unknown, reply: { code(n: number): { send(b: unknown): unknown } }) =>
    reply.code(501).send({ error: 'not_implemented', message: 'Kommt in Phase 1' });

  app.post('/api/v1/sync', handler);
  app.post('/api/v1/auth/login', handler);
  app.post('/api/v1/auth/logout', handler);
  app.post('/api/v1/ws-ticket', handler);
}
