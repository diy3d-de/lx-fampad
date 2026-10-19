CREATE TYPE "public"."list_audience" AS ENUM('parents', 'family', 'all');--> statement-breakpoint
ALTER TABLE "list_items" ALTER COLUMN "position" SET DATA TYPE double precision;--> statement-breakpoint
ALTER TABLE "applied_ops" ADD COLUMN "status" text DEFAULT 'acked' NOT NULL;--> statement-breakpoint
ALTER TABLE "applied_ops" ADD COLUMN "code" text;--> statement-breakpoint
ALTER TABLE "applied_ops" ADD COLUMN "conflicts" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "change_log" ADD COLUMN "created" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "families" ADD COLUMN "purged_rev" bigint DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "lists" ADD COLUMN "audience" "list_audience" DEFAULT 'family' NOT NULL;--> statement-breakpoint
ALTER TABLE "lists" ADD COLUMN "owner_id" uuid;--> statement-breakpoint
ALTER TABLE "lists" ADD CONSTRAINT "lists_owner_id_users_id_fk" FOREIGN KEY ("owner_id") REFERENCES "public"."users"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "change_log_tombstone_idx" ON "change_log" USING btree ("family_id","rev") WHERE "change_log"."tombstone";--> statement-breakpoint
CREATE INDEX "list_items_tombstone_idx" ON "list_items" USING btree ("family_id","rev") WHERE "list_items"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "list_items_assignee_idx" ON "list_items" USING btree ("family_id","assignee_id") WHERE "list_items"."assignee_id" is not null;--> statement-breakpoint
CREATE INDEX "lists_tombstone_idx" ON "lists" USING btree ("family_id","rev") WHERE "lists"."deleted_at" is not null;--> statement-breakpoint
CREATE INDEX "lists_owner_idx" ON "lists" USING btree ("family_id","owner_id") WHERE "lists"."owner_id" is not null;--> statement-breakpoint
ALTER TABLE "applied_ops" ADD CONSTRAINT "applied_ops_status_ck" CHECK ("applied_ops"."status" in ('acked', 'rejected'));--> statement-breakpoint
ALTER TABLE "list_items" ADD CONSTRAINT "list_items_text_len_ck" CHECK (char_length("list_items"."text") <= 500);--> statement-breakpoint
ALTER TABLE "list_items" ADD CONSTRAINT "list_items_position_ck" CHECK ("list_items"."position" between -1e12 and 1e12);--> statement-breakpoint
ALTER TABLE "lists" ADD CONSTRAINT "lists_name_len_ck" CHECK (char_length("lists"."name") <= 100);