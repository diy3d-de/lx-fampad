"""Ablauf der Integration: Tagesversand, Warteschlange, Wiederholung."""

from __future__ import annotations

import asyncio
import base64
import logging
from datetime import datetime
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, HomeAssistant, callback
from homeassistant.helpers import issue_registry as ir
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.event import (
    async_call_later,
    async_track_point_in_utc_time,
    async_track_utc_time_change,
)
from homeassistant.helpers.start import async_at_started
from homeassistant.helpers.storage import Store
from homeassistant.util import dt as dt_util

from .client import Ausgang, senden
from .const import (
    CONF_GEHEIMNIS,
    CONF_KANAELE,
    CONF_OEFFENTLICH,
    CONF_TOKEN,
    CONF_URL,
    CONF_VERSANDZEIT,
    DEFAULT_VERSANDZEIT,
    DOMAIN,
    SIGNAL_AKTUALISIERT,
    STORE_VERSION,
    VERBINDUNG_FEHLER,
    VERBINDUNG_UNBEKANNT,
    VERBINDUNG_UNGUELTIG,
    VERBINDUNG_VERBUNDEN,
)
from .kern import (
    Kopplung,
    Warteschlange,
    backoff_minuten,
    berlin_zeit,
    berliner_datum,
    epoch_ms,
    fehlende_kanaele,
    nachholen_faellig,
    naechster_versand,
    paeckchen_bauen,
    schluessel,
    stand_aus_zustand,
    warteschlange_passt,
)

_LOGGER = logging.getLogger(__name__)


def zeit_teile(text: str) -> tuple[int, int, int]:
    """'HH:MM[:SS]' -> (h, m, s); bei Unsinn der Standard."""
    try:
        teile = [int(x) for x in text.split(":")]
        while len(teile) < 3:
            teile.append(0)
        h, m, s = teile[:3]
        if 0 <= h < 24 and 0 <= m < 60 and 0 <= s < 60:
            return h, m, s
    except (ValueError, AttributeError):
        pass
    return (0, 5, 0)


