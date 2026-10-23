ALTER TYPE "public"."konversation_art" ADD VALUE IF NOT EXISTS 'zaehler';--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "zaehler" (
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
	CONSTRAINT "zaehler_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "zaehler_inhalt_len_ck" CHECK (char_length("zaehler"."inhalt") <= 16384)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "zaehlerstaende" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"zaehler_id" uuid NOT NULL,
	"inhalt" text NOT NULL,
	"bearbeiter_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "zaehlerstaende_inhalt_len_ck" CHECK (char_length("zaehlerstaende"."inhalt") <= 2048)
);
--> statement-breakpoint
ALTER TABLE "zaehler" DROP CONSTRAINT IF EXISTS "zaehler_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "zaehler" ADD CONSTRAINT "zaehler_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "zaehler" DROP CONSTRAINT IF EXISTS "zaehler_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "zaehler" ADD CONSTRAINT "zaehler_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "zaehler" DROP CONSTRAINT IF EXISTS "zaehler_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "zaehler" ADD CONSTRAINT "zaehler_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "zaehlerstaende" DROP CONSTRAINT IF EXISTS "zaehlerstaende_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "zaehlerstaende" ADD CONSTRAINT "zaehlerstaende_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "zaehlerstaende" DROP CONSTRAINT IF EXISTS "zaehlerstaende_bearbeiter_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "zaehlerstaende" ADD CONSTRAINT "zaehlerstaende_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "zaehlerstaende" DROP CONSTRAINT IF EXISTS "zaehlerstaende_family_id_konversation_id_konversationen_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "zaehlerstaende" ADD CONSTRAINT "zaehlerstaende_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "zaehlerstaende" DROP CONSTRAINT IF EXISTS "zaehlerstaende_family_id_zaehler_id_zaehler_family_id_id_fk";--> statement-breakpoint
ALTER TABLE "zaehlerstaende" ADD CONSTRAINT "zaehlerstaende_family_id_zaehler_id_zaehler_family_id_id_fk" FOREIGN KEY ("family_id","zaehler_id") REFERENCES "public"."zaehler"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehler_konversation_idx" ON "zaehler" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehler_family_rev_idx" ON "zaehler" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehler_tombstone_idx" ON "zaehler" USING btree ("family_id","rev") WHERE "zaehler"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehler_bearbeiter_idx" ON "zaehler" USING btree ("family_id","bearbeiter_id","created_at") WHERE "zaehler"."bearbeiter_id" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehlerstaende_zaehler_idx" ON "zaehlerstaende" USING btree ("family_id","zaehler_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehlerstaende_konversation_idx" ON "zaehlerstaende" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehlerstaende_family_rev_idx" ON "zaehlerstaende" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehlerstaende_tombstone_idx" ON "zaehlerstaende" USING btree ("family_id","rev") WHERE "zaehlerstaende"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "zaehlerstaende_bearbeiter_idx" ON "zaehlerstaende" USING btree ("family_id","bearbeiter_id","created_at") WHERE "zaehlerstaende"."bearbeiter_id" is not null;--> statement-breakpoint
ALTER TABLE "konversationen" DROP CONSTRAINT IF EXISTS "konversationen_teilnehmer_ck";--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_teilnehmer_ck" CHECK (("konversationen"."art" = 'family' and cardinality("konversationen"."teilnehmer") = 0)
        or ("konversationen"."art" = 'direct' and cardinality("konversationen"."teilnehmer") = 2)
        or ("konversationen"."art" = 'group' and cardinality("konversationen"."teilnehmer") between 2 and 20)
        or ("konversationen"."art"::text = 'meds' and cardinality("konversationen"."teilnehmer") between 1 and 20)
        or ("konversationen"."art"::text = 'zaehler' and cardinality("konversationen"."teilnehmer") between 1 and 20));