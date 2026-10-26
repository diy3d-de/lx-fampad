// Abläufe der Eltern-Wiederherstellung für Kinder (Projektbeschreibung 9a): Kind-Seite (Einwilligung/Hinterlegung, Anfrage mit Wartefrist, Offenlegung, Kurzcode, Abholen)
// und Eltern-Seite (Übersicht, Anfrage übernehmen, Kurzcode prüfen, freigeben oder ablehnen). Die Kryptografie steht in eltern_wiederherstellung.dart.
// Grundsätze: nur mit Zustimmung des Kindes; nie ein neuer Personenschlüssel und nie ein vorhandener lokaler Schlüssel wird stillschweigend ersetzt (Übernahme nur über
// E2eeController.schluesselUebernehmen, das gegen den Schlüssel des Servers prüft); es wird nur an Schlüssel hinterlegt und nur Signaturen geprüft, die GEMERKT (TOFU)
// und gleich dem Schlüssel des Servers sind. Das geheime flüchtige Schlüsselpaar des Kindes liegt nur im Schlüsselspeicher dieses Geräts, bis die Anfrage endet.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/eltern_modelle.dart';
import '../api/models.dart';
import '../auth/auth_state.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'e2ee_state.dart';
import 'eltern_wiederherstellung.dart';
import 'schluessel.dart';
import 'vertrauen.dart';

/// Ergebnis der Einwilligung: wer hinterlegt wurde und wer fehlt (kein bestätigter Schlüssel auf diesem Gerät).
class EinwilligungErgebnis {
  final List<String> hinterlegt;
  final List<String> uebersprungen;
  const EinwilligungErgebnis(this.hinterlegt, this.uebersprungen);
}

/// Die Anfrage des Kindes samt Kurzcode (sobald offengelegt).
class AnfrageAnsicht {
  final AnfrageDto anfrage;

  /// Achtstelliger Kurzcode, den das Kind dem Elternteil nennt (ab "offengelegt"); sonst null.
  final String? kurzcode;

  /// Der Schlüssel wurde in diesem Lauf übernommen (Anfrage fertig).
  final bool uebernommen;
  const AnfrageAnsicht(this.anfrage, {this.kurzcode, this.uebernommen = false});
}

String elternAnfrageName(String userId) => 'e2ee.elternanfrage.$userId';

/// Was das Elternteil beim Übernehmen festhält (je Anfrage): die Verpflichtung, die es sah, und die Zufallszahl, die es selbst erzeugt hat. Später gilt NUR das: ändert der Server
/// Verpflichtung oder Zufallszahl, bricht das Elternteil ab. Dazu zählt es die falschen Codes (nach [kMaxCodeVersuche] wird abgelehnt).
String elternUebernahmeName(String userId, String anfrageId) => 'e2ee.elternuebernahme.$userId.$anfrageId';

/// Falsche Kurzcodes, nach denen das Elternteil die Anfrage ablehnt.
const int kMaxCodeVersuche = 3;

class _Uebernahme {
  final String commit;
  final Uint8List challenge;
  final String kindId;
  final int versuche;
  _Uebernahme(this.commit, this.challenge, this.kindId, this.versuche);

  Uint8List toBytes() => utf8Bytes(jsonEncode({'commit': commit, 'r': base64urlKodieren(challenge), 'kind': kindId, 'versuche': versuche}));

  _Uebernahme mitVersuch() => _Uebernahme(commit, challenge, kindId, versuche + 1);

  static _Uebernahme? lesen(Uint8List? b) {
    if (b == null) return null;
    try {
      final m = jsonDecode(utf8.decode(b));
      if (m is! Map<String, dynamic>) return null;
      return _Uebernahme(m['commit'] as String, base64urlDekodieren(m['r'] as String), m['kind'] as String, (m['versuche'] as int?) ?? 0);
    } on Object {
      return null;
    }
  }
}

