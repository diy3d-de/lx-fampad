// Hinweis "Name teilt seinen Standort": entsteht auf diesem Gerät, nie auf dem Server. Der Push-Wecker, der ihn auslöst, enthält nichts (kein Name, kein Titel);
// die App fragt den Standort-Kanal kurz ab (standort_abruf.dart) bzw. bekommt `loc_start` über ihre Verbindung und zeigt dann selbst eine lokale
// Benachrichtigung ohne Standort und ohne Positionsdaten: nur "Standort geteilt" und den Namen aus der lokalen Mitgliederliste.
//
//  - Einstellung "Standortfreigaben melden" (Standard an) liegt nur auf diesem Gerät; der Server erfährt sie nicht (er weckt immer, die App unterdrückt).
//  - Eine Freigabe wird je Absender und Kennung nur einmal gemeldet (Buch in der lokalen Datenbank): erneutes Nachreichen beim Wiederverbinden meldet nichts.
//  - Im Vordergrund gibt es keine System-Benachrichtigung, sondern einen dezenten Hinweis in der App (Snackbar), außer die Standort-Seite ist selbst offen.
//  - Auf dem Sperrbildschirm bleibt die Benachrichtigung privat (Android verbirgt Titel und Text), außer die Person hat "Titel auf dem Sperrbildschirm
//    zeigen" (Erinnerungen) eingeschaltet.
//  - Die Benachrichtigung verschwindet, wenn die Freigabe endet oder die Person die Standort-Seite öffnet.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart';
import '../database_provider.dart';
import '../erinnerungen/erinnerung_einstellungen.dart';
import '../lists/members.dart';
import 'standort_anzeige_port_stub.dart' if (dart.library.io) 'standort_anzeige_port_io.dart';

/// Schnittstelle zum Betriebssystem für die Benachrichtigung über eine Freigabe (Android: eigener Kanal "Standortfreigaben"; Web und Tests: ohne Wirkung bzw. Fake).
abstract class StandortAnzeigePort {
  /// Bereitet Kanal und Plugin vor. false: nicht verfügbar (Web) oder keine Erlaubnis.
  Future<bool> initialisieren();

  /// Zeigt (oder ersetzt) die Benachrichtigung [id]; [verfall]: danach verschwindet sie von selbst (Ende der Freigabe).
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, Duration? verfall});

  /// Entfernt die Benachrichtigung [id]; eine nicht vorhandene ist kein Fehler.
  Future<void> entfernen(int id);

  /// Entfernt alle Standort-Benachrichtigungen dieser App.
  Future<void> alleEntfernen();
}

class KeineStandortAnzeige implements StandortAnzeigePort {
  const KeineStandortAnzeige();

  @override
  Future<bool> initialisieren() async => false;

  @override
  Future<bool> zeigen({required int id, required String titel, required String text, required bool sperrbildschirmTitel, Duration? verfall}) async => false;

  @override
  Future<void> entfernen(int id) async {}

  @override
  Future<void> alleEntfernen() async {}
}

/// Wert, mit dem das Tippen auf die Benachrichtigung die Standort-Seite öffnet (siehe ErinnerungDienst).
const kStandortPayload = 'standort';

/// Bereich der Benachrichtigungs-Kennungen dieser Art (oberhalb der Chat-Kennungen, 0x100000 bis 0x4fffff).
const int kStandortIdBasis = 0x500000;
const int kStandortIdBereich = 0x100000;

/// Stabile Kennung je Absender: eine neue Freigabe derselben Person ersetzt die Benachrichtigung statt zu stapeln.
int standortBenachrichtigungsId(String userId) {
  var h = 17;
  for (final c in userId.codeUnits) {
    h = (h * 31 + c) & (kStandortIdBereich - 1);
  }
  return kStandortIdBasis + h;
}

/// Buch der gemeldeten Freigaben (Absender -> Kennung der Freigabe) in der lokalen Datenbank.
String _buchSchluessel(String von) => 'standort_gemeldet:$von';

enum HinweisErgebnis {
  /// Nichts zu melden (aus, schon gemeldet, abgelaufen, eigene Freigabe, keine Erlaubnis).
  nichts,

  /// Als System-Benachrichtigung gezeigt.
  system,

  /// Die App ist im Vordergrund: die Oberfläche zeigt einen dezenten Hinweis.
  vordergrund,
}

class StandortBenachrichtiger {
  final AppDatabase db;
  final StandortAnzeigePort anzeige;
  final ErinnerungSpeicher speicher;

  /// Die angemeldete Person (aus der lokalen Datenbank: auch ohne laufende Oberfläche, im Hintergrund-Start).
  final Future<String?> Function() ich;

  /// Ist die App gerade im Vordergrund?
  final bool Function() istVordergrund;
  final DateTime Function() jetzt;

  StandortBenachrichtiger({required this.db, required this.anzeige, required this.speicher, required this.ich, required this.istVordergrund, DateTime Function()? jetzt}) : jetzt = jetzt ?? DateTime.now;

  /// Sind die Hinweise eingeschaltet (Standard: ja)?
  Future<bool> aktiv() async {
    try {
      return (await speicher.lesen())[kStandortHinweisSchluessel] != 'aus';
    } catch (_) {
      return true;
    }
  }

