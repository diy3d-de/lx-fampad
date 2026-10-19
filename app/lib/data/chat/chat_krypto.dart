// Ende-zu-Ende-Verschlüsselung des Chats (E2EE Phase 2): Epochenschlüssel je Konversation, Verteilung als signierte Wraps, Rotation bei Mitgliederwechsel,
// Verschlüsseln und Entschlüsseln der Nachrichten. Reine Logik auf den Bausteinen von data/crypto (epochen.dart, huelle.dart); keine Oberfläche, kein Riverpod.
//
// Grundsätze (docs/PROJEKTBESCHREIBUNG.md, Abschnitt 9a):
//  - Der Server sieht nur Chiffretext, Wraps und signierte Mitgliederlisten. Epochenschlüssel gibt es nur im Arbeitsspeicher; sie werden aus den Wraps der eigenen
//    Person (Sealed Box an den Personenschlüssel, den alle Geräte der Person teilen) bei Bedarf wieder geöffnet. Darum stehen sie nie auf der Platte.
//  - Ein Wrap gilt nur, wenn er samt Mitgliederliste vom selben Verteiler stammt und dessen Signatur zum GEMERKTEN (TOFU) Schlüssel passt (nie ein Schlüssel vom
//    Server). Für die eigene Person gilt der eigene Schlüssel. Unbekannte Verteiler: "wartet", nie "gilt".
//  - Verteilt wird nur an Personen, deren Schlüssel dieses Gerät vertraut (gemerkt UND gleich dem Schlüssel des Servers). Wer eine ungeprüfte Schlüsseländerung
//    hat, bekommt nichts, bis die Warnung bestätigt ist.
//  - Gesendet wird nur mit der höchsten vom Server BESTÄTIGTEN Epoche, für die dieses Gerät den Schlüssel hat; gibt es eine neuere, ungeklärte Epoche, wird gewartet
//    (nie mit einer veralteten Epoche an ein entferntes Mitglied verschlüsseln). Der Ausgang hält den Klartext (`l1:`) und verschlüsselt erst beim Senden neu.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:drift/drift.dart';

import '../app_database.dart';
import '../crypto/bytes.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/epochen.dart';
import '../crypto/huelle.dart';
import '../crypto/schluessel.dart';
import '../sync/sync_store.dart';
import 'chat_ids.dart';
import 'nachrichten_inhalt.dart';

const _familie = 'family';

/// Präfix der verschlüsselten Hülle in der Schnittstelle (Server und Datenbank).
const kPraefixE1 = 'e1:';

/// Nur lokal: Klartext einer noch nicht gesendeten Nachricht im Ausgang. Der Server lehnt ihn ab; er verlässt das Gerät nie (der Abgleich verschlüsselt vorher).
const kPraefixLokal = 'l1:';

/// Größte Nachricht in UTF-8-Bytes (vor dem Verschlüsseln): die verschlüsselte Hülle bleibt damit unter der Obergrenze des Servers (16 384 Zeichen Base64url).
const kMaxNachrichtBytes = 8000;

/// Eine Person kann (noch) nicht in einen verschlüsselten Chat aufgenommen werden: sie hat die Verschlüsselung nicht eingerichtet oder ihr Schlüssel ist ungeprüft.
class SchluesselFehlt implements Exception {
  final List<String> personen;
  const SchluesselFehlt(this.personen);

  @override
  String toString() => 'Schlüssel fehlt: ${personen.join(', ')}';
}

/// Dieses Gerät kann gerade nicht verschlüsseln (kein Personenschlüssel, keine Epoche): die Aktion wird nicht ausgeführt.
class VerschluesselungNichtBereit implements Exception {
  final String meldung;
  const VerschluesselungNichtBereit(this.meldung);

  @override
  String toString() => meldung;
}

/// Ein Eintrag der Mitgliederliste einer Epoche in lesbarer Form (für die Oberfläche).
class EpochenMitglied {
  final String userId;
  final int keyVersion;
  const EpochenMitglied(this.userId, this.keyVersion);
}

/// Gründe, warum eine Nachricht nicht lesbar ist (die Oberfläche zeigt je Grund einen kurzen Hinweis, nie Inhalte).
enum NichtLesbarGrund { schluesselFehlt, absenderUnbekannt, signaturUngueltig, beschaedigt, neuereVersion, unverschluesselt }

/// Was an den Mitgliedern einer Konversation anders ist als in ihrer letzten Epoche. [mitglieder] sind die Empfänger einer neuen Epoche (alle mit
/// vertrauenswürdigem Schlüssel, auch die [neu] hinzugekommenen).
///
/// Automatisch (ohne Rückfrage) rotiert ein Gerät nur, wenn jemand ENTFERNT wurde, eine bekannte Person einen bestätigten neuen Schlüssel hat oder die Epoche
/// nicht lesbar ist ([heilung]). Neu hinzugekommene Personen bekommen den Schlüssel nur auf Bestätigung der Person, die sie hinzugefügt hat, oder eines anderen
/// Mitglieds in der Oberfläche: sonst könnte ein Betreiber mit einem neuen Konto oder einer geänderten Teilnehmerliste ungefragt Zugang zu einer Gruppe bekommen.
class RotationsPlan {
  final Set<String> mitglieder;
  final Set<String> neu;
  final Set<String> entfernt;
  final bool versionNeu;
  final bool heilung;
  const RotationsPlan({required this.mitglieder, required this.neu, required this.entfernt, required this.versionNeu, required this.heilung});

  bool get automatisch => entfernt.isNotEmpty || versionNeu || heilung;

  /// Empfänger einer automatischen Rotation: ohne die noch unbestätigten Neuen.
  Set<String> get automatischeMitglieder => mitglieder.difference(neu);
}

/// Eine geöffnete Epoche, deren Mitgliederliste Personen enthält, die dieses Gerät nicht kennt: zurückgestellt, bis sie nachträglich durch eine eigene Epoche bestätigt ist.
class _Zurueck {
  final Epoche epoche;
  final Uint8List key;
  final String marke;
  final SignierteMitgliederListe liste;
  final OeffentlicheSchluessel verteiler;
  Set<String> extra;
  _Zurueck(this.epoche, this.key, this.marke, this.liste, this.verteiler, this.extra);
}

/// Was dieses Gerät je Konversation als akzeptiert festgehalten hat (dauerhaft, am Vertrauensspeicher verankert, siehe VertrauensPruefer.standLaden):
/// die akzeptierten Epochen (die höchsten, begrenzt auf [kMaxMerkEpochen]) und die zuletzt akzeptierte Mitgliederliste.
class AkzeptierterStand {
  final Set<int> epochen;
  final Map<String, int> liste;
  const AkzeptierterStand(this.epochen, this.liste);
}

/// Wie viele akzeptierte Epochen je Konversation gemerkt werden (ältere gelten, wenn das Gerät schon welche akzeptiert hatte, als bereits gesehen).
const kMaxMerkEpochen = 64;

