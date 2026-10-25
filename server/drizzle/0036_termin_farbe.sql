ALTER TABLE "termine" ADD COLUMN IF NOT EXISTS "farbe" smallint;--> statement-breakpoint
ALTER TABLE "termine" DROP CONSTRAINT IF EXISTS "termine_farbe_ck";--> statement-breakpoint
ALTER TABLE "termine" ADD CONSTRAINT "termine_farbe_ck" CHECK ("termine"."farbe" is null or "termine"."farbe" between 0 and 10);
