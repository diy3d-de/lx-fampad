# Testfamilie: Ablaufblatt zur Schlüsselverlust-Matrix

Manuelle Prüfung, dass bei Anmeldung, Zurücksetzen, Gerätewechsel und Browser-Aufräumen **kein Schlüssel und kein Chatverlauf unbemerkt verloren geht**. Gilt für Stand v0.6.5 (Abschnitt 9a der Projektbeschreibung). Die automatischen Tests stehen in `server/test/kein-datenverlust.test.ts`, `server/test/schluessel-matrix.test.ts`, `app/test/kein_datenverlust_test.dart`, `app/test/schluessel_matrix_test.dart`, `app/test/crypto/e2ee_controller_test.dart` und `app/test/web/schluessel_speicher_web_test.dart`; dieses Blatt deckt ab, was nur auf echten Geräten und im echten Browser zu sehen ist.

## Regeln (vorher lesen)

- **Nie auf der Produktion** (`familie.lx-labs.dev`) und **nie mit dem Betreiber-Konto oder einem Konto der echten Familie**. Die Testfamilie bekommt eine **eigene Instanz** mit eigener Datenbank, eigenem `AUTH_SECRET_KEY` und eigener Adresse. Debug-APKs (Debug-Schlüssel) gehören nur an diese Instanz (`deploy/README.md`, Abschnitt 9).
- Alle Konten sind Wegwerf-Konten mit erfundenen E-Mail-Adressen (z. B. `anna@test.invalid`). Es werden keine echten Chats, Fotos oder Daten benutzt.
- **Vor jedem Block ein Snapshot** der Testdatenbank (`pg_dump`), damit ein Versuch wiederholt werden kann. Nach „Hat etwas Unerwartetes verloren“ nichts mehr anfassen, erst Stand sichern.
- Der Betreiber-Bereich „Betrieb“ ist nicht nötig. Wer die Schlüssel-Ampel ansehen will, legt für die Testinstanz **ein eigenes Test-Konto** als Betreiber an (`node dist/cli/operator.js grant <E-Mail>` auf der Testinstanz), nie das echte.
- Jeder Schritt hat **Erwartet** und, wo es wichtig ist, **Nicht erlaubt**. Weicht etwas ab: Schritt, Gerät, Uhrzeit und Bildschirmfoto festhalten und als Fehler melden.

## 0. Vorbereitung

### Testinstanz

1. Server-Stand `v0.6.5` (oder der zu prüfende Stand) auf einer **eigenen** Instanz einrichten: eigene PostgreSQL-17-Datenbank, eigene Adresse mit HTTPS (z. B. `test-familie.<eigene Domain>`), `E2EE_PW_BACKUP=true` (sonst fehlt die Passwort-Sicherung). Ablauf wie in `deploy/README.md`; lokal zum Ausprobieren der Server-Seite genügt eine Docker-Datenbank (`postgres:17`), `npm ci && npm run build && npm run migrate` in `server/`.
2. Erstkonto der Testfamilie anlegen: `node dist/cli/bootstrap.js --family "Testfamilie"`; der Link erscheint nur dort.
3. Web-App und (für Handy-Tests) ein APK **gegen diese Instanz** bauen (`--dart-define=API_BASE=https://<Testadresse>`, `INVITE_HOST` entsprechend). Android braucht HTTPS.

### Personen und Geräte

| Kürzel | Wer | Rolle | Geräte |
| --- | --- | --- | --- |
| **Anna** | Erwachsene, zweiter Admin (mindestens zwei Admins!) | Admin | **A1** Android-Handy 1, **W1** Browser-Profil 1 (Chrome) |
| **Ben** | Erwachsener | Elternteil | **B1** Android-Handy 2 |
| **Cora** | Kind | Kind | **C1** Browser-Profil 2 (Chrome, zweites Profil) |
| **Dora** | Wegwerf-Konto für die zerstörerischen Fälle (3, 10, 12) | Elternteil | **D1** Browser-Profil 3 (Chrome) |

