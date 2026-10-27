// Vorsorge und Impfungen (Abschnitt 6p), Zustand für die Oberfläche und die Erinnerungen: die lesbaren Profile und Einträge aller Personen, deren Daten diese Person sehen darf
// ("Ich + meine Kinder", medikament_subjekte.dart). Die Datenbank hält ohnehin nur, was der Server dieser Person liefert; die Sichtregel wird hier trotzdem noch einmal angewendet
// (Rolle gegen Mitgliederliste), damit eine Altlast (zum Beispiel ein Kind, das erwachsen wurde) nie angezeigt wird.
// Entschlüsselt wird nicht blockierend über den Zwischenspeicher ([NachrichtenInhalt.zusatz]).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show Role, UserDto;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/nachrichten_inhalt.dart';
import '../database_provider.dart';
import '../lists/members.dart';
import '../medikamente/medikament_state.dart' show medsKonversationenProvider;
import '../medikamente/medikament_subjekte.dart';
import 'vorsorge_modelle.dart';
import 'vorsorge_repository.dart';

/// Alles, was die Oberfläche braucht. [personen] sind die wählbaren Personen (Ich zuerst, dann die Kinder, wenn die Person Elternteil oder Admin ist).
class VorsorgeDaten {
  /// Datenbank und Mitgliederliste sind gelesen (vorher darf nichts geplant werden).
  final bool geladen;
  final String? ich;
  final Role? ichRolle;
  final List<UserDto> personen;
  final List<VorsorgeAnsicht> eintraege;
  final Map<String, VorsorgeProfilAnsicht> profile;
  const VorsorgeDaten({this.geladen = false, this.ich, this.ichRolle, this.personen = const [], this.eintraege = const [], this.profile = const {}});

  bool get hatKinder => personen.length > 1;
  bool get leer => eintraege.isEmpty && profile.isEmpty;

  UserDto? person(String id) => personen.where((u) => u.id.toLowerCase() == id.toLowerCase()).firstOrNull;

  List<VorsorgeAnsicht> von(String subjektId) => [for (final e in eintraege) if (e.subjektId.toLowerCase() == subjektId.toLowerCase()) e];

  VorsorgeAnsicht? eintrag(String id) => eintraege.where((e) => e.id == id).firstOrNull;

  /// Das Profil der Person, wenn es lesbar ist.
  VorsorgeProfilInhalt? profilVon(String subjektId) => profile[subjektId.toLowerCase()]?.inhalt;

  /// Gibt es ein Profil, das sich (noch) nicht lesen lässt? Dann nie ein neues darüberschreiben.
  bool profilUnlesbar(String subjektId) {
    final p = profile[subjektId.toLowerCase()];
    return p != null && p.inhalt == null;
  }
}

final vorsorgeProfileZeilenProvider = StreamProvider<List<VorsorgeProfilZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.vorsorgeProfile).watch();
});

final vorsorgeEintraegeZeilenProvider = StreamProvider<List<VorsorgeEintragZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.vorsorgeEintraege).watch();
});

/// Die Vorsorge-Daten der sichtbaren Personen (leer ohne Anmeldung); wechselt, sobald sich Daten, Mitglieder oder die Entschlüsselung ändern. Die Mitgliederliste wird nur gelesen (und bei Bedarf
/// geladen), wenn es überhaupt Daten gibt: wer keine hat, löst dadurch keinen Netzaufruf aus. Die Oberfläche nimmt [vorsorgeAnsichtProvider], der die wählbaren Personen immer mitbringt.
final vorsorgeDatenProvider = Provider<VorsorgeDaten>((ref) {
  final me = ref.watch(authProvider.select((a) => a.user?.id));
  final rolle = ref.watch(authProvider.select((a) => a.user?.role));
  final profile = ref.watch(vorsorgeProfileZeilenProvider);
  final zeilen = ref.watch(vorsorgeEintraegeZeilenProvider);
  final konv = ref.watch(medsKonversationenProvider);
  if (me == null || !profile.hasValue || !zeilen.hasValue || !konv.hasValue) return VorsorgeDaten(ich: me, ichRolle: rolle);
  if (profile.value!.isEmpty && zeilen.value!.isEmpty) return VorsorgeDaten(geladen: true, ich: me, ichRolle: rolle);
  final inhalt = ref.watch(nachrichtenInhaltProvider); // erst bei vorhandenen Daten (startet die Entschlüsselung)
  final mitglieder = ref.watch(mitgliederProvider);
  if (!mitglieder.hasValue) return VorsorgeDaten(ich: me, ichRolle: rolle);
  final liste = mitglieder.value!;
  final personen = erlaubteSubjekte(ich: me, mitglieder: liste);
  final subjektVon = {for (final k in konv.value!) if (k.subjektId != null) k.id: k.subjektId!};
  final repo = ref.read(vorsorgeRepositoryProvider);
  final eintraege = <VorsorgeAnsicht>[];
  for (final z in zeilen.value!) {
    final subjekt = subjektVon[z.konversationId];
    if (subjekt == null || !darfSubjektSehen(ich: me, subjekt: subjekt, mitglieder: liste)) continue;
    eintraege.add(repo.ansicht(subjekt, z, inhalt));
  }
  final profilKarte = <String, VorsorgeProfilAnsicht>{};
  for (final z in profile.value!) {
    final subjekt = subjektVon[z.konversationId];
    if (subjekt == null || !darfSubjektSehen(ich: me, subjekt: subjekt, mitglieder: liste)) continue;
    profilKarte[subjekt.toLowerCase()] = repo.profilAnsicht(subjekt, z, inhalt);
  }
  return VorsorgeDaten(geladen: true, ich: me, ichRolle: rolle, personen: personen, eintraege: eintraege, profile: profilKarte);
});

/// Für die Oberfläche: [vorsorgeDatenProvider] mit den wählbaren Personen ("Ich + meine Kinder"), auch wenn es noch keine Daten gibt (lädt die Mitgliederliste).
final vorsorgeAnsichtProvider = Provider<VorsorgeDaten>((ref) {
  final d = ref.watch(vorsorgeDatenProvider);
  final mitglieder = ref.watch(mitgliederProvider);
  final me = d.ich;
  if (me == null || !mitglieder.hasValue) return d;
  return VorsorgeDaten(geladen: d.geladen, ich: me, ichRolle: d.ichRolle, personen: erlaubteSubjekte(ich: me, mitglieder: mitglieder.value!), eintraege: d.eintraege, profile: d.profile);
});
