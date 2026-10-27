// Erinnerungen in der Web-App (REINE Logik, kein Browser, keine Oberfläche). Das Web hat keinen Hintergrund: Erinnerungen kommen nur, solange
// die Web-App geöffnet ist. Die Planung ist dieselbe wie auf Android (`planeErinnerungen`, ein Fenster, alle Quellen); hier wird nur entschieden,
// welche geplante Erinnerung JETZT fällig ist, welche nur noch als "verpasst" gilt und welcher NEUTRALE Text gezeigt wird.
//  - Der Schnappschuss (Kennung, Zeit, Nutzlast; nie ein Titel, nie ein Text) wird lokal gehalten, damit Erinnerungen, die während einer Pause der
//    App fällig wurden, danach noch als "verpasst" erscheinen können (die neue Planung kennt nur noch Zukünftiges).
//  - Nie doppelt: eine Merkliste gezeigter Erinnerungen (Kennung + Zeit), nach 48 Stunden bereinigt.
//  - Strenger als Android: Benachrichtigung und Hinweis nennen nie Titel, Namen, Orte, Medikamente, Zähler oder Werte, auch wenn auf Android
//    "Titel zeigen" an ist. Der Titel steht erst in der Zielseite.
import 'dart:convert';

import '../medikamente/medikament_erinnerung.dart' show istMedikamentPayload;
import '../muell/muell_logik.dart' show istMuellPayload;
import '../tagesbriefing/briefing_erinnerung.dart' show istBriefingPayload;
import '../zaehler/zaehler_erinnerung.dart' show istZaehlerPayload;
import 'erinnerung_planung.dart';

/// Toleranz: eine Erinnerung, die höchstens so lange fällig ist, gilt als "jetzt" (Browser drosseln Zeitgeber in Hintergrund-Tabs).
const kWebToleranz = Duration(minutes: 5);

/// "Verpasst seit du weg warst": so weit zurück, und höchstens so viele.
const kWebVerpasstFenster = Duration(hours: 24);
const kWebVerpasstMax = 10;

/// So lange bleibt eine gezeigte Erinnerung in der Merkliste (danach kann sie nie wieder fällig werden: Fenster 24 Stunden).
const kWebMerklisteDauer = Duration(hours: 48);

/// Eine geplante Erinnerung im Schnappschuss: nur Kennung, Zeitpunkt (Millisekunden, UTC) und Nutzlast.
class WebEintrag {
  final int id;
  final int zeitMs;
  final String payload;
  const WebEintrag(this.id, this.zeitMs, this.payload);

  DateTime get zeit => DateTime.fromMillisecondsSinceEpoch(zeitMs, isUtc: true);

  /// Schlüssel für die Merkliste: dieselbe Kennung mit neuer Zeit (verschobener Termin) zählt als neue Erinnerung.
  String get schluessel => '$id@$zeitMs';

  @override
  bool operator ==(Object other) => other is WebEintrag && other.id == id && other.zeitMs == zeitMs && other.payload == payload;
  @override
  int get hashCode => Object.hash(id, zeitMs, payload);
}

/// Neutraler Text zur Nutzlast; null = nicht für das Web gedacht (Hinweis "Erinnerungen laufen aus", unbekanntes Format, Sicherheits-/Betriebs-/
/// Standort-/Wetter-Hinweise gehören nicht hierher). Nie ein Titel, nie ein Name.
String? webNeutralerText(String payload) {
  if (erinnerungPayloadLesen(payload) != null) return 'Erinnerung: Ein Termin steht an';
  if (aufgabeErinnerungPayloadLesen(payload) != null) return 'Erinnerung: Eine Aufgabe steht an';
  if (istMuellPayload(payload)) return 'Erinnerung: Eine Abholung steht an';
  if (istMedikamentPayload(payload) || istZaehlerPayload(payload)) return 'Erinnerung: Etwas steht an';
  if (istBriefingPayload(payload)) return 'Erinnerung: Dein Tagesüberblick ist bereit';
  return null;
}

