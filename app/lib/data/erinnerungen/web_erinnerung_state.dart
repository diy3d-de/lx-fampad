// Zustand der Erinnerungen in der Web-App (nur lokal, nur solange die Web-App geöffnet ist; kein Web-Push, kein Service Worker, kein Server):
//  - Schalter "Erinnerungen im Browser" je Gerät (`sync_meta`, Standard AUS; die Browser-Erlaubnis wird nur beim Einschalten per Klick angefragt),
//  - Hinweise für die Startseite (neu fällig, verpasst) und der Durchgang [webErinnerungPruefen], den der Minutentakt auslöst
//    (verdrahtet in features/calendar/web_erinnerung_steuerung.dart).
// Texte sind immer neutral (web_erinnerung_logik.dart): nie ein Titel, nie ein Name. Im Wandtablet-Betrieb kommt nichts.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../auth/auth_state.dart';
import '../calendar/feiertage.dart' show feiertageSpeicherProvider;
import '../wandtablet/wandtablet_einstellungen.dart' show wandtabletLaeuftProvider;
import 'browser_benachrichtigung.dart';
import 'erinnerung_dienst.dart';
import 'web_erinnerung_logik.dart';
import 'web_erinnerung_port.dart';

final browserBenachrichtigungProvider = Provider<BrowserBenachrichtigung>((ref) => browserBenachrichtigungErzeugen());

/// Schalter "Erinnerungen im Browser" (lokal je Gerät, Standard aus).
class WebErinnerungAn extends Notifier<bool> {
  /// Fertig, sobald der gespeicherte Wert gelesen ist.
  late Future<void> bereit;
  bool _gesetzt = false;

  @override
  bool build() {
    bereit = _laden();
    return false;
  }

  Future<void> _laden() async {
    var an = false;
    try {
      an = await ref.read(feiertageSpeicherProvider).lesen(schluessel: kWebAnSchluessel) == 'ja';
    } catch (_) {}
    if (!ref.mounted || _gesetzt) return;
    state = an;
  }

  Future<void> _schreiben(bool an) async {
    try {
      await ref.read(feiertageSpeicherProvider).schreiben(an ? 'ja' : 'nein', schluessel: kWebAnSchluessel);
    } catch (_) {}
  }

  /// Einschalten (nur aus einem Klick): fragt die Browser-Erlaubnis an und plant neu. Bleibt die Erlaubnis aus, zeigt die App die Hinweise trotzdem selbst.
  Future<BrowserErlaubnis> einschalten() async {
    _gesetzt = true;
    state = true;
    // die Browser-Anfrage zuerst und ohne Umweg: Browser verlangen, dass sie direkt aus dem Klick kommt
    final dienst = ref.read(erinnerungDienstProvider);
    try {
      await dienst.berechtigungAnfragen();
    } catch (_) {}
    await _schreiben(true);
    return ref.read(browserBenachrichtigungProvider).erlaubnis();
  }

  Future<void> ausschalten() async {
    _gesetzt = true;
    state = false;
    await _schreiben(false);
    try {
      await ref.read(erinnerungPortProvider).alleLoeschen();
    } catch (_) {}
    ref.read(webHinweiseProvider.notifier).leeren();
  }
}

final webErinnerungAnProvider = NotifierProvider<WebErinnerungAn, bool>(WebErinnerungAn.new);

/// Hinweise für die Startseite: [neu] = gerade fällig geworden (schließbar), [verpasst] = fällig, während die App nicht lief oder zu spät (ruhige Zeile).
class WebHinweise {
  final List<WebEintrag> neu;
  final List<WebEintrag> verpasst;
  const WebHinweise({this.neu = const [], this.verpasst = const []});
  bool get leer => neu.isEmpty && verpasst.isEmpty;
}

class WebHinweiseNotifier extends Notifier<WebHinweise> {
  @override
  WebHinweise build() => const WebHinweise();

  void setzen({List<WebEintrag>? neu, List<WebEintrag>? verpasst}) {
    final n = WebHinweise(neu: neu ?? state.neu, verpasst: verpasst ?? state.verpasst);
    if (n.neu.length == state.neu.length && n.verpasst.length == state.verpasst.length && _gleich(n, state)) return;
    state = n;
  }

