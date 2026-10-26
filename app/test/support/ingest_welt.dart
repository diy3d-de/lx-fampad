// Gemeinsame Bausteine der Tests der Home-Assistant-Anbindung: ein Notifier mit festem Zustand und aufgezeichneten Aufrufen (kein Dienst, kein Netz), ein Fake-Dienst, ein Prüfeintrag.
import 'dart:async';

import 'package:lx_fampad/data/ingest/ingest_dienst.dart';
import 'package:lx_fampad/data/ingest/ingest_logik.dart' show PruefGrund;
import 'package:lx_fampad/data/ingest/ingest_state.dart';

import 'zaehler_welt.dart' show zStrom;

/// Ersetzt den echten Notifier: feste Zustände, aufgezeichnete Aufrufe, kein Dienst, kein Netz.
class TestIngest extends IngestNotifier {
  final IngestZustand start;
  final aufrufe = <String>[];
  TestIngest(this.start);

  @override
  IngestZustand build() => start;

  @override
  Future<void> neuLesen() async {}

  @override
  Future<void> schalterSetzen(bool an) async {
    aufrufe.add('schalter:$an');
    state = state.kopie(schalter: an);
  }

  @override
  Future<void> abholen() async => aufrufe.add('abholen');

  @override
  Future<void> beimOeffnen() async => aufrufe.add('oeffnen');

  void _weg(IngestPruefEintrag e) => state = state.kopie(zuPruefen: [for (final x in state.zuPruefen) if (x.paketId != e.paketId) x]);

  @override
  Future<void> pruefEintragen(IngestPruefEintrag e) async {
    aufrufe.add('eintragen:${e.paketId}');
    _weg(e);
  }

  @override
  Future<void> verwerfen(IngestPruefEintrag e) async {
    aufrufe.add('verwerfen:${e.paketId}');
    _weg(e);
  }

  @override
  Future<void> erledigt(IngestPruefEintrag e) async {
    aufrufe.add('erledigt:${e.paketId}');
    _weg(e);
  }
}

class FakeIngestDienst implements IngestDienst {
  int laeufe = 0;
  IngestLauf lauf = IngestLauf(zeit: DateTime(2026, 10, 24, 12, 5));

  /// Hält den nächsten Lauf an, bis der Test den Torwächter öffnet (für Entscheidungen WÄHREND eines Laufs).
  Completer<void>? tor;
  final entschieden = <String>[];

  @override
  Future<IngestLauf> abholen() async {
    laeufe++;
    final ergebnis = lauf; // der Stand beim START des Laufs, wie ein Lauf, der vor einer Entscheidung begann
    final t = tor;
    if (t != null) await t.future;
    return ergebnis;
  }

  @override
  Future<void> verwerfen(IngestPruefEintrag e) async => entschieden.add('verwerfen:${e.paketId}');

  @override
  Future<void> pruefEintragen(IngestPruefEintrag e) async => entschieden.add('eintragen:${e.paketId}');

  @override
  Future<void> erledigt(IngestPruefEintrag e) async => entschieden.add('erledigt:${e.paketId}');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

IngestPruefEintrag pruefEintrag({String id = 'p1', PruefGrund grund = PruefGrund.kleiner, int milli = 12400, DateTime? empfangen, String? standText}) => IngestPruefEintrag(
  paketId: id,
  zaehlerId: zStrom,
  kanal: 'strom_bezug',
  tag: DateTime.utc(2026, 10, 24),
  milli: milli,
  einheit: 'kWh',
  grund: grund,
  davorMilli: 2951700,
  tagesVerbrauchMilli: 86000,
  ueblichMilli: 1500,
  empfangen: empfangen,
  standText: standText,
);

