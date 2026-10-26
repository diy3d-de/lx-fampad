// Gemeinsame Anzeige-Bausteine der Aufgaben: Fälligkeitstext, Prioritätsfarbe, Auswahl für die Startseiten und die kurze Zeile.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show WidgetRef;
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/api/models.dart';
import '../../data/lists/members.dart';
import '../../data/tasks/aufgabe_logik.dart';

/// "heute", "morgen", "gestern" oder "do, 22. okt" (bei einem anderen Jahr mit Jahr), bei Uhrzeit mit ", 14:30"; ohne Fälligkeit "ohne datum".
String faelligText(Aufgabe a, DateTime jetzt) {
  final w = faelligWand(a);
  if (w == null) return 'ohne Datum';
  final heute = tagVon(jetzt);
  final tag = DateTime.utc(w.year, w.month, w.day);
  final diff = tag.difference(heute).inDays;
  final text = switch (diff) {
    0 => 'heute',
    1 => 'morgen',
    -1 => 'gestern',
    _ => DateFormat(tag.year == heute.year ? 'E, d. MMM' : 'E, d. MMM y', 'de_DE').format(tag).toLowerCase(),
  };
  return hatUhrzeit(a) ? '$text, ${DateFormat('HH:mm').format(w)}' : text;
}

/// Farbe der Priorität: hoch rot, mittel gelb, niedrig gedämpft.
Color prioFarbe(AufgabePrio p) => switch (p) {
  AufgabePrio.hoch => kDanger,
  AufgabePrio.mittel => kWarn,
  AufgabePrio.niedrig => kTextMuted,
  AufgabePrio.keine => kTextFaint,
};

/// Offene Aufgaben für die Startseiten, sortiert nach Fälligkeit. [nurFaellig]: überfällig oder innerhalb der nächsten [tage] Tage fällig.
List<Aufgabe> startseitenAufgaben(List<Aufgabe> alle, DateTime jetzt, {bool nurFaellig = false, int tage = 7}) {
  final offen = sortiereAufgaben([for (final a in alle) if (!istErledigt(a)) a], AufgabeSortierung.faelligkeit);
  if (!nurFaellig) return offen;
  final grenze = tagVon(jetzt).add(Duration(days: tage + 1));
  return [
    for (final a in offen)
      if ((faelligWand(a)?.isBefore(grenze) ?? false)) a,
  ];
}

/// Kurze Zeile für die Startseiten: Farbbalken (Personenfarbe der zuständigen Person, sonst gedämpft), Titel, Fälligkeit (überfällig rot).
class AufgabeKurzzeile extends StatelessWidget {
  final Aufgabe aufgabe;
  final Mitglieder mitglieder;
  final DateTime jetzt;
  const AufgabeKurzzeile({super.key, required this.aufgabe, required this.mitglieder, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final a = aufgabe;
    final person = mitglieder[a.assigneeId];
    final ueberfaellig = istUeberfaellig(a, jetzt);
    final farbe = person == null ? kBorder : personColor(person.colorIndex);
    final faellig = faelligText(a, jetzt);
    final meta = [ueberfaellig ? 'überfällig · $faellig' : faellig, ?person?.displayName.split(RegExp(r'\s+')).first].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 4, height: 34, margin: const EdgeInsets.only(right: 10), decoration: BoxDecoration(color: farbe, borderRadius: BorderRadius.circular(2))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.titel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: ueberfaellig ? kDanger : kTextMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Mitglieder für Farben, aber erst laden, wenn es Aufgaben gibt (kein zusätzlicher Abruf auf leeren Startseiten).
Mitglieder mitgliederFuerAufgaben(WidgetRef ref, List<Aufgabe> aufgaben) => Mitglieder(aufgaben.isEmpty ? const [] : (ref.watch(mitgliederProvider).value ?? const <UserDto>[]));
