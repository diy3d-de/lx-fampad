// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), Kopplungscode und Postfach-Schlüssel. Formate verbindlich: docs/HA-FORMAT.md.
//
// Der Kopplungscode `FH1-<base64url ohne Auffüllung von UTF-8-JSON>` entsteht in der App (nur Admin, einmal angezeigt) und wird von der Home-Assistant-Integration gelesen:
//   { "v": 1, "u": "https://…", "t": "fhi_…", "p": <öffentlicher Postfach-Schlüssel, 32 Byte Base64>, "s": <MAC-Geheimnis, 32 Byte Base64>, "n": "Name" }
// Der PRIVATE Postfach-Schlüssel (X25519) und das MAC-Geheimnis liegen NUR im Schlüsselspeicher des Geräts, das die Verbindung koppelt (dem Abholgerät): `ingest.postfach.<userId>`.
// Abmelden löscht ihn nie (wie der Personenschlüssel), nur "Gerät abgeben". Nichts davon wird geloggt.
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/bytes.dart';
import '../crypto/crypto_provider.dart';
import '../crypto/schluessel_speicher.dart';

const String kKopplungPraefix = 'FH1-';
const int kKopplungVersion = 1;
const int kMaxKopplungZeichen = 2000;
const int kMaxVerbindungsname = 40;

/// Ein Einwurf-Token (`POST /ingest/tokens`): `fhi_` + 32 Zufallsbytes als Base64url (43 Zeichen).
final RegExp _tokenForm = RegExp(r'^fhi_[A-Za-z0-9_-]{43}$');

bool istEinwurfToken(String t) => _tokenForm.hasMatch(t);

/// Name im Schlüsselspeicher (je Person getrennt, wie `e2ee.pk.<uid>`).
String postfachName(String userId) => 'ingest.postfach.$userId';

/// Die Kennungen der Verbindungen (Token-IDs, nichts Geheimes), die DIESES Gerät gekoppelt hat: nur deren Päckchen holt es ab (`GET /ingest/zaehler/pending?token=`). Sie liegen neben dem
/// Postfach-Schlüssel (überleben das Abmelden wie er, verschwinden mit ihm). Fehlt der Eintrag (Gerät aus der Zeit davor), holt das Gerät wie bisher alle Päckchen der Familie ab.
String postfachVerbindungenName(String userId) => 'ingest.tokens.$userId';

/// Höchstens so viele gemerkte Verbindungen je Gerät (der Server erlaubt 5 aktive; widerrufene dürfen noch etwas länger abholbar bleiben).
const int kMaxGemerkteVerbindungen = 20;

final RegExp _idForm = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Inhalt eines Kopplungscodes.
class IngestKopplung {
  /// Basisadresse des Servers (nur https, ohne Pfad).
  final String url;
  final String token;

  /// Öffentlicher Postfach-Schlüssel (X25519, 32 Byte) und Prüfgeheimnis des MAC (32 Byte).
  final Uint8List postfach;
  final Uint8List geheimnis;
  final String name;
  IngestKopplung({required this.url, required this.token, required this.postfach, required this.geheimnis, required this.name});
}

/// Basisadresse für den Code: nur https, nur Rechner und Port, nie ein Pfad, keine Zugangsdaten. null, wenn sich keine gültige Adresse ergibt.
String? kopplungsAdresse(String adresse) {
  final u = Uri.tryParse(adresse.trim());
  if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty) return null;
  return 'https://${u.host}${u.hasPort && u.port != 443 ? ':${u.port}' : ''}';
}

String _b64(List<int> b) => base64.encode(b);

/// Strenges Standard-Base64 (mit Auffüllung, kanonisch) zu genau [laenge] Bytes; sonst null.
Uint8List? _b64Fest(Object? v, int laenge) {
  if (v is! String || v.length != ((laenge + 2) ~/ 3) * 4 || !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(v)) return null;
  try {
    final b = base64.decode(v);
    return b.length == laenge && base64.encode(b) == v ? Uint8List.fromList(b) : null;
  } on FormatException {
    return null;
  }
}

/// Baut den Kopplungscode. Wirft [ArgumentError] bei ungültigen Eingaben (es entsteht nie ein Code, den die Gegenseite ablehnen müsste).
String kopplungscodeBauen(IngestKopplung k) {
  final u = kopplungsAdresse(k.url);
  if (u == null || u != k.url) throw ArgumentError('Ungültige Serveradresse');
  if (!istEinwurfToken(k.token) || k.postfach.length != 32 || k.geheimnis.length != 32) throw ArgumentError('Ungültige Kopplungsdaten');
  final n = k.name.trim();
  if (n.isEmpty || n.length > kMaxVerbindungsname) throw ArgumentError('Ungültiger Name');
  final json = jsonEncode({'v': kKopplungVersion, 'u': u, 't': k.token, 'p': _b64(k.postfach), 's': _b64(k.geheimnis), 'n': n});
  final code = '$kKopplungPraefix${base64urlKodieren(utf8.encode(json))}';
  if (code.length > kMaxKopplungZeichen) throw ArgumentError('Kopplungscode zu lang');
  return code;
}

