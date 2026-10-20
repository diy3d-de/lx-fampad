// Standort teilen, Verschlüsselung (reine Funktionen, getestet in test/standort_krypto_test.dart). Der Server reicht nur opake Pakete weiter.
//
// Je Freigabe erzeugt das sendende Gerät einen zufälligen 32-Byte-Sitzungsschlüssel K und verteilt ihn an die gewählten Empfänger:
//
//  Freigabe-Wrap (je Empfänger, Base64url):  v (1) | shareId | senderId | senderKeyVersion (u32) | recipientId | recipientKeyVersion (u32) |
//    endsAt (Dezimaltext, ms) | Sealed Box von K an den X25519-Schlüssel des Empfängers | Ed25519-Signatur   (Felder bis auf v längengerahmt)
//  Die Signatur (Domäne 'lx-familyhub|loc-share|v1') deckt alle Felder und SHA-256 der Sealed Box ab: der Server kann den Wrap weder umlenken noch
//  austauschen. Der Empfänger prüft sie gegen den gemerkten (TOFU) Schlüssel des Absenders, nie gegen einen vom Server genannten.
//
//  Positions-Paket (Base64url):  v (1) | senderKeyVersion (4, BE) | nonce (24) | Signatur (64) | Chiffretext (XChaCha20-Poly1305)
//  AAD = 'shareId|senderId|senderKeyVersion|v'; Signatur (Domäne 'lx-familyhub|loc-pos|v1') über AAD, Kopf und Chiffretext. Inhalt (JSON):
//    s = Sequenznummer (steigt je Paket), t = Zeit der Messung, a = Ablauf des Pakets, x = Ende der Freigabe, la/lo = Breite/Länge, g = Genauigkeit (m).
//
//  Schutz gegen Wiederholung: Der Empfänger nimmt nur Pakete mit höherer Sequenznummer als das letzte angenommene und nur vor dem Ablauf (a); die
//  Messzeit t darf nicht in der Zukunft liegen. Der Zustand liegt nur im Arbeitsspeicher (flüchtig): Nach einem Neustart der App fängt die Zählung
//  neu an; ein Server könnte dann ein älteres Paket innerhalb seiner Gültigkeit erneut einspielen (angezeigt wird weiter das echte Alter der Messung).
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/bytes.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/domaenen.dart';
import '../crypto/schluessel.dart';

const int kStandortWrapVersion = 1;
const int kStandortPaketVersion = 1;

/// Wie lange ein einzelnes Positions-Paket gilt (danach wird es verworfen, auch wenn es echt ist).
const Duration kStandortPaketGueltigkeit = Duration(minutes: 10);

/// Obergrenze der Freigabe (der Server lehnt Längeres ab; der Empfänger rechnet nie mit mehr).
const Duration kStandortMaxDauer = Duration(hours: 12);

/// Wie weit die Uhr eines Absenders höchstens vorgehen darf (Messzeit in der Zukunft).
const Duration _kUhrenToleranz = Duration(minutes: 5);

/// Gründe, aus denen ein formal richtiges Paket nicht angenommen wird (kein Angriff nötig: auch eine verspätete Zustellung).
enum PaketAblehnung { wiederholt, abgelaufen, zukunft }

class StandortPaketAbgelehnt implements Exception {
  final PaketAblehnung grund;
  const StandortPaketAbgelehnt(this.grund);

  @override
  String toString() => 'StandortPaketAbgelehnt(${grund.name})';
}

CryptoFehler _format() => const CryptoFehler(CryptoFehlerArt.format, 'Die Standortfreigabe ist beschädigt.');
CryptoFehler _signatur() => const CryptoFehler(CryptoFehlerArt.signatur, 'Die Standortfreigabe konnte nicht bestätigt werden.');

Uint8List _sha256(List<int> d) => Uint8List.fromList(c.sha256.convert(d).bytes);

bool _idOk(String s) => s.isNotEmpty && s.length <= 64 && !s.contains('|');

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

/// Der für einen Empfänger verpackte Sitzungsschlüssel einer Freigabe.
class StandortWrap {
  final String shareId;
  final String senderId;
  final int senderKeyVersion;
  final String empfaengerId;
  final int empfaengerKeyVersion;
  final int endsAtMs;
  final Uint8List versiegelt;
  final Uint8List signatur;
  const StandortWrap({
    required this.shareId,
    required this.senderId,
    required this.senderKeyVersion,
    required this.empfaengerId,
    required this.empfaengerKeyVersion,
    required this.endsAtMs,
    required this.versiegelt,
    required this.signatur,
  });