/// Die lokale Seite einer Anfrage des Kindes: das flüchtige Paar und, nach dem Offenlegen, die Zufallszahl und das Elternteil, gegen die offengelegt wurde (gepinnt).
class _LokaleAnfrage {
  final String? id;
  final Uint8List pub;
  final Uint8List geheim;
  final Uint8List nonce;
  final String? pinChallenge;
  final String? pinElternId;
  _LokaleAnfrage(this.id, this.pub, this.geheim, this.nonce, {this.pinChallenge, this.pinElternId});

  _LokaleAnfrage mitId(String neueId) => _LokaleAnfrage(neueId, pub, geheim, nonce, pinChallenge: pinChallenge, pinElternId: pinElternId);
  _LokaleAnfrage mitPin(String challenge, String elternId) => _LokaleAnfrage(id, pub, geheim, nonce, pinChallenge: challenge, pinElternId: elternId);

  Uint8List toBytes() => utf8Bytes(
    jsonEncode({'id': id, 'pub': base64urlKodieren(pub), 'geheim': base64urlKodieren(geheim), 'nonce': base64urlKodieren(nonce), 'pinChallenge': pinChallenge, 'pinElternId': pinElternId}),
  );

  static _LokaleAnfrage? lesen(Uint8List? b) {
    if (b == null) return null;
    try {
      final m = jsonDecode(utf8.decode(b));
      if (m is! Map<String, dynamic>) return null;
      return _LokaleAnfrage(
        m['id'] as String?,
        base64urlDekodieren(m['pub'] as String),
        base64urlDekodieren(m['geheim'] as String),
        base64urlDekodieren(m['nonce'] as String),
        pinChallenge: m['pinChallenge'] as String?,
        pinElternId: m['pinElternId'] as String?,
      );
    } on Object {
      return null;
    }
  }

  FluechtigesPaar get paar => FluechtigesPaar(pub, geheim, nonce);
}

class ElternSteuerung {
  final Ref ref;
  ElternSteuerung(this.ref);

  E2eeController get _e2ee => ref.read(e2eeProvider.notifier);

  String get _userId {
    final id = ref.read(authProvider).user?.id;
    if (id == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du bist nicht angemeldet.');
    return id;
  }

  /// Der vertrauenswürdige öffentliche Schlüssel einer Person: auf diesem Gerät GEMERKT und gleich dem aktuellen Schlüssel des Servers; sonst null.
  Future<OeffentlicheSchluessel?> _vertraut(String userId, OeffentlicheSchluessel? server) async {
    if (server == null) return null;
    final g = await VertrauensPruefer(ref.read(schluesselSpeicherProvider), eigeneUserId: _userId).gemerkterSchluessel(userId);
    return g != null && g.gleichWie(server) ? g : null;
  }

  // ------------------------------------------------------------------ Kind

  Future<HinterlegungStand> stand() => ref.read(apiProvider).hinterlegungStand();

  /// Die Einwilligung des Kindes: verpackt den eigenen Schlüssel für alle Eltern (Rolle Admin oder Elternteil, aktiv, mit bestätigtem Schlüssel) und legt die Einträge ab (Step-up
  /// legt die Oberfläche um den Aufruf). Ersetzt eine vorhandene Hinterlegung (zugleich das "Aktualisieren"). Braucht den Schlüssel auf diesem Gerät.
  Future<EinwilligungErgebnis> einwilligen() async {
    final api = ref.read(apiProvider);
    final crypto = await _e2ee.kryptoFuerAblauf();
    final lokal = await _e2ee.lokalenSchluesselFuerAblauf();
    if (lokal == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Auf diesem Gerät gibt es keinen Schlüssel. Verbinde das Gerät zuerst.');
    final server = (await api.eigeneSchluessel()).schluessel;
    if (server == null || !server.gleichWie(lokal.oeffentlich(server.version))) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Schlüssel dieses Geräts passt nicht zu deinem Konto. Verbinde das Gerät zuerst neu.');
    }
    final mitglieder = await api.mitglieder();
    final eintraege = <({String guardianId, int guardianKeyVersion, String blob, String sig})>[];
    final hinterlegt = <String>[];
    final uebersprungen = <String>[];
    for (final m in mitglieder) {
      if ((m.role != Role.admin && m.role != Role.parent) || m.status != MemberStatus.active || m.id == _userId) continue;
      final vertraut = await _vertraut(m.id, m.schluessel);
      if (vertraut == null) {
        uebersprungen.add(m.displayName);
        continue;
      }
      final e = ElternKrypto.hinterlegen(crypto, kind: lokal, kindId: _userId, keyVersion: server.version, elternId: m.id, eltern: vertraut);
      eintraege.add((guardianId: m.id, guardianKeyVersion: vertraut.version, blob: e.blob, sig: e.sig));
      hinterlegt.add(m.displayName);
    }
    if (eintraege.isEmpty) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Kein Elternteil hat einen Schlüssel, dem dieses Gerät vertraut. Die Eltern müssen den Nachrichten-Schutz eingerichtet haben und du musst ihren Schlüssel kennen.');
    }
    await api.hinterlegungSetzen(keyVersion: server.version, eintraege: eintraege);
    ref.invalidate(hinterlegungProvider);
    return EinwilligungErgebnis(hinterlegt, uebersprungen);
  }

