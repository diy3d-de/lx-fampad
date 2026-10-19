// Fotos der Benutzerbilder: laden, zwischenspeichern, offline weiter anzeigen.
// Reihenfolge: Arbeitsspeicher, lokale Datenbank (sync_meta, Schlüssel "avatar:<id>", Wert "Version:base64"), dann der Server.
// Ändert eine Person ihr Bild, ändert sich die Version in /members und damit der Schlüssel: das neue Foto wird geladen.
// - Nur bei Verbindungs- und Serverfehlern bleibt ein älteres Foto aus der Datenbank sichtbar; sagt der Server 404/403 (Bild entfernt,
//   Person nicht mehr in der Familie), wird die lokale Kopie gelöscht und es gelten die Initialen.
// - Nach einem Verbindungsfehler wird 60 Sekunden lang nicht erneut abgerufen (kein Abruf-Sturm bei jedem Neuzeichnen).
// - Nach Abmelden oder Personenwechsel wird nichts mehr in die Datenbank geschrieben (laufende Abrufe verwerfen ihr Ergebnis).
// - Kopien von Personen, die nicht mehr in der Mitgliederliste stehen, räumt [avatarCacheBereinigen] auf.
// Die Datenbank wird beim Abmelden und beim Wechsel der Person geleert (damit auch diese Fotos); bei Sitzungsverlust bleibt sie bis dahin.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';

typedef AvatarFotoSchluessel = ({String userId, int version});

/// Arbeitsspeicher-Zwischenspeicher; beim Wechsel der angemeldeten Person wird er neu angelegt.
class AvatarSpeicher {
  final Map<String, Uint8List> bytes = {};

  /// Zeitpunkt des letzten Verbindungsfehlers je Schlüssel (negativer Zwischenspeicher).
  final Map<String, DateTime> fehlversuche = {};
}

const kAvatarFehlerPause = Duration(seconds: 60);

final avatarSpeicherProvider = Provider<AvatarSpeicher>((ref) {
  ref.watch(authProvider.select((s) => s.user?.id));
  return AvatarSpeicher();
});

const _praefix = 'avatar:';
String _schluessel(String userId) => '$_praefix$userId';

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

/// Löscht gespeicherte Fotos von Personen, die nicht in [aktuelleIds] stehen.
Future<void> avatarCacheBereinigen(AppDatabase db, Iterable<String> aktuelleIds) async {
  final behalte = {for (final id in aktuelleIds) _schluessel(id)};
  for (final k in await db.metaSchluesselMit(_praefix)) {
    if (!behalte.contains(k)) await db.metaLoeschen(k);
  }
}

/// Foto der Person in der gegebenen Version; null = keines verfügbar (Initialen).
final avatarFotoProvider = FutureProvider.autoDispose.family<Uint8List?, AvatarFotoSchluessel>((ref, k) async {
  final speicher = ref.watch(avatarSpeicherProvider);
  final key = '${k.userId}:${k.version}';
  final imSpeicher = speicher.bytes[key];
  if (imSpeicher != null) return imSpeicher;
  final eigenerUser = ref.read(authProvider).user?.id;
  // Ist noch dieselbe Person angemeldet? Sonst nichts mehr speichern (Abmelden/Wipe während des Abrufs).
  bool nochAngemeldet() {
    return ref.read(authProvider).user?.id == eigenerUser;
  }

  final db = ref.read(appDatabaseProvider);
  ({int version, Uint8List bytes})? lokal;
  try {
    lokal = _lesen(await db.metaLesen(_schluessel(k.userId)));
  } catch (_) {
    lokal = null; // Datenbank nicht lesbar: nur der Server bleibt
  }
  if (lokal != null && lokal.version == k.version) {
    speicher.bytes[key] = lokal.bytes;
    return lokal.bytes;
  }
  final letzter = speicher.fehlversuche[key];
  if (letzter != null && DateTime.now().difference(letzter) < kAvatarFehlerPause) return lokal?.bytes;
  try {
    final bytes = await ref.read(apiProvider).avatarFoto(k.userId);
    speicher.fehlversuche.remove(key);
    if (!nochAngemeldet()) return null;
    speicher.bytes[key] = bytes;
    try {
      await db.metaSchreiben(_schluessel(k.userId), '${k.version}:${base64Encode(bytes)}');
    } catch (_) {
      // Zwischenspeicher ist nur ein Komfort
    }
    return bytes;
  } on ApiException catch (e) {
    if (e.status == 404 || e.status == 403) {
      // Bild gibt es nicht (mehr): lokale Kopie verwerfen
      if (nochAngemeldet()) {
        try {
          await db.metaLoeschen(_schluessel(k.userId));
        } catch (_) {
          // nur ein Komfort
        }
      }
      return null;
    }
    speicher.fehlversuche[key] = DateTime.now();
    return lokal?.bytes; // offline oder Serverfehler: das ältere Foto ist besser als keines
  }
});
