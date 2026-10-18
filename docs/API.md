# API (Phase 1a: Konten und Anmeldung)

Stand: Phase 1a. Basis: `https://familie.lx-labs.dev/api/v1`, REST mit JSON (`Content-Type: application/json`). Der Sync (`/sync`) folgt in
Phase 1c und antwortet bis dahin mit `501`. Diese Beschreibung ist Markdown statt OpenAPI; die Validierung steckt in den Zod-Schemas in
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
| 404 | nicht gefunden (auch für Objekte einer fremden Familie) |
| 409 | Konflikt (`last_admin`, `last_credential`, `invite_not_open`, `registration_failed`, ...) |
| 413 / 415 | Body zu groß / kein JSON |
| 429 | Rate-Limit (`rate_limited`) oder verzögerte Sperre nach Fehlversuchen (`too_many_attempts`, Header `Retry-After` in Sekunden) |

Antworten der API tragen `Cache-Control: no-store`.

**Anmeldearten und Sitzungen**

- **Web (Cookie):** Nach der Anmeldung setzt der Server `__Host-lxsid=<Token>; Path=/; Secure; HttpOnly; SameSite=Strict` (kein `Domain`). Die Antwort enthält
  `session.csrfToken`; **jede ändernde Anfrage (POST, PUT, PATCH, DELETE)** mit Cookie muss es im Header `X-CSRF-Token` mitsenden (sonst `403 csrf_invalid`).
  Zusätzlich wird ein fremder `Origin`-Header bei ändernden Anfragen abgelehnt (`403 origin_not_allowed`). `GET /me` liefert das Token erneut (nach einem Neuladen).
  Cookie-Sitzung: 30 Tage absolut, 7 Tage Leerlauf.
- **App (Token):** Anmeldung mit `client: "app"` und `device`. Antwort: `accessToken` (15 min, `Authorization: Bearer <accessToken>`, kein CSRF-Header nötig),
  `refreshToken` (einmal einlösbar, 90 Tage absolut, 30 Tage Leerlauf) und `deviceId`. `POST /auth/refresh` tauscht das Refresh-Token gegen ein neues Paar (Rotation).
  Wird ein bereits eingelöstes Refresh-Token erneut vorgelegt (auch gleichzeitig), widerruft der Server die **ganze Token-Familie** und schreibt `session_reuse_detected` ins Audit-Log.
  Ein vorhandener, aber ungültiger `Authorization`-Header fällt nie auf das Cookie zurück.
- **Step-up:** Die Anmeldung zählt als frische Bestätigung. Wiederverwendbare Prüfung (`requireStepUp`, 5 Minuten): Rollenänderung, Mitglied entfernen/zurücksetzen,
  Admin-Einladung erzeugen, neuen Passkey hinzufügen/entfernen, Wiederherstellungs-Codes neu erzeugen (später: Tresor, Familie löschen). Ist die Bestätigung älter,
  antwortet der Server mit `403 step_up_required`; die Bestätigung erfolgt über `/auth/step-up/*`.

**Rate-Limits:** 300 Anfragen/min je IP insgesamt; `/auth/*`, `/ws-ticket`, `/invites` (POST), `/members/:id/reset` und `/me/passkeys/*` strenger (10/min). Zusätzlich zählt der Server
Fehlversuche (Passwort, TOTP, Wiederherstellungs-Code, Step-up) je **IP**, je **Konto** und je **Paar aus Konto und IP** und sperrt verzögert: Konto+IP ab 5, IP ab 20, Konto ab 10 Fehlversuchen
30 s, danach doppelt so lang, **höchstens 90 s** (so lässt sich ein fremdes Konto nicht lange aussperren; die tippende IP ist früher dran als das Konto). Anmeldung und Step-up teilen sich denselben Konto-Schlüssel.
**Passkey-Anmeldungen hängen nicht an der Konto-Sperre** (nur IP-Sperre). IPv6-Adressen gelten als **/64-Präfix** (IP-Sperre, Rate-Limit, Verbindungslimit am WebSocket); IPv4-in-IPv6 als IPv4.
WebSocket-Anmeldefehler zählen mit. Die Erzeugung von Challenges ohne Anmeldung (`/auth/login/passkey/options`, Start der Registrierung) ist je IP-Präfix (20) und insgesamt (2000 offene) begrenzt, sonst `429 rate_limited`.

