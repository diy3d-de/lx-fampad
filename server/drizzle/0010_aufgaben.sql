DROP TABLE "tasks" CASCADE;--> statement-breakpoint
CREATE TABLE "aufgabe_punkte" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"aufgabe_id" uuid NOT NULL,
	"text" text NOT NULL,
	"done_at" timestamp with time zone,
	"position" double precision DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "aufgabe_punkte_text_len_ck" CHECK (char_length("aufgabe_punkte"."text") <= 500),
	CONSTRAINT "aufgabe_punkte_position_ck" CHECK ("aufgabe_punkte"."position" between -1e12 and 1e12)
);
--> statement-breakpoint
CREATE TABLE "aufgaben" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"titel" text NOT NULL,
	"beschreibung" text DEFAULT '' NOT NULL,
	"faellig_date" date,
	"faellig_utc" timestamp with time zone,
	"tzid" text,
	"prioritaet" integer DEFAULT 0 NOT NULL,
	"assignee_id" uuid,
	"erledigt_at" timestamp with time zone,
	"erledigt_von" uuid,
	"wiederholung" text,
	"erinnerung_min" integer,
	"audience" "list_audience" DEFAULT 'family' NOT NULL,
	"owner_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "aufgaben_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "aufgaben_titel_len_ck" CHECK (char_length("aufgaben"."titel") <= 200),
	CONSTRAINT "aufgaben_beschreibung_len_ck" CHECK (char_length("aufgaben"."beschreibung") <= 4000),
	CONSTRAINT "aufgaben_prioritaet_ck" CHECK ("aufgaben"."prioritaet" between 0 and 3),
	CONSTRAINT "aufgaben_wiederholung_ck" CHECK ("aufgaben"."wiederholung" is null or "aufgaben"."wiederholung" in ('daily', 'weekly', 'monthly')),
	CONSTRAINT "aufgaben_erinnerung_ck" CHECK ("aufgaben"."erinnerung_min" is null or "aufgaben"."erinnerung_min" between 0 and 40320),
	CONSTRAINT "aufgaben_faellig_ck" CHECK (("aufgaben"."faellig_date" is null or "aufgaben"."faellig_utc" is null) and ("aufgaben"."faellig_utc" is null or "aufgaben"."tzid" is not null))
);
--> statement-breakpoint
ALTER TABLE "aufgabe_punkte" ADD CONSTRAINT "aufgabe_punkte_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "aufgabe_punkte" ADD CONSTRAINT "aufgabe_punkte_family_id_aufgabe_id_aufgaben_family_id_id_fk" FOREIGN KEY ("family_id","aufgabe_id") REFERENCES "public"."aufgaben"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "aufgaben" ADD CONSTRAINT "aufgaben_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "aufgaben" ADD CONSTRAINT "aufgaben_assignee_id_users_id_fk" FOREIGN KEY ("assignee_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "aufgaben" ADD CONSTRAINT "aufgaben_erledigt_von_users_id_fk" FOREIGN KEY ("erledigt_von") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "aufgaben" ADD CONSTRAINT "aufgaben_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "aufgabe_punkte_aufgabe_idx" ON "aufgabe_punkte" USING btree ("aufgabe_id");--> statement-breakpoint
CREATE INDEX "aufgabe_punkte_family_rev_idx" ON "aufgabe_punkte" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "aufgabe_punkte_tombstone_idx" ON "aufgabe_punkte" USING btree ("family_id","rev") WHERE "aufgabe_punkte"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "aufgaben_family_rev_idx" ON "aufgaben" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "aufgaben_tombstone_idx" ON "aufgaben" USING btree ("family_id","rev") WHERE "aufgaben"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "aufgaben_owner_idx" ON "aufgaben" USING btree ("family_id","owner_id") WHERE "aufgaben"."owner_id" is not null;--> statement-breakpoint
CREATE INDEX "aufgaben_assignee_idx" ON "aufgaben" USING btree ("family_id","assignee_id") WHERE "aufgaben"."assignee_id" is not null;