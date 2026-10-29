"""Familyhub: schickt tägliche Zählerstände verschlüsselt an deinen Familyhub-Server."""

from __future__ import annotations

import voluptuous as vol
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.helpers import issue_registry as ir

from .const import DOMAIN, SERVICE_JETZT_SENDEN
from .dienst import FamilyhubDienst

PLATFORMS = [Platform.SENSOR]


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    async def jetzt_senden(call: ServiceCall) -> None:
        for dienst in list(hass.data.get(DOMAIN, {}).values()):
            await dienst.tagesversand(erneut=call.data["erneut"])

    hass.services.async_register(
        DOMAIN,
        SERVICE_JETZT_SENDEN,
        jetzt_senden,
        schema=vol.Schema({vol.Optional("erneut", default=False): bool}),
    )
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    dienst = FamilyhubDienst(hass, entry)
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = dienst
    await dienst.async_start()
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_on_unload(entry.add_update_listener(_optionen_geaendert))
    return True


async def _optionen_geaendert(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if ok:
        hass.data[DOMAIN].pop(entry.entry_id).async_stop()
    return ok


async def async_remove_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    ir.async_delete_issue(hass, DOMAIN, f"verbindung_ungueltig_{entry.entry_id}")