  Future<bool> _sperrbildschirmTitel() async {
    try {
      return (await speicher.lesen())[kSperrbildschirmSchluessel] == 'ja';
    } catch (_) {
      return false;
    }
  }

  /// Meldet eine laufende Freigabe von [von] (aus `loc_start`). Idempotent je Freigabe.
  Future<HinweisErgebnis> freigabe({required String von, required String shareId, required DateTime endsAt}) async {
    try {
      final me = await ich();
      if (me == null || me == von) return HinweisErgebnis.nichts;
      if (!await aktiv()) return HinweisErgebnis.nichts;
      final rest = endsAt.difference(jetzt());
      if (rest <= Duration.zero) return HinweisErgebnis.nichts;
      if (await db.metaLesen(_buchSchluessel(von)) == shareId) return HinweisErgebnis.nichts;
      if (istVordergrund()) {
        await db.metaSchreiben(_buchSchluessel(von), shareId);
        return HinweisErgebnis.vordergrund;
      }
      if (!await anzeige.initialisieren()) return HinweisErgebnis.nichts;
      final name = await _name(von);
      final ok = await anzeige.zeigen(
        id: standortBenachrichtigungsId(von),
        titel: 'Standort geteilt',
        text: '$name teilt seinen Standort.',
        sperrbildschirmTitel: await _sperrbildschirmTitel(),
        verfall: rest,
      );
      if (!ok) return HinweisErgebnis.nichts;
      await db.metaSchreiben(_buchSchluessel(von), shareId);
      return HinweisErgebnis.system;
    } catch (_) {
      return HinweisErgebnis.nichts; // eine Benachrichtigung ist Zusatz: nie den Ablauf stören
    }
  }

  /// Die Freigabe von [von] ist beendet: die Benachrichtigung verschwindet.
  Future<void> beendet(String von) async {
    try {
      await anzeige.entfernen(standortBenachrichtigungsId(von));
    } catch (_) {}
  }

  /// Die Person hat die Standort-Seite geöffnet: alle Hinweise sind erledigt.
  Future<void> alleEntfernen() async {
    try {
      await anzeige.alleEntfernen();
    } catch (_) {}
  }

  /// Name der Person aus der lokalen Mitgliederliste (nie vom Server in der Freigabe); unbekannt: "Jemand".
  Future<String> name(String userId) => _name(userId);

  Future<String> _name(String userId) async {
    try {
      final m = Mitglieder(mitgliederAusSpeicher(await db.metaLesen('members')));
      final n = m[userId]?.displayName.trim();
      if (n != null && n.isNotEmpty) return n;
    } catch (_) {}
    return 'Jemand';
  }
}

final standortAnzeigePortProvider = Provider<StandortAnzeigePort>((ref) => standortAnzeigePortErzeugen());

final standortBenachrichtigerProvider = Provider<StandortBenachrichtiger>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return StandortBenachrichtiger(
    db: db,
    anzeige: ref.watch(standortAnzeigePortProvider),
    speicher: ref.watch(erinnerungSpeicherProvider),
    ich: () async {
      try {
        return await db.besitzerLesen();
      } catch (_) {
        return null;
      }
    },
    istVordergrund: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
  );
});

/// Einstellung "Standortfreigaben melden" (nur dieses Gerät).
class StandortHinweisAn extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref.read(standortBenachrichtigerProvider).aktiv();

  Future<void> setzen(bool an) async {
    state = AsyncData(an);
    try {
      await ref.read(erinnerungSpeicherProvider).schreiben(kStandortHinweisSchluessel, an ? 'an' : 'aus');
    } catch (_) {
      // nicht speicherbar: gilt bis zum Neustart der App
    }
  }
}

final standortHinweisAnProvider = AsyncNotifierProvider<StandortHinweisAn, bool>(StandortHinweisAn.new);

/// Ein Hinweis für die Oberfläche (Snackbar im Vordergrund).
class StandortHinweis {
  final String von;
  final int nr;
  const StandortHinweis(this.von, this.nr);
}

class StandortHinweisNotifier extends Notifier<StandortHinweis?> {
  int _nr = 0;

  @override
  StandortHinweis? build() => null;

  void melden(String von) => state = StandortHinweis(von, ++_nr);
}

final standortHinweisProvider = NotifierProvider<StandortHinweisNotifier, StandortHinweis?>(StandortHinweisNotifier.new);

/// Ist die Standort-Seite (gepusht) gerade offen? Dann gibt es keinen Hinweis: die Person sieht es dort selbst.
class StandortSeiteOffen extends Notifier<bool> {
  @override
  bool build() => false;

  void setzen(bool offen) => state = offen;
}

final standortSeiteOffenProvider = NotifierProvider<StandortSeiteOffen, bool>(StandortSeiteOffen.new);

/// Anforderung, die Standort-Seite zu öffnen (Tipp auf die Benachrichtigung oder "Ansehen" im Hinweis); die Shell reagiert darauf.
class StandortOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final standortOeffnenProvider = NotifierProvider<StandortOeffnenAnforderung, int>(StandortOeffnenAnforderung.new);
