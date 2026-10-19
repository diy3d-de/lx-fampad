// Vertrauen beim ersten Sehen (TOFU): Der erste öffentliche Schlüssel, den dieses Gerät von einer Person sieht, wird gemerkt. Ändert er sich
// später (oder verschwindet er), warnt die App deutlich; der neue Schlüssel gilt erst nach ausdrücklicher Bestätigung ("Neuen Schlüssel akzeptieren").
// Das schützt vor einem Server oder Admin, der unbemerkt Schlüssel austauscht, solange jemand die Warnung ernst nimmt und den Sicherheitscode
// (sicherheitscode.dart) mit der Person abgleicht. Die gemerkten Schlüssel sind öffentlich, brauchen aber Integrität: sie liegen im Schlüsselspeicher des Geräts.
import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'schluessel.dart';
import 'schluessel_speicher.dart';
import 'sicherheitscode.dart';

class GemerkterSchluessel {
  final Uint8List enc;
  final Uint8List sign;
  final int version;
  const GemerkterSchluessel(this.enc, this.sign, this.version);

  bool gleichWie(OeffentlicheSchluessel o) => gleicheBytes(enc, o.enc) && gleicheBytes(sign, o.sign);
}

/// Ein Schlüssel hat sich geändert (oder fehlt jetzt): [aktuell] ist null, wenn der Server keinen Schlüssel mehr liefert.
class SchluesselWarnung {
  final String userId;
  final GemerkterSchluessel gemerkt;
  final OeffentlicheSchluessel? aktuell;
  const SchluesselWarnung({required this.userId, required this.gemerkt, required this.aktuell});
}

class VertrauensPruefer {
  final SchluesselSpeicher speicher;
  final String eigeneUserId;
  VertrauensPruefer(this.speicher, {required this.eigeneUserId});

  String get _name => 'e2ee.vertrauen.$eigeneUserId';

  Future<Map<String, GemerkterSchluessel>> _laden() async {
    // Lesefehler des Speichers (Keystore, IndexedDB) gehen weiter: ein Fehler darf nie wie "noch nichts gemerkt" aussehen und die Merkliste überschreiben
    final bytes = await speicher.lesen(_name);
    if (bytes == null) return {};
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map) return {};
      final out = <String, GemerkterSchluessel>{};
      raw.forEach((k, v) {
        if (k is String && v is Map && v['e'] is String && v['s'] is String && v['v'] is int) {
          out[k] = GemerkterSchluessel(base64urlDekodieren(v['e'] as String), base64urlDekodieren(v['s'] as String), v['v'] as int);
        }
      });
      return out;
    } on Object {
      return {};
    }
  }

  Future<void> _speichern(Map<String, GemerkterSchluessel> m) => speicher.schreiben(
    _name,
    utf8Bytes(jsonEncode({for (final e in m.entries) e.key: {'e': base64urlKodieren(e.value.enc), 's': base64urlKodieren(e.value.sign), 'v': e.value.version}})),
  );

  /// Gleicht die aktuellen Schlüssel der Mitglieder mit den gemerkten ab. Unbekannte Personen werden gemerkt (ohne Warnung), Abweichungen
  /// ergeben eine Warnung (und werden NICHT übernommen). Die eigene Person wird nicht geprüft (dafür gibt es den Abgleich mit dem lokalen Schlüssel).
  Future<List<SchluesselWarnung>> pruefen(Map<String, OeffentlicheSchluessel?> aktuell) async {
    final gemerkt = await _laden();
    final warnungen = <SchluesselWarnung>[];
    var geaendert = false;
    for (final e in aktuell.entries) {
      if (e.key == eigeneUserId) continue;
      final alt = gemerkt[e.key];
      final neu = e.value;
      if (alt == null) {
        if (neu != null) {
          gemerkt[e.key] = GemerkterSchluessel(neu.enc, neu.sign, neu.version);
          geaendert = true;
        }
      } else if (neu == null || !alt.gleichWie(neu)) {
        warnungen.add(SchluesselWarnung(userId: e.key, gemerkt: alt, aktuell: neu));
      }
    }
    // Personen, die nicht mehr in der Mitgliederliste stehen (entfernt), werden vergessen: ein späteres Wiederhinzufügen beginnt mit neuem Vertrauen
    final entfernt = gemerkt.keys.where((id) => !aktuell.containsKey(id)).toList();
    for (final id in entfernt) {
      gemerkt.remove(id);
      geaendert = true;
    }
    if (geaendert) await _speichern(gemerkt);
    return warnungen;
  }

  /// Der gemerkte Schlüssel einer Person (null, wenn keiner gemerkt ist): Grundlage für Signaturprüfungen (nie der Schlüssel vom Server).
  Future<OeffentlicheSchluessel?> gemerkterSchluessel(String userId) async {
    final k = (await _laden())[userId];
    return k == null ? null : OeffentlicheSchluessel(enc: k.enc, sign: k.sign, version: k.version);
  }

  /// Übernimmt den neuen Schlüssel einer Person nach ausdrücklicher Bestätigung. Ohne neuen Schlüssel wird nur der alte vergessen.
  Future<void> akzeptieren(String userId, OeffentlicheSchluessel? neu) async {
    final gemerkt = await _laden();
    if (neu == null) {
      gemerkt.remove(userId);
    } else {
      gemerkt[userId] = GemerkterSchluessel(neu.enc, neu.sign, neu.version);
    }
    await _speichern(gemerkt);
  }

  /// Sicherheitscode des gemerkten Schlüssels (zum Vergleich "alt gegen neu").
  static String codeVon(String userId, GemerkterSchluessel k) =>
      personenSicherheitscode(MitgliedSchluessel(userId, OeffentlicheSchluessel(enc: k.enc, sign: k.sign, version: k.version)));
}
