// Phase-2-Bausteine (reine Funktionen, noch ohne Chat-Integration): Verteilung des Epochenschlüssels einer Konversation.
//
// Epochenschlüssel-Wrap: Der Verteiler (ein Mitglied) verpackt den 32-Byte-Epochenschlüssel für jeden Empfänger als Sealed Box an dessen X25519-Schlüssel
// und signiert (Ed25519, Domäne 'lx-familyhub|wrap|v1', längengerahmt) conversation_id, epoch, recipient_id, recipient_key_version, distributor_id,
// distributor_key_version und SHA-256(Sealed Box). Der Server kann so weder eine fremde Sealed Box unterschieben (die Signatur deckt ihren Hash ab) noch
// einen Wrap in eine andere Konversation, Epoche oder an eine andere Person umlenken (alle stehen in der Signatur).
//
// Signierte Mitgliederliste der Epoche: sortierte (user_id, key_version)-Paare, vom Verteiler signiert (Domäne 'lx-familyhub|members|v1'). Der Empfänger
// übernimmt einen Epochenschlüssel nur, wenn Wrap UND Mitgliederliste vom selben Verteiler stammen, dessen Signatur gegen den im TOFU-Speicher
// gemerkten Schlüssel stimmt, beide zur erwarteten Konversation und Epoche passen und die Liste ihn selbst mit seiner Schlüsselversion enthält.
// Das hindert den Server daran, ein Mitglied unbemerkt in die Liste einzuschleusen oder die Liste umzudeuten.
//
// Was die Signaturen NICHT leisten: Ein Verteiler kann sich irren oder böswillig sein (dann ist jedes Mitglied der Epoche betroffen); ob die Liste dem
// entspricht, was die Person wollte, zeigt die UI beim Hinzufügen (Mitglieder anzeigen, zum Sicherheitscode-Vergleich auffordern: Phase 2).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'bytes.dart';
import 'crypto_fehler.dart';
import 'crypto_provider.dart';
import 'domaenen.dart';
import 'schluessel.dart';
import 'vertrauen.dart';

const int _wrapVersion = 1;
const int _listeVersion = 1;

CryptoFehler _format() => const CryptoFehler(CryptoFehlerArt.format, 'Die Schlüsselverteilung ist beschädigt.');

Uint8List _sha256(List<int> d) => Uint8List.fromList(c.sha256.convert(d).bytes);

class _Leser {
  final Uint8List b;
  int p = 0;
  _Leser(this.b);

  int u32() {
    if (p + 4 > b.length) throw _format();
    final v = u32Lesen(b, p);
    p += 4;
    return v;
  }

  Uint8List feld() {
    final n = u32();
    if (n > b.length - p) throw _format();
    final out = Uint8List.sublistView(b, p, p + n);
    p += n;
    return out;
  }

  String text() {
    try {
      return utf8.decode(feld());
    } on FormatException {
      throw _format();
    }
  }

  void ende() {
    if (p != b.length) throw _format();
  }
}

/// Eine Person der Mitgliederliste mit der Version ihres Schlüssels.
class MitgliedEintrag {
  final String userId;
  final int keyVersion;
  const MitgliedEintrag(this.userId, this.keyVersion);
}

/// Mitglieder einer Epoche, sortiert nach Personen-ID und ohne Doppelte (kanonisch, damit jede Seite dieselben Bytes signiert).
class MitgliederListe {
  final String conversationId;
  final int epoch;
  final List<MitgliedEintrag> mitglieder;

  MitgliederListe._(this.conversationId, this.epoch, this.mitglieder);

  factory MitgliederListe.erstellen({required String conversationId, required int epoch, required Iterable<MitgliedEintrag> mitglieder}) {
    final sortiert = [...mitglieder]..sort((a, b) => a.userId.compareTo(b.userId));
    for (var i = 0; i < sortiert.length; i++) {
      if (sortiert[i].userId.isEmpty || sortiert[i].keyVersion < 1) throw _format();
      if (i > 0 && sortiert[i].userId == sortiert[i - 1].userId) throw const CryptoFehler(CryptoFehlerArt.format, 'Eine Person steht doppelt in der Mitgliederliste.');
    }
    if (conversationId.isEmpty || epoch < 0 || epoch > 0xFFFFFFFF) throw _format();
    return MitgliederListe._(conversationId, epoch, List.unmodifiable(sortiert));
  }

  int? versionVon(String userId) {
    for (final m in mitglieder) {
      if (m.userId == userId) return m.keyVersion;
    }
    return null;
  }

