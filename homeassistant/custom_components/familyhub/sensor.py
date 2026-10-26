"""Diagnose-Sensoren: letzter Versand, Warteschlange, Verbindung."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.const import EntityCategory
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, VERBINDUNG_ZUSTAENDE
from .dienst import FamilyhubDienst


@dataclass(frozen=True, kw_only=True)
class FhSensorBeschreibung(SensorEntityDescription):
    wert: Callable[[FamilyhubDienst], Any]


BESCHREIBUNGEN = (
    FhSensorBeschreibung(
        key="letzter_versand",
        translation_key="letzter_versand",
        device_class=SensorDeviceClass.TIMESTAMP,
        entity_category=EntityCategory.DIAGNOSTIC,
        wert=lambda d: d.letzter_versand,
    ),
    FhSensorBeschreibung(
        key="warteschlange",
        translation_key="warteschlange",
        state_class=SensorStateClass.MEASUREMENT,
        entity_category=EntityCategory.DIAGNOSTIC,
        native_unit_of_measurement="Päckchen",
        wert=lambda d: len(d.queue),
    ),
    FhSensorBeschreibung(
        key="verbindung",
        translation_key="verbindung",
        device_class=SensorDeviceClass.ENUM,
        options=VERBINDUNG_ZUSTAENDE,
        entity_category=EntityCategory.DIAGNOSTIC,
        wert=lambda d: d.verbindung,
    ),
)


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    dienst: FamilyhubDienst = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(FhSensor(dienst, entry, b) for b in BESCHREIBUNGEN)


class FhSensor(SensorEntity):
    _attr_has_entity_name = True
    _attr_should_poll = False
    entity_description: FhSensorBeschreibung

    def __init__(
        self, dienst: FamilyhubDienst, entry: ConfigEntry, beschreibung: FhSensorBeschreibung
    ) -> None:
        self._dienst = dienst
        self.entity_description = beschreibung
        self._attr_unique_id = f"{entry.entry_id}_{beschreibung.key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=f"Familyhub {entry.title}",
            manufacturer="lx-labs",
            entry_type=DeviceEntryType.SERVICE,
        )

    @property
    def native_value(self) -> Any:
        return self.entity_description.wert(self._dienst)

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(
            async_dispatcher_connect(self.hass, self._dienst.signal, self._aktualisiert)
        )

    @callback
    def _aktualisiert(self) -> None:
        self.async_write_ha_state()
