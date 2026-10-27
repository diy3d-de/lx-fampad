# Home-Assistant-Anbindung der Zähler: Formate (verbindlich für App und Integration)

Übersicht und Begründung: `docs/konzept-homeassistant-anbindung.html`, Server-Schnittstelle: `docs/API.md` „Einwurf (Home Assistant)“. Der Server sieht nur undurchsichtige Päckchen. **Es gibt nur Tageswerte** (ein Wert je Kanal und Tag).

## Kopplungscode

Erzeugt die App (nur Admin, einmal angezeigt), gelesen von der HA-Integration.

```
FH1-<base64url ohne Padding von UTF-8-JSON>
{ "v": 1,
  "u": "https://familyhub.lx-labs.dev",   // Basisadresse des Servers (Regeln unten)
  "t": "fhi_…",                           // Einwurf-Token (POST /ingest/tokens)
  "p": "<base64 (Standard) 32 Bytes>",    // öffentlicher Postfach-Schlüssel (X25519, libsodium crypto_box)
  "s": "<base64 (Standard) 32 Bytes>",    // Prüfgeheimnis für den MAC
  "n": "Haus Keller" }                    // Name der Verbindung (nur Anzeige)
```

**Adresse `u` (streng, App und Integration gleich):** nur `https://`, nur Rechnername und optional Port (nicht 443), kleingeschrieben; **kein** Pfad (auch kein abschließender `/`), keine Abfrage, kein Fragment, keine Zugangsdaten, **kein IP-Literal** (auch nicht `127.1` oder Namen mit rein numerischer letzter Marke). Die Prüfung vergleicht die normalisierte Form mit der Eingabe (App: `kopplungsAdresse`, Integration: `kopplungs_adresse`); alles andere lehnt den Code ab. Die Integration zeigt vor dem Speichern den Host zur Bestätigung („Familyhub-Server: <host>. Stimmt das?“), auch beim Neukoppeln.

Der private Postfach-Schlüssel entsteht in der App (`crypto_box_keypair`) und verlässt das Gerät nie (Schlüsselspeicher des Geräts, wie der Personenschlüssel). Unbekannte `v` = Code ablehnen.

## Weitergabe des Postfach-Schlüssels auf ein weiteres Gerät (nur App, nicht Teil der Integration)

Verfahren wie die Geräte-Übertragung des Personenschlüssels (`app/lib/data/crypto/uebertragung.dart`), Umsetzung `app/lib/data/ingest/ingest_weitergabe.dart`. Die Integration und die Päckchen sind davon nicht berührt, `docs/ingest-vektoren.json` bleibt unverändert.

- Das Abholgerät erzeugt ein 32-Byte-Einmalgeheimnis S. QR: `LXP1:` + 56 Zeichen Base32 (mit 3 Byte Prüfsumme über den Zweck `lx-fampad|ingest-postfach-transfer|anzeige|v1`); Tippform: dieselben 56 Zeichen in 14 Vierergruppen.
- Suchkennung (an den Server): `BLAKE2b-256(key = S, "lx-fampad|ingest|postfach-transfer-lookup|v1")`, Base64url. Verpackungsschlüssel (bleibt auf den Geräten): `BLAKE2b-256(key = S, "lx-fampad|ingest|postfach-transfer-key|v1")`.
- Klartext: 1 Byte Version (1) | 96 Byte Postfach (öffentlicher Schlüssel 32, privater 32, MAC-Geheimnis `s` 32) | 1 Byte Anzahl n (0 bis 20) | n mal 16 Byte (UUID einer Verbindung, nur die Token-IDs).
- Blob (Base64url, höchstens 1024 Zeichen): Version (1) | Nonce (24) | Chiffretext (wie bei der Geräte-Übertragung); AAD `lx-fampad|ingest-postfach-transfer|v1|<userId>`.
- Server: `POST /ingest/postfach-transfer` und `…/claim` (siehe `docs/API.md`); 2 Minuten, einmal einlösbar, nur dieselbe Person.

## Päckchen

`POST /ingest/zaehler` mit `items: [{ k, box }]`:

- `k` = Eindeutigkeitsschlüssel (ein Tag je Kanal nur einmal angenommen), **verrät weder Kanal noch Datum**: `k = hex(blake2b("fampad-ingest-v1-k\n" + kanal + "\n" + d, key = s, digest_size = 16))` (BLAKE2b mit 16 Byte Ausgabe, Schlüssel = die 32 Bytes aus `s`, Kleinbuchstaben-Hex, 32 Zeichen). Die App wertet `k` nie aus (nur der Server nutzt es zur Doppelerkennung); die Warteschlange der Integration arbeitet lokal nach (Kanal, Tag), nie nach `k`.
- `box` = base64 (Standard-Alphabet) einer libsodium **Sealed Box** (`crypto_box_seal`) an `p` über den UTF-8-Text des folgenden JSON (kompakt, Schlüsselreihenfolge egal):

