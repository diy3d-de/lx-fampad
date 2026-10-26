#!/usr/bin/env bash
# Prüft den Release-Build der Android-App ohne Geheimnisse: baut mit einem Wegwerf-Schlüssel (wird erzeugt und gelöscht, die APK wird nie verteilt) und prüft
#   1. Manifest: INTERNET vorhanden, kein ACCESS_BACKGROUND_LOCATION,
#   2. APK: nur Bibliotheken der gebauten Architektur (kein armeabi-v7a/x86_64 neben arm64-v8a: vorgefertigte Pakete bringen sonst alle ABIs mit), Bibliotheken komprimiert (useLegacyPackaging), Größe unter 40 MB,
#   3. R8: Die Klassen, die die Karte über JNI aufruft, wurden weder ganz noch in ihren Methoden entfernt (sonst bleibt die Karte im Release-Build leer,
#      im Debug-Build nicht sichtbar).
# Debug-Builds laufen ohne R8 und fangen solche Fehler nicht: v0.5.0 hatte deshalb eine leere Karte (docs/KARTE-SPIKE.md, "Release-Build").
# Aufruf aus dem Repository:  tools/release-pruefung.sh [ABI]    (ABI: android-arm64 (Standard), android-x64 für den Emulator)
# Lokal unter Windows ohne C-Compiler für libsodium: NIX_SKIP_SODIUM_BUILD_HOOKS=1 setzen.
# Eine vorhandene app/android/key.properties (echte Signatur) wird NIE angefasst: das Skript bricht dann ab, ohne etwas zu verändern.
set -Eeuo pipefail

ABI="${1:-android-arm64}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/app"
PROPS="$APP/android/key.properties"

# Schutz zuerst, noch bevor irgendetwas aufgeräumt wird
if [ -e "$PROPS" ]; then
  echo "app/android/key.properties existiert (echte Signatur?): Abbruch, nichts verändert" >&2
  exit 2
fi

TMP="$(mktemp -d)"
ERZEUGT=0
aufraeumen() {
  rm -rf "$TMP"
  # nur die Datei löschen, die dieses Skript selbst angelegt hat
  if [ "$ERZEUGT" = 1 ]; then rm -f "$PROPS"; fi
}
trap aufraeumen EXIT

keytool -genkeypair -keystore "$TMP/pruefung.jks" -storepass pruefung -keypass pruefung -alias pruefung -keyalg RSA -keysize 2048 -validity 2 -dname "CN=release-pruefung" >/dev/null 2>&1
STORE="$TMP/pruefung.jks"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) STORE="$(cygpath -m "$STORE")" ;; esac
printf 'storeFile=%s\nstorePassword=pruefung\nkeyAlias=pruefung\nkeyPassword=pruefung\n' "$STORE" > "$PROPS"
ERZEUGT=1

cd "$APP"
# Ergebnisse früherer Läufe (z. B. des Debug-Builds davor) können die Prüfung verfälschen; die Platte des CI-Runners ist knapp
rm -rf build/app/outputs/mapping/release build/app/intermediates/merged_manifest/release build/app/outputs/flutter-apk/app-release.apk
df -h . | tail -1
flutter build apk --release --target-platform "$ABI"

fehler=0
case "$ABI" in android-arm64) ERWARTET=arm64-v8a ;; android-x64) ERWARTET=x86_64 ;; android-arm) ERWARTET=armeabi-v7a ;; *) ERWARTET="" ;; esac
apk="build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$apk" ] && [ -n "$ERWARTET" ]; then
  abis="$(unzip -Z1 "$apk" | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u | tr '\n' ' ')"
  if [ "$abis" != "$ERWARTET " ]; then echo "FEHLER: APK enthält Bibliotheken für '$abis' statt nur '$ERWARTET' (abiFilters in app/android/app/build.gradle.kts)" >&2; fehler=1; fi
  if unzip -v "$apk" | grep ' lib/' | grep -q ' Stored '; then echo "FEHLER: Bibliotheken in der APK unkomprimiert (useLegacyPackaging in build.gradle.kts), die APK wird doppelt so groß" >&2; fehler=1; fi
  groesse="$(wc -c < "$apk")"
  echo "APK: $groesse Bytes, ABIs: $abis"
  if [ "$groesse" -gt 41943040 ]; then echo "FEHLER: APK größer als 40 MB ($groesse Bytes); 0.5.1 hatte 127 MB, Ziel etwa 24 MB" >&2; fehler=1; fi
else
  echo "FEHLER: $apk fehlt oder ABI '$ABI' unbekannt" >&2; fehler=1
fi
manifest="$(find build/app/intermediates/merged_manifest/release -name AndroidManifest.xml | head -1)"
[ -n "$manifest" ] || { echo "FEHLER: gemergtes Release-Manifest nicht gefunden" >&2; exit 1; }
grep -q 'android.permission.INTERNET' "$manifest" || { echo "FEHLER: INTERNET fehlt im Release-Manifest" >&2; fehler=1; }
if grep -q 'android.permission.ACCESS_BACKGROUND_LOCATION' "$manifest"; then echo "FEHLER: ACCESS_BACKGROUND_LOCATION im Release-Manifest (bewusst nie)" >&2; fehler=1; fi

# Widget "Heute": Empfaenger im Manifest (exportiert, mit APPWIDGET_UPDATE und Provider-Beschreibung), sonst fehlt das Widget auf dem Startbildschirm
if ! tr -d '\r' < "$manifest" | tr '\n' ' ' | grep -Eq '<receiver[^>]*dev\.lx_labs\.fampad\.HeuteWidget"[^>]*exported="true"|<receiver[^>]*exported="true"[^>]*dev\.lx_labs\.fampad\.HeuteWidget"'; then
  echo "FEHLER: Widget-Empfaenger HeuteWidget fehlt im Release-Manifest oder ist nicht exportiert" >&2; fehler=1
