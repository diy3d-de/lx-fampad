# API (Phase 1a bis 1c: Konten, Anmeldung, Sync)

Stand: Phase 1c-4a (Sync-Kern mit Listen, Kalender: Termine, Teilnehmer, Ausnahmen, und Aufgaben mit Unteraufgaben; Konten und Anmeldung seit 1a/1b). Basis: `https://familie.lx-labs.dev/api/v1`, REST mit JSON (`Content-Type: application/json`). Der Sync (`POST /sync`) ist im Abschnitt „Sync“ beschrieben; Chat und Dateien kommen als weitere Entitäten dazu. Diese Beschreibung ist Markdown statt OpenAPI; die Validierung steckt in den Zod-Schemas in
`server/src/routes/` (jedes Objekt ist `strict`: unbekannte Felder führen zu `400`).

## Allgemeines

**Fehlerformat** (nie interne Meldungen, kein Stacktrace; Details nur im Server-Log):

```json
{ "error": "invalid_credentials", "message": "Die Anmeldedaten sind nicht korrekt." }
```

| Status | Bedeutung |
| --- | --- |
| 400 | ungültige Eingabe (`invalid_request`, generisch) oder fachlich abgelehnt (`invite_invalid`, `weak_password`, `challenge_invalid`, `invalid_code`, `registration_failed`) |
| 401 | nicht angemeldet (`unauthenticated`), Anmeldedaten falsch (`invalid_credentials`, immer dieselbe Antwort, egal ob das Konto existiert), `invalid_token` (Refresh), `step_up_failed` |
| 403 | `forbidden`, `csrf_invalid`, `origin_not_allowed`, `step_up_required`, `account_pending` |
| 404 | nicht gefunden (`not_found`, auch für Objekte einer fremden Familie) |
| 409 | Konflikt (`last_admin`, `last_credential`, `invite_not_open`, `registration_failed`, `no_passkey`, `passkey_exists`, `password_exists`, `no_password`, `not_pending`, `cannot_remove_self`, `device_mismatch`, ...) |
| 413 / 415 | Body zu groß (`payload_too_large`, beim Sync über 1 MB) / kein JSON (`unsupported_media_type`) |
| 426 | `update_required`: die Protokollversion des Clients ist zu alt (nur `/sync`); die App zeigt die Pflicht-Update-Seite |
| 429 | Rate-Limit (`rate_limited`) oder verzögerte Sperre nach Fehlversuchen (`too_many_attempts`, Header `Retry-After` in Sekunden) |
| 500 | `internal_error` (nie mit Details; die stehen nur im Server-Log) |
| 503 | `server_busy` (Passwort-Berechnung ausgelastet, Header `Retry-After`) |

**Fehlercodes im Einzelnen** (`error` im Antwortkörper; die App zeigt nie den `message`-Text, sondern eigene deutsche Meldungen je Code):

| Code | Status | Wann |
| --- | --- | --- |
| `invalid_request` | 400 | Eingabe ungültig (Zod-Schema, unbekannte Felder, NUL/Surrogate) |
| `invite_invalid` | 400 | Einladung unbekannt, benutzt, widerrufen, gesperrt, abgelaufen oder PIN falsch (immer dieselbe Antwort) |
| `weak_password` | 400 | Passwort kürzer als die Mindestlänge (12) |
| `challenge_invalid` | 400 | Challenge unbekannt, abgelaufen oder schon benutzt |
| `invalid_code` | 400 | TOTP-Bestätigung bei der Registrierung bzw. beim nachträglichen Einrichten von Passwort + TOTP falsch |
| `registration_failed` | 400 / 409 | Registrierung mit diesen Angaben nicht möglich (z. B. E-Mail schon vergeben; keine Auskunft, warum) |
| `unauthenticated` | 401 | keine gültige Sitzung (kein/ungültiges Cookie oder Access-Token) |
| `invalid_token` | 401 | Refresh-Token ungültig, abgelaufen, widerrufen oder wiederverwendet |
| `invalid_credentials` | 401 | Anmeldung fehlgeschlagen (Konto unbekannt, Passwort/Code falsch, Konto gesperrt; ohne Unterschied) |
| `step_up_failed` | 401 | erneute Bestätigung (Step-up) falsch. **Kein Sitzungsende**: die Sitzung bleibt gültig, der Versuch zählt gegen die Sperre; Clients dürfen ihn nicht wiederholen und das Token nicht erneuern |
| `forbidden` | 403 | Rolle reicht nicht oder Objekt gehört nicht zur Familie |
| `csrf_invalid` / `origin_not_allowed` | 403 | CSRF-Header fehlt/falsch bzw. fremder `Origin` (nur Cookie-Sitzungen) |
| `step_up_required` | 403 | Bestätigung älter als 5 Minuten; dann `/auth/step-up/*`, danach wiederholen |
| `account_pending` | 403 | Konto wartet auf die Freigabe. Bei der Passwort- und Wiederherstellungs-Anmeldung **erst nach erfolgreicher Prüfung** von Passwort und zweitem Faktor (kein Rückschluss ohne gültige Anmeldedaten); dabei wird nichts verbraucht |
| `not_found` | 404 | Objekt unbekannt oder fremd |
| `last_admin` | 409 | der letzte Admin kann nicht herabgestuft oder entfernt werden |
| `last_credential` | 409 | der letzte Zugang einer Person kann nicht entfernt werden |
| `no_passkey` | 409 | Step-up per Passkey, aber die Person hat keinen Passkey |
| `passkey_exists` | 409 | dieser Authenticator ist schon als Passkey eingerichtet |
| `password_exists` | 409 | für das Konto gibt es schon ein Passwort (stattdessen ändern) |
| `no_password` | 409 | für das Konto ist kein Passwort eingerichtet (ändern/entfernen nicht möglich) |
| `not_pending` | 409 | freigeben/ablehnen, aber das Mitglied wartet nicht auf Freigabe |
| `cannot_remove_self` | 409 | Admin will sich selbst entfernen |
| `device_mismatch` | 409 | `/sync`: die `deviceId` im Körper passt nicht zur Sitzung (die App lädt `/me` neu und versucht es erneut) |
| `update_required` | 426 | `/sync`: `protocolVersion` kleiner als `minProtocolVersion` (`GET /version`) |
| `invite_not_open` | 409 | widerrufen/verlängern, aber die Einladung ist nicht (mehr) offen |
| `multiple_families` / `already_bootstrapped` | 409 | nur beim Einrichten per CLI (`npm run bootstrap`), nicht über die HTTP-API: mehr als eine Familie vorhanden bzw. Familie schon eingerichtet |
| `rate_limited` / `too_many_attempts` | 429 | Rate-Limit bzw. verzögerte Sperre; `Retry-After` in Sekunden |
| `server_busy` | 503 | Passwort-Berechnung ausgelastet (es wird kein Fehlversuch gezählt) bzw. beim Sync: die Familie ist gerade gesperrt oder die Anweisung lief zu lange (`Retry-After`, nichts wurde geändert) |
| `internal_error` | 500 | unerwarteter Fehler |

**Sitzungsende aus Sicht der App:** Nur `401 unauthenticated` und `401 invalid_token` bedeuten, dass die Sitzung ungültig ist (die App erneuert dann einmal bzw. meldet ab). Alle anderen 401-Fachcodes (`step_up_failed`, `invalid_credentials`) beenden die Sitzung nicht und werden nicht wiederholt.

Antworten der API tragen `Cache-Control: no-store`.

**Anmeldearten und Sitzungen**

- **Web (Cookie):** Nach der Anmeldung setzt der Server `__Host-lxsid=<Token>; Path=/; Secure; HttpOnly; SameSite=Strict` (kein `Domain`). Die Antwort enthält
  `session.csrfToken`; **jede ändernde Anfrage (POST, PUT, PATCH, DELETE)** mit Cookie muss es im Header `X-CSRF-Token` mitsenden (sonst `403 csrf_invalid`).
  Zusätzlich wird ein fremder `Origin`-Header bei ändernden Anfragen abgelehnt (`403 origin_not_allowed`). `GET /me` liefert das Token erneut (nach einem Neuladen).
  Cookie-Sitzung: 30 Tage absolut, 7 Tage Leerlauf.
- **App (Token):** Anmeldung mit `client: "app"` und `device`. Antwort: `accessToken` (15 min, `Authorization: Bearer <accessToken>`, kein CSRF-Header nötig),
  `refreshToken` (einmal einlösbar, 90 Tage absolut, 30 Tage Leerlauf) und `deviceId`. `POST /auth/refresh` tauscht das Refresh-Token gegen ein neues Paar (Rotation).
  Wird ein bereits eingelöstes Refresh-Token erneut vorgelegt (auch gleichzeitig), widerruft der Server die **ganze Token-Familie** und schreibt `session_reuse_detected` ins Audit-Log.
  **Ausnahme: Wiederholung im Toleranzfenster** (verlorene Antwort), siehe unten.
  Ein vorhandener, aber ungültiger `Authorization`-Header fällt nie auf das Cookie zurück.
- **Step-up:** Die Anmeldung zählt als frische Bestätigung. Wiederverwendbare Prüfung (`requireStepUp`, 5 Minuten): Rollenänderung, Mitglied entfernen/zurücksetzen,
  Admin-Einladung erzeugen, neuen Passkey hinzufügen/entfernen, Wiederherstellungs-Codes neu erzeugen (später: Tresor, Familie löschen). Ist die Bestätigung älter,
  antwortet der Server mit `403 step_up_required`; die Bestätigung erfolgt über `/auth/step-up/*`.

**Wiederholung des Refresh-Tokens (Toleranzfenster).** Geht die Antwort auf `POST /auth/refresh` unterwegs verloren (Funkloch nach dem Senden), kennt die App das neue Paar nicht, das alte Token ist aber schon eingelöst. Damit daraus kein Widerruf der Familie wird, bedient der Server eine Wiederholung, wenn **alle** Bedingungen gelten:

1. höchstens **30 Sekunden** seit dem Einlösen (festes Fenster ab dem ersten Einlösen, kein gleitendes; Konstante `refreshGraceSec` in `server/src/config.ts`),
2. **dieselbe `deviceId`** wie beim Einlösen (sie liegt nur auf dem Gerät),
3. die **Nachfolgerin ist noch unbenutzt** (nicht eingelöst, nicht widerrufen).

Dann widerruft der Server die erste, nie angekommene Nachfolgerin und stellt **genau ein** neues Paar aus (immer nur ein lebender Nachfolger je Familie; Audit-Ereignis `session_refresh_retry`). Mehrfache und gleichzeitige Wiederholungen im Fenster sind erlaubt und werden nacheinander bedient (Zeilensperre); es bleibt bei einem lebenden Nachfolger. Alles andere bleibt **echte Wiederverwendung** und widerruft die ganze Familie: Wiederholung nach mehr als 30 Sekunden, von einer anderen `deviceId`, oder nachdem die Nachfolgerin schon benutzt wurde. Das Fenster ersetzt kein Wiederholen auf Verdacht: Die App sendet ein Refresh-Token nur dann erneut, wenn sicher ist, dass die Anfrage den Server nie erreichte (Fehler beim Verbindungsaufbau); bei unklarem Ausgang meldet sie ab. Sicherheitsbetrachtung: PROJEKTBESCHREIBUNG.md, Abschnitt 7.

