CREATE TABLE IF NOT EXISTS "ingest_postfach_transfers" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"lookup_hash" text NOT NULL,
	"blob" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	CONSTRAINT "ingest_postfach_transfers_lookup_hash_unique" UNIQUE("lookup_hash"),
	CONSTRAINT "ingest_postfach_transfers_blob_ck" CHECK (char_length("ingest_postfach_transfers"."blob") between 32 and 1024)
);
--> statement-breakpoint
ALTER TABLE "ingest_postfach_transfers" DROP CONSTRAINT IF EXISTS "ingest_postfach_transfers_user_id_users_id_fk";--> statement-breakpoint
ALTER TABLE "ingest_postfach_transfers" ADD CONSTRAINT "ingest_postfach_transfers_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;