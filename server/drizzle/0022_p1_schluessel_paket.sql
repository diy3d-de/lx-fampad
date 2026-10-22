ALTER TABLE "users" ADD COLUMN "removed_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "removed_by" uuid;--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_removed_ck" CHECK ("users"."removed_at" is null or "users"."disabled_at" is not null);