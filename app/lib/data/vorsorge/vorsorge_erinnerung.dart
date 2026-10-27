// Vorsorge und Impfungen (Abschnitt 6p): Planung der Erinnerungen als reine Logik (kein Plugin, keine Oberfläche). Das Ergebnis geht über `planeErinnerungen(zusatz:)` in das gemeinsame
// Fenster des Erinnerungsdienstes (erinnerung_planung.dart), wie bei Medikamenten, Müll und Zählern; im Browser über denselben Dienst (WebErinnerungPort).
//
// Regeln:
//  - Lokal und nur an Personen, die die Daten sehen: die Person selbst und, bei einem Kind, jedes Elternteil und jeder Admin ([VorsorgeDaten] enthält ohnehin nur, was die Person sehen darf;
//    jedes Gerät plant, was es sehen darf). Nie Push, nie ein Wecker vom Server.
//  - Text immer neutral: "Eine Vorsorge ist fällig" (nie Name, nie Person, nie Art des Eintrags), auch auf dem Sperrbildschirm. Die Nutzlast ist nur `vorsorge` und öffnet den Bereich.
//  - Wann: [Vorlauf] Tage vor Beginn des Zeitfensters (je Eintrag einstellbar, Standard 14), danach einmal wöchentlich, solange der Eintrag fällig oder überfällig ist (bis er erledigt ist);
//    um 09:00 Uhr der Familienzone, höchstens ein Alarm je Person und Tag.
//  - Eintrag erledigt, nur Hinweis (ohne Zeitfenster), nicht berechenbar (Geburtsdatum fehlt) oder nicht lesbar: keine Erinnerung.
//  - Vorausgeplant wird [kVorsorgeHorizontTage] Tage; vergangene Zeitpunkte entfallen. Das Fenster des Dienstes wird bei jeder Änderung neu berechnet, ein Erledigt-Eintrag nimmt seine Alarme mit.
import 'package:timezone/timezone.dart' as tz;

import '../calendar/zeitzonen.dart';
import '../medikamente/medikament_logik.dart' show familienTag;
import '../erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung, erinnerungId, kMindestAbstand;
import 'vorsorge_logik.dart';
import 'vorsorge_modelle.dart';
import 'vorsorge_vorlagen.dart' show vorsorgeVorlage;
import 'vorsorge_state.dart';

/// Neutraler Titel (nie ein Name).
const String kVorsorgeTitel = 'Eine Vorsorge ist fällig';

/// Text unter dem Titel (nie ein Name).
const String kVorsorgeErinnerungText = 'Tippe, um den Bereich Vorsorge zu öffnen.';

/// Nutzlast (nur eine Kennung, nie ein Inhalt).
const String kVorsorgePayload = 'vorsorge';

/// Uhrzeit der Erinnerung in Minuten seit Mitternacht (09:00).
const int kVorsorgeMinuten = 9 * 60;

/// Wie viele Tage (ab heute) vorausgeplant wird.
const int kVorsorgeHorizontTage = 28;

bool istVorsorgePayload(String? payload) => payload == kVorsorgePayload;

/// Die Erinnerungen für die nächsten Tage ab [jetzt] (nicht sortiert, der Dienst sortiert das gemeinsame Fenster).
List<GeplanteErinnerung> planeVorsorgeErinnerungen({required VorsorgeDaten daten, required DateTime jetzt, tz.Location? ort, int tage = kVorsorgeHorizontTage}) {
  if (daten.ich == null || !daten.geladen || daten.eintraege.isEmpty) return const [];
  final berlin = ort ?? familienOrt;
  final jetztUtc = jetzt.toUtc();
  final grenze = jetztUtc.add(kMindestAbstand);
  final f = familienTag(jetztUtc, berlin);
  final heute = DateTime.utc(f.year, f.month, f.day);
  // je Person die Tage, an denen eine Erinnerung gewünscht ist
  final proPerson = <String, Set<DateTime>>{};
  for (final person in daten.personen) {
    final profil = daten.profilVon(person.id);
    final geburt = profil?.geburtTag;
    final eintraege = daten.von(person.id);
    for (final a in eintraege) {
      final i = a.inhalt;
      if (i == null) continue;
      final fl = vorsorgeFaelligkeit(vorlage: vorsorgeVorlage(i.vorlage), eintrag: i, geburt: geburt, geschlecht: profil?.geschlecht, heute: heute);
      if (fl.ab == null || fl.status == VorsorgeStatus.erledigt || fl.status == VorsorgeStatus.keinTermin) continue;
      final start = fl.ab!.subtract(Duration(days: i.vorlauf));
      for (var n = 0; n < tage; n++) {
        final tag = DateTime.utc(heute.year, heute.month, heute.day + n);
        final diff = tag.difference(start).inDays;
        if (diff >= 0 && diff % 7 == 0) (proPerson[person.id.toLowerCase()] ??= {}).add(tag);
      }
    }
  }
  final out = <GeplanteErinnerung>[];
  for (final e in proPerson.entries) {
    for (final tag in e.value) {
      final zeit = tz.TZDateTime(berlin, tag.year, tag.month, tag.day, kVorsorgeMinuten ~/ 60, kVorsorgeMinuten % 60).toUtc();
      if (!zeit.isAfter(grenze)) continue;
      out.add(GeplanteErinnerung(id: erinnerungId(e.key, 'vorsorge|${vorsorgeTagText(tag)}'), zeit: zeit, titel: kVorsorgeTitel, text: kVorsorgeErinnerungText, payload: kVorsorgePayload));
    }
  }
  return out;
}