/// Liest einen Kopplungscode streng; null bei allem, was nicht genau dem Format entspricht (Präfix, Kodierung, JSON, Version, Adresse, Token, Schlüssel, Name).
IngestKopplung? kopplungscodeLesen(String code) {
  final c = code.trim();
  if (!c.startsWith(kKopplungPraefix) || c.length > kMaxKopplungZeichen) return null;
  try {
    final text = utf8.decode(base64urlDekodieren(c.substring(kKopplungPraefix.length)));
    final d = jsonDecode(text);
    if (d is! Map || d['v'] != kKopplungVersion) return null;
    final u = d['u'];
    final t = d['t'];
    final n = d['n'];
    final p = _b64Fest(d['p'], 32);
    final s = _b64Fest(d['s'], 32);
    if (u is! String || t is! String || n is! String || p == null || s == null) return null;
    final basis = kopplungsAdresse(u);
    final name = n.trim();
    if (basis == null || basis != u || !istEinwurfToken(t) || name.isEmpty || name.length > kMaxVerbindungsname) return null;
    return IngestKopplung(url: u, token: t, postfach: p, geheimnis: s, name: name);
  } on Object {
    return null; // kaputte Kodierung, kein UTF-8, kein JSON
  }
}

/// Die Geheimnisse des Abholgeräts: Postfach-Schlüsselpaar und MAC-Geheimnis. 96 Byte: öffentlich | geheim | Geheimnis.
class PostfachSchluessel {
  final Uint8List oeffentlich;
  final Uint8List geheim;
  final Uint8List geheimnis;
  PostfachSchluessel(this.oeffentlich, this.geheim, this.geheimnis);

  /// Neues Postfach: `crypto_box_keypair` (hier über einen Zufalls-Seed der Bibliothek) und 32 Zufallsbytes als MAC-Geheimnis.
  factory PostfachSchluessel.erzeugen(CryptoProvider c) {
    final paar = c.boxPaarAusSeed(c.zufall(32));
    return PostfachSchluessel(paar.oeffentlich, paar.geheim, c.zufall(32));
  }

  Uint8List toBytes() => verketten([oeffentlich, geheim, geheimnis]);

  static PostfachSchluessel? fromBytes(Uint8List b) {
    if (b.length != 96) return null;
    return PostfachSchluessel(Uint8List.fromList(b.sublist(0, 32)), Uint8List.fromList(b.sublist(32, 64)), Uint8List.fromList(b.sublist(64)));
  }

  /// Überschreibt die Bytes im Arbeitsspeicher (best effort).
  void verwerfen() {
    loescheBytes(geheim);
    loescheBytes(geheimnis);
  }
}

/// Lesen, Schreiben und Löschen des Postfach-Schlüssels. [lesen] liefert null NUR, wenn es ihn nicht gibt; ein Fehler des Speichers wirft ([SchluesselSpeicherFehler]) und
/// bedeutet nie "kein Schlüssel" (dann bleibt alles unverändert, ein späterer Versuch kann klappen).
class PostfachSpeicher {
  final SchluesselSpeicher speicher;
  const PostfachSpeicher(this.speicher);

  Future<PostfachSchluessel?> lesen(String userId) async {
    final b = await speicher.lesen(postfachName(userId));
    if (b == null) return null;
    final s = PostfachSchluessel.fromBytes(b);
    if (s == null) throw const SchluesselSpeicherFehler('Der Postfach-Schlüssel ist beschädigt.', dauerhaft: true);
    return s;
  }

  Future<bool> vorhanden(String userId) async => (await speicher.lesen(postfachName(userId))) != null;

  Future<void> schreiben(String userId, PostfachSchluessel s) => speicher.schreiben(postfachName(userId), s.toBytes());

  /// Löscht den Schlüssel und die gemerkten Verbindungen.
  Future<void> entfernen(String userId) async {
    await speicher.loeschen(postfachName(userId));
    await speicher.loeschen(postfachVerbindungenName(userId));
  }

  /// Die Token-IDs der Verbindungen dieses Geräts; null = nichts gemerkt (Gerät aus der Zeit davor, oder noch nie gekoppelt). Ein Lesefehler wirft ([SchluesselSpeicherFehler]).
  Future<List<String>?> verbindungen(String userId) async {
    final b = await speicher.lesen(postfachVerbindungenName(userId));
    if (b == null) return null;
    try {
      final d = jsonDecode(utf8.decode(b));
      if (d is! List) return null;
      return [for (final x in d) if (x is String && _idForm.hasMatch(x)) x];
    } on Object {
      return null; // unlesbar = wie nicht vorhanden (das Gerät holt dann alle ab, nichts geht verloren)
    }
  }

  /// Merkt die Verbindung (Token-ID) als die eines Geräts; die jüngsten [kMaxGemerkteVerbindungen] bleiben.
  Future<void> verbindungMerken(String userId, String tokenId) => verbindungenMerken(userId, [tokenId]);

  /// Wie [verbindungMerken], für mehrere Verbindungen in einem Schreibvorgang (Reihenfolge: die zuletzt genannte ist die jüngste).
  Future<void> verbindungenMerken(String userId, Iterable<String> tokenIds) async {
    final neue = [for (final t in tokenIds) if (_idForm.hasMatch(t)) t];
    if (neue.isEmpty) return;
    final alt = (await verbindungen(userId)) ?? <String>[];
    final neu = [...alt.where((x) => !neue.contains(x)), ...neue];
    final kurz = neu.length > kMaxGemerkteVerbindungen ? neu.sublist(neu.length - kMaxGemerkteVerbindungen) : neu;
    await speicher.schreiben(postfachVerbindungenName(userId), Uint8List.fromList(utf8.encode(jsonEncode(kurz))));
  }
}
