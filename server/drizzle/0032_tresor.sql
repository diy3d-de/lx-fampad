ALTER TYPE "public"."konversation_art" ADD VALUE IF NOT EXISTS 'tresor';--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tresor_eintraege" (
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
	CONSTRAINT "tresor_eintraege_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "tresor_eintraege_inhalt_len_ck" CHECK (char_length("tresor_eintraege"."inhalt") <= 24576)
);
--> statement-breakpoint
ALTER TABLE "konversationen" DROP CONSTRAINT IF EXISTS "konversationen_teilnehmer_ck";--> statement-breakpoint
ALTER TABLE "tresor_eintraege" DROP CONSTRAINT IF EXISTS "tresor_eintraege_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "tresor_eintraege" ADD CONSTRAINT "tresor_eintraege_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tresor_eintraege" DROP CONSTRAINT IF EXISTS "tresor_eintraege_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "tresor_eintraege" ADD CONSTRAINT "tresor_eintraege_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tresor_eintraege" DROP CONSTRAINT IF EXISTS "tresor_eintraege_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "tresor_eintraege" ADD CONSTRAINT "tresor_eintraege_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_eintraege_konversation_idx" ON "tresor_eintraege" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_eintraege_family_rev_idx" ON "tresor_eintraege" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_eintraege_tombstone_idx" ON "tresor_eintraege" USING btree ("family_id","rev") WHERE "tresor_eintraege"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_eintraege_bearbeiter_idx" ON "tresor_eintraege" USING btree ("family_id","bearbeiter_id","created_at") WHERE "tresor_eintraege"."bearbeiter_id" is not null;--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_teilnehmer_ck" CHECK (("konversationen"."art" = 'family' and cardinality("konversationen"."teilnehmer") = 0)
        or ("konversationen"."art" = 'direct' and cardinality("konversationen"."teilnehmer") = 2)
        or ("konversationen"."art" = 'group' and cardinality("konversationen"."teilnehmer") between 2 and 20)
        or ("konversationen"."art"::text = 'meds' and cardinality("konversationen"."teilnehmer") between 1 and 20)
        or ("konversationen"."art"::text = 'zaehler' and cardinality("konversationen"."teilnehmer") between 1 and 20)
        or ("konversationen"."art"::text = 'tresor' and cardinality("konversationen"."teilnehmer") between 1 and 20));