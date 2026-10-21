// /api/v1/weather: aktuelles Wetter der Station des Betreibers für angemeldete Mitglieder. Antwort nur mit Ortsname und Messwerten
// (keine Straße, keine Koordinaten, keine Karte, keine Station-ID). Ist das Wetter aus, antwortet die Route mit available:false.
import type { FastifyInstance } from 'fastify';
import type { Auth } from '../auth/service.js';
import type { WeatherService } from '../weather/service.js';

export function registerWeatherRoutes(app: FastifyInstance, auth: Auth, weather: WeatherService): void {
  app.get('/api/v1/weather', async (req) => {
    await auth.requireSession(req);
    if (!weather.enabled) return { available: false };
    return { available: true, ...(await weather.view()) };
  });
}
