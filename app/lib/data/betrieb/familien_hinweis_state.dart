// Familienhinweis und Wartung auf dem Gerät (Betrieb, Paket 2b): Die App fragt `GET /family-notice` (beim Start der angemeldeten Oberfläche, bei der Rückkehr in die
// App, nach einem Abgleich mit Wartung und danach alle fünf Minuten) und zeigt den Hinweis des Betreibers als Banner an alle. Der Hinweis ist reiner Text, lässt sich
// je Gerät wegklicken (gemerkt wird die Version = Zeitpunkt des Setzens, ein neu gesetzter Hinweis erscheint also wieder) und läuft zum Ablaufzeitpunkt von selbst ab.
// Die Wartung zeigt die App als eigenen Banner (nicht wegklickbar). Alles ist ein Zusatz: scheitert die Abfrage (offline, älterer Server), bleibt der letzte Stand.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../sync_state.dart';
import 'familien_stand.dart';

/// `sync_meta`-Schlüssel (Vorspann): Version (ISO-Zeit) des Hinweises, den die Person auf diesem Gerät weggeklickt hat. Je Person ein eigener Schlüssel: auf einem geteilten
/// Gerät blendet das Wegklicken einer Person den Hinweis nicht für die nächste aus.
const kHinweisGeschlossenSchluessel = 'familienHinweisGeschlossen';

String hinweisGeschlossenSchluessel(String userId) => '$kHinweisGeschlossenSchluessel:$userId';

/// Abstand der erneuten Abfrage; null = keine (nur Tests, damit kein Timer stehen bleibt).
final familienHinweisTaktProvider = Provider<Duration?>((ref) => const Duration(minutes: 5));

class FamilienHinweisZustand {
  final FamilienStand? stand;

  /// Version des zuletzt weggeklickten Hinweises (null: keiner).
  final DateTime? geschlossen;
  const FamilienHinweisZustand({this.stand, this.geschlossen});

  bool get wartung => stand?.wartung.aktiv ?? false;

  /// Der Hinweis, der jetzt angezeigt wird: vorhanden, nicht abgelaufen und nicht weggeklickt (ein neu gesetzter Hinweis hat eine neuere Version).
  FamilienHinweis? sichtbar(DateTime jetzt) {
    final h = stand?.hinweis;
    if (h == null) return null;
    if (h.ablauf != null && !h.ablauf!.isAfter(jetzt)) return null;
    final zu = geschlossen;
    if (zu != null && !h.version.isAfter(zu)) return null;
    return h;
  }

  FamilienHinweisZustand mit({FamilienStand? stand, DateTime? geschlossen}) => FamilienHinweisZustand(stand: stand ?? this.stand, geschlossen: geschlossen ?? this.geschlossen);
}

class FamilienHinweisNotifier extends Notifier<FamilienHinweisZustand> {
  Timer? _timer;
  bool _laeuft = false;
  bool _gestartet = false;
  String? _userId;

  /// Zählt die Neuaufbauten (Personenwechsel, Abmelden): eine Antwort oder ein Lauf einer früheren Person darf nichts mehr ändern.
  int _generation = 0;

  @override
  FamilienHinweisZustand build() {
    // je angemeldeter Person neu (Abmelden, Personenwechsel): kein Hinweis der vorigen Person, kein laufender Lauf, keine Antwort der vorigen Person
    _userId = ref.watch(authProvider.select((s) => s.user?.id));
    _generation++;
    _laeuft = false;
    _timer?.cancel();
    _timer = null;
    ref.onDispose(() => _timer?.cancel());
    // Wartung beginnt oder endet (der Abgleich merkt es zuerst): Stand sofort holen, damit der Banner stimmt
    ref.listen(syncProvider.select((s) => s.status == SyncStatus.wartung), (alt, neu) {
      if (alt != neu && _gestartet) unawaited(laden());
    });
    _gestartet = false;
    return const FamilienHinweisZustand();
  }

  /// Beim Start der angemeldeten Oberfläche: gemerkten Stand lesen, dann abfragen.
  Future<void> starten() async {
    final userId = _userId;
    if (!ref.mounted || userId == null) return;
    final gen = _generation;
    _gestartet = true;
    try {
      final roh = await ref.read(appDatabaseProvider).metaLesen(hinweisGeschlossenSchluessel(userId));
      final zu = roh == null ? null : DateTime.tryParse(roh);
      if (ref.mounted && gen == _generation && zu != null) state = state.mit(geschlossen: zu);
    } on Object {
      // Ablage nicht lesbar: der Hinweis erscheint (schlimmstenfalls noch einmal)
    }
    if (gen != _generation) return;
    await laden();
  }

  /// Fragt den Stand ab. Fehler (offline, ältere Server ohne die Route) ändern nichts: der letzte Stand bleibt.
  Future<void> laden() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    final gen = _generation;
    try {
      final stand = await ref.read(apiProvider).familienStand();
      // die Person hat inzwischen gewechselt (oder sich abgemeldet): die Antwort gehört zur vorigen Person
      if (ref.mounted && gen == _generation) state = FamilienHinweisZustand(stand: stand, geschlossen: state.geschlossen);
    } on ApiException {
      // der Stand bleibt
    } on Object {
      // unerwartete Antwort: der Stand bleibt
    } finally {
      // ein neuer Aufbau (Personenwechsel) hat Lauf und Zeitgeber schon zurückgesetzt: dann nichts mehr anfassen
      if (gen == _generation) _laeuft = false;
      final takt = ref.mounted && _gestartet && gen == _generation ? ref.read(familienHinweisTaktProvider) : null;
      if (takt != null) {
        _timer?.cancel();
        _timer = Timer(takt, () => unawaited(laden()));
      }
    }
  }

  /// Blendet den aktuellen Hinweis auf diesem Gerät aus (gemerkt wird seine Version).
  Future<void> schliessen() async {
    final h = state.stand?.hinweis;
    final userId = _userId;
    if (h == null) return;
    state = state.mit(geschlossen: h.version);
    if (userId == null) return;
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(hinweisGeschlossenSchluessel(userId), h.version.toUtc().toIso8601String());
    } on Object {
      // nicht speicherbar: gilt bis zum Schließen der App
    }
  }

  void stoppen() {
    _gestartet = false;
    _timer?.cancel();
    _timer = null;
  }
}

final familienHinweisProvider = NotifierProvider<FamilienHinweisNotifier, FamilienHinweisZustand>(FamilienHinweisNotifier.new);
