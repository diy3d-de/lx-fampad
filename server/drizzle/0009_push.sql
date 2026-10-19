CREATE TABLE "push_endpoints" (
	"device_id" uuid PRIMARY KEY NOT NULL,
	"family_id" uuid NOT NULL,
	"topic" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_ok_at" timestamp with time zone,
	"last_error_at" timestamp with time zone,
	"fail_count" integer DEFAULT 0 NOT NULL,
	"disabled_at" timestamp with time zone,
	CONSTRAINT "push_endpoints_topic_uq" UNIQUE("topic"),
	CONSTRAINT "push_endpoints_topic_ck" CHECK ("push_endpoints"."topic" ~ '^up[A-Za-z0-9_-]{12,64}$')
);
--> statement-breakpoint
ALTER TABLE "push_endpoints" ADD CONSTRAINT "push_endpoints_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "push_endpoints" ADD CONSTRAINT "push_endpoints_family_id_device_id_devices_family_id_id_fk" FOREIGN KEY ("family_id","device_id") REFERENCES "public"."devices"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "push_endpoints_family_idx" ON "push_endpoints" USING btree ("family_id");