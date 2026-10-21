CREATE TABLE "operator_alert_state" (
	"family_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"active" boolean DEFAULT false NOT NULL,
	"since" timestamp with time zone,
	"last_notified_at" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "operator_alert_state_family_id_kind_pk" PRIMARY KEY("family_id","kind"),
	CONSTRAINT "operator_alert_state_kind_ck" CHECK (length("operator_alert_state"."kind") between 1 and 60)
);
--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "key_version" integer;--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "key_reported_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "operators" ADD COLUMN "alerts_enabled" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "operator_alert_state" ADD CONSTRAINT "operator_alert_state_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "devices" ADD CONSTRAINT "devices_key_version_ck" CHECK ("devices"."key_version" is null or "devices"."key_version" >= 0);