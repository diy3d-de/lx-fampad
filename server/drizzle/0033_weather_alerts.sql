CREATE TABLE IF NOT EXISTS "weather_alert_state" (
	"kind" text PRIMARY KEY NOT NULL,
	"active" boolean NOT NULL,
	"changed_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "push_endpoints" ADD COLUMN IF NOT EXISTS "weather_kinds" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "push_endpoints" ADD COLUMN IF NOT EXISTS "weather_sent" jsonb DEFAULT '{}'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "push_endpoints" DROP CONSTRAINT IF EXISTS "push_endpoints_weather_kinds_ck";--> statement-breakpoint
ALTER TABLE "push_endpoints" ADD CONSTRAINT "push_endpoints_weather_kinds_ck" CHECK ("push_endpoints"."weather_kinds" between 0 and 31);
