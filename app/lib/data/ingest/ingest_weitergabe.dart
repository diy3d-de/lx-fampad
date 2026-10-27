// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), Mehrgeräte-Weitergabe: der Postfach-Schlüssel eines Elternteils wird vom Abholgerät auf ein weiteres EIGENES Gerät übertragen,
// damit auch dieses abholen kann. Gleiches Verfahren wie die Geräte-Übertragung des Personenschlüssels (`uebertragung.dart`), nur mit eigenen Verwendungszwecken, eigenem QR-Präfix
// `LXP1:` und eigener Server-Route (`POST /ingest/postfach-transfer[/claim]`):
//   Das Abholgerät erzeugt ein 32-Byte-Einmalgeheimnis S und leitet daraus zwei unabhängige Werte ab: eine Suchkennung (geht an den Server) und einen Verpackungsschlüssel (bleibt
//   auf den Geräten). Der Inhalt (Postfach-Schlüsselpaar, MAC-Geheimnis, Merkliste der eigenen Verbindungen) wird damit verschlüsselt und als kurzlebiger Blob (2 Minuten, einmal
//   einlösbar, nur dieselbe Person) über den Server gereicht. S steht nur im QR bzw. Code, den das Zielgerät einliest; der Server sieht nie ein Geheimnis. Keine neuen Primitive.
// Klartext (Version 1): 1 Byte Version | 96 Byte Postfach (öffentlich 32, geheim 32, MAC-Geheimnis 32) | 1 Byte Anzahl n (0 bis 20) | n mal 16 Byte (UUID einer Verbindung, nur die
// Token-IDs, nichts Geheimes). Blob (Base64url): v (1 Byte) | nonce (24 Byte) | Chiffretext; AAD = "lx-fampad|ingest-postfach-transfer|v1|<userId>".
// Das Zielgerät überschreibt nie einen vorhandenen, anderen Postfach-Schlüssel. Nichts davon wird geloggt; Bytes werden nach Gebrauch überschrieben.
import 'dart:typed_data';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../crypto/bytes.dart';
import '../crypto/code32.dart';
import '../crypto/crypto_fehler.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/schluessel_speicher.dart';
import 'ingest_kopplung.dart';

const String _zweckAnzeige = 'lx-fampad|ingest-postfach-transfer|anzeige|v1';
const String _zweckSuche = 'lx-fampad|ingest|postfach-transfer-lookup|v1';
const String _zweckSchluessel = 'lx-fampad|ingest|postfach-transfer-key|v1';

/// QR-Inhalt: "LXP1:" + 56 Zeichen. Zum Abtippen: dieselben 56 Zeichen in 14 Vierergruppen (Prüfsumme wie beim Übertragungscode, aber mit eigenem Zweck: ein Code für den
/// Personenschlüssel wird hier abgelehnt und umgekehrt).
const String kPostfachQrPraefix = 'LXP1:';
const int _blobVersion = 1;
const int _nonce = 24;
const int _postfachLaenge = 96;

final RegExp _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Was ein Zielgerät aus dem Blob bekommt.
class PostfachInhalt {
  final PostfachSchluessel schluessel;

  /// Die Token-IDs der Verbindungen, die das Abholgerät gekoppelt hat (leer: keine Liste, das Zielgerät holt dann wie ein Gerät aus der Zeit davor alle Päckchen der Familie ab).
  final List<String> verbindungen;
  PostfachInhalt(this.schluessel, this.verbindungen);
}

/// Was das Abholgerät bereitstellt: [geheimnis] nur in QR/Code, [suchkennung] und [blob] zum Server.
class PostfachAngebot {
  final Uint8List geheimnis;
  final String suchkennung;
  final String blob;
  const PostfachAngebot({required this.geheimnis, required this.suchkennung, required this.blob});
}

class PostfachWeitergabe {
  static Uint8List _ableiten(CryptoProvider crypto, String zweck, Uint8List geheimnis) => crypto.hash(utf8Bytes(zweck), schluessel: geheimnis);

  static Uint8List _aad(String userId) => utf8Bytes('lx-fampad|ingest-postfach-transfer|v1|$userId');

  /// Suchkennung (Base64url, 32 Byte) für den Server; lässt keinen Rückschluss auf das Geheimnis zu.
  static String suchkennung(CryptoProvider crypto, Uint8List geheimnis) => base64urlKodieren(_ableiten(crypto, _zweckSuche, geheimnis));

  static Uint8List _uuidBytes(String id) {
    final hex = id.replaceAll('-', '');
    return Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
  }

