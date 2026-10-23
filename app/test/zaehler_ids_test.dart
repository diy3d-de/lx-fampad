// Feste ID der Zähler-Konversation (Abschnitt 6l): je Familie genau eine, abgeleitet; muss exakt dem Server entsprechen (server/test/sync-zaehler.test.ts, Known-Answer).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';

void main() {
  const familie = '11111111-1111-4111-8111-111111111111';

  test('leitet die ID aus der Familie ab (Known-Answer wie auf dem Server)', () {
    expect(zaehlerChatId(familie), uuidAusSchluessel('zaehler:$familie'));
    expect(zaehlerChatId(familie.toUpperCase()), zaehlerChatId(familie));
    expect(zaehlerChatId(familie), 'ed088537-4d78-5bb2-9826-6bb598e1f202');
    expect(zaehlerChatId('22222222-2222-4222-8222-222222222222'), isNot(zaehlerChatId(familie)));
  });

  test('unterscheidet sich von allen anderen festen IDs derselben Eingabe', () {
    expect(zaehlerChatId(familie), isNot(medsChatId(familie)));
    expect(zaehlerChatId(familie), isNot(familienchatId(familie)));
  });
}