class FamilyhubDienst:
    """Eine Verbindung (ein Konfigurationseintrag)."""

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self.kopplung = Kopplung(
            url=entry.data[CONF_URL],
            token=entry.data[CONF_TOKEN],
            oeffentlich=base64.b64decode(entry.data[CONF_OEFFENTLICH]),
            geheimnis=base64.b64decode(entry.data[CONF_GEHEIMNIS]),
            name=entry.title,
        )
        self.queue = Warteschlange()
        self.verbindung = VERBINDUNG_UNBEKANNT
        self.letzter_versand: datetime | None = None
        self.fehlversuche = 0
        self._store: Store = Store(hass, STORE_VERSION, f"{DOMAIN}.{entry.entry_id}")
        self._lock = asyncio.Lock()
        self._entladen: list[CALLBACK_TYPE] = []
        self._retry: CALLBACK_TYPE | None = None
        self._versand_timer: CALLBACK_TYPE | None = None

    @property
    def signal(self) -> str:
        return SIGNAL_AKTUALISIERT.format(self.entry.entry_id)

    @property
    def kanaele(self) -> dict[str, str]:
        roh = self.entry.options.get(CONF_KANAELE) or {}
        return {k: v for k, v in roh.items() if isinstance(v, str) and v}

    # ------------------------------------------------------------ Start/Ende

    async def async_start(self) -> None:
        daten = await self._store.async_load()
        if isinstance(daten, dict):
            if warteschlange_passt(daten.get("oeffentlich"), self.entry.data[CONF_OEFFENTLICH]):
                self.queue = Warteschlange.aus_dict(daten.get("queue"))
            else:
                _LOGGER.warning("Neuer Postfach-Schlüssel: alte Warteschlange verworfen")
            roh = daten.get("letzter_versand")
            self.letzter_versand = dt_util.parse_datetime(roh) if isinstance(roh, str) else None

        # Versandzeit gilt als Wanduhr in Europe/Berlin (nicht in der HA-Zeitzone)
        self._versand_planen()
        # stündlich nachholen, falls ein Sensor zur Versandzeit keinen gültigen Wert hatte
        # (volle UTC-Stunde = volle Berliner Stunde; geprüft wird in Berliner Zeit)
        self._entladen.append(
            async_track_utc_time_change(self.hass, self._stuendlich, minute=0, second=0)
        )
        self._entladen.append(async_at_started(self.hass, self._nach_start))

    async def _nach_start(self, _hass: HomeAssistant) -> None:
        """Verpassten Tag nachholen (nur wenn die Versandzeit heute schon war)."""
        jetzt = berlin_zeit(dt_util.utcnow())
        h, m, s = zeit_teile(self.entry.options.get(CONF_VERSANDZEIT, DEFAULT_VERSANDZEIT))
        if nachholen_faellig((jetzt.hour, jetzt.minute, jetzt.second), (h, m, s)):
            await self.tagesversand(jetzt)
        else:
            await self.flush()

    @callback
    def async_stop(self) -> None:
        for aus in self._entladen:
            aus()
        self._entladen.clear()
        self._retry_abbrechen()
        if self._versand_timer is not None:
            self._versand_timer()
            self._versand_timer = None

    # ------------------------------------------------------------ Ablauf

    def _versand_planen(self) -> None:
        if self._versand_timer is not None:
            self._versand_timer()
        versand = zeit_teile(self.entry.options.get(CONF_VERSANDZEIT, DEFAULT_VERSANDZEIT))
        zeit = naechster_versand(dt_util.utcnow(), versand)
        self._versand_timer = async_track_point_in_utc_time(self.hass, self._zeit_erreicht, zeit)

    async def _zeit_erreicht(self, _jetzt: datetime) -> None:
        self._versand_timer = None
        try:
            await self.tagesversand()  # t = tatsächlicher Lesezeitpunkt
        finally:
            self._versand_planen()

    async def _stuendlich(self, jetzt: datetime) -> None:
        """Nur wenn die Versandzeit heute vorbei ist und für `d` noch Kanäle fehlen.
        Der Tag endet mit dem Datumswechsel; tagesversand sendet nie zweimal für d."""
        jetzt = berlin_zeit(jetzt)
        versand = zeit_teile(self.entry.options.get(CONF_VERSANDZEIT, DEFAULT_VERSANDZEIT))
        if not nachholen_faellig((jetzt.hour, jetzt.minute, jetzt.second), versand):
            return
        if fehlende_kanaele(self.queue, list(self.kanaele), berliner_datum(jetzt)):
            await self.tagesversand(jetzt)

    def _stand_lesen(self, entity_id: str) -> str | None:
        zustand = self.hass.states.get(entity_id)
        if zustand is None:
            return None
        return stand_aus_zustand(zustand.state, zustand.attributes.get("unit_of_measurement"))

    async def tagesversand(self, jetzt: datetime | None = None) -> None:
        """Stand je Kanal lesen, Päckchen anlegen (je Tag und Kanal einmal), senden."""
        jetzt = berlin_zeit(jetzt or dt_util.utcnow())
        d = berliner_datum(jetzt)
        t = epoch_ms(jetzt)
        for kanal, entity_id in self.kanaele.items():
            if self.queue.hat_tag(kanal, d):
                continue
            stand = self._stand_lesen(entity_id)
            if stand is None:
                _LOGGER.info(
                    "Kanal %s: Sensor liefert keinen gültigen Wert (oder über dem Höchstwert), nichts gesendet",
                    kanal,
                )
                continue
            self.queue.hinzufuegen(paeckchen_bauen(self.kopplung, kanal, d, t, stand))
        verworfen = self.queue.verwerfen_alte(d)
        if verworfen:
            _LOGGER.warning("%d Päckchen älter als 7 Tage verworfen", len(verworfen))
        await self._speichern()
        await self.flush()

    async def flush(self) -> None:
        async with self._lock:
            self._retry_abbrechen()
            if self.verbindung == VERBINDUNG_UNGUELTIG:
                # kein Dauerversand mit ungültigem Token; neu koppeln lädt den Eintrag neu
                self._melden()
                return
            while len(self.queue):
                if not await self._runde(self.queue.naechste()):
                    break
            self._melden()

    async def _runde(self, batch: list[dict[str, Any]]) -> bool:
        """Sendet einen Stapel. True = weitermachen, False = anhalten."""
        session = async_get_clientsession(self.hass)
        antwort = await senden(session, self.kopplung, batch)
        if antwort.ausgang is Ausgang.OK:
            self.queue.bestaetigen([schluessel(p["kanal"], p["d"]) for p in batch])
            self.letzter_versand = dt_util.utcnow()
            self.fehlversuche = 0
            self.verbindung = VERBINDUNG_VERBUNDEN
            ir.async_delete_issue(self.hass, DOMAIN, f"verbindung_ungueltig_{self.entry.entry_id}")
            await self._speichern()
            return True
        if antwort.ausgang is Ausgang.UNGUELTIG:
            self.verbindung = VERBINDUNG_UNGUELTIG
            _LOGGER.error("Familyhub hat die Verbindung abgelehnt (401). Bitte neu koppeln.")
            ir.async_create_issue(
                self.hass,
                DOMAIN,
                f"verbindung_ungueltig_{self.entry.entry_id}",
                is_fixable=False,
                severity=ir.IssueSeverity.ERROR,
                translation_key="verbindung_ungueltig",
                translation_placeholders={"name": self.entry.title},
            )
            self.entry.async_start_reauth(self.hass)
            return False
        if antwort.ausgang is Ausgang.WIEDERHOLEN:
            self.fehlversuche += 1
            self.verbindung = VERBINDUNG_FEHLER
            minuten = backoff_minuten(self.fehlversuche)
            _LOGGER.warning(
                "Familyhub nicht erreichbar oder ausgelastet (Status %s), neuer Versuch in %d Minuten, "
                "%d in der Warteschlange",
                antwort.status if antwort.status is not None else "Netzfehler",
                minuten,
                len(self.queue),
            )
            self._retry = async_call_later(self.hass, minuten * 60, self._retry_faellig)
            return False
        # endgültig abgelehnt (nur 400 und 422)
        if len(batch) > 1:
            for p in batch:
                if not await self._runde([p]):
                    return False
            return True
        p = batch[0]
        self.queue.abgelehnt(p)  # nicht stündlich neu versuchen
        _LOGGER.error("Familyhub hat das Päckchen für Kanal %s abgelehnt (Status %s), verworfen", p["kanal"], antwort.status)
        await self._speichern()
        return True

    async def _retry_faellig(self, _jetzt: datetime) -> None:
        self._retry = None
        await self.flush()

    def _retry_abbrechen(self) -> None:
        if self._retry is not None:
            self._retry()
            self._retry = None

    # ------------------------------------------------------------ Hilfen

    async def _speichern(self) -> None:
        await self._store.async_save(
            {
                "oeffentlich": self.entry.data[CONF_OEFFENTLICH],
                "queue": self.queue.zu_dict(),
                "letzter_versand": self.letzter_versand.isoformat() if self.letzter_versand else None,
            }
        )

    def _melden(self) -> None:
        async_dispatcher_send(self.hass, self.signal)