  Uint8List get _nutzlast => verketten([
    u32Bytes(mitglieder.length),
    for (final m in mitglieder) ...[gerahmt(utf8Bytes(m.userId)), u32Bytes(m.keyVersion)],
  ]);
}

Uint8List _listeSignaturEingabe(MitgliederListe l, String verteilerId, int verteilerVersion) => signaturEingabe(kDomaeneMitglieder, [
  utf8Bytes(l.conversationId),
  u32Bytes(l.epoch),
  utf8Bytes(verteilerId),
  u32Bytes(verteilerVersion),
  l._nutzlast,
]);

class SignierteMitgliederListe {
  final MitgliederListe liste;
  final String verteilerId;
  final int verteilerKeyVersion;
  final Uint8List signatur;
  const SignierteMitgliederListe({required this.liste, required this.verteilerId, required this.verteilerKeyVersion, required this.signatur});

  /// Transportform (Base64url).
  String kodieren() => base64urlKodieren(verketten([
    [_listeVersion],
    gerahmt(utf8Bytes(liste.conversationId)),
    u32Bytes(liste.epoch),
    gerahmt(utf8Bytes(verteilerId)),
    u32Bytes(verteilerKeyVersion),
    u32Bytes(liste.mitglieder.length),
    for (final m in liste.mitglieder) ...[gerahmt(utf8Bytes(m.userId)), u32Bytes(m.keyVersion)],
    gerahmt(signatur),
  ]));

  factory SignierteMitgliederListe.dekodieren(String text) {
    final l = _Leser(base64urlDekodieren(text));
    if (l.b.isEmpty || l.b[0] != _listeVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Schlüsselverteilung stammt von einer neueren App-Version.');
    l.p = 1;
    final conv = l.text();
    final epoch = l.u32();
    final vId = l.text();
    final vVer = l.u32();
    final n = l.u32();
    if (n > 100000) throw _format();
    final eintraege = <MitgliedEintrag>[];
    for (var i = 0; i < n; i++) {
      eintraege.add(MitgliedEintrag(l.text(), l.u32()));
    }
    final sig = l.feld();
    l.ende();
    final liste = MitgliederListe.erstellen(conversationId: conv, epoch: epoch, mitglieder: eintraege);
    // kanonische Reihenfolge erzwingen: sonst wären zwei Kodierungen derselben Liste gültig
    for (var i = 0; i < eintraege.length; i++) {
      if (eintraege[i].userId != liste.mitglieder[i].userId) throw _format();
    }
    return SignierteMitgliederListe(liste: liste, verteilerId: vId, verteilerKeyVersion: vVer, signatur: Uint8List.fromList(sig));
  }
}

/// Der für eine Person verpackte Epochenschlüssel.
class EpochenWrap {
  final String conversationId;
  final int epoch;
  final String empfaengerId;
  final int empfaengerKeyVersion;
  final String verteilerId;
  final int verteilerKeyVersion;
  final Uint8List versiegelt;
  final Uint8List signatur;
  const EpochenWrap({
    required this.conversationId,
    required this.epoch,
    required this.empfaengerId,
    required this.empfaengerKeyVersion,
    required this.verteilerId,
    required this.verteilerKeyVersion,
    required this.versiegelt,
    required this.signatur,
  });

  String kodieren() => base64urlKodieren(verketten([
    [_wrapVersion],
    gerahmt(utf8Bytes(conversationId)),
    u32Bytes(epoch),
    gerahmt(utf8Bytes(empfaengerId)),
    u32Bytes(empfaengerKeyVersion),
    gerahmt(utf8Bytes(verteilerId)),
    u32Bytes(verteilerKeyVersion),
    gerahmt(versiegelt),
    gerahmt(signatur),
  ]));

