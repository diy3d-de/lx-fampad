CREATE TABLE "key_backups" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"blob" text NOT NULL,
	"key_version" integer NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "key_transfers" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"lookup_hash" text NOT NULL,
	"blob" text NOT NULL,
	"key_version" integer NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	CONSTRAINT "key_transfers_lookup_hash_unique" UNIQUE("lookup_hash")
);
--> statement-breakpoint
CREATE TABLE "person_key_history" (
	"user_id" uuid NOT NULL,
	"key_version" integer NOT NULL,
	"enc_key" text NOT NULL,
	"sign_key" text NOT NULL,
	"valid_from" timestamp with time zone NOT NULL,
	"valid_until" timestamp with time zone NOT NULL,
	CONSTRAINT "person_key_history_user_id_key_version_pk" PRIMARY KEY("user_id","key_version")
);
--> statement-breakpoint
CREATE TABLE "person_keys" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"public_enc_key" text NOT NULL,
	"public_sign_key" text NOT NULL,
	"key_version" integer DEFAULT 1 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "person_keys_version_pos" CHECK ("person_keys"."key_version" >= 1)
);
--> statement-breakpoint
ALTER TABLE "key_backups" ADD CONSTRAINT "key_backups_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "key_transfers" ADD CONSTRAINT "key_transfers_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "person_key_history" ADD CONSTRAINT "person_key_history_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "person_keys" ADD CONSTRAINT "person_keys_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;