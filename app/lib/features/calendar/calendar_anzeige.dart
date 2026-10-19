// Anstehende Termine für die Startseite (mobil "Als Nächstes", Desktop "Heute & morgen"): Auswahl aus der lokalen Datenbank, Zeilen und
// ein Minutentakt, damit vorbeigegangene Termine verschwinden, auch wenn die Seite offen bleibt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/calendar/expansion.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/calendar/zeitzonen.dart';
import '../../data/lists/members.dart';
import 'calendar_state.dart';

/// Aktuelle Uhrzeit, einmal je Minute erneuert (nur solange etwas zuhört).
final minutenTaktProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(const Duration(minutes: 1), (_) => DateTime.now());
});

/// Termine ab [jetzt], die in den nächsten [tage] Tagen (ab heute 0 Uhr) liegen; laufende zuerst. Vorbei ist ein Zeittermin, dessen Ende vor
/// [jetzt] liegt; ganztägige Termine bleiben den ganzen Tag.
List<Vorkommen> anstehende(KalenderDaten daten, DateTime jetzt, {int tage = 60}) {
  final heute = heuteTag(jetzt);
  final jetztWand = wandUhr(jetzt.toUtc(), familienOrt);
  final alle = vorkommenImFenster(
    termine: daten.termine,
    ausnahmen: daten.ausnahmen,
    vonWand: heute,
    bisWand: heute.add(Duration(days: tage)),
    jetzt: jetzt.toUtc(),
  );
  return [
    for (final v in alle)
      if (v.endeWand.isAfter(jetztWand) || (v.endeWand == v.startWand && !v.startWand.isBefore(jetztWand))) v,
  ];
}

/// Mitglieder für Farben, aber erst laden, wenn es Termine gibt (kein zusätzlicher Abruf auf leeren Startseiten).
Mitglieder mitgliederFuer(WidgetRef ref, KalenderDaten daten) => Mitglieder(daten.termine.isEmpty ? const [] : (ref.watch(mitgliederProvider).value ?? const []));

/// Eine Zeile "Farbbalken, Titel, Tag und Zeit".
class AnstehenderTermin extends StatelessWidget {
  final Vorkommen v;
  final Mitglieder mitglieder;
  final DateTime heute;
  const AnstehenderTermin({super.key, required this.v, required this.mitglieder, required this.heute});

  @override
  Widget build(BuildContext context) {
    final tag = v.ersterTag.isBefore(heute) ? heute : v.ersterTag;
    final morgen = heute.add(const Duration(days: 1));
    final tagText = tag == heute ? 'heute' : (tag == morgen ? 'morgen' : DateFormat('E, d. MMM', 'de_DE').format(tag).toLowerCase());
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 4, height: 34, margin: const EdgeInsets.only(right: 10), decoration: BoxDecoration(color: terminFarbe(v, mitglieder), borderRadius: BorderRadius.circular(2))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.titel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '$tagText · ${zeitText(v, tag)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
