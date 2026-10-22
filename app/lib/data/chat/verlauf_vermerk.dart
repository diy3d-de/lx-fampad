// Lokaler Vermerk, welchen Verlauf dieses Gerät schon für eine Person (und deren Schlüsselversion) freigegeben hat ("Verlauf freigeben", Wrap-ID v2): je Person und Version
// eine Liste "Konversation:Epoche" in `sync_meta`. Der Server erfährt nichts davon. Eigene Datei, damit sowohl der Schlüsselbund als auch die Abgleich-Entität (abgelehnter
// Wrap "gibt es schon") darauf zugreifen können, ohne einander zu importieren.
import 'dart:convert';

import '../app_database.dart';

String _schluessel(String userId, int keyVersion) => 'verlaufFreigabe.${userId.toLowerCase()}.$keyVersion';

/// Was für diese Person und Version schon freigegeben und vom Server bestätigt ist ("Konversation:Epoche").
Future<Set<String>> freigabeVermerke(AppDatabase db, String userId, int keyVersion) async {
  final raw = await db.metaLesen(_schluessel(userId, keyVersion));
  if (raw == null) return {};
  try {
    final d = jsonDecode(raw);
    return d is List ? {for (final x in d) if (x is String) x} : {};
  } on FormatException {
    return {};
  }
}

/// Vermerkt weitere "Konversation:Epoche" als freigegeben (nichts Neues: keine Schreibung).
Future<void> freigabeVermerken(AppDatabase db, String userId, int keyVersion, Iterable<String> neu) async {
  final alt = await freigabeVermerke(db, userId, keyVersion);
  final alle = {...alt, ...neu};
  if (alle.length == alt.length) return;
  await db.metaSchreiben(_schluessel(userId, keyVersion), jsonEncode(alle.toList()..sort()));
}