  Uint8List get _signaturEingabe => signaturEingabe(kDomaeneStandortFreigabe, [
    utf8Bytes(shareId),
    utf8Bytes(senderId),
    u32Bytes(senderKeyVersion),
    utf8Bytes(empfaengerId),
    u32Bytes(empfaengerKeyVersion),
    utf8Bytes('$endsAtMs'),
    _sha256(versiegelt),
  ]);

  String kodieren() => base64urlKodieren(verketten([
    [kStandortWrapVersion],
    gerahmt(utf8Bytes(shareId)),
    gerahmt(utf8Bytes(senderId)),
    u32Bytes(senderKeyVersion),
    gerahmt(utf8Bytes(empfaengerId)),
    u32Bytes(empfaengerKeyVersion),
    gerahmt(utf8Bytes('$endsAtMs')),
    gerahmt(versiegelt),
    gerahmt(signatur),
  ]));

  factory StandortWrap.dekodieren(String text) {
    final l = _Leser(base64urlDekodieren(text));
    if (l.b.isEmpty || l.b[0] != kStandortWrapVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Standortfreigabe stammt von einer neueren App-Version.');
    l.p = 1;
    final shareId = l.text();
    final senderId = l.text();
    final senderVer = l.u32();
    final empfId = l.text();
    final empfVer = l.u32();
    final ende = int.tryParse(l.text());
    final versiegelt = Uint8List.fromList(l.feld());
    final sig = Uint8List.fromList(l.feld());
    l.ende();
    if (ende == null || !_idOk(shareId) || !_idOk(senderId) || !_idOk(empfId)) throw _format();
    return StandortWrap(
      shareId: shareId,
      senderId: senderId,
      senderKeyVersion: senderVer,
      empfaengerId: empfId,
      empfaengerKeyVersion: empfVer,
      endsAtMs: ende,
      versiegelt: versiegelt,
      signatur: sig,
    );
  }
}

/// Ein geöffnetes, geprüftes Positions-Paket.
class StandortPaketInhalt {
  final int seq;
  final DateTime zeit;
  final DateTime ablauf;
  final DateTime freigabeEnde;
  final double breite;
  final double laenge;

  /// Genauigkeit in Metern (null: unbekannt).
  final double? genauigkeit;
  const StandortPaketInhalt({required this.seq, required this.zeit, required this.ablauf, required this.freigabeEnde, required this.breite, required this.laenge, this.genauigkeit});
}

Uint8List _paketAad(String shareId, String senderId, int senderKeyVersion) {
  if (!_idOk(shareId) || !_idOk(senderId) || senderKeyVersion < 1) throw _format();
  return utf8Bytes('$shareId|$senderId|$senderKeyVersion|$kStandortPaketVersion');
}

Uint8List _paketSignaturEingabe(Uint8List aad, Uint8List kopf, Uint8List ct) => signaturEingabe(kDomaeneStandortPaket, [aad, kopf, ct]);

const int _paketKopf = 1 + 4 + kNonceLaengeStandort;
const int kNonceLaengeStandort = 24;
const int _sigLaenge = 64;
const int _tagLaenge = 16;

/// Seite des Senders: eine Freigabe mit ihrem Sitzungsschlüssel.
class StandortSender {
  final CryptoProvider crypto;
  final String shareId;
  final String ichId;
  final int meineKeyVersion;
  final Uint8List _signGeheim;
  final Uint8List _schluessel;
  int _seq = 0;
  int _endsAtMs;

  StandortSender._(this.crypto, this.shareId, this.ichId, this.meineKeyVersion, this._signGeheim, this._schluessel, this._endsAtMs);

  factory StandortSender.neu(
    CryptoProvider crypto, {
    required String shareId,
    required String ichId,
    required int meineKeyVersion,
    required Uint8List signGeheim,
    required int endsAtMs,
  }) {
    if (!_idOk(shareId) || !_idOk(ichId) || meineKeyVersion < 1) throw _format();
    return StandortSender._(crypto, shareId, ichId, meineKeyVersion, Uint8List.fromList(signGeheim), crypto.zufall(32), endsAtMs);
  }

  int get endsAtMs => _endsAtMs;
  int get seq => _seq;

  void verlaengern(int endsAtMs) => _endsAtMs = endsAtMs;