**Rate-Limits:** 300 Anfragen/min je IP insgesamt; `/auth/*`, `/ws-ticket`, `/invites` (POST), `/members/:id/reset`, `PUT /me/family-role`, `PUT /members/:id/family-role` und `/me/passkeys/*` strenger (10/min); `POST /sync` 120/min je IP (`SYNC_RATE_LIMIT_MAX`) und zusätzlich je Gerät und Person (Abschnitt „Sync“, Limits). Zusätzlich zählt der Server
Fehlversuche (Passwort, TOTP, Wiederherstellungs-Code, Step-up) je **IP**, je **Konto** und je **Paar aus Konto und IP** und sperrt verzögert: Konto+IP ab 5, IP ab 20, Konto ab 10 Fehlversuchen
30 s, danach doppelt so lang, **höchstens 90 s** (so lässt sich ein fremdes Konto nicht lange aussperren; die tippende IP ist früher dran als das Konto). Anmeldung und Step-up teilen sich denselben Konto-Schlüssel.
**Passkey-Anmeldungen hängen nicht an der Konto-Sperre** (nur IP-Sperre). IPv6-Adressen gelten als **/64-Präfix** (IP-Sperre, Rate-Limit, Verbindungslimit am WebSocket); IPv4-in-IPv6 als IPv4.
WebSocket-Anmeldefehler zählen mit. Die Erzeugung von Challenges ohne Anmeldung (`/auth/login/passkey/options`, Start der Registrierung) ist je IP-Präfix (20) und insgesamt (2000 offene) begrenzt, sonst `429 rate_limited`.

**Eingaben:** Zeichenketten mit NUL (`\u0000`) oder einzelnen Surrogaten (`\ud800`) werden überall (auch verschachtelt und in Schlüsseln) mit `400 invalid_request` abgelehnt.
**Überlast:** Sind alle Passwort-Berechnungen (Argon2id, 2 gleichzeitig) und die Warteschlange (16) belegt, antwortet der Server `503 server_busy` mit `Retry-After` (kein Fehlversuch wird gezählt).

**Rollen:** `admin`, `parent`, `child`. Die frühere Rolle `guest` (Gast) gibt es seit Migration 0005 nicht mehr; Zugriff haben nur eingeladene Familienmitglieder. Eine Einladung mit `role: "guest"` ergibt `400 invalid_request`. Alle Zugriffe sind auf die eigene Familie begrenzt; Objekte einer fremden Familie liefern `404`.

## Einladung einlösen (ohne Anmeldung)

Das Token steht im Einladungslink im **URL-Fragment** (`https://familie.lx-labs.dev/#/einladung/<token>`) und wird von der App nur im **POST-Body** gesendet.

| Methode, Pfad | Body | Antwort |
| --- | --- | --- |
| `POST /auth/invites/lookup` | `{ token }` | `{ invite: { role, pinRequired, requireApproval, familyName, reset, displayName?, expiresAt } }`; jeder ungültige Fall (unbekannt, benutzt, widerrufen, gesperrt, abgelaufen) ergibt dieselbe `400 invite_invalid` |
| `POST /auth/invites/passkey/options` | `{ token, pin?, email?, displayName? }` | `{ challengeId, options }` (WebAuthn-Registrierungsoptionen, Challenge serverseitig, 5 min) |
| `POST /auth/invites/passkey/complete` | `{ challengeId, response, client?, device?, label? }` | `{ member, status, recoveryCodes[10], session? }` |
| `POST /auth/invites/password/start` | `{ token, pin?, email?, displayName?, password }` | `{ challengeId, totpSecret, totpUri }` (noch kein Konto; Passwort mindestens 12 Zeichen) |
| `POST /auth/invites/password/complete` | `{ challengeId, code, client?, device? }` | wie oben; `code` = 6-stelliger TOTP-Code aus der Authenticator-App |

- Bei Einladungen zum **Zurücksetzen** (`reset: true`) entfallen `email` und `displayName`.
- `status: "pending"`: Das Konto wartet auf die Freigabe durch einen Admin; es gibt keine Sitzung und die Anmeldung antwortet `403 account_pending`.
- `recoveryCodes` (10 Stück, Format `XXXX-XXXX-XXXX-XXXX`) erscheinen **nur hier** im Klartext.
- **PIN:** Jeder Versuch wird vor dem Vergleich gezählt; nach 5 Fehlversuchen ist die Einladung gesperrt (auch mit richtiger PIN). Antwort immer `400 invite_invalid`.
- `client`: `"web"` (Standard, setzt das Cookie) oder `"app"` (Tokens im Body). `device`: `{ id?, name, platform: android|ios|web|windows|linux|macos, appVersion? }`.

## Anmeldung (ohne Anmeldung)

| Methode, Pfad | Body | Antwort |
| --- | --- | --- |
| `POST /auth/login/passkey/options` | `{}` | `{ challengeId, options }` (ohne Kontoangabe: auffindbare Passkeys, `userVerification: required`) |
| `POST /auth/login/passkey/verify` | `{ challengeId, response, client?, device? }` | `{ user, session }`; geprüft werden Challenge, Origin, RP-ID, Nutzerprüfung, Signatur und `signCount` (Rückgang = abgelehnt und `passkey_counter_regression` im Audit-Log) |
| `POST /auth/login/password` | `{ email, password, totp \| recoveryCode, client?, device? }` | `{ user, session }`; **Passwort nur mit zweitem Faktor**; ein TOTP-Zeitschritt gilt nur einmal (Replay-Schutz). Der zweite Faktor wird erst nach der Statusprüfung (aktiv, nicht gesperrt) und gemeinsam mit der Sitzungserstellung in einer Transaktion verbraucht: bei `account_pending` und bei gesperrten Konten bleibt Code bzw. Zeitschritt unverändert |
| `POST /auth/login/recovery` | `{ email, code, client?, device? }` | `{ user, session, recoveryCodesRemaining }`; Einmal-Code, Sitzung gilt als frisch bestätigt; verbraucht wird der Code nur bei aktivem Konto (pending: `403 account_pending` nach gültigem Code, nichts verbraucht; gesperrt: `401 invalid_credentials`) |
| `POST /auth/refresh` | `{ refreshToken, deviceId }` | `{ session }` (neues Token-Paar); Gerät muss zum Token passen |

`session` (Web): `{ kind: "web", csrfToken, expiresAt, deviceId }` + Cookie. `session` (App): `{ kind: "app", accessToken, accessExpiresAt, refreshToken, refreshExpiresAt, deviceId }`.

## Angemeldet

| Methode, Pfad | Rolle | Body / Antwort |
| --- | --- | --- |
| `POST /auth/logout` | alle | meldet das aktuelle Gerät ab (Cookie wird gelöscht); ohne Sitzung ein No-op |
| `POST /auth/logout-all` | alle | alle Sitzungen und Geräte der Person |
| `POST /auth/step-up/passkey/options` | alle | `{ challengeId, options }` (nur die eigenen Passkeys) |
| `POST /auth/step-up/passkey/verify` | alle | `{ challengeId, response }` → `{ stepUpAt }` |
| `POST /auth/step-up/code` | alle | `{ totp }` oder `{ recoveryCode }` → `{ stepUpAt }` |
| `GET /me` | alle | `{ user (mit `familyRole`: String oder `null`), familyId, session, csrfToken?, credentials: { passkeys, password, totp }, recoveryCodesRemaining }` |
| `PUT /me/family-role` | alle (nur die eigene Person) | `{ familyRole }` mit `vater`, `mutter`, `elternteil`, `kind`, `grosseltern`, `sonstige` oder `null` (löscht). **Reine Anzeige**, ändert keine Rechte, Sichtbarkeit oder Sync; sonst `400`. Strikt rate-limitiert, Audit `family_role_set` (nur Ziel-ID und fester Wert). |
| `PATCH /me` | alle | `{ displayName?, colorIndex? (0–9) }` |
| `PUT /me/avatar` | alle (nur die eigene Person; die Anmeldung wird vor dem Einlesen des Bodys geprüft, `401` ohne Upload) | Benutzerbild setzen. **Platzhalter:** `Content-Type: application/json`, `{ preset }` mit einer Kennung aus `V01 V08 V12 M01 M08 M13 K07 K08 K12 K13` (sonst `400`). **Foto:** Rohbytes mit `Content-Type: image/png`, `image/jpeg` oder `image/webp` (andere Typen, auch SVG: `415`). Animierte Bilder (APNG, animiertes WebP), Fremdbytes nach dem PNG-Ende und abgeschnittene Dateien werden abgelehnt (`400 invalid_image`). Der Server prüft die **Magic-Bytes** (muss zum Content-Type passen, sonst `400 invalid_image`) und liest die Maße aus dem Dateikopf (höchstens 1024 × 1024, sonst `400`); **Hartlimit 512 KB** nur für diese Route (`413`). Er dekodiert nichts: die App verkleinert auf ca. 512 × 512 und kodiert neu (entfernt EXIF/Standort). Strikt rate-limitiert (wie Anmeldung). → `{ avatar }` |
| `DELETE /me/avatar` | alle | entfernt das eigene Bild (Initialen); die Version zählt hoch |
| `GET /me/credentials` | alle | `{ credentials: [{ id, type, label, createdAt, lastUsedAt }] }` (nie Geheimnisse) |
| `POST /me/passkeys/options` | alle, Step-up | neuer Passkey: `{ challengeId, options }` |
| `POST /me/passkeys/verify` | alle, Step-up | `{ challengeId, response, label? }` → `{ id }` |
| `DELETE /me/passkeys/:id` | alle, Step-up | entfernt einen Passkey; der letzte Zugang bleibt (`409 last_credential`) |
| `POST /me/password/start` | alle, Step-up | `{ password }` (min. 12 Zeichen; nur ohne vorhandenes Passwort, sonst `409 password_exists`) → `{ challengeId, totpSecret, totpUri }`; es wird noch nichts gespeichert, ein neuer Start ersetzt den offenen Vorgang |
| `POST /me/password/complete` | alle, Step-up | `{ challengeId, code }` (6-stelliger TOTP-Code) legt Passwort und TOTP atomar an → `{ ok }`; falscher Code `400 invalid_code` (Audit `password_setup_failed`; zählt nur gegen einen eigenen Schlüssel je Person, ab 5 Fehlversuchen `429 too_many_attempts`, nicht gegen die Anmeldung), fremde/abgelaufene Challenge `400 challenge_invalid`. Danach sind alle anderen Sitzungen der Person beendet und das Step-up der aktuellen Sitzung verbraucht |
| `POST /me/password/change` | alle, Step-up | `{ password }` ersetzt das Passwort (TOTP bleibt); ohne Passwort `409 no_password`. Beendet alle anderen Sitzungen der Person und verbraucht das Step-up (die nächste Aktion verlangt `403 step_up_required`) |
| `DELETE /me/password` | alle, Step-up | entfernt Passwort und TOTP, nur wenn ein Passkey bleibt (`409 last_credential`); ohne Passwort `409 no_password`. Beendet alle anderen Sitzungen, verbraucht das Step-up und verwirft offene Einrichtungsvorgänge |
| `POST /me/recovery-codes` | alle, Step-up | `{ recoveryCodes[10] }`; die alten Codes entfallen |
| `GET /devices` | alle | `{ devices: [{ id, name, platform, appVersion, createdAt, lastSeenAt, current }] }` |
| `DELETE /devices/:id` | alle | meldet ein eigenes Gerät ab |
| `POST /ws-ticket` | alle | `{ ticket, expiresInSec: 30 }`: Einmal-Ticket (256 Bit) für den WebSocket |
| `GET /me/push` | alle | Push-Stand **dieses Geräts**: `{ available, server, registered, active, lastOkAt, lastErrorAt }` (`available`: der Server hat Push eingerichtet) |
| `PUT /me/push` | alle | `{ endpoint }`: UnifiedPush-Endpunkt dieses Geräts anmelden oder ersetzen (siehe Abschnitt „Push“); `400 invalid_endpoint` (auch für ein Topic, das schon einem anderen Gerät gehört: gleiche Antwort, damit die Existenz eines Topics nicht verraten wird), `503 push_unavailable` (Push nicht eingerichtet) |
| `DELETE /me/push` | alle | Endpunkt dieses Geräts löschen (idempotent) |
| `POST /me/push/test` | alle | schickt einen Test-Wecker an dieses Gerät: `{ result: "sent" \| "failed" \| "disabled" }`; `409 no_endpoint`, `429` (höchstens alle 10 s je Gerät) |

