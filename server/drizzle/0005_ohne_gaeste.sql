-- Gäste entfallen: Daten bereinigen, bevor die Aufzählungstypen ohne "guest" und ohne Freigabestufe "all" neu angelegt werden.
-- Wie die Anwendung (account.ts removeFromFamily, sync/refs.ts): Verweise der Gäste lösen und Termin-Teilnahmen löschen, jeweils mit neuer
-- Revision und Änderungseintrag, damit die Geräte es beim nächsten Abgleich sehen; Freigabe "all" wird "family" (ebenfalls mit Änderungseintrag).
DO $$
DECLARE
  f record;
  g record;
  r record;
  cur bigint;
BEGIN
  -- offene Einladungen für Gäste oder von/für Gäste enden
  UPDATE invites SET revoked_at = now()
   WHERE used_at IS NULL AND revoked_at IS NULL
     AND (role = 'guest'
          OR created_by IN (SELECT user_id FROM memberships WHERE role = 'guest')
          OR user_id IN (SELECT user_id FROM memberships WHERE role = 'guest'));

  FOR f IN SELECT id, current_rev FROM families FOR UPDATE LOOP
    cur := f.current_rev;

    -- Freigabe "all" (auch Gäste) -> "family"
    FOR r IN SELECT id FROM lists WHERE family_id = f.id AND audience = 'all' AND deleted_at IS NULL LOOP
      cur := cur + 1;
      UPDATE lists SET audience = 'family', rev = cur, field_revs = field_revs || jsonb_build_object('audience', cur), updated_at = now() WHERE id = r.id;
      INSERT INTO change_log (family_id, rev, entity, entity_id, tombstone, created, changes) VALUES (f.id, cur, 'list', r.id, false, false, '{"audience":"family"}'::jsonb);
    END LOOP;
    FOR r IN SELECT id FROM termine WHERE family_id = f.id AND audience = 'all' AND deleted_at IS NULL LOOP
      cur := cur + 1;
      UPDATE termine SET audience = 'family', rev = cur, field_revs = field_revs || jsonb_build_object('audience', cur), updated_at = now() WHERE id = r.id;
      INSERT INTO change_log (family_id, rev, entity, entity_id, tombstone, created, changes) VALUES (f.id, cur, 'termin', r.id, false, false, '{"audience":"family"}'::jsonb);
    END LOOP;

    -- Gäste entfernen
    FOR g IN SELECT user_id FROM memberships WHERE family_id = f.id AND role = 'guest' LOOP
      FOR r IN SELECT id FROM lists WHERE family_id = f.id AND owner_id = g.user_id AND deleted_at IS NULL LOOP
        cur := cur + 1;
        UPDATE lists SET owner_id = NULL, rev = cur, field_revs = field_revs || jsonb_build_object('ownerId', cur), updated_at = now() WHERE id = r.id;
        INSERT INTO change_log (family_id, rev, entity, entity_id, tombstone, created, changes) VALUES (f.id, cur, 'list', r.id, false, false, '{"ownerId":null}'::jsonb);
      END LOOP;
      FOR r IN SELECT id FROM termine WHERE family_id = f.id AND owner_id = g.user_id AND deleted_at IS NULL LOOP
        cur := cur + 1;
        UPDATE termine SET owner_id = NULL, rev = cur, field_revs = field_revs || jsonb_build_object('ownerId', cur), updated_at = now() WHERE id = r.id;
        INSERT INTO change_log (family_id, rev, entity, entity_id, tombstone, created, changes) VALUES (f.id, cur, 'termin', r.id, false, false, '{"ownerId":null}'::jsonb);
      END LOOP;
      FOR r IN SELECT id FROM list_items WHERE family_id = f.id AND assignee_id = g.user_id AND deleted_at IS NULL LOOP
        cur := cur + 1;
        UPDATE list_items SET assignee_id = NULL, rev = cur, field_revs = field_revs || jsonb_build_object('assigneeId', cur), updated_at = now() WHERE id = r.id;
        INSERT INTO change_log (family_id, rev, entity, entity_id, tombstone, created, changes) VALUES (f.id, cur, 'list_item', r.id, false, false, '{"assigneeId":null}'::jsonb);
      END LOOP;
      FOR r IN SELECT id FROM termin_teilnehmer WHERE family_id = f.id AND user_id = g.user_id AND deleted_at IS NULL LOOP
        cur := cur + 1;
        UPDATE termin_teilnehmer SET deleted_at = now(), rev = cur, field_revs = '{}'::jsonb, updated_at = now() WHERE id = r.id;
        UPDATE change_log SET changes = '{}'::jsonb WHERE family_id = f.id AND entity = 'termin_teilnehmer' AND entity_id = r.id;
        INSERT INTO change_log (family_id, rev, entity, entity_id, tombstone, created, changes) VALUES (f.id, cur, 'termin_teilnehmer', r.id, true, false, '{}'::jsonb);
      END LOOP;

      INSERT INTO audit_log (family_id, event, detail)
        VALUES (f.id, 'member_removed', jsonb_build_object('target', g.user_id, 'role', 'guest', 'reason', 'role_removed'));
      -- Mitgliedschaft löschen: Geräte, Sitzungen und Tickets der Familie folgen per Fremdschlüssel (Sitzungen sind damit widerrufen)
      DELETE FROM memberships WHERE family_id = f.id AND user_id = g.user_id;
      IF NOT EXISTS (SELECT 1 FROM memberships WHERE user_id = g.user_id) THEN
        DELETE FROM users WHERE id = g.user_id;
      END IF;
    END LOOP;

    IF cur <> f.current_rev THEN
      UPDATE families SET current_rev = cur WHERE id = f.id;
    END IF;
  END LOOP;

  -- gelöschte Datensätze (Tombstones) und Reste ohne Änderungseintrag
  UPDATE lists SET audience = 'family' WHERE audience = 'all';
  UPDATE termine SET audience = 'family' WHERE audience = 'all';
  -- erledigte/widerrufene Einladungen bleiben als Verlauf, die Rolle "guest" gibt es nicht mehr
  UPDATE invites SET role = 'child' WHERE role = 'guest';
