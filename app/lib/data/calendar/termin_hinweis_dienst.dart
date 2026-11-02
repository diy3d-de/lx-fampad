// Dienst für die Hinweise auf neue und geänderte Termine (Abschnitt 6r): nach einem erfolgreichen Abgleich vergleicht er die Termine mit dem Stand von
// VOR dem Abgleich und zeigt höchstens EINE neutrale lokale Benachrichtigung je Lauf. Rein lokal: kein Server, kein Schema, nie Inhalt im Wecker, im Log
// oder im Push. Läuft im Vordergrund und im Hintergrund-Start (beide benutzen dieselbe Abgleich-Engine).
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart' show kAppName;
import '../app_database.dart';
import '../database_provider.dart';
import '../erinnerungen/browser_benachrichtigung.dart';
import '../erinnerungen/erinnerung_einstellungen.dart';
import '../erinnerungen/web_erinnerung_port.dart' show kWebAnSchluessel;
import '../erinnerungen/web_erinnerung_state.dart' show browserBenachrichtigungProvider;
import '../sync/sync_engine.dart' show AbgleichBeobachter;
import '../wandtablet/wandtablet_einstellungen.dart' show wandtabletLaeuftProvider;
import 'feiertage.dart' show AnzeigeSchalter, feiertageSpeicherProvider;
import 'termin_hinweis_logik.dart';
import 'termin_hinweis_port_stub.dart' if (dart.library.io) 'termin_hinweis_port_android.dart';

/// Schalter "Hinweise auf neue und geänderte Termine" (lokal je Gerät in `sync_meta`; Standard: an, nur der Wert `nein` schaltet aus).
const kTerminHinweiseSchluessel = 'termin_hinweise';

/// Schalter der Oberfläche (Profil > Benachrichtigungen), Standard an.
class TerminHinweiseAnNotifier extends AnzeigeSchalter {
  @override
  String get schluessel => kTerminHinweiseSchluessel;
}

final terminHinweiseAnProvider = NotifierProvider<TerminHinweiseAnNotifier, bool>(TerminHinweiseAnNotifier.new);

/// Kennung der (einen) Benachrichtigung; kleiner als `kErinnerungIdMin`, also nie die einer Erinnerung (1 und 2 sind schon vergeben).
const kTerminHinweisId = 3;

/// Anzeige der Hinweise (Android: lokale Benachrichtigung, Web: Browser-Benachrichtigung, Tests: Fake). Nie eine Ausnahme nach außen.
abstract class TerminHinweisAnzeige {
  /// Zeigt EINE Meldung für [treffer]. [mitTitel]: der Titel eines einzelnen Termins darf erscheinen (nur Android; das Web ist immer neutral).
  /// [sperrbildschirmTitel]: Text darf auf dem Sperrbildschirm erscheinen. Gibt false zurück, wenn nichts angezeigt wurde.
  Future<bool> zeigen(List<TerminTreffer> treffer, {required bool mitTitel, required bool sperrbildschirmTitel});
}

class KeineTerminHinweisAnzeige implements TerminHinweisAnzeige {
  const KeineTerminHinweisAnzeige();

  @override
  Future<bool> zeigen(List<TerminTreffer> treffer, {required bool mitTitel, required bool sperrbildschirmTitel}) async => false;
}

/// Web: Browser-Benachrichtigung, nur mit Erlaubnis und nur, solange die Web-App offen ist (wie die Web-Erinnerungen), immer mit neutralem Text.
class WebTerminHinweisAnzeige implements TerminHinweisAnzeige {
  final BrowserBenachrichtigung browser;
  final Future<bool> Function() webAn;
  final void Function() beiKlick;
  WebTerminHinweisAnzeige({required this.browser, required this.webAn, required this.beiKlick});

