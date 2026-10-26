"""Erzeugt docs/ingest-vektoren.json (NUR Testschlüssel, nie echte).

Aufruf: python homeassistant/tools/vektor_erzeugen.py   (braucht PyNaCl)
"""

import base64
import importlib.util
import json
import sys
from pathlib import Path

from nacl.bindings import crypto_box_seed_keypair

WURZEL = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "fh_kern", WURZEL / "homeassistant/custom_components/familyhub/kern.py"
)
kern = importlib.util.module_from_spec(spec)
sys.modules["fh_kern"] = kern
spec.loader.exec_module(kern)

SEED = bytes(range(1, 33))
S = bytes(range(101, 133))


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


oeffentlich, geheim = crypto_box_seed_keypair(SEED)
klartext = kern.klartext_bauen(S, "strom_bezug", "2026-10-26", 1793059140000, "2951.709566", "kWh")
mac = json.loads(klartext)["mac"]
ziel = WURZEL / "docs/ingest-vektoren.json"
box = None
if ziel.exists():
    # Sealed Box ist zufällig: eine vorhandene, zum Klartext passende Box bleibt unverändert,
    # damit die App-Tests (feste Box im Vektor) stabil bleiben
    from nacl.public import PrivateKey, SealedBox

    try:
        vorher = json.loads(ziel.read_text(encoding="utf-8"))
        if (
            vorher.get("klartext") == klartext
            and SealedBox(PrivateKey(geheim)).decrypt(base64.b64decode(vorher["boxBase64"])).decode() == klartext
        ):
            box = vorher["boxBase64"]
    except Exception:
        box = None
if box is None:
    box = kern.versiegeln(oeffentlich, klartext)
k = kern.eindeutigkeit(S, "strom_bezug", "2026-10-26")

code_json = json.dumps(
    {
        "v": 1,
        "u": "https://test.invalid",
        "t": "fhi_TESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTES",
        "p": b64(oeffentlich),
        "s": b64(S),
        "n": "Testverbindung",
    },
    separators=(",", ":"),
)
code = "FH1-" + base64.urlsafe_b64encode(code_json.encode()).decode().rstrip("=")

ergebnis = {
    "hinweis": "NUR TESTSCHLUESSEL. Erzeugt von homeassistant/tools/vektor_erzeugen.py. Nie echte Schluessel hier.",
    "seedHex": SEED.hex(),
    "oeffentlichHex": oeffentlich.hex(),
    "oeffentlichBase64": b64(oeffentlich),
    "geheimHex": geheim.hex(),
    "sHex": S.hex(),
    "sBase64": b64(S),
    "klartext": klartext,
    "mac": mac,
    "k": k,
    "boxBase64": box,
    "kopplungscode": code,
}
ziel.write_text(json.dumps(ergebnis, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("geschrieben:", ziel)