END $$;--> statement-breakpoint
ALTER TABLE "lists" ALTER COLUMN "audience" SET DATA TYPE text;--> statement-breakpoint
ALTER TABLE "lists" ALTER COLUMN "audience" SET DEFAULT 'family'::text;--> statement-breakpoint
ALTER TABLE "termine" ALTER COLUMN "audience" SET DATA TYPE text;--> statement-breakpoint
ALTER TABLE "termine" ALTER COLUMN "audience" SET DEFAULT 'family'::text;--> statement-breakpoint
DROP TYPE "public"."list_audience";--> statement-breakpoint
CREATE TYPE "public"."list_audience" AS ENUM('parents', 'family');--> statement-breakpoint
ALTER TABLE "lists" ALTER COLUMN "audience" SET DEFAULT 'family'::"public"."list_audience";--> statement-breakpoint
ALTER TABLE "lists" ALTER COLUMN "audience" SET DATA TYPE "public"."list_audience" USING "audience"::"public"."list_audience";--> statement-breakpoint
ALTER TABLE "termine" ALTER COLUMN "audience" SET DEFAULT 'family'::"public"."list_audience";--> statement-breakpoint
ALTER TABLE "termine" ALTER COLUMN "audience" SET DATA TYPE "public"."list_audience" USING "audience"::"public"."list_audience";--> statement-breakpoint
ALTER TABLE "invites" ALTER COLUMN "role" SET DATA TYPE text;--> statement-breakpoint
ALTER TABLE "memberships" ALTER COLUMN "role" SET DATA TYPE text;--> statement-breakpoint
DROP TYPE "public"."member_role";--> statement-breakpoint
CREATE TYPE "public"."member_role" AS ENUM('admin', 'parent', 'child');--> statement-breakpoint
ALTER TABLE "invites" ALTER COLUMN "role" SET DATA TYPE "public"."member_role" USING "role"::"public"."member_role";--> statement-breakpoint
ALTER TABLE "memberships" ALTER COLUMN "role" SET DATA TYPE "public"."member_role" USING "role"::"public"."member_role";