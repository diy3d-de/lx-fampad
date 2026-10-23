ALTER TABLE "aufgaben" ADD COLUMN IF NOT EXISTS "frist" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "aufgaben" ADD COLUMN IF NOT EXISTS "frist_monate" integer;--> statement-breakpoint
ALTER TABLE "aufgaben" DROP CONSTRAINT IF EXISTS "aufgaben_erinnerung_ck";--> statement-breakpoint
ALTER TABLE "aufgaben" ADD CONSTRAINT "aufgaben_erinnerung_ck" CHECK ("aufgaben"."erinnerung_min" is null or "aufgaben"."erinnerung_min" between 0 and 525600);--> statement-breakpoint
ALTER TABLE "aufgaben" DROP CONSTRAINT IF EXISTS "aufgaben_frist_monate_ck";--> statement-breakpoint
ALTER TABLE "aufgaben" ADD CONSTRAINT "aufgaben_frist_monate_ck" CHECK ("aufgaben"."frist_monate" is null or "aufgaben"."frist_monate" between 1 and 120);
