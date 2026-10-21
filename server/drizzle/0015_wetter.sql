CREATE TABLE "weather_credentials" (
	"id" integer PRIMARY KEY DEFAULT 1 NOT NULL,
	"client_id_enc" text NOT NULL,
	"client_secret_enc" text NOT NULL,
	"refresh_token_enc" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_ok_at" timestamp with time zone,
	"last_error_at" timestamp with time zone,
	"last_error_code" text,
	"disabled_at" timestamp with time zone,
	CONSTRAINT "weather_credentials_single_ck" CHECK ("weather_credentials"."id" = 1)
);
--> statement-breakpoint
CREATE TABLE "weather_samples" (
	"ts" timestamp with time zone PRIMARY KEY NOT NULL,
	"temperature" double precision,
	"humidity" double precision,
	"pressure" double precision,
	"rain_1h" double precision,
	"rain_24h" double precision,
	"wind_kmh" double precision,
	"gust_kmh" double precision,
	"wind_angle" double precision
);
