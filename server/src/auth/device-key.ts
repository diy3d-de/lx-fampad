// Das Gerät meldet seinen Schlüsselstand (`PUT /me/device-key`): "dieses Gerät hat Schlüsselversion n" oder "keinen Schlüssel" (0). Nur diese eine öffentliche
// Zahl, nie Schlüsselmaterial. Sie stützt die Schlüssel-Ampel der Betreiber-Ansicht (operator/key-status.ts), ist aber vom Gerät selbst gemeldet und kein Beweis.
// Das Gerät ist immer das der Sitzung (nie ein fremdes).
import { and, eq, isNull } from 'drizzle-orm';
import { devices } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { AuthContext } from './context.js';
import type { SessionPrincipal } from './types.js';

/** Obergrenze der gemeldeten Version (Schutz vor Unsinn; echte Versionen zählen einzeln hoch). */
export const MAX_REPORTED_KEY_VERSION = 1_000_000;

export async function reportDeviceKey(ctx: AuthContext, p: SessionPrincipal, keyVersion: number): Promise<void> {
  if (!p.deviceId) throw new AppError(409, 'no_device', 'Für diese Sitzung gibt es kein Gerät.');
  const rows = await ctx.db
    .update(devices)
    .set({ keyVersion, keyReportedAt: ctx.now() })
    .where(and(eq(devices.id, p.deviceId), eq(devices.userId, p.userId), eq(devices.familyId, p.familyId), isNull(devices.revokedAt)))
    .returning({ id: devices.id });
  if (rows.length === 0) throw new AppError(404, 'not_found');
}