### Mitglieder

| Methode, Pfad | Rolle | Beschreibung |
| --- | --- | --- |
| `GET /members` | alle | Antwort `{ members: [...] }`. Admins: alle Mitglieder (auch wartende) inkl. E-Mail; andere: nur aktive Mitglieder, **ohne E-Mail – außer der eigenen**. Jedes Mitglied (und `user` in `GET /me`) trägt `avatar`: `null` (keines), `{ kind: "preset", id, version }` oder `{ kind: "photo", version }`; `version` zählt jede Änderung und ist der Cache-Schlüssel der Apps. Alte Apps ignorieren das Feld. Zusätzlich tragen sie `publicEncKey`, `publicSignKey` (je 32 Byte Base64url) und `keyVersion` (alle drei `null`, solange die Person keine E2EE-Schlüssel eingerichtet hat) |
| `GET /members/:id/avatar` | alle | Foto eines Mitglieds **derselben Familie** (fremde Familie, unbekannte Id, Platzhalter oder kein Foto: `404`). Bytes mit festem `Content-Type` (PNG/JPEG/WebP), `ETag` (`"a<version>"`) und `If-None-Match` → `304`, `Cache-Control: private, no-cache`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`. Platzhalter liefert der Server nicht (die Zeichnungen liegen in der App) |
| `DELETE /members/:id/avatar` | admin | setzt das Bild eines Mitglieds der eigenen Familie zurück (Initialen); Audit-Ereignis `avatar_reset`. Die Antworten von Anmeldung, Registrierung und Refresh enthalten `avatar` **nicht**: die App lädt danach `GET /me` (`neuLaden`) |
| `PUT /members/:id/family-role` | admin (sonst `403`, außer für die eigene ID) | `{ familyRole }` wie bei `PUT /me/family-role`, für ein Mitglied der eigenen Familie (fremde oder unbekannte ID `404`); ohne Step-up, da ohne Wirkung auf Rechte. Strikt rate-limitiert. |
| `PATCH /members/:id/role` | admin, Step-up | `{ role }`; **alle Sitzungen der Person werden widerrufen** (offene WebSockets schließen mit `4401`); bei **Herabstufung** werden ihre offenen Einladungen widerrufen; der letzte Admin kann nicht herabgestuft werden |
| `POST /members/:id/approve` | admin | gibt ein wartendes Mitglied frei |
| `POST /members/:id/reject` | admin | lehnt ein wartendes Mitglied ab: löscht die Mitgliedschaft; das Konto nur, wenn keine weitere Mitgliedschaft besteht |
| `POST /members/:id/reset` | admin, Step-up | `{ hours?, pin? }` (**keine E-Mail, kein Name**: das Konto bleibt) → `{ invite }`: widerruft Anmeldedaten, Codes und Sitzungen und erzeugt eine neue Einladung für dasselbe Konto; beim Annehmen entfallen `email` und `displayName` |
| `DELETE /members/:id` | admin, Step-up | entfernt ein Mitglied (nicht sich selbst, nicht den letzten Admin): löscht die Mitgliedschaft samt Geräten und Sitzungen, widerruft offene Einladungen von und für die Person, schließt ihre WebSockets; das Konto nur, wenn keine weitere Mitgliedschaft besteht |

### Einladungen

| Methode, Pfad | Rolle | Beschreibung |
| --- | --- | --- |
| `POST /invites` | admin (alle Rollen, Admin-Einladung mit Step-up), parent (nur `child`) | `{ role, hours? (1–168, Standard 24), pin? (bool), requireApproval? }` → `{ invite: { id, token, link, pin?, expiresAt, requireApproval } }`. **Token und PIN erscheinen nur in dieser Antwort.** `requireApproval` ist standardmäßig `false`; `true` verlangt die Freigabe des neuen Mitglieds durch einen Admin. |
| `GET /invites` | admin (alle), parent (eigene) | `{ invites: [{ id, role, status: open\|used\|revoked\|locked\|expired, createdAt, expiresAt, hasPin, requireApproval, reset, createdBy, usedBy }] }` ohne Token und PIN |
| `POST /invites/:id/revoke` | wie oben | widerruft eine offene Einladung; wer die Rolle der Einladung nicht (mehr) einladen darf, bekommt `403` |
| `POST /invites/:id/extend` | wie oben | `{ hours }` → `{ expiresAt }`: setzt die Gültigkeit auf **das spätere** von bisheriger Ablaufzeit und jetzt + `hours` (**verkürzt nie**; höchstens 7 Tage je Aufruf); gesperrte Einladungen bleiben gesperrt; Rollenprüfung wie bei `revoke` |

### E2EE-Schlüssel (Phase 1 der Ende-zu-Ende-Verschlüsselung)

Alles nur für die angemeldete Person selbst (Familien- und Personenfilter: fremde Daten gibt es hier nicht), strenges Rate-Limit (wie die Anmeldung). Blobs sind für den Server undurchsichtiger Base64url-Text;
der Server sieht nie ein Geheimnis. Schlüsselmaterial erscheint nie im Log. Kodierung: Schlüssel und Suchkennung = genau 32 Byte als Base64url **ohne** `=` (43 Zeichen, kanonisch).

| Methode, Pfad | Rolle | Beschreibung |
| --- | --- | --- |
| `GET /me/keys` | alle | `{ keys: { publicEncKey, publicSignKey, keyVersion } \| null, hasBackup }` (`hasBackup`: eine Sicherung zur aktuellen `keyVersion` liegt vor) |
| `POST /me/keys` | alle | `{ publicEncKey, publicSignKey }` legt das erste Schlüsselpaar an → `{ keys }` (`keyVersion` 1); gibt es schon eines `409 keys_exist`. Audit `key_created` |
| `PUT /me/keys` | alle, Step-up | `{ publicEncKey, publicSignKey, expectedKeyVersion }` **Schlüsselwechsel** (Totalverlust, Verdacht): `expectedKeyVersion` ist die dem Client bekannte Version (andere → `409 key_version_mismatch`, identische Schlüssel → `409 keys_unchanged`, es ändert sich nichts); `keyVersion` steigt um 1, der alte Stand wandert in die Schlüsselhistorie, Sicherung und offene Übertragungen entfallen → `{ keys }`; ohne Schlüssel `404`. Die anderen Geräte der Familie warnen. Audit `key_rotated` |
| `PUT /me/key-backup` | alle, Step-up | `{ blob (bis 2048 Zeichen), keyVersion }` legt die Sicherung ab oder ersetzt sie; `409 no_keys` ohne Schlüssel, `409 key_version_mismatch` bei veralteter Version. Audit `backup_set` |
| `GET /me/key-backup` | alle, Step-up | `{ blob, keyVersion }`; `404` ohne Sicherung. Audit `key_backup_read` |
| `GET /members/:id/keys` | alle | `?version=N` (optional): `{ userId, keys: [{ publicEncKey, publicSignKey, keyVersion, validFrom, validUntil }] }` mit der Version N (aktuell: `validUntil: null`, sonst aus der Historie), ohne `version` alle Versionen aufsteigend. Nur Mitglieder der eigenen Familie; unbekannte ID, unbekannte Version, Fremde und Entfernte: `404`; ungültige Eingabe `400`. Zum Prüfen alter Signaturen (`sender_key_version`) |
| `POST /me/key-transfer` | alle | `{ lookup (32 Byte Base64url), blob (bis 1024 Zeichen), keyVersion }` (`keyVersion` muss zur aktuellen Version passen, sonst `409 key_version_mismatch`; kollidiert die Suchkennung mit der einer anderen Person `409 transfer_conflict`) → `{ expiresAt, ttlSec: 120 }`: Übertragung für ein neues Gerät; höchstens eine offene je Person (eine neue ersetzt sie); gespeichert wird nur der SHA-256-Hash von `lookup`. `409 no_keys` ohne Schlüssel |
| `POST /me/key-transfer/claim` | alle | `{ lookup }` → `{ blob, keyVersion }`: löst **genau einmal** ein (atomar), nur durch dieselbe Person, nur vor Ablauf. Jeder Fehlschlag (unbekannt, abgelaufen, schon eingelöst, fremde Person) antwortet gleich mit `404 not_found`. Audit `transfer_claimed` |

## Sync `POST /api/v1/sync`

Der Abgleich der Familiendaten (Phase 1c; erster Fachbereich: **Listen**). Gleiche Anmeldung wie `/me` (Cookie + `X-CSRF-Token` oder `Authorization: Bearer`). **Die Familie und die Rolle kommen immer aus der Sitzung, nie aus dem Körper**; ein Feld `familyId` im Körper führt zu `400`. Konzept und Entscheidungen: `PROJEKTBESCHREIBUNG.md`, Abschnitt 6.

**Anfrage** (alle Objekte sind `strict`: unbekannte Felder im Umschlag führen zu `400 invalid_request`)

```json
{
  "protocolVersion": 1,
  "deviceId": "<Geräte-ID der Sitzung>",
  "sinceRev": 17,
  "limit": 500,
  "snapshotRev": 40,
  "ops": [
    { "opId": "<UUID>", "op": "upsert", "entity": "list_item", "id": "<UUID>", "baseRev": 12,
      "fields": { "text": "Hafermilch", "doneAt": "2026-10-19T10:00:00.000Z" } },
    { "opId": "<UUID>", "op": "delete", "entity": "list", "id": "<UUID>", "baseRev": 3 }
  ]
}
```

- `protocolVersion`: Version, die der Client spricht (Ganzzahl ab 1). Ist sie kleiner als `minProtocolVersion` (`GET /api/v1/version`, Einstellung `MIN_PROTOCOL_VERSION`), antwortet der Server mit `426 update_required`; die App zeigt dann die Pflicht-Update-Seite.
- `deviceId`: muss die Geräte-ID der Sitzung sein (`session.deviceId` aus der Anmeldung bzw. `/me`), sonst `409 device_mismatch` (die App lädt dann `/me` neu).
- `sinceRev`: letzte Revision, die der Client vollständig kennt (`0` = nichts, der Server liefert den Snapshot). Der Server merkt sie als `devices.last_rev`.
- `limit` (optional, 1 bis 500, Standard 500): Protokolleinträge je Antwortseite (ersetzte Stände werden übersprungen, die Seite kann daher weniger `changes` enthalten).
- `snapshotRev` (optional): nur in den Folgeanfragen eines mehrseitigen Snapshots, genau der Wert aus der Antwort der ersten Seite (siehe unten). Dann ist `sinceRev` der Cursor.
- `ops`: höchstens **50** je Aufruf, in der Reihenfolge ihrer Entstehung. Der Körper ist höchstens **1 MB** groß (sonst `413 payload_too_large`).
- Je Op: `opId` (vom Client vergebene UUID, macht den Upload wiederholbar), `op` (`upsert` oder `delete`), `entity`, `id` (vom Client vergebene UUID), `baseRev` (Revision des Datensatzes, auf der die Änderung aufbaut; `0` = neu angelegt) und bei `upsert` die **geänderten** Felder in `fields`. Eine Op mit unbekanntem Feld, falschem Wert, zu langem Text oder ungültigen Zeichen (NUL, einzelnes Surrogat) wird als `invalid` abgelehnt, ohne die anderen Ops zu blockieren. Fehlt die `opId` oder ist sie keine UUID, ist die ganze Anfrage ungültig (`400`).

**Antwort** (immer `200`, wenn die Anfrage gültig und die Person angemeldet ist)

```json
{
  "status": "ok",
  "rev": 21,
  "acked": ["<opId>", "..."],
  "rejected": [{ "opId": "<UUID>", "code": "deleted" }],
  "conflicts": [{ "opId": "<UUID>", "entity": "list_item", "id": "<UUID>", "fields": { "text": "Milch" }, "serverRev": 19 }],
  "changes": [
    { "rev": 18, "entity": "list", "id": "<UUID>", "tombstone": false, "fields": { "name": "Einkauf", "kind": "shopping", "audience": "family", "ownerId": "<UUID>", "createdAt": "2026-10-19T08:00:00.000Z" } },
    { "rev": 19, "entity": "list_item", "id": "<UUID>", "tombstone": true, "fields": {} }
  ],
  "hasMore": false,
  "next": 21,
  "snapshotRev": 21,
  "serverTime": "2026-10-19T10:00:01.000Z"
}
```

- `status`: `ok` oder `resync_required` (siehe unten). `rev`: aktueller Stand der Familie zum Zeitpunkt der Abfrage.
- `acked`: Ops, die der Server übernommen hat (auch ohne Wirkung, z. B. gleicher Wert; auch **mit Konflikten**: die nicht umstrittenen Felder wurden übernommen) und die er bei einem wiederholten Upload erneut bestätigt. `rejected`: Ops, die nicht angewendet wurden, mit Grund (Tabelle unten). Der Client nimmt beide aus seinem Ausgang.
- `conflicts`: Felder einer Op, die **nicht** übernommen wurden, weil sie seit `baseRev` anderswo geändert wurden; `fields` nennt den **Serverstand** dieser Felder, `serverRev` die Revision des Datensatzes. Der Client übernimmt den Serverwert (und weist die Person darauf hin).
- `changes`: Änderungen seit `sinceRev`, **stabil nach `rev` sortiert**, höchstens `limit` Einträge je Seite. Geliefert wird jeweils der **aktuelle Stand** des Datensatzes (nur der letzte Eintrag je Datensatz; `fields` enthält alle Felder), bei `tombstone: true` ohne Inhalt. Mit `hidden: true` verschwindet der Datensatz nur für diese Person (Freigabe zurückgenommen), der Client entfernt ihn lokal. Bei `sinceRev: 0` (Snapshot) gibt es keine Tombstones. Auch ein **gelöschter** Datensatz, den die Person nicht (mehr) sehen darf, kommt (nur im Delta, `sinceRev > 0`) als `hidden`-Tombstone: eine Liste, die erst für die Person unsichtbar gemacht und dann gelöscht wurde, bliebe sonst als Geist in ihrer App stehen. Das verrät die ID eines gelöschten, nie sichtbaren Datensatzes (nie Inhalt; siehe Datenschutz-Entwurf). Die eigenen Änderungen des Geräts kommen ebenfalls zurück (so lernt der Client die neue Revision des Datensatzes).
- `hasMore` / `next`: gibt es mehr als `limit` Änderungen, ist `hasMore` `true` und `next` das `sinceRev` der nächsten Anfrage (ohne Ops). Sonst gilt `rev` als neues `sinceRev`. Ops werden nur in der ersten Anfrage gesendet.
- **Mehrseitiger Snapshot (`snapshotRev`):** Die erste Seite (`sinceRev: 0`) legt die Ziel-Revision fest (Stand der Familie) und nennt sie als `snapshotRev`, solange weitere Seiten folgen. Der Client sendet sie mit `sinceRev: next` zurück. Folgeseiten prüfen **nie** gegen `purged_rev` (ein Snapshot braucht keine Tombstones, Bereinigung während des Laufs kann ihn nicht brechen), liefern nur Einträge bis zur Ziel-Revision, **nie Tombstones** und schreiben `devices.last_rev` nicht fort. Ist die letzte Seite erreicht und die Familie inzwischen weitergekommen, antwortet der Server mit `hasMore: true`, `next` = Ziel-Revision und **ohne** `snapshotRev`: der Client fährt mit einem normalen Lauf ab dort fort (Änderungen während des Snapshots kommen als Delta). Ein `snapshotRev` über dem Stand der Familie ergibt `resync_required`; ein `snapshotRev` kleiner oder gleich `sinceRev` wird ignoriert. Der Client speichert `snapshotRev` mit dem Cursor (ein unterbrochener Snapshot wird fortgesetzt) und löscht es bei `resync_required`, Gerätewechsel und Abschluss.
- **`resync_required`**: Der Client ist zu weit zurück (`sinceRev` liegt vor `families.purged_rev`: Tombstones bzw. Protokolleinträge wurden schon bereinigt; gilt nicht für Folgeseiten eines Snapshots), ihm eilt die Datenbank voraus (`sinceRev` größer als der Stand des Servers, z. B. nach einem Zurückspielen) oder seine Sicht hat sich geändert (`devices.resync_required`, gesetzt beim Rollenwechsel der Person; das Gerät kennt Datensätze, die es jetzt nicht mehr sehen dürfte). Das Flag gilt, bis das Gerät mit `sinceRev: 0` neu beginnt (und die Rolle seither unverändert ist). Die Antwort enthält keine `changes`; die mitgesendeten Ops sind trotzdem angewendet und bestätigt. Der Client leert die lokalen Fachtabellen (der Ausgang bleibt) und beginnt mit `sinceRev: 0` von vorn.
- Der Aufruf ändert `devices.last_rev` (auf das gesendete `sinceRev`, nicht bei Folgeseiten eines Snapshots) und `last_seen_at` des Geräts.

**Entscheidungen**

- **Idempotenz:** Jede Op läuft in einer eigenen Transaktion; die `opId` wird in `applied_ops` gespeichert (mit Ergebnis, Ziel der Op und den **Namen** der Konfliktfelder, nie mit Werten). Eine wiederholte Op (Antwort ging verloren) erhöht die Revision nicht und liefert dasselbe Ergebnis; Konfliktwerte werden dabei neu gelesen und die Rechte neu geprüft (wer den Datensatz inzwischen nicht mehr sehen darf oder wenn er gelöscht ist, bekommt keine Werte). Eine `opId`, die von einem **anderen Gerät** stammt, wird mit `duplicate_op` abgelehnt. `applied_ops` wird nach 90 Tagen bereinigt, **abgelehnte** Ops schon nach 7 Tagen.
- **Revisionen:** je Familie fortlaufend und lückenlos (die Familienzeile wird je Op gesperrt, `families.current_rev` atomar fortgeschrieben; gleichzeitige Syncs laufen nacheinander). Jede Änderung schreibt einen Eintrag in `change_log` und setzt `field_revs` je geänderten Feld.
- **Konflikte, Last-write-wins pro Feld:** Ein Feld einer `upsert`-Op **verliert**, wenn seine `field_rev` größer als `baseRev` ist (jemand hat es seit der Basis des Clients geändert) und diese Änderung **nicht vom selben Gerät** stammt. Der Serverwert bleibt und steht in `conflicts`. Reihenfolge bestimmt der Server, nie die Uhr des Clients. Felder, die nur eine Seite geändert hat, werden zusammengeführt (Abhaken gewinnt nicht gegen gleichzeitiges Umbenennen). Ein gleicher Wert ist kein Konflikt. Mehrere Ops desselben Geräts mit gleichem `baseRev` kollidieren nicht miteinander.
- **Löschen gewinnt:** `delete` wirkt immer (auch gegen gleichzeitige Änderungen) und ist wiederholbar. Ein `upsert` auf einen gelöschten Datensatz wird mit `deleted` abgelehnt. Das Löschen einer Liste löscht ihre Einträge mit (je ein Tombstone, die der Einträge mit kleineren Revisionen). Beim Löschen werden Inhalte sofort überschrieben und im `change_log` geleert.
- **Anlegen:** `upsert` auf eine unbekannte `id` mit `baseRev: 0` legt an (Pflichtfelder nötig); mit `baseRev > 0` ist der Datensatz inzwischen bereinigt (`not_found`). Eine ID, die schon einem fremden Datensatz (auch einer anderen Familie) gehört, ergibt `not_found` (verrät nicht, dass es sie gibt).
- **Verweise:** Verweise auf Mitglieder (`assigneeId`) müssen auf ein **aktives Mitglied der eigenen Familie** zeigen (`invalid_reference`), `listId` auf eine vorhandene, sichtbare, nicht gelöschte Liste.
- **Sortierung:** `position` ist eine Kommazahl; eine neue Position liegt zwischen den Nachbarn (Mittelwert, neue Einträge oben: kleiner als alle offenen). Nur das verschobene Feld ändert sich; Gleichstand entscheidet die Anlegezeit, dann die ID. Wertebereich ±10^12.
- **Obergrenzen:** 200 lebende Listen je Familie, 1000 lebende Einträge je Liste, 5000 lebende Termine je Familie und zusätzlich **500 lebende Termine je Besitzer für Kinder** (ein Kinderkonto kann die Familienobergrenze nicht allein füllen), 50 Teilnehmer und 500 Ausnahmen je Termin (`limit_reached`).
- **Mitglied entfernen:** Verweise der Person (`assigneeId`, `ownerId`) werden mit einem Änderungseintrag auf `null` gesetzt und die Geräte per WebSocket benachrichtigt; Mitglieder selbst sind keine Sync-Entität.
- **Wartung** (stündlich): Tombstones werden entfernt, wenn alle aktiven (nicht abgemeldeten) Geräte der Familie sie kennen (`last_rev` >= Revision) oder sie älter als 90 Tage sind; dabei steigt `families.purged_rev`. Ersetzte Protokolleinträge verschwinden nach 90 Tagen. Gerät mit neuer Geräte-ID (neue Anmeldung): die App beginnt mit einem Snapshot.
- **Limits:** höchstens 120 Aufrufe je Minute und IP (`SYNC_RATE_LIMIT_MAX`), **50 Ops** je Aufruf, 1 MB. Zusätzlich ein Token-Bucket **je Gerät** und **je Person** (Person = Dreifaches): Anfragen (`SYNC_REQ_BURST` 30, `SYNC_REQ_PER_MINUTE` 120) und Ops (`SYNC_OPS_BURST` 100, mindestens 50, `SYNC_OPS_PER_MINUTE` 120; eine Anfrage kostet 1, jede Op 1) sowie eine Tagesobergrenze je Gerät (`SYNC_OPS_PER_DAY`, 5000 Ops in 24 Stunden, gezählt über `applied_ops`). Reicht der Bucket nicht, wird die **ganze** Anfrage mit `429 rate_limited` und `Retry-After` abgewiesen (nichts wird halb verarbeitet; der Client wiederholt später dieselben Ops). Jede Op läuft mit `lock_timeout` (5 s) und `statement_timeout` (10 s); wird die Sperre der Familie nicht rechtzeitig frei oder dauert die Anweisung zu lange, antwortet der Sync mit `503 server_busy` und `Retry-After` (die Op ist dann nicht angewendet). Inhalte werden nie geloggt.

**Gründe einer Ablehnung (`rejected[].code`)**

| Code | Bedeutung |
| --- | --- |
| `invalid` | Eingabe ungültig: unbekanntes Feld, falscher Typ oder Wert, zu lang, ungültige Zeichen, Pflichtfeld fehlt, unveränderliches Feld (`listId`, `terminId`, `userId`, `originalStart`) geändert, Server-Feld (`ownerId`, `createdAt`) gesendet; bei Terminen außerdem unstimmige Zeiten (Ende vor Beginn, fehlende Zeitzone), unbekannte Zeitzone, unzulässige Wiederholungsregel; ein zweiter aktiver Teilnehmer/eine zweite Ausnahme für dasselbe Ziel ergibt `not_found` |
| `unknown_entity` | Entität unbekannt (z. B. neuere App-Version) |
| `forbidden` | Die Rolle darf das nicht, obwohl sie den Datensatz sehen darf |
| `not_found` | Datensatz unbekannt, gehört einer fremden Familie oder ist für die Rolle nicht sichtbar (kein Unterschied) |
| `deleted` | Der Datensatz wurde gelöscht |
| `parent_deleted` | Die übergeordnete Liste bzw. der übergeordnete Termin wurde gelöscht |
| `invalid_reference` | Verweis auf ein Mitglied, das nicht (mehr) zur Familie gehört |
| `limit_reached` | Obergrenze erreicht |
| `duplicate_op` | Die `opId` wurde von einem anderen Gerät benutzt |

Fehler der Anfrage selbst: `400 invalid_request` (Umschlag, zu viele Ops, ungültige `opId`), `401 unauthenticated`, `403 csrf_invalid`, `409 device_mismatch`, `413 payload_too_large`, `426 update_required`, `429 rate_limited`, `503 server_busy` (siehe Limits).

**Rechte (zentrales Modell, `server/src/sync/permissions.ts`)**

Jeder Datensatz hat eine Freigabe-Stufe `audience` (`parents`: nur Eltern und Admins, `family`: die ganze Familie; Standard `family`). **Rückwärtskompatibel:** die frühere Stufe `all` (auch Gäste) nimmt der Server in Eingaben weiter an (Apps bis 0.2.0 senden sie) und speichert und liefert sie als `family`. **Verhaltenswechsel (Migration 0005):** Apps vor 0.2.1 senden evtl. `all`; ein Kind darf damit jetzt eine eigene Liste/einen eigenen Termin anlegen (vorher `forbidden`), es wird `family`. Jeder Datensatz hat außerdem einen Besitzer. Was eine Rolle nicht lesen darf, gibt es für sie nicht: Ändern und Löschen ergeben `not_found`, im Änderungsstrom fehlt es.

| Entität | Admin, Elternteil | Kind |
| --- | --- | --- |
| `list` | lesen, anlegen, ändern, löschen, Freigabe ändern | Stufe `family` lesen; anlegen nur mit Stufe `family`; **eigene** Listen umbenennen (`name`, `kind`) und löschen |
| `list_item` | alles | in sichtbaren Listen lesen, anlegen, ändern, abhaken, zuweisen, löschen |
| `termin` | lesen, anlegen, ändern, löschen, Freigabe ändern | Stufe `family` lesen; anlegen nur mit Stufe `family`; **eigene** Termine ändern (alles außer `audience`) und löschen |
| `termin_teilnehmer` | alles | erben Stufe und Besitzer des Termins: lesen, wo der Termin sichtbar ist; anlegen, ändern, löschen nur an **eigenen** Terminen |
| `termin_ausnahmen` | alles | wie `termin_teilnehmer` |
| `aufgabe` | lesen, anlegen, ändern, löschen, Freigabe ändern | Stufe `family` lesen; anlegen nur mit Stufe `family`; **eigene** Aufgaben ändern (alles außer `audience`) und löschen; an **zugewiesenen** nur `erledigtAt`/`folgeId` |
| `aufgabe_punkt` | alles | erben Stufe, Besitzer und Zuständige der Aufgabe: lesen, wo sie sichtbar ist; anlegen, ändern, löschen nur an **eigenen** Aufgaben; an **zugewiesenen** nur `doneAt` ändern |

Ändert sich die Freigabe einer Liste (oder eines Termins), werden ihre Einträge (Teilnehmer, Ausnahmen) neu angestoßen (neue Revision ohne Inhaltsänderung): Geräte, die sie nun sehen dürfen, bekommen sie; Geräte, die die Liste nicht mehr sehen dürfen, bekommen einen Tombstone mit `hidden: true` ohne Inhalt. Bei Rollenwechsel werden die Sitzungen widerrufen und das Flag `resync_required` der Geräte der Person gesetzt; die neue Anmeldung ist ein neues Gerät und beginnt mit einem Snapshot (die App leert außerdem bei jeder neuen Geräte-ID ihre Fachtabellen und stellt nur lokal neu angelegte, noch nicht gesendete Zeilen wieder her).

**Entitäten** (Namen und Felder in der Schnittstelle; `rw` = vom Client beschreibbar, `create` = nur beim Anlegen, `server` = nur der Server)

| Entität | Feld | Typ | Zugriff |
| --- | --- | --- | --- |
| `list` | lesen, anlegen, ändern, löschen, Freigabe ändern | Stufe `family` lesen; anlegen nur mit Stufe `family`; **eigene** Listen umbenennen (`name`, `kind`) und löschen |
| | `kind` | `shopping`, `packing`, `custom` (Standard) | rw |
| | `audience` | `parents`, `family` (Standard), `all` | rw |
| | `ownerId` | UUID oder `null` | server (die anlegende Person) |
| | `createdAt` | ISO-8601 (UTC) | server |
| `list_item` | alles | in sichtbaren Listen lesen, anlegen, ändern, abhaken, zuweisen, löschen |
| | `text` | Text 1 bis 500 Zeichen (Pflicht) | rw |
| | `assigneeId` | UUID eines aktiven Mitglieds oder `null` | rw |
| | `doneAt` | ISO-8601 mit Zeitzone (2000 bis 2200) oder `null` (offen) | rw |
| | `position` | Zahl, ±10^12 (Standard 0) | rw |
| | `createdAt` | ISO-8601 (UTC) | server |

**Termine (Phase 1c-2a)**

- **Zeitmodell:** Die Familienzeitzone ist fest `Europe/Berlin` (Anzeige und Tagesgrenzen). **Zeittermine** (`ganztaegig: false`) speichern Beginn und Ende als Zeitpunkte (`startUtc`, `endUtc`, ISO-8601, in der Antwort UTC mit Millisekunden) plus IANA-Zeitzone (`tzid`); Wiederholungen werden in der **Wanduhrzeit der `tzid`** gerechnet (10 Uhr bleibt über die Zeitumstellung 10 Uhr). **Ganztägige Termine** (`ganztaegig: true`) sind Kalendertage ohne Uhrzeit und Zeitzone: `startDate`, `endDate` als `YYYY-MM-DD`, das **Ende ist exklusiv** wie in iCalendar (ein Tag: Ende = Folgetag). Der Server prüft die Stimmigkeit nach dem Zusammenführen jeder Änderung (Zeittermin: Beginn, Ende >= Beginn und `tzid`; ganztägig: Ende > Beginn), sonst `invalid`. Felder der jeweils anderen Art dürfen als Rest stehen bleiben; maßgeblich ist `ganztaegig`.
- **Zeitzonen-Kennung:** `tzid` muss der Laufzeit des Servers bekannt sein und in der Schreibweise der IANA-Datenbank stehen (`Europe/Berlin`; `europe/berlin` wird abgelehnt, weil die Zeitzonen-Datenbank der App Groß-/Kleinschreibung unterscheidet). Ältere Namen (z. B. `Asia/Kolkata`) bleiben erlaubt; kennt die App eine Kennung nicht, rechnet sie in der Familienzeitzone.
- **Wiederholung:** `rrule` ist RFC-5545-Text **ohne** Präfix. Erlaubt: `FREQ` (`DAILY`, `WEEKLY`, `MONTHLY`, `YEARLY`), `INTERVAL` 1 bis 999, `COUNT` 1 bis 1000 oder `UNTIL` (nicht beide; Zeittermin: `YYYYMMDDTHHMMSSZ` in UTC, ganztägig: `YYYYMMDD`), `BYDAY` (bei `MONTHLY`/`YEARLY` mit Zahl -5 bis 5), `BYMONTHDAY`, `BYMONTH`, `BYSETPOS`, `WKST`; höchstens 300 Zeichen und 10 Teile. Abgelehnt: **unerfüllbare Kombinationen** (`BYMONTH` mit `BYMONTHDAY`, für die es keinen Monat mit passendem Tag gibt, z. B. 30. Februar oder 31. April), `SECONDLY`/`MINUTELY`/`HOURLY`, `BYHOUR`/`BYMINUTE`/`BYSECOND`/`BYYEARDAY`/`BYWEEKNO`, ein Präfix, Kleinbuchstaben, doppelte Teile. Die Prüfung ist ein Hand-Tokenizer (`server/src/sync/rrule.ts`, kein regulärer Ausdruck mit Rückverfolgung). Der **Client** expandiert (Paket `rrule` mit `timezone`): höchstens 1000 Vorkommen je Termin und Abfrage, Horizont 5 Jahre.
- **Ausnahmen** (`termin_ausnahmen`): eine Zeile je (`terminId`, `originalStart`); `originalStart` ist **unveränderlich** und nennt das ursprüngliche Vorkommen: bei Zeitterminen den Beginn in UTC (`YYYY-MM-DDTHH:MM:SSZ`, der Server normalisiert), bei ganztägigen den Tag (`YYYY-MM-DD`). `abgesagt` blendet das Vorkommen aus; `titel`, `start`, `ende`, `ort` überschreiben (`null` = unverändert; nur `start` gesetzt: die Dauer bleibt; `start`/`ende` haben die Art von `originalStart`). Eine Ausnahme wird nicht gelöscht, sondern zurückgesetzt (alles leer); die App vergibt ihre ID aus Termin und `originalStart` (zwei Geräte schreiben dieselbe Zeile; ein zweites Anlegen mit neuer ID wird abgelehnt). **Gelöscht wird eine Ausnahme nie von der App** (nur zurückgesetzt oder mit dem Termin per Kaskade): eine gelöschte feste ID bliebe als Tombstone stehen und ließe sich nicht wiederverwenden (`deleted`). **„Dieses und alle folgenden“** ändert die Serie nicht über Ausnahmen: der Master bekommt ein `UNTIL` vor dem **ursprünglichen** Beginn des Vorkommens (nicht vor einem durch eine Ausnahme verschobenen), ab dort beginnt ein neuer Termin. Der neue Termin gehört der Person, die ihn anlegt (der Server setzt `ownerId` aus der Sitzung): teilen Eltern die Serie eines Kindes, ändert das Kind den neuen Teil nicht mehr.
- **Teilnehmer** (`termin_teilnehmer`): eine Zeile je Person (`userId` aktives Mitglied der Familie, `terminId`, beide unveränderlich); eine aktive Zeile je Person und Termin (ein zweites Anlegen ergibt `not_found`), Entfernen = Tombstone, danach ist Neu-Eintragen möglich. Verlässt die Person die Familie, wird ihre Zeile **mit Tombstone und Änderungseintrag** gelöscht (`memberOwned` im Register, vor dem Entfernen der Mitgliedschaft); die Zeile selbst verschwindet danach per Fremdschlüssel-Kaskade, der Änderungsstrom liefert den Tombstone trotzdem (`hidden`, nur die ID), und die Wartung räumt den verwaisten Eintrag nach 90 Tagen.
- **Erinnerung:** `erinnerungMin` (Minuten vor Beginn, 0 bis 40320, `null` = keine) wird gespeichert und synchronisiert; die Benachrichtigung entsteht lokal auf dem Gerät (Android, `flutter_local_notifications`), der Server verschickt nichts (siehe PROJEKTBESCHREIBUNG, Abschnitt 6b).

| Entität | Feld | Typ | Zugriff |
| --- | --- | --- | --- |
| `termin` | lesen, anlegen, ändern, löschen, Freigabe ändern | Stufe `family` lesen; anlegen nur mit Stufe `family`; **eigene** Termine ändern (alles außer `audience`) und löschen |
| | `ort`, `beschreibung` | Text bis 200 bzw. 4000 Zeichen (Standard leer) | rw |
| | `ganztaegig` | Wahrheitswert (Standard `false`) | rw |
| | `startUtc`, `endUtc` | ISO-8601 mit Zeitzone (2000 bis 2200) oder `null` | rw |
| | `tzid` | IANA-Zeitzone (z. B. `Europe/Berlin`) oder `null` | rw |
| | `startDate`, `endDate` | `YYYY-MM-DD` oder `null` | rw |
| | `rrule` | Wiederholungsregel oder `null` | rw |
| | `erinnerungMin` | Ganzzahl 0 bis 40320 oder `null` | rw |
| | `icalUid` | Text bis 255 Zeichen oder `null` (späterer Import, Duplikaterkennung) | rw |
| | `audience` | `parents`, `family` (Standard), `all` | rw |
| | `ownerId` | UUID oder `null` (bestimmt die Personenfarbe) | server |
| | `createdAt` | ISO-8601 (UTC) | server |
| `termin_teilnehmer` | alles | erben Stufe und Besitzer des Termins: lesen, wo der Termin sichtbar ist; anlegen, ändern, löschen nur an **eigenen** Terminen |
| `termin_ausnahmen` | alles | wie `termin_teilnehmer` |
| | `originalStart` | Tag oder Zeitpunkt, siehe oben (Pflicht) | create |
| | `abgesagt` | Wahrheitswert (Standard `false`) | rw |
| | `titel`, `ort` | Text bis 200 Zeichen oder `null` | rw |
| | `start`, `ende` | Tag oder Zeitpunkt oder `null` | rw |

**Chat (Phase 1c-3a)** · Konzept, Rechte und Datenschutz: `PROJEKTBESCHREIBUNG.md`, Abschnitt 6c.

- **Sichtbarkeit:** Direkt- und Gruppenchats (`konversation` mit `art` `direct`/`group`) sehen **nur ihre Teilnehmer**, auch Admin und Eltern nicht; Nachrichten und Lesestände erben das. Für alle anderen existiert die ID nicht: Ändern, Löschen und Anlegen darunter ergeben `not_found` (auch mit IDs einer fremden Familie), der Änderungsstrom liefert nichts, auch keinen Tombstone. Der Familienchat (`art` `family`, genau einer je Familie) gehört allen aktiven Mitgliedern. Wer aus einer Gruppe entfernt wird (`teilnehmer` geändert), bekommt einen `hidden`-Tombstone der Konversation (die App entfernt sie samt Nachrichten und Lesestand); wer nie dabei war, nichts.
- - **Inhalt ist undurchsichtig und verschlüsselt (E2EE Phase 2):** `text` einer Nachricht ist in jeder neuen Konversation eine **verschlüsselte Hülle** `e1:` + Base64url (Aufbau und Verfahren: `PROJEKTBESCHREIBUNG.md`, Abschnitt 9a). Der Server prüft nur die **Form**: Präfix passend zur Konversation (`encVersion`), nur Base64url-Zeichen, mindestens 153 Zeichen (Kopf 114 Byte + Tag), höchstens 16 384 Zeichen; er entschlüsselt, prüft, loggt und indiziert nie etwas (kein Suchendpunkt, keine Vorschau). **Klartext `p1:` ist in einer `e1`-Konversation `invalid`** (Downgrade-Schutz); `p1` gilt nur für Altbestand (`encVersion` `p1`, nur lesbar, die App schreibt dort nicht mehr). `l1:` (lokaler Klartext im Ausgang der App) lehnt der Server ab. `titel` (Gruppenname) bleibt `p1:` + Klartext: der Name ist sichtbarer Metadatenwert (wie die Teilnehmerliste).
- **Familienchat anlegen:** `upsert konversation {art: "family"}` von jeder Rolle; ohne `titel` und `teilnehmer`; verschlüsselt (`encVersion` `e1` ist der Standard, ein Client kann `p1` nur für Altbestände senden). Die ID ist **vorgeschrieben**: SHA-256 von `lx-fampad:familienchat:<familyId>`, die ersten 16 Byte mit Version 5 und Variante 10xx als UUID (`server/src/sync/entities/chat-ids.ts`, gleich in der App); jede andere ID ist `invalid`. Dieselbe ID noch einmal ist eine Wiederholung ohne Wirkung. Danach ist er für Clients unveränderlich (`forbidden`) und nicht löschbar.
- **Direktchat:** `art: "direct"`, `teilnehmer` = genau die zwei Personen (anlegende Person dabei, nur aktive Mitglieder der Familie, sonst `forbidden` bzw. `invalid_reference`); die Liste wird sortiert und ohne Doppelte gespeichert. Je Paar ein Chat: die ID ist vorgeschrieben (`direkt:<kleinere Nutzer-ID>:<größere>`, kleingeschrieben und sortiert), jede andere ist `invalid`; dieselbe ID noch einmal ist ein Update ohne Änderung. Wurde der Chat gelöscht (Person entfernt), belebt ein erneutes Anlegen mit derselben ID ihn wieder. Unveränderlich, nicht löschbar.
- **Gruppe:** `art: "group"` (ID: Zufalls-UUID Version 4, abgeleitete IDs mit Nibble 5 sind reserviert), 2 bis 20 `teilnehmer` (anlegende Person dabei), `titel` optional. Jeder Teilnehmer ändert `titel` und `teilnehmer`; löschen darf nur die anlegende Person (`ownerId`). Bleiben nach dem Entfernen eines Mitglieds aus der Familie weniger als zwei Teilnehmer, wird die Gruppe gelöscht.
- **Nachrichten:** schreiben darf jede Person mit Sicht, `autorId` und Zeit setzt der Server. **Bearbeiten (nur `text`) und Löschen nur der Autor** (`forbidden`); Ausnahme: **Admins löschen im Familienchat auch fremde Nachrichten**, nie in privaten Chats. `bearbeitetAt` setzt der Server beim Ändern des Textes. `antwortAuf` (nur beim Anlegen) muss eine Nachricht **derselben Konversation** sein, sonst `invalid`; `text` muss mit der Hülle der Konversation beginnen (`encVersion` `e1:` oder, nur für Altbestand, `p1:`) und bei `e1` die Form einer verschlüsselten Hülle haben, sonst `invalid`. Beim Bearbeiten wird ältere Text-Fassung aus dem Protokoll entfernt. Mengenbegrenzung: höchstens 60 neue Nachrichten und 60 Text-Änderungen je Person und Minute, Text je Person höchstens 1 MiB je Stunde und 4 MiB je Tag, 20 000 lebende Nachrichten je Konversation, 10 Teilnehmerwechsel je Person und Minute (`limit_reached`).
- **Lesestand:** eine Zeile je Person und Konversation (`userId` muss die eigene sein), `gelesenBis` = Zeit (`createdAt`) der letzten gelesenen fremden Nachricht. Schreiben nur die eigene Zeile, **lesen alle Teilnehmer der Konversation** (Lesebestätigung; Familienchat: alle Mitglieder); die ID ist vorgeschrieben (`lesestand:<Konversation>:<Person>`), jede andere ist `invalid`. `gelesenBis` geht nie zurück (ein kleinerer Wert wird verworfen). Die Teilnehmer erfahren per WebSocket von Änderungen (kein Push-Wecker).
- **Obergrenzen:** 500 lebende Konversationen je Familie, 100 je anlegender Person (`limit_reached`).
- **Mitglied entfernt:** aus Teilnehmerlisten genommen; Direktchats und Gruppen mit weniger als zwei Übrigen mit Tombstone gelöscht; `autorId` der Nachrichten wird `null`; Lesestand der Person wird gelöscht (Tombstone).
- **WebSocket:** `rev N` zu privaten Chats geht nur an die Teilnehmer (nach Person), zum Familienchat an alle Rollen mit Sicht.

| Entität | Feld | Typ | Zugriff |
| --- | --- | --- | --- |
| `konversation` | `art` | `family`, `direct`, `group` (Pflicht) | create |
| | `encVersion` | Version der Inhaltshülle: `e1` (Ende-zu-Ende verschlüsselt, **Standard**) oder `p1` (Klartext, nur Altbestand); **neue Konversationen nur als `e1`** (`p1` und alles andere beim Anlegen `invalid`); nach dem Anlegen unveränderlich (kein Zurückstufen: Änderung ist `invalid`), beim Wiederbeleben einer gelöschten Konversation gilt die Hülle der Neuanlage (`e1`, auch aus einem `p1`-Altbestand) | create |
| | `titel` | undurchsichtiger Text bis 512 Zeichen (Standard leer; Direkt- und Familienchat: leer) | rw |
| | `teilnehmer` | Liste von UUIDs (sortiert, eindeutig; Familienchat leer, Direktchat 2, Gruppe 2 bis 20) | rw (nur Gruppen) |
| | `ownerId` | UUID oder `null` (anlegende Person) | server |
| | `createdAt` | ISO-8601 (UTC) | server |
| `nachricht` | `konversationId` | UUID (Pflicht) | create |
| | `text` | Hülle `e1:`+Base64url (153 bis 16 384 Zeichen) bzw. `p1:`+Text im Altbestand (Pflicht); für den Server undurchsichtig | rw (nur Autor) |
| | `antwortAuf` | UUID oder `null` | create |
| | `autorId` | UUID oder `null` (nach Entfernen der Person) | server |
| | `bearbeitetAt`, `createdAt` | ISO-8601 (UTC) oder `null` | server |
| `lesestand` | `konversationId`, `userId` | UUID (Pflicht) | create |
| | `gelesenBis` | ISO-8601 mit Zeitzone (Pflicht) | rw |

**Epochen und Schlüssel-Wraps (E2EE Phase 2)** · Protokoll: `PROJEKTBESCHREIBUNG.md`, Abschnitt 9a. Zwei weitere Sync-Entitäten, Kinder der Konversation. Der Server speichert nur undurchsichtige
Base64url-Texte und wertet sie **nie** aus (keine Signaturprüfung, kein Entschlüsseln); er prüft Form, Größe, Eindeutigkeit und die Sicht. Nur in `e1`-Konversationen (sonst `invalid`).

- **`epoche`:** je (Konversation, Epoche) genau eine Zeile mit **vorgeschriebener ID** (`epoche:<Konversation>:<Nummer>`, SHA-256 mit Präfix `lx-fampad:`, Muster UUID Version 5, `chat-ids.ts`/`chat_ids.dart`); jede andere ID ist `invalid`.
  **Der erste Schreiber gewinnt:** wer eine schon vorhandene Epoche mit anderem Inhalt anlegt, wird mit `invalid` abgelehnt (die identische Wiederholung wird bestätigt); der Verlierer einer gleichzeitigen Rotation übernimmt
  die Epoche des Gewinners aus dem Änderungsstrom. Lückenlos: Epoche N gibt es erst, wenn N-1 da ist (sonst `invalid`). Alle Teilnehmer der Konversation lesen sie (im Familienchat alle aktiven Mitglieder), Nichtteilnehmer erfahren nichts
  (`not_found`, auch für Admins); unveränderlich, nicht löschbar (verschwindet nur mit der Konversation). Höchstens 1000 je Konversation, 20 neue je Person und Minute (`limit_reached`).
- **Grenzen für Epochen und Wraps:** Epochen je Person höchstens 3 je Minute und 12 je Stunde, höchstens 100 lebende je Konversation und Person (insgesamt 1000); Wraps höchstens 100 je Minute und 800 je Stunde, 2000 lebende je Konversation und Person (`limit_reached`). Wraps der **höchsten** Epoche nimmt der Server nur vom Verteiler dieser Epoche an (`forbidden`); für ältere Epochen (Verlauf teilen) darf jedes Mitglied Wraps anlegen. Eine gelöschte Epoche oder ein gelöschter Wrap lässt sich mit derselben ID wieder anlegen (Wiederbeleben). Im Verlauf für neu Aufgenommene liefert der Server die eigenen Wraps immer (Abfrage nach Empfänger, kein Verdrängen durch fremde Zeilen). Wraps und Lesestand lösen keinen Push-Wecker aus.
- **`epoche_wrap`:** der für **eine Person** verpackte Epochenschlüssel (Sealed Box plus Signatur des Verteilers). Je (Konversation, Epoche, Empfänger) genau eine Zeile mit vorgeschriebener ID (`wrap:<Konversation>:<Nummer>:<Empfänger>`), der erste gewinnt
  (ein zweiter ist `not_found`, "gibt es schon"), unveränderlich. **Nur der Empfänger liest seinen Wrap** (auch der Verteiler, die anderen Teilnehmer und Admins nicht), der WebSocket-Hinweis geht nur an ihn. Anlegen darf jeder Teilnehmer;
  die Epoche muss es geben, der Empfänger muss Teilnehmer sein (Familienchat: aktives Mitglied), sonst `invalid`. Verlässt die Person die Familie, verschwinden ihre Wraps (Tombstone für ihre Geräte). Höchstens 20 000 je Konversation, 400 neue je Person und Minute.

| Entität | Feld | Typ | Zugriff |
| --- | --- | --- | --- |
| `epoche` | `konversationId` | UUID (Pflicht) | create |
| | `epoche` | Ganzzahl 1 bis 100 000 (Pflicht) | create |
| | `mitglieder` | vom Verteiler signierte Mitgliederliste der Epoche, Base64url bis 16 384 Zeichen (Pflicht, undurchsichtig) | create |
| | `verteilerId`, `createdAt` | UUID bzw. ISO-8601 (UTC), vom Server | server |
| `epoche_wrap` | `konversationId` | UUID (Pflicht) | create |
| | `epoche` | Ganzzahl 1 bis 100 000 (Pflicht) | create |
| | `empfaengerId` | UUID des Empfängers (Pflicht, aktives Mitglied) | create |
| | `wrap` | Base64url bis 4096 Zeichen (Pflicht, undurchsichtig) | create |
| | `verteilerId`, `createdAt` | vom Server | server |

**Aufgaben (Phase 1c-4a)**

- **Fälligkeit** wie bei Terminen: `faelligDate` (`YYYY-MM-DD`, ganztägig, keine Zeitzone) **oder** `faelligUtc` (ISO-8601, in der Antwort UTC mit Millisekunden) mit `tzid` (IANA-Zeitzone, Pflicht bei `faelligUtc`); beides gleichzeitig oder `faelligUtc` ohne `tzid` ist `invalid` (geprüft nach dem Zusammenführen jeder Änderung). Beides `null` = ohne Fälligkeit. Beim Wechsel zwischen Tag und Zeitpunkt sendet der Client alle drei Felder zusammen.
- **Priorität** `prioritaet`: Ganzzahl 0 (keine) bis 3 (hoch). **Status:** `erledigtAt` (Zeitpunkt oder `null`) und `erledigtVon` (aktives Mitglied oder `null`; `invalid_reference` sonst); `erledigtVon` ist ein **Server-Feld**: der Server setzt es beim Setzen von `erledigtAt` auf den Akteur (Sitzung) und beim Zurücksetzen auf `null`; sendet der Client es, ist die Op `invalid`. **Zuständig:** `assigneeId` (aktives Mitglied der Familie oder `null`).
- **Wiederholung** `wiederholung`: `daily`, `weekly`, `monthly` oder `null`; der Server prüft nur die Form und legt nie selbst eine Folgeaufgabe an. Der **Client** erzeugt sie beim Erledigen (Fälligkeit, Deckel und feste ID: `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 6e). Das zweite Anlegen derselben ID (zwei Geräte erledigen dieselbe Aufgabe) ist eine gewöhnliche Änderung mit denselben Werten, kein Fehler.
- **Unteraufgaben** (`aufgabe_punkt`): `aufgabeId` (unveränderlich, Pflicht), `text` (1 bis 500 Zeichen), `doneAt` (Zeitpunkt oder `null`), `position` (Kommazahl wie bei Listeneinträgen). Sie erben Freigabe und Besitzer der Aufgabe; beim Löschen der Aufgabe werden sie per Kaskade mit Tombstone entfernt (niedrigere Revisionen vor der Aufgabe).
- **Obergrenzen:** 5000 **offene** (nicht erledigte) Aufgaben je Familie, zusätzlich **500 offene je Besitzer für Kinder**; alle lebenden Aufgaben (auch erledigte) zusammen höchstens 20000 je Familie; 100 lebende Unteraufgaben je Aufgabe und 50000 je Familie (`limit_reached`). **Mitglied entfernt:** `assigneeId`, `erledigtVon` und `ownerId` werden mit Änderungseintrag auf `null` gesetzt.
- **Zuständige Person:** Wer in `assigneeId` steht (auch ein Kind), darf an der Aufgabe **nur** `erledigtAt` und `folgeId` ändern und an ihren Unteraufgaben nur `doneAt`; jede weitere Änderung, Anlegen/Löschen von Unteraufgaben und Löschen der Aufgabe sind `forbidden`, eine für die Person nicht sichtbare Aufgabe `not_found`. Sonst gilt die Tabelle unten.
- **Folgeaufgabe:** `folgeId` (UUID oder `null`) nennt die beim Erledigen angelegte Folgeaufgabe (abgeleitet, bei belegter ID zufällig); `wiederholungTag` (1 bis 31 oder `null`) ist der Wunschtag des Monats bei `monthly` und bleibt in der Kette erhalten.
- **Erinnerung:** `erinnerungMin` (0 bis 40320 Minuten vor der Fälligkeit oder `null`) wird gespeichert und synchronisiert; die App nutzt es noch nicht (siehe Abschnitt 6e der Projektbeschreibung, Offen).

