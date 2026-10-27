// Erinnerung eines Termins (`termine.erinnerungMin`): Minuten VOR dem Beginn (0 = zur Startzeit), `null` = nie gesetzt (Altbestand, Termine
// ohne Wahl) und [kErinnerungKeine] (-1) = die Person hat bewusst KEINE Erinnerung gewählt. Der Server erlaubt -1 seit Migration 0038; ältere
// Apps planen für -1 nichts (die Planung rechnet nur mit Werten >= 0), zeigen im Detail aber "-1 Minuten vorher". Nur für Termine, nie für
// Aufgaben, Fristen oder Medikamente. Die Standard-Erinnerung trägt nur `null` nach, nie -1.
const kErinnerungKeine = -1;

/// Wert für die Oberfläche (Auswahl, Anzeige, Planung): `null` = keine Erinnerung (ob nie gesetzt oder bewusst keine).
int? erinnerungMinuten(int? gespeichert) => gespeichert == null || gespeichert < 0 ? null : gespeichert;

/// Wert für den Server, wenn die Person im Editor eine Erinnerung gewählt hat oder "Keine" gilt.
/// [bisher]: gespeicherter Wert eines bestehenden Termins (blieb er `null` und es bleibt bei "Keine", wird nichts geschrieben).
int? erinnerungSpeichern(int? auswahl, {bool neu = true, int? bisher}) {
  if (auswahl != null) return auswahl;
  if (!neu && bisher == null) return null;
  return kErinnerungKeine;
}