**Eingaben:** Zeichenketten mit NUL (`\u0000`) oder einzelnen Surrogaten (`\ud800`) werden überall (auch verschachtelt und in Schlüsseln) mit `400 invalid_request` abgelehnt.
**Überlast:** Sind alle Passwort-Berechnungen (Argon2id, 2 gleichzeitig) und die Warteschlange (16) belegt, antwortet der Server `503 server_busy` mit `Retry-After` (kein Fehlversuch wird gezählt).

**Rollen:** `admin`, `parent`, `child`, `guest`. Alle Zugriffe sind auf die eigene Familie begrenzt; Objekte einer fremden Familie liefern `404`.

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
| `POST /auth/login/password` | `{ email, password, totp \| recoveryCode, client?, device? }` | `{ user, session }`; **Passwort nur mit zweitem Faktor**; ein TOTP-Zeitschritt gilt nur einmal (Replay-Schutz) |
| `POST /auth/login/recovery` | `{ email, code, client?, device? }` | `{ user, session, recoveryCodesRemaining }`; Einmal-Code, Sitzung gilt als frisch bestätigt |
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
| `GET /me` | alle | `{ user, familyId, session, csrfToken?, credentials: { passkeys, password, totp }, recoveryCodesRemaining }` |
| `PATCH /me` | alle | `{ displayName?, colorIndex? (0–9) }` |
| `GET /me/credentials` | alle | `{ credentials: [{ id, type, label, createdAt, lastUsedAt }] }` (nie Geheimnisse) |
| `POST /me/passkeys/options` | alle, Step-up | neuer Passkey: `{ challengeId, options }` |
| `POST /me/passkeys/verify` | alle, Step-up | `{ challengeId, response, label? }` → `{ id }` |
| `DELETE /me/passkeys/:id` | alle, Step-up | entfernt einen Passkey; der letzte Zugang bleibt (`409 last_credential`) |
| `POST /me/recovery-codes` | alle, Step-up | `{ recoveryCodes[10] }`; die alten Codes entfallen |
| `GET /devices` | alle | `{ devices: [{ id, name, platform, appVersion, createdAt, lastSeenAt, current }] }` |
| `DELETE /devices/:id` | alle | meldet ein eigenes Gerät ab |
| `POST /ws-ticket` | alle | `{ ticket, expiresInSec: 30 }`: Einmal-Ticket (256 Bit) für den WebSocket |

### Mitglieder

| Methode, Pfad | Rolle | Beschreibung |
| --- | --- | --- |
| `GET /members` | alle | Admins: alle Mitglieder (auch wartende) inkl. E-Mail; andere: nur aktive Mitglieder, **ohne E-Mail – außer der eigenen** |
| `PATCH /members/:id/role` | admin, Step-up | `{ role }`; **alle Sitzungen der Person werden widerrufen** (offene WebSockets schließen mit `4401`); bei **Herabstufung** werden ihre offenen Einladungen widerrufen; der letzte Admin kann nicht herabgestuft werden |
| `POST /members/:id/approve` | admin | gibt ein wartendes Mitglied frei |
| `POST /members/:id/reject` | admin | lehnt ein wartendes Mitglied ab: löscht die Mitgliedschaft; das Konto nur, wenn keine weitere Mitgliedschaft besteht |
| `POST /members/:id/reset` | admin, Step-up | `{ hours?, pin? }` (**keine E-Mail, kein Name**: das Konto bleibt) → `{ invite }`: widerruft Anmeldedaten, Codes und Sitzungen und erzeugt eine neue Einladung für dasselbe Konto; beim Annehmen entfallen `email` und `displayName` |
| `DELETE /members/:id` | admin, Step-up | entfernt ein Mitglied (nicht sich selbst, nicht den letzten Admin): löscht die Mitgliedschaft samt Geräten und Sitzungen, widerruft offene Einladungen von und für die Person, schließt ihre WebSockets; das Konto nur, wenn keine weitere Mitgliedschaft besteht |

