ALTER TYPE "public"."list_kind" ADD VALUE IF NOT EXISTS 'template';--> statement-breakpoint
ALTER TABLE "list_items" ADD COLUMN IF NOT EXISTS "category" text;