class _Ring {
  final Map<int, Uint8List> schluessel = {};

  /// Zuletzt geprüfter Wrap je Epoche (Hash von Wrap und Liste), damit nur Neues erneut geöffnet wird.
  final Map<int, String> stand = {};
}

class ChatKrypto {
  final CryptoProvider crypto;
  final AppDatabase db;
  final SyncStore store;
  final String ichId;
  final Personenschluessel meinSchluessel;
  final int meineKeyVersion;

  /// Gemerkter (TOFU) Schlüssel einer Person; null, wenn keiner gemerkt ist. Die eigene Person wird nie gemerkt. Mit `version` der Schlüssel dieser Version, wenn das
  /// Gerät ihn früher bestätigt hat (vor einem bestätigten Schlüsselwechsel der Person).
  final Future<OeffentlicheSchluessel?> Function(String userId, {int? version}) gemerkt;

  /// Aktuelle Schlüssel der aktiven Mitglieder laut Server (Wert null: Person hat keinen eingerichtet; fehlt die Person, ist sie kein aktives Mitglied).
  /// Die ganze Abbildung ist null, solange der Stand nicht bekannt ist (offline): dann gilt für das Lesen und Anlegen der gemerkte Schlüssel allein, Wechsel der
  /// Mitglieder (Rotation) gibt es ohne diesen Stand nicht.
  final Map<String, OeffentlicheSchluessel?>? Function() serverSchluessel;

  /// Signaturschlüssel eines Absenders in einer bestimmten Version (gemerkt, sonst Historie des Servers).
  final Future<OeffentlicheSchluessel> Function(String userId, int version) absenderSchluessel;
  final HuellenCodec _huelle;
  final DateTime Function() _jetzt;

  final Map<String, _Ring> _ringe = {};
  final Map<String, Map<int, NichtLesbarGrund>> _probleme = {};

  /// Zuletzt AKZEPTIERTE Mitgliederliste je Konversation (Person -> Schlüsselversion). Eine neue Epoche gilt nur, wenn sie keine Person enthält, die in dieser Liste fehlt
  /// und die dieses Gerät nicht selbst aufgenommen hat (eigene Epoche): sonst könnte ein Teilnehmer ungefragt eine unbestätigte (oder bewusst entfernte) Person einschleusen.
  final Map<String, Map<String, int>> _akzeptiert = {};

  /// Wegen unbekannter Personen zurückgestellte Epochen (Schlüssel nur im Arbeitsspeicher, "Konversation:Epoche"): sie werden nicht bei jedem Lauf neu geöffnet.
  final Map<String, _Zurueck> _gehalten = {};

  /// Zurückgestellte Epochen je Konversation mit ihren zusätzlichen Personen (für die Entscheidung: Aufnahme-Abfrage statt Heilung).
  final Map<String, Map<int, Set<String>>> _zurueckgestellt = {};

  /// Dauerhafter Stand (Vertrauensspeicher); ohne Angabe nur leer.
  final Future<AkzeptierterStand?> Function(String konversationId) _standLaden;
  final Future<void> Function(String konversationId, AkzeptierterStand stand) _standSpeichern;

  /// Zählt jede Änderung des Vertrauens (neue gemerkte Schlüssel, Mitgliederliste): bis dahin gescheiterte Wraps werden dann erneut versucht.
  int _vertrauensStempel = 0;
  final Map<String, int> _gescheitertBei = {};

  /// Anzahl der Abrufe der Mitglieder beim Server ([mitgliederBeobachtet]) und der Abruf, bei dem eine Person zuerst fehlte: erst wenn sie in ZWEI aufeinanderfolgenden
  /// Abrufen fehlt, gilt sie als entfernt (ein einzelner unvollständiger Abruf löst keine Rotation aus).
  int _abrufe = 0;
  final Map<String, int> _fehltSeit = {};

  /// Seit wann die höchste Epoche für diese Person keinen lesbaren Schlüssel hat (Selbstheilung), je "Konversation:Epoche".
  final Map<String, DateTime> _ohneSchluesselSeit = {};

  /// Seit wann eine Konversation ohne Epoche beobachtet wird (Karenz der ersten Epoche, nicht gegen die Zeit eines fremden Geräts gerechnet).
  final Map<String, DateTime> _ohneEpocheSeit = {};

  /// Seit wann einem Empfänger der eigenen Epoche der Wrap fehlt, und welche Wraps in dieser Sitzung schon nachgereicht wurden.
  final Map<String, DateTime> _wrapFehltSeit = {};
  final Set<String> _nachgereicht = {};

  /// Wie lange die höchste Epoche unlesbar sein darf, bevor ein Gerät mit Schlüssel eine neue anlegt (Selbstheilung nach einer vergifteten Epoche).
  static const heilungsFrist = Duration(minutes: 5);

  /// Wie lange einem Empfänger der Wrap fehlen darf, bevor der Verteiler ihn erneut erzeugt.
  static const wrapFrist = Duration(minutes: 3);

  /// Der Abruf der Mitglieder beim Server hat geklappt (zählt für die Erkennung entfernter Personen).
  void mitgliederBeobachtet() => _abrufe++;

  ChatKrypto({
    required this.crypto,
    required this.db,
    required this.store,
    required this.ichId,
    required this.meinSchluessel,
    required this.meineKeyVersion,
    required this.gemerkt,
    required this.serverSchluessel,
    required this.absenderSchluessel,
    DateTime Function()? jetzt,
    Future<AkzeptierterStand?> Function(String konversationId)? standLaden,
    Future<void> Function(String konversationId, AkzeptierterStand stand)? standSpeichern,
  }) : _huelle = HuellenCodec(crypto),
       _jetzt = jetzt ?? DateTime.now,
       _standLaden = standLaden ?? ((_) async => null),
       _standSpeichern = standSpeichern ?? ((_, _) async {});

  /// Der Stand des Vertrauens hat sich geändert (neuer Abgleich der Mitglieder, bestätigte Warnung): Gescheitertes wird beim nächsten [aktualisieren] erneut geprüft.
  void vertrauenGeaendert() {
    _vertrauensStempel++;
    _vertrauen.clear();
    _verteiler.clear();
  }

  final Map<String, OeffentlicheSchluessel?> _verteiler = {};

  /// Zwischenspeicher der vertrauenswürdigen Schlüssel (der Schlüsselspeicher ist langsam; gültig bis [vertrauenGeaendert]).
  final Map<String, OeffentlicheSchluessel?> _vertrauen = {};

  // ------------------------------------------------------------------ Vertrauen

  OeffentlicheSchluessel get _ich => meinSchluessel.oeffentlich(meineKeyVersion);