### Einladungen

| Methode, Pfad | Rolle | Beschreibung |
| --- | --- | --- |
| `POST /invites` | admin (alle Rollen, Admin-Einladung mit Step-up), parent (nur `child`, `guest`) | `{ role, hours? (1–168, Standard 24), pin? (bool), requireApproval? }` → `{ invite: { id, token, link, pin?, expiresAt, requireApproval } }`. **Token und PIN erscheinen nur in dieser Antwort.** Gäste sind standardmäßig `requireApproval`, andere nicht; **`requireApproval: false` bei Gästen darf nur ein Admin** (für Eltern erzwingt der Server `true`). |
| `GET /invites` | admin (alle), parent (eigene) | `[{ id, role, status: open\|used\|revoked\|locked\|expired, createdAt, expiresAt, hasPin, requireApproval, reset, createdBy, usedBy }]` ohne Token und PIN |
| `POST /invites/:id/revoke` | wie oben | widerruft eine offene Einladung; wer die Rolle der Einladung nicht (mehr) einladen darf, bekommt `403` |
| `POST /invites/:id/extend` | wie oben | `{ hours }` → `{ expiresAt }`: setzt die Gültigkeit auf **das spätere** von bisheriger Ablaufzeit und jetzt + `hours` (**verkürzt nie**; höchstens 7 Tage je Aufruf); gesperrte Einladungen bleiben gesperrt; Rollenprüfung wie bei `revoke` |

## WebSocket `/ws`

1. `POST /ws-ticket` (angemeldet) → `{ ticket }`.
2. `wss://familie.lx-labs.dev/ws` öffnen (kein Ticket in der URL!); der Server sendet `{type:"hello"}`.
3. Als **erste Nachricht** `{ "type": "auth", "ticket": "<ticket>" }` senden (innerhalb von 5 s). Antwort `{type:"ready"}`; bei ungültigem, abgelaufenem oder schon benutztem Ticket schließt der Server mit Code `4401` und zählt den Fehlversuch gegen die IP.
4. Browser mit gültigem Session-Cookie sind schon beim Upgrade angemeldet.
5. Limits: Nachrichten je Socket (30 je 10 s, sonst Code `4429`), Verbindungen je IP (IPv6: je /64; 10, vor dem Upgrade `429`) und je Person (8, Code `4429`).
6. **Widerruf:** Abmelden, Gerät entfernen, „überall abmelden“, Rollenwechsel und Entfernen schließen die betroffenen Sockets sofort mit Code `4401`. Zusätzlich prüft der Server bei jedem Ping (30 s), ob Sitzung und Mitgliedschaft noch gelten (sonst `4401`), und hält die Rolle der Verbindung aktuell.

## Audit-Log

Ereignisse (`audit_log.event`; `invite_expired` einmal je Ablauf einer nicht gesperrten, nicht benutzten, nicht widerrufenen Einladung, ausgelöst vom stündlichen Aufräum-Job, nie beim Abruf): `bootstrap_created`, `invite_created`, `invite_used`, `invite_revoked`, `invite_extended`, `invite_expired`, `invite_pin_failed`, `invite_locked`,
`member_registered`, `member_approved`, `member_rejected`, `member_removed`, `member_reset`, `role_changed`, `login_ok`, `login_failed`, `device_added`, `device_removed`, `logout`, `logout_all`,
`session_reuse_detected`, `step_up_ok`, `step_up_failed`, `passkey_added`, `passkey_removed`, `passkey_counter_regression`, `recovery_codes_created`, `recovery_code_used`, `ws_auth_failed`.
Die IP-Adresse steht höchstens 7 Tage im Eintrag; Token, Passwörter, PINs und Codes werden nie protokolliert.