| Entität | Feld | Typ | Zugriff |
| --- | --- | --- | --- |
| `aufgabe` | lesen, anlegen, ändern, löschen, Freigabe ändern | Admin/Eltern alles; Kind: Stufe `family` lesen, nur mit Stufe `family` anlegen, **eigene** Aufgaben ändern (alles außer `audience`) und löschen, an **zugewiesenen** nur `erledigtAt`/`folgeId` | |
| | `titel` | Text 1 bis 200 Zeichen (Pflicht) | rw |
| | `beschreibung` | Text bis 4000 Zeichen (Standard leer) | rw |
| | `faelligDate` | `YYYY-MM-DD` oder `null` | rw |
| | `faelligUtc`, `tzid` | ISO-8601 mit Zeitzone (2000 bis 2200) bzw. IANA-Zeitzone, oder `null` | rw |
| | `prioritaet` | Ganzzahl 0 bis 3 (Standard 0) | rw |
| | `assigneeId` | UUID eines aktiven Mitglieds oder `null` | rw |
| | `erledigtAt` | ISO-8601 oder `null` (auch die zuständige Person darf es setzen) | rw |
| | `erledigtVon` | UUID oder `null` (Server: Akteur beim Erledigen) | server |
| | `folgeId` | UUID oder `null` (Folgeaufgabe, auch die zuständige Person darf es setzen) | rw |
| | `wiederholungTag` | Ganzzahl 1 bis 31 oder `null` (Wunschtag, `monthly`) | rw |
| | `wiederholung` | `daily`, `weekly`, `monthly` oder `null` | rw |
| | `erinnerungMin` | Ganzzahl 0 bis 40320 oder `null` | rw |
| | `audience` | `parents`, `family` (Standard), `all` (wird `family`) | rw |
| | `ownerId` | UUID oder `null` (Ersteller; bestimmt das Änderungsrecht des Kindes) | server |
| | `createdAt` | ISO-8601 (UTC) | server |
| `aufgabe_punkt` | alles | erben Stufe, Besitzer und Zuständige der Aufgabe: lesen, wo die Aufgabe sichtbar ist; anlegen, ändern, löschen nur an **eigenen** Aufgaben (Kind); an zugewiesenen nur `doneAt` | |
| | `aufgabeId` | UUID (Pflicht) | create |
| | `text`, `doneAt`, `position` | siehe oben | rw |

