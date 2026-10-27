// Verdrahtung der Erinnerungen in der Web-App: der Minutentakt prüft, ob eine geplante Erinnerung fällig geworden ist (nur solange die Web-App offen ist).
// Wie erinnerung_steuerung.dart am Wurzel-Widget (app.dart) beobachtet; auf Android tut er nichts (der Port ist dort nicht der Web-Port).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/auth_state.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart';
import '../../data/erinnerungen/web_erinnerung_port.dart';
import '../../data/erinnerungen/web_erinnerung_state.dart';
import 'calendar_anzeige.dart' show minutenTaktProvider;

final webErinnerungSteuerungProvider = Provider<void>((ref) {
  final port = ref.watch(erinnerungPortProvider);
  if (port is! WebErinnerungPort) return;
  void pruefen() => unawaited(webErinnerungPruefen(ref));
  port.beiGeplant = pruefen;
  ref.onDispose(() => port.beiGeplant = null);
  ref.listen(minutenTaktProvider, (_, _) => pruefen());
  ref.listen(webErinnerungAnProvider, (_, _) => pruefen());
  ref.listen(authProvider.select((a) => a.angemeldet), (_, _) => pruefen());
  final lebenszyklus = AppLifecycleListener(onResume: pruefen);
  ref.onDispose(lebenszyklus.dispose);
  Future.microtask(pruefen);
});