  static String _uuidText(Uint8List b) {
    final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// Der Klartext (Version 1). Nur gültige UUIDs aus [verbindungen] gehen mit, höchstens [kMaxGemerkteVerbindungen] (die jüngsten).
  static Uint8List _klartext(PostfachSchluessel s, List<String> verbindungen) {
    final ids = [for (final v in verbindungen) if (_uuid.hasMatch(v.toLowerCase())) v.toLowerCase()];
    final kurz = ids.length > kMaxGemerkteVerbindungen ? ids.sublist(ids.length - kMaxGemerkteVerbindungen) : ids;
    return verketten([
      [_blobVersion],
      s.toBytes(),
      [kurz.length],
      for (final id in kurz) _uuidBytes(id),
    ]);
  }

  static PostfachAngebot anbieten(CryptoProvider crypto, {required PostfachSchluessel schluessel, required List<String> verbindungen, required String userId}) {
    final geheimnis = crypto.zufall(kGeheimnisLaenge);
    final nonce = crypto.zufall(_nonce);
    final klar = _klartext(schluessel, verbindungen);
    try {
      final ct = crypto.verschluesseln(schluessel: _ableiten(crypto, _zweckSchluessel, geheimnis), nonce: nonce, klartext: klar, zusatzdaten: _aad(userId));
      return PostfachAngebot(
        geheimnis: geheimnis,
        suchkennung: suchkennung(crypto, geheimnis),
        blob: base64urlKodieren(verketten([
          [_blobVersion],
          nonce,
          ct,
        ])),
      );
    } finally {
      loescheBytes(klar);
    }
  }

  /// QR-Text (kompakt).
  static String qrText(Uint8List geheimnis) => '$kPostfachQrPraefix${Code32.kodieren(geheimnis, _zweckAnzeige, gruppiert: false)}';

  /// Code zum Abtippen (14 Vierergruppen).
  static String codeText(Uint8List geheimnis) => Code32.kodieren(geheimnis, _zweckAnzeige);

  /// Liest QR-Text oder abgetippten Code; wirft [CryptoFehler] (format/pruefsumme).
  static Uint8List geheimnisLesen(String eingabe) {
    var text = eingabe.trim();
    if (text.toUpperCase().startsWith(kPostfachQrPraefix)) text = text.substring(kPostfachQrPraefix.length);
    return Code32.dekodieren(text, _zweckAnzeige);
  }

  /// Entschlüsselt den eingelösten Blob mit dem Geheimnis aus dem QR; [userId] muss die der angemeldeten Person sein (steckt in der AAD). Wirft [CryptoFehler]
  /// (format, version, entschluesselung).
  static PostfachInhalt oeffnen(CryptoProvider crypto, {required String blob, required Uint8List geheimnis, required String userId}) {
    final bytes = base64urlDekodieren(blob);
    if (bytes.length < 1 + _nonce + 1 + _postfachLaenge + 1 + 16) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Weitergabe ist beschädigt.');
    if (bytes[0] != _blobVersion) throw const CryptoFehler(CryptoFehlerArt.version, 'Die Weitergabe stammt von einer neueren App-Version.');
    final klar = crypto.entschluesseln(
      schluessel: _ableiten(crypto, _zweckSchluessel, geheimnis),
      nonce: Uint8List.sublistView(bytes, 1, 1 + _nonce),
      chiffretext: Uint8List.sublistView(bytes, 1 + _nonce),
      zusatzdaten: _aad(userId),
    );
    try {
      if (klar.length < 2 + _postfachLaenge || klar[0] != _blobVersion) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Weitergabe ist beschädigt.');
      final n = klar[1 + _postfachLaenge];
      if (n > kMaxGemerkteVerbindungen || klar.length != 2 + _postfachLaenge + n * 16) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Weitergabe ist beschädigt.');
      final s = PostfachSchluessel.fromBytes(Uint8List.fromList(klar.sublist(1, 1 + _postfachLaenge)));
      if (s == null) throw const CryptoFehler(CryptoFehlerArt.format, 'Die Weitergabe ist beschädigt.');
      final ids = [for (var i = 0; i < n; i++) _uuidText(Uint8List.fromList(klar.sublist(2 + _postfachLaenge + i * 16, 2 + _postfachLaenge + (i + 1) * 16)))];
      return PostfachInhalt(s, ids);
    } finally {
      loescheBytes(klar);
    }
  }
}

/// Warum die Weitergabe nicht klappte (feste Texte, nie ein Servertext).
enum WeitergabeFehlerArt {
  /// Dieses Gerät hat keinen Postfach-Schlüssel, den es weitergeben könnte.
  keinPostfach,