Neue Entitäten (Dateien) tragen sich im Entitäten-Register des Servers (`server/src/sync/registry.ts`, `index.ts`) und der App (`app/lib/data/sync/sync_entities.dart`) ein; Protokoll und Rechte-Modell bleiben unverändert.

## Push (UnifiedPush, nur Android)

Push ist ein **Wecker ohne Inhalt**: kein Text, kein Titel, keine Tags, keine Namen. Das Gerät gleicht danach per `POST /sync` ab und zeigt selbst eine lokale Benachrichtigung. Der Server veröffentlicht auf dem eigenen ntfy (`NTFY_URL`, Loopback) mit dem Token `NTFY_TOKEN`; fehlt eines von beiden, ist Push still aus (ein Hinweis im Log, kein Fehler, `GET /me/push` meldet `available: false`).

- **Endpunkt melden (`PUT /me/push`)**: Das Gerät gehört immer zur Sitzung (nie eine ID im Body, der Body ist strikt). Akzeptiert wird nur ein Endpunkt der Form `https://<NTFY_PUBLIC_HOST>/up<12–64 Zeichen [A-Za-z0-9_-]>`, optional mit `?up=1` (so meldet ihn die ntfy-App: Präfix `up` plus 12 Zeichen); kein Port, keine Zugangsdaten, kein Fragment, keine Prozent-Kodierung, kein weiterer Pfad, keine IP. Geprüft wird auf dem Rohtext (kein URL-Parser). Gespeichert wird nur das Topic (`push_endpoints`, je Gerät eine Zeile). **Gepostet wird nie an die gemeldete URL**, sondern an `NTFY_URL` + Topic (SSRF-Schutz). Ein Topic gehört einem Gerät (bei fremdem Topic dieselbe Antwort `400 invalid_endpoint` wie bei ungültigem; die App meldet dann einmal ab und registriert neu, damit der Verteiler ein neues Topic vergibt); eine Neuanmeldung ersetzt den alten Endpunkt (Rotation) und aktiviert einen deaktivierten wieder. Strikt rate-limitiert wie die Anmeldung.
- **Auslöser**: Steigt die Revision der Familie durch eine Änderung im Sync, bekommen die Geräte einen Wecker, deren Person (1) aktiv ist und deren Rolle die Änderung sehen darf (dieselbe Rollen-Sicht wie beim WebSocket-Hinweis `rev`), (2) nicht das Gerät ist, das die Änderung ausgelöst hat (die anderen Geräte derselben Person werden geweckt und gleichen ab; ob danach eine Anzeige erscheint, entscheidet der `EreignisBenachrichtiger` der App, eigene Änderungen zeigt er nicht an), (3) keine lebendige WebSocket-Verbindung hat (Lebenszeichen, also Pong oder Nachricht, innerhalb von 1,5 Ping-Intervallen; ein wegen offener Verbindung nicht gesendeter Wecker wird nach Ablauf der Ping-Frist einmal nachgeprüft und dann gesendet, wenn die Verbindung nicht mehr lebendig ist), (4) vom Empfängerfilter zugelassen ist (siehe unten). Das Entfernen eines Mitglieds (Bereinigen von Verweisen) löst keinen Push aus.
- **Entprellung je Gerät**: höchstens ein Wecker je 10 s; was dazwischen anfällt, wird zu genau einem weiteren zusammengefasst. ntfy-`429` (mit `Retry-After`, höchstens 10 min) pausiert den Versand und fasst zusammen, ohne den Endpunkt zu bestrafen. `401/403` von ntfy (Token oder Rechte falsch) pausiert 5 min und lässt die Endpunkte unberührt (Betriebsfehler, im Log). Kein Wiederholen bei 4xx.
- **Netz-/5xx-Fehler** (Zeitlimit 5 s eingeschlossen) sind Störungen des ntfy, nicht des Geräts: globale Pause von 30 s, kein Zählen je Endpunkt (ein ntfy-Neustart deaktiviert keine Endpunkte), kein Wiederholen. Nach `429` und `401/403` wird je Gerät genau ein zusammengefasster Wecker nach der Pause neu geplant; ein Timer prüft die Pause beim Ablauf neu (wurde sie verlängert, wartet er die Restdauer).
- **Deaktivierung**: ntfy-`404/410` deaktiviert den Endpunkt sofort, 5 aufeinanderfolgende gezielte 4xx-Antworten (z. B. 400) ebenso; ein Erfolg setzt den Zähler zurück. Wieder aktiv durch erneutes `PUT /me/push`.
- **Löschen**: Abmelden (`/auth/logout`, `logout-all`, Gerät entfernen, Mitglied entfernen, Widerruf) löscht den Endpunkt; zusätzlich Fremdschlüssel `ON DELETE CASCADE` auf dem Gerät.
- **Empfängerfilter (Erweiterungsstelle für Chat)**: `app.push.addRecipientFilter(async (ev) => userIds | null)` (`server/src/push/service.ts`). `ev` trägt `familyId`, `rev`, `roles` (Rollen-Sicht) und `origin`. Der Chat liefert damit die Teilnehmer (Privatchats: nur diese); mehrere Filter wirken als Schnitt, `null` heißt keine Einschränkung. Ohne Filter gilt allein die Rollen-Sicht.
- **Test-Wecker** (`POST /me/push/test`) respektiert die globale Pause und hat ein eigenes Limit je Gerät. In der App heißt „angekommen“ nur, dass etwas ankam (es ist kein Herkunftsnachweis).
- **App**: `unifiedpush` initialisiert bei jedem Start (auch beim Hintergrund-Start durch das Plugin, `main(["--unifiedpush-bg"])`: nur abgleichen, keine Oberfläche); bei jedem Start erneut `register`; Hintergrund-Läufe dürfen **nie** das Refresh-Token einlösen (ApiClient `refreshErlaubt: false`: ist das Access-Token abgelaufen, endet der Lauf ohne Tokenzugriff, der nächste Start der App gleicht ab), laufen einzeln (Single-Flight) und höchstens alle 10 s (Wecker dazwischen werden zu einem Lauf), mit Höchstdauer 25 s; `onNewEndpoint` -> `PUT /me/push`; `onMessage` (Inhalt wird verworfen) -> Abgleich, danach die Schnittstelle `EreignisBenachrichtiger.neueEreignisse(rev, vorher)` (`app/lib/data/push/push_wecker.dart`) für lokale Benachrichtigungen (der Erinnerungs-Zweig hängt dort seine Umsetzung ein).