  @override
  Future<bool> zeigen(List<TerminTreffer> treffer, {required bool mitTitel, required bool sperrbildschirmTitel}) async {
    try {
      if (!await webAn() || browser.erlaubnis() != BrowserErlaubnis.erlaubt) return false;
      browser.zeigen(titel: kAppName, text: terminHinweisWebText(treffer), tag: 'fampad-termine', beiKlick: beiKlick);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Stand zu Beginn eines Abgleichs.
class _Vorher {
  final TerminStand stand;
  final int basisRev;
  final String? ich;
  const _Vorher(this.stand, this.basisRev, this.ich);
}

class TerminHinweisDienst implements AbgleichBeobachter {
  final AppDatabase db;
  final TerminHinweisAnzeige anzeige;
  final Future<bool> Function() an;
  final Future<bool> Function() sperrbildschirmTitel;
  final bool Function() wandtablet;
  TerminHinweisDienst({required this.db, required this.anzeige, required this.an, required this.sperrbildschirmTitel, required this.wandtablet});

  @override
  Future<Object?> vor({required int sinceRev}) async {
    try {
      if (!await an()) return null;
      final ich = await db.besitzerLesen();
      if (ich == null) return null;
      return _Vorher(terminStandAus(await db.select(db.termine).get()), sinceRev, ich);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> nach(Object? vor) async {
    try {
      if (vor is! _Vorher) return;
      if (wandtablet() || !await an()) return;
      final treffer = terminTreffer(vorher: vor.stand, jetzt: await db.select(db.termine).get(), ich: vor.ich, basisRev: vor.basisRev);
      if (treffer.isEmpty) return;
      await anzeige.zeigen(treffer, mitTitel: await sperrbildschirmTitel(), sperrbildschirmTitel: await sperrbildschirmTitel());
    } catch (_) {
      // ein Zusatz: nie den Abgleich stören
    }
  }
}

/// Schalter lesen (Standard an).
Future<bool> terminHinweiseAn(Ref ref) async {
  try {
    return await ref.read(feiertageSpeicherProvider).lesen(schluessel: kTerminHinweiseSchluessel) != 'nein';
  } catch (_) {
    return true;
  }
}

/// Anforderung, den Kalender zu öffnen (Tipp auf die Benachrichtigung); die Shell reagiert darauf.
class TermineOeffnenAnforderung extends Notifier<int> {
  @override
  int build() => 0;

  void anfordern() => state = state + 1;
}

final termineOeffnenProvider = NotifierProvider<TermineOeffnenAnforderung, int>(TermineOeffnenAnforderung.new);

/// Anzeige der Plattform (für Tests überschreibbar): im Web die Browser-Benachrichtigung, sonst das Plugin (Android).
final terminHinweisAnzeigeProvider = Provider<TerminHinweisAnzeige>((ref) {
  if (kIsWeb) {
    return WebTerminHinweisAnzeige(
      browser: ref.watch(browserBenachrichtigungProvider),
      webAn: () => webErinnerungenAn(ref),
      beiKlick: () {
        try {
          ref.read(termineOeffnenProvider.notifier).anfordern();
        } catch (_) {}
      },
    );
  }
  return terminHinweisAnzeigeErzeugen();
});

final terminHinweisDienstProvider = Provider<TerminHinweisDienst>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return TerminHinweisDienst(
    db: db,
    anzeige: ref.watch(terminHinweisAnzeigeProvider),
    an: () => terminHinweiseAn(ref),
    sperrbildschirmTitel: () async {
      try {
        return (await ref.read(erinnerungSpeicherProvider).lesen())[kSperrbildschirmSchluessel] == 'ja';
      } catch (_) {
        return false;
      }
    },
    wandtablet: () {
      try {
        return ref.read(wandtabletLaeuftProvider);
      } catch (_) {
        return false;
      }
    },
  );
});

/// Web-Schalter "Erinnerungen im Browser" lesen (dieselbe Erlaubnis und derselbe Schalter wie die Web-Erinnerungen).
Future<bool> webErinnerungenAn(Ref ref) async {
  try {
    return await ref.read(feiertageSpeicherProvider).lesen(schluessel: kWebAnSchluessel) == 'ja';
  } catch (_) {
    return false;
  }
}