Eine Person, die nur in einem Browser-Profil sitzt (Cora), ist der Normalfall für „Gerät weg = Schlüssel weg“. **W2** ist ein weiteres, leeres Browser-Profil für „neues Gerät“ (Fälle 4, 6, 12).

### Grundzustand (einmal aufbauen)

1. Anna registriert sich über den Link (Passkey **oder** Passwort + Authenticator-Code), notiert die **Wiederherstellungscodes** (Papier).
2. Anna legt in der App Profil › Verschlüsselung „Verschlüsselung einrichten“ an, **notiert den Wiederherstellungsschlüssel auf Papier**, tippt ihn bei der Kontrolle vollständig ein. Erwartet: Pille „Aktiv“ (grün) und „liegt beim Server (seit …)“. Ohne die Kontrolle bleibt es gelb mit „Sicherung offen“.
3. Anna lädt Ben, Cora und Dora ein (Profil › „Familie verwalten“ › Einladung), jeder richtet Verschlüsselung ein und notiert den Wiederherstellungsschlüssel (Dora nur, wo ein Fall es verlangt). Anna, Ben und Cora legen außerdem unter „Passwort-Sicherung“ eine Passwort-Sicherung an (nur sichtbar, wenn der Server `E2EE_PW_BACKUP` hat).
4. Anna legt eine Gruppe „Test“ mit Ben und Cora an (Sicherheitscode bestätigen) und schreibt **sechs Nachrichten** (z. B. „Eins“ bis „Sechs“); Ben und Cora antworten je einmal. Dora schreibt im Familienchat eine Nachricht (für Fall 12).
5. Auf allen Geräten Chat öffnen: alles lesbar. **Das ist der Soll-Zustand, gegen den jeder Fall vergleicht.**

> Sicherungsstand prüfen (SQL auf der Testdatenbank): `select user_id, key_version from person_keys;`, `select user_id, key_version, updated_at from key_backups;`, `select user_id, state, verified_at from key_backups_pw;`, `select user_id, kind, reason from key_backup_archive;`.

## 1. Fälle

### Fall 1: Abmelden und wieder Anmelden (Schlüssel bleibt)

1. A1: Profil › „Abmelden“. Im Dialog steht: „Dein Schlüssel bleibt auf diesem Gerät …“ und der Hinweis auf „Gerät abgeben“. Abmelden bestätigen.
2. A1: wieder anmelden (gleiche Person).
3. Chat öffnen.

**Erwartet:** Chat nach kurzer Zeit (Abgleich) wieder lesbar, **alle sechs plus zwei** Nachrichten, ohne Wiederherstellungsschlüssel, ohne QR. Profil › Verschlüsselung zeigt „Aktiv“.
**Nicht erlaubt:** „Gerät nicht verbunden“, Aufforderung, einen Schlüssel einzurichten, „Verlauf nicht lesbar“.
Wiederholen auf W1 (Browser) und mit „Überall abmelden“ (Anna; andere Geräte behalten ihren Schlüssel). Wiederholen mit Personenwechsel: Auf B1 meldet sich Ben ab, **Anna** meldet sich auf B1 an (Annas Schlüssel ist dort nicht), dann meldet sich Anna ab und Ben wieder an: Ben liest wieder alles, Anna hat auf B1 „Gerät nicht verbunden“, nie Bens Schlüssel.

### Fall 2: Gerät wird aus der Geräteliste entfernt oder die Sitzung wird widerrufen

1. Anna entfernt in Profil › „Angemeldete Geräte“ das Gerät **W1** (von A1 aus).
2. W1: Seite neu laden → Anmeldeseite (Sitzung weg).
3. W1: anmelden.

**Erwartet:** Nach der Anmeldung Chat wieder lesbar (der Schlüssel lag im Browser und wurde nicht angetastet). Die Anmeldeseite zeigt keinen Hinweis, dass der Schlüssel gelöscht wurde.