  /// Schlüssel für Signaturprüfungen des Verteilers: die eigene Person mit dem eigenen aktuellen Schlüssel, sonst der gemerkte (nie vom Server).
  Future<OeffentlicheSchluessel?> _verteilerSchluessel(String userId, int version) async {
    if (userId == ichId) return version == meineKeyVersion ? _ich : null;
    final key = '$userId:$version';
    if (_verteiler.containsKey(key)) return _verteiler[key];
    // der gemerkte Schlüssel dieser Version (der aktuelle oder ein früher bestätigter); die Version prüft EpochenEmpfaenger (Wrap und Liste nennen sie)
    return _verteiler[key] = await gemerkt(userId, version: version) ?? await gemerkt(userId);
  }

  /// Alle aktiven Mitglieder der Familie (laut letztem Abgleich mit dem Server); ohne diesen Stand nur die eigene Person.
  Set<String> aktiveMitglieder() => {...?serverSchluessel()?.keys, ichId};

  /// Schlüssel, an die dieses Gerät verteilt: gemerkt UND gleich dem aktuellen Schlüssel des Servers (eine ungeprüfte Änderung zählt nicht). Die eigene Person immer.
  Future<OeffentlicheSchluessel?> vertrauenswuerdig(String userId) async {
    if (userId == ichId) return _ich;
    if (_vertrauen.containsKey(userId)) return _vertrauen[userId];
    final g = await gemerkt(userId);
    OeffentlicheSchluessel? ergebnis;
    if (g != null) {
      final karte = serverSchluessel();
      final s = karte?[userId];
      ergebnis = karte == null || (s != null && g.gleichWie(s)) ? g : null;
    }
    _vertrauen[userId] = ergebnis;
    return ergebnis;
  }

  // ------------------------------------------------------------------ Schlüsselbund

  Future<void> _kette = Future<void>.value();

  /// Öffnet die Wraps der eigenen Person und merkt die Epochenschlüssel (nur Arbeitsspeicher). Liefert true, wenn sich etwas geändert hat. Läufe laufen nie
  /// gleichzeitig (der Controller, der Abgleich und die Oberfläche rufen es unabhängig voneinander auf).
  Future<bool> aktualisieren() {
    final f = _kette.then((_) => _aktualisieren());
    _kette = f.then((_) {}, onError: (Object _) {});
    return f;
  }

