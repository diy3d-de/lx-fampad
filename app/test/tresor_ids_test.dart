// Feste ID der Tresor-Konversation (Abschnitt 6m): je Familie genau eine, abgeleitet; muss exakt dem Server entsprechen (server/test/sync-tresor.test.ts, Known-Answer).
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_fampad/data/chat/chat_ids.dart';

void main() {
  const familie = '11111111-1111-4111-8111-111111111111';

  test('leitet die ID aus der Familie ab (Known-Answer wie auf dem Server)', () {
    expect(tresorChatId(familie), uuidAusSchluessel('tresor:$familie'));
    expect(tresorChatId(familie.toUpperCase()), tresorChatId(familie));
    expect(tresorChatId(familie), 'af79b489-d893-5427-9eae-468c85917458');
    expect(tresorChatId('22222222-2222-4222-8222-222222222222'), isNot(tresorChatId(familie)));
  });

  test('unterscheidet sich von allen anderen festen IDs derselben Eingabe', () {
    expect(tresorChatId(familie), isNot(zaehlerChatId(familie)));
    expect(tresorChatId(familie), isNot(medsChatId(familie)));
    expect(tresorChatId(familie), isNot(familienchatId(familie)));
  });
}
