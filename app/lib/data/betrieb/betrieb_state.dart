// Zustand der Betreiber-Ansicht (nur lesend, nur im Arbeitsspeicher; nichts davon wird lokal gespeichert oder synchronisiert).
// Status: eine Abfrage beim Öffnen und auf Wunsch ("Prüfung neu starten"). Protokoll: seitenweise, mit Filter; braucht ein frisches Step-up,
// das die Oberfläche über `mitStepUp` anstößt (die Methoden werfen dafür die ApiException weiter).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import 'betrieb_modelle.dart';

class BetriebStatusZustand {
  final BetriebStatus? status;
  final bool laedt;

  /// Die letzte Abfrage ist gescheitert (die Oberfläche macht daraus den Text über fehlerText, nie ein Servertext).
  final Object? fehler;
  const BetriebStatusZustand({this.status, this.laedt = false, this.fehler});
}

class BetriebStatusNotifier extends Notifier<BetriebStatusZustand> {
  bool _laeuft = false;

  @override
  BetriebStatusZustand build() => const BetriebStatusZustand();

  Future<void> laden({bool frisch = false}) async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = BetriebStatusZustand(status: state.status, laedt: true);
    try {
      final s = await ref.read(apiProvider).betriebStatus(frisch: frisch);
      if (ref.mounted) state = BetriebStatusZustand(status: s);
    } on ApiException catch (e) {
      if (ref.mounted) state = BetriebStatusZustand(status: state.status, fehler: e);
    } on Object {
      if (ref.mounted) state = BetriebStatusZustand(status: state.status, fehler: ApiException.unerwarteteAntwort);
    } finally {
      _laeuft = false;
    }
  }
}

final betriebStatusProvider = NotifierProvider.autoDispose<BetriebStatusNotifier, BetriebStatusZustand>(BetriebStatusNotifier.new);

class BetriebProtokollZustand {
  final ProtokollArt art;
  final List<ProtokollEintrag> eintraege;
  final String? weiter;
  final bool laedt;
  final bool geladen;
  final Object? fehler;
  const BetriebProtokollZustand({this.art = ProtokollArt.alle, this.eintraege = const [], this.weiter, this.laedt = false, this.geladen = false, this.fehler});

  BetriebProtokollZustand mit({ProtokollArt? art, List<ProtokollEintrag>? eintraege, String? weiter, bool? laedt, bool? geladen, Object? fehler, bool weiterLoeschen = false, bool fehlerLoeschen = false}) =>
      BetriebProtokollZustand(
        art: art ?? this.art,
        eintraege: eintraege ?? this.eintraege,
        weiter: weiterLoeschen ? null : (weiter ?? this.weiter),
        laedt: laedt ?? this.laedt,
        geladen: geladen ?? this.geladen,
        fehler: fehlerLoeschen ? null : (fehler ?? this.fehler),
      );
}

class BetriebProtokollNotifier extends Notifier<BetriebProtokollZustand> {
  bool _laeuft = false;
  // Zählt Filterwechsel: eine späte Antwort zu einem alten Filter wird verworfen
  int _lauf = 0;

  @override
  BetriebProtokollZustand build() => const BetriebProtokollZustand();

  /// Lädt die erste Seite (optional mit neuem Filter). Wirft [ApiException], wenn ein Step-up nötig ist (die Oberfläche fragt ihn ab und ruft erneut auf);
  /// andere Fehler landen im Zustand.
  Future<void> laden({ProtokollArt? art}) async {
    final neueArt = art ?? state.art;
    if (art != null && art != state.art) {
      _lauf++;
      _laeuft = false;
      state = BetriebProtokollZustand(art: art);
    }
    await _holen(neueArt, ersteSeite: true);
  }

  Future<void> mehr() async {
    final cursor = state.weiter;
    if (cursor == null) return;
    await _holen(state.art, ersteSeite: false, cursor: cursor);
  }

  Future<void> _holen(ProtokollArt art, {required bool ersteSeite, String? cursor}) async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    final lauf = _lauf;
    state = state.mit(laedt: true, fehlerLoeschen: true);
    try {
      final seite = await ref.read(apiProvider).betriebProtokoll(art: art, weiter: cursor);
      if (!ref.mounted || lauf != _lauf) return;
      state = state.mit(
        eintraege: ersteSeite ? seite.eintraege : [...state.eintraege, ...seite.eintraege],
        weiter: seite.weiter,
        weiterLoeschen: seite.weiter == null,
        laedt: false,
        geladen: true,
      );
    } on ApiException catch (e) {
      if (ref.mounted && lauf == _lauf) state = state.mit(laedt: false);
      if (e.istStepUp) rethrow;
      if (ref.mounted && lauf == _lauf) state = state.mit(fehler: e);
    } on Object {
      if (ref.mounted && lauf == _lauf) state = state.mit(laedt: false, fehler: ApiException.unerwarteteAntwort);
    } finally {
      if (lauf == _lauf) _laeuft = false;
    }
  }
}

final betriebProtokollProvider = NotifierProvider.autoDispose<BetriebProtokollNotifier, BetriebProtokollZustand>(BetriebProtokollNotifier.new);