  /// Nimmt die Zustimmung zurück (Step-up legt die Oberfläche um den Aufruf): löscht alle Einträge beim Server, beendet eine offene Anfrage, räumt die lokalen Reste ab.
  Future<void> zuruecknehmen() async {
    await ref.read(apiProvider).hinterlegungZuruecknehmen();
    await _lokalLoeschen();
    ref.invalidate(hinterlegungProvider);
  }

  Future<_LokaleAnfrage?> _lokal() async {
    try {
      return _LokaleAnfrage.lesen(await ref.read(schluesselSpeicherProvider).lesen(elternAnfrageName(_userId)));
    } on Object {
      return null;
    }
  }

  Future<void> _lokalLoeschen() async {
    try {
      final l = await _lokal();
      l?.paar.loeschen();
      await ref.read(schluesselSpeicherProvider).loeschen(elternAnfrageName(_userId));
    } on Object {
      // bleibt höchstens ein nutzloses flüchtiges Paar liegen
    }
  }

  /// Stellt die Anfrage (Step-up legt die Oberfläche um den Aufruf): flüchtiges Paar anlegen (der geheime Teil bleibt in diesem Gerät), nur die Verpflichtung geht an den Server.
  Future<AnfrageDto> anfrageStellen() async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final sp = ref.read(schluesselSpeicherProvider);
    final paar = ElternKrypto.fluechtigesPaar(crypto);
    final name = elternAnfrageName(_userId);
    // zuerst lokal sichern: ginge die App nach dem Senden aus, bliebe sonst eine Anfrage ohne den Schlüssel zum Abholen
    await sp.schreiben(name, _LokaleAnfrage(null, paar.oeffentlich, paar.geheim, paar.nonce).toBytes());
    try {
      final dto = await ref.read(apiProvider).anfrageStellen(ElternKrypto.verpflichtung(crypto, paar.oeffentlich, paar.nonce));
      await sp.schreiben(name, _LokaleAnfrage(dto.id, paar.oeffentlich, paar.geheim, paar.nonce).toBytes());
      return dto;
    } on ApiException catch (e) {
      // nur bei einer eindeutigen Ablehnung des Servers (4xx) gibt es keine Anfrage: dann weg. Bei Netzfehler oder 5xx kann der Server sie trotzdem angelegt haben (Antwort verloren):
      // das flüchtige Paar bleibt, [anfrageAktualisieren] ordnet die Anfrage über die Verpflichtung wieder zu.
      if (e.status >= 400 && e.status < 500) await _lokalLoeschen();
      rethrow;
    } on Object {
      rethrow;
    }
  }

  Future<_LokaleAnfrage> _pinSetzen(_LokaleAnfrage l) async {
    await ref.read(schluesselSpeicherProvider).schreiben(elternAnfrageName(_userId), l.toBytes());
    return l;
  }

  /// Bricht ab, weil sich Angaben des Servers während der Anfrage geändert haben (Verpflichtung, Zufallszahl oder Elternteil): ein ehrlicher Server tut das nie.
  Future<Never> _abbruchWegenAenderung(String anfrageId) async {
    try {
      await ref.read(apiProvider).anfrageAbbrechen(anfrageId);
    } on Object {
      // der Abbruch ist die sichere Richtung; scheitert er, bleibt die Anfrage höchstens liegen (sie verfällt)
    }
    await _lokalLoeschen();
    throw const CryptoFehler(
      CryptoFehlerArt.signatur,
      'Die Angaben des Servers haben sich während deiner Anfrage geändert. Aus Sicherheitsgründen wurde sie abgebrochen. Sprich mit deinen Eltern, bevor du es noch einmal versuchst.',
    );
  }

  /// Holt den Stand der eigenen Anfrage und führt, was dieses Gerät tun muss, selbst aus: übernommen -> flüchtigen Schlüssel offenlegen (genau einmal, gegen die Zufallszahl, die
  /// das Gerät dabei festhält); offengelegt/freigegeben -> Kurzcode berechnen, NUR mit den festgehaltenen Werten; freigegeben -> abholen und den Schlüssel übernehmen.
  /// Ändert der Server Zufallszahl oder Elternteil nach dem Offenlegen oder die Verpflichtung, wird abgebrochen. null: keine Anfrage. Fehler beim Abholen werden weitergereicht
  /// (die Anfrage bleibt; abbrechen geht immer).
  Future<AnfrageAnsicht?> anfrageAktualisieren() async {
    final api = ref.read(apiProvider);
    var dto = await api.eigeneAnfrage();
    if (dto == null) {
      await _lokalLoeschen();
      return null;
    }
    if (!dto.zustand.offen && dto.zustand != AnfrageZustand.fertig) {
      await _lokalLoeschen();
      return AnfrageAnsicht(dto);
    }
    var lokal = await _lokal();
    final crypto = await _e2ee.kryptoFuerAblauf();
    if (dto.zustand == AnfrageZustand.fertig) {
      await _lokalLoeschen();
      return AnfrageAnsicht(dto);
    }
    // eine Anfrage, deren Antwort verloren ging: dem flüchtigen Paar dieses Geräts zuordnen, wenn die Verpflichtung des Servers genau zu ihm passt
    if (lokal != null && lokal.id == null) {
      final eigen = ElternKrypto.verpflichtung(crypto, lokal.pub, lokal.nonce);
      if (dto.commit == eigen) {
        lokal = await _pinSetzen(lokal.mitId(dto.id));
      } else {
        return AnfrageAnsicht(dto);
      }
    }
    if (lokal == null || lokal.id != dto.id) {
      // eine Anfrage, deren flüchtigen Schlüssel dieses Gerät nicht hat (anderes Gerät): hier nur anzeigen
      return AnfrageAnsicht(dto);
    }
    // der Server zeigt dem Kind die Verpflichtung, die es selbst gesendet hat; eine andere ist ein Tausch
    final eigeneVerpflichtung = ElternKrypto.verpflichtung(crypto, lokal.pub, lokal.nonce);
    if (dto.commit != null && dto.commit != eigeneVerpflichtung) await _abbruchWegenAenderung(dto.id);
    final ch = dto.challenge;
    if (dto.zustand == AnfrageZustand.uebernommen) {
      if (ch == null || dto.elternteilId == null) return AnfrageAnsicht(dto);
      if (lokal.pinChallenge != null && (lokal.pinChallenge != ch || lokal.pinElternId != dto.elternteilId)) await _abbruchWegenAenderung(dto.id);
      // erst festhalten, dann offenlegen: nur gegen diese Zufallszahl und dieses Elternteil wird je offengelegt
      lokal = await _pinSetzen(lokal.mitPin(ch, dto.elternteilId!));
      await api.anfrageOffenlegen(dto.id, schluessel: base64urlKodieren(lokal.pub), nonce: base64urlKodieren(lokal.nonce), challenge: ch);
      dto = await api.eigeneAnfrage() ?? dto;
    }
    String? code;
    if (dto.zustand == AnfrageZustand.offengelegt || dto.zustand == AnfrageZustand.freigegeben) {
      final pin = lokal.pinChallenge;
      if (pin == null || dto.challenge != pin || dto.elternteilId != lokal.pinElternId) await _abbruchWegenAenderung(dto.id);
      code = ElternKrypto.kurzcode(crypto, pub: lokal.pub, nonce: lokal.nonce, challenge: base64urlDekodieren(pin), anfrageId: dto.id, commit: eigeneVerpflichtung, kindId: _userId, elternId: lokal.pinElternId!);
    }
    if (dto.zustand == AnfrageZustand.freigegeben) {
      await _abholen(dto, lokal);
      return AnfrageAnsicht(dto, kurzcode: code, uebernommen: true);
    }
    return AnfrageAnsicht(dto, kurzcode: code);
  }

  Future<void> _abholen(AnfrageDto dto, _LokaleAnfrage lokal) async {
    final api = ref.read(apiProvider);
    final crypto = await _e2ee.kryptoFuerAblauf();
    final blob = dto.freigabeBlob, sig = dto.freigabeSig, eltern = dto.elternteilId;
    if (blob == null || sig == null || eltern == null) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Freigabe ist unvollständig.');
    // der Schlüssel des Elternteils, dem dieses Gerät vertraut (gemerkt und gleich dem des Servers)
    final mitglieder = await api.mitglieder();
    final server = mitglieder.where((m) => m.id == eltern).firstOrNull?.schluessel;
    final vertraut = await _vertraut(eltern, server);
    if (vertraut == null) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Dieses Gerät kennt den Schlüssel des freigebenden Elternteils nicht. Bitte prüfe den Sicherheitscode unter Profil › Sicherheit › Nachrichten-Schutz.');
    }
    final schluessel = ElternKrypto.freigabeOeffnen(crypto, blob: blob, sig: sig, anfrageId: dto.id, kindId: _userId, keyVersion: dto.schluesselVersion, elternId: eltern, elternVertraut: vertraut, paar: lokal.paar);
    // schluesselUebernehmen vergleicht mit dem frisch geholten Schlüssel des Servers und schreibt erst dann (sonst Fehler, nichts verändert)
    await _e2ee.schluesselUebernehmen(schluessel, dto.schluesselVersion);
    await api.anfrageAbschliessen(dto.id);
    await _lokalLoeschen();
  }

  /// Bricht die eigene Anfrage ab (von jedem Gerät, ohne Step-up) und räumt den flüchtigen Schlüssel ab.
  Future<void> anfrageAbbrechen(String id) async {
    await ref.read(apiProvider).anfrageAbbrechen(id);
    await _lokalLoeschen();
  }

  // ------------------------------------------------------------------ Eltern

  Future<HilfeUebersicht> uebersicht() => ref.read(apiProvider).hilfeUebersicht();

  Future<_Uebernahme?> _uebernahme(String anfrageId) async {
    try {
      return _Uebernahme.lesen(await ref.read(schluesselSpeicherProvider).lesen(elternUebernahmeName(_userId, anfrageId)));
    } on Object {
      return null;
    }
  }

  Future<void> _uebernahmeLoeschen(String anfrageId) async {
    try {
      await ref.read(schluesselSpeicherProvider).loeschen(elternUebernahmeName(_userId, anfrageId));
    } on Object {
      // nur ein Vermerk dieses Geräts
    }
  }

  /// Das Elternteil übernimmt eine Anfrage nach der Wartefrist (Step-up legt die Oberfläche um den Aufruf), erzeugt eine frische Zufallszahl und HÄLT sie zusammen mit der
  /// Verpflichtung fest, die es gerade sieht: Kurzcode und Freigabe gelten später nur mit diesen Werten (ein Server, der die Verpflichtung oder die Zufallszahl danach
  /// ändert, wird erkannt). Die Übernahme gilt nur auf diesem Gerät.
  Future<void> uebernehmen(HilfeAnfrage a) async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final r = crypto.zufall(16);
    final pin = _Uebernahme(a.verpflichtung, r, a.kindId, 0);
    final sp = ref.read(schluesselSpeicherProvider);
    await sp.schreiben(elternUebernahmeName(_userId, a.anfrage.id), pin.toBytes());
    try {
      await ref.read(apiProvider).anfrageUebernehmen(a.anfrage.id, base64urlKodieren(r));
    } on ApiException catch (e) {
      // nur bei einer eindeutigen Ablehnung (4xx) gibt es keine Übernahme; sonst bleibt der Vermerk (die Antwort kann verloren gegangen sein)
      if (e.status >= 400 && e.status < 500) await _uebernahmeLoeschen(a.anfrage.id);
      rethrow;
    }
  }

  Future<void> ablehnen(String id) async {
    await ref.read(apiProvider).anfrageAblehnen(id);
    await _uebernahmeLoeschen(id);
  }

  /// Das Elternteil gibt frei (Step-up legt die Oberfläche um den Aufruf), nachdem es den Kurzcode des Kindes eingegeben hat. Prüft zuerst die Verpflichtung und den Kurzcode;
  /// stimmt der Code nicht, wird die Anfrage abgelehnt (ein Fehlversuch endet sie, kein Raten). Öffnet dann den eigenen Eintrag (Signatur des Kindes gegen den GEMERKTEN Schlüssel)
  /// und gibt die Seeds, an den flüchtigen Schlüssel des Kindes verpackt, an den Server.
  Future<void> freigeben(HilfeAnfrage a, String eingegebenerCode) async {
    final api = ref.read(apiProvider);
    final crypto = await _e2ee.kryptoFuerAblauf();
    final pubT = a.offenerSchluessel, nonceT = a.offeneNonce, ch = a.anfrage.challenge;
    final blob = a.hinterlegungBlob, sig = a.hinterlegungSig;
    if (a.anfrage.zustand != AnfrageZustand.offengelegt || pubT == null || nonceT == null || ch == null || blob == null || sig == null || a.hinterlegungKindVersion == null || a.hinterlegungElternVersion == null) {
      throw const CryptoFehler(CryptoFehlerArt.format, 'Diese Anfrage ist noch nicht bereit zur Freigabe.');
    }
    // nur die beim Übernehmen festgehaltenen Werte zählen (Verpflichtung und Zufallszahl); der Server darf sie danach nicht mehr ändern
    final pin = await _uebernahme(a.anfrage.id);
    if (pin == null) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Diese Anfrage hast du auf einem anderen Gerät übernommen (oder die Übernahme ging verloren). Gib dort frei oder lehne ab und lass das Kind neu anfragen.');
    }
    Future<Never> abbruch(String text) async {
      try {
        await api.anfrageAblehnen(a.anfrage.id);
      } on Object {
        // die sichere Richtung; die Anfrage verfällt sonst von selbst
      }
      await _uebernahmeLoeschen(a.anfrage.id);
      throw CryptoFehler(CryptoFehlerArt.signatur, text);
    }

    if (a.verpflichtung != pin.commit || a.kindId != pin.kindId || !gleicheBytes(base64urlDekodieren(ch), pin.challenge)) {
      await abbruch('Die Angaben des Servers haben sich geändert, seit du die Anfrage übernommen hast. Die Anfrage wurde aus Sicherheitsgründen abgelehnt. Sprich mit dem Kind, bevor es noch einmal anfragt.');
    }
    final pub = base64urlDekodieren(pubT), nonce = base64urlDekodieren(nonceT);
    if (!ElternKrypto.verpflichtungPasst(crypto, pin.commit, pub, nonce)) {
      await abbruch('Die Angaben des Kindes passen nicht zusammen. Die Anfrage wurde abgelehnt. Wenn das Kind es noch einmal versucht, sprich vorher mit ihm.');
    }
    final erwartet = ElternKrypto.kurzcode(crypto, pub: pub, nonce: nonce, challenge: pin.challenge, anfrageId: a.anfrage.id, commit: pin.commit, kindId: pin.kindId, elternId: _userId);
    if (eingegebenerCode.replaceAll(RegExp(r'\s'), '') != erwartet) {
      final neu = pin.mitVersuch();
      if (neu.versuche >= kMaxCodeVersuche) {
        await abbruch('Der Code stimmt nicht (dreimal). Die Anfrage wurde aus Sicherheitsgründen abgelehnt. Das Kind kann eine neue stellen.');
      }
      await ref.read(schluesselSpeicherProvider).schreiben(elternUebernahmeName(_userId, a.anfrage.id), neu.toBytes());
      throw CryptoFehler(
        CryptoFehlerArt.signatur,
        'Der Code stimmt nicht mit dem Code des Kindes überein. Frage das Kind noch einmal danach (noch ${kMaxCodeVersuche - neu.versuche} ${kMaxCodeVersuche - neu.versuche == 1 ? 'Versuch' : 'Versuche'}).',
      );
    }
    final eigen = await _e2ee.lokalenSchluesselFuerAblauf();
    final eigeneServer = (await api.eigeneSchluessel()).schluessel;
    if (eigen == null || eigeneServer == null || !eigeneServer.gleichWie(eigen.oeffentlich(eigeneServer.version)) || eigeneServer.version != a.hinterlegungElternVersion) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Dein Schlüssel auf diesem Gerät passt nicht zur Hinterlegung des Kindes. Das Kind muss die Hinterlegung aktualisieren, oder nimm ein Gerät mit deinem aktuellen Schlüssel.');
    }
    final mitglieder = await api.mitglieder();
    final kindServer = mitglieder.where((m) => m.id == a.kindId).firstOrNull?.schluessel;
    final kindVertraut = await _vertraut(a.kindId, kindServer);
    if (kindVertraut == null) {
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Dieses Gerät kennt den Schlüssel des Kindes nicht (oder er hat sich geändert). Prüfe den Sicherheitscode unter Profil › Sicherheit › Nachrichten-Schutz.');
    }
    final seeds = ElternKrypto.hinterlegungOeffnen(
      crypto,
      blob: blob,
      sig: sig,
      kindId: a.kindId,
      keyVersion: a.hinterlegungKindVersion!,
      kindVertraut: kindVertraut,
      elternId: _userId,
      elternVersion: a.hinterlegungElternVersion!,
      elternSchluessel: eigen,
    );
    try {
      final e = ElternKrypto.freigeben(
        crypto,
        seeds: seeds,
        anfrageId: a.anfrage.id,
        kindId: a.kindId,
        keyVersion: a.hinterlegungKindVersion!,
        elternId: _userId,
        eltern: eigen,
        elternVersion: eigeneServer.version,
        tempPub: pub,
      );
      await api.anfrageFreigeben(a.anfrage.id, blob: e.blob, sig: e.sig);
      await _uebernahmeLoeschen(a.anfrage.id);
    } finally {
      loescheBytes(seeds);
    }
  }
}

