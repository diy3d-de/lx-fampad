# app – Flutter (Android + Web)

Flutter 3.47.6 / Dart 3.13.5, Riverpod 3.4.3, drift 2.35.1 (Versionen exakt gepinnt, siehe `../docs/VERSIONEN.md`).

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # erzeugt lib/data/app_database.g.dart (drift)
flutter analyze
flutter test
flutter run -d chrome
```

Release-Builds:

```bash
# Web: ohne CDN-Abrufe (CanvasKit lokal), Schriften gebündelt, Fallback-Schriften von der eigenen Domain
flutter build web --release --no-web-resources-cdn
# Android (APK für den eigenen Update-Kanal; Signatur über android/key.properties, nicht eingecheckt)
flutter build apk --release --dart-define=API_BASE=https://familie.lx-labs.dev
```

- `lib/constants.dart`: Design-Tokens (Farben, Personenfarben, Schriften, Tabs). Keine Farbwerte in Widgets.
- `lib/ui/`: Theme (Material 3), Glow-Hintergrund, gemeinsame Widgets.
- `lib/data/`: drift-Datenbank (Sync-Meta, Outbox), Provider, Sync-Zustand.
- `lib/features/<bereich>/`: Screens je Tab, Anmeldung, Update (OTA).
- `web/`: `sqlite3.wasm` (sqlite3 3.7.0) und `drift_worker.js` (drift 2.35.1) liegen eingecheckt im Ordner, damit nichts von einem CDN geladen wird. Bei Versionswechsel von drift/sqlite3 beide Dateien aus den GitHub-Releases (`simolus3/sqlite3.dart`, `simolus3/drift`) ersetzen.
