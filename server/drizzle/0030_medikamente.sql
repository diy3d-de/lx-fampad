ALTER TYPE "public"."konversation_art" ADD VALUE IF NOT EXISTS 'meds';--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "einnahmen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"medikament_id" uuid NOT NULL,
	"inhalt" text NOT NULL,
	"bearbeiter_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "einnahmen_inhalt_len_ck" CHECK (char_length("einnahmen"."inhalt") <= 2048)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "medikamente" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"inhalt" text NOT NULL,
	"bearbeiter_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "medikamente_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "medikamente_inhalt_len_ck" CHECK (char_length("medikamente"."inhalt") <= 16384)
);
--> statement-breakpoint
ALTER TABLE "konversationen" ADD COLUMN IF NOT EXISTS "subjekt_id" uuid;--> statement-breakpoint
ALTER TABLE "einnahmen" DROP CONSTRAINT IF EXISTS "einnahmen_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "einnahmen" ADD CONSTRAINT "einnahmen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "einnahmen" DROP CONSTRAINT IF EXISTS "einnahmen_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "einnahmen" ADD CONSTRAINT "einnahmen_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "einnahmen" DROP CONSTRAINT IF EXISTS "einnahmen_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "einnahmen" ADD CONSTRAINT "einnahmen_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "einnahmen" DROP CONSTRAINT IF EXISTS "einnahmen_family_id_medikament_id_medikamente_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "einnahmen" ADD CONSTRAINT "einnahmen_family_id_medikament_id_medikamente_family_id_id_fk" FOREIGN KEY ("family_id","medikament_id") REFERENCES "public"."medikamente"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medikamente" DROP CONSTRAINT IF EXISTS "medikamente_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "medikamente" ADD CONSTRAINT "medikamente_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medikamente" DROP CONSTRAINT IF EXISTS "medikamente_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "medikamente" ADD CONSTRAINT "medikamente_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "medikamente" DROP CONSTRAINT IF EXISTS "medikamente_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "medikamente" ADD CONSTRAINT "medikamente_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "einnahmen_medikament_idx" ON "einnahmen" USING btree ("family_id","medikament_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "einnahmen_konversation_idx" ON "einnahmen" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "einnahmen_family_rev_idx" ON "einnahmen" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "einnahmen_created_idx" ON "einnahmen" USING btree ("family_id","created_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "einnahmen_tombstone_idx" ON "einnahmen" USING btree ("family_id","rev") WHERE "einnahmen"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "einnahmen_bearbeiter_idx" ON "einnahmen" USING btree ("family_id","bearbeiter_id","created_at") WHERE "einnahmen"."bearbeiter_id" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "medikamente_konversation_idx" ON "medikamente" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "medikamente_family_rev_idx" ON "medikamente" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "medikamente_tombstone_idx" ON "medikamente" USING btree ("family_id","rev") WHERE "medikamente"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "medikamente_bearbeiter_idx" ON "medikamente" USING btree ("family_id","bearbeiter_id","created_at") WHERE "medikamente"."bearbeiter_id" is not null;--> statement-breakpoint
ALTER TABLE "konversationen" DROP CONSTRAINT IF EXISTS "konversationen_family_id_subjekt_id_memberships_family_id_user_id_fk";--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_family_id_subjekt_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","subjekt_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "konversationen_subjekt_idx" ON "konversationen" USING btree ("family_id","subjekt_id") WHERE "konversationen"."subjekt_id" is not null;--> statement-breakpoint
ALTER TABLE "konversationen" DROP CONSTRAINT IF EXISTS "konversationen_subjekt_ck";--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_subjekt_ck" CHECK (("konversationen"."art"::text = 'meds') = ("konversationen"."subjekt_id" is not null));--> statement-breakpoint
ALTER TABLE "konversationen" DROP CONSTRAINT IF EXISTS "konversationen_teilnehmer_ck";--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_teilnehmer_ck" CHECK (("konversationen"."art" = 'family' and cardinality("konversationen"."teilnehmer") = 0)
        or ("konversationen"."art" = 'direct' and cardinality("konversationen"."teilnehmer") = 2)
        or ("konversationen"."art" = 'group' and cardinality("konversationen"."teilnehmer") between 2 and 20)
        or ("konversationen"."art"::text = 'meds' and cardinality("konversationen"."teilnehmer") between 1 and 20));