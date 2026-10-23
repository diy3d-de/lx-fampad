// Countdown-Kacheln der Startseite: reine Logik ohne Oberfläche und ohne Speicher.
//  - Gemerkt werden nur die Termin-IDs (lokal je Gerät in `sync_meta`, nie synchronisiert, kein Server, kein Schema).
//  - Je gemerktem Termin zählt das nächste Vorkommen (bei Serien über die vorhandene Expansion), Vergangenes fällt heraus.
import 'dart:convert';

import '../calendar/expansion.dart';
import '../calendar/geburtstag.dart';

/// Schlüssel in `sync_meta`.
const kCountdownSchluessel = 'countdown_termine';

/// Höchstens so viele Countdowns auf der Startseite.
const kCountdownMax = 3;

/// Gemerkte Termin-IDs aus dem gespeicherten Text (JSON-Liste); jeder Fehler ergibt die leere Menge.
Set<String> countdownIdsAusText(String? text) {
  if (text == null || text.isEmpty) return <String>{};
  try {
    final j = jsonDecode(text);
    if (j is! List) return <String>{};
    return {for (final e in j) if (e is String && e.isNotEmpty && e.length <= 64) e};
  } catch (_) {
    return <String>{};
  }
}

String countdownIdsAlsText(Set<String> ids) => jsonEncode(ids.toList()..sort());

class CountdownEintrag {
  final String terminId;
  final String titel;

  /// Kalendertage bis zum Beginn (0 = heute).
  final int tage;
  const CountdownEintrag({required this.terminId, required this.titel, required this.tage});

  /// "heute", "morgen" oder "in N Tagen".
  String get text => countdownText(tage);
}

String countdownText(int tage) => tage <= 0 ? 'heute' : (tage == 1 ? 'morgen' : 'in $tage Tagen');

/// Die Countdowns aus den anstehenden [vorkommen] (Wanduhr der Familienzone), [heute] = Tag (UTC-Datum der Wanduhr, wie `heuteTag`).
/// Je Termin das nächste Vorkommen, das nicht vor heute begonnen hat; nächster zuerst, höchstens [max].
List<CountdownEintrag> countdownEintraege({required Iterable<Vorkommen> vorkommen, required Set<String> ids, required DateTime heute, int max = kCountdownMax}) {
  if (ids.isEmpty) return const [];
  final sortiert = [for (final v in vorkommen) if (ids.contains(v.termin.id)) v]..sort((a, b) => a.startWand.compareTo(b.startWand));
  final gesehen = <String>{};
  final liste = <CountdownEintrag>[];
  for (final v in sortiert) {
    if (v.ersterTag.isBefore(heute)) continue; // läuft schon (mehrtägig): kein Countdown mehr
    if (!gesehen.add(v.termin.id)) continue;
    liste.add(CountdownEintrag(terminId: v.termin.id, titel: vorkommenTitel(v), tage: v.ersterTag.difference(heute).inDays));
    if (liste.length >= max) break;
  }
  return liste;
}
