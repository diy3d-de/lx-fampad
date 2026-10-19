import { aufgabeEntity, aufgabePunktEntity } from './entities/aufgaben.js';
import { listEntity, listItemEntity } from './entities/lists.js';
import { terminAusnahmeEntity, terminEntity, terminTeilnehmerEntity } from './entities/termine.js';
import { Registry } from './registry.js';

/** Alle synchronisierten Entitäten. Neue Fachbereiche (Chat, Dateien, ...) tragen sich hier ein. */
export const defaultRegistry = new Registry([
  listEntity,
  listItemEntity,
  terminEntity,
  terminTeilnehmerEntity,
  terminAusnahmeEntity,
  aufgabeEntity,
  aufgabePunktEntity,
]);
