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

// ------------------------------------------------------------------ Paket 2a: Schlüssel-Ampel, Warnungen, Mitglieder und Geräte

/// Ein Teil der Übersicht, der alt gewordene oder fehlende Angaben des Servers verträgt: scheitert die Abfrage (älterer Server: 404), bleibt [fehler] gesetzt und die
/// Übersicht zeigt "nicht verfügbar" statt einer Fehlermeldung über der ganzen Seite.
class BetriebTeilZustand<T> {
  final T? wert;
  final bool laedt;
  final Object? fehler;
  const BetriebTeilZustand({this.wert, this.laedt = false, this.fehler});
}

class BetriebSchluesselNotifier extends Notifier<BetriebTeilZustand<SchluesselStatus>> {
  bool _laeuft = false;

  @override
  BetriebTeilZustand<SchluesselStatus> build() => const BetriebTeilZustand();

  Future<void> laden() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = BetriebTeilZustand(wert: state.wert, laedt: true);
    try {
      final s = await ref.read(apiProvider).betriebSchluesselStatus();
      if (ref.mounted) state = BetriebTeilZustand(wert: s);
    } on ApiException catch (e) {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: e);
    } on Object {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: ApiException.unerwarteteAntwort);
    } finally {
      _laeuft = false;
    }
  }
}

final betriebSchluesselProvider = NotifierProvider.autoDispose<BetriebSchluesselNotifier, BetriebTeilZustand<SchluesselStatus>>(BetriebSchluesselNotifier.new);

class BetriebWarnungenNotifier extends Notifier<BetriebTeilZustand<BetriebWarnungen>> {
  bool _laeuft = false;

  @override
  BetriebTeilZustand<BetriebWarnungen> build() => const BetriebTeilZustand();

  Future<void> laden() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = BetriebTeilZustand(wert: state.wert, laedt: true);
    try {
      final w = await ref.read(apiProvider).betriebWarnungen();
      if (ref.mounted) state = BetriebTeilZustand(wert: w);
    } on ApiException catch (e) {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: e);
    } on Object {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: ApiException.unerwarteteAntwort);
    } finally {
      _laeuft = false;
    }
  }

  /// Schaltet die Warnungen ein oder aus. Braucht ein frisches Step-up: die ApiException geht weiter (die Oberfläche fragt ab und ruft erneut auf).
  Future<void> setzen(bool an) async {
    final w = await ref.read(apiProvider).betriebWarnungenSetzen(an);
    if (ref.mounted) state = BetriebTeilZustand(wert: w);
  }
}

final betriebWarnungenProvider = NotifierProvider.autoDispose<BetriebWarnungenNotifier, BetriebTeilZustand<BetriebWarnungen>>(BetriebWarnungenNotifier.new);

/// Verlauf (Nutzung): die gewählte Spanne in Tagen und die geladenen Messpunkte. Scheitert die Abfrage (älterer Server: 404), bleibt [fehler] gesetzt.
class BetriebVerlaufZustand {
  final int tage;
  final BetriebVerlauf? wert;
  final bool laedt;
  final Object? fehler;
  const BetriebVerlaufZustand({this.tage = 30, this.wert, this.laedt = false, this.fehler});
}

/// Wählbare Spannen des Verlaufs in Tagen.
const kVerlaufSpannen = <int>[7, 30, 90, 365];

class BetriebVerlaufNotifier extends Notifier<BetriebVerlaufZustand> {
  bool _laeuft = false;
  // Zählt Spannenwechsel: eine späte Antwort zu einer alten Spanne wird verworfen
  int _lauf = 0;

  @override
  BetriebVerlaufZustand build() => const BetriebVerlaufZustand();

  /// Lädt den Verlauf, optional mit neuer Spanne.
  Future<void> laden({int? tage}) async {
    final neu = tage ?? state.tage;
    if (tage != null && tage != state.tage) {
      _lauf++;
      _laeuft = false;
      state = BetriebVerlaufZustand(tage: tage);
    }
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    final lauf = _lauf;
    state = BetriebVerlaufZustand(tage: neu, wert: state.wert, laedt: true);
    try {
      final v = await ref.read(apiProvider).betriebVerlauf(tage: neu);
      if (ref.mounted && lauf == _lauf) state = BetriebVerlaufZustand(tage: neu, wert: v);
    } on ApiException catch (e) {
      if (ref.mounted && lauf == _lauf) state = BetriebVerlaufZustand(tage: neu, wert: state.wert, fehler: e);
    } on Object {
      if (ref.mounted && lauf == _lauf) state = BetriebVerlaufZustand(tage: neu, wert: state.wert, fehler: ApiException.unerwarteteAntwort);
    } finally {
      if (lauf == _lauf) _laeuft = false;
    }
  }
}

final betriebVerlaufProvider = NotifierProvider.autoDispose<BetriebVerlaufNotifier, BetriebVerlaufZustand>(BetriebVerlaufNotifier.new);

class BetriebMitgliederZustand {
  final List<BetriebMitglied> mitglieder;
  final bool geladen;
  final bool laedt;
  final Object? fehler;
  const BetriebMitgliederZustand({this.mitglieder = const [], this.geladen = false, this.laedt = false, this.fehler});
}

class BetriebMitgliederNotifier extends Notifier<BetriebMitgliederZustand> {
  bool _laeuft = false;

  @override
  BetriebMitgliederZustand build() => const BetriebMitgliederZustand();

  /// Lädt Mitglieder und Geräte. Wirft [ApiException], wenn ein Step-up nötig ist (die Oberfläche fragt ab und ruft erneut auf); andere Fehler landen im Zustand.
  Future<void> laden() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = BetriebMitgliederZustand(mitglieder: state.mitglieder, geladen: state.geladen, laedt: true);
    try {
      final m = await ref.read(apiProvider).betriebMitglieder();
      if (ref.mounted) state = BetriebMitgliederZustand(mitglieder: m.mitglieder, geladen: true);
    } on ApiException catch (e) {
      if (ref.mounted) state = BetriebMitgliederZustand(mitglieder: state.mitglieder, geladen: state.geladen);
      if (e.istStepUp) rethrow;
      if (ref.mounted) state = BetriebMitgliederZustand(mitglieder: state.mitglieder, geladen: state.geladen, fehler: e);
    } on Object {
      if (ref.mounted) state = BetriebMitgliederZustand(mitglieder: state.mitglieder, geladen: state.geladen, fehler: ApiException.unerwarteteAntwort);
    } finally {
      _laeuft = false;
    }
  }

  /// Hebt die Anmeldesperre eines Kontos auf (Step-up: die ApiException geht weiter) und lädt danach neu.
  Future<void> entsperren(String id) async {
    await ref.read(apiProvider).betriebEntsperren(id);
    _laeuft = false;
    await laden();
  }
}

final betriebMitgliederProvider = NotifierProvider.autoDispose<BetriebMitgliederNotifier, BetriebMitgliederZustand>(BetriebMitgliederNotifier.new);
