// Hintergrund-Start durch einen Push-Wecker. Das Android-Plugin (unifiedpush_android) startet bei einer Nachricht, wenn gerade keine
// Flutter-Engine mit dem Plugin läuft, eine Engine OHNE Oberfläche und ruft main() mit dem Argument "--unifiedpush-bg" auf.
// Dann wird nur abgeglichen (und neue Ereignisse an [EreignisBenachrichtiger] gemeldet), nie runApp aufgerufen.
//
// Grenzen (bewusst): Der Abgleich läuft nur, solange Android den Prozess lässt (wenige Sekunden nach dem Wecker). Scheitert er
// (Prozess beendet, Netz weg), holt die App es beim nächsten Öffnen nach: der Sync läuft ohnehin bei jedem Start. Mit geöffneter
// App bekommt die laufende Engine den Wecker (PushController), nicht diese Funktion.
//
// Jeder Wecker nutzt einen eigenen, kurzlebigen ProviderContainer, der danach samt Datenbankverbindung geschlossen wird: So hält
// diese Engine die lokale Datenbank nicht offen, wenn die Person die App später öffnet (zwei Engines, eine SQLite-Datei).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../sync_state.dart';
import 'push_plattform.dart';
import 'push_plattform_fabrik.dart';
import 'push_wecker.dart';

/// Argument, mit dem das Plugin den Hintergrund-Start kennzeichnet.
const kPushHintergrundArgument = '--unifiedpush-bg';

/// Wie lange ein Hintergrund-Abgleich höchstens dauern darf.
const _hoechstdauer = Duration(seconds: 25);

/// Mit austauschbarer Plattform und Container-Fabrik für Tests.
Future<void> pushHintergrundStarten({
  PushPlattform? plattform,
  ProviderContainer Function()? containerFabrik,
  EreignisBenachrichtiger? ereignisse,
}) async {
  final p = plattform ?? neuePushPlattform();
  if (!p.unterstuetzt) return;
  ProviderContainer neu() => containerFabrik != null ? containerFabrik() : ProviderContainer();

  Future<void> abgleichen() async {
    final c = neu();
    try {
      final engine = c.read(syncEngineProvider);
      await weckerAbgleichen(
        store: c.read(syncStoreProvider),
        abgleich: () async {
          await engine.abgleichen().timeout(_hoechstdauer);
        },
        ereignisse: ereignisse ?? c.read(ereignisBenachrichtigerProvider),
      );
    } catch (_) {
      // Zeitüberschreitung oder Fehler: der nächste Start der App gleicht ab
    } finally {
      c.dispose();
    }
  }

  // Ein Verteiler kann den Endpunkt auch ändern, während die App geschlossen ist: dann dem Server den neuen melden.
  Future<void> endpunkt(String url) async {
    final c = neu();
    try {
      await c.read(apiProvider).pushAnmelden(url);
    } on ApiException {
      // abgelehnt oder offline: beim nächsten Öffnen der App meldet sie sich selbst neu an
    } catch (_) {
    } finally {
      c.dispose();
    }
  }

  await p.initialisieren(
    PushRueckrufe(
      beiEndpunkt: (url) => unawaited(endpunkt(url)),
      beiFehler: (_) {},
      beiAbgemeldet: () {},
      beiWecker: () => unawaited(abgleichen()),
    ),
  );
}

