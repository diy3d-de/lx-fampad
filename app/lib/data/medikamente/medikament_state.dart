// Medikamenten-Plan (Abschnitt 6k), Zustand für die Oberfläche und die Erinnerungen: die lesbaren Pläne und Einnahmen aller Personen, deren Medikamente diese Person sehen darf
// ("Ich + meine Kinder", medikament_subjekte.dart). Die Datenbank hält ohnehin nur, was der Server dieser Person liefert; die Sichtregel wird hier trotzdem noch einmal angewendet
// (Rolle gegen Mitgliederliste), damit eine Altlast (z. B. ein Kind, das erwachsen wurde) nie angezeigt wird.
// Entschlüsselt wird nicht blockierend über den Zwischenspeicher ([NachrichtenInhalt.zusatz]): bis der Schlüssel da ist, kommt ein Eintrag ohne Inhalt mit Hinweis.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models.dart' show Role, UserDto;
import '../app_database.dart';
import '../auth/auth_state.dart';
import '../chat/chat_repository.dart' show ChatArt;
import '../chat/nachrichten_inhalt.dart';
import '../database_provider.dart';
import '../lists/members.dart';
import 'medikament_modelle.dart';
import 'medikament_repository.dart';
import 'medikament_subjekte.dart';

/// Ein Medikament mit seinen Einnahmen (älteste zuerst).
class MedEintrag {
  final MedikamentAnsicht med;
  final List<EinnahmeAnsicht> einnahmen;
  const MedEintrag(this.med, this.einnahmen);

  String get id => med.id;
  String get subjektId => med.subjektId;
  MedikamentInhalt? get inhalt => med.inhalt;
  bool get lesbar => med.inhalt != null;
}

/// Alles, was die Oberfläche braucht. [personen] sind die wählbaren Subjekte (Ich zuerst, dann die Kinder, wenn die Person Elternteil oder Admin ist).
class MedDaten {
  /// Datenbank und Mitgliederliste sind gelesen (vorher darf nichts geplant oder gelöscht werden).
  final bool geladen;
  final String? ich;
  final Role? ichRolle;
  final List<UserDto> personen;
  final List<MedEintrag> eintraege;
  const MedDaten({this.geladen = false, this.ich, this.ichRolle, this.personen = const [], this.eintraege = const []});

  bool get hatKinder => personen.length > 1;
  bool get leer => eintraege.isEmpty;

  UserDto? person(String id) => personen.where((u) => u.id.toLowerCase() == id.toLowerCase()).firstOrNull;

  MedEintrag? eintrag(String id) => eintraege.where((e) => e.id == id).firstOrNull;

  List<MedEintrag> von(String subjektId) => [for (final e in eintraege) if (e.subjektId.toLowerCase() == subjektId.toLowerCase()) e];
}

final medikamenteZeilenProvider = StreamProvider<List<MedikamentZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.medikamente).watch();
});

final einnahmenZeilenProvider = StreamProvider<List<EinnahmeZeile>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.einnahmen).watch();
});

/// Die verborgenen Medikamenten-Konversationen (nur für die Zuordnung Konversation -> Person).
final medsKonversationenProvider = StreamProvider<List<Konversation>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.konversationen)..where((k) => k.art.equals(ChatArt.meds.wire))).watch();
});

/// Die Medikamente der sichtbaren Personen (leer ohne Anmeldung); wechselt, sobald sich Daten, Mitglieder oder die Entschlüsselung ändern. Die Mitgliederliste wird nur gelesen (und bei Bedarf geladen),
/// wenn es überhaupt Pläne gibt: wer keine hat, löst dadurch keinen Netzaufruf aus. Die Oberfläche nimmt [medAnsichtProvider], der die wählbaren Personen immer mitbringt.
final medDatenProvider = Provider<MedDaten>((ref) {
  final me = ref.watch(authProvider.select((a) => a.user?.id));
  final rolle = ref.watch(authProvider.select((a) => a.user?.role));
  final zeilen = ref.watch(medikamenteZeilenProvider);
  final einnahmen = ref.watch(einnahmenZeilenProvider);
  final konv = ref.watch(medsKonversationenProvider);
  if (me == null || !zeilen.hasValue || !einnahmen.hasValue || !konv.hasValue) return MedDaten(ich: me, ichRolle: rolle);
  if (zeilen.value!.isEmpty) return MedDaten(geladen: true, ich: me, ichRolle: rolle);
  final inhalt = ref.watch(nachrichtenInhaltProvider); // erst bei vorhandenen Plänen (startet die Entschlüsselung)
  final mitglieder = ref.watch(mitgliederProvider);
  if (!mitglieder.hasValue) return MedDaten(ich: me, ichRolle: rolle);
  final liste = mitglieder.value!;
  final personen = erlaubteSubjekte(ich: me, mitglieder: liste);
  final subjektVon = {for (final k in konv.value!) if (k.subjektId != null) k.id: k.subjektId!};
  final repo = ref.read(medikamentRepositoryProvider);
  final nachMed = <String, List<EinnahmeAnsicht>>{};
  for (final z in einnahmen.value!) {
    (nachMed[z.medikamentId] ??= []).add(repo.einnahmeAnsicht(z, inhalt));
  }
  final eintraege = <MedEintrag>[];
  for (final z in zeilen.value!) {
    final subjekt = subjektVon[z.konversationId];
    if (subjekt == null || !darfSubjektSehen(ich: me, subjekt: subjekt, mitglieder: liste)) continue;
    eintraege.add(MedEintrag(repo.ansicht(subjekt, z, inhalt), nachMed[z.id] ?? const []));
  }
  return MedDaten(geladen: true, ich: me, ichRolle: rolle, personen: personen, eintraege: eintraege);
});

/// Für die Oberfläche (Bereich, Detail, Editor): [medDatenProvider] mit den wählbaren Personen ("Ich + meine Kinder"), auch wenn es noch keinen Plan gibt (lädt die Mitgliederliste).
final medAnsichtProvider = Provider<MedDaten>((ref) {
  final d = ref.watch(medDatenProvider);
  final mitglieder = ref.watch(mitgliederProvider);
  final me = d.ich;
  if (me == null || !mitglieder.hasValue) return d;
  return MedDaten(geladen: d.geladen, ich: me, ichRolle: d.ichRolle, personen: erlaubteSubjekte(ich: me, mitglieder: mitglieder.value!), eintraege: d.eintraege);
});
