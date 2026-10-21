CREATE TABLE "account_kdf" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"salt_generation" integer DEFAULT 1 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "account_kdf_generation_ck" CHECK ("account_kdf"."salt_generation" >= 1)
);
--> statement-breakpoint
CREATE TABLE "key_backups_pw" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"family_id" uuid NOT NULL,
	"blob" text NOT NULL,
	"key_version" integer NOT NULL,
	"kdf_id" text NOT NULL,
	"mem_kib" integer NOT NULL,
	"ops" integer NOT NULL,
	"salt_generation" integer NOT NULL,
	"state" text DEFAULT 'active' NOT NULL,
	"verified_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "key_backups_pw_state_ck" CHECK ("key_backups_pw"."state" in ('active', 'stale', 'superseded')),
	CONSTRAINT "key_backups_pw_size_ck" CHECK (length("key_backups_pw"."blob") between 96 and 4096 and "key_backups_pw"."key_version" >= 1),
	CONSTRAINT "key_backups_pw_kdf_ck" CHECK ("key_backups_pw"."kdf_id" in ('argon2id-v1') and "key_backups_pw"."mem_kib" >= 65536 and "key_backups_pw"."ops" >= 3 and "key_backups_pw"."salt_generation" >= 1)
);
--> statement-breakpoint
ALTER TABLE "account_kdf" ADD CONSTRAINT "account_kdf_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "key_backups_pw" ADD CONSTRAINT "key_backups_pw_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "key_backups_pw" ADD CONSTRAINT "key_backups_pw_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "key_backups_pw_current_uq" ON "key_backups_pw" USING btree ("user_id") WHERE "key_backups_pw"."state" in ('active', 'stale');--> statement-breakpoint
CREATE INDEX "key_backups_pw_user_idx" ON "key_backups_pw" USING btree ("user_id");