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

  /// Zählt jede Änderung des Vertrauens (neue gemerkte Schlüssel, Mitgliederliste): bis dahin gescheiterte Wraps werden dann erneut versucht.
  int _vertrauensStempel = 0;
  final Map<String, int> _gescheitertBei = {};

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
  }) : _huelle = HuellenCodec(crypto),
       _jetzt = jetzt ?? DateTime.now;

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

    for (final eintrag in nachKonv.entries) {
      final conv = eintrag.key;
      final liste = [...eintrag.value]..sort((a, b) => b.epoche.compareTo(a.epoche));
      final ring = _ringe.putIfAbsent(conv, _Ring.new);
      // 1. regulärer Weg: die Mitgliederliste der Epoche nennt die Person
      final regulaer = <int, ({SignierteMitgliederListe liste, OeffentlicheSchluessel verteiler})>{};
      final spaeter = <Epoche>[];
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
          final v = await _verteilerSchluessel(signiert.verteilerId, signiert.verteilerKeyVersion);
          if (v != null) regulaer[e.epoche] = (liste: signiert, verteiler: v);
          continue;
        }
        if (_gescheitertBei['$conv:${e.epoche}:$marke'] == _vertrauensStempel) continue;
        final r = await _regulaerOeffnen(conv, e, w, signiert);
        if (r != null) {
          ring.schluessel[e.epoche] = r.key;
          ring.stand[e.epoche] = marke;
          _probleme[conv]?.remove(e.epoche);
          regulaer[e.epoche] = (liste: signiert, verteiler: r.verteiler);
          geaendert = true;
        } else {
          _gescheitertBei['$conv:${e.epoche}:$marke'] = _vertrauensStempel;
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
    }
    return geaendert;
  }

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
  }

  /// Vergisst alle Schlüssel im Arbeitsspeicher (Abmelden, Schlüsselwechsel).
  void vergessen() {
    for (final id in _ringe.keys.toList()) {
      _verwerfen(id);
    }
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
      );
    } on CryptoFehler catch (f) {
      _problem(conv, e.epoche, _grund(f));
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
    return (epoche: hoechste.epoche, wartet: false);
  }

  // ------------------------------------------------------------------ Nachrichten

  /// Verschlüsselt eine Nachricht für den Versand (Hülle `e1:`); null, wenn jetzt nicht verschlüsselt werden kann (der Aufrufer wartet).
  Future<String?> nachrichtVersiegeln({required String konversationId, required String nachrichtId, required String klartext}) async {
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
      kontext: HuellenKontext(conversationId: konversationId, messageId: nachrichtId, senderId: ichId, epoch: epoche, senderKeyVersion: meineKeyVersion),
      signGeheim: meinSchluessel.signGeheim,
    );
    return '$kPraefixE1$wire';
  }

  /// Öffnet eine verschlüsselte Nachricht (`e1:`). Prüft zuerst die Signatur gegen den Schlüssel des Absenders in der Version der Hülle, entschlüsselt erst danach.
  Future<DekodierterInhalt> nachrichtOeffnen({required String konversationId, required String nachrichtId, required String? autorId, required String wire}) async {
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
        } on CryptoFehler {
          return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(NichtLesbarGrund.absenderUnbekannt));
        } on Object {
          return DekodierterInhalt('', InhaltStatus.nichtEntschluesselbar, hinweis: _hinweis(NichtLesbarGrund.absenderUnbekannt));
        }
      }
      final klar = _huelle.oeffnen(
        schluessel: key,
        huelle: huelle,
        kontext: HuellenKontext(conversationId: konversationId, messageId: nachrichtId, senderId: autorId, epoch: epoche, senderKeyVersion: senderVersion),
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

  /// Soll für die Konversation eine neue Epoche angelegt werden, damit die Mitglieder der letzten Epoche zu den heutigen Teilnehmern passen? Liefert die
  /// Personen für die neue Epoche und die neu hinzugekommenen (null: nichts zu tun).
  ///  - Entfernt: Personen der Liste, die nicht mehr Teilnehmer oder nicht mehr aktiv sind: neue Epoche ohne sie.
  ///  - Hinzugekommen: Teilnehmer mit vertrauenswürdigem Schlüssel, die nicht in der Liste stehen (Schlüssel eingerichtet, aufgenommen).
  ///  - Neuer Schlüssel einer Person, der dieses Gerät vertraut (die Liste kennt die alte Version): sie bekommt die neue Epoche.
  /// Eine Person mit ungeprüfter Schlüsseländerung löst NICHTS aus (sonst schaukeln sich Geräte mit verschiedenem Vertrauen gegenseitig hoch).
  Future<({Set<String> mitglieder, Set<String> neu})?> rotationNoetig({required Konversation konversation, required Set<String> teilnehmer}) async {
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
    final liste = {for (final m in signiert.liste.mitglieder) m.userId: m.keyVersion};
    final aktiv = serverSchluessel();
    if (aktiv == null) return null;
    // nur Teilnehmer, die aktive Mitglieder sind (alle Mitglieder beim Familienchat)
    final sollen = konversation.art == _familie ? aktiv.keys.toSet() : teilnehmer.where(aktiv.containsKey).toSet();
    if (!sollen.contains(ichId) && konversation.art != _familie) return null;
    final entfernt = liste.keys.where((u) => !sollen.contains(u)).toSet();
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
    if (entfernt.isEmpty && neu.isEmpty && !versionNeu) return null;
    // Empfänger der neuen Epoche: alle Sollenden mit vertrauenswürdigem Schlüssel
    final empf = <String>{};
    for (final u in sollen) {
      if (await vertrauenswuerdig(u) != null) empf.add(u);
    }
    if (!empf.contains(ichId)) return null;
    return (mitglieder: empf, neu: neu);
  }

  /// Wie lange eine Konversation ohne Epoche warten darf, bevor ein anderes Gerät die erste anlegt (der Ersteller legt sie sofort selbst an).
  static const karenz = Duration(seconds: 20);

  /// Konversation ohne jede Epoche (Ersteller ohne Schlüssel oder verlorene Anlage): nach der [karenz] legt ein Teilnehmer mit Schlüssel die erste an.
  Future<Set<String>?> ersteEpocheNoetig({required Konversation konversation, required Set<String> teilnehmer}) async {
    if (konversation.encVersion != 'e1' || konversation.rev == 0) return null;
    if (_jetzt().difference(konversation.createdAt) < karenz) return null;
    if ((await _epochen(konversation.id)).isNotEmpty) return null;
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
