CREATE TABLE "security_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"user_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"via" text NOT NULL,
	"actor_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "security_events_kind_ck" CHECK ("security_events"."kind" in ('password_reset_requested', 'password_reset_done', 'account_reset_requested')),
	CONSTRAINT "security_events_via_ck" CHECK ("security_events"."via" in ('admin', 'recovery_code', 'passkey'))
);
--> statement-breakpoint
ALTER TABLE "invites" ADD COLUMN "kind" text DEFAULT 'standard' NOT NULL;--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "security_events" ADD CONSTRAINT "security_events_actor_id_users_id_fk" FOREIGN KEY ("actor_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "security_events_user_idx" ON "security_events" USING btree ("user_id","created_at");--> statement-breakpoint
ALTER TABLE "invites" ADD CONSTRAINT "invites_kind_ck" CHECK ("invites"."kind" in ('standard', 'password_reset') and ("invites"."kind" = 'standard' or "invites"."user_id" is not null));