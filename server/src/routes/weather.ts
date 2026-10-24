// /api/v1/weather: aktuelles Wetter der Station des Betreibers für angemeldete Mitglieder. Antwort nur mit Ortsname und Messwerten
// (keine Straße, keine Koordinaten, keine Karte, keine Station-ID). Ist das Wetter aus, antwortet die Route mit available:false.
import type { FastifyInstance } from 'fastify';
import type { Auth } from '../auth/service.js';
import { createHash } from 'node:crypto';
import type { ForecastService } from '../weather/forecast.js';
import type { WeatherService } from '../weather/service.js';

export function registerWeatherRoutes(app: FastifyInstance, auth: Auth, weather: WeatherService, forecast: ForecastService): void {
  app.get('/api/v1/weather', async (req) => {
    await auth.requireSession(req);
    if (!weather.enabled) return { available: false };
    return { available: true, ...(await weather.view()) };
  });
  // Vorhersage und amtliche Warnungen (DWD): eigene Route, damit /weather unverändert bleibt. Nur aus der Datenbank, nie Koordinaten.
  // Ältere Apps kennen die Route nicht, neuere Apps behandeln 404 (älterer Server) als "keine Vorhersage".
  app.get('/api/v1/weather/forecast', async (req, reply) => {
    await auth.requireSession(req);
    if (!weather.enabled || !forecast.enabled) return { available: false };
    const view = { available: true, ...(await forecast.view()) };
    const etag = `"wf-${createHash('sha256').update(JSON.stringify(view)).digest('hex').slice(0, 24)}"`;
    const headers = { etag, 'cache-control': 'private, no-cache', vary: 'Authorization, Cookie' };
    const inm = req.headers['if-none-match'];
    if (typeof inm === 'string' && inm.split(',').some((t) => t.trim() === etag || t.trim() === `W/${etag}`)) return reply.code(304).headers(headers).send();
    return reply.headers(headers).send(view);
  });
}
