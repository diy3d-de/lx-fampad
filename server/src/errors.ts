// Einheitliche Fehler: Antworten enthalten nie interne Meldungen (kein Stacktrace, keine Texte von Bibliotheken).
import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { ZodError } from 'zod';

/** Erwarteter Fehler mit festem Code und fester, nutzerfreundlicher Meldung. */
export class AppError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message?: string,
    readonly headers?: Record<string, string>,
    /** Zusätzliche, nicht geheime Felder der Fehlerantwort (z. B. `retryAfterSec`); nur additiv zu `error` und `message`. */
    readonly extra?: Record<string, string | number | boolean>,
  ) {
    super(message ?? code);
    this.name = 'AppError';
  }
}

const DEFAULT_MESSAGES: Record<number, string> = {
  400: 'Ungültige Eingabe.',
  401: 'Nicht angemeldet.',
  403: 'Nicht erlaubt.',
  404: 'Nicht gefunden.',
  409: 'Konflikt.',
  413: 'Anfrage zu groß.',
  415: 'Nicht unterstützter Inhaltstyp.',
  429: 'Zu viele Anfragen. Bitte später erneut versuchen.',
  500: 'Interner Fehler.',
  503: 'Der Server ist gerade nicht erreichbar.',
};

function body(code: string, status: number, message?: string) {
  return { error: code, message: message ?? DEFAULT_MESSAGES[status] ?? DEFAULT_MESSAGES[500] };
}

/** Ein eigener Fehlerhandler für die ganze App; Details stehen nur im Log. */
export function registerErrorHandling(app: FastifyInstance): void {
  app.setErrorHandler((err: FastifyError | AppError | ZodError, req: FastifyRequest, reply: FastifyReply) => {
    if (err instanceof AppError) {
      if (err.headers) reply.headers(err.headers);
      return reply.code(err.status).send({ ...err.extra, ...body(err.code, err.status, err.message === err.code ? undefined : err.message) });
    }
    if (err instanceof ZodError) {
      return reply.code(400).send(body('invalid_request', 400));
    }
    const status = (err as FastifyError).statusCode;
    if (typeof status === 'number' && status >= 400 && status < 500) {
      // Fastify-eigene Fehler (kaputtes JSON, zu großer Body, falscher Inhaltstyp, Rate-Limit): nur Status und Code
      const code =
        status === 429 ? 'rate_limited' : status === 413 ? 'payload_too_large' : status === 415 ? 'unsupported_media_type' : 'invalid_request';
      return reply.code(status).send(body(code, status));
    }
    req.log.error({ err }, 'Unbehandelter Fehler');
    return reply.code(500).send(body('internal_error', 500));
  });

  app.setNotFoundHandler((_req, reply) => reply.code(404).send(body('not_found', 404)));
}