  /// Verpackt den Sitzungsschlüssel für einen Empfänger mit dessen (vertrauten) öffentlichen Schlüsseln.
  StandortWrap wrapFuer(String empfaengerId, OeffentlicheSchluessel empfaenger) {
    if (!_idOk(empfaengerId) || empfaenger.version < 1) throw _format();
    final sealed = crypto.versiegeln(_schluessel, empfaenger.enc);
    final roh = StandortWrap(
      shareId: shareId,
      senderId: ichId,
      senderKeyVersion: meineKeyVersion,
      empfaengerId: empfaengerId,
      empfaengerKeyVersion: empfaenger.version,
      endsAtMs: _endsAtMs,
      versiegelt: sealed,
      signatur: Uint8List(0),
    );
    return StandortWrap(
      shareId: shareId,
      senderId: ichId,
      senderKeyVersion: meineKeyVersion,
      empfaengerId: empfaengerId,
      empfaengerKeyVersion: empfaenger.version,
      endsAtMs: _endsAtMs,
      versiegelt: sealed,
      signatur: crypto.signieren(roh._signaturEingabe, _signGeheim),
    );
  }

  /// Verschlüsselt und signiert eine Position; die Sequenznummer steigt bei jedem Aufruf.
  String paket({required double breite, required double laenge, double? genauigkeit, required DateTime jetzt, DateTime? messzeit}) {
    final zeit = messzeit ?? jetzt;
    final inhalt = utf8Bytes(
      jsonEncode({
        's': ++_seq,
        't': zeit.millisecondsSinceEpoch,
        'a': jetzt.add(kStandortPaketGueltigkeit).millisecondsSinceEpoch,
        'x': _endsAtMs,
        'la': breite,
        'lo': laenge,
        'g': ?genauigkeit,
      }),
    );
    final aad = _paketAad(shareId, ichId, meineKeyVersion);
    final nonce = crypto.zufall(kNonceLaengeStandort);
    final kopf = verketten([
      [kStandortPaketVersion],
      u32Bytes(meineKeyVersion),
      nonce,
    ]);
    final ct = crypto.verschluesseln(schluessel: _schluessel, nonce: nonce, klartext: inhalt, zusatzdaten: aad);
    final sig = crypto.signieren(_paketSignaturEingabe(aad, kopf, ct), _signGeheim);
    return base64urlKodieren(verketten([kopf, sig, ct]));
  }

  /// Überschreibt den Sitzungsschlüssel (best effort).
  void vergessen() {
    loescheBytes(_schluessel);
    loescheBytes(_signGeheim);
  }
}

/// Seite des Empfängers: eine angenommene Freigabe mit Schlüssel und Zähler gegen Wiederholung.
class StandortEmpfaenger {
  final CryptoProvider crypto;
  final String shareId;
  final String senderId;
  final int senderKeyVersion;
  final OeffentlicheSchluessel _sender;
  final Uint8List _schluessel;
  int _hoechsteSeq = 0;

  /// Ende der Freigabe laut Wrap, später laut letztem gültigen Paket.
  DateTime freigabeEnde;

  StandortEmpfaenger._(this.crypto, this.shareId, this.senderId, this.senderKeyVersion, this._sender, this._schluessel, this.freigabeEnde);

  int get hoechsteSeq => _hoechsteSeq;

  /// Prüft den Wrap (Absender und Freigabe müssen zu den Angaben des Servers passen, Empfänger und Schlüsselversion zu mir, Signatur gegen den
  /// gemerkten Schlüssel des Absenders) und öffnet ihn erst danach. [sender] ist der gemerkte (TOFU) Schlüssel, nie einer vom Server.
  factory StandortEmpfaenger.annehmen(
    CryptoProvider crypto, {
    required String wrapText,
    required String erwarteteShareId,
    required String erwarteterSenderId,
    required String ichId,
    required Personenschluessel meinSchluessel,
    required int meineKeyVersion,
    required OeffentlicheSchluessel sender,
    required DateTime jetzt,
  }) {
    final w = StandortWrap.dekodieren(wrapText);
    if (w.shareId != erwarteteShareId || w.senderId != erwarteterSenderId) throw _format();
    if (w.empfaengerId != ichId || w.empfaengerKeyVersion != meineKeyVersion) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Standortfreigabe ist nicht für dich und deinen aktuellen Schlüssel bestimmt.');
    if (sender.version != w.senderKeyVersion) throw _signatur();
    if (!crypto.signaturPruefen(w._signaturEingabe, w.signatur, sender.sign)) throw _signatur();
    final ende = DateTime.fromMillisecondsSinceEpoch(w.endsAtMs);
    if (!ende.isAfter(jetzt) || ende.isAfter(jetzt.add(kStandortMaxDauer + _kUhrenToleranz))) throw _format();
    final klar = crypto.versiegelungOeffnen(w.versiegelt, meinSchluessel.encOeffentlich, meinSchluessel.encGeheim);
    if (klar.length != 32) {
      loescheBytes(klar);
      throw _format();
    }
    return StandortEmpfaenger._(crypto, w.shareId, w.senderId, w.senderKeyVersion, sender, klar, ende);
  }

