// Zeitzonen-Daten für Terminserien. Die Familienzeitzone ist fest Europe/Berlin; jeder Zeittermin trägt aber seine eigene IANA-Zeitzone
// (`tzid`), in der seine Wiederholung gerechnet wird. Die Daten (timezone 0.11.1, latest.tzf mit allen Zonen bis 2037) liegen als
// Asset in der App und kommen von der eigenen Domain: kein CDN, kein Abruf von Dritten.
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

/// Zeitzone der Familie: Anzeige und Tagesgrenzen richten sich immer nach ihr, nicht nach dem Gerät.
const kFamilienZone = 'Europe/Berlin';

const _kAsset = 'assets/tz/latest.tzf';

bool _geladen = false;

/// Nur für Tests: erzwingt "Zeitzonen-Daten fehlen" (false) bzw. "da" (true); null = tatsächlicher Zustand.
@visibleForTesting
bool? zeitzonenBereitUeberschreibung;

/// Sind die Zeitzonen-Daten da? Ohne sie rechnet die Anzeige mit UTC (Lesen bleibt möglich), Anlegen und Ändern von Terminen wäre aber falsch
/// (Uhrzeit und Sommerzeit) und wird gesperrt.
bool zeitzonenBereit() {
  final t = zeitzonenBereitUeberschreibung;
  if (t != null) return t;
  try {
    tz.getLocation(kFamilienZone);
    return true;
  } catch (_) {
    return false;
  }
}

/// Neuer Versuch, die Zeitzonen-Daten zu laden. Liefert, ob sie jetzt da sind.
Future<bool> zeitzonenNeuLaden({Future<ByteData> Function()? lader}) async {
  try {
    await zeitzonenLaden(lader: lader);
  } catch (_) {
    // bleibt unbereit
  }
  return zeitzonenBereit();
}

/// Lädt die Zeitzonen-Daten einmalig (vor `runApp`). [lader] ist für Tests überschreibbar.
Future<void> zeitzonenLaden({Future<ByteData> Function()? lader}) async {
  if (_geladen && zeitzonenBereit()) return;
  final daten = await (lader ?? () => rootBundle.load(_kAsset))();
  tz.initializeDatabase(daten.buffer.asUint8List(daten.offsetInBytes, daten.lengthInBytes));
  _geladen = true;
}

/// Zeitzone zur Kennung; unbekannte oder fehlende Kennung fällt auf die Familienzeitzone zurück (nie ein Absturz).
tz.Location ortFuer(String? tzid) {
  for (final name in [?tzid, kFamilienZone]) {
    try {
      return tz.getLocation(name);
    } catch (_) {
      // nächster Versuch
    }
  }
  return tz.UTC;
}

tz.Location get familienOrt => ortFuer(kFamilienZone);

/// Wanduhrzeit des Zeitpunkts [instant] in [ort], als `DateTime.utc(...)`-Markierung (die Uhrzeit ist die an der Wand, nicht UTC).
DateTime wandUhr(DateTime instant, tz.Location ort) {
  final t = tz.TZDateTime.from(instant.toUtc(), ort);
  return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/// Umkehrung von [wandUhr]: der Zeitpunkt (UTC), zu dem es in [ort] [wand] Uhr ist. Eine ausgefallene Uhrzeit (Beginn der Sommerzeit)
/// rutscht auf die Zeit danach.
DateTime instantAusWand(DateTime wand, tz.Location ort) =>
    tz.TZDateTime(ort, wand.year, wand.month, wand.day, wand.hour, wand.minute, wand.second).toUtc();