### Fall 3: „Gerät abgeben – alles löschen“

1. **Ohne Sicherung:** Eine neue Person „Dora“ (nur zum Test) richtet Verschlüsselung ein, **überspringt** die Kontrolle („Später sichern“). Profil › Verschlüsselung › „Erweitert“ › „Gerät abgeben – alles löschen“.
   **Erwartet:** gesperrt, Text „Lege zuerst eine Sicherung an.“ und der Knopf „Sicherung anlegen“. Nichts wird gelöscht.
2. **Mit Sicherung** (Anna auf A1): „Gerät abgeben – alles löschen“. Der Dialog verlangt einen Haken („Ohne meine Sicherung … kommt mein Verlauf nicht zurück“) und das **getippte Wort „löschen“**. Ohne Haken oder falsches Wort bleibt der Knopf aus.
3. Abbrechen: **nichts** wird gelöscht (Chat danach weiter lesbar, kein Abmelden).
4. Bestätigen: A1 meldet ab, Schlüssel und lokale Daten sind weg, Meldung „Schlüssel und lokale Daten sind von diesem Gerät gelöscht, du bist abgemeldet.“
5. A1 wieder anmelden → „Dieses Gerät ist nicht verbunden“ → „Mit Wiederherstellungsschlüssel verbinden“ (Papier) → Chat lesbar, **derselbe** Sicherheitscode wie vorher.
6. Sonderfall Quarantäne vorhanden (nach Fall 5): Im Dialog erscheint ein **zusätzlicher Pflicht-Haken mit Anzahl** („Auf diesem Gerät liegen noch N frühere Schlüssel …“).

**Nicht erlaubt:** Löschen ohne bestätigte Sicherung; Löschen durch „Abbrechen“; Löschen ohne getipptes Wort. Ein unbekannter Stand zählt nie als „gesichert“: Bei Flugmodus **vor** dem Öffnen der Seite fehlt der Bereich „Gerät abgeben“ ganz (nur „Erneut versuchen“); schaltest du den Flugmodus erst **nach** dem Öffnen ein, meldet der Knopf „Der Stand deiner Sicherung ließ sich gerade nicht prüfen. Es wurde nichts gelöscht.“

### Fall 4: Neues Gerät verbinden per QR oder Code

1. Anna auf A1: Profil › Verschlüsselung › „Neues Gerät verbinden“ → QR und Code erscheinen (2 Minuten gültig).
2. Neues Gerät (Browser-Profil W2, Anna angemeldet): „Mit anderem Gerät verbinden“, Code eintippen (im Web nur Eintippen/Einfügen) bzw. am Handy scannen.
3. Denselben Code ein zweites Mal verwenden. Außerdem einen Code **nach 2 Minuten** verwenden.
4. Als Ben denselben Code eintippen.

**Erwartet:** 2. Gerät sieht „Aktiv“, **gleicher Sicherheitscode**, Chat lesbar, alter Verlauf vollständig. Zweites Einlösen, Ablauf und fremde Person: Meldung „abgelaufen oder schon benutzt“ bzw. Fehler, **kein** Schlüsselwechsel. A1 behält seinen Schlüssel.

### Fall 5: Defekter Schlüssel im Speicher → Quarantäne statt Löschen

Nur im Browser gut herbeizuführen.

1. W1 (Anna angemeldet, Chat lesbar). Entwicklerwerkzeuge › Application › IndexedDB › `lx-fampad-e2ee` › `kv`: den Eintrag **`__wrap`** löschen (der Wrapper-Schlüssel), Seite neu laden.
2. Profil › Verschlüsselung ansehen.
3. „Mit Wiederherstellungsschlüssel verbinden“.

