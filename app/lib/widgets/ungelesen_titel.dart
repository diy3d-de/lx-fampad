// Hält den Titel des Browser-Tabs mit der Zahl der ungelesenen Chat-Nachrichten aktuell (nur Web wirksam; auf Android gelten Benachrichtigungen, siehe
// data/push/chat_benachrichtigung_raeumen.dart). Wird vom Wurzel-Widget beobachtet (lib/app.dart).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat/chat_repository.dart';
import 'tab_titel_stub.dart' if (dart.library.js_interop) 'tab_titel_web.dart';

final ungelesenTitelProvider = Provider<void>((ref) {
  ref.listen(chatUngelesenProvider, (_, neu) => tabTitelSetzen(neu.value ?? 0), fireImmediately: true);
});
