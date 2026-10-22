CREATE TABLE "guardian_escrows" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"child_id" uuid NOT NULL,
	"guardian_id" uuid NOT NULL,
	"key_version" integer NOT NULL,
	"guardian_key_version" integer NOT NULL,
	"blob" text NOT NULL,
	"sig" text NOT NULL,
	"state" text DEFAULT 'active' NOT NULL,
	"consent_at" timestamp with time zone DEFAULT now() NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "guardian_escrows_state_ck" CHECK ("guardian_escrows"."state" in ('active', 'stale', 'superseded', 'revoked')),
	CONSTRAINT "guardian_escrows_size_ck" CHECK (length("guardian_escrows"."blob") between 64 and 2048 and length("guardian_escrows"."sig") between 64 and 256 and "guardian_escrows"."key_version" >= 1 and "guardian_escrows"."guardian_key_version" >= 1),
	CONSTRAINT "guardian_escrows_self_ck" CHECK ("guardian_escrows"."child_id" <> "guardian_escrows"."guardian_id")
);
--> statement-breakpoint
CREATE TABLE "guardian_recoveries" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"child_id" uuid NOT NULL,
	"state" text DEFAULT 'pending' NOT NULL,
	"key_version" integer NOT NULL,
	"commit" text NOT NULL,
	"ready_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"guardian_id" uuid,
	"challenge" text,
	"reveal_pub" text,
	"reveal_nonce" text,
	"release_blob" text,
	"release_sig" text,
	"device_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "guardian_recoveries_state_ck" CHECK ("guardian_recoveries"."state" in ('pending', 'challenged', 'revealed', 'released', 'done', 'cancelled', 'declined', 'expired')),
	CONSTRAINT "guardian_recoveries_size_ck" CHECK (length("guardian_recoveries"."commit") between 32 and 128 and "guardian_recoveries"."key_version" >= 1)
);
--> statement-breakpoint
CREATE TABLE "key_backups_prf" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"family_id" uuid NOT NULL,
	"credential_id" text NOT NULL,
	"blob" text NOT NULL,
	"key_version" integer NOT NULL,
	"state" text DEFAULT 'pending' NOT NULL,
	"verified_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "key_backups_prf_state_ck" CHECK ("key_backups_prf"."state" in ('pending', 'active', 'stale', 'superseded')),
	CONSTRAINT "key_backups_prf_size_ck" CHECK (length("key_backups_prf"."blob") between 96 and 4096 and "key_backups_prf"."key_version" >= 1 and length("key_backups_prf"."credential_id") between 1 and 1024)
);
--> statement-breakpoint
ALTER TABLE "security_events" DROP CONSTRAINT "security_events_kind_ck";--> statement-breakpoint
ALTER TABLE "credentials" ADD COLUMN "device_type" text;--> statement-breakpoint
ALTER TABLE "credentials" ADD COLUMN "backed_up" boolean;--> statement-breakpoint
ALTER TABLE "guardian_escrows" ADD CONSTRAINT "guardian_escrows_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "guardian_escrows" ADD CONSTRAINT "guardian_escrows_family_id_child_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","child_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "guardian_escrows" ADD CONSTRAINT "guardian_escrows_family_id_guardian_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","guardian_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "guardian_recoveries" ADD CONSTRAINT "guardian_recoveries_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "guardian_recoveries" ADD CONSTRAINT "guardian_recoveries_family_id_child_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","child_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "key_backups_prf" ADD CONSTRAINT "key_backups_prf_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "key_backups_prf" ADD CONSTRAINT "key_backups_prf_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "guardian_escrows_current_uq" ON "guardian_escrows" USING btree ("child_id","guardian_id") WHERE "guardian_escrows"."state" in ('active', 'stale');--> statement-breakpoint
CREATE INDEX "guardian_escrows_guardian_idx" ON "guardian_escrows" USING btree ("guardian_id");--> statement-breakpoint
CREATE UNIQUE INDEX "guardian_recoveries_open_uq" ON "guardian_recoveries" USING btree ("child_id") WHERE "guardian_recoveries"."state" in ('pending', 'challenged', 'revealed', 'released');--> statement-breakpoint
CREATE INDEX "guardian_recoveries_child_idx" ON "guardian_recoveries" USING btree ("child_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "key_backups_prf_current_uq" ON "key_backups_prf" USING btree ("user_id","credential_id") WHERE "key_backups_prf"."state" in ('active', 'stale');--> statement-breakpoint
CREATE UNIQUE INDEX "key_backups_prf_pending_uq" ON "key_backups_prf" USING btree ("user_id") WHERE "key_backups_prf"."state" = 'pending';--> statement-breakpoint
CREATE INDEX "key_backups_prf_user_idx" ON "key_backups_prf" USING btree ("user_id");--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_kind_ck" CHECK ("security_events"."kind" in ('password_reset_requested', 'password_reset_done', 'account_reset_requested', 'key_rotated', 'key_backup_replaced', 'key_backup_read', 'key_backup_pw_read', 'key_backup_archive_read', 'recovery_code_login', 'key_transfer_created', 'key_transfer_claimed', 'member_account_reset', 'key_backup_prf_read', 'guardian_escrow_set', 'guardian_escrow_removed', 'guardian_recovery_requested', 'guardian_recovery_asked', 'guardian_recovery_challenged', 'guardian_recovery_released', 'guardian_recovery_ended', 'key_backup_prf_set'));