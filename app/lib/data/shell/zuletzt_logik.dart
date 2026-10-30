// Auffindbarkeit der Bereiche (nur lokal je Gerät, `sync_meta`): "Zuletzt benutzt" im Blatt "Mehr", einklappbare Gruppen der Seitenleiste und die
// Suche über die Bereichsnamen. REINE Logik ohne Oberfläche und ohne Speicher. Gesucht wird nur in den Namen der Bereiche, nie in Inhalten.
import 'dart:convert';

import '../suche/such_logik.dart' show finde, suchWoerter;

/// Schlüssel in `sync_meta`: zuletzt geöffnete Bereiche (JSON-Liste von Kennungen, neueste zuerst).
const kZuletztSchluessel = 'mehr_zuletzt';

/// Schlüssel in `sync_meta`: eingeklappte Gruppen der Seitenleiste (JSON-Liste von Gruppen-Namen).
const kGruppenZuSchluessel = 'seitenleiste_zu';

/// Wie viele zuletzt benutzte Bereiche gemerkt und wie viele gezeigt werden.
const kZuletztMax = 6;
const kZuletztAnzeige = 3;

/// [id] nach vorn, ohne Doppelte, höchstens [kZuletztMax].
List<String> zuletztMerken(List<String> alt, String id) => [id, for (final x in alt) if (x != id) x].take(kZuletztMax).toList();

List<String> _liste(String? text) {
  if (text == null || text.isEmpty) return const [];
  try {
    final j = jsonDecode(text);
    if (j is! List) return const [];
    return [for (final e in j) if (e is String && e.isNotEmpty) e];
  } catch (_) {
    return const [];
  }
}

/// Gemerkte Liste lesen; fehlender oder defekter Wert ergibt eine leere Liste, doppelte Kennungen fallen weg.
List<String> zuletztAusText(String? text) => _liste(text).toSet().take(kZuletztMax).toList();

String zuletztAlsText(Iterable<String> ids) => jsonEncode(ids.toList());

/// Eingeklappte Gruppen aus dem gespeicherten Text (unbekannte Namen werden vom Aufrufer ignoriert).
Set<String> gruppenZuAusText(String? text) => _liste(text).toSet();

String gruppenZuAlsText(Iterable<String> gruppen) => jsonEncode(gruppen.toList()..sort());

/// Die zuletzt benutzten Kennungen, die es gerade gibt ([vorhanden], z. B. nicht verfügbare Bereiche fallen weg), höchstens [kZuletztAnzeige].
List<String> zuletztSichtbar(List<String> gemerkt, Set<String> vorhanden) => [for (final id in gemerkt) if (vorhanden.contains(id)) id].take(kZuletztAnzeige).toList();

/// Passt der Name eines Bereichs zur Eingabe? Jedes Wort muss als Teil des Namens vorkommen (Umlaute auch als a/o/u/ae/oe/ue); leere Eingabe: alle.
bool bereichPasst(String name, String eingabe) {
  final woerter = suchWoerter(eingabe);
  if (woerter.isEmpty) return true;
  return finde(name, woerter) != null;
}
