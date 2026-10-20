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

/// Zeitpunkt (ms) des letzten Hinweises je Absender: ein Absender, der immer wieder neu startet, löst höchstens alle [kHinweisAbstand] einen Hinweis aus.
String _zeitSchluessel(String von) => 'standort_gemeldet_zeit:$von';

/// Mindestabstand zwischen zwei Hinweisen auf Freigaben derselben Person (gilt auf dem Gerät, unabhängig von der Entprellung des Servers).
const kHinweisAbstand = Duration(minutes: 10);

/// Zeitpunkt (ms) des letzten Kurzabrufs des Standort-Kanals auf diesem Gerät (auch über Prozesse: Hintergrund-Start und laufende App).
const _kAbrufZeit = 'standort_abruf_zeit';

/// Mindestabstand zwischen zwei Kurzabrufen: jeder holt ein WebSocket-Ticket, und die Anmelde-Grenze je IP ist knapp (die Familie teilt oft eine Adresse).
/// Höchstens 2 Tickets je Minute und Gerät; ein längerer Abstand ließ einen Standort-Wecker hinter einem Chat-Wecker kurz davor ohne Abruf.
const kAbrufAbstand = Duration(seconds: 30);

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

  /// Darf jetzt ein Kurzabruf des Standort-Kanals laufen? Höchstens einer je [kAbrufAbstand] und Gerät; der Zeitpunkt wird schon beim Start gebucht,
  /// ein gescheiterter Abruf (Netz, 429) wird also nicht sofort wiederholt.
  Future<bool> abrufErlaubt() async {
    try {
      final jetztMs = jetzt().millisecondsSinceEpoch;
      final letzter = int.tryParse(await db.metaLesen(_kAbrufZeit) ?? '');
      if (letzter != null) {
        final seit = jetztMs - letzter;
        if (seit >= 0 && seit < kAbrufAbstand.inMilliseconds) return false;
      }
      await db.metaSchreiben(_kAbrufZeit, '$jetztMs');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Meldet eine laufende Freigabe von [von] (aus `loc_start`). Idempotent je Freigabe.
  Future<HinweisErgebnis> freigabe({required String von, required String shareId, required DateTime endsAt}) async {
    Future<HinweisErgebnis> ergebnis(String code, HinweisErgebnis e) async {
      await standortDiagnoseSchreiben(db, kDiagHinweis, code, jetzt());
      return e;
    }

    try {
      final me = await ich();
      if (me == null || me == von) return await ergebnis('eigene', HinweisErgebnis.nichts);
      if (!await aktiv()) return await ergebnis('aus', HinweisErgebnis.nichts);
      final rest = endsAt.difference(jetzt());
      if (rest <= Duration.zero) return await ergebnis('abgelaufen', HinweisErgebnis.nichts);
      if (await db.metaLesen(_buchSchluessel(von)) == shareId) return await ergebnis('schon_gemeldet', HinweisErgebnis.nichts);
      // eine andere Freigabe derselben Person kurz nach dem letzten Hinweis: kein neuer Hinweis (sie erscheint in der Liste, sobald die App offen ist)
      final letzter = int.tryParse(await db.metaLesen(_zeitSchluessel(von)) ?? '');
      if (letzter != null) {
        final seit = jetzt().millisecondsSinceEpoch - letzter;
        if (seit >= 0 && seit < kHinweisAbstand.inMilliseconds) return await ergebnis('abstand', HinweisErgebnis.nichts);
      }
      if (istVordergrund()) {
        await db.metaSchreiben(_buchSchluessel(von), shareId);
        await db.metaSchreiben(_zeitSchluessel(von), '${jetzt().millisecondsSinceEpoch}');
        return await ergebnis('im_vordergrund', HinweisErgebnis.vordergrund);
      }
      if (!await anzeige.initialisieren()) return await ergebnis('keine_erlaubnis', HinweisErgebnis.nichts);
      final name = await _name(von);
      final ok = await anzeige.zeigen(
        id: standortBenachrichtigungsId(von),
        titel: 'Standort geteilt',
        text: '$name teilt seinen Standort.',
        sperrbildschirmTitel: await _sperrbildschirmTitel(),
        verfall: rest,
      );
      if (!ok) return await ergebnis('anzeige_fehlgeschlagen', HinweisErgebnis.nichts);
      await db.metaSchreiben(_buchSchluessel(von), shareId);
      await db.metaSchreiben(_zeitSchluessel(von), '${jetzt().millisecondsSinceEpoch}');
      return await ergebnis('gezeigt', HinweisErgebnis.system);
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

  /// Legt den Android-Kanal "Standortfreigaben" an (beim Start der App, wie bei Chat und Terminerinnerungen), damit er in den Systemeinstellungen steht und die Person ihn
  /// einstellen kann, bevor die erste Freigabe kommt. Ohne Erlaubnis für Benachrichtigungen bleibt es beim Kanal; Fehler sind egal.
  Future<void> kanalAnlegen() async {
    try {
      await anzeige.initialisieren();
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

// ---------------------------------------------------------------- Diagnose (ohne Inhalte: nur Zeitpunkt und Code)

/// Schlüssel in sync_meta: letzter Wecker, letzter Abruf des Standort-Kanals, letzte Entscheidung über einen Hinweis.
const kDiagWecker = 'diag_wecker';
const kDiagAbruf = 'diag_abruf';
const kDiagHinweis = 'diag_hinweis';

/// Merkt Zeitpunkt und Code (nie Namen, Kennungen oder Orte). Fehler beim Speichern sind egal.
Future<void> standortDiagnoseSchreiben(AppDatabase db, String schluessel, String code, DateTime zeit) async {
  try {
    await db.metaSchreiben(schluessel, '${zeit.millisecondsSinceEpoch}|$code');
  } catch (_) {}
}

class StandortDiagnoseEintrag {
  final DateTime zeit;
  final String code;
  const StandortDiagnoseEintrag(this.zeit, this.code);

  static StandortDiagnoseEintrag? lesen(String? wert) {
    if (wert == null) return null;
    final i = wert.indexOf('|');
    final ms = int.tryParse(i < 0 ? wert : wert.substring(0, i));
    if (ms == null) return null;
    return StandortDiagnoseEintrag(DateTime.fromMillisecondsSinceEpoch(ms), i < 0 ? '' : wert.substring(i + 1));
  }
}

class StandortDiagnose {
  final StandortDiagnoseEintrag? wecker;
  final StandortDiagnoseEintrag? abruf;
  final StandortDiagnoseEintrag? hinweis;
  const StandortDiagnose({this.wecker, this.abruf, this.hinweis});
}

/// Lesbare Texte zu den Codes (feste Sätze, keine Servertexte).
String standortDiagnoseText(String code) => switch (code) {
  'ok' => 'Verbindung ok, nichts Neues',
  'freigaben' => 'Freigabe(n) abgeholt',
  'aus' => 'Hinweise ausgeschaltet',
  'im_vordergrund' => 'App war offen (Hinweis in der App)',
  'gestartet' => 'gestartet, aber nicht zu Ende gekommen (Android hat den Hintergrund-Start beendet?)',
  'gedrosselt' => 'übersprungen: vor weniger als 30 Sekunden schon abgefragt',
  'keine_verbindung' => 'keine Verbindung (Netz oder Anmeldung abgelaufen: öffne die App einmal)',
  'fehler' => 'Fehler',
  'gezeigt' => 'Benachrichtigung gezeigt',
  'schon_gemeldet' => 'schon gemeldet',
  'abstand' => 'unterdrückt: weniger als 10 Minuten nach dem letzten Hinweis dieser Person',
  'abgelaufen' => 'Freigabe schon abgelaufen',
  'eigene' => 'eigene Freigabe',
  'keine_erlaubnis' => 'Android zeigt keine Benachrichtigungen (Erlaubnis oder Kanal aus)',
  'anzeige_fehlgeschlagen' => 'Anzeige fehlgeschlagen',
  _ => code,
};

final standortDiagnoseProvider = FutureProvider.autoDispose<StandortDiagnose>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  try {
    return StandortDiagnose(
      wecker: StandortDiagnoseEintrag.lesen(await db.metaLesen(kDiagWecker)),
      abruf: StandortDiagnoseEintrag.lesen(await db.metaLesen(kDiagAbruf)),
      hinweis: StandortDiagnoseEintrag.lesen(await db.metaLesen(kDiagHinweis)),
    );
  } catch (_) {
    return const StandortDiagnose();
  }
});

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
