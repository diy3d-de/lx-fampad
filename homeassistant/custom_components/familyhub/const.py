"""Konstanten der Familyhub-Integration."""

DOMAIN = "familyhub"

# Daten des Eintrags (aus dem Kopplungscode)
CONF_URL = "url"
CONF_TOKEN = "token"
CONF_OEFFENTLICH = "oeffentlich"  # base64, Postfach-Schlüssel
CONF_GEHEIMNIS = "geheimnis"  # base64, Prüfgeheimnis
CONF_NAME_VERBINDUNG = "verbindungsname"

# Optionen
CONF_KANAELE = "kanaele"  # {kanal: entity_id}
CONF_VERSANDZEIT = "versandzeit"  # "HH:MM:SS"
DEFAULT_VERSANDZEIT = "00:05:00"

KANAL_BEZEICHNUNG = {
    "strom_bezug": "Strom Bezug",
    "strom_einspeisung": "Strom Einspeisung",
    "solar_erzeugung": "Solar Erzeugung",
}

# Zustände des Verbindungs-Sensors
VERBINDUNG_UNBEKANNT = "unbekannt"
VERBINDUNG_VERBUNDEN = "verbunden"
VERBINDUNG_UNGUELTIG = "ungueltig"
VERBINDUNG_FEHLER = "fehler"
VERBINDUNG_ZUSTAENDE = [
    VERBINDUNG_UNBEKANNT,
    VERBINDUNG_VERBUNDEN,
    VERBINDUNG_UNGUELTIG,
    VERBINDUNG_FEHLER,
]

SERVICE_JETZT_SENDEN = "jetzt_senden"
SIGNAL_AKTUALISIERT = "familyhub_aktualisiert_{}"
STORE_VERSION = 1