/// Neuer Schnappschuss: die neue Planung (nur Erinnerungen mit Web-Text) plus der Teil des alten, der inzwischen vorbei ist, aber noch im
/// Verpasst-Fenster liegt. Sortiert nach Zeit.
List<WebEintrag> webSchnappschuss(List<GeplanteErinnerung> neu, List<WebEintrag> alt, DateTime jetzt) {
  final nun = jetzt.toUtc();
  final jetztMs = nun.millisecondsSinceEpoch;
  final grenze = nun.subtract(kWebVerpasstFenster).millisecondsSinceEpoch;
  final out = <String, WebEintrag>{};
  for (final e in alt) {
    if (e.zeitMs <= jetztMs && e.zeitMs > grenze && webNeutralerText(e.payload) != null) out[e.schluessel] = e;
  }
  for (final g in neu) {
    if (webNeutralerText(g.payload) == null) continue;
    final e = WebEintrag(g.id, g.zeit.toUtc().millisecondsSinceEpoch, g.payload);
    out[e.schluessel] = e;
  }
  return out.values.toList()..sort((a, b) => a.zeitMs != b.zeitMs ? a.zeitMs.compareTo(b.zeitMs) : a.id.compareTo(b.id));
}

/// Ergebnis einer Prüfung: [faellig] = jetzt zu zeigen (Benachrichtigung und Hinweis), [verpasst] = zu spät für eine Benachrichtigung (nur eine
/// ruhige Zeile, neueste zuerst, höchstens [kWebVerpasstMax]).
class WebPruefung {
  final List<WebEintrag> faellig;
  final List<WebEintrag> verpasst;
  const WebPruefung(this.faellig, this.verpasst);
}

WebPruefung webPruefen({required List<WebEintrag> plan, required Set<String> gezeigt, required DateTime jetzt}) {
  final nun = jetzt.toUtc();
  final jetztMs = nun.millisecondsSinceEpoch;
  final tolMs = nun.subtract(kWebToleranz).millisecondsSinceEpoch;
  final fensterMs = nun.subtract(kWebVerpasstFenster).millisecondsSinceEpoch;
  final faellig = <WebEintrag>[];
  final verpasst = <WebEintrag>[];
  for (final e in plan) {
    if (e.zeitMs > jetztMs || e.zeitMs <= fensterMs || gezeigt.contains(e.schluessel)) continue;
    (e.zeitMs >= tolMs ? faellig : verpasst).add(e);
  }
  verpasst.sort((a, b) => b.zeitMs.compareTo(a.zeitMs));
  return WebPruefung(faellig, verpasst.length > kWebVerpasstMax ? verpasst.sublist(0, kWebVerpasstMax) : verpasst);
}

/// Merkliste ohne Einträge, die älter als [kWebMerklisteDauer] sind (der Schlüssel trägt die Zeit hinter dem `@`).
Set<String> webMerklisteBereinigen(Set<String> gezeigt, DateTime jetzt) {
  final grenze = jetzt.toUtc().subtract(kWebMerklisteDauer).millisecondsSinceEpoch;
  return {
    for (final k in gezeigt)
      if ((int.tryParse(k.split('@').last) ?? 0) > grenze) k,
  };
}

// ---- Ablage (JSON in sync_meta) ----

String webPlanKodieren(List<WebEintrag> plan) => jsonEncode([for (final e in plan) [e.id, e.zeitMs, e.payload]]);

/// Tolerant: ein unlesbarer Stand ergibt eine leere Liste.
List<WebEintrag> webPlanLesen(String? text) {
  if (text == null || text.isEmpty) return const [];
  try {
    final j = jsonDecode(text);
    if (j is! List) return const [];
    return [
      for (final z in j)
        if (z is List && z.length == 3 && z[0] is int && z[1] is int && z[2] is String && webNeutralerText(z[2] as String) != null) WebEintrag(z[0] as int, z[1] as int, z[2] as String),
    ];
  } catch (_) {
    return const [];
  }
}

String webMerklisteKodieren(Set<String> gezeigt) => jsonEncode(gezeigt.toList());

Set<String> webMerklisteLesen(String? text) {
  if (text == null || text.isEmpty) return const {};
  try {
    final j = jsonDecode(text);
    if (j is! List) return const {};
    return {
      for (final k in j)
        if (k is String && RegExp(r'^\d+@\d+$').hasMatch(k)) k,
    };
  } catch (_) {
    return const {};
  }
}
