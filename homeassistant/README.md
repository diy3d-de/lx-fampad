# Familyhub für Home Assistant

Schickt einmal täglich die Zählerstände deiner Sensoren (Strom Bezug, Einspeisung, Solar) **verschlüsselt** an deinen Familyhub-Server. Die Familyhub-App holt sie ab, öffnet sie lokal und trägt sie in die Zähler ein. Format: `docs/HA-FORMAT.md`, Server: `docs/API.md` „Einwurf (Home Assistant)“.

## Installation

1. Den Ordner `homeassistant/custom_components/familyhub/` aus diesem Repo nach `/config/custom_components/familyhub/` kopieren (Samba, SSH oder Datei-Editor).
2. Home Assistant neu starten (die Bibliothek PyNaCl wird dabei automatisch installiert).
3. Einstellungen › Geräte & Dienste › Integration hinzufügen › **Familyhub**.

## Einrichtung

1. Erzeuge in der Familyhub-App (als Admin) unter Zähler › Home Assistant › Neue Verbindung koppeln einen Kopplungscode (`FH1-…`). Tippe dort auf „Code kopieren“ und füge ihn im ersten Schritt ein (Home Assistant hat nur ein Textfeld, keinen QR-Scanner; läuft Home Assistant auf einem anderen Gerät, zeigt die App den Code auf Wunsch auch als QR-Code, den du mit der Kamera liest und als Text kopierst). Der Code ist ein Geheimnis: nicht weitergeben, nicht posten; die App leert die Zwischenablage nach 60 Sekunden.
2. Wähle je Kanal einen Sensor mit dem **Gesamt-Zählerstand in kWh** (Geräteklasse Energie). Mindestens ein Kanal ist nötig, die anderen sind optional. Für dein Haus passen:

   | Kanal | Sensor |
   | --- | --- |
   | Strom Bezug | `sensor.ecotracker_lokal_zaehlerstand_bezug` |
   | Strom Einspeisung | `sensor.ecotracker_lokal_zaehlerstand_einspeisung` |
   | Solar Erzeugung | `sensor.solarbank_3_e2700_pro_energie_produziert` |

3. Vor dem Speichern zeigt Home Assistant den **Server-Host** aus dem Kopplungscode („Familyhub-Server: …. Stimmt das?“). Prüfe, dass es dein Server ist; der Code muss `https://Rechnername` ohne Pfad und ohne IP-Adresse enthalten.
4. Unter „Konfigurieren“ änderst du später die Sensoren und die **Versandzeit** (Standard 00:05, **Berliner Zeit**, unabhängig von der Zeitzone von Home Assistant).

Sensoren in Wh oder MWh werden in kWh umgerechnet; andere Einheiten werden nicht gesendet.

## Was passiert

- Täglich zur Versandzeit wird je Kanal der aktuelle Stand gelesen und als verschlüsseltes Päckchen gesendet (ein Wert je Kanal und Tag, Datum nach Berliner Zeit).
- Ist ein Sensor `unavailable`, `unknown`, nicht numerisch, negativ oder größer als 9 999 999 999,999 kWh, wird **nichts** gesendet (Lücke statt falscher Null; das Protokoll nennt nie den Wert).
- Nur HTTP 400 und 422 gelten als endgültig abgelehnt (Päckchen wird verworfen). Schlägt der Versand sonst fehl (Server nicht erreichbar, Wartung, Limit, 403/404/408/413 oder Unbekanntes), bleibt das Päckchen in einer Warteschlange, die einen Neustart übersteht, und wird nach 1, 5, 15, 60 Minuten, danach stündlich wiederholt. Päckchen älter als 7 Tage werden verworfen.
- Nach einem Neustart wird der heutige Tag nachgeholt, falls die Versandzeit schon vorbei ist und für ihn noch nichts bestätigt wurde.
- War ein Sensor zur Versandzeit `unavailable`/`unknown`, wird er für den heutigen Tag **stündlich** (zur vollen Stunde, Berliner Zeit) erneut geprüft, bis ein gültiger Wert gesendet ist oder der Tag endet. Für einen Kanal und Tag wird nie ein zweites Päckchen gesendet.
- Der Dienst `familyhub.jetzt_senden` (Entwicklerwerkzeuge › Aktionen) liest die Sensoren sofort und sendet; zum Testen. Pro Kanal und Tag gibt es nur ein Päckchen.

