CREATE TABLE "pins" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"nachricht_id" uuid NOT NULL,
	"gepinnt_von" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "reaktionen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"nachricht_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"inhalt" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "reaktionen_inhalt_len_ck" CHECK (char_length("reaktionen"."inhalt") <= 512)
);
--> statement-breakpoint
CREATE TABLE "stimmen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"nachricht_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"inhalt" text NOT NULL,
	"geaendert_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "stimmen_inhalt_len_ck" CHECK (char_length("stimmen"."inhalt") <= 512)
);
--> statement-breakpoint
ALTER TABLE "nachrichten" ADD CONSTRAINT "nachrichten_family_id_uq" UNIQUE("family_id","id");--> statement-breakpoint
ALTER TABLE "pins" ADD CONSTRAINT "pins_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "pins" ADD CONSTRAINT "pins_gepinnt_von_users_id_fk" FOREIGN KEY ("gepinnt_von") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "pins" ADD CONSTRAINT "pins_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "pins" ADD CONSTRAINT "pins_family_id_nachricht_id_nachrichten_family_id_id_fk" FOREIGN KEY ("family_id","nachricht_id") REFERENCES "public"."nachrichten"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "reaktionen" ADD CONSTRAINT "reaktionen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "reaktionen" ADD CONSTRAINT "reaktionen_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "reaktionen" ADD CONSTRAINT "reaktionen_family_id_nachricht_id_nachrichten_family_id_id_fk" FOREIGN KEY ("family_id","nachricht_id") REFERENCES "public"."nachrichten"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "reaktionen" ADD CONSTRAINT "reaktionen_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "stimmen" ADD CONSTRAINT "stimmen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "stimmen" ADD CONSTRAINT "stimmen_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "stimmen" ADD CONSTRAINT "stimmen_family_id_nachricht_id_nachrichten_family_id_id_fk" FOREIGN KEY ("family_id","nachricht_id") REFERENCES "public"."nachrichten"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "stimmen" ADD CONSTRAINT "stimmen_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "pins_active_uq" ON "pins" USING btree ("nachricht_id") WHERE "pins"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "pins_konversation_idx" ON "pins" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX "pins_family_rev_idx" ON "pins" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "pins_tombstone_idx" ON "pins" USING btree ("family_id","rev") WHERE "pins"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "pins_von_idx" ON "pins" USING btree ("family_id","gepinnt_von","created_at") WHERE "pins"."gepinnt_von" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "reaktionen_active_uq" ON "reaktionen" USING btree ("nachricht_id","user_id") WHERE "reaktionen"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "reaktionen_konversation_idx" ON "reaktionen" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX "reaktionen_user_idx" ON "reaktionen" USING btree ("family_id","user_id","created_at");--> statement-breakpoint
CREATE INDEX "reaktionen_family_rev_idx" ON "reaktionen" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "reaktionen_tombstone_idx" ON "reaktionen" USING btree ("family_id","rev") WHERE "reaktionen"."deleted_at" is not null;--> statement-breakpoint
CREATE UNIQUE INDEX "stimmen_active_uq" ON "stimmen" USING btree ("nachricht_id","user_id") WHERE "stimmen"."deleted_at" is null;--> statement-breakpoint
CREATE INDEX "stimmen_konversation_idx" ON "stimmen" USING btree ("family_id","konversation_id");--> statement-breakpoint
CREATE INDEX "stimmen_user_idx" ON "stimmen" USING btree ("family_id","user_id","created_at");--> statement-breakpoint
CREATE INDEX "stimmen_family_rev_idx" ON "stimmen" USING btree ("family_id","rev");--> statement-breakpoint
CREATE INDEX "stimmen_tombstone_idx" ON "stimmen" USING btree ("family_id","rev") WHERE "stimmen"."deleted_at" is not null;