**Soll:** „Dieses Gerät ist nicht verbunden“ (nicht „Nicht eingerichtet“!), unter „Erweitert“/Hinweisen ein Eintrag **„Alter Schlüssel auf diesem Gerät · seit …“** (der nicht lesbare Eintrag wurde unverändert aufbewahrt, nicht gelöscht). Nach dem Verbinden: derselbe Schlüssel wie vorher, Chat lesbar, der alte Eintrag bleibt als Hinweis stehen, bis jemand ihn mit dem getippten Wort „löschen“ **verwirft** (Knopf „Verwerfen“).
**Sind alle Einträge unlesbar** (auch die gemerkten Schlüssel der Familie, was bei fehlendem Wrapper-Schlüssel immer so ist; Lücke L-2, behoben): „Dieses Gerät ist nicht verbunden“ mit den Verbinden-Wegen und der Meldung „Der Schlüsselspeicher dieses Geräts ist nicht mehr lesbar …“ samt Knopf „Vertrauen zurücksetzen“ (die gemerkten Schlüssel der Familie sind verloren und werden danach beim ersten Sehen neu gemerkt: Sicherheitscodes mit den Personen vergleichen). Auf Android steht zusätzlich „Gerätespeicher zurücksetzen“ bereit (siehe L-1). Der Schlüssel liegt in der Quarantäne. Dasselbe Bild ist auf Android denkbar, wenn der Keystore-Schlüssel verloren geht; das Plugin löscht dort nicht mehr selbst (L-1, behoben).
**Nicht erlaubt:** stilles Anlegen eines neuen Schlüssels, Meldung „Verschlüsselung einrichten“ ohne Hinweis, automatisches Löschen des alten Eintrags.

### Fall 6: Browser-Daten gelöscht, Speicher nicht dauerhaft

1. W2 (Chrome-Profil): Anna angemeldet, verbunden, Chat lesbar. Hinweis auf der Seite beachten: Verweigert der Browser den dauerhaften Speicher, steht „Der Browser darf diese Daten löschen …“ und der Knopf „Dauerhaften Speicher anfragen“.
2. Chrome › Einstellungen › „Websitedaten“ › für die Testadresse **alle Daten löschen** (Cookies **und** Speicher).
3. Seite öffnen, anmelden.

**Erwartet:** Anmeldung geht, danach „Dieses Gerät ist nicht verbunden“ (Schlüssel war nur lokal). **Kein** neuer Schlüssel, kein „Verschlüsselung einrichten“. Verbinden mit dem Wiederherstellungsschlüssel oder per Code von A1 (Fall 4) stellt den **alten** Schlüssel her, Chat lesbar.
**Nicht erlaubt:** dass der Server-Schlüssel ersetzt wird (Sicherheitscode ändert sich; bei anderen Mitgliedern erscheint „Der Schlüssel von … hat sich geändert“).
Zusatz: „Dauerhaften Speicher anfragen“ klicken und Ergebnis notieren (Chrome erlaubt es je nach Nutzung; ein privates Fenster verweigert es).

### Fall 7: Passwort zurücksetzen durch den Admin („leicht“)

1. Anna (Admin): „Familie verwalten“ › Menü bei **Ben** › „Passwort zurücksetzen“ → Link erzeugen (Gültigkeit, optional PIN). Der Dialog sagt: „Der Chat-Verlauf bleibt nur erhalten, wenn Ben ein Gerät mit dem eigenen Schlüssel oder den Wiederherstellungsschlüssel hat.“
2. Ben öffnet den Link (B1 oder anderer Browser), setzt das neue Passwort, gibt seinen Authenticator-Code ein (der zweite Faktor ist Pflicht).
3. Auf B1: neu anmelden (alle Geräte von Ben wurden abgemeldet).
4. Ben: Profil › Verschlüsselung › Passwort-Sicherung.

