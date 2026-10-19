// Vertrauen beim ersten Sehen (TOFU): Der erste öffentliche Schlüssel, den dieses Gerät von einer Person sieht, wird gemerkt. Ändert er sich
// später (oder verschwindet er), warnt die App deutlich; der neue Schlüssel gilt erst nach ausdrücklicher Bestätigung ("Neuen Schlüssel akzeptieren").
// Das schützt vor einem Server oder Admin, der unbemerkt Schlüssel austauscht, solange jemand die Warnung ernst nimmt und den Sicherheitscode
// (sicherheitscode.dart) mit der Person abgleicht. Die gemerkten Schlüssel sind öffentlich, brauchen aber Integrität: sie liegen im Schlüsselspeicher des Geräts.
import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'schluessel.dart';
import 'schluessel_speicher.dart';
import 'sicherheitscode.dart';

class GemerkterSchluessel {
  final Uint8List enc;
  final Uint8List sign;
  final int version;

  /// Früher bestätigte Schlüssel dieser Person (vom Gerät selbst gemerkt, nicht vom Server): Sie gelten für Signaturen aus der Zeit vor einem bestätigten
  /// Schlüsselwechsel (Wraps und Nachrichten, die die Person mit dem damaligen Schlüssel signiert hat).
  final List<GemerkterSchluessel> frueher;

  /// Die Person steht nicht mehr in der Mitgliederliste (aus der Familie entfernt). Der Eintrag BLEIBT: Wraps, Listen und Nachrichten, die sie früher signiert hat, lassen
  /// sich weiter prüfen (sonst wäre der Verlauf nach einem Neustart unlesbar), und ein Wiederauftauchen mit anderem Schlüssel warnt wie jeder Wechsel.
  final bool entfernt;
  const GemerkterSchluessel(this.enc, this.sign, this.version, {this.frueher = const [], this.entfernt = false});

  GemerkterSchluessel alsEntfernt(bool wert) => GemerkterSchluessel(enc, sign, version, frueher: frueher, entfernt: wert);

  bool gleichWie(OeffentlicheSchluessel o) => gleicheBytes(enc, o.enc) && gleicheBytes(sign, o.sign);
}

/// Ein Schlüssel hat sich geändert (oder fehlt jetzt): [aktuell] ist null, wenn der Server keinen Schlüssel mehr liefert.
class SchluesselWarnung {
  final String userId;
  final GemerkterSchluessel gemerkt;
  final OeffentlicheSchluessel? aktuell;

  /// Der Server nennt eine ÄLTERE Schlüsselversion als die gemerkte (Rückfall): das gibt es im Normalbetrieb nie (die Version steigt nur) und lässt sich nicht bestätigen.
  final bool rueckfall;
  const SchluesselWarnung({required this.userId, required this.gemerkt, required this.aktuell, this.rueckfall = false});
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
      GemerkterSchluessel? eintrag(Object? v) {
        if (v is Map && v['e'] is String && v['s'] is String && v['v'] is int) {
          final h = v['h'];
          return GemerkterSchluessel(
            base64urlDekodieren(v['e'] as String),
            base64urlDekodieren(v['s'] as String),
            v['v'] as int,
            frueher: h is List ? [for (final x in h) ?eintrag(x)] : const [],
            entfernt: v['x'] == true,
          );
        }
        return null;
      }

