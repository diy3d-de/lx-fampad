// Fake für CryptoProvider: läuft ohne native Bibliothek, VERHÄLT SICH aber wie echte Verfahren (Verschlüsseln-dann-MAC mit HMAC-SHA256, Signatur als
// HMAC über den öffentlichen Schlüssel). Nur für Tests der Logik (Hülle, Sicherung, Übertragung, Zustand): Das ist KEINE sichere Kryptografie;
// die echten Bausteine prüfen test/crypto/sodium_kat_test.dart und alle Logik-Tests laufen zusätzlich gegen libsodium, wo sie verfügbar ist.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:lx_fampad/data/crypto/bytes.dart';
import 'package:lx_fampad/data/crypto/crypto_fehler.dart';
import 'package:lx_fampad/data/crypto/crypto_provider.dart';
import 'package:lx_fampad/data/crypto/sodium_crypto_provider.dart';

class FakeCryptoProvider implements CryptoProvider {
  final Random _zufall;

  /// true: [zufall] liefert immer dieselben Bytes (zum Testen der Nonce-Wiederverwendung).
  final bool konstant;

  FakeCryptoProvider({int? seed, this.konstant = false}) : _zufall = seed == null ? Random.secure() : Random(seed);

  Uint8List _hmac(List<int> key, List<int> data, [int laenge = 32]) {
    final out = BytesBuilder();
    var i = 0;
    while (out.length < laenge) {
      out.add(c.Hmac(c.sha256, key).convert([...data, i++]).bytes);
    }
    return Uint8List.fromList(out.takeBytes().sublist(0, laenge));
  }

  /// KEIN Argon2: billiger HMAC über Passwort, Salt und Parameter (nur damit Tests schnell laufen; Ausgabe hängt von allen Eingaben ab).
  @override
  Future<Uint8List> pwhash({required Uint8List passwort, required Uint8List salt, required int memKiB, required int ops}) async {
    if (salt.length != 16) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Parameter der Schlüsselableitung.');
    return _hmac(verketten([salt, u32Bytes(memKiB), u32Bytes(ops)]), passwort, 32);
  }

  @override
  Uint8List kdf(Uint8List master, String kontext, {int laenge = 32}) => hash(utf8Bytes(kontext), schluessel: master, laenge: laenge);

  @override
  Uint8List zufall(int laenge) => Uint8List.fromList(List.generate(laenge, (i) => konstant ? (i * 7 + 3) & 255 : _zufall.nextInt(256)));

  @override
  Uint8List hash(Uint8List nachricht, {Uint8List? schluessel, int laenge = 32}) => _hmac(schluessel ?? const [], nachricht, laenge);

  @override
  SchluesselPaar boxPaarAusSeed(Uint8List seed) => SchluesselPaar(_hmac(seed, utf8Bytes('box-pub')), _hmac(seed, utf8Bytes('box-sec')));

  @override
  SchluesselPaar signPaarAusSeed(Uint8List seed) {
    final pub = _hmac(seed, utf8Bytes('sign-pub'));
    return SchluesselPaar(pub, verketten([seed, pub]));
  }

  @override
  Uint8List signieren(Uint8List nachricht, Uint8List geheimerSchluessel) => _hmac(geheimerSchluessel.sublist(32), nachricht, 64);

  @override
  bool signaturPruefen(Uint8List nachricht, Uint8List signatur, Uint8List oeffentlicherSchluessel) =>
      gleicheBytes(signatur, _hmac(oeffentlicherSchluessel, nachricht, 64));

  Uint8List _tag(Uint8List key, Uint8List nonce, Uint8List aad, Uint8List ct) => _hmac(key, verketten([nonce, u32Bytes(aad.length), aad, ct]), 16);

  Uint8List _strom(Uint8List key, Uint8List nonce, int laenge) => _hmac(key, verketten([nonce, utf8Bytes('strom')]), laenge);

  @override
  Uint8List verschluesseln({required Uint8List schluessel, required Uint8List nonce, required Uint8List klartext, Uint8List? zusatzdaten}) {
    if (schluessel.length != 32 || nonce.length != 24) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Länge.');
    final s = _strom(schluessel, nonce, klartext.length);
    final ct = Uint8List.fromList([for (var i = 0; i < klartext.length; i++) klartext[i] ^ s[i]]);
    return verketten([ct, _tag(schluessel, nonce, zusatzdaten ?? Uint8List(0), ct)]);
  }

  @override
  Uint8List entschluesseln({required Uint8List schluessel, required Uint8List nonce, required Uint8List chiffretext, Uint8List? zusatzdaten}) {
    const fehler = CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    if (schluessel.length != 32 || nonce.length != 24 || chiffretext.length < 16) throw fehler;
    final ct = Uint8List.sublistView(chiffretext, 0, chiffretext.length - 16);
    if (!gleicheBytes(Uint8List.sublistView(chiffretext, chiffretext.length - 16), _tag(schluessel, nonce, zusatzdaten ?? Uint8List(0), ct))) throw fehler;
    final s = _strom(schluessel, nonce, ct.length);
    return Uint8List.fromList([for (var i = 0; i < ct.length; i++) ct[i] ^ s[i]]);
  }

