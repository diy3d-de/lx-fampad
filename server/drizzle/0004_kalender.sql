DROP TABLE "event_attendees" CASCADE;--> statement-breakpoint
DROP TABLE "events" CASCADE;--> statement-breakpoint
CREATE TABLE "termin_ausnahmen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"termin_id" uuid NOT NULL,
	"original_start" text NOT NULL,
	"abgesagt" boolean DEFAULT false NOT NULL,
	"titel" text,
	"start" text,
	"ende" text,
	"ort" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "termin_ausnahmen_original_len_ck" CHECK (char_length("termin_ausnahmen"."original_start") between 10 and 20),
	CONSTRAINT "termin_ausnahmen_titel_len_ck" CHECK ("termin_ausnahmen"."titel" is null or char_length("termin_ausnahmen"."titel") <= 200),
	CONSTRAINT "termin_ausnahmen_ort_len_ck" CHECK ("termin_ausnahmen"."ort" is null or char_length("termin_ausnahmen"."ort") <= 200),
	CONSTRAINT "termin_ausnahmen_zeit_len_ck" CHECK (("termin_ausnahmen"."start" is null or char_length("termin_ausnahmen"."start") between 10 and 20) and ("termin_ausnahmen"."ende" is null or char_length("termin_ausnahmen"."ende") between 10 and 20))
);
--> statement-breakpoint
CREATE TABLE "termin_teilnehmer" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"termin_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "termine" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"titel" text NOT NULL,
	"ort" text DEFAULT '' NOT NULL,
	"beschreibung" text DEFAULT '' NOT NULL,
	"ganztaegig" boolean DEFAULT false NOT NULL,
	"start_utc" timestamp with time zone,
	"end_utc" timestamp with time zone,
	"tzid" text,
	"start_date" date,
	"end_date" date,
	"rrule" text,
	"erinnerung_min" integer,
	"ical_uid" text,
	"audience" "list_audience" DEFAULT 'family' NOT NULL,
	"owner_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "termine_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "termine_titel_len_ck" CHECK (char_length("termine"."titel") <= 200),
	CONSTRAINT "termine_ort_len_ck" CHECK (char_length("termine"."ort") <= 200),
	CONSTRAINT "termine_beschreibung_len_ck" CHECK (char_length("termine"."beschreibung") <= 4000),
	CONSTRAINT "termine_rrule_len_ck" CHECK ("termine"."rrule" is null or char_length("termine"."rrule") <= 300),
	CONSTRAINT "termine_erinnerung_ck" CHECK ("termine"."erinnerung_min" is null or "termine"."erinnerung_min" between 0 and 40320),
	CONSTRAINT "termine_zeit_ck" CHECK (("termine"."ganztaegig" and "termine"."start_date" is not null and "termine"."end_date" is not null and "termine"."end_date" > "termine"."start_date")
        or (not "termine"."ganztaegig" and "termine"."start_utc" is not null and "termine"."end_utc" is not null and "termine"."tzid" is not null and "termine"."end_utc" >= "termine"."start_utc"))
);
--> statement-breakpoint
ALTER TABLE "termin_ausnahmen" ADD CONSTRAINT "termin_ausnahmen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "termin_ausnahmen" ADD CONSTRAINT "termin_ausnahmen_family_id_termin_id_termine_family_id_id_fk" FOREIGN KEY ("family_id","termin_id") REFERENCES "public"."termine"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "termin_teilnehmer" ADD CONSTRAINT "termin_teilnehmer_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "termin_teilnehmer" ADD CONSTRAINT "termin_teilnehmer_family_id_termin_id_termine_family_id_id_fk" FOREIGN KEY ("family_id","termin_id") REFERENCES "public"."termine"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "termin_teilnehmer" ADD CONSTRAINT "termin_teilnehmer_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "termine" ADD CONSTRAINT "termine_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "termine" ADD CONSTRAINT "termine_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "termin_ausnahmen_active_uq" ON "termin_ausnahmen" USING btree ("termin_id","original_start") WHERE "termin_ausnahmen"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "termin_ausnahmen_family_rev_idx" ON "termin_ausnahmen" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "termin_ausnahmen_tombstone_idx" ON "termin_ausnahmen" USING btree ("family_id","rev") WHERE "termin_ausnahmen"."deleted_at" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "termin_teilnehmer_active_uq" ON "termin_teilnehmer" USING btree ("termin_id","user_id") WHERE "termin_teilnehmer"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "termin_teilnehmer_user_idx" ON "termin_teilnehmer" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "termin_teilnehmer_family_rev_idx" ON "termin_teilnehmer" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "termin_teilnehmer_tombstone_idx" ON "termin_teilnehmer" USING btree ("family_id","rev") WHERE "termin_teilnehmer"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "termine_family_start_idx" ON "termine" USING btree ("family_id","start_utc");--> statement-breakpoint
CREATE INDEX "termine_family_rev_idx" ON "termine" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "termine_tombstone_idx" ON "termine" USING btree ("family_id","rev") WHERE "termine"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "termine_owner_idx" ON "termine" USING btree ("family_id","owner_id") WHERE "termine"."owner_id" is not null;--> statement-breakpoint
CREATE INDEX "termine_ical_uid_idx" ON "termine" USING btree ("family_id","ical_uid") WHERE "termine"."ical_uid" is not null;