      raw.forEach((k, v) {
        final e = eintrag(v);
        if (k is String && e != null) out[k] = e;
      });
      return out;
    } on Object {
      return {};
    }
  }

  static Map<String, Object?> _json(GemerkterSchluessel k) => {
    'e': base64urlKodieren(k.enc),
    's': base64urlKodieren(k.sign),
    'v': k.version,
    if (k.frueher.isNotEmpty) 'h': [for (final f in k.frueher) _json(f)],
    if (k.entfernt) 'x': true,
  };

  Future<void> _speichern(Map<String, GemerkterSchluessel> m) => speicher.schreiben(
    _name,
    utf8Bytes(jsonEncode({for (final e in m.entries) e.key: _json(e.value)})),
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
      } else if (neu != null && alt.gleichWie(neu)) {
        // wieder da mit demselben Schlüssel: kein Anlass zur Warnung
        if (alt.entfernt) {
          gemerkt[e.key] = alt.alsEntfernt(false);
          geaendert = true;
        }
      } else if (neu == null && alt.entfernt) {
        // schon als entfernt vermerkt und ohne Schlüssel gelistet: nichts Neues
      } else {
        // Schlüsselwechsel oder verschwundener Schlüssel; eine ÄLTERE Version als die gemerkte ist ein Rückfall (der Server dreht zurück)
        warnungen.add(SchluesselWarnung(userId: e.key, gemerkt: alt, aktuell: neu, rueckfall: neu != null && neu.version < alt.version));
      }
    }
    // Personen, die nicht mehr in der Mitgliederliste stehen, werden nur als entfernt vermerkt, nie vergessen (alte Signaturen bleiben prüfbar, ein Wiederauftauchen
    // mit anderem Schlüssel warnt)
    for (final id in gemerkt.keys.toList()) {
      final k = gemerkt[id]!;
      if (id != eigeneUserId && !aktuell.containsKey(id) && !k.entfernt) {
        gemerkt[id] = k.alsEntfernt(true);
        geaendert = true;
      }
    }
    if (geaendert) await _speichern(gemerkt);
    return warnungen;
  }

  /// Der gemerkte Schlüssel einer Person (null, wenn keiner gemerkt ist): Grundlage für Signaturprüfungen (nie der Schlüssel vom Server). Mit [version]
  /// der Schlüssel genau dieser Version, wenn das Gerät ihn früher bestätigt hat (vor einem bestätigten Schlüsselwechsel); sonst null.
  Future<OeffentlicheSchluessel?> gemerkterSchluessel(String userId, {int? version}) async {
    final k = (await _laden())[userId];
    if (k == null) return null;
    GemerkterSchluessel? treffer = k;
    if (version != null && version != k.version) treffer = k.frueher.where((f) => f.version == version).firstOrNull;
    return treffer == null ? null : OeffentlicheSchluessel(enc: treffer.enc, sign: treffer.sign, version: treffer.version);
  }

  /// Übernimmt den neuen Schlüssel einer Person nach ausdrücklicher Bestätigung. Ohne neuen Schlüssel wird die Person nur als entfernt vermerkt (nichts wird
  /// vergessen). Eine ÄLTERE Schlüsselversion als die gemerkte lässt sich nie übernehmen ([CryptoFehler]).
  Future<void> akzeptieren(String userId, OeffentlicheSchluessel? neu) async {
    final gemerkt = await _laden();
    if (neu == null) {
      final alt = gemerkt[userId];
      if (alt != null) gemerkt[userId] = alt.alsEntfernt(true);
    } else {
      final alt = gemerkt[userId];
      if (alt != null && neu.version < alt.version) {
        throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Server nennt eine ältere Schlüsselversion als die bestätigte. Das gibt es normalerweise nie und lässt sich nicht bestätigen.');
      }
      // der bisherige (bestätigte) Schlüssel bleibt für Signaturen aus der Zeit davor erhalten
      final frueher = [
        if (alt != null && !alt.gleichWie(neu)) ...[GemerkterSchluessel(alt.enc, alt.sign, alt.version), ...alt.frueher],
        if (alt != null && alt.gleichWie(neu)) ...alt.frueher,
      ];
      gemerkt[userId] = GemerkterSchluessel(neu.enc, neu.sign, neu.version, frueher: frueher);
    }
    await _speichern(gemerkt);
  }

  /// Sicherheitscode des gemerkten Schlüssels (zum Vergleich "alt gegen neu").
  static String codeVon(String userId, GemerkterSchluessel k) =>
      personenSicherheitscode(MitgliedSchluessel(userId, OeffentlicheSchluessel(enc: k.enc, sign: k.sign, version: k.version)));
}
