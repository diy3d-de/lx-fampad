"""Status-Zuordnung des Versands (braucht aiohttp, das Home Assistant mitbringt)."""

import importlib.util
import sys
from pathlib import Path

import pytest

pytest.importorskip("aiohttp")

PFAD = Path(__file__).resolve().parents[1] / "custom_components" / "familyhub" / "client.py"


@pytest.fixture(scope="module")
def client(kern):
    # als Teil eines Pakets laden, damit `from .kern import ...` greift
    import types

    paket = types.ModuleType("fhpaket")
    paket.__path__ = [str(PFAD.parent)]
    sys.modules["fhpaket"] = paket
    sys.modules["fhpaket.kern"] = kern
    spec = importlib.util.spec_from_file_location("fhpaket.client", PFAD)
    modul = importlib.util.module_from_spec(spec)
    sys.modules["fhpaket.client"] = modul
    spec.loader.exec_module(modul)
    return modul


@pytest.mark.parametrize(
    "status,name",
    [(200, "OK"), (401, "UNGUELTIG"), (429, "WIEDERHOLEN"), (503, "WIEDERHOLEN"), (500, "WIEDERHOLEN"),
     (400, "ABGELEHNT"), (422, "ABGELEHNT"),
     (403, "WIEDERHOLEN"), (404, "WIEDERHOLEN"), (408, "WIEDERHOLEN"), (413, "WIEDERHOLEN"),
     (201, "WIEDERHOLEN"), (302, "WIEDERHOLEN"), (418, "WIEDERHOLEN")],
)
def test_status(client, status, name):
    assert client.ausgang_aus_status(status) is client.Ausgang[name]
