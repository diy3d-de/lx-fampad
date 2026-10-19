import type { FastifyInstance } from 'fastify';

/** Noch ohne Fachlogik (501): der Sync kommt in Phase 1c. Anmeldung und Ticket-Ausgabe stehen in routes/auth.ts bzw. routes/account.ts. */
export function registerPlaceholderRoutes(app: FastifyInstance): void {
  app.post('/api/v1/sync', async (_req, reply) => reply.code(501).send({ error: 'not_implemented', message: 'Kommt in Phase 1c' }));
}
