# tools

Hilfsskripte für Betrieb und CI (Node 24, keine Abhängigkeiten, nur `node:`-Module).

## update-manifest.mjs – Update-Manifest des Android-Kanals signieren

Der Update-Kanal (`familie.lx-labs.dev/releases/android/latest.json`) ist mit Ed25519 signiert. Die App enthält den **öffentlichen** Schlüssel
(`kUpdatePublicKey` und `kUpdateKeyId` in `app/lib/constants.dart`); der **private** Schlüssel liegt nur in der CI (Secret `UPDATE_SIGNING_KEY`) und
beim Betreiber, **nie im Repository** (`*.pem` und `update-signing*.key` stehen in `.gitignore`).

### Update-Schlüssel erzeugen (einmalig)

```bash
node tools/update-manifest.mjs keygen ~/lx-update-key.pem     # Pfad außerhalb des Repositories; das Skript verweigert Pfade darin
```

Das Skript schreibt den privaten Schlüssel (PEM, Rechte 0600) und gibt den öffentlichen Schlüssel (Base64, 32 Byte) aus.

1. Den öffentlichen Schlüssel in `kUpdatePublicKey` eintragen und `kUpdateKeyId` ändern (z. B. `fampad-2026-1`; bei Schlüsselwechsel hochzählen). Der eingecheckte Wert ist ein **Platzhalter** ohne privaten Gegenpart: Solange er drinsteht, nimmt die App kein Manifest an.
2. Den Inhalt von `~/lx-update-key.pem` als Secret `UPDATE_SIGNING_KEY` in der CI hinterlegen und eine Sicherung offline aufbewahren (geht der Schlüssel verloren, lassen sich Apps nur noch per Neuinstallation aktualisieren).
3. App bauen und installieren (die Schlüssel-Konstanten sind Teil der App).

### Manifest erzeugen

```bash
node tools/update-manifest.mjs sign \
  --apk build/app/outputs/flutter-apk/dev-lx_labs-fampad-0.2.0.apk \
  --version 0.2.0 --version-code 2 --min-version 0.1.0 \
  --key-id fampad-2026-1 --notes "Kurzer Text für die Release-Notes" \
  --out latest.json                                           # privater Schlüssel aus $UPDATE_SIGNING_KEY oder --key-file
```

`--version-code` muss mit dem `versionCode` der APK übereinstimmen. Der Release-Workflow (`.github/workflows/release.yml`, `deploy/README.md` Abschnitt 10) leitet ihn aus dem Tag ab (`major*1000000 + minor*1000 + patch`, also `v0.2.0` gibt 2000) und baut die APK mit `--build-number`; von Hand muss man beides gleich setzen. Der Dateiname der APK steht im Manifest und darf nur
aus `A-Z a-z 0-9 . _ -` bestehen. Hochladen: erst die APK, dann `latest.json` nach `/srv/fampad/releases/android/` (siehe `deploy/README.md`, Abschnitt 9). Zusätzlich die APK als `lx-familyhub-latest.apk` kopieren (stabiler Download-Link für neue Mitglieder, `kApkDownloadUrl`; nicht Teil des signierten Manifests, die App aktualisiert sich weiter über `latest.json`).

Format: `{ "payload": "<JSON-Text>", "signature": "<Base64, 64 Byte>" }`. Signiert wird genau der Text in `payload`; er enthält `packageName`, `version`, `versionCode`,
`minVersion`, `apk`, `sha256`, `size`, `notes`, `issuedAt` und `keyId`. Die App lehnt falsche Signaturen, fremde Paketnamen und Schlüssel-IDs, kleinere `versionCode`s als die installierte,
zu alte (über 365 Tage) oder in der Zukunft liegende Manifeste und Größen über 200 MB ab.

### Prüfung vor dem Signieren (CI)

`verify-update-key.mjs` stellt sicher, dass `kUpdateKeyId` kein Platzhalter ist und `kUpdatePublicKey` in `app/lib/constants.dart` zum privaten Schlüssel (`UPDATE_SIGNING_KEY`) passt:
`UPDATE_SIGNING_KEY="$(cat ~/lx-update-key.pem)" node tools/verify-update-key.mjs app/lib/constants.dart` (gibt `key_id=…` aus). Der Release-Workflow ruft es vor dem Signieren auf.

### Secrets und Reihenfolge des ersten Releases

Welche Secrets (Android-Keystore, `UPDATE_SIGNING_KEY`, SSH-Zugang) angelegt werden, wie der Keystore mit `keytool` entsteht und in welcher Reihenfolge das erste Release läuft, steht in `deploy/README.md`, Abschnitt 10. **`applicationId` und Android-Keystore nie ändern. `latest.json` erst hochladen, wenn der echte öffentliche Schlüssel in `constants.dart` steht.**

### Test

```bash
node --test "tools/*.test.mjs"
```
