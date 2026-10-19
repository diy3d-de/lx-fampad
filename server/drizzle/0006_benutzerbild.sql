CREATE TABLE "user_avatars" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"content_type" text NOT NULL,
	"width" integer NOT NULL,
	"height" integer NOT NULL,
	"data" "bytea" NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "user_avatars_type_ck" CHECK ("user_avatars"."content_type" in ('image/png', 'image/jpeg', 'image/webp')),
	CONSTRAINT "user_avatars_size_ck" CHECK (octet_length("user_avatars"."data") between 1 and 524288 and "user_avatars"."width" between 1 and 1024 and "user_avatars"."height" between 1 and 1024)
);
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "avatar_kind" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "avatar_preset" text;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "avatar_version" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "user_avatars" ADD CONSTRAINT "user_avatars_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_avatar_ck" CHECK (("users"."avatar_kind" is null and "users"."avatar_preset" is null) or ("users"."avatar_kind" = 'preset' and "users"."avatar_preset" is not null) or ("users"."avatar_kind" = 'photo' and "users"."avatar_preset" is null));