## WebSocket `/ws`

1. `POST /ws-ticket` (angemeldet) → `{ ticket }`.
2. `wss://familie.lx-labs.dev/ws` öffnen (kein Ticket in der URL!); der Server sendet `{type:"hello", protocolVersion, serverVersion}`.
3. Als **erste Nachricht** `{ "type": "auth", "ticket": "<ticket>" }` senden (innerhalb von 5 s). Antwort `{type:"ready"}`; bei ungültigem, abgelaufenem oder schon benutztem Ticket schließt der Server mit Code `4401` und zählt den Fehlversuch gegen die IP.
   Danach meldet der Server nach **jedem Commit einer Änderung** im Sync den Sockets der Familie, **deren Rolle die Änderung sehen darf**, `{ "type": "rev", "rev": N }` (ohne Inhalt; auch an das Gerät, das die Änderung gesendet hat). Wer einen Datensatz nicht sehen darf, erfährt nicht einmal, dass es eine Änderung gab; entzieht eine Änderung die Sicht (Freigabe zurückgenommen), erfahren es die Rollen vorher und nachher. Das Bereinigen von Verweisen beim Entfernen eines Mitglieds geht an alle Rollen. Änderungen an **Privatchats** (Direkt- und Gruppenchats) gehen nur an deren Teilnehmer (nach Person, nicht nach Rolle). Der Client gleicht daraufhin ab (`POST /sync`), wenn `N` größer als sein Stand ist. Der Client kann `{ "type": "ping" }` senden und bekommt `{ "type": "pong" }` (die App tut das alle 25 s und verbindet neu, wenn das Pong ausbleibt).
