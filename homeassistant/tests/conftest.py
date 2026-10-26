"""Lädt den reinen Kern direkt aus der Datei (ohne Home Assistant)."""

import importlib.util
import json
import sys
from pathlib import Path

import pytest

WURZEL = Path(__file__).resolve().parents[2]
KERN = WURZEL / "homeassistant" / "custom_components" / "familyhub" / "kern.py"

spec = importlib.util.spec_from_file_location("fh_kern", KERN)
_kern = importlib.util.module_from_spec(spec)
sys.modules["fh_kern"] = _kern
spec.loader.exec_module(_kern)


@pytest.fixture(scope="session")
def kern():
    return _kern


@pytest.fixture(scope="session")
def vektor():
    return json.loads((WURZEL / "docs" / "ingest-vektoren.json").read_text(encoding="utf-8"))
