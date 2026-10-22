// Zustand der Seite "Einstellungen" im Bereich Betrieb (Paket 2b): Konfiguration (nur lesend), Wartungsmodus und Familienhinweis (schreibend, mit Step-up).
// Nur im Arbeitsspeicher; die Schreibmethoden werfen die ApiException weiter (die Oberfläche fragt bei Bedarf das Step-up ab und ruft erneut auf).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import 'betrieb_state.dart';
import 'familien_hinweis_state.dart';
import 'familien_stand.dart';

class BetriebKonfigurationNotifier extends Notifier<BetriebTeilZustand<BetriebKonfiguration>> {
  bool _laeuft = false;

  @override
  BetriebTeilZustand<BetriebKonfiguration> build() => const BetriebTeilZustand();

  Future<void> laden() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = BetriebTeilZustand(wert: state.wert, laedt: true);
    try {
      final k = await ref.read(apiProvider).betriebKonfiguration();
      if (ref.mounted) state = BetriebTeilZustand(wert: k);
    } on ApiException catch (e) {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: e);
    } on Object {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: ApiException.unerwarteteAntwort);
    } finally {
      _laeuft = false;
    }
  }
}

final betriebKonfigurationProvider = NotifierProvider.autoDispose<BetriebKonfigurationNotifier, BetriebTeilZustand<BetriebKonfiguration>>(BetriebKonfigurationNotifier.new);

class BetriebEinstellungenNotifier extends Notifier<BetriebTeilZustand<FamilienStand>> {
  bool _laeuft = false;

  @override
  BetriebTeilZustand<FamilienStand> build() => const BetriebTeilZustand();

  Future<void> laden() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = BetriebTeilZustand(wert: state.wert, laedt: true);
    try {
      final s = await ref.read(apiProvider).betriebEinstellungen();
      if (ref.mounted) state = BetriebTeilZustand(wert: s);
    } on ApiException catch (e) {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: e);
    } on Object {
      if (ref.mounted) state = BetriebTeilZustand(wert: state.wert, fehler: ApiException.unerwarteteAntwort);
    } finally {
      _laeuft = false;
    }
  }

  /// Schaltet den Wartungsmodus (Step-up: die ApiException geht weiter). Danach holt das Gerät den Stand für den eigenen Banner neu.
  Future<void> wartungSetzen(bool an, {Duration? dauer}) async {
    final s = await ref.read(apiProvider).betriebWartungSetzen(an, dauer: dauer);
    if (!ref.mounted) return;
    state = BetriebTeilZustand(wert: s);
    unawaited(ref.read(familienHinweisProvider.notifier).laden());
  }

  /// Setzt ([text]) oder löscht (null) den Familienhinweis (Step-up: die ApiException geht weiter).
  Future<void> hinweisSetzen(String? text, {Duration? ablauf}) async {
    final s = await ref.read(apiProvider).betriebHinweisSetzen(text, ablauf: ablauf);
    if (!ref.mounted) return;
    state = BetriebTeilZustand(wert: s);
    unawaited(ref.read(familienHinweisProvider.notifier).laden());
  }
}

final betriebEinstellungenProvider = NotifierProvider.autoDispose<BetriebEinstellungenNotifier, BetriebTeilZustand<FamilienStand>>(BetriebEinstellungenNotifier.new);
