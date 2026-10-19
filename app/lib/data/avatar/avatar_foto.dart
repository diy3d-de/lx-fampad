// Fotos der Benutzerbilder: laden, zwischenspeichern, offline weiter anzeigen.
// Reihenfolge: Arbeitsspeicher, lokale Datenbank (sync_meta, Schlüssel "avatar:<id>", Wert "Version:base64"), dann der Server.
// Ändert eine Person ihr Bild, ändert sich die Version in /members und damit der Schlüssel: das neue Foto wird geladen. Ist der Server
// nicht erreichbar, bleibt ein älteres Foto aus der Datenbank sichtbar; gibt es keines, gelten die Initialen. Die Datenbank wird beim
// Abmelden und beim Wechsel der Person geleert (damit auch diese Fotos).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';

typedef AvatarFotoSchluessel = ({String userId, int version});

/// Arbeitsspeicher-Zwischenspeicher; beim Wechsel der angemeldeten Person wird er neu angelegt.
final avatarSpeicherProvider = Provider<Map<String, Uint8List>>((ref) {
  ref.watch(authProvider.select((s) => s.user?.id));
  return {};
});

String _schluessel(String userId) => 'avatar:$userId';

/// Wert `Version:base64` -> (Version, Bytes); null bei Unbrauchbarem.
({int version, Uint8List bytes})? _lesen(String? wert) {
  if (wert == null) return null;
  final i = wert.indexOf(':');
  if (i < 1) return null;
  final version = int.tryParse(wert.substring(0, i));
  if (version == null) return null;
  try {
    return (version: version, bytes: base64Decode(wert.substring(i + 1)));
  } on FormatException {
    return null;
  }
}

/// Foto der Person in der gegebenen Version; null = keines verfügbar (Initialen).
final avatarFotoProvider = FutureProvider.autoDispose.family<Uint8List?, AvatarFotoSchluessel>((ref, k) async {
  final speicher = ref.watch(avatarSpeicherProvider);
  final key = '${k.userId}:${k.version}';
  final imSpeicher = speicher[key];
  if (imSpeicher != null) return imSpeicher;
  final db = ref.read(appDatabaseProvider);
  ({int version, Uint8List bytes})? lokal;
  try {
    lokal = _lesen(await db.metaLesen(_schluessel(k.userId)));
  } catch (_) {
    lokal = null; // Datenbank nicht lesbar: nur der Server bleibt
  }
  if (lokal != null && lokal.version == k.version) {
    speicher[key] = lokal.bytes;
    return lokal.bytes;
  }
  try {
    final bytes = await ref.read(apiProvider).avatarFoto(k.userId);
    speicher[key] = bytes;
    try {
      await db.metaSchreiben(_schluessel(k.userId), '${k.version}:${base64Encode(bytes)}');
    } catch (_) {
      // Zwischenspeicher ist nur ein Komfort
    }
    return bytes;
  } on ApiException {
    return lokal?.bytes; // offline oder Fehler: das ältere Foto ist besser als keines
  }
});
