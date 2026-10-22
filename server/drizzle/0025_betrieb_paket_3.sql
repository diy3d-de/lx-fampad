CREATE TABLE "operator_metrics" (
	"family_id" uuid NOT NULL,
	"day" date NOT NULL,
	"active_persons_7" integer DEFAULT 0 NOT NULL,
	"active_persons_30" integer DEFAULT 0 NOT NULL,
	"active_devices_7" integer DEFAULT 0 NOT NULL,
	"active_devices_30" integer DEFAULT 0 NOT NULL,
	"sync_runs" integer DEFAULT 0 NOT NULL,
	"sync_errors" integer DEFAULT 0 NOT NULL,
	"rate_limited" integer DEFAULT 0 NOT NULL,
	"db_bytes" bigint,
	"files_bytes" bigint,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "operator_metrics_family_id_day_pk" PRIMARY KEY("family_id","day"),
	CONSTRAINT "operator_metrics_nonneg_ck" CHECK ("operator_metrics"."active_persons_7" >= 0 and "operator_metrics"."active_persons_30" >= 0 and "operator_metrics"."active_devices_7" >= 0 and "operator_metrics"."active_devices_30" >= 0 and "operator_metrics"."sync_runs" >= 0 and "operator_metrics"."sync_errors" >= 0 and "operator_metrics"."rate_limited" >= 0 and ("operator_metrics"."db_bytes" is null or "operator_metrics"."db_bytes" >= 0) and ("operator_metrics"."files_bytes" is null or "operator_metrics"."files_bytes" >= 0))
);
--> statement-breakpoint
ALTER TABLE "weather_credentials" ADD COLUMN "error_count" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "operator_metrics" ADD CONSTRAINT "operator_metrics_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;