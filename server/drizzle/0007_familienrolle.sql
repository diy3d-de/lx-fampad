ALTER TABLE "memberships" ADD COLUMN "family_role" text;--> statement-breakpoint
ALTER TABLE "memberships" ADD CONSTRAINT "memberships_family_role_ck" CHECK ("memberships"."family_role" is null or "memberships"."family_role" in ('vater', 'mutter', 'elternteil', 'kind', 'grosseltern', 'sonstige'));
