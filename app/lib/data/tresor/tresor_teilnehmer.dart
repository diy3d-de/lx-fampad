// Tresor (Abschnitt 6m): wer den Tresor der Eltern sehen darf und wer in die Tresor-Konversation gehört. Rein, ohne Datenbank.
//
// Regel (der Server erzwingt dieselbe gegen die Rollen seiner Datenbank, server/src/sync/entities/tresor-regeln.ts):
//  - Eltern und Admins (Rollen `parent`/`admin`) sehen und ändern den Tresor, alle gemeinsam (EIN Tresor, keiner je Person).
//  - Kinder haben NIE Zugriff: sie sind nie Teilnehmer, sehen nichts, die App zeigt ihnen keinen Menüpunkt.
// Die Rolle kommt aus der Mitgliederliste der App (GET /members, lokal zwischengespeichert), nie aus der Familienrolle (reine Anzeige) und nie aus dem Betreiber-Flag.
import '../api/models.dart' show MemberStatus, UserDto;
import '../medikamente/medikament_subjekte.dart' show istErwachsen;

Set<String> _aktiveErwachsene(Iterable<UserDto> mitglieder) => {
  for (final u in mitglieder)
    if (u.status == MemberStatus.active && istErwachsen(u.role)) u.id.toLowerCase(),
};

/// Darf [ich] den Tresor sehen und ändern (aktive Person mit Rolle Elternteil oder Admin)?
bool darfTresorSehen({required String ich, required Iterable<UserDto> mitglieder}) => _aktiveErwachsene(mitglieder).contains(ich.toLowerCase());

/// Ist diese Teilnehmerliste zulässig (dieselbe Regel wie auf dem Server)? Mindestens eine Person, nur aktive Erwachsene, keine Doppelten.
bool tresorTeilnehmerGueltig({required Iterable<String> teilnehmer, required Iterable<UserDto> mitglieder}) {
  final liste = [for (final t in teilnehmer) t.toLowerCase()];
  final erlaubt = _aktiveErwachsene(mitglieder);
  return liste.isNotEmpty && liste.toSet().length == liste.length && liste.every(erlaubt.contains);
}

/// Wer in die Tresor-Konversation gehört: alle aktiven Eltern und Admins. Mit [nurMit] (Personen mit eingerichteter Verschlüsselung; der Rest kann noch keinen Schlüssel bekommen)
/// beschränkt auf diese.
Set<String> sollTresorTeilnehmer({required Iterable<UserDto> mitglieder, Set<String>? nurMit}) {
  final alle = _aktiveErwachsene(mitglieder);
  if (nurMit == null) return alle;
  final mit = nurMit.map((x) => x.toLowerCase()).toSet();
  return alle.where(mit.contains).toSet();
}

/// Was an der Teilnehmerliste zu ändern ist: wer hinzukommt (Eltern/Admins, die noch fehlen und einen vertrauenswürdigen Schlüssel haben) und wer geht (jede Person, die nach den
/// Rollen nicht (mehr) hineingehört: Elternteil wurde Kind oder wurde entfernt). Wer keinen Schlüssel hat, bleibt, wenn er hineingehört (nie jemanden wegen fehlendem Schlüssel entfernen).
class TresorAbgleich {
  final Set<String> hinzu;
  final Set<String> weg;
  const TresorAbgleich(this.hinzu, this.weg);
  bool get leer => hinzu.isEmpty && weg.isEmpty;
}

TresorAbgleich tresorAbgleichen({required Iterable<String> aktuell, required Iterable<UserDto> mitglieder, Set<String>? nurMit}) {
  final soll = sollTresorTeilnehmer(mitglieder: mitglieder, nurMit: nurMit);
  final gehoertHinein = sollTresorTeilnehmer(mitglieder: mitglieder);
  final jetzt = {for (final t in aktuell) t.toLowerCase()};
  return TresorAbgleich({for (final t in soll) if (!jetzt.contains(t)) t}, {for (final t in jetzt) if (!gehoertHinein.contains(t)) t});
}