**Erwartet:** B1 liest den Chat (Schlüssel lag auf dem Gerät). Die Passwort-Sicherung ist „veraltet“, die App bietet „Sicherung erneuern“ an (oder legt sie nach der Anmeldung selbst neu an); danach „geprüft“. Der Wiederherstellungsschlüssel von Ben **gilt unverändert**. Sicherheitsereignisse (Profil) zeigen „Passwort zurückgesetzt“ für Ben; ein Wecker auf den anderen Geräten ohne Inhalt.
SQL: `select state from key_backups_pw where user_id = '<Ben>'` → `stale` (die alte, nie gelöscht), dann `active`/`superseded` nach der Erneuerung; `person_keys` unverändert.
**Nicht erlaubt:** neuer Personenschlüssel, „Verschlüsselung einrichten“, Verlust des Verlaufs.
Variante ohne Schlüssel-Gerät: Cora (nur C1 im Browser) wird zurückgesetzt, **dann C1-Browserdaten löschen** (Fall 6), anmelden: „Dieses Gerät ist nicht verbunden“; Verbinden mit **Wiederherstellungsschlüssel** klappt, „Mit Passwort verbinden“ erklärt, dass die alte Sicherung mit dem **alten** Passwort geöffnet wird.

### Fall 8: „Passwort vergessen?“ mit Wiederherstellungscode (Selbst-Reset)

1. Anmeldeseite von Ben: „Passwort vergessen? Neues Passwort festlegen“, E-Mail, **ein Wiederherstellungscode**, neues Passwort.
2. Auf B1 (mit Schlüssel): nach dem Reset ist die App angemeldet. Chat lesbar? Passwort-Sicherung erneuert?
3. Auf einem Gerät **ohne** Schlüssel (frisches Browser-Profil): dasselbe, danach „Gerät nicht verbunden“.

**Erwartet:** Mit Schlüssel-Gerät: neue Passwort-Sicherung wird mit dem neuen Passwort angelegt und geprüft, Hinweis erscheint, alter Verlauf bleibt lesbar. Ohne Schlüssel-Gerät: **kein neuer Schlüssel**, ein Hinweis erklärt, dass der Verlauf nur mit Gerät oder Wiederherstellungsschlüssel zurückkommt. Der verbrauchte Code ist weg (9 übrig). Ereignis „Passwort per Wiederherstellungscode zurückgesetzt“ bei Ben.
**Wichtig danach:** diese Sitzung ist **24 Stunden gesperrt** für Schlüsselwechsel, Passkey/Passwort ändern, Codes neu erzeugen, Mitglieder entfernen (Fall 9).

### Fall 9: 24-Stunden-Sperre (`destructive_locked`)

1. Anna meldet sich auf einem **neuen Browser-Profil** mit **Wiederherstellungscode** an („Passwort verloren? Mit Wiederherstellungscode anmelden“).
2. In dieser Sitzung (bis zu 24 Stunden): Profil › Verschlüsselung › „Erweitert“ › „Neuen Schlüssel erzeugen …“ (Checkliste, vier Haken, Wort „ersetzen“) → Schlüsselwechsel versuchen. Außerdem versuchen: Profil › „Wiederherstellungscodes“ (neue Codes erzeugen), „Passkeys“ › „Passkey hinzufügen“, „Passwort und Zwei-Faktor (TOTP)“ › „Passwort ändern“, als Admin: „Entfernen“ und „Zugang zurücksetzen“ bei einem Mitglied.
3. Testinstanz: die Sperre vorzeitig beenden (nur dort): `update sessions set origin_at = origin_at - interval '25 hours' where user_id = '<Anna>';` und Aktion wiederholen.
4. Annas **andere** Geräte (A1, W1) bekommen eine Benachrichtigung ohne Inhalt (Kanal „Sicherheit“); Profil › „Sicherheitsereignisse“ zeigt dort „Anmeldung per Wiederherstellungscode“.

**Erwartet:** Schritt 2: jede dieser Aktionen scheitert mit einer Meldung wie „… noch gesperrt (frühestens in … Stunden)“; **nichts ändert sich** (Sicherheitscode gleich, Passkeys gleich, Codes gleich). Nach Schritt 3 gehen die Aktionen (mit neuem Step-up).
**Nicht erlaubt:** dass die Sperre per Umweg fällt (z. B. in der Code-Sitzung einen Passkey anlegen, sich mit dem Passkey neu anmelden und dann den Schlüssel wechseln: die neue Sitzung erbt die Frist).

