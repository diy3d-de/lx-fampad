// Das Gerät meldet beim Start seine App-Version (`PUT /me/device-info`): ein Versionsstring `x.y.z` (die Route prüft ihn streng), sonst nichts. Sie stützt den Update-Stand
// der Betreiber-Ansicht (operator/update-status.ts), ist aber vom Gerät selbst gemeldet und kein Beweis. Die Version steht auch beim Anmelden im Gerät; diese Meldung hält sie
// nach einem App-Update aktuell, ohne dass die Person sich neu anmelden muss. Das Gerät ist immer das der Sitzung (nie ein fremdes).
import { and, eq, isNull } from 'drizzle-orm';
import { devices } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { AuthContext } from './context.js';
import type { SessionPrincipal } from './types.js';

export async function reportDeviceApp(ctx: AuthContext, p: SessionPrincipal, appVersion: string): Promise<void> {
  if (!p.deviceId) throw new AppError(409, 'no_device', 'Für diese Sitzung gibt es kein Gerät.');
  const rows = await ctx.db
    .update(devices)
    .set({ appVersion })
    .where(and(eq(devices.id, p.deviceId), eq(devices.userId, p.userId), eq(devices.familyId, p.familyId), isNull(devices.revokedAt)))
    .returning({ id: devices.id });
  if (rows.length === 0) throw new AppError(404, 'not_found');
}
