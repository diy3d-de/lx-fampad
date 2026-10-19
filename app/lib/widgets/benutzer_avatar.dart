// Avatar einer Person der Familie: zeigt ihr Benutzerbild (Platzhalter-Zeichnung oder Foto) auf der Personenfarbe, sonst die Initialen.
// Überall verwenden, wo eine Person (UserDto) gezeigt wird; PersonAvatar (ui/widgets.dart) ist nur das Zeichnen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/models.dart';
import '../data/avatar/avatar_foto.dart';
import '../data/avatar/avatar_vorlagen.dart';
import '../ui/widgets.dart';

class BenutzerAvatar extends ConsumerWidget {
  /// Die Person; null (unbekannt, entfernt) zeigt "?" bzw. [ersatzName].
  final UserDto? user;
  final String ersatzName;
  final double size;
  const BenutzerAvatar({super.key, required this.user, this.ersatzName = '?', this.size = 40});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = user;
    final name = u?.displayName ?? ersatzName;
    final farbe = u?.colorIndex ?? 0;
    final a = u?.avatar;
    if (u == null || a == null) return PersonAvatar(name: name, colorIndex: farbe, size: size);
    if (!a.istFoto) {
      final v = avatarVorlage(a.vorlage);
      // unbekannte Kennung (neuere Server-Version): Initialen
      return PersonAvatar(name: name, colorIndex: farbe, size: size, bild: v == null ? null : AssetImage(v.asset), bildAufFarbe: true);
    }
    final foto = ref.watch(avatarFotoProvider((userId: u.id, version: a.version))).value;
    return PersonAvatar(name: name, colorIndex: farbe, size: size, bild: foto == null ? null : ResizeImage.resizeIfNeeded((size * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1)).ceil(), null, MemoryImage(foto)));
  }
}
