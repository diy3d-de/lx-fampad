// Einstieg des Wetter-Abruf-Takts. Der Abruf läuft NICHT im API-Prozess (lx-fampad.service darf nur Loopback erreichen),
// sondern im eigenen Dienst lx-fampad-weather.service (cli/weather-poller.ts). Hier steht nur die testbare Verdrahtung.
import type { Logger } from '../auth/context.js';
import type { WeatherService } from './service.js';

/** Startet den einen Abruf-Takt; ohne WEATHER_ENABLED passiert nichts (false). */
export function startWeatherPoller(weather: WeatherService, log: Logger): boolean {
  if (!weather.enabled) {
    log.warn({ code: 'weather_disabled' }, 'WEATHER_ENABLED ist nicht gesetzt: kein Abruf');
    return false;
  }
  weather.start();
  return true;
}
