// Reine Anzeige-Zusammenfassung für das Android-Startbildschirm-Widget "Heute" (nur Android, Kotlin-Seite: HeuteWidget*.kt).
//
// Datenschutz: nur das, was das Widget zeigt (Uhrzeit, Titel, fällige Aufgaben, offene Einträge EINER gewählten Liste), kein Chat, kein Standort,
// keine Schlüssel, keine Personen- oder Termin-IDs. Mit ausgeschaltetem "Titel anzeigen" stehen statt der Titel neutrale Wörter ("Termin", "Aufgabe",
// "Eintrag") in der Zusammenfassung; sie wird dann gar nicht erst mit Titeln geschrieben.
//
// Das Widget zeigt immer den Tag, an dem es gezeichnet wird: die Zusammenfassung enthält deshalb die Termine von heute und den zwei Folgetagen (nach
// Mitternacht genügt der Tageswechsel-Broadcast, ohne dass die App laufen muss) und Aufgaben mit ihrem Fälligkeitstag.
import 'dart:convert';

import '../app_database.dart';
import '../calendar/expansion.dart';
import '../calendar/geburtstag.dart';
import '../calendar/termin_repository.dart';
import '../lists/list_repository.dart' show sortiereEintraege;
import '../tasks/aufgabe_logik.dart';

/// Obergrenzen (das Widget zeigt je Bereich höchstens 5 Zeilen; etwas Reserve für Zeilen, die nach Mitternacht heute werden).
const kWidgetMaxTermineProTag = 8;
const kWidgetMaxAufgaben = 12;
const kWidgetMaxEinkauf = 8;
const kWidgetTage = 3;

/// Schlüssel der Einstellung "keine Liste im Widget".
const kWidgetKeineListe = '';

String _hhmm(DateTime w) => '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';

/// Baut die Zusammenfassung als JSON-Text. [jetzt] ist der Zeitpunkt der Berechnung, [titelAnzeigen] die lokale Einstellung,
/// [einkaufListe] (Name) und [einkaufEintraege] (offene Einträge) nur, wenn eine Liste gewählt ist.
String heuteZusammenfassung({
  required KalenderDaten kalender,
  required List<Aufgabe> aufgaben,
  required DateTime jetzt,
  required bool titelAnzeigen,
  String? einkaufListe,
  List<Listeneintrag> einkaufEintraege = const [],
  DateTime? stand,
}) {
  final heute = tagVon(jetzt);
  final bis = heute.add(const Duration(days: kWidgetTage));
  final vorkommen = vorkommenImFenster(termine: kalender.termine, ausnahmen: kalender.ausnahmen, vonWand: heute, bisWand: bis, jetzt: jetzt.toUtc());
  final proTag = nachTagen(vorkommen, heute, bis.subtract(const Duration(days: 1)));
  final tage = <Map<String, Object?>>[];
  for (var i = 0; i < kWidgetTage; i++) {
    final tag = heute.add(Duration(days: i));
    final liste = proTag[tag] ?? const <Vorkommen>[];
    tage.add({
      'd': tagText(tag),
      't': [
        for (final v in liste.take(kWidgetMaxTermineProTag))
          {
            // ganztägig und weitergehende Termine ohne Uhrzeit; sonst die Startzeit
            'z': (!v.ganztaegig && v.ersterTag == tag) ? _hhmm(v.startWand) : '',
            'x': titelAnzeigen ? vorkommenTitel(v) : (istGeburtstag(v.termin) ? 'Geburtstag' : 'Termin'),
          },
      ],
    });
  }
  final offen = [
    for (final a in sortiereAufgaben([for (final a in aufgaben) if (!istErledigt(a)) a], AufgabeSortierung.faelligkeit))
      if (faelligWand(a) != null) a,
  ];
  final grenze = heute.add(const Duration(days: kWidgetTage));
  final faellige = <Map<String, Object?>>[];
  for (final a in offen) {
    final w = faelligWand(a)!;
    final tag = DateTime.utc(w.year, w.month, w.day);
    if (!tag.isBefore(grenze)) continue;
    faellige.add({'f': tagText(tag), 'x': titelAnzeigen ? a.titel : 'Aufgabe'});
    if (faellige.length >= kWidgetMaxAufgaben) break;
  }
  Map<String, Object?>? einkauf;
  if (einkaufListe != null) {
    final offene = sortiereEintraege(einkaufEintraege);
    einkauf = {
      'n': titelAnzeigen ? einkaufListe : 'Einkaufsliste',
      'a': offene.length,
      'e': [for (final e in offene.take(kWidgetMaxEinkauf)) titelAnzeigen ? e.inhalt : 'Eintrag'],
    };
  }
  final s = (stand ?? jetzt).toUtc();
  return jsonEncode({'v': 1, 's': s.toIso8601String(), 'tage': tage, 'aufgaben': faellige, 'einkauf': ?einkauf});
}

/// Ohne den Zeitstempel verglichen: nur Änderungen am Inhalt lösen ein Schreiben und eine Widget-Aktualisierung aus.
String ohneStand(String json) {
  try {
    final m = jsonDecode(json) as Map<String, dynamic>;
    m.remove('s');
    return jsonEncode(m);
  } catch (_) {
    return json;
  }
}