  factory EpochenWrap.dekodieren(String text) {
    final l = _Leser(base64urlDekodieren(text));
    if (l.b.isEmpty || l.b[0] != _wrapVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Schlüsselverteilung stammt von einer neueren App-Version.');
    l.p = 1;
    final w = EpochenWrap(
      conversationId: l.text(),
      epoch: l.u32(),
      empfaengerId: l.text(),
      empfaengerKeyVersion: l.u32(),
      verteilerId: l.text(),
      verteilerKeyVersion: l.u32(),
      versiegelt: Uint8List.fromList(l.feld()),
      signatur: Uint8List.fromList(l.feld()),
    );
    l.ende();
    return w;
  }

  Uint8List get _signaturEingabe => signaturEingabe(kDomaeneWrap, [
    utf8Bytes(conversationId),
    u32Bytes(epoch),
    utf8Bytes(empfaengerId),
    u32Bytes(empfaengerKeyVersion),
    utf8Bytes(verteilerId),
    u32Bytes(verteilerKeyVersion),
    _sha256(versiegelt),
  ]);
}

/// Seite des Verteilers.
class EpochenVerteiler {
  /// Verpackt [epochenschluessel] für einen Empfänger (mit dessen aktuellem öffentlichen Schlüssel) und signiert den Wrap.
  static EpochenWrap wrapErstellen(
    CryptoProvider crypto, {
    required Uint8List epochenschluessel,
    required String conversationId,
    required int epoch,
    required String empfaengerId,
    required OeffentlicheSchluessel empfaenger,
    required String verteilerId,
    required int verteilerKeyVersion,
    required Uint8List verteilerSignGeheim,
  }) {
    if (epochenschluessel.length != 32) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Schlüssellänge.');
    if (conversationId.isEmpty || empfaengerId.isEmpty || verteilerId.isEmpty || epoch < 0 || epoch > 0xFFFFFFFF || empfaenger.version < 1 || verteilerKeyVersion < 1) {
      throw _format();
    }
    final sealed = crypto.versiegeln(epochenschluessel, empfaenger.enc);
    final unsigniert = EpochenWrap(
      conversationId: conversationId,
      epoch: epoch,
      empfaengerId: empfaengerId,
      empfaengerKeyVersion: empfaenger.version,
      verteilerId: verteilerId,
      verteilerKeyVersion: verteilerKeyVersion,
      versiegelt: sealed,
      signatur: Uint8List(0),
    );
    return EpochenWrap(
      conversationId: conversationId,
      epoch: epoch,
      empfaengerId: empfaengerId,
      empfaengerKeyVersion: empfaenger.version,
      verteilerId: verteilerId,
      verteilerKeyVersion: verteilerKeyVersion,
      versiegelt: sealed,
      signatur: crypto.signieren(unsigniert._signaturEingabe, verteilerSignGeheim),
    );
  }

  static SignierteMitgliederListe listeSignieren(
    CryptoProvider crypto, {
    required MitgliederListe liste,
    required String verteilerId,
    required int verteilerKeyVersion,
    required Uint8List verteilerSignGeheim,
  }) => SignierteMitgliederListe(
    liste: liste,
    verteilerId: verteilerId,
    verteilerKeyVersion: verteilerKeyVersion,
    signatur: crypto.signieren(_listeSignaturEingabe(liste, verteilerId, verteilerKeyVersion), verteilerSignGeheim),
  );
}

CryptoFehler _signatur() => const CryptoFehler(CryptoFehlerArt.signatur, 'Die Schlüsselverteilung konnte nicht bestätigt werden.');

/// Seite des Empfängers.
class EpochenEmpfaenger {
  /// Prüft die Signatur der Mitgliederliste gegen [verteiler] und ihre Passung zur erwarteten Konversation/Epoche; enthält sie [ichId]
  /// nicht mit [meineKeyVersion], gilt sie nicht. Optional muss sie genau [erwarteteMitglieder] enthalten (z. B. aus der eigenen Sicht der Konversation).
  static void listePruefen(
    CryptoProvider crypto, {
    required SignierteMitgliederListe signiert,
    required String erwarteteConversationId,
    required int erwarteteEpoche,
    required OeffentlicheSchluessel verteiler,
    required String ichId,
    required int meineKeyVersion,
    Iterable<MitgliedEintrag>? erwarteteMitglieder,
  }) {
    final l = signiert.liste;
    if (l.conversationId != erwarteteConversationId || l.epoch != erwarteteEpoche) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Mitgliederliste gehört nicht zu dieser Konversation.');
    if (verteiler.version != signiert.verteilerKeyVersion) throw _signatur();
    if (!crypto.signaturPruefen(_listeSignaturEingabe(l, signiert.verteilerId, signiert.verteilerKeyVersion), signiert.signatur, verteiler.sign)) throw _signatur();
    if (l.versionVon(ichId) != meineKeyVersion) throw const CryptoFehler(CryptoFehlerArt.format, 'Du stehst nicht (mit deinem Schlüssel) in der Mitgliederliste.');
    if (erwarteteMitglieder != null) {
      final erwartet = MitgliederListe.erstellen(conversationId: erwarteteConversationId, epoch: erwarteteEpoche, mitglieder: erwarteteMitglieder);
      if (erwartet.mitglieder.length != l.mitglieder.length) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Mitgliederliste weicht von der erwarteten ab.');
      for (var i = 0; i < l.mitglieder.length; i++) {
        if (erwartet.mitglieder[i].userId != l.mitglieder[i].userId || erwartet.mitglieder[i].keyVersion != l.mitglieder[i].keyVersion) {
          throw const CryptoFehler(CryptoFehlerArt.format, 'Die Mitgliederliste weicht von der erwarteten ab.');
        }
      }
    }
  }

