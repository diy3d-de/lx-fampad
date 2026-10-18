import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_indicator.dart';

/// Chat: Kopf, leerer Verlauf und Eingabezeile. Phase 0: Eingabe gesperrt.
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: ScreenHeader(title: 'Chat', actions: [StatusPill('● offline', color: kTextMuted), SyncIndicator()]),
          ),
          const Expanded(
            child: EmptyState(
              icon: Icons.chat_bubble_outline,
              title: 'Noch keine Nachrichten',
              hint: 'Der Familien-Chat startet in Phase 1.',
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    enabled: false,
                    decoration: InputDecoration(hintText: 'Nachricht', contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
                  ),
                ),
                SizedBox(width: 8),
                IconButton.filled(onPressed: null, tooltip: 'Senden', icon: Icon(Icons.send)),
              ],
            ),
          ),
        ],
      );
}
