// Familienmitglieder für die Anzeige von Zuständigkeiten (Name und Farbe). Kommt von GET /members; die letzte Antwort liegt in
// der lokalen Datenbank (nur ID, Name, Farbe, Rolle: keine E-Mail-Adressen), damit die Anzeige auch offline funktioniert.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';

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

/// Zugriff per ID mit Rückfall für unbekannte Personen (entfernt, noch nicht geladen).
class Mitglieder {
  final Map<String, UserDto> _nachId;
  Mitglieder(List<UserDto> liste) : _nachId = {for (final u in liste) u.id: u};

  UserDto? operator [](String? id) => id == null ? null : _nachId[id];
  List<UserDto> get alle => _nachId.values.toList();
}
