// Bildschirm wach halten (Wandtablet-Modus). Schnittstelle mit Plattform-Umsetzungen: Android über den System-Kanal (FLAG_KEEP_SCREEN_ON),
// Web über die Wake Lock API (bedingter Import wie bei features/update/apk_downloader*.dart), sonst ohne Wirkung. Tests setzen einen Fake.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart' show systemChannelProvider;
import 'bildschirm_wach_io.dart' if (dart.library.js_interop) 'bildschirm_wach_web.dart' as plattform;

abstract class BildschirmWach {
  /// Bildschirm anlassen. Nie ein Fehler: geht es nicht, bleibt alles wie es ist.
  Future<void> halten();

  /// Wieder freigeben (der Bildschirm darf ausgehen).
  Future<void> freigeben();
}

final bildschirmWachProvider = Provider<BildschirmWach>((ref) => plattform.erzeugeBildschirmWach(ref.read(systemChannelProvider)));
