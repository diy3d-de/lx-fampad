ALTER TABLE "applied_ops" ADD COLUMN "entity" text;--> statement-breakpoint
ALTER TABLE "applied_ops" ADD COLUMN "entity_id" uuid;--> statement-breakpoint
ALTER TABLE "devices" ADD COLUMN "resync_required" boolean DEFAULT false NOT NULL;--> statement-breakpoint
CREATE INDEX "applied_ops_device_idx" ON "applied_ops" USING btree ("device_id","created_at");--> statement-breakpoint
-- Konfliktwerte werden nicht mehr gespeichert: bestehende Einträge behalten nur die Feldnamen.
UPDATE "applied_ops" SET "conflicts" = COALESCE((SELECT jsonb_agg(jsonb_build_object('fields', (SELECT COALESCE(jsonb_agg(k), '[]'::jsonb) FROM jsonb_object_keys(c->'fields') AS k), 'serverRev', c->'serverRev')) FROM jsonb_array_elements("conflicts") AS c), '[]'::jsonb) WHERE "conflicts" <> '[]'::jsonb;
