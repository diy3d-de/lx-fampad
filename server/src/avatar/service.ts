// Benutzerbild: Platzhalter (preset) oder Foto. Die Metadaten stehen an users, die Foto-Bytes in user_avatars.
// Nichts davon landet im Log.
import { and, eq, inArray, isNull, sql } from 'drizzle-orm';
import type { AuthContext } from '../auth/context.js';
import type { SessionPrincipal } from '../auth/types.js';
import { memberships, userAvatars, users } from '../db/schema.js';
import { AppError } from '../errors.js';
import type { AvatarPreset, ImageInfo } from './image.js';

/** Metadaten für /me und /members; `version` zählt jede Änderung (Cache-Schlüssel der Apps). */
export type AvatarMeta = { kind: 'preset'; id: string; version: number } | { kind: 'photo'; version: number } | null;

const notFound = () => new AppError(404, 'not_found');

export function metaOf(row: { avatarKind: string | null; avatarPreset: string | null; avatarVersion: number }): AvatarMeta {
  if (row.avatarKind === 'photo') return { kind: 'photo', version: row.avatarVersion };
  if (row.avatarKind === 'preset' && row.avatarPreset) return { kind: 'preset', id: row.avatarPreset, version: row.avatarVersion };
  return null;
}

/** Metadaten mehrerer Personen (eine Abfrage). */
export async function avatarMetaFor(ctx: AuthContext, userIds: string[]): Promise<Map<string, AvatarMeta>> {
  const out = new Map<string, AvatarMeta>();
  if (userIds.length === 0) return out;
  const rows = await ctx.db
    .select({ id: users.id, avatarKind: users.avatarKind, avatarPreset: users.avatarPreset, avatarVersion: users.avatarVersion })
    .from(users)
    .where(inArray(users.id, userIds));
  for (const r of rows) out.set(r.id, metaOf(r));
  return out;
}

export async function setPreset(ctx: AuthContext, userId: string, preset: AvatarPreset): Promise<AvatarMeta> {
  await ctx.db.transaction(async (tx) => {
    await tx.delete(userAvatars).where(eq(userAvatars.userId, userId));
    await tx
      .update(users)
      .set({ avatarKind: 'preset', avatarPreset: preset, avatarVersion: sql`${users.avatarVersion} + 1` })
      .where(eq(users.id, userId));
  });
  return (await avatarMetaFor(ctx, [userId])).get(userId) ?? null;
}

export async function setPhoto(ctx: AuthContext, userId: string, data: Buffer, info: ImageInfo): Promise<AvatarMeta> {
  const now = ctx.now();
  await ctx.db.transaction(async (tx) => {
    await tx
      .insert(userAvatars)
      .values({ userId, contentType: info.mime, width: info.width, height: info.height, data, updatedAt: now })
      .onConflictDoUpdate({ target: userAvatars.userId, set: { contentType: info.mime, width: info.width, height: info.height, data, updatedAt: now } });
    await tx
      .update(users)
      .set({ avatarKind: 'photo', avatarPreset: null, avatarVersion: sql`${users.avatarVersion} + 1` })
      .where(eq(users.id, userId));
  });
  return (await avatarMetaFor(ctx, [userId])).get(userId) ?? null;
}

/** Entfernt das Bild (Initialen); die Version zählt trotzdem hoch, damit Caches es verwerfen. */
export async function clearAvatar(ctx: AuthContext, userId: string): Promise<void> {
  await ctx.db.transaction(async (tx) => {
    await tx.delete(userAvatars).where(eq(userAvatars.userId, userId));
    await tx
      .update(users)
      .set({ avatarKind: null, avatarPreset: null, avatarVersion: sql`${users.avatarVersion} + 1` })
      .where(eq(users.id, userId));
  });
}

/** Ist die Person Mitglied der Familie der Sitzung? Nur Admins sehen auch wartende Mitglieder. Fremde Familie = 404. */
export async function assertMemberOfFamily(ctx: AuthContext, p: SessionPrincipal, targetId: string): Promise<void> {
  const [row] = await ctx.db
    .select({ id: memberships.id })
    .from(memberships)
    .innerJoin(users, eq(users.id, memberships.userId))
    .where(
      and(
        eq(memberships.familyId, p.familyId),
        eq(memberships.userId, targetId),
        isNull(users.disabledAt),
        p.role === 'admin' ? undefined : eq(memberships.status, 'active'),
      ),
    )
    .limit(1);
  if (!row) throw notFound();
}

/** Version des Fotos (ohne die Bytes zu laden) für die ETag-Prüfung; null = die Person hat kein Foto. */
export async function photoVersion(ctx: AuthContext, userId: string): Promise<number | null> {
  const [r] = await ctx.db.select({ kind: users.avatarKind, version: users.avatarVersion }).from(users).where(eq(users.id, userId)).limit(1);
  return r && r.kind === 'photo' ? r.version : null;
}

export interface PhotoRow {
  version: number;
  contentType: string;
  data: Buffer;
}

export async function loadPhoto(ctx: AuthContext, userId: string): Promise<PhotoRow | null> {
  const [r] = await ctx.db
    .select({ version: users.avatarVersion, contentType: userAvatars.contentType, data: userAvatars.data })
    .from(userAvatars)
    .innerJoin(users, eq(users.id, userAvatars.userId))
    .where(and(eq(userAvatars.userId, userId), eq(users.avatarKind, 'photo')))
    .limit(1);
  return r ?? null;
}
