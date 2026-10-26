"""Konfigurationsdialog: Kopplungscode, Kanäle, Optionen."""

from __future__ import annotations

import base64
from typing import Any

import voluptuous as vol
from homeassistant.config_entries import ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.core import callback
from homeassistant.helpers import selector

from .const import (
    CONF_GEHEIMNIS,
    CONF_KANAELE,
    CONF_OEFFENTLICH,
    CONF_TOKEN,
    CONF_URL,
    CONF_VERSANDZEIT,
    DEFAULT_VERSANDZEIT,
    DOMAIN,
)
from .kern import KANAELE, Kopplung, KopplungsFehler, host_anzeige, kopplungscode_lesen

CONF_CODE = "kopplungscode"

FEHLER_ZU_SCHLUESSEL = {
    "format": "code_format",
    "version": "code_version",
    "adresse": "code_adresse",
    "token": "code_token",
    "schluessel_laenge": "code_schluessel",
}


def _sensor_auswahl() -> selector.EntitySelector:
    return selector.EntitySelector(
        selector.EntitySelectorConfig(domain="sensor", device_class="energy")
    )


def _kanal_schema(vorgabe: dict[str, str] | None = None) -> dict:
    schema: dict = {}
    for kanal in KANAELE:
        if vorgabe and vorgabe.get(kanal):
            schema[vol.Optional(kanal, description={"suggested_value": vorgabe[kanal]})] = _sensor_auswahl()
        else:
            schema[vol.Optional(kanal)] = _sensor_auswahl()
    return schema


def _kanaele_aus(eingabe: dict[str, Any]) -> dict[str, str]:
    return {k: eingabe[k] for k in KANAELE if eingabe.get(k)}


class FamilyhubConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1

    def __init__(self) -> None:
        self._kopplung: Kopplung | None = None

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        fehler: dict[str, str] = {}
        if user_input is not None:
            try:
                self._kopplung = kopplungscode_lesen(user_input[CONF_CODE])
            except KopplungsFehler as exc:
                fehler["base"] = FEHLER_ZU_SCHLUESSEL.get(exc.code, "code_format")
            else:
                await self.async_set_unique_id(base64.b64encode(self._kopplung.oeffentlich).decode())
                self._abort_if_unique_id_configured()
                return await self.async_step_bestaetigen()
        return self.async_show_form(
            step_id="user",
            data_schema=vol.Schema({vol.Required(CONF_CODE): selector.TextSelector()}),
            errors=fehler,
        )

    async def async_step_bestaetigen(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Server-Host zur Bestätigung zeigen, bevor etwas gespeichert wird."""
        assert self._kopplung is not None
        if user_input is not None:
            return await self.async_step_kanaele()
        return self.async_show_form(
            step_id="bestaetigen",
            data_schema=vol.Schema({}),
            description_placeholders={"host": host_anzeige(self._kopplung.url)},
        )

    async def async_step_kanaele(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        assert self._kopplung is not None
        fehler: dict[str, str] = {}
        if user_input is not None:
            kanaele = _kanaele_aus(user_input)
            if not kanaele:
                fehler["base"] = "kein_kanal"
            else:
                k = self._kopplung
                return self.async_create_entry(
                    title=k.name,
                    data={
                        CONF_URL: k.url,
                        CONF_TOKEN: k.token,
                        CONF_OEFFENTLICH: base64.b64encode(k.oeffentlich).decode(),
                        CONF_GEHEIMNIS: base64.b64encode(k.geheimnis).decode(),
                    },
                    options={CONF_KANAELE: kanaele, CONF_VERSANDZEIT: DEFAULT_VERSANDZEIT},
                )
        return self.async_show_form(
            step_id="kanaele", data_schema=vol.Schema(_kanal_schema()), errors=fehler
        )

    # Neu koppeln, wenn der Server das Token ablehnt (401)
    async def async_step_reauth(self, entry_data: dict[str, Any]) -> ConfigFlowResult:
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        fehler: dict[str, str] = {}
        if user_input is not None:
            try:
                k = kopplungscode_lesen(user_input[CONF_CODE])
            except KopplungsFehler as exc:
                fehler["base"] = FEHLER_ZU_SCHLUESSEL.get(exc.code, "code_format")
            else:
                self._kopplung = k
                return await self.async_step_reauth_bestaetigen()
        return self.async_show_form(
            step_id="reauth_confirm",
            data_schema=vol.Schema({vol.Required(CONF_CODE): selector.TextSelector()}),
            errors=fehler,
        )

    async def async_step_reauth_bestaetigen(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Auch beim Neukoppeln den Server-Host zur Bestätigung zeigen (die Adresse kann sich ändern)."""
        k = self._kopplung
        assert k is not None
        if user_input is None:
            return self.async_show_form(
                step_id="reauth_bestaetigen",
                data_schema=vol.Schema({}),
                description_placeholders={"host": host_anzeige(k.url)},
            )
        eintrag = self._get_reauth_entry()
        # neuer Code darf ein anderes Token UND ein anderes Schlüsselpaar tragen;
        # eine Warteschlange mit altem Schlüssel verwirft der Dienst beim Start
        neu_pub = base64.b64encode(k.oeffentlich).decode()
        return self.async_update_reload_and_abort(
            eintrag,
            unique_id=neu_pub,
            data_updates={
                CONF_URL: k.url,
                CONF_TOKEN: k.token,
                CONF_OEFFENTLICH: neu_pub,
                CONF_GEHEIMNIS: base64.b64encode(k.geheimnis).decode(),
            },
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry) -> "FamilyhubOptionsFlow":
        return FamilyhubOptionsFlow()


class FamilyhubOptionsFlow(OptionsFlow):
    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        fehler: dict[str, str] = {}
        aktuell = self.config_entry.options
        if user_input is not None:
            kanaele = _kanaele_aus(user_input)
            if not kanaele:
                fehler["base"] = "kein_kanal"
            else:
                return self.async_create_entry(
                    data={
                        CONF_KANAELE: kanaele,
                        CONF_VERSANDZEIT: user_input.get(CONF_VERSANDZEIT, DEFAULT_VERSANDZEIT),
                    }
                )
        schema = _kanal_schema(aktuell.get(CONF_KANAELE))
        schema[
            vol.Required(
                CONF_VERSANDZEIT,
                default=aktuell.get(CONF_VERSANDZEIT, DEFAULT_VERSANDZEIT),
            )
        ] = selector.TimeSelector()
        return self.async_show_form(step_id="init", data_schema=vol.Schema(schema), errors=fehler)
