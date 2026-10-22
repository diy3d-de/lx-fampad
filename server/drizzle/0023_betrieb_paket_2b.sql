CREATE TABLE "operator_settings" (
	"family_id" uuid PRIMARY KEY NOT NULL,
	"maintenance_active" boolean DEFAULT false NOT NULL,
	"maintenance_since" timestamp with time zone,
	"maintenance_until" timestamp with time zone,
	"maintenance_by" uuid,
	"notice_text" text,
	"notice_expires_at" timestamp with time zone,
	"notice_set_at" timestamp with time zone,
	"notice_set_by" uuid,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "operator_settings_notice_ck" CHECK ("operator_settings"."notice_text" is null or (length("operator_settings"."notice_text") between 1 and 280 and "operator_settings"."notice_set_at" is not null)),
	CONSTRAINT "operator_settings_maintenance_ck" CHECK (not "operator_settings"."maintenance_active" or "operator_settings"."maintenance_since" is not null)
);
--> statement-breakpoint
ALTER TABLE "operator_settings" ADD CONSTRAINT "operator_settings_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "operator_settings" ADD CONSTRAINT "operator_settings_maintenance_by_users_id_fk" FOREIGN KEY ("maintenance_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "operator_settings" ADD CONSTRAINT "operator_settings_notice_set_by_users_id_fk" FOREIGN KEY ("notice_set_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;