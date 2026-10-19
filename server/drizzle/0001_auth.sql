CREATE TYPE "public"."member_status" AS ENUM('active', 'pending');--> statement-breakpoint
CREATE TABLE "login_attempts" (
	"key" text PRIMARY KEY NOT NULL,
	"fail_count" integer DEFAULT 0 NOT NULL,
	"window_started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_failed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"locked_until" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "webauthn_challenges" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"purpose" text NOT NULL,
	"challenge" text NOT NULL,
	"user_id" uuid,
	"data" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ws_tickets" (
	"token_hash" text PRIMARY KEY NOT NULL,
	"family_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"session_id" uuid NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "devices" DROP CONSTRAINT "devices_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "event_attendees" DROP CONSTRAINT "event_attendees_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "message_reactions" DROP CONSTRAINT "message_reactions_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "message_reads" DROP CONSTRAINT "message_reads_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "sessions" DROP CONSTRAINT "sessions_user_id_users_id_fk";
--> statement-breakpoint
-- Der eindeutige Index wird zur Constraint (Ziel der zusammengesetzten Fremdschlüssel); sie muss vor den Fremdschlüsseln stehen.
DROP INDEX "memberships_family_user_uq";--> statement-breakpoint
ALTER TABLE "memberships" ADD CONSTRAINT "memberships_family_user_uq" UNIQUE("family_id","user_id");--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "revoked_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "user_id" uuid;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "pin_hash" text;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "pin_attempts" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "locked_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "revoked_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "require_approval" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "expired_logged_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "memberships" ADD COLUMN "status" "member_status" DEFAULT 'active' NOT NULL;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "kind" text DEFAULT 'web' NOT NULL;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "auth_method" text DEFAULT 'passkey' NOT NULL;--> statement-breakpoint
ALTER TABLE "sessions" ADD COLUMN "step_up_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "webauthn_challenges" ADD CONSTRAINT "webauthn_challenges_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ws_tickets" ADD CONSTRAINT "ws_tickets_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ws_tickets" ADD CONSTRAINT "ws_tickets_session_id_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ws_tickets" ADD CONSTRAINT "ws_tickets_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "login_attempts_last_failed_idx" ON "login_attempts" USING btree ("last_failed_at");--> statement-breakpoint
CREATE INDEX "webauthn_challenges_expires_idx" ON "webauthn_challenges" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "ws_tickets_expires_idx" ON "ws_tickets" USING btree ("expires_at");--> statement-breakpoint
ALTER TABLE "devices" ADD CONSTRAINT "devices_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "event_attendees" ADD CONSTRAINT "event_attendees_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "invites" ADD CONSTRAINT "invites_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_reactions" ADD CONSTRAINT "message_reactions_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "message_reads" ADD CONSTRAINT "message_reads_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_family_id_user_id_memberships_family_id_user_id_fk" FOREIGN KEY ("family_id","user_id") REFERENCES "public"."memberships"("family_id","user_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "audit_log_created_idx" ON "audit_log" USING btree ("created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "credentials_single_active_uq" ON "credentials" USING btree ("user_id","type") WHERE "credentials"."type" in ('password', 'totp') and "credentials"."revoked_at" is null;--> statement-breakpoint
ALTER TABLE "invites" ADD CONSTRAINT "invites_pin_attempts_ck" CHECK ("invites"."pin_attempts" >= 0);--> statement-breakpoint
ALTER TABLE "sessions" ADD CONSTRAINT "sessions_kind_ck" CHECK ("sessions"."kind" in ('web', 'app'));