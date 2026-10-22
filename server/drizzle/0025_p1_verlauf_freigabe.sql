-- Wrap-ID v2 (PR 7 "Verlauf freigeben"): Schlüsselversion des Empfängers je Wrap. Rein additiv: bestehende Zeilen bekommen NULL (Altbestand und Wraps älterer Apps,
-- ID v1), die Eindeutigkeit gilt weiter je (Konversation, Epoche, Empfänger) und zusätzlich je Schlüsselversion (NULL zählt als 0). Die Anweisungen sind wiederholbar
-- (IF [NOT] EXISTS), damit Tests, die frühere Stände nachstellen, die Migration erneut anwenden können.
ALTER TABLE "epoche_wraps" ADD COLUMN IF NOT EXISTS "key_version" integer;--> statement-breakpoint
DROP INDEX IF EXISTS "epoche_wraps_uq";--> statement-breakpoint
CREATE UNIQUE INDEX "epoche_wraps_uq" ON "epoche_wraps" USING btree ("family_id","konversation_id","epoche","empfaenger_id",coalesce("key_version", 0)) WHERE "epoche_wraps"."deleted_at" is null;--> statement-breakpoint
ALTER TABLE "epoche_wraps" DROP CONSTRAINT IF EXISTS "epoche_wraps_key_version_ck";--> statement-breakpoint
ALTER TABLE "epoche_wraps" ADD CONSTRAINT "epoche_wraps_key_version_ck" CHECK ("epoche_wraps"."key_version" is null or "epoche_wraps"."key_version" between 1 and 1000000);