### Fall 10: Schlüsselwechsel (Notfall) und Archiv

Nur auf dem Wegwerf-Konto „Dora“ oder einem Konto, dessen Verlauf egal ist.

1. Dora hat Sicherungen (Wiederherstellungsschlüssel **und** Passwort-Sicherung). Dora: „Neuen Schlüssel erzeugen …“ (Checkliste, „ersetzen“).
2. Dora: Profil › Verschlüsselung.
3. SQL: `select kind, key_version, reason from key_backup_archive where user_id = '<Dora>';` und `select state, key_version from key_backups_pw where user_id = '<Dora>';`.

**Erwartet:** Andere Mitglieder sehen die Warnung „Der Schlüssel von Dora hat sich geändert“ (erst nach „Neuen Schlüssel akzeptieren“ wird verschlüsselt neu verteilt). Bei Dora: neue Sicherung offen („Sicherung offen“), „Gerät abgeben“ wieder gesperrt, **„N ältere Sicherungen liegen beim Server“**. Der **alte Schlüssel liegt als „Alter Schlüssel auf diesem Gerät“** auf dem Gerät. In der Datenbank: die alte Wiederherstellungssicherung im Archiv (`reason = rotation`), die alte Passwort-Sicherung `stale`; **nichts gelöscht**.
**Bekannte Lücke L-3 (nicht als Fehler melden):** Die App bietet **keinen Weg**, aus Archiv oder aus dem aufbewahrten alten Schlüssel den alten Verlauf wieder zu öffnen („Archivschlüssel“ kommt später). Der alte Verlauf bleibt für Dora nach dem Wechsel **nicht lesbar**; er geht aber nicht verloren (Archiv und Quarantäne bleiben, ein Entwickler kann ihn aus dem Archiv holen).

### Fall 11: Archiv-Ausdünnung (nur Server, automatisch; L-6)

Nicht von Hand. Der Test `server/test/schluessel-matrix.test.ts` prüft die Grenze: Von den ersetzten Wiederherstellungssicherungen bleiben je Schlüsselstand die ältesten 5 und insgesamt die neuesten 50; Einträge aus einem Schlüsselwechsel (`rotation`) werden nie ausgedünnt. Eine **echte aktuelle** Sicherung, die durch Ersetzen ins Archiv kommt, bleibt dort noch genau 50 weitere Ersetzungen lang erhalten (dokumentierte Grenze).

### Fall 12: Mitglied entfernen (endgültig!)

**Snapshot der Testdatenbank vorher.** Nur mit der Wegwerf-Person „Dora“ (nicht mit Cora, die in der Gruppe ist).

1. Dora schreibt eine Nachricht in den Familienchat; Anna und Ben lesen sie.
2. Anna (Admin, **normal angemeldet**, nicht über Wiederherstellungscode): „Familie verwalten“ › Menü bei Dora › „Entfernen“ → Rückfrage „Mitglied entfernen?“, Step-up.
3. SQL: `select count(*) from person_keys where user_id = '<Dora>'` und `key_backup_archive` für Dora.
4. Neues Gerät für Anna (frisches Browser-Profil), verbinden (Fall 4), Familienchat öffnen: Doras alte Nachricht.

**Erwartet (heute):** Dora ist weg, **mit ihr alle Schlüssel, Sicherungen und Archiveinträge** (Zeilen verschwinden per Kaskade). Doras Nachrichten bleiben als Chiffretext bei den anderen; auf **bestehenden** Geräten, die ihren Schlüssel gemerkt haben, bleiben sie lesbar. Auf dem **neuen** Gerät fehlt Doras Schlüssel: die Nachricht steht dort als „Absender nicht bestätigt“/nicht lesbar.
**Rückfrage (L-4, Text behoben):** Sie nennt jetzt, dass Schlüssel, Sicherungen und Schlüsselarchiv der Person endgültig gelöscht werden und ihre früheren Nachrichten auf neu verbundenen Geräten nicht mehr prüfbar sind. Ein Soft-Delete mit Frist ist geplant (eigenes Paket). Bis dahin: vor jedem echten Entfernen Snapshot der Datenbank.
Außerdem: eine Admin-Sitzung, die per Wiederherstellungscode entstand, darf **nicht** entfernen (Fall 9).