  /// Prüft den Wrap (Passung zu Konversation, Epoche, Person und Schlüsselversion, Signatur des Verteilers) und öffnet ihn erst danach.
  static Uint8List wrapOeffnen(
    CryptoProvider crypto, {
    required EpochenWrap wrap,
    required String erwarteteConversationId,
    required int erwarteteEpoche,
    required String ichId,
    required Personenschluessel meinSchluessel,
    required int meineKeyVersion,
    required OeffentlicheSchluessel verteiler,
  }) {
    if (wrap.conversationId != erwarteteConversationId || wrap.epoch != erwarteteEpoche) throw const CryptoFehler(CryptoFehlerArt.format, 'Der Schlüssel gehört nicht zu dieser Konversation.');
    if (wrap.empfaengerId != ichId || wrap.empfaengerKeyVersion != meineKeyVersion) throw const CryptoFehler(CryptoFehlerArt.format, 'Der Schlüssel ist nicht für dich und deinen aktuellen Schlüssel bestimmt.');
    if (verteiler.version != wrap.verteilerKeyVersion) throw _signatur();
    if (!crypto.signaturPruefen(wrap._signaturEingabe, wrap.signatur, verteiler.sign)) throw _signatur();
    final klar = crypto.versiegelungOeffnen(wrap.versiegelt, meinSchluessel.encOeffentlich, meinSchluessel.encGeheim);
    if (klar.length != 32) {
      loescheBytes(klar);
      throw _format();
    }
    return klar;
  }

  /// Übernimmt einen Epochenschlüssel erst, wenn Mitgliederliste und Wrap vom selben Verteiler stammen und beide Prüfungen bestehen.
  static Uint8List uebernehmen(
    CryptoProvider crypto, {
    required EpochenWrap wrap,
    required SignierteMitgliederListe liste,
    required String erwarteteConversationId,
    required int erwarteteEpoche,
    required String ichId,
    required Personenschluessel meinSchluessel,
    required int meineKeyVersion,
    required OeffentlicheSchluessel verteiler,
    Iterable<MitgliedEintrag>? erwarteteMitglieder,
  }) {
    if (wrap.verteilerId != liste.verteilerId || wrap.verteilerKeyVersion != liste.verteilerKeyVersion) {
      throw const CryptoFehler(CryptoFehlerArt.signatur, 'Mitgliederliste und Schlüssel stammen nicht vom selben Verteiler.');
    }
    listePruefen(
      crypto,
      signiert: liste,
      erwarteteConversationId: erwarteteConversationId,
      erwarteteEpoche: erwarteteEpoche,
      verteiler: verteiler,
      ichId: ichId,
      meineKeyVersion: meineKeyVersion,
      erwarteteMitglieder: erwarteteMitglieder,
    );
    return wrapOeffnen(
      crypto,
      wrap: wrap,
      erwarteteConversationId: erwarteteConversationId,
      erwarteteEpoche: erwarteteEpoche,
      ichId: ichId,
      meinSchluessel: meinSchluessel,
      meineKeyVersion: meineKeyVersion,
      verteiler: verteiler,
    );
  }

  /// Wie [uebernehmen], aber der Verteiler-Schlüssel kommt aus dem TOFU-Speicher (nie vom Server): unbekannte Verteiler werden abgelehnt.
  static Future<Uint8List> uebernehmenMitVertrauen(
    CryptoProvider crypto, {
    required VertrauensPruefer vertrauen,
    required EpochenWrap wrap,
    required SignierteMitgliederListe liste,
    required String erwarteteConversationId,
    required int erwarteteEpoche,
    required String ichId,
    required Personenschluessel meinSchluessel,
    required int meineKeyVersion,
    Iterable<MitgliedEintrag>? erwarteteMitglieder,
  }) async {
    final verteiler = await vertrauen.gemerkterSchluessel(wrap.verteilerId);
    if (verteiler == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Der Verteiler ist dir noch nicht bekannt.');
    return uebernehmen(
      crypto,
      wrap: wrap,
      liste: liste,
      erwarteteConversationId: erwarteteConversationId,
      erwarteteEpoche: erwarteteEpoche,
      ichId: ichId,
      meinSchluessel: meinSchluessel,
      meineKeyVersion: meineKeyVersion,
      verteiler: verteiler,
      erwarteteMitglieder: erwarteteMitglieder,
    );
  }
}
