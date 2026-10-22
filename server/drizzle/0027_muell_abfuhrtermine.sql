CREATE TABLE "waste_events" (
	"family_id" uuid NOT NULL,
	"day" date NOT NULL,
	"kind" text NOT NULL,
	CONSTRAINT "waste_events_family_id_day_kind_pk" PRIMARY KEY("family_id","day","kind"),
	CONSTRAINT "waste_events_kind_ck" CHECK ("waste_events"."kind" in ('rest', 'bio', 'gelb', 'papier', 'gruen', 'sonder', 'sperr', 'baum', 'sonst'))
);
--> statement-breakpoint
CREATE TABLE "waste_state" (
	"family_id" uuid PRIMARY KEY NOT NULL,
	"check_requested_at" timestamp with time zone,
	"last_request_at" timestamp with time zone,
	"last_check_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "waste_years" (
	"family_id" uuid NOT NULL,
	"year" integer NOT NULL,
	"status" text NOT NULL,
	"event_count" integer DEFAULT 0 NOT NULL,
	"loaded_at" timestamp with time zone,
	"last_checked_at" timestamp with time zone,
	"error_code" text,
	CONSTRAINT "waste_years_family_id_year_pk" PRIMARY KEY("family_id","year"),
	CONSTRAINT "waste_years_status_ck" CHECK ("waste_years"."status" in ('loaded', 'unavailable', 'error')),
	CONSTRAINT "waste_years_year_ck" CHECK ("waste_years"."year" between 2000 and 2200)
);
--> statement-breakpoint
ALTER TABLE "waste_events" ADD CONSTRAINT "waste_events_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "waste_state" ADD CONSTRAINT "waste_state_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "waste_years" ADD CONSTRAINT "waste_years_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;