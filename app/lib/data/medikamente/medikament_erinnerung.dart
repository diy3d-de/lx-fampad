// Medikamenten-Plan (Abschnitt 6k): Planung der Einnahme-Erinnerungen als reine Logik (kein Plugin, keine Oberfläche). Das Ergebnis geht über `planeErinnerungen(zusatz:)` in das gemeinsame
// Fenster des Erinnerungsdienstes (erinnerung_planung.dart), wie die Müll-Erinnerungen.
//
// Regeln:
//  - Lokal und nur an Personen, die den Plan sehen: die Person selbst und, bei Plänen eines Kindes, jedes Elternteil und jeder Admin (deren Geräte planen die Alarme für die Kinder-Pläne;
//    [medDaten] enthält ohnehin nur, was die Person sehen darf). Nie Push, nie ein Wecker vom Server.
//  - Text immer neutral: "Zeit für deine Medikamente" für die eigenen Pläne, "Zeit für Medikamente" für die eines Kindes (ohne Namen von Medikament, Dosis, Person), auch auf dem
//    Sperrbildschirm. Die Nutzlast nennt nur eine ID (`medikament|<ID>`), nie einen Inhalt.
//  - Ein Alarm je Person und Uhrzeit (mehrere Medikamente zur selben Zeit ergeben eine Erinnerung). Er wird nur geplant, solange mindestens ein Medikament dieses Slots nicht erfasst ist.
//  - Vergisst jemand die Einnahme, folgt GENAU EINE erneute Erinnerung [kNachfassMinuten] Minuten später, solange der Slot nicht erfasst ist. Keine weitere Eskalation.
//  - Pausierte und beendete Pläne und "bei Bedarf" ergeben nichts (Rhythmus und Zustand wertet `tagesplan` aus). Vorrat und Rezept lösen keine Erinnerung aus (nur Hinweise in der App).
//  - Vorausgeplant wird [kMedHorizontTage] Tage; vergangene Zeitpunkte entfallen. Das Fenster des Dienstes wird bei jeder Änderung neu berechnet, ein abgehakter Slot nimmt seine Alarme mit.
import 'package:timezone/timezone.dart' as tz;

import '../calendar/zeitzonen.dart';
import '../erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung, erinnerungId, kMindestAbstand;
import 'medikament_logik.dart';
import 'medikament_state.dart';

/// Minuten bis zur erneuten Erinnerung bei vergessener Einnahme.
const int kNachfassMinuten = 15;

/// Wie viele Tage (ab heute) vorausgeplant wird.
const int kMedHorizontTage = 5;

/// Neutrale Titel (nie ein Name).
const String kMedTitelEigen = 'Zeit für deine Medikamente';
const String kMedTitelKind = 'Zeit für Medikamente';

/// Text unter dem Titel (nie ein Name).
const String kMedErinnerungText = 'Tippe, um die Einnahme abzuhaken.';

/// Kennung der Nutzlast (`medikament|<ID>`).
const String kMedPayloadKennung = 'medikament';

String medikamentPayload(String medikamentId) => '$kMedPayloadKennung|$medikamentId';

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Ist es die Nutzlast einer Medikamenten-Erinnerung (ID muss eine UUID sein)? Nie eine Ausnahme.
bool istMedikamentPayload(String? payload) {
  if (payload == null) return false;
  final t = payload.split('|');
  return t.length == 2 && t[0] == kMedPayloadKennung && _uuid.hasMatch(t[1]);
}

/// Die Erinnerungen für die nächsten Tage ab [jetzt] (nicht sortiert, der Dienst sortiert das gemeinsame Fenster). [ich] ist die angemeldete Person.
List<GeplanteErinnerung> planeMedikamentErinnerungen({required MedDaten medDaten, required DateTime jetzt, tz.Location? ort, int tage = kMedHorizontTage}) {
  final ich = medDaten.ich?.toLowerCase();
  if (ich == null || !medDaten.geladen || medDaten.eintraege.isEmpty) return const [];
  final berlin = ort ?? familienOrt;
  final jetztUtc = jetzt.toUtc();
  final grenze = jetztUtc.add(kMindestAbstand);
  final heute = familienTag(jetztUtc, berlin);
  // je Person und Slot: die Medikamente, die nicht erfasst sind
  final offen = <String, ({String subjekt, Slot slot, String ersteId})>{};
  for (final e in medDaten.eintraege) {
    final m = e.inhalt;
    if (m == null) continue;
    final subjekt = e.subjektId.toLowerCase();
    for (var i = 0; i < tage; i++) {
      final tag = DateTime.utc(heute.year, heute.month, heute.day + i);
      for (final s in tagesplan(m, e.einnahmen, tag, jetztUtc, ort: berlin)) {
        if (s.status == SlotStatus.genommen || s.status == SlotStatus.uebersprungen) continue;
        final k = '$subjekt|${s.slot.schluessel}';
        final alt = offen[k];
        if (alt == null || e.id.compareTo(alt.ersteId) < 0) offen[k] = (subjekt: subjekt, slot: s.slot, ersteId: e.id);
      }
    }
  }
  final out = <GeplanteErinnerung>[];
  final ids = <int>{};
  void dazu(String subjekt, Slot slot, String medId, DateTime zeit, String art) {
    if (!zeit.isAfter(grenze)) return;
    final id = erinnerungId(subjekt, 'med|${slot.schluessel}|$art');
    if (!ids.add(id)) return;
    out.add(
      GeplanteErinnerung(
        id: id,
        zeit: zeit,
        titel: subjekt == ich ? kMedTitelEigen : kMedTitelKind,
        text: kMedErinnerungText,
        payload: medikamentPayload(medId),
      ),
    );
  }

  for (final o in offen.values) {
    final zeit = o.slot.instant(berlin);
    dazu(o.subjekt, o.slot, o.ersteId, zeit, 'a');
    dazu(o.subjekt, o.slot, o.ersteId, zeit.add(const Duration(minutes: kNachfassMinuten)), 'n');
  }
  return out;
}
