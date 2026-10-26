"""Versand der Päckchen an den Familyhub-Server (nur aiohttp, kein Home Assistant).

Es wird nie ein Wert, Token oder Schlüssel geloggt.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any

import aiohttp

from .kern import Kopplung

_LOGGER = logging.getLogger(__name__)

TIMEOUT_SEKUNDEN = 20


class Ausgang(Enum):
    OK = "ok"  # 200
    UNGUELTIG = "ungueltig"  # 401: Token ungültig/widerrufen
    WIEDERHOLEN = "wiederholen"  # alles andere (429, 5xx, 403, 404, 408, 413 ...), Netzfehler, Zeitlimit
    ABGELEHNT = "abgelehnt"  # nur 400 und 422: Päckchen taugt nicht


@dataclass(frozen=True)
class Antwort:
    ausgang: Ausgang
    status: int | None = None
    angenommen: int = 0
    doppelt: int = 0


def ausgang_aus_status(status: int) -> Ausgang:
    if status == 200:
        return Ausgang.OK
    if status == 401:
        return Ausgang.UNGUELTIG
    if status in (400, 422):
        return Ausgang.ABGELEHNT
    # Proxy-/Wartungsseiten (403, 404, 408, 413 ...) und Unbekanntes: nie Daten wegwerfen;
    # das Päckchen bleibt in der Warteschlange (sie räumt sich nach 7 Tagen selbst auf)
    return Ausgang.WIEDERHOLEN


async def senden(
    session: aiohttp.ClientSession, kopplung: Kopplung, paeckchen: list[dict[str, Any]]
) -> Antwort:
    """Sendet 1 bis 50 Päckchen. Wirft nie bei Netzfehlern."""
    url = f"{kopplung.url}/api/v1/ingest/zaehler"
    kopf = {"Authorization": f"Bearer {kopplung.token}", "Content-Type": "application/json"}
    body = {"items": [{"k": p["k"], "box": p["box"]} for p in paeckchen]}
    try:
        async with session.post(
            url,
            json=body,
            headers=kopf,
            allow_redirects=False,
            timeout=aiohttp.ClientTimeout(total=TIMEOUT_SEKUNDEN),
        ) as antwort:
            status = antwort.status
            ausgang = ausgang_aus_status(status)
            angenommen = doppelt = 0
            if ausgang is Ausgang.OK:
                try:
                    daten = await antwort.json(content_type=None)
                    angenommen = int(daten.get("accepted", 0))
                    doppelt = int(daten.get("duplicates", 0))
                except (aiohttp.ClientError, ValueError, TypeError, AttributeError):
                    pass
            return Antwort(ausgang, status, angenommen, doppelt)
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as exc:
        # nur der Fehlertyp, nie Adresse oder Kopfzeilen
        _LOGGER.debug("Netzfehler beim Versand: %s", type(exc).__name__)
        return Antwort(Ausgang.WIEDERHOLEN, None)
