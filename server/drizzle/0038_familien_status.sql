CREATE TABLE IF NOT EXISTS "familien_status" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"text" text NOT NULL,
	"bis" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "familien_status" DROP CONSTRAINT IF EXISTS "familien_status_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "familien_status" ADD CONSTRAINT "familien_status_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "familien_status" DROP CONSTRAINT IF EXISTS "familien_status_family_id_user_id_memberships_family_id_user_id_fk";--> statement-breakpoint
ALTER TABLE "familien_status" ADD CONSTRAINT "familien_status_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "familien_status_active_uq" ON "familien_status" USING btree ("family_id","user_id") WHERE "familien_status"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "familien_status_family_rev_idx" ON "familien_status" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "familien_status_tombstone_idx" ON "familien_status" USING btree ("family_id","rev") WHERE "familien_status"."deleted_at" is not null;