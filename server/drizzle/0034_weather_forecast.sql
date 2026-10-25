CREATE TABLE IF NOT EXISTS "weather_forecast" (
	"kind" text PRIMARY KEY NOT NULL,
	"data" jsonb NOT NULL,
	"fetched_at" timestamp with time zone,
	"last_error_at" timestamp with time zone,
	"last_error_code" text,
	"error_count" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "weather_forecast_kind_ck" CHECK ("weather_forecast"."kind" in ('forecast', 'alerts'))
);
