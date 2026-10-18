import websocket from '@fastify/websocket';
import Fastify, { type FastifyInstance } from 'fastify';
import type { Config } from './config.js';
import { registerPlaceholderRoutes } from './routes/placeholders.js';
import { registerSystemRoutes } from './routes/system.js';
import { registerWebSocketRoute } from './ws/route.js';

export interface AppDeps {
  config: Config;
  pingDb?: () => Promise<void>;
}

export async function buildApp({ config, pingDb }: AppDeps): Promise<FastifyInstance> {
  const app = Fastify({
    logger: config.logLevel === 'silent' ? false : { level: config.logLevel },
    // hinter Caddy: echte Client-IP aus X-Forwarded-For
    trustProxy: '127.0.0.1',
    bodyLimit: 1024 * 1024,
  });

  await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

  registerSystemRoutes(app, { config, pingDb });
  registerPlaceholderRoutes(app);
  registerWebSocketRoute(app, config);

  return app;
}
