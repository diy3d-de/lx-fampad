import { epocheEntity, epocheWrapEntity } from './entities/chat-epochen.js';
import { konversationEntity, lesestandEntity, nachrichtEntity } from './entities/chat.js';
import { listEntity, listItemEntity } from './entities/lists.js';
import { terminAusnahmeEntity, terminEntity, terminTeilnehmerEntity } from './entities/termine.js';
import { Registry } from './registry.js';

/** Alle synchronisierten Entitäten. Neue Fachbereiche (Aufgaben, Dateien, ...) tragen sich hier ein. */
export const defaultRegistry = new Registry([
  listEntity,
  listItemEntity,
  terminEntity,
  terminTeilnehmerEntity,
  terminAusnahmeEntity,
  konversationEntity,
  nachrichtEntity,
  lesestandEntity,
  epocheEntity,
  epocheWrapEntity,
]);