### Fall 13: Komplett-Reset („Zugang zurücksetzen“)

1. Anna: Menü bei Cora › „Zugang zurücksetzen“ (Link, optional PIN). Der Dialog warnt, dass verschlüsselte Chats nur lesbar bleiben, wenn Cora noch ein Gerät mit ihrem Schlüssel oder den Wiederherstellungsschlüssel hat.
2. Cora richtet den Zugang über den Link neu ein (neues Passwort/Passkey, neuer Authenticator, **neue Wiederherstellungscodes**).
3. Alle anderen Mitglieder (Anna, Ben): Profil › „Sicherheitsereignisse“.

**Erwartet:** Coras **Schlüssel und Sicherungen bleiben** (`person_keys`, `key_backups*` unverändert); mit C1 (Schlüssel noch im Browser) ist alles lesbar, ohne C1 mit Wiederherstellungsschlüssel. **Alle anderen** bekommen einen Hinweis „Zugang von Cora wurde zurückgesetzt; nimm einen neuen Schlüssel dieser Person nur nach Rücksprache an“ (Ereignis + Wecker ohne Inhalt). Eine Schlüsseländerung bei Cora wird bei den anderen **nie** stillschweigend akzeptiert.

### Fall 14: Ungesendeter Ausgang beim Abmelden (Lücke L-5, Warnung eingebaut)

1. A1 (Android): Flugmodus an. Chat: Nachricht „Offline-Test“ schreiben (Zustand „wird gesendet“).
2. Profil › „Abmelden“.

**Erwartet:** Der Dialog nennt in Gelb die Anzahl („Eine Änderung (z. B. eine Nachricht) wurde noch nicht an den Server gesendet und geht beim Abmelden verloren …“), bietet „Erst synchronisieren“ an, und der Abmelden-Knopf heißt „Abmelden (Änderungen verwerfen)“. Mit Netz und „Erst synchronisieren“ verschwindet die Warnung, die Nachricht ist beim Server. Dasselbe bei „Gerät abgeben“: vorher ein Abgleich, ein Pflicht-Haken nennt den Rest. Wer trotzdem abmeldet, verliert die Nachricht (der Ausgang wird geleert); Schlüssel und Verlauf auf dem Server sind nicht betroffen. Zum Vergleich: Bei einem Sitzungsverlust (Widerruf, 401) bleibt der Ausgang erhalten und geht nach erneuter Anmeldung derselben Person hinaus.

## 2. Ergebnisblatt

| Fall | Gerät/Browser | Datum | Ergebnis (bestanden / Fehler / nicht geprüft) | Bemerkung |
| --- | --- | --- | --- | --- |
| 1 Abmelden/Anmelden | | | | |
| 2 Gerät entfernt | | | | |
| 3 Gerät abgeben | | | | |
| 4 Gerät verbinden (QR/Code) | | | | |
| 5 Quarantäne (defekter Schlüssel) | | | | |
| 6 Browserdaten gelöscht | | | | |
| 7 Passwort-Reset (Admin) | | | | |
| 8 Passwort vergessen (Code) | | | | |
| 9 24-h-Sperre | | | | |
| 10 Schlüsselwechsel und Archiv | | | | |
| 11 Archiv-Ausdünnung (Test) | – | | automatisch | |
| 12 Mitglied entfernen | | | | |
| 13 Komplett-Reset | | | | |
| 14 Ausgang beim Abmelden | | | | |

## 3. Bekannte Lücken (Stand dieser Prüfung)