```
{ "v": 1,
  "kanal": "strom_bezug",        // [a-z0-9_]{1,40}
  "d": "2026-10-26",             // Kalendertag Europe/Berlin, für den der Stand gilt (Stand zum Tagesbeginn)
  "t": 1793059140000,            // Ablesezeitpunkt, Millisekunden seit 1970 (UTC)
  "stand": "2951.709566",        // Dezimaltext mit Punkt, höchstens 10 Vorkommastellen und 6 Nachkommastellen, nie negativ, nie Gleitkomma-Exponent
  "e": "kWh",                    // Einheit (nur Anzeige/Plausibilität)
  "mac": "<64 Hex-Zeichen>" }
```

**MAC** = BLAKE2b-256 (libsodium `crypto_generichash`, 32 Bytes, Schlüssel = die 32 Bytes aus `s`) über die UTF-8-Bytes von
`"fampad-ingest-v1\n" + kanal + "\n" + d + "\n" + t + "\n" + stand + "\n" + e`
(`t` als Dezimalzahl ohne Trennzeichen), als Kleinbuchstaben-Hex. Die App verwirft jedes Päckchen mit falschem MAC (nie eintragen, nur zählen und im Briefkasten-Bildschirm melden), mit unbekannter `v`, ungültigem Kanal/Datum/Stand.

**Grenzen des Stands** (App und Integration gleich): Muster `^\d{1,10}(\.\d{1,6})?$`, führende Nullen sind erlaubt (die Integration schreibt keine); die App rechnet in Tausendstel (kaufmännisch gerundet) und lehnt Werte über `kMaxStandMilli` = 10^13 Tausendstel ab. Der **größte Stand ist 9 999 999 999,999**. Sensorwerte darüber (oder die nach dem Runden mehr als 10 Vorkommastellen hätten) sendet die Integration nicht; im Protokoll steht nur ein Hinweis ohne Wert.

## Kanäle (Vorschlag, frei erweiterbar)

`strom_bezug`, `strom_einspeisung`, `solar_erzeugung`. Die Zuordnung Kanal → Zähler legt der Nutzer in der App im Zähler fest (verschlüsselt im Zähler-Datensatz).

## Zeitpunkt und Wiederholung

HA sendet **einmal täglich kurz nach Mitternacht (Wanduhr Europe/Berlin, nicht die Zeitzone von Home Assistant)** den aktuellen Stand jedes Kanals, `d` = heutiges Datum in Europe/Berlin. Versandzeit, stündliches Nachholen und `d` rechnen durchgehend in Europe/Berlin. Schlägt der Versand fehl, bleibt das Päckchen in einer lokalen Warteschlange und wird mit Wartezeit (Backoff) wiederholt; der Server ignoriert Wiederholungen mit gleichem `k`. Ist der Sensor `unavailable`/`unknown`/nicht numerisch, wird **nichts** gesendet (Lücke statt falscher Null). Beim Start holt die Integration einen verpassten Tag nach, wenn der Sensor jetzt gültig ist und für `d` noch nichts gesendet wurde.

**Nur 400 und 422 sind endgültig:** Antwortet der Server mit 400 oder 422, wird das Päckchen verworfen. Alles andere außer 200 und 401 (429, 5xx, aber auch 403, 404, 408, 413, Weiterleitungen und Unbekanntes, z. B. von Proxys oder Wartungsseiten) wird wie ein vorübergehender Fehler behandelt: Backoff, das Päckchen bleibt in der Warteschlange und wird nach 7 Tagen selbst aufgeräumt. 401 löst die Neukopplung aus.

**Ehrlicher Ablesezeitpunkt:** Wird ein Tag verspätet nachgeholt (Neustart, Sensor war zur Versandzeit nicht verfügbar), bleibt `d` der heutige Tag und `t` ist der tatsächliche Lesezeitpunkt, nicht die Versandzeit. Die App darf `t` für die Anzeige „Stand vom Tag, abgelesen um hh:mm“ nutzen.

## Restrisiken

- **Wiederholung (Replay):** Das Päckchen ist authentisch (MAC mit dem Prüfgeheimnis), aber nicht an einen Server-Zähler gebunden. Wer ein altes Päckchen mitlesen könnte (der Weg ist https), könnte es wieder einwerfen; der Server nimmt je `k` nur eines an, die App erkennt Doppelte über Kanal und `d`. Ein solcher Angreifer bräuchte zusätzlich das Token. Mehr als „ein Wert je Kanal und Tag“ ist daraus nicht zu gewinnen.
- **Geheimnisse in Home Assistant:** Token und Prüfgeheimnis (und der öffentliche Postfach-Schlüssel) liegen im Klartext in `.storage/core.config_entries` und damit in Home-Assistant-Sicherungen. Wer sie lesen kann, kann Päckchen **einwerfen** (Werte fälschen), aber nie Daten lesen: der private Postfach-Schlüssel bleibt in der App.

## Testvektor

`docs/ingest-vektoren.json` (von der HA-Seite mit Python/PyNaCl erzeugt): feste Schlüssel aus einem Seed, ein fertiges Päckchen, Klartext, erwarteter MAC und erwartetes `k` (Feld `k`, für Kanal `strom_bezug`, Tag `2026-10-26`). Die App-Tests müssen es öffnen und prüfen; ändert sich ein Format, müssen beide Seiten angepasst werden.
