CREATE TABLE "password_authkeys" (
	"credential_id" uuid PRIMARY KEY NOT NULL,
	"user_id" uuid NOT NULL,
	"auth_hash" text NOT NULL,
	"kdf_id" text DEFAULT 'argon2id-v1' NOT NULL,
	"salt_generation" integer DEFAULT 1 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "password_authkeys_hash_ck" CHECK (length("password_authkeys"."auth_hash") = 64),
	CONSTRAINT "password_authkeys_kdf_ck" CHECK ("password_authkeys"."kdf_id" in ('argon2id-v1') and "password_authkeys"."salt_generation" >= 1)
);
--> statement-breakpoint
ALTER TABLE "password_authkeys" ADD CONSTRAINT "password_authkeys_credential_id_credentials_id_fk" FOREIGN KEY ("credential_id") REFERENCES "public"."credentials"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "password_authkeys" ADD CONSTRAINT "password_authkeys_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "password_authkeys_user_idx" ON "password_authkeys" USING btree ("user_id");