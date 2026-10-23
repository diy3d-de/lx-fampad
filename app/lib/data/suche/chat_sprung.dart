// Sprung zu einer Nachricht (aus der Suche über alle Chats): der Chat-Bereich öffnet den Chat und der Verlauf scrollt zur Nachricht und hebt sie hervor.
// Nur eine Kennung im Arbeitsspeicher, nie Inhalt.
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef ChatSprungZiel = ({String chatId, String nachrichtId});

class ChatSprung extends Notifier<ChatSprungZiel?> {
  @override
  ChatSprungZiel? build() => null;

  void zu(String chatId, String nachrichtId) => state = (chatId: chatId, nachrichtId: nachrichtId);

  /// Der Verlauf hat das Ziel übernommen.
  void verbraucht() => state = null;
}

final chatSprungProvider = NotifierProvider<ChatSprung, ChatSprungZiel?>(ChatSprung.new);