  /// Öffnet ein Positions-Paket: Signatur zuerst, dann Entschlüsseln, dann Zähler, Ablauf und Wertebereich.
  /// Wirft [CryptoFehler] (beschädigt, falsche Signatur) oder [StandortPaketAbgelehnt] (veraltet, wiederholt).
  StandortPaketInhalt oeffnen(String paket, {required DateTime jetzt}) {
    final bytes = base64urlDekodieren(paket);
    if (bytes.length < _paketKopf + _sigLaenge + _tagLaenge) throw _format();
    if (bytes[0] != kStandortPaketVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Das Standortpaket stammt von einer neueren App-Version.');
    if (u32Lesen(bytes, 1) != senderKeyVersion) throw _signatur();
    final kopf = Uint8List.sublistView(bytes, 0, _paketKopf);
    final nonce = Uint8List.sublistView(bytes, 5, _paketKopf);
    final sig = Uint8List.sublistView(bytes, _paketKopf, _paketKopf + _sigLaenge);
    final ct = Uint8List.sublistView(bytes, _paketKopf + _sigLaenge);
    final aad = _paketAad(shareId, senderId, senderKeyVersion);
    if (!crypto.signaturPruefen(_paketSignaturEingabe(aad, kopf, ct), sig, _sender.sign)) throw _signatur();
    final klar = crypto.entschluesseln(schluessel: _schluessel, nonce: nonce, chiffretext: ct, zusatzdaten: aad);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(klar));
    } on FormatException {
      throw _format();
    }
    if (decoded is! Map) throw _format();
    final Map<Object?, Object?> roh = decoded;
    int? ganz(String k) {
      final v = roh[k];
      return v is int ? v : null;
    }

    double? zahl(String k) {
      final v = roh[k];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    final seq = ganz('s');
    final t = ganz('t');
    final a = ganz('a');
    final x = ganz('x');
    final breite = zahl('la');
    final laenge = zahl('lo');
    final g = roh.containsKey('g') ? zahl('g') : null;
    if (seq == null || seq < 1 || t == null || a == null || x == null || breite == null || laenge == null) throw _format();
    if (breite < -90 || breite > 90 || laenge < -180 || laenge > 180) throw _format();
    if (roh.containsKey('g') && (g == null || g < 0 || g > 1e7)) throw _format();
    final zeit = DateTime.fromMillisecondsSinceEpoch(t);
    final ablauf = DateTime.fromMillisecondsSinceEpoch(a);
    final ende = DateTime.fromMillisecondsSinceEpoch(x);
    // Reihenfolge der Prüfung: erst Zähler, dann Ablauf, dann Zukunft
    if (seq <= _hoechsteSeq) throw const StandortPaketAbgelehnt(PaketAblehnung.wiederholt);
    if (!ablauf.isAfter(jetzt)) throw const StandortPaketAbgelehnt(PaketAblehnung.abgelaufen);
    // weder eine Messung noch ein Ablauf weit in der Zukunft (sonst ließe sich ein Paket auf Vorrat "aufheben")
    if (zeit.isAfter(jetzt.add(_kUhrenToleranz)) || ablauf.isAfter(jetzt.add(kStandortPaketGueltigkeit + _kUhrenToleranz))) throw const StandortPaketAbgelehnt(PaketAblehnung.zukunft);
    _hoechsteSeq = seq;
    // das Ende der Freigabe darf der Absender verlängern, aber nie über die Obergrenze hinaus
    final deckel = jetzt.add(kStandortMaxDauer);
    freigabeEnde = ende.isAfter(deckel) ? deckel : ende;
    return StandortPaketInhalt(seq: seq, zeit: zeit, ablauf: ablauf, freigabeEnde: freigabeEnde, breite: breite, laenge: laenge, genauigkeit: g);
  }

  void vergessen() => loescheBytes(_schluessel);
}
