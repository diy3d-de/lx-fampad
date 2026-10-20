CREATE TABLE "epoche_wraps" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"epoche" integer NOT NULL,
	"empfaenger_id" uuid NOT NULL,
	"verteiler_id" uuid,
	"wrap" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "epoche_wraps_epoche_ck" CHECK ("epoche_wraps"."epoche" between 1 and 100000),
	CONSTRAINT "epoche_wraps_len_ck" CHECK (char_length("epoche_wraps"."wrap") <= 4096)
);
--> statement-breakpoint
CREATE TABLE "konversation_epochen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"epoche" integer NOT NULL,
	"verteiler_id" uuid,
	"mitglieder" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "konversation_epochen_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "konversation_epochen_epoche_ck" CHECK ("konversation_epochen"."epoche" between 1 and 100000),
	CONSTRAINT "konversation_epochen_len_ck" CHECK (char_length("konversation_epochen"."mitglieder") <= 16384)
);
--> statement-breakpoint
ALTER TABLE "konversationen" ALTER COLUMN "enc_version" SET DEFAULT 'e1';--> statement-breakpoint
ALTER TABLE "epoche_wraps" ADD CONSTRAINT "epoche_wraps_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "epoche_wraps" ADD CONSTRAINT "epoche_wraps_verteiler_id_users_id_fk" FOREIGN KEY ("verteiler_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "epoche_wraps" ADD CONSTRAINT "epoche_wraps_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "epoche_wraps" ADD CONSTRAINT "epoche_wraps_family_id_empfaenger_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","empfaenger_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "konversation_epochen" ADD CONSTRAINT "konversation_epochen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "konversation_epochen" ADD CONSTRAINT "konversation_epochen_verteiler_id_users_id_fk" FOREIGN KEY ("verteiler_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "konversation_epochen" ADD CONSTRAINT "konversation_epochen_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "epoche_wraps_uq" ON "epoche_wraps" USING btree ("family_id","konversation_id","epoche","empfaenger_id") WHERE "epoche_wraps"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "epoche_wraps_empfaenger_idx" ON "epoche_wraps" USING btree ("family_id","empfaenger_id");--> statement-breakpoint
CREATE INDEX "epoche_wraps_family_rev_idx" ON "epoche_wraps" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "epoche_wraps_tombstone_idx" ON "epoche_wraps" USING btree ("family_id","rev") WHERE "epoche_wraps"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "epoche_wraps_verteiler_idx" ON "epoche_wraps" USING btree ("family_id","verteiler_id","created_at") WHERE "epoche_wraps"."verteiler_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "konversation_epochen_uq" ON "konversation_epochen" USING btree ("family_id","konversation_id","epoche") WHERE "konversation_epochen"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "konversation_epochen_family_rev_idx" ON "konversation_epochen" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "konversation_epochen_tombstone_idx" ON "konversation_epochen" USING btree ("family_id","rev") WHERE "konversation_epochen"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "konversation_epochen_verteiler_idx" ON "konversation_epochen" USING btree ("family_id","verteiler_id","created_at") WHERE "konversation_epochen"."verteiler_id" is not null;