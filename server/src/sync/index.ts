import { listEntity, listItemEntity } from './entities/lists.js';
import { Registry } from './registry.js';

/** Alle synchronisierten Entitäten. Neue Fachbereiche (Termine, Aufgaben, ...) tragen sich hier ein. */
export const defaultRegistry = new Registry([listEntity, listItemEntity]);
