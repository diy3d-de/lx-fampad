// Kartenstil dunkel/hell: Auswahl je Gerät (Gerätewahl, nicht je Person oder Konto; nur lokal, nie auf dem Server, nie synchronisiert), gemerkt in der lokalen Datenbank (`sync_meta`).
// Standard ist dunkel. Die Stile entstehen aus `tools/karte/make-style.mjs` (beide mit denselben Glyphen, eigene Sprites je Thema, nur eigene Adressen).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database_provider.dart';

enum KartenStil {
  dunkel('dunkel', 'assets/karte/style.json'),
  hell('hell', 'assets/karte/style-hell.json');

  /// Wert für die Ablage.
  final String wert;

  /// Stil-Vorlage (Asset, siehe `karteStyleAusVorlage`).
  final String asset;
  const KartenStil(this.wert, this.asset);

  /// Der jeweils andere Stil (Umschalter).
  KartenStil get anderer => this == dunkel ? hell : dunkel;

  bool get istHell => this == hell;

  /// Beschriftung des Umschalters: nennt, was der Knopf bewirkt.
  String get umschaltText => this == dunkel ? 'Helle Karte' : 'Dunkle Karte';

  /// Unbekannte oder fehlende Werte ergeben null (dann gilt der Standard).
  static KartenStil? aus(String? wert) {
    for (final s in KartenStil.values) {
      if (s.wert == wert) return s;
    }
    return null;
  }
}

const kKartenStilStandard = KartenStil.dunkel;

/// Schlüssel in `sync_meta`.
const kKartenStilSchluessel = 'karte_stil';

/// Ablage der Auswahl. Implementierungen dürfen werfen: der Aufrufer fängt es ab (die Karte bleibt benutzbar, die Wahl gilt dann nur bis zum Schließen).
abstract class KartenStilSpeicher {
  Future<String?> lesen();
  Future<void> schreiben(String wert);
}

/// Lokale Datenbank des Geräts (Android und Web).
class DatenbankKartenStilSpeicher implements KartenStilSpeicher {
  final Ref _ref;
  DatenbankKartenStilSpeicher(this._ref);

  @override
  Future<String?> lesen() => _ref.read(appDatabaseProvider).metaLesen(kKartenStilSchluessel);

  @override
  Future<void> schreiben(String wert) => _ref.read(appDatabaseProvider).metaSchreiben(kKartenStilSchluessel, wert);
}

/// Arbeitsspeicher (Tests).
class MemoryKartenStilSpeicher implements KartenStilSpeicher {
  String? wert;
  bool wirft = false;
  MemoryKartenStilSpeicher([this.wert]);

  @override
  Future<String?> lesen() async {
    if (wirft) throw StateError('Speicher nicht verfügbar');
    return wert;
  }

  @override
  Future<void> schreiben(String w) async {
    if (wirft) throw StateError('Speicher nicht verfügbar');
    wert = w;
  }
}

final kartenStilSpeicherProvider = Provider<KartenStilSpeicher>((ref) => DatenbankKartenStilSpeicher(ref));

class KartenStilNotifier extends Notifier<KartenStil> {
  /// Fertig, sobald die gespeicherte Auswahl gelesen ist (die Karte baut erst danach, sonst blitzte erst der falsche Stil auf).
  late Future<void> bereit;
  bool _gesetzt = false;

  @override
  KartenStil build() {
    _gesetzt = false;
    bereit = _laden();
    return kKartenStilStandard;
  }

  Future<void> _laden() async {
    KartenStil? gelesen;
    try {
      gelesen = KartenStil.aus(await ref.read(kartenStilSpeicherProvider).lesen());
    } catch (_) {
      // Ablage nicht lesbar (z. B. Datenbank noch nicht offen): Standard
    }
    // was die Person schon gewählt hat, bevor das Lesen fertig war, bleibt
    if (ref.mounted && !_gesetzt && gelesen != null) state = gelesen;
  }

  Future<void> setzen(KartenStil neu) async {
    _gesetzt = true;
    state = neu;
    try {
      await ref.read(kartenStilSpeicherProvider).schreiben(neu.wert);
    } catch (_) {
      // nicht speicherbar: gilt bis zum Schließen der App
    }
  }

  Future<void> umschalten() => setzen(state.anderer);
}

final kartenStilProvider = NotifierProvider<KartenStilNotifier, KartenStil>(KartenStilNotifier.new);
