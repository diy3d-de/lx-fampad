CREATE TABLE IF NOT EXISTS "ingest_inbox" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"seq" bigint GENERATED ALWAYS AS IDENTITY (sequence name "ingest_inbox_seq_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"family_id" uuid NOT NULL,
	"token_id" uuid NOT NULL,
	"k" text NOT NULL,
	"box" "bytea" NOT NULL,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "ingest_inbox_token_k_unique" UNIQUE("token_id","k"),
	CONSTRAINT "ingest_inbox_seq_unique" UNIQUE("seq"),
	CONSTRAINT "ingest_inbox_k_ck" CHECK (char_length("ingest_inbox"."k") between 1 and 64),
	CONSTRAINT "ingest_inbox_box_ck" CHECK (octet_length("ingest_inbox"."box") between 1 and 1024)
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "ingest_tokens" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"family_id" uuid NOT NULL,
	"name" text NOT NULL,
	"token_hash" text NOT NULL,
	"created_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_used_at" timestamp with time zone,
	"revoked_at" timestamp with time zone,
	CONSTRAINT "ingest_tokens_family_id_unique" UNIQUE("family_id","id"),
	CONSTRAINT "ingest_tokens_hash_unique" UNIQUE("token_hash"),
	CONSTRAINT "ingest_tokens_name_ck" CHECK (char_length("ingest_tokens"."name") between 1 and 40)
);
--> statement-breakpoint
ALTER TABLE "ingest_inbox" DROP CONSTRAINT IF EXISTS "ingest_inbox_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "ingest_inbox" ADD CONSTRAINT "ingest_inbox_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ingest_inbox" DROP CONSTRAINT IF EXISTS "ingest_inbox_token_fk";--> statement-breakpoint
ALTER TABLE "ingest_inbox" ADD CONSTRAINT "ingest_inbox_token_fk" FOREIGN KEY ("family_id","token_id") REFERENCES "public"."ingest_tokens"("family_id","id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ingest_tokens" DROP CONSTRAINT IF EXISTS "ingest_tokens_family_id_families_id_fk";--> statement-breakpoint
ALTER TABLE "ingest_tokens" ADD CONSTRAINT "ingest_tokens_family_id_families_id_fk" FOREIGN KEY ("family_id") REFERENCES "public"."families"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ingest_tokens" DROP CONSTRAINT IF EXISTS "ingest_tokens_created_by_users_id_fk";--> statement-breakpoint
ALTER TABLE "ingest_tokens" ADD CONSTRAINT "ingest_tokens_created_by_users_id_fk" FOREIGN KEY ("created_by") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "ingest_inbox_family_seq_idx" ON "ingest_inbox" USING btree ("family_id","seq");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "ingest_inbox_received_idx" ON "ingest_inbox" USING btree ("received_at");