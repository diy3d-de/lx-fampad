import { readFileSync } from 'node:fs';

/** Version des Servers aus package.json (liegt von src/ und dist/ aus eine Ebene höher). */
export const SERVER_VERSION: string = (
  JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string }
).version;

/**
 * Protokollversion des Sync-/WebSocket-Protokolls. Der Client sendet seine Version mit;
 * ist sie kleiner als MIN_PROTOCOL_VERSION, antwortet der Server mit "Update nötig".
 */
export const PROTOCOL_VERSION = 1;
export const MIN_PROTOCOL_VERSION = 1;
