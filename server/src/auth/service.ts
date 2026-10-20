// Zusammenbau der Anmeldung: Kontext (Datenbank, Schlüssel, Uhr) und die Schnittstelle AuthService für den WebSocket.
import type { FastifyRequest } from 'fastify';
import type { Config } from '../config.js';
import { AppError } from '../errors.js';
import { recheckSession, redeemWsTicket } from './account.js';
import { writeAudit } from './audit.js';
import type { AuthContext, Db, Logger } from './context.js';
import { KeyRing } from './crypto.js';
import { ipKey, lockedForSeconds, recordLoginFailure } from './lockout.js';
import { authenticateRequest } from './sessions.js';
import type { AuthService, Principal, SessionPrincipal } from './types.js';

export class Auth implements AuthService {
  readonly ctx: AuthContext;

  constructor(deps: { db: Db; config: Config; log?: Logger; now?: () => Date }) {
    this.ctx = {
      db: deps.db,
      config: deps.config,
      keys: new KeyRing(deps.config.auth.secretKey),
      now: deps.now ?? (() => new Date()),
      log: deps.log ?? { warn: () => {}, error: () => {} },
      onRevoke: () => {},
      onRev: () => {},
      onMembersChanged: () => {},
    };
  }

  authenticate(request: FastifyRequest): Promise<SessionPrincipal | null> {
    return authenticateRequest(this.ctx, request);
  }

  /** Wie authenticate, wirft aber 401, wenn niemand angemeldet ist. */
  async requireSession(request: FastifyRequest): Promise<SessionPrincipal> {
    const p = await this.authenticate(request);
    if (!p) throw new AppError(401, 'unauthenticated', 'Nicht angemeldet.');
    return p;
  }

  redeemWsTicket(ticket: string): Promise<Principal | null> {
    return redeemWsTicket(this.ctx, ticket);
  }

  recheck(principal: Principal): Promise<Principal | null> {
    return recheckSession(this.ctx, principal);
  }

  async isIpBlocked(ip: string): Promise<boolean> {
    return (await lockedForSeconds(this.ctx, [ipKey(this.ctx, ip)])) > 0;
  }

  async noteWsFailure(ip: string): Promise<void> {
    await recordLoginFailure(this.ctx, ip);
    await writeAudit(this.ctx, this.ctx.db, { event: 'ws_auth_failed', ip });
  }
}
