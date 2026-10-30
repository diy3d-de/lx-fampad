// Familienmitglieder für die Anzeige von Zuständigkeiten (Name und Farbe). Kommt von GET /members; die letzte Antwort liegt in
// der lokalen Datenbank (nur ID, Name, Farbe, Rolle: keine E-Mail-Adressen), damit die Anzeige auch offline funktioniert.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../auth/auth_state.dart';
import '../app_database.dart' show AppDatabase;
import '../avatar/avatar_foto.dart';
import '../database_provider.dart';
import '../sync_state.dart' show mitgliederHinweisProvider, syncProvider;

const _kMitglieder = 'members';

/// Aktive Mitglieder der Familie (leer, solange weder Server noch Zwischenspeicher etwas liefern).
final mitgliederProvider = FutureProvider.autoDispose<List<UserDto>>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final api = ref.watch(apiProvider);
  try {
    final alle = [
      for (final u in await api.mitglieder())
        if (u.status == MemberStatus.active) u,
    ];
    try {
      await db.metaSchreiben(_kMitglieder, jsonEncode([for (final u in alle) {'id': u.id, 'displayName': u.displayName, 'colorIndex': u.colorIndex, 'role': u.role.wire, 'status': 'active', if (u.avatar != null) 'avatar': u.avatar!.toJson()}]));
    } catch (_) {
      // Zwischenspeicher ist nur ein Komfort
    }
    try {
      // Fotos von Personen, die nicht mehr in der Familie sind, vom Gerät entfernen
      await avatarCacheBereinigen(db, [for (final u in alle) u.id]);
    } catch (_) {
      // nur ein Komfort
    }
    return alle;
  } on ApiException {
    return mitgliederAusSpeicher(await db.metaLesen(_kMitglieder));
  }
});

/// Liest die zwischengespeicherte Mitgliederliste (unlesbare Einträge werden übersprungen).
List<UserDto> mitgliederAusSpeicher(String? json) {
  if (json == null) return const [];
  try {
    final daten = jsonDecode(json);
    if (daten is! List) return const [];
    return parseListe(daten, UserDto.fromJson);
  } catch (_) {
    return const [];
  }
}

/// Ist die Person [id] laut zwischengespeicherter Mitgliederliste noch ein aktives Mitglied? Ohne ID, oder solange es keine Liste gibt (nie geladen), gilt sie
/// als aktiv (kein Grund, etwas abzulehnen, was sich nicht prüfen lässt).
Future<bool> mitgliedNochAktiv(AppDatabase db, String? id) async {
  if (id == null) return true;
  try {
    final alle = mitgliederAusSpeicher(await db.metaLesen(_kMitglieder));
    return alle.isEmpty || alle.any((u) => u.id == id);
  } catch (_) {
    return true;
  }
}

/// Zugriff per ID mit Rückfall für unbekannte Personen (entfernt, noch nicht geladen).
class Mitglieder {
  final Map<String, UserDto> _nachId;
  Mitglieder(List<UserDto> liste) : _nachId = {for (final u in liste) u.id: u};

  UserDto? operator [](String? id) => id == null ? null : _nachId[id];
  List<UserDto> get alle => _nachId.values.toList();
}

/// Uhr für die Drosselung (in Tests überschreibbar).
final mitgliederUhrProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Mindestabstand zwischen zwei Neuladungen der Mitgliederliste.
const kMitgliederMinAbstand = Duration(seconds: 60);

/// Mindestabstand bei einem Hinweis des Servers ("Mitglieder geändert"): kürzer, weil der Hinweis selten ist; ein zu früher Hinweis wird nachgeholt.
const kMitgliederHinweisAbstand = Duration(seconds: 5);

/// Lädt die Mitgliederliste neu, wenn ein Abgleich gelungen ist oder die App wieder in den Vordergrund kommt (höchstens alle 60 s), damit
/// neue Mitglieder ohne Neustart erscheinen. Schlägt das Laden fehl, bleibt der Zwischenstand (siehe [mitgliederProvider]).
/// Wird vom Wurzel-Widget beobachtet (lib/app.dart).
final mitgliederAktualisierungProvider = Provider<void>((ref) {
  DateTime? zuletzt;
  void neuLaden({bool erzwingen = false}) {
    final jetzt = ref.read(mitgliederUhrProvider)();
    if (!erzwingen && zuletzt != null && jetzt.difference(zuletzt!) < kMitgliederMinAbstand) return;
    zuletzt = jetzt;
    // Fotos, die wegen eines Verbindungsfehlers beim älteren Stand geblieben sind, werden erneut versucht; Fotos im Speicher bleiben (die Version steht in /members)
    final speicher = ref.read(avatarSpeicherProvider);
    if (speicher.fehlversuche.isNotEmpty) {
      speicher.fehlversuche.clear();
      ref.invalidate(avatarFotoProvider);
    }
    ref.invalidate(mitgliederProvider);
  }

  Timer? nachholen;
  ref.onDispose(() => nachholen?.cancel());
  ref.listen(mitgliederHinweisProvider, (alt, neu) {
    if (neu == alt || !ref.read(authProvider).angemeldet) return;
    final jetzt = ref.read(mitgliederUhrProvider)();
    final seit = zuletzt == null ? null : jetzt.difference(zuletzt!);
    if (seit == null || seit >= kMitgliederHinweisAbstand) {
      nachholen?.cancel();
      neuLaden(erzwingen: true);
    } else {
      // zu früh nach der letzten Ladung: einmal später nachholen (mehrere Hinweise ergeben eine Ladung)
      nachholen?.cancel();
      nachholen = Timer(kMitgliederHinweisAbstand - seit, () {
        if (ref.read(authProvider).angemeldet) neuLaden(erzwingen: true);
      });
    }
  });
  ref.listen(syncProvider.select((s) => s.letzterAbgleich), (alt, neu) {
    if (neu != null && neu != alt && ref.read(authProvider).angemeldet) neuLaden();
  });
  final lebenszyklus = AppLifecycleListener(onResume: () {
    if (ref.read(authProvider).angemeldet) neuLaden();
  });
  ref.onDispose(lebenszyklus.dispose);
});
