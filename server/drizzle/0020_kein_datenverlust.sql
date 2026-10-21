CREATE TABLE "key_backup_archive" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"kind" text DEFAULT 'recovery' NOT NULL,
	"blob" text NOT NULL,
	"key_version" integer NOT NULL,
	"reason" text NOT NULL,
	"backup_created_at" timestamp with time zone NOT NULL,
	"backup_updated_at" timestamp with time zone NOT NULL,
	"archived_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "key_backup_archive_kind_ck" CHECK ("key_backup_archive"."kind" in ('recovery')),
	CONSTRAINT "key_backup_archive_reason_ck" CHECK ("key_backup_archive"."reason" in ('rotation', 'replaced')),
	CONSTRAINT "key_backup_archive_version_ck" CHECK ("key_backup_archive"."key_version" >= 1)
);
--> statement-breakpoint
ALTER TABLE "security_events" DROP CONSTRAINT "security_events_kind_ck";--> statement-breakpoint
ALTER TABLE "security_events" DROP CONSTRAINT "security_events_via_ck";--> statement-breakpoint
ALTER TABLE "security_events" ADD COLUMN "subject_id" uuid;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "origin" text DEFAULT 'login' NOT NULL;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "origin_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "key_backup_archive" ADD CONSTRAINT "key_backup_archive_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "key_backup_archive_user_idx" ON "key_backup_archive" USING btree ("user_id","archived_at");--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_subject_id_users_id_fk" FOREIGN KEY ("subject_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_kind_ck" CHECK ("security_events"."kind" in ('password_reset_requested', 'password_reset_done', 'account_reset_requested', 'key_rotated', 'key_backup_read', 'key_backup_pw_read', 'key_backup_archive_read', 'recovery_code_login', 'key_transfer_created', 'key_transfer_claimed', 'member_account_reset'));--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_via_ck" CHECK ("security_events"."via" in ('admin', 'recovery_code', 'passkey', 'password'));--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_origin_ck" CHECK ("sessions"."origin" in ('login', 'recovery_code', 'password_reset'));