CREATE TABLE IF NOT EXISTS "vorsorge_eintraege" (
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
	CONSTRAINT "vorsorge_eintraege_inhalt_len_ck" CHECK (char_length("vorsorge_eintraege"."inhalt") <= 8192)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "vorsorge_profile" (
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
	CONSTRAINT "vorsorge_profile_inhalt_len_ck" CHECK (char_length("vorsorge_profile"."inhalt") <= 2048)
);
--> statement-breakpoint
ALTER TABLE "vorsorge_eintraege" DROP CONSTRAINT IF EXISTS "vorsorge_eintraege_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "vorsorge_eintraege" ADD CONSTRAINT "vorsorge_eintraege_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vorsorge_eintraege" DROP CONSTRAINT IF EXISTS "vorsorge_eintraege_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "vorsorge_eintraege" ADD CONSTRAINT "vorsorge_eintraege_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vorsorge_eintraege" DROP CONSTRAINT IF EXISTS "vorsorge_eintraege_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "vorsorge_eintraege" ADD CONSTRAINT "vorsorge_eintraege_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vorsorge_profile" DROP CONSTRAINT IF EXISTS "vorsorge_profile_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "vorsorge_profile" ADD CONSTRAINT "vorsorge_profile_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vorsorge_profile" DROP CONSTRAINT IF EXISTS "vorsorge_profile_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "vorsorge_profile" ADD CONSTRAINT "vorsorge_profile_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "vorsorge_profile" DROP CONSTRAINT IF EXISTS "vorsorge_profile_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "vorsorge_profile" ADD CONSTRAINT "vorsorge_profile_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_eintraege_konversation_idx" ON "vorsorge_eintraege" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_eintraege_family_rev_idx" ON "vorsorge_eintraege" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_eintraege_tombstone_idx" ON "vorsorge_eintraege" USING btree ("family_id","rev") WHERE "vorsorge_eintraege"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_eintraege_bearbeiter_idx" ON "vorsorge_eintraege" USING btree ("family_id","bearbeiter_id","created_at") WHERE "vorsorge_eintraege"."bearbeiter_id" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_profile_konversation_idx" ON "vorsorge_profile" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_profile_family_rev_idx" ON "vorsorge_profile" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_profile_tombstone_idx" ON "vorsorge_profile" USING btree ("family_id","rev") WHERE "vorsorge_profile"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "vorsorge_profile_bearbeiter_idx" ON "vorsorge_profile" USING btree ("family_id","bearbeiter_id","created_at") WHERE "vorsorge_profile"."bearbeiter_id" is not null;