  Future<bool> _aktualisieren() async {
    final epochen = await db.select(db.konversationEpochen).get();
    final wraps = await (db.select(db.epocheWraps)..where((w) => w.empfaengerId.equals(ichId))).get();
    final konversationen = {for (final k in await db.select(db.konversationen).get()) k.id: k};
    var geaendert = false;

    // Konversationen, die es nicht mehr gibt: Schlüssel vergessen
    for (final id in _ringe.keys.toList()) {
      if (!konversationen.containsKey(id)) {
        _verwerfen(id);
        geaendert = true;
      }
    }
    final nachKonv = <String, List<Epoche>>{};
    for (final e in epochen) {
      if (konversationen[e.konversationId]?.encVersion == 'e1') (nachKonv[e.konversationId] ??= []).add(e);
    }
    final wrapNach = {for (final w in wraps) '${w.konversationId}:${w.epoche}': w};
    // Konversationen ohne jede Epoche (Zeilen sind verschwunden): ihre Schlüssel im Speicher gehen mit
    for (final id in _ringe.keys.toList()) {
      if (!nachKonv.containsKey(id)) {
        _verwerfen(id);
        geaendert = true;
      }
    }

    for (final eintrag in nachKonv.entries) {
      final conv = eintrag.key;
      // aufsteigend: die zuletzt akzeptierte Mitgliederliste wächst von Epoche zu Epoche
      final liste = [...eintrag.value]..sort((a, b) => a.epoche.compareTo(b.epoche));
      final stand0 = await _standLaden(conv);
      final vorab = stand0?.epochen ?? const <int>{};
      final vorabMin = vorab.isEmpty ? null : vorab.reduce((a, b) => a < b ? a : b);
      Map<String, int>? basis;
      final angenommen = <int>{};
      final zurueck = <_Zurueck>[];
      final ring = _ringe.putIfAbsent(conv, _Ring.new);
      // 1. regulärer Weg: die Mitgliederliste der Epoche nennt die Person
      final regulaer = <int, ({SignierteMitgliederListe liste, OeffentlicheSchluessel verteiler})>{};
      final spaeter = <Epoche>[];

      // Entscheidet über eine geöffnete Epoche (Signatur ist geprüft): angenommen (basis wird fortgeschrieben) oder zurückgestellt.
      void pruefeAnnahme(Epoche e, SignierteMitgliederListe signiert, _Zurueck? z0, Uint8List key, String marke, OeffentlicheSchluessel verteiler) {
        // schon früher von diesem Gerät akzeptiert (dauerhafter Stand), eigene Epoche, oder noch keine Basis (erste Epoche: Vertrauen beim ersten Sehen)
        final frueherAkzeptiert = vorab.contains(e.epoche) || (vorabMin != null && e.epoche < vorabMin);
        final b = basis ?? stand0?.liste;
        final extra = frueherAkzeptiert || b == null || signiert.verteilerId == ichId ? <String>{} : {for (final m in signiert.liste.mitglieder) m.userId}.difference(b.keys.toSet());
        if (extra.isNotEmpty) {
          if (z0 != null) {
            z0.extra = extra;
            zurueck.add(z0);
          } else {
            final z = _Zurueck(e, key, marke, signiert, verteiler, extra);
            _gehalten['$conv:${e.epoche}'] = z;
            zurueck.add(z);
          }
          _problem(conv, e.epoche, NichtLesbarGrund.schluesselFehlt);
          return;
        }
        basis = _basisVon(signiert);
        angenommen.add(e.epoche);
        ring.schluessel[e.epoche] = key;
        ring.stand[e.epoche] = marke;
        _probleme[conv]?.remove(e.epoche);
        regulaer[e.epoche] = (liste: signiert, verteiler: verteiler);
        _gehalten.remove('$conv:${e.epoche}');
        geaendert = true;
      }

      for (final e in liste) {
        final w = wrapNach['$conv:${e.epoche}'];
        if (w == null) {
          if (!ring.schluessel.containsKey(e.epoche)) _problem(conv, e.epoche, NichtLesbarGrund.schluesselFehlt);
          continue;
        }
        final marke = _marke(e, w);
        SignierteMitgliederListe signiert;
        try {
          signiert = SignierteMitgliederListe.dekodieren(e.mitglieder);
        } on CryptoFehler {
          _problem(conv, e.epoche, NichtLesbarGrund.beschaedigt);
          continue;
        }
        final eingetragen = signiert.liste.versionVon(ichId);
        if (eingetragen == null) {
          spaeter.add(e);
          continue;
        }
        if (eingetragen != meineKeyVersion) {
          // die Epoche wurde für einen früheren Schlüssel dieser Person verteilt (Schlüsselwechsel): ihr Verlauf ist mit dem neuen Schlüssel nicht mehr lesbar
          _problem(conv, e.epoche, NichtLesbarGrund.schluesselFehlt);
          continue;
        }
        if (ring.schluessel.containsKey(e.epoche) && ring.stand[e.epoche] == marke) {
          basis = _basisVon(signiert); // war schon akzeptiert
          angenommen.add(e.epoche);
          final v = await _verteilerSchluessel(signiert.verteilerId, signiert.verteilerKeyVersion);
          if (v != null) regulaer[e.epoche] = (liste: signiert, verteiler: v);
          continue;
        }
        // schon geöffnet und zurückgestellt: nicht erneut öffnen, nur neu entscheiden
        final gehalten = _gehalten['$conv:${e.epoche}'];
        if (gehalten != null) {
          if (gehalten.marke == marke) {
            pruefeAnnahme(e, signiert, gehalten, gehalten.key, marke, gehalten.verteiler);
            continue;
          }
          loescheBytes(gehalten.key);
          _gehalten.remove('$conv:${e.epoche}');
        }
        if (_gescheitertBei['$conv:${e.epoche}:$marke'] == _vertrauensStempel) continue;
        final r = await _regulaerOeffnen(conv, e, w, signiert);
        if (r != null) {
          pruefeAnnahme(e, signiert, null, r.key, marke, r.verteiler);
        } else {
          _gescheitertBei['$conv:${e.epoche}:$marke'] = _vertrauensStempel;
        }
      }
      // zurückgestellte Epochen gelten nachträglich, wenn ihre zusätzlichen Personen inzwischen in der akzeptierten Liste stehen (z. B. durch die eigene Aufnahme)
      final offen = <int, Set<String>>{};
      final endBasis = basis;
      for (final z in zurueck) {
        if (endBasis != null && z.extra.every(endBasis.containsKey)) {
          _gehalten.remove('$conv:${z.epoche.epoche}');
          ring.schluessel[z.epoche.epoche] = z.key;
          ring.stand[z.epoche.epoche] = z.marke;
          _probleme[conv]?.remove(z.epoche.epoche);
          regulaer[z.epoche.epoche] = (liste: z.liste, verteiler: z.verteiler);
          angenommen.add(z.epoche.epoche);
          geaendert = true;
        } else {
          offen[z.epoche.epoche] = z.extra;
        }
      }
      // gehaltene Epochen, die es nicht mehr gibt, vergessen (Schlüssel überschreiben)
      for (final k in _gehalten.keys.where((k) => k.startsWith('$conv:')).toList()) {
        final ep = int.tryParse(k.substring(conv.length + 1));
        if (ep == null || !offen.containsKey(ep)) loescheBytes(_gehalten.remove(k)!.key);
      }
      if (offen.isEmpty) {
        _zurueckgestellt.remove(conv);
      } else {
        _zurueckgestellt[conv] = offen;
      }
      if (endBasis == null) {
        _akzeptiert.remove(conv);
      } else {
        _akzeptiert[conv] = endBasis;
        // dauerhaft festhalten (am Vertrauensspeicher verankert), wenn sich etwas geändert hat
        final alle = {...vorab, ...angenommen};
        final sortiert = alle.toList()..sort();
        final behalten = sortiert.length > kMaxMerkEpochen ? sortiert.sublist(sortiert.length - kMaxMerkEpochen).toSet() : alle;
        final alt = stand0;
        final gleichListe = alt != null && alt.liste.length == endBasis.length && endBasis.entries.every((x) => alt.liste[x.key] == x.value);
        if (alt == null || !gleichListe || behalten.length != alt.epochen.length || !behalten.containsAll(alt.epochen)) {
          await _standSpeichern(conv, AkzeptierterStand(behalten, Map.of(endBasis)));
        }
      }
      // 2. Verlauf: ältere Epochen, die ein Mitglied beim Aufnehmen geteilt hat; Bürge ist die aktuelle, geprüfte Liste
      if (regulaer.isNotEmpty) {
        final hoechste = regulaer.keys.reduce((a, b) => a > b ? a : b);
        final aktuell = regulaer[hoechste]!;
        for (final e in spaeter) {
          if (e.epoche >= hoechste) continue;
          final w = wrapNach['$conv:${e.epoche}']!;
          final marke = '${_marke(e, w)}|h$hoechste';
          if (ring.schluessel.containsKey(e.epoche) && ring.stand[e.epoche] == marke) continue;
          if (_gescheitertBei['$conv:${e.epoche}:$marke'] == _vertrauensStempel) continue;
          final key = await _historieOeffnen(conv, e, w, aktuell.liste, hoechste, aktuell.verteiler);
          if (key != null) {
            ring.schluessel[e.epoche] = key;
            ring.stand[e.epoche] = marke;
            _probleme[conv]?.remove(e.epoche);
            geaendert = true;
          } else {
            _gescheitertBei['$conv:${e.epoche}:$marke'] = _vertrauensStempel;
          }
        }
      }
      for (final e in spaeter) {
        if (!ring.schluessel.containsKey(e.epoche) && !(_probleme[conv]?.containsKey(e.epoche) ?? false)) _problem(conv, e.epoche, NichtLesbarGrund.schluesselFehlt);
      }
      // Verschwindet die Epochenzeile oder der eigene Wrap lokal (Neuaufbau, gelöscht), gehört der Schlüssel im Speicher nicht mehr dazu: überschreiben und entfernen
      final vorhandeneEpochen = {for (final e in liste) if (wrapNach.containsKey('$conv:${e.epoche}')) e.epoche};
      for (final ep in ring.schluessel.keys.toList()) {
        if (!vorhandeneEpochen.contains(ep)) {
          loescheBytes(ring.schluessel.remove(ep)!);
          ring.stand.remove(ep);
          geaendert = true;
        }
      }
    }
    return geaendert;
  }

  static Map<String, int> _basisVon(SignierteMitgliederListe s) => {for (final m in s.liste.mitglieder) m.userId: m.keyVersion};

  String _marke(Epoche e, EpocheWrapZeile w) => c.sha256.convert(utf8.encode('${e.mitglieder}|${w.wrap}')).toString();

  void _problem(String conv, int epoche, NichtLesbarGrund grund) => (_probleme[conv] ??= {})[epoche] = grund;

  void _verwerfen(String conv) {
    final r = _ringe.remove(conv);
    if (r != null) {
      for (final k in r.schluessel.values) {
        loescheBytes(k);
      }
    }
    _probleme.remove(conv);
    _akzeptiert.remove(conv);
    _zurueckgestellt.remove(conv);
    for (final k in _gehalten.keys.where((k) => k.startsWith('$conv:')).toList()) {
      loescheBytes(_gehalten.remove(k)!.key);
    }
  }

  /// Vergisst alle Schlüssel im Arbeitsspeicher (Abmelden, Schlüsselwechsel).
  void vergessen() {
    for (final id in _ringe.keys.toList()) {
      _verwerfen(id);
    }
    for (final z in _gehalten.values) {
      loescheBytes(z.key);
    }
    _gehalten.clear();
    _zurueckgestellt.clear();
  }

