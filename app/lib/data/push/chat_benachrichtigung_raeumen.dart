// Räumt Chat-Benachrichtigungen weg, sobald der Chat gelesen ist (Ungelesen-Zähler der Konversation steht auf 0). So verschwinden auch Punkt und Zahl am App-Symbol:
// Android leitet sie aus den aktiven Benachrichtigungen ab. Beim ersten Stand der Liste (App-Start) werden alle gelesenen Chats geräumt, falls auf einem anderen Gerät oder
// vor dem Beenden gelesen wurde.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_repository.dart';
import 'chat_benachrichtiger.dart';
import 'chat_benachrichtiger_provider.dart';

final chatBenachrichtigungenRaeumenProvider = Provider<void>((ref) {
  final port = ref.watch(chatAnzeigePortProvider);
  Map<String, int>? vorher;
  void pruefen(List<ChatEintrag> liste) {
    for (final e in liste) {
      final v = vorher?[e.id];
      if (e.ungelesen == 0 && (v == null || v > 0)) unawaited(port.entfernen(chatBenachrichtigungsId(e.id)));
    }
    vorher = {for (final e in liste) e.id: e.ungelesen};
  }

  ref.listen(chatUebersichtProvider, (_, neu) {
    final liste = neu.value;
    if (liste != null) pruefen(liste);
  }, fireImmediately: true);
});
