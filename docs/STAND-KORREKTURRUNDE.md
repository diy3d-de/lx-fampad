# Stand der Korrekturrunde (Sync-Kern, Branch phase-1c-sync)

Zwischenstand, WIP. Es wurde noch kein Produktivcode geändert; bisher nur Analyse.

## Erledigt
- Keine Punkte umgesetzt (Nummern 1-9 der Aufgabe sind alle offen).
- Vorbereitung: portable PostgreSQL 17 (UTF8) mit Daten C:\lxq\pgdata13 initialisiert, Port 54349, Datenbank lx_test (TEST_DATABASE_URL=postgres://postgres@127.0.0.1:54349/lx_test). Start: pg_ctl aus C:\lxq\pgb\node_modules\@embedded-postgres\windows-x64\native\bin.

## Offen (alle Punkte 1-9)
Entwurf aus der Analyse:
1. Snapshot-Cursor: Request-Feld `snapshotRev` (Ziel-rev, beim Start = family.rev), Antwort liefert `snapshotRev`, solange der Snapshot läuft. Folgeseiten (sinceRev>0, snapshotRev>sinceRev) prüfen nie gegen purged_rev, filtern `rev <= snapshotRev`, senden keine Tombstones/hidden. Letzte Seite: hasMore=true, next=snapshotRev, wenn family.rev größer ist, danach normaler Delta-Lauf. devices.last_rev bei Folgeseiten nicht fortschreiben. Client: Meta `snapshotRev` speichern, mitsenden, bei resync löschen.
2. Geisterliste: in pull.ts hidden-Tombstone für unsichtbare Zeilen mit deleted_at (nur neuester Eintrag, sinceRev>0, nicht im Snapshot); Rollenwechsel/Mitglied entfernen: neue Spalte devices.resync_required (Migration 0003), Sync-Route antwortet resync_required, Flag wird bei sinceRev=0 geleert (nur wenn Rolle unverändert).
3. applied_ops: MAX_OPS=50; Token-Bucket je Gerät und Person (Ops und Anfragen, Config SYNC_OPS_BURST/PER_MINUTE usw., 429 mit Retry-After), Tagesobergrenze je Gerät über applied_ops (Index device_id, created_at), abgelehnte Ops nur 7 Tage, Konfliktwerte nicht mehr speichern (nur Feldnamen + entity/entity_id; bei Wiederholung Rechte neu prüfen und aktuelle Werte liefern), lock_timeout/statement_timeout in applyOp (55P03 -> 503). Datenschutz-Entwurf anpassen.
4. id_taken -> not_found; hidden-Metadaten-Leck (nie sichtbare gelöschte IDs) in Doku/SPÄTER; WS-rev nur an Rollen, die die Änderung sehen (onRev mit Rollenliste, Outcome mit Audiences).
5-8. App: vordergrund(false) vorher synchronisieren() bei offenem Ausgang; stoppen()/starten() setzt state/_bekannteRev zurück, nach sitzungVerloren stoppen(), eigener rev-Hinweis während Lauf ignorieren; sync_store: Verschmelzen nur bei gleicher baseRev, geraetZuordnen stellt offline angelegte Zeilen wieder her, loeschen nurLokal nur ohne je vorhandene Op, Stream-Fehler anzeigen, SyncIndicator mounted-Prüfung; Dialog „Neue Liste“ Fokus/Tab-Reihenfolge.
9. Tests zu allen Punkten, docs/API.md, DATENSCHUTZ-ENTWURF, PROJEKTBESCHREIBUNG 6a, CLAUDE.md; volle Prüfung (typecheck, lint, test mehrfach, build, flutter analyze/test/web build, web-assets.sha256, Vertragstest, Browser-Prüfung, node --test tools).

## Nächster Schritt
Server zuerst: Migration 0003 (schema.ts + db:generate in C:\lxq\ws), pull.ts (Snapshot-Cursor, hidden), routes/sync.ts, engine.ts, limits.ts, Tests; danach App-Teile 5-8, Doku, Gesamtprüfung.