## Diagnose-Sensoren

- **Letzter Versand**: Zeitpunkt der letzten bestätigten Übertragung.
- **Warteschlange**: Anzahl noch nicht bestätigter Päckchen (dauerhaft über 0 = Server nicht erreichbar).
- **Verbindung**: `verbunden`, `fehler` (nicht erreichbar, es wird wiederholt), `ungueltig` (Token widerrufen oder ungültig; es wird nichts mehr gesendet und HA zeigt einen Reparatur-Hinweis samt Neukopplung), `unbekannt` (noch nichts versucht).

## Fehlersuche

- Einstellungen › System › Protokolle, Filter `familyhub`. Das Protokoll nennt nur Kanalnamen und Anzahlen, nie Werte, Token oder Schlüssel.
- „Kopplungscode ungültig“: Code vollständig und unverändert einfügen (beginnt mit `FH1-`, die Adresse muss `https` sein).
- Verbindung `ungueltig`: In der App einen neuen Kopplungscode erzeugen und den Neukopplungs-Dialog von Home Assistant nutzen. Der neue Code darf ein anderes Token und ein anderes Schlüsselpaar tragen; noch nicht bestätigte Päckchen, die mit dem alten Schlüssel versiegelt waren, werden dann verworfen (das neue Postfach könnte sie nicht lesen).
- Warteschlange wächst: Erreichbarkeit von `familyhub.lx-labs.dev` prüfen; Wartungsmodus des Servers (`503`) ist normal und wird später nachgeholt.

## Datenschutz

Es werden **nur verschlüsselte Päckchen** gesendet (libsodium Sealed Box an den öffentlichen Postfach-Schlüssel aus dem Kopplungscode, dazu ein Prüfwert). Der Server sieht nie einen Wert und kann ihn nicht lesen; den privaten Schlüssel hat nur deine App. Gesendet wird nur an die Adresse aus dem Kopplungscode. In Home Assistant liegen Token, öffentlicher Schlüssel und Prüfgeheimnis, nie ein Schlüssel zum Lesen deiner Familyhub-Daten. **Hinweis:** Token und Prüfgeheimnis stehen im Klartext in `.storage/core.config_entries` und damit auch in Home-Assistant-Sicherungen; behandle diese Sicherungen als vertraulich. Wer sie liest, könnte gefälschte Stände einwerfen (aber nichts lesen); bei Verdacht das Token in der App widerrufen und neu koppeln. Restrisiko: Ein mitgeschnittenes altes Päckchen ließe sich wieder einwerfen (Replay), der Server nimmt pro Kanal und Tag aber nur eines an (Einzelheiten `docs/HA-FORMAT.md`).

## Token widerrufen

In der Familyhub-App (Admin) das Token der Verbindung widerrufen. Danach lehnt der Server es sofort ab, Home Assistant meldet „Verbindung ungültig“. Schon abgelegte Päckchen bleiben abholbar. Zum endgültigen Entfernen zusätzlich die Integration in Home Assistant löschen.

## Entwicklung und Tests

```bash
python -m venv .venv && .venv/bin/pip install -r homeassistant/requirements-test.txt
.venv/bin/python -m pytest homeassistant/tests
.venv/bin/python homeassistant/tools/vektor_erzeugen.py   # schreibt docs/ingest-vektoren.json (nur Testschlüssel)
```

Der Kern (`kern.py`: Kopplungscode, Päckchen, MAC, Warteschlange, Backoff) kommt ohne Home Assistant aus und wird getrennt getestet. Ändert sich ein Format, müssen `docs/HA-FORMAT.md`, der Testvektor und die App gemeinsam angepasst werden.
