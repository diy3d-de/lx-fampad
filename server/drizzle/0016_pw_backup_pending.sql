ALTER TABLE "key_backups_pw" DROP CONSTRAINT "key_backups_pw_state_ck";--> statement-breakpoint
ALTER TABLE "key_backups_pw" ALTER COLUMN "state" SET DEFAULT 'pending';--> statement-breakpoint
CREATE UNIQUE INDEX "key_backups_pw_pending_uq" ON "key_backups_pw" USING btree ("user_id") WHERE "key_backups_pw"."state" = 'pending';--> statement-breakpoint
ALTER TABLE "key_backups_pw" ADD CONSTRAINT "key_backups_pw_state_ck" CHECK ("key_backups_pw"."state" in ('pending', 'active', 'stale', 'superseded'));