  Future<({Uint8List key, OeffentlicheSchluessel verteiler})?> _regulaerOeffnen(String conv, Epoche e, EpocheWrapZeile w, SignierteMitgliederListe signiert) async {
    try {
      final wrap = EpochenWrap.dekodieren(w.wrap);
      final verteiler = await _verteilerSchluessel(signiert.verteilerId, signiert.verteilerKeyVersion);
      if (verteiler == null) {
        _problem(conv, e.epoche, NichtLesbarGrund.absenderUnbekannt);
        return null;
      }
      final key = EpochenEmpfaenger.uebernehmen(
        crypto,
        wrap: wrap,
        liste: signiert,
        erwarteteConversationId: conv,
        erwarteteEpoche: e.epoche,
        ichId: ichId,
        meinSchluessel: meinSchluessel,
        meineKeyVersion: meineKeyVersion,
        verteiler: verteiler,
      );
      return (key: key, verteiler: verteiler);
    } on CryptoFehler catch (f) {
      _problem(conv, e.epoche, _grund(f));
      return null;
    }
  }

  Future<Uint8List?> _historieOeffnen(String conv, Epoche e, EpocheWrapZeile w, SignierteMitgliederListe aktuelleListe, int aktuelleEpoche, OeffentlicheSchluessel aktuellerVerteiler) async {
    try {
      final wrap = EpochenWrap.dekodieren(w.wrap);
      final wrapVerteiler = await _verteilerSchluessel(wrap.verteilerId, wrap.verteilerKeyVersion);
      if (wrapVerteiler == null) {
        _problem(conv, e.epoche, NichtLesbarGrund.absenderUnbekannt);
        return null;
      }
      return EpochenEmpfaenger.historieUebernehmen(
        crypto,
        wrap: wrap,
        erwarteteConversationId: conv,
        erwarteteEpoche: e.epoche,
        aktuelleListe: aktuelleListe,
        aktuelleEpoche: aktuelleEpoche,
        aktuellerVerteiler: aktuellerVerteiler,
        ichId: ichId,
        meinSchluessel: meinSchluessel,
        meineKeyVersion: meineKeyVersion,
        wrapVerteiler: wrapVerteiler,
        alteListe: _alteListe(e, wrap, wrapVerteiler),
      );
    } on CryptoFehler catch (f) {
      _problem(conv, e.epoche, _grund(f));
      return null;
    }
  }

  /// Die Mitgliederliste der älteren Epoche, wenn sie vom Verteiler des Wraps signiert ist (dann prüft die Übernahme den Schlüssel gegen ihre Verpflichtung).
  MitgliederListe? _alteListe(Epoche e, EpochenWrap wrap, OeffentlicheSchluessel wrapVerteiler) {
    try {
      final s = SignierteMitgliederListe.dekodieren(e.mitglieder);
      if (s.verteilerId != wrap.verteilerId) return null;
      return EpochenEmpfaenger.alteListeGeprueft(crypto, signiert: s, verteiler: wrapVerteiler);
    } on CryptoFehler {
      return null;
    }
  }

  static NichtLesbarGrund _grund(CryptoFehler f) => switch (f.art) {
    CryptoFehlerArt.signatur => NichtLesbarGrund.signaturUngueltig,
    CryptoFehlerArt.version => NichtLesbarGrund.neuereVersion,
    CryptoFehlerArt.schluessel => NichtLesbarGrund.absenderUnbekannt,
    CryptoFehlerArt.entschluesselung => NichtLesbarGrund.schluesselFehlt,
    _ => NichtLesbarGrund.beschaedigt,
  };

  /// Epochenschlüssel im Speicher (null: nicht geöffnet).
  Uint8List? schluessel(String konversationId, int epoche) => _ringe[konversationId]?.schluessel[epoche];

  /// Epochen der Konversation, für die dieses Gerät den Schlüssel hat.
  List<int> epochenMitSchluessel(String konversationId) => [...?_ringe[konversationId]?.schluessel.keys]..sort();

  NichtLesbarGrund? problem(String konversationId, int epoche) => _probleme[konversationId]?[epoche];

  // ------------------------------------------------------------------ Epochen und Wraps lesen

  Future<List<Epoche>> _epochen(String konversationId) =>
      (db.select(db.konversationEpochen)
            ..where((e) => e.konversationId.equals(konversationId))
            ..orderBy([(e) => OrderingTerm.desc(e.epoche)]))
          .get();

  /// Mitglieder der höchsten Epoche (aus der signierten Liste, ungeprüft: nur zur Anzeige und für den Vergleich), null ohne Epoche.
  Future<List<EpochenMitglied>?> aktuelleMitglieder(String konversationId) async {
    final epochen = await _epochen(konversationId);
    if (epochen.isEmpty) return null;
    try {
      final l = SignierteMitgliederListe.dekodieren(epochen.first.mitglieder).liste;
      return [for (final m in l.mitglieder) EpochenMitglied(m.userId, m.keyVersion)];
    } on CryptoFehler {
      return null;
    }
  }

  /// Höchste Epoche, die der Server bestätigt hat und für die dieses Gerät den Schlüssel hat. Liefert (epoche, wartetAufNeuere): wartet ist true, wenn es eine
  /// neuere (oder noch unbestätigte) Epoche gibt, deren Schlüssel noch fehlt: dann wird nicht mit der älteren verschlüsselt.
  Future<({int? epoche, bool wartet})> sendeEpoche(String konversationId) async {
    final epochen = await _epochen(konversationId);
    if (epochen.isEmpty) return (epoche: null, wartet: true);
    final hoechste = epochen.first;
    // eine eigene, noch nicht bestätigte Epoche: erst nach der Bestätigung benutzen (bei einer verlorenen Rotation wäre die Nachricht sonst unlesbar)
    if (hoechste.rev == 0) return (epoche: null, wartet: true);
    final key = schluessel(konversationId, hoechste.epoche);
    if (key == null) return (epoche: null, wartet: true);
    // nur an Personen der akzeptierten Liste: eine Epoche mit unbestätigten Personen wird nicht benutzt
    final basis = _akzeptiert[konversationId];
    try {
      final ids = SignierteMitgliederListe.dekodieren(hoechste.mitglieder).liste.mitglieder.map((m) => m.userId);
      if (basis == null || !ids.every(basis.containsKey)) return (epoche: null, wartet: true);
    } on CryptoFehler {
      return (epoche: null, wartet: true);
    }
    return (epoche: hoechste.epoche, wartet: false);
  }

  // ------------------------------------------------------------------ Nachrichten

