// Was die Oberfläche der angemeldeten Rolle bei Listen anbietet. Spiegelt die Regeln des Servers (server/src/sync/entities/lists.ts);
// maßgeblich ist immer der Server, der jede Op prüft und Unerlaubtes ablehnt. Hier geht es nur darum, nichts Unmögliches anzubieten.
import '../api/models.dart';
import '../app_database.dart';
import 'list_repository.dart';

class ListenRechte {
  final Role rolle;
  final String? userId;
  const ListenRechte(this.rolle, this.userId);

  bool get _erwachsen => rolle == Role.admin || rolle == Role.parent;

  /// Alle Rollen legen Listen an; Kinder nur Familienlisten.
  bool get darfListeAnlegen => true;

  /// Eintragen, bearbeiten, abhaken, zuweisen, löschen: alle Rollen (in sichtbaren Listen).
  bool get darfEintraegeAendern => true;

  bool darfListeAendern(Liste l) => _erwachsen || (rolle == Role.child && userId != null && l.ownerId == userId);

  /// Die Freigabe (wer die Liste sieht) ändern nur Eltern und Admins.
  bool get darfFreigabeAendern => _erwachsen;

  /// Freigaben, die beim Anlegen zur Wahl stehen.
  List<ListenSicht> get freigaben => _erwachsen ? ListenSicht.values : const [ListenSicht.family];
}