  /// Der Server nimmt keine Werte aus Home Assistant an (Einwurf aus).
  nichtVerfuegbar,

  /// Nicht angemeldet oder keine Berechtigung (nur Eltern und Admins).
  nichtBereit,

  /// Kein Netz oder der Server antwortete nicht.
  netz,

  /// Der Code ist unvollständig, ein Tippfehler oder gehört zu etwas anderem.
  codeUngueltig,

  /// Der Code ist abgelaufen oder schon benutzt.
  abgelaufen,

  /// Die Weitergabe ließ sich nicht öffnen (beschädigt, anderes Konto oder neuere App-Version).
  beschaedigt,

  /// Dieses Gerät hat schon einen Postfach-Schlüssel (zum Beispiel von einer eigenen Verbindung): der Code wird nicht eingelöst, nichts wird überschrieben.
  schonAnderes,

  /// Der Schlüsselspeicher ließ sich nicht lesen oder beschreiben.
  speicher,
}

class WeitergabeFehler implements Exception {
  final WeitergabeFehlerArt art;
  const WeitergabeFehler(this.art);

  String get text => switch (art) {
    WeitergabeFehlerArt.keinPostfach => 'Dieses Gerät hat den Schlüssel für die Werte aus Home Assistant nicht und kann ihn nicht weitergeben.',
    WeitergabeFehlerArt.nichtVerfuegbar => 'Der Server nimmt keine Werte aus Home Assistant an.',
    WeitergabeFehlerArt.nichtBereit => 'Das ist gerade nicht möglich. Prüfe deine Anmeldung.',
    WeitergabeFehlerArt.netz => 'Der Server ist gerade nicht erreichbar. Versuche es gleich noch einmal.',
    WeitergabeFehlerArt.codeUngueltig => 'Der Code stimmt nicht. Prüfe ihn auf Tippfehler oder scanne den QR-Code noch einmal.',
    WeitergabeFehlerArt.abgelaufen => 'Der Code ist abgelaufen oder schon benutzt. Zeige auf dem anderen Gerät einen neuen an.',
    WeitergabeFehlerArt.beschaedigt => 'Die Weitergabe ließ sich nicht öffnen. Zeige auf dem anderen Gerät einen neuen Code an, und halte beide Apps aktuell.',
    WeitergabeFehlerArt.schonAnderes => 'Dieses Gerät hat schon ein Postfach für Home Assistant. Es bleibt unverändert, der Code wurde nicht eingelöst.',
    WeitergabeFehlerArt.speicher => 'Der Schlüsselspeicher dieses Geräts ließ sich gerade nicht nutzen. Versuche es noch einmal.',
  };

  @override
  String toString() => 'WeitergabeFehler(${art.name})';
}

/// Angebot auf dem Abholgerät: QR-Text und Code enthalten das Einmalgeheimnis, [gueltigBis] ist die Frist des Servers.
class WeitergabeAnzeige {
  final String qrText;
  final String codeText;
  final DateTime gueltigBis;
  const WeitergabeAnzeige({required this.qrText, required this.codeText, required this.gueltigBis});
}

/// Ergebnis auf dem Zielgerät.
enum WeitergabeErgebnis {
  /// Der Schlüssel liegt jetzt auf diesem Gerät.
  uebernommen,
}

class IngestWeitergabe {
  final FampadApi api;
  final Future<CryptoProvider> Function() krypto;
  final PostfachSpeicher postfach;
  final String? Function() ich;
  const IngestWeitergabe({required this.api, required this.krypto, required this.postfach, required this.ich});

  Future<CryptoProvider> _krypto() async {
    try {
      return await krypto();
    } on Object {
      throw const WeitergabeFehler(WeitergabeFehlerArt.nichtBereit);
    }
  }

  WeitergabeFehler _apiFehler(ApiException e) {
    if (e.status == 404) return const WeitergabeFehler(WeitergabeFehlerArt.nichtVerfuegbar);
    if (e.kind == ApiErrorKind.nichtAngemeldet || e.status == 403) return const WeitergabeFehler(WeitergabeFehlerArt.nichtBereit);
    return const WeitergabeFehler(WeitergabeFehlerArt.netz);
  }

