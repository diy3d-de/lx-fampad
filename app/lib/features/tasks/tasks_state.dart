// Ansicht der Aufgabenliste: Filter (Offen/Alle/Meine/Erledigt), Person und Sortierung. Bleibt beim Tab-Wechsel erhalten.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks/aufgabe_logik.dart';

class AufgabenAnsicht {
  final AufgabeFilter filter;
  final AufgabeSortierung sortierung;

  /// Nur Aufgaben dieser Person (null: alle).
  final String? person;
  const AufgabenAnsicht({this.filter = AufgabeFilter.offen, this.sortierung = AufgabeSortierung.faelligkeit, this.person});

  AufgabenAnsicht mit({AufgabeFilter? filter, AufgabeSortierung? sortierung, String? person, bool personLeeren = false}) =>
      AufgabenAnsicht(filter: filter ?? this.filter, sortierung: sortierung ?? this.sortierung, person: personLeeren ? null : (person ?? this.person));
}

class AufgabenAnsichtNotifier extends Notifier<AufgabenAnsicht> {
  @override
  AufgabenAnsicht build() => const AufgabenAnsicht();

  void filter(AufgabeFilter f) => state = state.mit(filter: f);
  void sortierung(AufgabeSortierung s) => state = state.mit(sortierung: s);
  void person(String? id) => state = id == null ? state.mit(personLeeren: true) : state.mit(person: id);
}

final aufgabenAnsichtProvider = NotifierProvider<AufgabenAnsichtNotifier, AufgabenAnsicht>(AufgabenAnsichtNotifier.new);
