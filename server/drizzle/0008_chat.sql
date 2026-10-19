CREATE TYPE "public"."konversation_art" AS ENUM('family', 'direct', 'group');--> statement-breakpoint
CREATE TABLE "konversationen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"art" "konversation_art" NOT NULL,
	"titel" text DEFAULT '' NOT NULL,
	"enc_version" text DEFAULT 'p1' NOT NULL,
	"teilnehmer" uuid[] DEFAULT '{}'::uuid[] NOT NULL,
	"owner_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "konversationen_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "konversationen_titel_len_ck" CHECK (char_length("konversationen"."titel") <= 512),
	CONSTRAINT "konversationen_teilnehmer_ck" CHECK (("konversationen"."art" = 'family' and cardinality("konversationen"."teilnehmer") = 0)
        or ("konversationen"."art" = 'direct' and cardinality("konversationen"."teilnehmer") = 2)
        or ("konversationen"."art" = 'group' and cardinality("konversationen"."teilnehmer") between 2 and 20))
);
--> statement-breakpoint
CREATE TABLE "lesestand" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"gelesen_bis" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "nachrichten" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"autor_id" uuid,
	"text" text NOT NULL,
	"antwort_auf" uuid,
	"bearbeitet_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "nachrichten_text_len_ck" CHECK (char_length("nachrichten"."text") <= 16384)
);
--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "konversationen" ADD CONSTRAINT "konversationen_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "lesestand" ADD CONSTRAINT "lesestand_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "lesestand" ADD CONSTRAINT "lesestand_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "lesestand" ADD CONSTRAINT "lesestand_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "nachrichten" ADD CONSTRAINT "nachrichten_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "nachrichten" ADD CONSTRAINT "nachrichten_autor_id_users_id_fk" FOREIGN KEY ("autor_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "nachrichten" ADD CONSTRAINT "nachrichten_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "konversationen_family_rev_idx" ON "konversationen" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "konversationen_tombstone_idx" ON "konversationen" USING btree ("family_id","rev") WHERE "konversationen"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "konversationen_owner_idx" ON "konversationen" USING btree ("family_id","owner_id") WHERE "konversationen"."owner_id" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "konversationen_family_chat_uq" ON "konversationen" USING btree ("family_id") WHERE "konversationen"."art" = 'family' and "konversationen"."deleted_at" is null;--> statement-breakpoint
CREATE UNIQUE INDEX "konversationen_direct_uq" ON "konversationen" USING btree ("family_id","teilnehmer") WHERE "konversationen"."art" = 'direct' and "konversationen"."deleted_at" is null;--> statement-breakpoint
CREATE UNIQUE INDEX "lesestand_active_uq" ON "lesestand" USING btree ("konversation_id","user_id") WHERE "lesestand"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "lesestand_user_idx" ON "lesestand" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "lesestand_family_rev_idx" ON "lesestand" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "lesestand_tombstone_idx" ON "lesestand" USING btree ("family_id","rev") WHERE "lesestand"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "nachrichten_konversation_idx" ON "nachrichten" USING btree ("family_id","konversation_id","created_at");--> statement-breakpoint
CREATE INDEX "nachrichten_family_rev_idx" ON "nachrichten" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "nachrichten_tombstone_idx" ON "nachrichten" USING btree ("family_id","rev") WHERE "nachrichten"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "nachrichten_autor_idx" ON "nachrichten" USING btree ("family_id","autor_id","created_at") WHERE "nachrichten"."autor_id" is not null;