  /// Verschlüsselt eine Nachricht für den Versand (Hülle `e1:`); null, wenn jetzt nicht verschlüsselt werden kann (der Aufrufer wartet).
  Future<String?> nachrichtVersiegeln({required String konversationId, required String nachrichtId, required String klartext, String? antwortAuf}) async {
    final bytes = utf8.encode(klartext);
    if (bytes.length > kMaxNachrichtBytes) throw const VerschluesselungNichtBereit('Die Nachricht ist zu lang.');
    final s = await sendeEpoche(konversationId);
    final epoche = s.epoche;
    if (epoche == null) return null;
    final key = schluessel(konversationId, epoche);
    if (key == null) return null;
    final wire = _huelle.versiegeln(
      schluessel: key,
      klartext: Uint8List.fromList(bytes),
      kontext: HuellenKontext(conversationId: konversationId, messageId: nachrichtId, senderId: ichId, epoch: epoche, senderKeyVersion: meineKeyVersion, antwortAuf: antwortAuf),
      signGeheim: meinSchluessel.signGeheim,
    );
    return '$kPraefixE1$wire';
  }

  /// Epoche, mit der eine `e1:`-Hülle verschlüsselt ist (null: keine gültige Hülle).
  static int? huellenEpoche(String wire) {
    if (!wire.startsWith(kPraefixE1)) return null;
    try {
      return HuellenCodec.epocheLesen(wire.substring(kPraefixE1.length));
    } on CryptoFehler {
      return null;
    }
  }

  /// Eine eigene, schon verschlüsselte Nachricht im Ausgang mit der höchsten bestätigten Epoche neu verschlüsseln, wenn inzwischen eine neuere bekannt ist (eine
  /// Rotation lag dazwischen: sonst könnte ein inzwischen entferntes Mitglied sie noch lesen). Liefert die neue Hülle, [wire] unverändert (schon aktuell oder
  /// nicht neu zu verschlüsseln) oder null (die neuere Epoche ist noch nicht bereit: die Nachricht wartet).
  Future<String?> nachrichtNeuVersiegeln({required String konversationId, required String nachrichtId, required String wire, String? antwortAuf}) async {
    final alt = huellenEpoche(wire);
    if (alt == null) return wire;
    final s = await sendeEpoche(konversationId);
    final neu = s.epoche;
    if (neu == null) return null;
    if (alt >= neu) return wire;
    final d = await nachrichtOeffnen(konversationId: konversationId, nachrichtId: nachrichtId, autorId: ichId, wire: wire, antwortAuf: antwortAuf);
    if (!d.lesbar) return wire; // die alte Epoche lässt sich nicht mehr öffnen: es bleibt, wie es ist
    return nachrichtVersiegeln(konversationId: konversationId, nachrichtId: nachrichtId, klartext: d.text, antwortAuf: antwortAuf);
  }

