"""Reiner Kern der Familyhub-Integration (ohne Home-Assistant-Importe).

Format laut docs/HA-FORMAT.md: Kopplungscode, Päckchen, MAC, Warteschlange,
Backoff. Wird getrennt von Home Assistant getestet.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import ipaddress
import json
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any
from zoneinfo import ZoneInfo

KOPPLUNG_PRAEFIX = "FH1-"
FORMAT_VERSION = 1
MAC_PRAEFIX = "fampad-ingest-v1\n"
K_PRAEFIX = "fampad-ingest-v1-k\n"
ZEITZONE = ZoneInfo("Europe/Berlin")

KANAELE = ("strom_bezug", "strom_einspeisung", "solar_erzeugung")
KANAL_MUSTER = re.compile(r"^[a-z0-9_]{1,40}$")
DATUM_MUSTER = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# wie die App (`\d{1,10}`, kMaxStandMilli = 10^13 Tausendstel): höchstens 10 Vorkommastellen, führende Nullen erlaubt
STAND_MUSTER = re.compile(r"^\d{1,10}(\.\d{1,6})?$")
TOKEN_MUSTER = re.compile(r"^fhi_[A-Za-z0-9_-]{43}$")
HOST_MUSTER = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")
PORT_MUSTER = re.compile(r"^[1-9]\d{0,4}$")
B64URL_MUSTER = re.compile(r"^[A-Za-z0-9_-]+$")
B64_MUSTER = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
ZAHL_MUSTER = re.compile(r"^\d+(\.\d+)?$")

MAX_ALTER_TAGE = 7
BACKOFF_MINUTEN = (1, 5, 15, 60)  # danach stündlich
MAX_ITEMS_JE_AUFRUF = 50


class KopplungsFehler(ValueError):
    """Kopplungscode ungültig. `code` ist ein fester Schlüssel für die Oberfläche."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class Kopplung:
    url: str
    token: str
    oeffentlich: bytes  # 32 Bytes, Postfach-Schlüssel (X25519)
    geheimnis: bytes  # 32 Bytes, Prüfgeheimnis für den MAC
    name: str


