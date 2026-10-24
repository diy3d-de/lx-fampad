ALTER TABLE "messages" DROP CONSTRAINT IF EXISTS "messages_file_id_files_id_fk";
--> statement-breakpoint
ALTER TABLE "messages" DROP COLUMN IF EXISTS "file_id";
--> statement-breakpoint
DROP TABLE IF EXISTS "files" CASCADE;
--> statement-breakpoint
DROP TYPE IF EXISTS "public"."file_kind";
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "datei_blob" (
	"id" uuid PRIMARY KEY NOT NULL,
	"family_id" uuid NOT NULL,
	"uploader_id" uuid,
	"modus" text NOT NULL,
	"kind" text NOT NULL,
	"size" bigint NOT NULL,
	"disk_size" bigint NOT NULL,
	"sha256" text NOT NULL,
	"mime" text,
	"dek_wrap" "bytea",
	"kid" integer,
	"state" text DEFAULT 'ready' NOT NULL,
	"claim_entity" text,
	"claim_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"claimed_at" timestamp with time zone,
	"orphaned_at" timestamp with time zone,
	CONSTRAINT "datei_blob_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "datei_blob_modus_ck" CHECK ("datei_blob"."modus" in ('server', 'e2ee')),
	CONSTRAINT "datei_blob_kind_ck" CHECK ("datei_blob"."kind" in ('datei', 'thumb', 'opak')),
	CONSTRAINT "datei_blob_state_ck" CHECK ("datei_blob"."state" in ('ready', 'claimed')),
	CONSTRAINT "datei_blob_size_ck" CHECK ("datei_blob"."size" >= 0 and "datei_blob"."disk_size" >= 0),
	CONSTRAINT "datei_blob_key_ck" CHECK (("datei_blob"."modus" = 'server' and "datei_blob"."dek_wrap" is not null and "datei_blob"."kid" is not null) or ("datei_blob"."modus" = 'e2ee' and "datei_blob"."dek_wrap" is null and "datei_blob"."kid" is null)),
	CONSTRAINT "datei_blob_claim_ck" CHECK (("datei_blob"."state" = 'claimed') = ("datei_blob"."claim_entity" is not null and "datei_blob"."claim_id" is not null))
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "datei_upload" (
	"id" uuid PRIMARY KEY NOT NULL,
	"family_id" uuid NOT NULL,
	"uploader_id" uuid NOT NULL,
	"modus" text NOT NULL,
	"kind" text NOT NULL,
	"declared_mime" text,
	"length" bigint NOT NULL,
	"offset" bigint DEFAULT 0 NOT NULL,
	"status" text DEFAULT 'open' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	CONSTRAINT "datei_upload_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "datei_upload_modus_ck" CHECK ("datei_upload"."modus" in ('server', 'e2ee')),
	CONSTRAINT "datei_upload_kind_ck" CHECK ("datei_upload"."kind" in ('datei', 'thumb', 'opak')),
	CONSTRAINT "datei_upload_status_ck" CHECK ("datei_upload"."status" in ('open', 'finalizing', 'done', 'aborted')),
	CONSTRAINT "datei_upload_len_ck" CHECK ("datei_upload"."length" >= 0 and "datei_upload"."offset" >= 0 and "datei_upload"."offset" <= "datei_upload"."length")
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "datei_versionen" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"datei_id" uuid NOT NULL,
	"nr" integer NOT NULL,
	"blob_id" uuid NOT NULL,
	"thumb_blob_id" uuid,
	"size" bigint DEFAULT 0 NOT NULL,
	"mime" text,
	"sha256" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "datei_versionen_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "datei_versionen_nr_uq" UNIQUE("family_id","datei_id","nr"),
	CONSTRAINT "datei_versionen_nr_ck" CHECK ("datei_versionen"."nr" between 1 and 9999),
	CONSTRAINT "datei_versionen_size_ck" CHECK ("datei_versionen"."size" >= 0)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "dateien" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"ordner_id" uuid,
	"name" text NOT NULL,
	"audience" "list_audience" DEFAULT 'family' NOT NULL,
	"owner_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "dateien_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "dateien_name_len_ck" CHECK (char_length("dateien"."name") <= 200)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "ordner" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"parent_id" uuid,
	"name" text NOT NULL,
	"audience" "list_audience" DEFAULT 'family' NOT NULL,
	"owner_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "ordner_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "ordner_name_len_ck" CHECK (char_length("ordner"."name") <= 200)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "tresor_anhaenge" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"konversation_id" uuid NOT NULL,
	"blob_id" uuid NOT NULL,
	"inhalt" text NOT NULL,
	"size" bigint DEFAULT 0 NOT NULL,
	"bearbeiter_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"rev" bigint NOT NULL,
	"field_revs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone,
	CONSTRAINT "tresor_anhaenge_family_id_uq" UNIQUE("family_id","id"),
	CONSTRAINT "tresor_anhaenge_inhalt_len_ck" CHECK (char_length("tresor_anhaenge"."inhalt") <= 4096),
	CONSTRAINT "tresor_anhaenge_size_ck" CHECK ("tresor_anhaenge"."size" >= 0)
);
--> statement-breakpoint
ALTER TABLE "datei_blob" DROP CONSTRAINT IF EXISTS "datei_blob_family_id_families_id_fk";
--> statement-breakpoint
ALTER TABLE "datei_blob" ADD CONSTRAINT "datei_blob_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "datei_blob" DROP CONSTRAINT IF EXISTS "datei_blob_uploader_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "datei_blob" ADD CONSTRAINT "datei_blob_uploader_id_users_id_fk" FOREIGN KEY ("uploader_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "datei_upload" DROP CONSTRAINT IF EXISTS "datei_upload_family_id_families_id_fk";
--> statement-breakpoint
ALTER TABLE "datei_upload" ADD CONSTRAINT "datei_upload_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "datei_upload" DROP CONSTRAINT IF EXISTS "datei_upload_uploader_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "datei_upload" ADD CONSTRAINT "datei_upload_uploader_id_users_id_fk" FOREIGN KEY ("uploader_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "datei_versionen" DROP CONSTRAINT IF EXISTS "datei_versionen_family_id_families_id_fk";
--> statement-breakpoint
ALTER TABLE "datei_versionen" ADD CONSTRAINT "datei_versionen_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "datei_versionen" DROP CONSTRAINT IF EXISTS "datei_versionen_family_id_datei_id_dateien_family_id_id_fk";
--> statement-breakpoint
ALTER TABLE "datei_versionen" ADD CONSTRAINT "datei_versionen_family_id_datei_id_dateien_family_id_id_fk" FOREIGN KEY ("family_id","datei_id") REFERENCES "public"."dateien"("family_id","id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "dateien" DROP CONSTRAINT IF EXISTS "dateien_family_id_families_id_fk";
--> statement-breakpoint
ALTER TABLE "dateien" ADD CONSTRAINT "dateien_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "dateien" DROP CONSTRAINT IF EXISTS "dateien_owner_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "dateien" ADD CONSTRAINT "dateien_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "ordner" DROP CONSTRAINT IF EXISTS "ordner_family_id_families_id_fk";
--> statement-breakpoint
ALTER TABLE "ordner" ADD CONSTRAINT "ordner_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "ordner" DROP CONSTRAINT IF EXISTS "ordner_owner_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "ordner" ADD CONSTRAINT "ordner_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "tresor_anhaenge" DROP CONSTRAINT IF EXISTS "tresor_anhaenge_family_id_families_id_fk";
--> statement-breakpoint
ALTER TABLE "tresor_anhaenge" ADD CONSTRAINT "tresor_anhaenge_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "tresor_anhaenge" DROP CONSTRAINT IF EXISTS "tresor_anhaenge_bearbeiter_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "tresor_anhaenge" ADD CONSTRAINT "tresor_anhaenge_bearbeiter_id_users_id_fk" FOREIGN KEY ("bearbeiter_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "tresor_anhaenge" DROP CONSTRAINT IF EXISTS "tresor_anhaenge_family_id_konversation_id_konversationen_family_id_id_fk";
--> statement-breakpoint
ALTER TABLE "tresor_anhaenge" ADD CONSTRAINT "tresor_anhaenge_family_id_konversation_id_konversationen_family_id_id_fk" FOREIGN KEY ("family_id","konversation_id") REFERENCES "public"."konversationen"("family_id","id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_blob_family_state_idx" ON "datei_blob" USING btree ("family_id","state");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_blob_claim_idx" ON "datei_blob" USING btree ("claim_entity","claim_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_blob_orphan_idx" ON "datei_blob" USING btree ("orphaned_at") WHERE "datei_blob"."orphaned_at" is not null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_upload_uploader_idx" ON "datei_upload" USING btree ("uploader_id","created_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_upload_family_status_idx" ON "datei_upload" USING btree ("family_id","status");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_versionen_datei_idx" ON "datei_versionen" USING btree ("family_id","datei_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_versionen_family_rev_idx" ON "datei_versionen" USING btree ("family_id","rev");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "datei_versionen_tombstone_idx" ON "datei_versionen" USING btree ("family_id","rev") WHERE "datei_versionen"."deleted_at" is not null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "dateien_ordner_idx" ON "dateien" USING btree ("family_id","ordner_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "dateien_family_rev_idx" ON "dateien" USING btree ("family_id","rev");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "dateien_tombstone_idx" ON "dateien" USING btree ("family_id","rev") WHERE "dateien"."deleted_at" is not null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "dateien_owner_idx" ON "dateien" USING btree ("family_id","owner_id") WHERE "dateien"."owner_id" is not null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "ordner_parent_idx" ON "ordner" USING btree ("family_id","parent_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "ordner_family_rev_idx" ON "ordner" USING btree ("family_id","rev");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "ordner_tombstone_idx" ON "ordner" USING btree ("family_id","rev") WHERE "ordner"."deleted_at" is not null;
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_anhaenge_konversation_idx" ON "tresor_anhaenge" USING btree ("family_id","konversation_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_anhaenge_family_rev_idx" ON "tresor_anhaenge" USING btree ("family_id","rev");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "tresor_anhaenge_tombstone_idx" ON "tresor_anhaenge" USING btree ("family_id","rev") WHERE "tresor_anhaenge"."deleted_at" is not null;