  /// Öffnet eine verschlüsselte Nachricht (`e1:`). Prüft zuerst die Signatur gegen den Schlüssel des Absenders in der Version der Hülle, entschlüsselt erst danach.
  Future<DekodierterInhalt> nachrichtOeffnen({required String konversationId, required String nachrichtId, required String? autorId, required String wire, String? antwortAuf}) async {
    if (!wire.startsWith(kPraefixE1)) return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'unverschlüsselt');
    final huelle = wire.substring(kPraefixE1.length);
    if (autorId == null) return const DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: 'Absender nicht mehr in der Familie');
    try {
      final epoche = HuellenCodec.epocheLesen(huelle);
      final senderVersion = HuellenCodec.senderKeyVersionLesen(huelle);
      final key = schluessel(konversationId, epoche);
      if (key == null) {
        final p = problem(konversationId, epoche);
        return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(p ?? NichtLesbarGrund.schluesselFehlt));
      }
      final OeffentlicheSchluessel sender;
      if (autorId == ichId && senderVersion == meineKeyVersion) {
        sender = _ich;
      } else {
        try {
          sender = await absenderSchluessel(autorId, senderVersion);
        } on CryptoFehler catch (f) {
          // ein Schlüssel, den dieses Gerät nie bestätigt hat, gilt nicht (kein Nachladen vom Server): "Absender nicht bestätigt"
          return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(f.art == CryptoFehlerArt.signatur ? NichtLesbarGrund.signaturUngueltig : NichtLesbarGrund.absenderUnbekannt));
        } on Object {
          return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(NichtLesbarGrund.absenderUnbekannt));
        }
      }
      final klar = _huelle.oeffnen(
        schluessel: key,
        huelle: huelle,
        kontext: HuellenKontext(conversationId: konversationId, messageId: nachrichtId, senderId: autorId, epoch: epoche, senderKeyVersion: senderVersion, antwortAuf: antwortAuf),
        sender: sender,
      );
      try {
        return DekodierterInhalt(utf8.decode(klar), InhaltStatus.bereit);
      } on FormatException {
        return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(NichtLesbarGrund.beschaedigt));
      } finally {
        loescheBytes(klar);
      }
    } on CryptoFehler catch (f) {
      return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(_grund(f)));
    }
  }

  static String _hinweis(NichtLesbarGrund g) => switch (g) {
    NichtLesbarGrund.schluesselFehlt => 'warte auf Schlüssel',
    NichtLesbarGrund.absenderUnbekannt => 'Absender noch nicht bekannt',
    NichtLesbarGrund.signaturUngueltig => 'Absender nicht bestätigt',
    NichtLesbarGrund.beschaedigt => 'beschädigt',
    NichtLesbarGrund.neuereVersion => 'neuere App-Version nötig',
    NichtLesbarGrund.unverschluesselt => 'unverschlüsselt',
  };

  // ------------------------------------------------------------------ Rotation

  /// Personen, die als Empfänger einer neuen Epoche in Frage kommen: die gewünschten Mitglieder mit vertrauenswürdigem Schlüssel. [fehlend] sind die ohne.
  Future<({Map<String, OeffentlicheSchluessel> schluessel, List<String> fehlend})> empfaenger(Iterable<String> mitglieder) async {
    final ok = <String, OeffentlicheSchluessel>{};
    final fehlend = <String>[];
    for (final u in {...mitglieder, ichId}) {
      final k = await vertrauenswuerdig(u);
      if (k == null) {
        fehlend.add(u);
      } else {
        ok[u] = k;
      }
    }
    return (schluessel: ok, fehlend: fehlend);
  }

  /// Änderungen für eine NEUE Epoche der Konversation (Epochennummer = höchste vorhandene + 1): frischer Epochenschlüssel, signierte Mitgliederliste und ein Wrap je
  /// Mitglied. Mit [historieFuer] bekommen diese Personen zusätzlich die Schlüssel der älteren Epochen, die dieses Gerät kennt ("Verlauf teilen"). Wirft
  /// [SchluesselFehlt], wenn jemand aus [mitglieder] keinen vertrauenswürdigen Schlüssel hat (außer [ueberspringen]: diese werden ausgelassen, z. B. ungeprüfte).
  /// Die Aufrufer schreiben die Änderungen in EINER Transaktion zusammen mit der Änderung der Konversation (SyncStore.aendernMehrere).
  Future<List<SyncAenderung>> epocheErstellen({
    required String konversationId,
    required Set<String> mitglieder,
    Set<String> historieFuer = const {},
    bool unvertrauteAuslassen = false,
  }) async {
    final e = await empfaenger(mitglieder);
    if (e.fehlend.isNotEmpty && !unvertrauteAuslassen) throw SchluesselFehlt(e.fehlend);
    if (!e.schluessel.containsKey(ichId)) throw const VerschluesselungNichtBereit('Dein Schlüssel ist nicht bereit.');
    final vorhandene = await _epochen(konversationId);
    final nummer = (vorhandene.isEmpty ? 0 : vorhandene.first.epoche) + 1;
    if (nummer > 100000) throw const VerschluesselungNichtBereit('Zu viele Schlüsselwechsel.');
    final epochenKey = crypto.zufall(32);
    try {
      final liste = MitgliederListe.erstellen(
        conversationId: konversationId,
        epoch: nummer,
        mitglieder: [for (final m in e.schluessel.entries) MitgliedEintrag(m.key, m.value.version)],
        schluesselCommitment: schluesselCommitmentBerechnen(crypto, epochenschluessel: epochenKey, conversationId: konversationId, epoch: nummer),
      );
      final signiert = EpochenVerteiler.listeSignieren(crypto, liste: liste, verteilerId: ichId, verteilerKeyVersion: meineKeyVersion, verteilerSignGeheim: meinSchluessel.signGeheim);
      final aenderungen = <SyncAenderung>[
        SyncAenderung('epoche', epocheId(konversationId, nummer), {'konversationId': konversationId, 'epoche': nummer, 'mitglieder': signiert.kodieren()}),
      ];
      SyncAenderung wrapFuer(int epoche, Uint8List key, String user, OeffentlicheSchluessel empf) {
        final w = EpochenVerteiler.wrapErstellen(
          crypto,
          epochenschluessel: key,
          conversationId: konversationId,
          epoch: epoche,
          empfaengerId: user,
          empfaenger: empf,
          verteilerId: ichId,
          verteilerKeyVersion: meineKeyVersion,
          verteilerSignGeheim: meinSchluessel.signGeheim,
        );
        return SyncAenderung(
          'epoche_wrap',
          wrapId(konversationId, epoche, user),
          {'konversationId': konversationId, 'epoche': epoche, 'empfaengerId': user, 'wrap': w.kodieren()},
        );
      }

      for (final m in e.schluessel.entries) {
        aenderungen.add(wrapFuer(nummer, epochenKey, m.key, m.value));
      }
      // Verlauf teilen: ältere Epochen, deren Schlüssel dieses Gerät kennt, für die genannten Personen (die den Wrap noch nicht haben)
      if (historieFuer.isNotEmpty) {
        final bekannte = await (db.select(db.epocheWraps)..where((w) => w.konversationId.equals(konversationId))).get();
        final vergeben = {for (final w in bekannte) '${w.epoche}:${w.empfaengerId}'};
        for (final alt in epochenMitSchluessel(konversationId)) {
          final key = schluessel(konversationId, alt)!;
          for (final u in historieFuer) {
            final k = e.schluessel[u];
            if (k == null || u == ichId || vergeben.contains('$alt:$u')) continue;
            aenderungen.add(wrapFuer(alt, key, u, k));
          }
        }
      }
      return aenderungen;
    } finally {
      loescheBytes(epochenKey);
    }
  }

  /// Soll für die Konversation eine neue Epoche angelegt werden, damit die Mitglieder der letzten Epoche zu den heutigen Teilnehmern passen? Liefert den
  /// [RotationsPlan] (null: nichts zu tun).
  ///  - Entfernt: Personen der Liste, die nicht mehr Teilnehmer oder nicht mehr aktiv sind: neue Epoche ohne sie. Dass eine Person aus der Familie verschwunden ist,
  ///    gilt erst, wenn sie in zwei aufeinanderfolgenden Abrufen der Mitglieder fehlt ([mitgliederBeobachtet]).
  ///  - Hinzugekommen: Teilnehmer mit vertrauenswürdigem Schlüssel, die nicht in der Liste stehen (nur auf Bestätigung, siehe [RotationsPlan]).
  ///  - Neuer Schlüssel einer Person, der dieses Gerät vertraut (die Liste kennt die alte Version): sie bekommt die neue Epoche.
  ///  - Heilung: die höchste Epoche nennt dieses Gerät mit seinem aktuellen Schlüssel, ist aber seit [heilungsFrist] nicht lesbar (fehlender oder ungültiger Wrap,
  ///    z. B. eine absichtlich angelegte Epoche ohne gültige Wraps): ein Gerät mit Schlüssel legt die nächste an.
  /// Eine Person mit ungeprüfter Schlüsseländerung löst NICHTS aus (sonst schaukeln sich Geräte mit verschiedenem Vertrauen gegenseitig hoch).
  Future<RotationsPlan?> rotationNoetig({required Konversation konversation, required Set<String> teilnehmer}) async {
    if (konversation.encVersion != 'e1' || konversation.rev == 0) return null;
    final epochen = await _epochen(konversation.id);
    if (epochen.isEmpty) return null;
    final letzte = epochen.first;
    if (letzte.rev == 0) return null; // eine eigene Rotation ist unterwegs
    final SignierteMitgliederListe signiert;
    try {
      signiert = SignierteMitgliederListe.dekodieren(letzte.mitglieder);
    } on CryptoFehler {
      return null;
    }
    // Vergleichsbasis: die zuletzt AKZEPTIERTE Liste (nicht die der höchsten Epoche, die unbestätigte Personen enthalten kann)
    final liste = _akzeptiert[konversation.id] ?? {for (final m in signiert.liste.mitglieder) m.userId: m.keyVersion};
    final aktiv = serverSchluessel();
    if (aktiv == null) return null;
    // Selbstheilung: die höchste Epoche nennt mich mit meinem Schlüssel (oder gar nicht, obwohl dieses Gerät frühere Schlüssel hat), ist aber nicht lesbar
    var heilung = false;
    final hk = '${konversation.id}:${letzte.epoche}';
    final inLetzter = signiert.liste.versionVon(ichId);
    final heilbar = inLetzter == meineKeyVersion || (inLetzter == null && epochenMitSchluessel(konversation.id).isNotEmpty);
    if (heilbar && schluessel(konversation.id, letzte.epoche) == null) {
      final seit = _ohneSchluesselSeit.putIfAbsent(hk, _jetzt);
      heilung = _jetzt().difference(seit) >= heilungsFrist;
    } else {
      _ohneSchluesselSeit.remove(hk);
    }
    // nur Teilnehmer, die aktive Mitglieder sind (alle Mitglieder beim Familienchat)
    final sollen = konversation.art == _familie ? aktiv.keys.toSet() : teilnehmer.where(aktiv.containsKey).toSet();
    if (!sollen.contains(ichId) && konversation.art != _familie) return null;
    // Eine Epoche, die nur wegen Personen zurückgestellt ist, die jemand aufnehmen will, ist nicht vergiftet: keine Heilung (die würde die Aufgenommenen wieder
    // hinauswerfen), sondern die Aufnahme-Abfrage. Heilung gibt es für Unlesbares und für Epochen mit Personen, die niemand aufnehmen will.
    if (heilung) {
      final zg = _zurueckgestellt[konversation.id]?[letzte.epoche];
      if (zg != null) {
        var alleGewollt = true;
        for (final u in zg) {
          if (!sollen.contains(u) || await vertrauenswuerdig(u) == null) {
            alleGewollt = false;
            break;
          }
        }
        if (alleGewollt) heilung = false;
      }
    }
    _fehltSeit.removeWhere((u, _) => aktiv.containsKey(u));
    final entfernt = <String>{};
    for (final u in liste.keys) {
      if (sollen.contains(u)) continue;
      if (!aktiv.containsKey(u)) {
        // aus der Familie verschwunden: erst beim zweiten Abruf in Folge
        final seit = _fehltSeit.putIfAbsent(u, () => _abrufe);
        if (_abrufe - seit < 1) continue;
      }
      entfernt.add(u);
    }
    final neu = <String>{};
    var versionNeu = false;
    for (final u in sollen) {
      final k = await vertrauenswuerdig(u);
      if (k == null) continue; // ohne Schlüssel oder ungeprüft: nicht auslösen
      final alt = liste[u];
      if (alt == null) {
        neu.add(u);
      } else if (alt != k.version) {
        versionNeu = true;
      }
    }
    if (entfernt.isEmpty && neu.isEmpty && !versionNeu && !heilung) return null;
    // Empfänger der neuen Epoche: alle Sollenden mit vertrauenswürdigem Schlüssel
    final empf = <String>{};
    for (final u in sollen) {
      if (await vertrauenswuerdig(u) != null) empf.add(u);
    }
    if (!empf.contains(ichId)) return null;
    return RotationsPlan(mitglieder: empf, neu: neu, entfernt: entfernt, versionNeu: versionNeu, heilung: heilung);
  }

  // ------------------------------------------------------------------ Verlorene Wraps nachreichen

  /// Empfänger der höchsten Epoche, die dieses Gerät selbst verteilt hat (Verteiler der Epoche = diese Person, Schlüssel im Speicher) und für die es lokal keinen
  /// Wrap gibt, seit mehr als [wrapFrist] (z. B. wegen einer abgelehnten Op). Jede Person nur einmal je Sitzung.
  Future<List<String>> fehlendeWraps(String konversationId) async {
    final epochen = await _epochen(konversationId);
    if (epochen.isEmpty) return const [];
    final e = epochen.first;
    if (e.rev == 0) return const [];
    final key = schluessel(konversationId, e.epoche);
    if (key == null) return const [];
    final SignierteMitgliederListe signiert;
    try {
      signiert = SignierteMitgliederListe.dekodieren(e.mitglieder);
    } on CryptoFehler {
      return const [];
    }
    if (signiert.verteilerId != ichId || signiert.verteilerKeyVersion != meineKeyVersion) return const [];
    final wraps = await (db.select(db.epocheWraps)..where((w) => w.konversationId.equals(konversationId) & w.epoche.equals(e.epoche))).get();
    final da = {for (final w in wraps) w.empfaengerId};
    final fehlt = <String>[];
    for (final m in signiert.liste.mitglieder) {
      final k = '$konversationId:${e.epoche}:${m.userId}';
      if (da.contains(m.userId) || _nachgereicht.contains(k)) {
        _wrapFehltSeit.remove(k);
        continue;
      }
      final seit = _wrapFehltSeit.putIfAbsent(k, _jetzt);
      if (_jetzt().difference(seit) >= wrapFrist) fehlt.add(m.userId);
    }
    return fehlt;
  }

  /// Erzeugt die fehlenden Wraps der höchsten Epoche erneut (gleicher Schlüssel, gleicher Empfänger); nur für Personen, deren Schlüssel noch zu der Version in der
  /// signierten Liste passt und denen dieses Gerät vertraut. Die Aufrufer schreiben sie über [SyncStore.aendernMehrere].
  Future<List<SyncAenderung>> wrapsNachreichen(String konversationId, Iterable<String> personen) async {
    final epochen = await _epochen(konversationId);
    if (epochen.isEmpty) return const [];
    final e = epochen.first;
    final key = schluessel(konversationId, e.epoche);
    if (key == null) return const [];
    final SignierteMitgliederListe signiert;
    try {
      signiert = SignierteMitgliederListe.dekodieren(e.mitglieder);
    } on CryptoFehler {
      return const [];
    }
    final aenderungen = <SyncAenderung>[];
    for (final u in personen) {
      final version = signiert.liste.versionVon(u);
      final k = await vertrauenswuerdig(u);
      _nachgereicht.add('$konversationId:${e.epoche}:$u');
      if (version == null || k == null || k.version != version || u == ichId) continue;
      final w = EpochenVerteiler.wrapErstellen(
        crypto,
        epochenschluessel: key,
        conversationId: konversationId,
        epoch: e.epoche,
        empfaengerId: u,
        empfaenger: k,
        verteilerId: ichId,
        verteilerKeyVersion: meineKeyVersion,
        verteilerSignGeheim: meinSchluessel.signGeheim,
      );
      aenderungen.add(SyncAenderung('epoche_wrap', wrapId(konversationId, e.epoche, u), {'konversationId': konversationId, 'epoche': e.epoche, 'empfaengerId': u, 'wrap': w.kodieren()}));
    }
    return aenderungen;
  }

  /// Wie lange eine Konversation ohne Epoche warten darf, bevor ein anderes Gerät die erste anlegt (der Ersteller legt sie sofort selbst an).
  static const karenz = Duration(seconds: 20);

  /// Konversation ohne jede Epoche (Ersteller ohne Schlüssel oder verlorene Anlage): nach der [karenz] legt ein Teilnehmer mit Schlüssel die erste an.
  Future<Set<String>?> ersteEpocheNoetig({required Konversation konversation, required Set<String> teilnehmer}) async {
    if (konversation.encVersion != 'e1' || konversation.rev == 0) return null;
    // Karenz ab dem Zeitpunkt, an dem DIESES Gerät die Konversation ohne Epoche zuerst gesehen hat (nicht gegen die Uhr eines fremden Geräts)
    if ((await _epochen(konversation.id)).isNotEmpty) {
      _ohneEpocheSeit.remove(konversation.id);
      return null;
    }
    final seit = _ohneEpocheSeit.putIfAbsent(konversation.id, _jetzt);
    if (_jetzt().difference(seit) < karenz) return null;
    final aktiv = serverSchluessel();
    if (aktiv == null) return null;
    final sollen = konversation.art == _familie ? aktiv.keys.toSet() : teilnehmer.where(aktiv.containsKey).toSet();
    final empf = <String>{};
    for (final u in sollen) {
      if (await vertrauenswuerdig(u) != null) empf.add(u);
    }
    if (!empf.contains(ichId) || (konversation.art != _familie && !teilnehmer.contains(ichId))) return null;
    return empf;
  }
}