4. Browser mit gültigem Session-Cookie sind schon beim Upgrade angemeldet.
5. Limits: Nachrichten je Socket (30 je 10 s, sonst Code `4429`), Verbindungen je IP (IPv6: je /64; 10, vor dem Upgrade `429`) und je Person (8, Code `4429`).
6. **Widerruf:** Abmelden, Gerät entfernen, „überall abmelden“, Rollenwechsel und Entfernen schließen die betroffenen Sockets sofort mit Code `4401`. Zusätzlich prüft der Server bei jedem Ping (30 s), ob Sitzung und Mitgliedschaft noch gelten (sonst `4401`), und hält die Rolle der Verbindung aktuell.
7. **Standort teilen:** zusätzliche Nachrichten `loc_*`, siehe Abschnitt „Standort“ unten.

## Standort (WebSocket `loc_*`, flüchtig)

Standort teilen läuft **nur über den WebSocket** und **nur im Prozessspeicher** des Servers: keine Tabelle, keine Migration, kein Backup, keine Historie, nichts im Log (nicht einmal Kennungen von Freigaben). Der Server reicht opake Pakete weiter; Wrap und Paket sind für ihn Base64url-Zeichenketten, geprüft werden nur Form (`^[A-Za-z0-9_-]+$`) und Länge. Aufbau und Verfahren: `docs/PROJEKTBESCHREIBUNG.md`, Abschnitt 6f. Alle `loc_*`-Nachrichten brauchen eine angemeldete Verbindung (vorher `error` `unauthenticated`) und zählen für das Nachrichtenlimit je Socket. `loc_start`, `loc_pos`, `loc_extend` und `loc_stop` werden je Socket der Reihe nach verarbeitet.

