import { aufgabeEntity, aufgabePunktEntity } from './entities/aufgaben.js';
import { epocheEntity, epocheWrapEntity } from './entities/chat-epochen.js';
import { konversationEntity, lesestandEntity, nachrichtEntity } from './entities/chat.js';
import { pinEntity, reaktionEntity, stimmeEntity } from './entities/chat-zusatz.js';
import { einnahmeEntity, medikamentEntity } from './entities/medikamente.js';
import { vorsorgeEintragEntity, vorsorgeProfilEntity } from './entities/vorsorge.js';
import { dateiEntity, dateiVersionEntity, ordnerEntity } from './entities/dateien.js';
import { tresorAnhangEntity } from './entities/tresor-anhang.js';
import { tresorEintragEntity } from './entities/tresor.js';
import { statusEntity } from './entities/status.js';
import { zaehlerEntity, zaehlerstandEntity } from './entities/zaehler.js';
import { listEntity, listItemEntity } from './entities/lists.js';
import { terminAusnahmeEntity, terminEntity, terminTeilnehmerEntity } from './entities/termine.js';
import { Registry } from './registry.js';

/** Alle synchronisierten Entitäten. Neue Fachbereiche (Dateien, ...) tragen sich hier ein. */
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
  aufgabeEntity,
  aufgabePunktEntity,
  reaktionEntity,
  stimmeEntity,
  pinEntity,
  medikamentEntity,
  einnahmeEntity,
  vorsorgeProfilEntity,
  vorsorgeEintragEntity,
  zaehlerEntity,
  zaehlerstandEntity,
  tresorEintragEntity,
  tresorAnhangEntity,
  ordnerEntity,
  dateiEntity,
  dateiVersionEntity,
  statusEntity,
]);