  bool _gleich(WebHinweise a, WebHinweise b) {
    for (var i = 0; i < a.neu.length; i++) {
      if (a.neu[i] != b.neu[i]) return false;
    }
    for (var i = 0; i < a.verpasst.length; i++) {
      if (a.verpasst[i] != b.verpasst[i]) return false;
    }
    return true;
  }

  void neuSchliessen(WebEintrag e) => state = WebHinweise(neu: [for (final x in state.neu) if (x != e) x], verpasst: state.verpasst);

  void leeren() => state = const WebHinweise();
}

final webHinweiseProvider = NotifierProvider<WebHinweiseNotifier, WebHinweise>(WebHinweiseNotifier.new);

/// Der Port der Web-App (für Tests überschreibbar; auf Android nie benutzt).
final webErinnerungPortProvider = Provider<WebErinnerungPort>((ref) {
  return WebErinnerungPort(
    speicher: ref.watch(feiertageSpeicherProvider),
    browser: ref.watch(browserBenachrichtigungProvider),
    aktiv: () async {
      await ref.read(webErinnerungAnProvider.notifier).bereit;
      return ref.read(webErinnerungAnProvider);
    },
    jetzt: ref.read(erinnerungUhrProvider),
  );
});


/// Ein Durchgang (Minutentakt, Rückkehr in den Tab, nach dem Planen): fällige Erinnerungen zeigen (Browser-Benachrichtigung nur mit Erlaubnis,
/// Hinweis in der App immer), verpasste für die ruhige Zeile sammeln. Nie ein Fehler nach außen, nie parallel.
Future<void> webErinnerungPruefen(Ref ref) async {
  final port = ref.read(erinnerungPortProvider);
  if (port is! WebErinnerungPort || port.beschaeftigt) return;
  port.beschaeftigt = true;
  try {
    await ref.read(webErinnerungAnProvider.notifier).bereit;
    if (!ref.mounted) return;
    final hinweise = ref.read(webHinweiseProvider.notifier);
    if (!ref.read(webErinnerungAnProvider) || !ref.read(authProvider).angemeldet) {
      hinweise.leeren();
      return;
    }
    final jetzt = ref.read(erinnerungUhrProvider)();
    final p = await port.pruefen(jetzt);
    if (!ref.mounted) return;
    // Wandtablet: keine Benachrichtigung und kein Hinweis; nichts wird als gezeigt gemerkt (später erscheint es als verpasst)
    final faellig = ref.read(wandtabletLaeuftProvider) ? const <WebEintrag>[] : p.faellig;
    if (faellig.isNotEmpty) {
      _zeigen(ref, port, faellig);
      await port.alsGezeigtMerken(faellig, jetzt);
      if (!ref.mounted) return;
    }
    final neu = [...ref.read(webHinweiseProvider).neu, ...faellig];
    hinweise.setzen(neu: neu.length > 5 ? neu.sublist(neu.length - 5) : neu, verpasst: p.verpasst);
  } catch (_) {
    // ein Zusatz: nie etwas anderes stören
  } finally {
    port.beschaeftigt = false;
  }
}

void _zeigen(Ref ref, WebErinnerungPort port, List<WebEintrag> faellig) {
  if (faellig.length == 1) {
    final e = faellig.first;
    final text = webNeutralerText(e.payload);
    if (text == null) return;
    port.browser.zeigen(titel: kAppName, text: text, tag: 'fampad-${e.id}', beiKlick: () => webErinnerungOeffnen(ref, e));
  } else {
    port.browser.zeigen(titel: kAppName, text: 'Erinnerung: ${faellig.length} Erinnerungen stehen an', tag: 'fampad-sammel', beiKlick: () {});
  }
}

/// Öffnet das Ziel der Erinnerung wie ein Tipp auf die Android-Benachrichtigung und nimmt den Hinweis aus der Liste.
void webErinnerungOeffnen(Ref ref, WebEintrag e) {
  try {
    ref.read(webHinweiseProvider.notifier).neuSchliessen(e);
    ref.read(erinnerungDienstProvider).oeffnen(e.payload);
  } catch (_) {}
}