fi
grep -q 'android.appwidget.provider' "$manifest" || { echo "FEHLER: android.appwidget.provider (Widget-Beschreibung) fehlt im Release-Manifest" >&2; fehler=1; }
grep -q 'android.appwidget.action.APPWIDGET_UPDATE' "$manifest" || { echo "FEHLER: APPWIDGET_UPDATE fehlt im Release-Manifest" >&2; fehler=1; }

# Datei-Uebertragungen: Vordergrunddienst nur intern (nicht exportiert), Typ dataSync, Berechtigung vorhanden
manifest_flach="$(tr -d '\r' < "$manifest" | tr '\n' ' ')"
transfer_dienst="$(printf '%s' "$manifest_flach" | grep -Eo '<service[^>]*dev\.lx_labs\.fampad\.TransferService"[^>]*>' | head -1)"
[ -n "$transfer_dienst" ] || transfer_dienst="$(printf '%s' "$manifest_flach" | grep -Eo '<service[^>]*android:name="[^"]*TransferService"[^>]*>' | head -1)"
if [ -z "$transfer_dienst" ]; then
  echo "FEHLER: Dienst TransferService fehlt im Release-Manifest (Datei-Uebertragungen im Hintergrund)" >&2; fehler=1
else
  printf '%s' "$transfer_dienst" | grep -q 'android:exported="false"' || { echo "FEHLER: TransferService ist nicht auf exported=false gesetzt" >&2; fehler=1; }
  printf '%s' "$transfer_dienst" | grep -q 'android:foregroundServiceType="dataSync"' || { echo "FEHLER: TransferService hat nicht den Typ dataSync" >&2; fehler=1; }
fi
grep -q 'android.permission.FOREGROUND_SERVICE_DATA_SYNC' "$manifest" || { echo "FEHLER: FOREGROUND_SERVICE_DATA_SYNC fehlt im Release-Manifest" >&2; fehler=1; }

# Teilen aus anderen Apps: nur Text (ACTION_SEND mit text/plain); keine Mehrfachauswahl und kein anderer MIME-Typ im Filter
manifest_zeilen="$(tr -d '\r' < "$manifest" | tr '\n' ' ' | sed 's#</intent-filter>#&\n#g')"
if ! printf '%s\n' "$manifest_zeilen" | grep 'android.intent.action.SEND"' | grep -q 'mimeType="text/plain"'; then
  echo "FEHLER: Intent-Filter ACTION_SEND mit text/plain fehlt im Release-Manifest (Teilen aus anderen Apps)" >&2; fehler=1
fi
if grep -q 'android.intent.action.SEND_MULTIPLE' "$manifest"; then echo "FEHLER: SEND_MULTIPLE im Release-Manifest (nur ein Text wird angenommen)" >&2; fehler=1; fi
if printf '%s\n' "$manifest_zeilen" | grep 'android.intent.action.SEND"' | grep -o 'mimeType="[^"]*"' | grep -qv 'mimeType="text/plain"'; then
  echo "FEHLER: ACTION_SEND nimmt einen anderen MIME-Typ als text/plain an (Bilder und Dateien werden nicht angenommen)" >&2; fehler=1
fi

usage="build/app/outputs/mapping/release/usage.txt"
if [ -f "$usage" ]; then
  # usage.txt nennt, was R8 entfernt hat: "Klasse" allein = ganz entfernt, "Klasse:" mit Einrückungen darunter = Mitglieder entfernt
  for klasse in \
    io.flutter.plugin.platform.PlatformView \
    io.flutter.plugin.platform.PlatformViewFactory \
    io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding \
    org.maplibre.android.maps.MapLibreMap \
    org.maplibre.android.maps.MapView \
    org.maplibre.android.MapLibre; do
    muster="$(printf '%s' "$klasse" | sed 's/\./\\./g'):?"
    if grep -qxE "$muster" "$usage"; then
      echo "FEHLER: R8 hat $klasse (ganz oder in Methoden) entfernt: Keep-Regel in app/android/app/proguard-rules.pro prüfen, die Karte bliebe leer" >&2; fehler=1
    fi
  done
  # Widget "Heute": Empfaenger und Anzeige-Klassen duerfen nicht ganz entfernt sein (HeuteSpeicher ist ausgenommen: R8 fuegt das kleine Objekt in seine Aufrufer ein und listet die Klasse dann als entfernt; R8 wuerde sie sonst als unbenutzt streichen, das Widget bliebe leer)
  for klasse in dev.lx_labs.fampad.HeuteWidget dev.lx_labs.fampad.HeuteAnzeige dev.lx_labs.fampad.HeuteKanal; do
    muster="$(printf '%s' "$klasse" | sed 's/\./\\./g')"
    if grep -qxE "$muster" "$usage"; then echo "FEHLER: R8 hat $klasse entfernt (Widget Heute)" >&2; fehler=1; fi
  done
  if grep -q '^com.github.josxha.maplibre\.' "$usage"; then
    echo "FEHLER: R8 hat Klassen des maplibre-Plugins entfernt (com.github.josxha.maplibre.*)" >&2; fehler=1
  fi
else
  echo "FEHLER: $usage fehlt (R8 lief nicht?)" >&2; fehler=1
fi

[ "$fehler" = 0 ] && echo "Release-Prüfung bestanden (Manifest inkl. Widget-Empfänger und Teilen-Filter, ABI und Größe der APK, R8-Regeln der Karte und des Widgets)."
exit "$fehler"