  /// Auf dem Abholgerät: Weitergabe für ein weiteres Gerät anlegen (2 Minuten gültig, einmal einlösbar).
  Future<WeitergabeAnzeige> anbieten() async {
    final uid = ich();
    if (uid == null) throw const WeitergabeFehler(WeitergabeFehlerArt.nichtBereit);
    final PostfachSchluessel? s;
    final List<String>? liste;
    try {
      s = await postfach.lesen(uid);
      liste = await postfach.verbindungen(uid);
    } on SchluesselSpeicherFehler {
      throw const WeitergabeFehler(WeitergabeFehlerArt.speicher);
    }
    if (s == null) throw const WeitergabeFehler(WeitergabeFehlerArt.keinPostfach);
    try {
      final c = await _krypto();
      final angebot = PostfachWeitergabe.anbieten(c, schluessel: s, verbindungen: liste ?? const [], userId: uid);
      try {
        final bis = await api.ingestWeitergabeAnlegen(suchkennung: angebot.suchkennung, blob: angebot.blob);
        return WeitergabeAnzeige(qrText: PostfachWeitergabe.qrText(angebot.geheimnis), codeText: PostfachWeitergabe.codeText(angebot.geheimnis), gueltigBis: bis);
      } on ApiException catch (e) {
        throw _apiFehler(e);
      } finally {
        loescheBytes(angebot.geheimnis);
      }
    } finally {
      s.verwerfen();
    }
  }

  /// Auf dem Zielgerät: QR-Text oder Code einlesen, die Weitergabe beim Server einlösen und den Schlüssel übernehmen. Hat dieses Gerät schon einen Postfach-Schlüssel,
  /// wird der Code gar nicht erst eingelöst ([WeitergabeFehlerArt.schonAnderes]); es wird nie etwas überschrieben.
  Future<WeitergabeErgebnis> annehmen(String eingabe) async {
    final uid = ich();
    if (uid == null) throw const WeitergabeFehler(WeitergabeFehlerArt.nichtBereit);
    final Uint8List geheimnis;
    try {
      geheimnis = PostfachWeitergabe.geheimnisLesen(eingabe);
    } on CryptoFehler {
      throw const WeitergabeFehler(WeitergabeFehlerArt.codeUngueltig);
    }
    PostfachSchluessel? vorhanden;
    PostfachInhalt? inhalt;
    try {
      // erst den Schlüsselspeicher prüfen, dann den Code verbrauchen: ein nicht lesbarer Speicher soll nie einen einmaligen Code kosten
      try {
        vorhanden = await postfach.lesen(uid);
      } on SchluesselSpeicherFehler {
        throw const WeitergabeFehler(WeitergabeFehlerArt.speicher);
      }
      // Hat dieses Gerät schon einen Postfach-Schlüssel, wird der Code gar nicht erst eingelöst (nichts wird überschrieben, der Server protokolliert keine Übernahme)
      if (vorhanden != null) throw const WeitergabeFehler(WeitergabeFehlerArt.schonAnderes);
      final c = await _krypto();
      final String blob;
      try {
        blob = await api.ingestWeitergabeEinloesen(PostfachWeitergabe.suchkennung(c, geheimnis));
      } on ApiException catch (e) {
        if (e.status == 404 && e.code == 'not_found') {
          // 404 heißt hier: Code abgelaufen, schon benutzt oder falsch. Ein Server ohne Einwurf antwortet ebenso; die Meldung trifft beides ("neu anzeigen"), der Einstieg
          // wird ohnehin nur bei verfügbarem Einwurf angeboten.
          throw const WeitergabeFehler(WeitergabeFehlerArt.abgelaufen);
        }
        throw _apiFehler(e);
      } on FormatException {
        throw const WeitergabeFehler(WeitergabeFehlerArt.beschaedigt);
      }
      try {
        inhalt = PostfachWeitergabe.oeffnen(c, blob: blob, geheimnis: geheimnis, userId: uid);
      } on CryptoFehler {
        throw const WeitergabeFehler(WeitergabeFehlerArt.beschaedigt);
      }
      final neu = inhalt.schluessel;
      try {
        // erst die Merkliste, dann der Schlüssel: scheitert das Schreiben des Schlüssels, bleibt höchstens eine unbenutzte Liste liegen (sie macht ohne Schlüssel nichts)
        if (inhalt.verbindungen.isNotEmpty) await postfach.verbindungenMerken(uid, inhalt.verbindungen);
        await postfach.schreiben(uid, neu);
        return WeitergabeErgebnis.uebernommen;
      } on SchluesselSpeicherFehler {
        throw const WeitergabeFehler(WeitergabeFehlerArt.speicher);
      }
    } finally {
      loescheBytes(geheimnis);
      vorhanden?.verwerfen();
      inhalt?.schluessel.verwerfen();
    }
  }
}
