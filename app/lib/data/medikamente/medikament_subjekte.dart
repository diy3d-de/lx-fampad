// Medikamenten-Plan (Abschnitt 6k): wessen Medikamente eine Person sehen darf, und wer in die Medikamenten-Konversation einer Person gehört. Rein, ohne Datenbank.
//
// Regel (der Server erzwingt dieselbe gegen die Rollen seiner Datenbank, server/src/sync/entities/meds-regeln.ts):
//  - Jede Person sieht ihre eigenen Medikamente.
//  - Eltern und Admins (Rollen `parent`/`admin`) sehen zusätzlich die ihrer KINDER (Rolle `child`), nie die eines anderen Erwachsenen (auch Admins nicht).
//  - Kinder sehen nur ihre eigenen, nie die von Erwachsenen und nie die ihrer Geschwister.
// Die Rolle kommt aus der Mitgliederliste der App (GET /members, lokal zwischengespeichert), nie aus der Familienrolle (reine Anzeige).
import '../api/models.dart' show MemberStatus, Role, UserDto;

bool istErwachsen(Role r) => r == Role.admin || r == Role.parent;

Map<String, Role> _rollen(Iterable<UserDto> mitglieder) => {
  for (final u in mitglieder)
    if (u.status == MemberStatus.active) u.id.toLowerCase(): u.role,
};

/// Die Personen, deren Medikamente [ich] auswählen darf: zuerst die eigene Person, dann (nur für Eltern und Admins) die Kinder, nach Namen sortiert. Nie ein anderer Erwachsener.
List<UserDto> erlaubteSubjekte({required String ich, required Iterable<UserDto> mitglieder}) {
  final aktive = [for (final u in mitglieder) if (u.status == MemberStatus.active) u];
  final eigene = aktive.where((u) => u.id.toLowerCase() == ich.toLowerCase()).firstOrNull;
  if (eigene == null) return const [];
  final kinder = istErwachsen(eigene.role) ? ([for (final u in aktive) if (u.role == Role.child && u.id != eigene.id) u]..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()))) : const <UserDto>[];
  return [eigene, ...kinder];
}

/// Darf [ich] die Medikamente von [subjekt] sehen und ändern?
bool darfSubjektSehen({required String ich, required String subjekt, required Iterable<UserDto> mitglieder}) =>
    erlaubteSubjekte(ich: ich, mitglieder: mitglieder).any((u) => u.id.toLowerCase() == subjekt.toLowerCase());

/// Ist diese Teilnehmerliste für die Medikamente von [subjekt] zulässig (dieselbe Regel wie auf dem Server)? Kind: es selbst und beliebig viele Erwachsene; Erwachsener: nur er selbst.
bool teilnehmerGueltig({required String subjekt, required Iterable<String> teilnehmer, required Iterable<UserDto> mitglieder}) {
  final rollen = _rollen(mitglieder);
  final s = subjekt.toLowerCase();
  final liste = [for (final t in teilnehmer) t.toLowerCase()];
  final rolle = rollen[s];
  if (rolle == null || !liste.contains(s)) return false;
  if (istErwachsen(rolle)) return liste.length == 1;
  return liste.every((t) => t == s || (rollen[t] != null && istErwachsen(rollen[t]!)));
}

/// Wer in die Medikamenten-Konversation von [subjekt] gehört: das Subjekt und, nur bei einem Kind, alle aktiven Eltern und Admins. Mit [nurMit] (Personen mit eingerichteter
/// Verschlüsselung, der Rest kann noch keinen Schlüssel bekommen) beschränkt auf diese; das Subjekt selbst bleibt immer. Leer, wenn das Subjekt nicht (mehr) aktiv ist.
Set<String> sollTeilnehmer({required String subjekt, required Iterable<UserDto> mitglieder, Set<String>? nurMit}) {
  final rollen = _rollen(mitglieder);
  final s = subjekt.toLowerCase();
  final rolle = rollen[s];
  if (rolle == null) return const {};
  if (istErwachsen(rolle)) return {s};
  return {
    s,
    for (final e in rollen.entries)
      if (istErwachsen(e.value) && (nurMit == null || nurMit.map((x) => x.toLowerCase()).contains(e.key))) e.key,
  };
}

/// Was an der Teilnehmerliste einer Medikamenten-Konversation zu ändern ist: wer hinzukommt (Eltern/Admins eines Kindes, die noch fehlen) und wer geht (jede Person, die nach den
/// Rollen nicht mehr hinein gehört: Kind wurde erwachsen, Elternteil wurde Kind oder entfernt). Das Subjekt geht nie.
class TeilnehmerAbgleich {
  final Set<String> hinzu;
  final Set<String> weg;
  const TeilnehmerAbgleich(this.hinzu, this.weg);
  bool get leer => hinzu.isEmpty && weg.isEmpty;
}

TeilnehmerAbgleich teilnehmerAbgleichen({required String subjekt, required Iterable<String> aktuell, required Iterable<UserDto> mitglieder, Set<String>? nurMit}) {
  final soll = sollTeilnehmer(subjekt: subjekt, mitglieder: mitglieder, nurMit: nurMit);
  // wer schon drin ist, bleibt, wenn er laut Rollen hineingehört (auch ohne Schlüssel: nie jemanden wegen fehlendem Schlüssel entfernen)
  final gehoertHinein = sollTeilnehmer(subjekt: subjekt, mitglieder: mitglieder);
  final jetzt = {for (final t in aktuell) t.toLowerCase()};
  return TeilnehmerAbgleich({for (final t in soll) if (!jetzt.contains(t)) t}, {for (final t in jetzt) if (!gehoertHinein.contains(t)) t});
}