final elternSteuerungProvider = Provider<ElternSteuerung>((ref) => ElternSteuerung(ref));

/// Hat dieses Kinder-Konto die Eltern-Wiederherstellung erlaubt? (Für die Pille im Profil; ohne Schalter des Servers, für Erwachsene und bei Fehlern false.)
final elternHilfeAktivProvider = Provider.autoDispose<bool>((ref) {
  final verfuegbar = ref.watch(e2eeProvider.select((s) => s.elternWiederherstellungVerfuegbar));
  final rolle = ref.watch(authProvider.select((a) => a.user?.role));
  if (!verfuegbar || rolle != Role.child) return false;
  return ref.watch(hinterlegungProvider).value?.aktiv ?? false;
});

/// Stand der eigenen Hinterlegung (Kind); bei Fehler "keine" (ältere Server, offline).
final hinterlegungProvider = FutureProvider.autoDispose<HinterlegungStand>((ref) async {
  try {
    return await ref.read(elternSteuerungProvider).stand();
  } on ApiException {
    return HinterlegungStand.keine;
  }
}, retry: (_, _) => null);

/// Übersicht für ein Elternteil; bei Fehler leer.
final hilfeProvider = FutureProvider.autoDispose<HilfeUebersicht>((ref) async {
  try {
    return await ref.read(elternSteuerungProvider).uebersicht();
  } on ApiException {
    return HilfeUebersicht.leer;
  }
}, retry: (_, _) => null);
