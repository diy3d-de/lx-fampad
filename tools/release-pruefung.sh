#!/usr/bin/env bash
# Prüft den Release-Build der Android-App ohne Geheimnisse: baut mit einem Wegwerf-Schlüssel (wird erzeugt und gelöscht, die APK wird nie verteilt) und prüft
#   1. Manifest: INTERNET vorhanden, kein ACCESS_BACKGROUND_LOCATION,
#   2. R8: Die Klassen, die die Karte über JNI aufruft, wurden nicht entfernt (sonst bleibt die Karte im Release-Build leer, im Debug-Build nicht sichtbar).
# Debug-Builds laufen ohne R8 und fangen solche Fehler nicht: v0.5.0 hatte deshalb eine leere Karte (docs/KARTE-SPIKE.md, "Release-Build").
# Aufruf aus dem Repository:  tools/release-pruefung.sh [ABI]    (ABI: android-arm64 (Standard), android-x64 für den Emulator)
# Lokal unter Windows ohne C-Compiler für libsodium: NIX_SKIP_SODIUM_BUILD_HOOKS=1 setzen.
set -Eeuo pipefail

ABI="${1:-android-arm64}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -f "$APP/android/key.properties"' EXIT

[ ! -e "$APP/android/key.properties" ] || { echo "app/android/key.properties existiert (echte Signatur?): Abbruch, nichts überschrieben" >&2; exit 2; }
keytool -genkeypair -keystore "$TMP/pruefung.jks" -storepass pruefung -keypass pruefung -alias pruefung -keyalg RSA -keysize 2048 -validity 2 -dname "CN=release-pruefung" >/dev/null 2>&1
STORE="$TMP/pruefung.jks"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) STORE="$(cygpath -m "$STORE")" ;; esac
printf 'storeFile=%s\nstorePassword=pruefung\nkeyAlias=pruefung\nkeyPassword=pruefung\n' "$STORE" > "$APP/android/key.properties"

cd "$APP"
flutter build apk --release --target-platform "$ABI"

fehler=0
manifest="$(find build/app/intermediates/merged_manifest/release -name AndroidManifest.xml | head -1)"
[ -n "$manifest" ] || { echo "FEHLER: gemergtes Release-Manifest nicht gefunden" >&2; exit 1; }
grep -q 'android.permission.INTERNET' "$manifest" || { echo "FEHLER: INTERNET fehlt im Release-Manifest" >&2; fehler=1; }
if grep -q 'android.permission.ACCESS_BACKGROUND_LOCATION' "$manifest"; then echo "FEHLER: ACCESS_BACKGROUND_LOCATION im Release-Manifest (bewusst nie)" >&2; fehler=1; fi

usage="build/app/outputs/mapping/release/usage.txt"
if [ -f "$usage" ]; then
  # In usage.txt stehen von R8 entfernte Klassen; "Klasse:" mit Einrückungen darunter = entfernte Mitglieder
  if grep -qx 'io.flutter.plugin.platform.PlatformView:' "$usage"; then
    echo "FEHLER: R8 hat Methoden von io.flutter.plugin.platform.PlatformView entfernt (Keep-Regel in app/android/app/proguard-rules.pro fehlt): die Karte bliebe leer" >&2; fehler=1
  fi
  if grep -q '^com.github.josxha.maplibre\.' "$usage"; then
    echo "FEHLER: R8 hat Klassen des maplibre-Plugins entfernt (com.github.josxha.maplibre.*)" >&2; fehler=1
  fi
  if grep -q '^org.maplibre.android.maps.MapLibreMap[:$]' "$usage"; then
    echo "FEHLER: R8 hat MapLibreMap entfernt oder gekürzt" >&2; fehler=1
  fi
else
  echo "FEHLER: $usage fehlt (R8 lief nicht?)" >&2; fehler=1
fi

[ "$fehler" = 0 ] && echo "Release-Prüfung bestanden (Manifest, R8-Regeln der Karte)."
exit "$fehler"