def _b64_32(wert: Any) -> bytes:
    if not isinstance(wert, str) or not B64_MUSTER.match(wert):
        raise KopplungsFehler("schluessel_laenge")
    try:
        roh = base64.b64decode(wert, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise KopplungsFehler("schluessel_laenge") from exc
    if len(roh) != 32:
        raise KopplungsFehler("schluessel_laenge")
    return roh


def kopplungs_adresse(adresse: str) -> str | None:
    """Basisadresse streng wie in der App (`kopplungsAdresse` samt Vergleich mit der Eingabe):
    nur https, nur Rechnername und optional Port (nicht 443), kein Pfad, keine Abfrage,
    kein Fragment, keine Zugangsdaten, kein IP-Literal. None, wenn die Adresse nicht
    genau diese Form hat."""
    if not isinstance(adresse, str) or adresse != adresse.strip() or len(adresse) > 300:
        return None
    if any(c in adresse for c in "?#@\\ \t\r\n") or not adresse.startswith("https://"):
        return None
    rest = adresse[len("https://"):]
    if "/" in rest:
        return None
    host, trenner, port_text = rest.partition(":")
    if not host or len(host) > 253 or not HOST_MUSTER.match(host) or _ist_ip_literal(host):
        return None
    if trenner:
        if not PORT_MUSTER.match(port_text) or not 1 <= int(port_text) <= 65535 or int(port_text) == 443:
            return None
        return f"https://{host}:{int(port_text)}" if str(int(port_text)) == port_text else None
    return f"https://{host}"


def _ist_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        pass
    # letzte Marke rein numerisch (z. B. 127.1, 2130706433): kein Name
    return host.rsplit(".", 1)[-1].isdigit()


def host_anzeige(url: str) -> str:
    """Rechnername (mit Port) zur Bestätigung in der Oberfläche."""
    return url[len("https://"):] if url.startswith("https://") else url


def kopplungscode_lesen(text: str) -> Kopplung:
    """Liest `FH1-…`. Wirft KopplungsFehler mit festem Code."""
    if not isinstance(text, str):
        raise KopplungsFehler("format")
    code = text.strip()
    if not code.startswith(KOPPLUNG_PRAEFIX):
        raise KopplungsFehler("format")
    rest = code[len(KOPPLUNG_PRAEFIX):]
    if not rest or len(rest) > 4096 or not B64URL_MUSTER.match(rest):
        raise KopplungsFehler("format")
    try:
        roh = base64.urlsafe_b64decode(rest + "=" * (-len(rest) % 4))
        daten = json.loads(roh.decode("utf-8"))
    except (binascii.Error, ValueError, UnicodeDecodeError) as exc:
        raise KopplungsFehler("format") from exc
    if not isinstance(daten, dict):
        raise KopplungsFehler("format")
    v = daten.get("v")
    if type(v) is not int or v != FORMAT_VERSION:
        raise KopplungsFehler("version")

    url = daten.get("u")
    if not isinstance(url, str) or kopplungs_adresse(url) != url:
        raise KopplungsFehler("adresse")

    token = daten.get("t")
    if not isinstance(token, str) or not TOKEN_MUSTER.match(token):
        raise KopplungsFehler("token")

    oeffentlich = _b64_32(daten.get("p"))
    geheimnis = _b64_32(daten.get("s"))

    name = daten.get("n")
    if not isinstance(name, str):
        name = ""
    name = "".join(c for c in name if c.isprintable()).strip()[:40] or "Familyhub"
    return Kopplung(url, token, oeffentlich, geheimnis, name)


def stand_text(wert: Any) -> str | None:
    """Sensorzustand -> Dezimaltext mit Punkt (höchstens 6 Nachkommastellen,
    höchstens 10 Vorkommastellen) oder None (nichts senden). Nie über float-Rechnung."""
    if isinstance(wert, bool) or wert is None:
        return None
    if isinstance(wert, Decimal):
        text = format(wert, "f") if wert.is_finite() else ""
    elif isinstance(wert, (float, int)):
        text = repr(wert)
    elif isinstance(wert, str):
        text = wert.strip()
    else:
        return None
    if not ZAHL_MUSTER.match(text):
        return None  # Komma, Exponent, Vorzeichen, unavailable usw.
    try:
        d = Decimal(text).quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
    except InvalidOperation:
        return None
    ergebnis = format(d, "f")
    if "." in ergebnis:
        ergebnis = ergebnis.rstrip("0").rstrip(".")
    if not STAND_MUSTER.match(ergebnis):
        return None
    return ergebnis


_KWH_FAKTOR = {
    "kWh": Decimal(1),
    "Wh": Decimal("0.001"),
    "MWh": Decimal(1000),
    "GWh": Decimal(1000000),
}


def stand_aus_zustand(zustand: Any, einheit: str | None) -> str | None:
    """Sensorzustand (Text) + Einheit des Sensors -> Stand in kWh als Text.

    Ohne Einheit gilt kWh; unbekannte Einheit = nichts senden."""
    if einheit is not None and einheit not in _KWH_FAKTOR:
        return None
    if not isinstance(zustand, str) or not ZAHL_MUSTER.match(zustand.strip()):
        return None
    faktor = _KWH_FAKTOR.get(einheit or "kWh", Decimal(1))
    return stand_text(Decimal(zustand.strip()) * faktor)


def berliner_datum(zeitpunkt: datetime) -> str:
    """Kalendertag (YYYY-MM-DD) in Europe/Berlin; naive Zeiten gelten als UTC."""
    if zeitpunkt.tzinfo is None:
        zeitpunkt = zeitpunkt.replace(tzinfo=timezone.utc)
    return zeitpunkt.astimezone(ZEITZONE).date().isoformat()


def epoch_ms(zeitpunkt: datetime) -> int:
    if zeitpunkt.tzinfo is None:
        zeitpunkt = zeitpunkt.replace(tzinfo=timezone.utc)
    return int(zeitpunkt.timestamp() * 1000)


def mac_berechnen(geheimnis: bytes, kanal: str, d: str, t: int, stand: str, einheit: str) -> str:
    nachricht = f"{MAC_PRAEFIX}{kanal}\n{d}\n{t}\n{stand}\n{einheit}".encode("utf-8")
    return hashlib.blake2b(nachricht, key=geheimnis, digest_size=32).hexdigest()


def klartext_bauen(
    geheimnis: bytes, kanal: str, d: str, t: int, stand: str, einheit: str = "kWh"
) -> str:
    """Klartext-JSON (kompakt) eines Päckchens samt MAC."""
    if not KANAL_MUSTER.match(kanal):
        raise ValueError("kanal")
    if not DATUM_MUSTER.match(d):
        raise ValueError("datum")
    if not STAND_MUSTER.match(stand):
        raise ValueError("stand")
    if type(t) is not int or t < 0:
        raise ValueError("zeit")
    objekt = {
        "v": FORMAT_VERSION,
        "kanal": kanal,
        "d": d,
        "t": t,
        "stand": stand,
        "e": einheit,
        "mac": mac_berechnen(geheimnis, kanal, d, t, stand, einheit),
    }
    return json.dumps(objekt, separators=(",", ":"), ensure_ascii=False)


def versiegeln(oeffentlich: bytes, klartext: str) -> str:
    """Sealed Box (crypto_box_seal) an den Postfach-Schlüssel, base64 (Standard)."""
    from nacl.public import PublicKey, SealedBox

    box = SealedBox(PublicKey(oeffentlich)).encrypt(klartext.encode("utf-8"))
    return base64.b64encode(box).decode("ascii")


def schluessel(kanal: str, d: str) -> str:
    """Lokaler Schlüssel (Kanal, Tag) für die Warteschlange; wird nie gesendet."""
    return f"{kanal}:{d}"


def eindeutigkeit(geheimnis: bytes, kanal: str, d: str) -> str:
    """`k` des Päckchens: BLAKE2b-128 (Schlüssel = Prüfgeheimnis) über Kanal und Tag,
    32 Hex-Zeichen. Der Server sieht weder Kanal noch Datum."""
    nachricht = f"{K_PRAEFIX}{kanal}\n{d}".encode("utf-8")
    return hashlib.blake2b(nachricht, key=geheimnis, digest_size=16).hexdigest()


def paeckchen_bauen(
    kopplung: Kopplung, kanal: str, d: str, t: int, stand: str, einheit: str = "kWh"
) -> dict[str, Any]:
    """Fertiges, verschlüsseltes Warteschlangen-Element {k, kanal, d, box}."""
    klartext = klartext_bauen(kopplung.geheimnis, kanal, d, t, stand, einheit)
    return {
        "k": eindeutigkeit(kopplung.geheimnis, kanal, d),
        "kanal": kanal,
        "d": d,
        "box": versiegeln(kopplung.oeffentlich, klartext),
    }


# ---------------------------------------------------------------- Backoff

def backoff_minuten(fehlversuche: int) -> int:
    """Wartezeit nach dem n-ten Fehlversuch (n >= 1): 1, 5, 15, 60, dann 60."""
    if fehlversuche < 1:
        return 0
    return BACKOFF_MINUTEN[min(fehlversuche, len(BACKOFF_MINUTEN)) - 1]


# ---------------------------------------------------------------- Nachholen

def fehlende_kanaele(queue: "Warteschlange", kanaele: list[str], d: str) -> list[str]:
    """Kanäle, für die für Tag `d` weder ein offenes noch ein bestätigtes Päckchen existiert."""
    return [k for k in kanaele if not queue.hat_tag(k, d)]


# ---------------------------------------------------------------- Versandzeit (Europe/Berlin)

def berlin_zeit(zeitpunkt: datetime) -> datetime:
    """Zeitpunkt in Europe/Berlin; naive Zeiten gelten als UTC."""
    if zeitpunkt.tzinfo is None:
        zeitpunkt = zeitpunkt.replace(tzinfo=timezone.utc)
    return zeitpunkt.astimezone(ZEITZONE)


def naechster_versand(jetzt: datetime, versand_hms: tuple[int, int, int]) -> datetime:
    """Nächste Versandzeit (Wanduhr Europe/Berlin) nach `jetzt`, als UTC-Zeitpunkt."""
    b = berlin_zeit(jetzt)
    h, m, s = versand_hms
    tag = b.date()
    kandidat = b
    for _ in range(3):
        kandidat = datetime(tag.year, tag.month, tag.day, h, m, s, tzinfo=ZEITZONE)
        if kandidat.astimezone(timezone.utc) > b.astimezone(timezone.utc):
            break
        tag += timedelta(days=1)
    return kandidat.astimezone(timezone.utc)


def nachholen_faellig(jetzt_hms: tuple[int, int, int], versand_hms: tuple[int, int, int]) -> bool:
    """Stündliches Nachholen erst ab der Versandzeit des (Orts-)Tages."""
    return jetzt_hms >= versand_hms


def warteschlange_passt(gespeicherter_schluessel: Any, aktueller_schluessel: str) -> bool:
    """Alte Päckchen sind nur mit demselben öffentlichen Postfach-Schlüssel lesbar.
    Fehlt die Angabe (ältere Ablage), gilt die Warteschlange als passend."""
    if gespeicherter_schluessel is None:
        return True
    return gespeicherter_schluessel == aktueller_schluessel


# ---------------------------------------------------------------- Warteschlange

def _tag(d: str) -> datetime:
    return datetime.strptime(d, "%Y-%m-%d").replace(tzinfo=ZEITZONE)


class Warteschlange:
    """Noch nicht bestätigte Päckchen plus Merkliste bestätigter Tage.

    Zustand ist JSON-fähig (`zu_dict`/`aus_dict`) für den HA-Store.
    """

    def __init__(self) -> None:
        # beide nach lokalem Schlüssel "kanal:tag" (nicht nach `k`, das ist ein Hash)
        self.offen: dict[str, dict[str, Any]] = {}  # lokal -> Päckchen
        self.bestaetigt: dict[str, str] = {}  # lokal -> d (nur Merkliste)

    def hinzufuegen(self, paeckchen: dict[str, Any]) -> bool:
        """False bei Duplikat (offen oder schon bestätigt)."""
        k = schluessel(paeckchen["kanal"], paeckchen["d"])
        if k in self.offen or k in self.bestaetigt:
            return False
        self.offen[k] = paeckchen
        return True

    def bestaetigen(self, schluessel_liste: list[str]) -> None:
        """Nimmt Päckchen nach lokalem Schlüssel (`kanal:tag`) aus der Warteschlange."""
        for k in schluessel_liste:
            p = self.offen.pop(k, None)
            if p is not None:
                self.bestaetigt[k] = p["d"]

    def abgelehnt(self, paeckchen: dict[str, Any]) -> None:
        """Endgültig abgelehntes Päckchen verwerfen und den Tag als erledigt merken."""
        k = schluessel(paeckchen["kanal"], paeckchen["d"])
        self.offen.pop(k, None)
        self.bestaetigt[k] = paeckchen["d"]

    def hat_tag(self, kanal: str, d: str) -> bool:
        k = schluessel(kanal, d)
        return k in self.offen or k in self.bestaetigt

    def tag_vergessen(self, d: str) -> int:
        """Vergisst die Merkliste der bestätigten Päckchen für Tag `d` (offene bleiben), damit der Tag neu gesendet werden kann."""
        weg = [k for k, tag in self.bestaetigt.items() if tag == d]
        for k in weg:
            del self.bestaetigt[k]
        return len(weg)

    def verwerfen_alte(self, heute: str) -> list[str]:
        """Verwirft offene Päckchen älter als 7 Tage (Merkliste: 14 Tage)."""
        grenze = _tag(heute) - timedelta(days=MAX_ALTER_TAGE)
        weg = [k for k, p in self.offen.items() if _tag(p["d"]) < grenze]
        for k in weg:
            del self.offen[k]
        alt = grenze - timedelta(days=MAX_ALTER_TAGE)
        for k in [k for k, d in self.bestaetigt.items() if _tag(d) < alt]:
            del self.bestaetigt[k]
        return weg

    def naechste(self, grenze: int = MAX_ITEMS_JE_AUFRUF) -> list[dict[str, Any]]:
        return sorted(self.offen.values(), key=lambda p: (p["d"], p["kanal"]))[:grenze]

    def __len__(self) -> int:
        return len(self.offen)

    def zu_dict(self) -> dict[str, Any]:
        return {"offen": list(self.offen.values()), "bestaetigt": dict(self.bestaetigt)}

    @classmethod
    def aus_dict(cls, daten: Any) -> "Warteschlange":
        w = cls()
        if not isinstance(daten, dict):
            return w
        for p in daten.get("offen") or []:
            if (
                isinstance(p, dict)
                and all(isinstance(p.get(f), str) for f in ("k", "kanal", "d", "box"))
                and DATUM_MUSTER.match(p["d"])
            ):
                w.offen[schluessel(p["kanal"], p["d"])] = {f: p[f] for f in ("k", "kanal", "d", "box")}
        best = daten.get("bestaetigt") or {}
        if isinstance(best, dict):
            for k, d in best.items():
                if isinstance(k, str) and isinstance(d, str) and DATUM_MUSTER.match(d):
                    w.bestaetigt[k] = d
        return w