  @override
  Uint8List versiegeln(Uint8List nachricht, Uint8List oeffentlicherSchluessel) {
    final eph = zufall(24);
    return verketten([eph, verschluesseln(schluessel: _hmac(oeffentlicherSchluessel, utf8Bytes('seal')), nonce: eph, klartext: nachricht)]);
  }

  @override
  Uint8List versiegelungOeffnen(Uint8List chiffretext, Uint8List oeffentlicherSchluessel, Uint8List geheimerSchluessel) {
    if (chiffretext.length < 24 + 16) throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    return entschluesseln(
      schluessel: _hmac(oeffentlicherSchluessel, utf8Bytes('seal')),
      nonce: Uint8List.sublistView(chiffretext, 0, 24),
      chiffretext: Uint8List.sublistView(chiffretext, 24),
    );
  }

  // Fake des secretstream: gleiche Maße wie libsodium (Kopfzeile 24 Byte, je Block 17 Byte mehr als der Klartext), Block i hängt über Nonce (Kopfzeile + Zähler) und Kennzeichen (AAD) an Reihenfolge
  // und Ende. KEINE sichere Kryptografie; die echten Bausteine prüfen die libsodium-Läufe der Tests.
  Uint8List _stromNonce(Uint8List kopf, int i) => verketten([Uint8List.sublistView(kopf, 0, 16), Uint8List.fromList([for (var b = 0; b < 8; b++) (i >> (8 * b)) & 255])]);

  @override
  Future<Uint8List> stromVerschluesseln({required Uint8List schluessel, required Uint8List klartext, int blockBytes = 65536}) async {
    if (schluessel.length != 32 || blockBytes < 1) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Ungültige Länge.');
    final kopf = zufall(24);
    final teile = <Uint8List>[kopf];
    var pos = 0;
    var i = 0;
    do {
      final ende = pos + blockBytes < klartext.length ? pos + blockBytes : klartext.length;
      final letzter = ende >= klartext.length;
      final flag = Uint8List.fromList([letzter ? 1 : 0]);
      final ct = verschluesseln(schluessel: schluessel, nonce: _stromNonce(kopf, i++), klartext: Uint8List.sublistView(klartext, pos, ende), zusatzdaten: flag);
      teile.addAll([flag, ct]);
      pos = ende;
    } while (pos < klartext.length);
    return verketten(teile);
  }

  @override
  Future<Uint8List> stromEntschluesseln({required Uint8List schluessel, required Uint8List chiffretext, int blockBytes = 65536}) async {
    const fehler = CryptoFehler(CryptoFehlerArt.entschluesselung, 'Entschlüsselung nicht möglich.');
    if (schluessel.length != 32 || blockBytes < 1 || chiffretext.length < 24 + 17) throw fehler;
    final kopf = Uint8List.sublistView(chiffretext, 0, 24);
    final teile = <Uint8List>[];
    var pos = 24;
    var i = 0;
    var istFinal = false;
    while (pos < chiffretext.length) {
      if (istFinal) throw fehler; // nach dem letzten Block darf nichts mehr kommen
      final ende = pos + blockBytes + 17 < chiffretext.length ? pos + blockBytes + 17 : chiffretext.length;
      final flag = Uint8List.sublistView(chiffretext, pos, pos + 1);
      istFinal = flag[0] == 1;
      teile.add(entschluesseln(schluessel: schluessel, nonce: _stromNonce(kopf, i++), chiffretext: Uint8List.sublistView(chiffretext, pos + 1, ende), zusatzdaten: flag));
      pos = ende;
    }
    if (!istFinal) throw fehler; // gekürzt
    return verketten(teile);
  }
}

/// Die Varianten, gegen die die Logik-Tests laufen: immer der Fake, dazu libsodium, wenn die Bibliothek geladen werden kann.
/// In der CI ist libsodium Pflicht (`SODIUM_ERFORDERLICH=1`): dann ist ein Ladefehler ein Testfehler statt eines Überspringens.
Future<List<(String, CryptoProvider)>> kryptoVarianten() async {
  final liste = <(String, CryptoProvider)>[('Fake', FakeCryptoProvider())];
  final echt = await echtesSodium();
  if (echt != null) liste.add(('libsodium', echt));
  return liste;
}

CryptoProvider? _echt;
Object? _echtFehler;
bool _versucht = false;

/// Lädt libsodium über [lader]. Ist libsodium [erforderlich] (CI), ist ein Ladefehler ein Fehler (nie ein stilles Überspringen), sonst null.
Future<CryptoProvider?> ladeEchtesSodium(Future<CryptoProvider> Function() lader, {required bool erforderlich}) async {
  try {
    return await lader();
  } on Object {
    if (erforderlich) rethrow;
    return null;
  }
}

/// libsodium oder null (z. B. lokal unter Windows ohne C-Compiler für den Build-Hook). Mit SODIUM_ERFORDERLICH=1 wirft jeder Aufruf, wenn das Laden scheitert.
Future<CryptoProvider?> echtesSodium() async {
  final erforderlich = Platform.environment['SODIUM_ERFORDERLICH'] == '1';
  if (!_versucht) {
    _versucht = true;
    try {
      _echt = await ladeEchtesSodium(SodiumCryptoProvider.laden, erforderlich: erforderlich);
    } on Object catch (e) {
      _echtFehler = e;
    }
  }
  if (_echtFehler != null) throw _echtFehler!;
  return _echt;
}