Nicht als neue Fehler melden, aber bei jedem Durchlauf beobachten, ob sie noch gelten. Behobene Lücken sind markiert (Tests in `app/test/schluessel_matrix_test.dart`, `abmelden_warnung_test.dart`, `auth_screens_test.dart`), L-6 hat einen Test in `server/test/schluessel-matrix.test.ts`.

| Nr. | Schwere | Was |
| --- | --- | --- |
| L-1 | **behoben** (war hoch, Android) | `flutter_secure_storage` löschte bei einem Lesefehler **selbst** (Standard `resetOnError: true`). Jetzt erzeugt nur `lib/data/crypto/sicherer_speicher.dart` ein `FlutterSecureStorage`, mit `resetOnError: false` (Wächtertest); ein Lesefehler kommt als `SchluesselSpeicherFehler` an. Nebenwirkung und Gegenmittel: Ist der Keystore-Schlüssel dauerhaft kaputt, heilt sich der Speicher nicht mehr selbst und die Anmeldung kann nichts ablegen. Dann zeigt die App „Gerätespeicher defekt“ mit dem Knopf **„Gerätespeicher zurücksetzen“** (auch im Defektbild unter Profil › Verschlüsselung): nur auf Klick, nur nach einer Probe (zwei Zugriffe scheitern nacheinander), mit Rückfrage und getipptem Wort „zurücksetzen“ (ohne bestätigte Sicherung zusätzlich Pflicht-Haken); danach wird abgemeldet und neu angefangen. Das ist die **einzige** Stelle mit `resetOnError: true` (Wächtertest). |
| L-2 | **behoben** (war mittel) | Sackgasse „Schlüsselspeicher nicht lesbar“: Eine dauerhaft unlesbare Vertrauensablage gilt wie eine beschädigte; ohne eigenen Schlüssel bleibt „Gerät nicht verbunden“ mit allen Verbinden-Wegen, Meldung und „Vertrauen zurücksetzen“ (Fall 5). |
| L-3 | mittel | Kein Weg in der App, aus Archiv oder aufbewahrtem altem Schlüssel den alten Verlauf zu öffnen (Fall 10). |
| L-4 | **Text behoben**, Soft-Delete offen | „Entfernen“ löscht Schlüssel, Sicherungen und Archiv endgültig und nimmt auf **neuen** Geräten der anderen die Prüfbarkeit der alten Nachrichten der Person; die Rückfrage sagt es jetzt (Fall 12). |
| L-5 | **behoben** (war niedrig bis mittel) | Ausdrückliches Abmelden und „Gerät abgeben“ leerten den **Ausgang** ohne Warnung: jetzt Anzahl, „Erst synchronisieren“, beim Gerät abgeben Abgleich und Pflicht-Haken (Fall 14). |
| L-6 | niedrig | Die zuletzt gültige echte Wiederherstellungssicherung ist nach 51 späteren Ersetzungen aus dem Archiv gedünnt (nur mit einer geliehenen, voll angemeldeten Sitzung auslösbar, Fall 11). |
| L-7 | **behoben** (war niedrig) | Ein interner Fehler der Verschlüsselungsbibliothek (`bibliothek`) beim Ableiten schob einen gesunden Schlüssel in die Quarantäne; jetzt bleibt er liegen („nicht verfügbar“, der nächste Versuch klappt). |
| L-8 | niedrig, theoretisch | Löst die App nach einem unklaren Schlüsselwechsel (Verbindungsabbruch) den Zwischenstand auf und kommt die Anfrage danach doch noch beim Server an, ist der neue private Schlüssel weg (der alte bleibt, der Server kennt aber den neuen). |

## 4. Nach den Tests

- Testinstanz samt Datenbank, Debug-APK und Browser-Profile löschen oder zurücksetzen; die Wiederherstellungsschlüssel und Codes der Testfamilie vernichten.
- Fehler mit Fall, Schrittnummer, Gerät, Uhrzeit, erwartet/tatsächlich melden. Bei Verdacht auf Schlüsselverlust zuerst den Snapshot sichern.
