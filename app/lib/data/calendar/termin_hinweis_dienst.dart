// Dienst für die Hinweise auf neue und geänderte Termine (Abschnitt 6r): nach einem erfolgreichen Abgleich vergleicht er die Termine mit dem Stand von
// VOR dem Abgleich und zeigt höchstens EINE neutrale lokale Benachrichtigung je Lauf. Rein lokal: kein Server, kein Schema, nie Inhalt im Wecker, im Log
// oder im Push. Läuft im Vordergrund und im Hintergrund-Start (beide benutzen dieselbe Abgleich-Engine).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart' show kAppName;
import '../app_database.dart';
import '../database_provider.dart';
import '../../features/shell/shell_tab.dart' show kKalenderTab, shellTabProvider;
import '../erinnerungen/browser_benachrichtigung.dart';
import '../erinnerungen/erinnerung_dienst.dart' show erinnerungDienstProvider;
import '../erinnerungen/erinnerung_einstellungen.dart';
import '../erinnerungen/web_erinnerung_port.dart' show kWebAnSchluessel;
import '../erinnerungen/web_erinnerung_state.dart' show browserBenachrichtigungProvider;
import '../sync/sync_engine.dart' show AbgleichBeobachter;
import '../sync/sync_models.dart' show SyncChange;
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

  /// Nimmt die gezeigte Meldung zurück (Abmelden, Personenwechsel); keine ist kein Fehler.
  Future<void> entfernen();
}

class KeineTerminHinweisAnzeige implements TerminHinweisAnzeige {
  const KeineTerminHinweisAnzeige();

  @override
  Future<bool> zeigen(List<TerminTreffer> treffer, {required bool mitTitel, required bool sperrbildschirmTitel}) async => false;

  @override
  Future<void> entfernen() async {}
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

  @override
  Future<void> entfernen() async {} // eine Browser-Benachrichtigung lässt sich nicht zurücknehmen; sie trägt nie einen Titel
}

class TerminHinweisDienst implements AbgleichBeobachter {
  final AppDatabase db;
  final TerminHinweisAnzeige anzeige;
  final Future<bool> Function() an;
  final Future<bool> Function() sperrbildschirmTitel;
  final bool Function() wandtablet;

  /// Android im Vordergrund mit dem Kalender vor Augen: die Oberfläche zeigt die Änderung selbst.
  final bool Function() unterdruecken;

  /// Stand der betroffenen Termine VOR dem Einarbeiten der Serverantwort: Termin-ID -> Abdruck (`null`: gab es lokal nicht). Nur im Arbeitsspeicher
  /// (Titel und Ort landen nie auf der Platte). Bleibt über abgebrochene Läufe hinweg bestehen, bis ein Lauf vollständig durch ist; ein
  /// Hintergrund-Start, der abbricht, verliert ihn mit seinem Container (dann entfällt die Meldung).
  final Map<String, String?> _vorher = {};

  /// Termine, die diese Person selbst geändert hat (offener oder im Lauf gesendeter Ausgang).
  final Set<String> _eigene = {};

  TerminHinweisDienst({
    required this.db,
    required this.anzeige,
    required this.an,
    required this.sperrbildschirmTitel,
    required this.wandtablet,
    this.unterdruecken = _nie,
  });

  static bool _nie() => false;

  Future<String> _abdruck(Termin t) async => terminAbdruck(t, await (db.select(db.terminAusnahmen)..where((x) => x.terminId.equals(t.id))).get());

  /// Termin-ID, die ein Ausgangseintrag betrifft (Termin selbst oder Ausnahme); sonst null.
  Future<String?> _terminVon(String entity, String id, {String fieldsJson = '{}'}) async {
    if (entity == 'termin') return id;
    if (entity != 'termin_ausnahmen') return null;
    final z = await (db.select(db.terminAusnahmen)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (z != null) return z.terminId;
    try {
      final f = jsonDecode(fieldsJson);
      final t = f is Map ? f['terminId'] : null;
      return t is String ? t : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> vorUebernahme(List<SyncChange> changes, List<OutboxData> gesendet) async {
    try {
      if (!await an()) return;
      // eigene Änderungen: alles, was im Ausgang liegt, und was in dieser Runde gesendet wird
      for (final o in [...await db.select(db.outbox).get(), ...gesendet]) {
        final t = await _terminVon(o.entity, o.entityId, fieldsJson: o.fieldsJson);
        if (t != null) _eigene.add(t);
      }
      // betroffene Termine der Antwort: nur diese werden vorher festgehalten (kein Durchlauf über alle Termine)
      for (final c in changes) {
        if (c.entity != 'termin' && c.entity != 'termin_ausnahmen') continue;
        String? id;
        if (c.entity == 'termin') {
          id = c.id;
        } else {
          final f = c.fields['terminId'];
          id = f is String ? f : await _terminVon(c.entity, c.id);
        }
        if (id == null || _vorher.containsKey(id)) continue;
        final t = await (db.select(db.termine)..where((x) => x.id.equals(id!))).getSingleOrNull();
        _vorher[id] = t == null ? null : await _abdruck(t);
      }
    } catch (_) {
      // ein Zusatz: nie den Abgleich stören
    }
  }

  @override
  Future<void> nach() async {
    try {
      final vorher = Map<String, String?>.of(_vorher);
      final eigene = Set<String>.of(_eigene);
      _vorher.clear();
      _eigene.clear();
      if (vorher.isEmpty || !await an() || wandtablet()) return;
      final jetzt = <String, ({Termin termin, String abdruck})>{};
      for (final id in vorher.keys) {
        final t = await (db.select(db.termine)..where((x) => x.id.equals(id))).getSingleOrNull();
        if (t != null) jetzt[id] = (termin: t, abdruck: await _abdruck(t));
      }
      final treffer = terminTreffer(vorher: vorher, jetzt: jetzt, eigene: eigene);
      if (treffer.isEmpty || unterdruecken()) return;
      final mitTitel = await sperrbildschirmTitel();
      await anzeige.zeigen(treffer, mitTitel: mitTitel, sperrbildschirmTitel: mitTitel);
    } catch (_) {
      // ein Zusatz: nie den Abgleich stören
    }
  }

  @override
  void verwerfen() {
    _vorher.clear();
    _eigene.clear();
  }

  /// Abmelden, Personenwechsel, Gerät abgeben: Zustand weg und eine schon gezeigte Meldung zurücknehmen (sie nennt vielleicht einen Titel).
  Future<void> abmelden() async {
    verwerfen();
    try {
      await anzeige.entfernen();
    } catch (_) {}
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
  // ein Tipp auf die Meldung läuft über den Erinnerungsdienst (Nutzlast `termine` öffnet den Kalender, andere Nutzlasten behalten ihr Ziel)
  return terminHinweisAnzeigeErzeugen(beiTipp: (p) => ref.read(erinnerungDienstProvider).oeffnen(p));
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
    unterdruecken: () {
      try {
        return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && ref.read(shellTabProvider) == kKalenderTab;
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