**Client → Server**

| Nachricht | Inhalt und Regeln |
| --- | --- |
| `loc_start` | `{ shareId (UUID, vom Client), endsAt (Epoch-ms, in der Zukunft, höchstens `LOC_MAX_DURATION_MS` = 12 h ab jetzt), recipients: [{ userId, wrap }] }`. 1 bis 30 Empfänger, jede ID einmal, **nur aktive Mitglieder der Familie der Sitzung, nie die Person selbst** (Regel `locationRecipients` in `sync/permissions.ts`; Mitglieder kommen aus der Datenbank). Eine neue Freigabe **ersetzt** die alte derselben Person (die alte endet mit `replaced`). Antwort `loc_started`. |
| `loc_pos` | `{ shareId, packet }`, Paket ≤ 1024 Zeichen. Nur vom **Gerät, das gestartet hat** (gleiche Person und Gerät). Mindestabstand je Freigabe `LOC_MIN_INTERVAL_MS` (1000), sonst `loc_error` `rate_limited` (das Paket wird verworfen, nichts endet). |
| `loc_extend` | `{ shareId, endsAt }`, gleiche Grenzen wie beim Start. Antwort `loc_active`. |
| `loc_hello` | `{}`. Die Verbindung gehört dem Standort-Kanal der App: der Server zählt sie weder als „Gerät ist live“ (Push) noch schickt er ihr `rev`-Hinweise. |
| `loc_stop` | `{ shareId }`. Beendet; Empfänger bekommen `loc_stop` mit `reason: "stopped"`. |

**Server → Client**

| Nachricht | Inhalt |
| --- | --- |
| `loc_started` / `loc_active` | `{ shareId, endsAt }` an den Sender: bestätigt Start bzw. Verlängern; `loc_active` kommt außerdem, wenn sich das Sendergerät innerhalb der Schonfrist wieder verbindet. |
| `loc_start` | `{ from, shareId, endsAt, wrap }` an **jeden Empfänger einzeln, nur mit dessen eigenem Wrap**; ein später verbundener Empfänger bekommt es beim Anmelden nachgereicht, danach die letzte Position als `loc_pos`. |
| `loc_extend` | `{ from, shareId, endsAt }` an die Empfänger, wenn der Sender verlängert. |
| `loc_pos` | `{ from, shareId, packet }` an die Empfänger der Freigabe (nie an den Sender, nie an Unbeteiligte oder andere Familien). |
| `loc_stop` | `{ from, shareId, reason }` an Empfänger und Sender; `reason`: `stopped`, `expired`, `disconnected`, `removed`, `replaced`. |
| `loc_error` | `{ code, shareId? }`: `bad_request`, `bad_duration`, `bad_recipients`, `share_exists`, `rate_limited`, `too_many_shares`, `forbidden`, `unknown_share` (auch für fremde Freigaben und Sendungen vom falschen Gerät), `unavailable`. |

**Auto-Ende:** Ablauf (`endsAt`), `loc_stop`, Widerruf (Abmelden, Gerät oder Mitglied entfernen, Rollenwechsel: sofort), **Sendergerät länger als `LOC_GRACE_MS` (90 s) ohne Verbindung**, Sender nicht mehr aktives Mitglied. Entfernte Empfänger werden bei der regelmäßigen Prüfung (Abstand 12 × `LOC_SWEEP_MS`) aus der Freigabe genommen. **Limits:** 10 Starts je Person in 10 Minuten, `LOC_MAX_SHARES_PER_FAMILY` (50) Freigaben je Familie, Wrap ≤ 1024 und Paket ≤ 1024 Zeichen. Einstellungen: `server/.env.example`.

## Audit-Log

Ereignisse (`audit_log.event`; `invite_expired` einmal je Ablauf einer nicht gesperrten, nicht benutzten, nicht widerrufenen Einladung, ausgelöst vom stündlichen Aufräum-Job, nie beim Abruf): `bootstrap_created`, `invite_created`, `invite_used`, `invite_revoked`, `invite_extended`, `invite_expired`, `invite_pin_failed`, `invite_locked`,
`member_registered`, `member_approved`, `member_rejected`, `member_removed`, `member_reset`, `role_changed`, `login_ok`, `login_failed`, `device_added`, `device_removed`, `logout`, `logout_all`,
`session_reuse_detected`, `session_refresh_retry`, `step_up_ok`, `step_up_failed`, `passkey_added`, `passkey_removed`, `passkey_counter_regression`, `recovery_codes_created`, `recovery_code_used`, `ws_auth_failed`, `key_created`, `key_rotated`, `backup_set`, `key_backup_read`, `transfer_claimed`.
Die IP-Adresse steht höchstens 7 Tage im Eintrag; Token, Passwörter, PINs und Codes werden nie protokolliert.
