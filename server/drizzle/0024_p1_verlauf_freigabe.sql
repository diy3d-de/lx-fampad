-- Wrap-ID v2 (PR 7 "Verlauf freigeben"): Schlüsselversion des Empfängers je Wrap. Rein additiv: bestehende Zeilen bekommen NULL (Altbestand und Wraps älterer Apps,
-- ID v1). Für Wraps ohne Version gilt die Eindeutigkeit je (Konversation, Epoche, Empfänger) wie bisher; Wraps mit Version (ID v2) enthalten den Verteiler in ihrer ID
-- (Primärschlüssel), sodass jeder Verteiler seinen eigenen Platz hat. Die Anweisungen sind wiederholbar (IF [NOT] EXISTS), damit Tests, die frühere Stände nachstellen,
-- die Migration erneut anwenden können.
ALTER TABLE "epoche_wraps" ADD COLUMN IF NOT EXISTS "key_version" integer;--> statement-breakpoint
DROP INDEX IF EXISTS "epoche_wraps_uq";--> statement-breakpoint
CREATE UNIQUE INDEX "epoche_wraps_uq" ON "epoche_wraps" USING btree ("family_id","konversation_id","epoche","empfaenger_id") WHERE "epoche_wraps"."deleted_at" is null and "epoche_wraps"."key_version" is null;--> statement-breakpoint
ALTER TABLE "epoche_wraps" DROP CONSTRAINT IF EXISTS "epoche_wraps_key_version_ck";--> statement-breakpoint
ALTER TABLE "epoche_wraps" ADD CONSTRAINT "epoche_wraps_key_version_ck" CHECK ("epoche_wraps"."key_version" is null or "epoche_wraps"."key_version" between 1 and 1000000);
