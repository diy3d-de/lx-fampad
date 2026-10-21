// Passwort-Regeln und Vorschlag für die Passwort-Sicherung. Bewusst ohne Fremdpaket (kein zxcvbn): wenige, nachvollziehbare Regeln, die den
// Offline-Angriff auf den authKey (Argon2id, 64 MiB) nicht mit einem leicht zu ratenden Passwort entwerten. Die Prüfung läuft nur auf dem Gerät.
import 'dart:math';

import 'crypto_provider.dart';
import 'nfkc.dart';

/// Mindestlänge in Zeichen (Codepunkten, nach der Normalisierung).
const int kPasswortMindestlaenge = 12;

enum PasswortProblem {
  zuKurz('Das Passwort braucht mindestens $kPasswortMindestlaenge Zeichen.'),
  enthaeltKontodaten('Das Passwort darf deine E-Mail-Adresse oder deinen Namen nicht enthalten.'),
  zuHaeufig('Dieses Passwort ist zu leicht zu erraten.'),
  einfachesMuster('Das Passwort besteht aus einem einfachen Muster.');

  final String meldung;
  const PasswortProblem(this.meldung);
}

/// Kleine Verbotsliste (Kleinbuchstaben): häufige Passwörter und Begriffe rund um die App.
const List<String> kVerboteneWoerter = [
  'passwort',
  'password',
  'kennwort',
  'geheim',
  'hallo',
  'hello',
  'willkommen',
  'welcome',
  'familie',
  'family',
  'familienzentrale',
  'fampad',
  'lxfampad',
  'lxlabs',
  'qwertz',
  'qwerty',
  'asdfgh',
  'letmein',
  'iloveyou',
  'admin',
  'master',
  'dragon',
  'monkey',
  'fussball',
  'football',
  'sommer',
  'winter',
  'schatz',
  'liebe',
  'changeme',
  'abcdef',
  'test',
];

/// Kleinschreibung und Normalisierung; bei Buchstaben nur A-Z/ä/ö/ü, ß bleibt wie es ist (genügt für die Vergleiche hier).
String _klein(String s) => passwortNormalisiert(s).toLowerCase();

/// Nur Buchstaben und Ziffern (für Vergleiche ohne Trennzeichen).
String _kern(String s) => s.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

bool _folge(List<int> r, int laenge) {
  // aufsteigende oder absteigende Folge (123456, abcdef, 987654) ab [laenge] Zeichen
  var lauf = 1;
  var richtung = 0;
  for (var i = 1; i < r.length; i++) {
    final d = r[i] - r[i - 1];
    if ((d == 1 || d == -1) && (richtung == 0 || richtung == d)) {
      richtung = d;
      lauf++;
      if (lauf >= laenge) return true;
    } else {
      richtung = (d == 1 || d == -1) ? d : 0;
      lauf = (d == 1 || d == -1) ? 2 : 1;
    }
  }
  return false;
}

bool _wiederholung(String kern) {
  if (kern.isEmpty) return false;
  if (kern.runes.toSet().length <= 3) return true; // aaaaaaaaaaaa, abababababab
  // ein kurzer Block, der sich wiederholt (abcabcabcabc)
  for (var b = 1; b <= kern.length ~/ 3; b++) {
    if (kern.length % b != 0) continue;
    final block = kern.substring(0, b);
    if (block * (kern.length ~/ b) == kern) return true;
  }
  return false;
}

/// Prüft ein neues Passwort; leere Liste = in Ordnung. [email] und [anzeigename] sind die Kontodaten der Person.
List<PasswortProblem> passwortPruefen(String passwort, {String? email, String? anzeigename}) {
  final probleme = <PasswortProblem>[];
  final norm = passwortNormalisiert(passwort);
  if (norm.runes.length < kPasswortMindestlaenge) probleme.add(PasswortProblem.zuKurz);
  final klein = _klein(passwort);
  final kern = _kern(klein);

  // Kontodaten: ganze E-Mail, Name davor (ab 4 Zeichen) oder Anzeigename (ab 3 Zeichen, auch Teile des Namens ab 4 Zeichen)
  final kontodaten = <String>[];
  if (email != null && email.trim().isNotEmpty) {
    final e = _klein(email.trim());
    kontodaten.add(_kern(e));
    final lokal = e.split('@').first;
    if (_kern(lokal).length >= 4) kontodaten.add(_kern(lokal));
  }
  if (anzeigename != null && anzeigename.trim().isNotEmpty) {
    final n = _klein(anzeigename.trim());
    if (_kern(n).length >= 3) kontodaten.add(_kern(n));
    for (final teil in n.split(RegExp(r'\s+'))) {
      if (_kern(teil).length >= 4) kontodaten.add(_kern(teil));
    }
  }
  if (kontodaten.any((k) => k.isNotEmpty && kern.contains(k))) probleme.add(PasswortProblem.enthaeltKontodaten);

  // Verbotsliste: das Passwort ist das Wort selbst oder das Wort macht mindestens die Hälfte aus ("passwort123456")
  if (kVerboteneWoerter.any((w) => kern.contains(w) && w.length * 2 >= kern.length)) probleme.add(PasswortProblem.zuHaeufig);

  // Muster: gleiche Zeichen/Blöcke, lange Zahlen- und Buchstabenfolgen
  if (_wiederholung(kern) || _folge(kern.runes.toList(), 6)) probleme.add(PasswortProblem.einfachesMuster);
  return probleme;
}

/// Bits Entropie eines Vorschlags aus [anzahl] gleichverteilt gezogenen Wörtern einer Liste mit [listenGroesse] Einträgen (5 aus 2048 = 55 Bit).
double passwortVorschlagBits(int listenGroesse, {int anzahl = 5}) => anzahl * (log(listenGroesse) / ln2);

/// Vorschlag aus [anzahl] Zufallswörtern der [woerter]-Liste, getrennt mit [trenner]. Gleichverteilt (Ablehnungsverfahren, kein Modulo-Fehler),
/// Zufall nur aus dem [CryptoProvider]. Die Wortliste kommt aus assets/crypto/wortliste.txt (wortliste.dart).
String passwortVorschlag(CryptoProvider crypto, List<String> woerter, {int anzahl = 5, String trenner = '-'}) {
  if (woerter.length < 256 || woerter.length > 65536) throw ArgumentError('Wortliste hat eine unbrauchbare Größe');
  final grenze = 65536 - (65536 % woerter.length);
  final gewaehlt = <String>[];
  while (gewaehlt.length < anzahl) {
    final b = crypto.zufall(2);
    final v = (b[0] << 8) | b[1];
    if (v >= grenze) continue;
    gewaehlt.add(woerter[v % woerter.length]);
  }
  return gewaehlt.join(trenner);
}
