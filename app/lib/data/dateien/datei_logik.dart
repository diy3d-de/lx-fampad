// Dateiablage (Abschnitt 6n): reine Logik ohne Datenbank und Netz. Namensprüfung wie der Server, Pfad und Brotkrumen, Sortierung, Größenformat, Kontingent-Anzeige, Vorschau-Entscheidung
// nach Medientyp, Medientyp aus den ersten Bytes, Rechte der Oberfläche und die Prüfungen der Invariante (Tiefe, Zyklus, Freigabestufe), die das Repository vor jeder Änderung braucht.
import 'dart:typed_data';

import '../api/models.dart' show Role;
import '../app_database.dart';
import 'datei_modelle.dart';

// ---------------------------------------------------------------------------------------------------- Namen

const int kNameMaxZeichen = 200;
const int kNameMaxBytes = 255;

/// Steuerzeichen (C0, DEL, C1), Zeilen-/Absatztrenner, Zero-Width- und Bidi-Steuerzeichen werden entfernt (wie der Server).
bool _istUnsichtbar(int r) =>
    r <= 0x1f || (r >= 0x7f && r <= 0x9f) || (r >= 0x200b && r <= 0x200f) || (r >= 0x2028 && r <= 0x202e) || (r >= 0x2060 && r <= 0x2064) || (r >= 0x2066 && r <= 0x2069) || r == 0xfeff;

String _ohneUnsichtbare(String s) => String.fromCharCodes(s.runes.where((r) => !_istUnsichtbar(r)));
final RegExp _reserviert = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$', caseSensitive: false);

int _utf8Laenge(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return n;
}

/// Bereinigt einen Namen wie der Server (unsichtbare Zeichen und Bidi-Overrides entfernen, Ränder kürzen); null, wenn er danach nicht zulässig ist: leer, `.`/`..`, enthält `/` oder `\`,
/// endet auf einen Punkt, ist zu lang (200 Zeichen/255 Byte) oder ein von Windows reservierter Name (mit oder ohne Endung). Die Unicode-Normalisierung (NFC) macht der Server.
String? bereinigeName(String roh) {
  if (roh.contains('\u0000')) return null;
  final name = _ohneUnsichtbare(roh).trim();
  if (name.isEmpty || name == '.' || name == '..') return null;
  if (name.contains('/') || name.contains('\\')) return null;
  if (name.endsWith('.')) return null;
  if (name.runes.length > kNameMaxZeichen || _utf8Laenge(name) > kNameMaxBytes) return null;
  final stamm = name.split('.').first.trimRight();
  if (_reserviert.hasMatch(stamm)) return null;
  return name;
}

/// Ein Name, der unter den [vorhanden] Namen (ohne Beachtung der Groß-/Kleinschreibung) noch frei ist: "Foto.jpg", "Foto (2).jpg", "Foto (3).jpg" …
String freierName(String name, Iterable<String> vorhanden) {
  final belegt = {for (final v in vorhanden) v.toLowerCase()};
  if (!belegt.contains(name.toLowerCase())) return name;
  final punkt = name.lastIndexOf('.');
  final stamm = punkt > 0 ? name.substring(0, punkt) : name;
  final endung = punkt > 0 ? name.substring(punkt) : '';
  for (var i = 2; i < 10000; i++) {
    final kandidat = '$stamm ($i)$endung';
    if (!belegt.contains(kandidat.toLowerCase())) return kandidat;
  }
  return name;
}

/// Dateiendung in Kleinbuchstaben ohne Punkt ("" ohne Endung).
String dateiEndung(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 || i == name.length - 1 ? '' : name.substring(i + 1).toLowerCase();
}

// ---------------------------------------------------------------------------------------------------- Pfad und Baum

/// Die Ordner von der obersten Ebene bis [id] (die Brotkrumen; [id] selbst zuletzt). Leer bei `null` und bei einer unvollständigen oder zyklischen Kette (nie eine Endlosschleife).
List<OrdnerZeile> ordnerPfad(Iterable<OrdnerZeile> alle, String? id) {
  final nachId = {for (final o in alle) o.id: o};
  final kette = <OrdnerZeile>[];
  final gesehen = <String>{};
  var aktuell = id;
  while (aktuell != null) {
    final o = nachId[aktuell];
    if (o == null || !gesehen.add(aktuell) || kette.length >= kMaxOrdnerTiefe) return const [];
    kette.add(o);
    aktuell = o.parentId;
  }
  return kette.reversed.toList();
}

/// Anzeigepfad "Ordner / Unterordner" ohne führenden Schrägstrich ("" für die oberste Ebene).
String ordnerPfadText(Iterable<OrdnerZeile> alle, String? id) => ordnerPfad(alle, id).map((o) => o.name).join(' / ');

/// Tiefe eines Ordners (ein Ordner oben hat 1); 0 für `null` (oberste Ebene); -1 bei einer unvollständigen oder zyklischen Kette.
int ordnerTiefe(Iterable<OrdnerZeile> alle, String? id) {
  if (id == null) return 0;
  final p = ordnerPfad(alle, id);
  return p.isEmpty ? -1 : p.length;
}

/// Alle Ordner unterhalb von [id] (nicht [id] selbst), tiefste zuerst und je Ebene zusammen (Nachordnung: Kinder vor ihrem Elternteil). Endet auch bei einem Zyklus.
List<OrdnerZeile> unterordnerVonUnten(Iterable<OrdnerZeile> alle, String id) {
  final kinder = <String?, List<OrdnerZeile>>{};
  for (final o in alle) {
    (kinder[o.parentId] ??= []).add(o);
  }
  final out = <OrdnerZeile>[];
  final besucht = <String>{id};
  void besuche(String eltern) {
    for (final k in kinder[eltern] ?? const <OrdnerZeile>[]) {
      if (!besucht.add(k.id)) continue;
      besuche(k.id);
      out.add(k);
    }
  }

  besuche(id);
  return out;
}

/// Wie viele Ebenen unterhalb des Ordners [id] noch Ordner liegen (0 = keine).
int hoeheUnter(Iterable<OrdnerZeile> alle, String id) {
  final kinder = <String?, List<OrdnerZeile>>{};
  for (final o in alle) {
    (kinder[o.parentId] ??= []).add(o);
  }
  int hoehe(String eltern, Set<String> weg) {
    var h = 0;
    for (final k in kinder[eltern] ?? const <OrdnerZeile>[]) {
      if (weg.contains(k.id)) continue;
      final x = 1 + hoehe(k.id, {...weg, k.id});
      if (x > h) h = x;
    }
    return h;
  }

  return hoehe(id, {id});
}

/// Liegt [kandidat] in [ordnerId] oder unterhalb davon (oder ist es derselbe)? Grundlage der Zyklus-Prüfung beim Verschieben.
bool liegtUnterOderIn(Iterable<OrdnerZeile> alle, String? kandidat, String ordnerId) {
  final nachId = {for (final o in alle) o.id: o};
  final gesehen = <String>{};
  var a = kandidat;
  while (a != null && gesehen.add(a)) {
    if (a == ordnerId) return true;
    a = nachId[a]?.parentId;
  }
  return false;
}

// ---------------------------------------------------------------------------------------------------- Sortierung

enum DateiSortierung { name, geaendert, groesse }

/// Vergleich für Namen: ohne Beachtung der Groß-/Kleinschreibung, Zahlen nach ihrem Wert ("Foto 2" vor "Foto 10").
int namensVergleich(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i);
    final cy = y.codeUnitAt(j);
    final ziffernX = cx >= 48 && cx <= 57;
    final ziffernY = cy >= 48 && cy <= 57;
    if (ziffernX && ziffernY) {
      var ei = i;
      while (ei < x.length && x.codeUnitAt(ei) >= 48 && x.codeUnitAt(ei) <= 57) {
        ei++;
      }
      var ej = j;
      while (ej < y.length && y.codeUnitAt(ej) >= 48 && y.codeUnitAt(ej) <= 57) {
        ej++;
      }
      final zx = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final zy = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (zx.length != zy.length) return zx.length - zy.length;
      final c = zx.compareTo(zy);
      if (c != 0) return c;
      i = ei;
      j = ej;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final c = (x.length - i) - (y.length - j);
  return c != 0 ? c : a.compareTo(b);
}

/// Ordner zuerst (nach Name), dann Dateien in der gewählten Reihenfolge (Name aufsteigend, zuletzt geändert zuerst, größte zuerst).
List<OrdnerZeile> ordnerSortiert(Iterable<OrdnerZeile> ordner) => [...ordner]..sort((a, b) => namensVergleich(a.name, b.name));

List<T> dateienSortiert<T>(Iterable<T> dateien, DateiSortierung wie, {required String Function(T) name, required DateTime Function(T) geaendert, required int Function(T) groesse}) {
  final liste = [...dateien];
  liste.sort((a, b) {
    final c = switch (wie) {
      DateiSortierung.name => namensVergleich(name(a), name(b)),
      DateiSortierung.geaendert => geaendert(b).compareTo(geaendert(a)),
      DateiSortierung.groesse => groesse(b).compareTo(groesse(a)),
    };
    return c != 0 ? c : namensVergleich(name(a), name(b));
  });
  return liste;
}

// ---------------------------------------------------------------------------------------------------- Größe und Kontingent

String _dezimal(double x) {
  final s = (x >= 100 ? x.round().toDouble() : (x * 10).round() / 10).toString();
  final ohneNull = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  return ohneNull.replaceAll('.', ',');
}

/// "0 B", "512 B", "1,5 KB", "12 MB", "2,3 GB" (Basis 1024, Komma als Dezimaltrenner).
String groesseText(int bytes) {
  if (bytes < 1024) return '${bytes < 0 ? 0 : bytes} B';
  const einheiten = ['KB', 'MB', 'GB', 'TB'];
  var wert = bytes / 1024;
  var i = 0;
  while (wert >= 1024 && i < einheiten.length - 1) {
    wert /= 1024;
    i++;
  }
  return '${_dezimal(wert)} ${einheiten[i]}';
}

enum KontingentStufe { ok, knapp, voll }

/// Anzeige des Familienspeichers aus den Zahlen des Servers: Anteil (0 bis 1), Text und Warnstufe (ab 90 Prozent knapp, ab 100 voll).
class KontingentAnzeige {
  final int belegt;
  final int reserviert;
  final int kontingent;
  const KontingentAnzeige({required this.belegt, required this.reserviert, required this.kontingent});

  factory KontingentAnzeige.aus(DateiNutzung n) => KontingentAnzeige(belegt: n.belegtBytes, reserviert: n.reserviertBytes, kontingent: n.kontingentBytes);

  int get genutzt => belegt + reserviert;
  int get frei => kontingent - genutzt < 0 ? 0 : kontingent - genutzt;
  double get anteil => kontingent <= 0 ? 1 : (genutzt / kontingent).clamp(0.0, 1.0);
  KontingentStufe get stufe => anteil >= 1 ? KontingentStufe.voll : (anteil >= 0.9 ? KontingentStufe.knapp : KontingentStufe.ok);
  String get text => '${groesseText(genutzt)} von ${groesseText(kontingent)} belegt';
}

/// Passt eine Datei der Größe [bytes] in die Grenzen? Liefert den Grund oder null. Mit [e2ee] gilt die Grenze für die übertragenen (verschlüsselten) Bytes ([bytes] ist dann schon die Größe
/// mit Overhead). Das Kontingent zählt die Größe der Datei; die Prüfung vorab erspart einen Upload, den der Server ablehnen würde.
DateiFehler? groessePruefen(int bytes, DateiNutzung n, {bool e2ee = false}) {
  if (bytes <= 0) return DateiFehler.leer;
  if (bytes > (e2ee ? n.maxE2eeBytes : n.maxDateiBytes)) return DateiFehler.zuGross;
  if (bytes > n.freiBytes) return DateiFehler.speicherVoll;
  return null;
}

// ---------------------------------------------------------------------------------------------------- Medientyp und Vorschau

enum VorschauArt { bild, pdf, text, video, audio, archiv, sonstige }

/// Art der Datei für Symbol und Vorschau, nach Medientyp, sonst nach Endung.
VorschauArt vorschauArt(String? mime, String name) {
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('image/')) return VorschauArt.bild;
  if (m == 'application/pdf') return VorschauArt.pdf;
  if (m.startsWith('text/')) return VorschauArt.text;
  if (m.startsWith('video/')) return VorschauArt.video;
  if (m.startsWith('audio/')) return VorschauArt.audio;
  if (m == 'application/zip' || m == 'application/gzip' || m == 'application/x-tar') return VorschauArt.archiv;
  return switch (dateiEndung(name)) {
    'png' || 'jpg' || 'jpeg' || 'webp' || 'gif' || 'heic' || 'heif' || 'bmp' => VorschauArt.bild,
    'pdf' => VorschauArt.pdf,
    'txt' || 'md' || 'csv' || 'log' => VorschauArt.text,
    'mp4' || 'mov' || 'mkv' || 'webm' || 'avi' => VorschauArt.video,
    'mp3' || 'wav' || 'flac' || 'ogg' || 'm4a' || 'aac' => VorschauArt.audio,
    'zip' || 'gz' || 'tar' || '7z' || 'rar' => VorschauArt.archiv,
    _ => VorschauArt.sonstige,
  };
}

/// Kann die App aus dieser Datei ein Vorschaubild erzeugen? Nur Bilder, die der Decoder von Android und Browser sicher kann (JPEG, PNG, WebP, nicht animiert/HEIC/GIF/SVG).
bool kannVorschaubild(String? mime) {
  final m = (mime ?? '').toLowerCase();
  return m == 'image/png' || m == 'image/jpeg' || m == 'image/webp';
}

/// Zeigt die Oberfläche das Bild in der Vollansicht? Bilder ja (Auslieferung bleibt Anhang: die App lädt die Bytes und zeigt sie selbst), alles andere nur Herunterladen.
bool zeigtVollbild(String? mime, String name) => vorschauArt(mime, name) == VorschauArt.bild && kannVorschaubild(mime);

/// Medientyp aus den ersten Bytes (wie `sniffMime` des Servers: PNG, JPEG, GIF, WebP, PDF); null, wenn nichts passt. Der Server prüft Bilder und PDF gegen die Magic-Bytes: die App
/// nennt im Upload nur einen Typ, den sie selbst erkannt hat, damit ein falsches Etikett nie zur Ablehnung führt.
String? mimeAusKopf(Uint8List kopf) {
  bool beginnt(List<int> b) {
    if (kopf.length < b.length) return false;
    for (var i = 0; i < b.length; i++) {
      if (kopf[i] != b[i]) return false;
    }
    return true;
  }

  if (beginnt(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'image/png';
  if (beginnt(const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (beginnt(const [0x47, 0x49, 0x46, 0x38]) && kopf.length >= 6 && (kopf[4] == 0x37 || kopf[4] == 0x39) && kopf[5] == 0x61) return 'image/gif';
  if (kopf.length >= 12 && beginnt(const [0x52, 0x49, 0x46, 0x46]) && kopf[8] == 0x57 && kopf[9] == 0x45 && kopf[10] == 0x42 && kopf[11] == 0x50) return 'image/webp';
  if (beginnt(const [0x25, 0x50, 0x44, 0x46, 0x2d])) return 'application/pdf';
  return null;
}

/// Medientyp für den Upload (Modus `server`): bei Bildern und PDF nur, was die ersten Bytes belegen (sonst lässt der Server erkennen); andere Typen nach der Endung (nur Anzeige).
String? mimeFuerUpload(String name, Uint8List kopf) {
  final erkannt = mimeAusKopf(kopf);
  if (erkannt != null) return erkannt;
  return switch (dateiEndung(name)) {
    'txt' || 'log' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'zip' => 'application/zip',
    'mp4' => 'video/mp4',
    'mp3' => 'audio/mpeg',
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => null, // Bilder und PDF ohne passende Magic-Bytes bleiben ohne Typ (der Server entscheidet)
  };
}

// ---------------------------------------------------------------------------------------------------- Rechte der Oberfläche

/// Rechte der Oberfläche, nur nach der Rolle der Sitzung (nie nach Familienrolle oder Betreiber-Flag; der Server erzwingt dieselben Regeln): Eltern und Admins alles; Kinder sehen und legen
/// nur Einträge der Stufe `family` an und ändern/löschen nur ihre eigenen (die Stufe ändern sie nie).
class DateiRechte {
  final Role rolle;
  final String? ich;
  const DateiRechte({required this.rolle, required this.ich});

  bool get erwachsen => rolle == Role.admin || rolle == Role.parent;

  /// Sieht die Person einen Eintrag dieser Stufe?
  bool darfSehen(String audience) => erwachsen || audience == kStufeFamilie;

  /// Stufen, die die Person beim Anlegen wählen darf.
  List<String> get stufenZumAnlegen => erwachsen ? const [kStufeFamilie, kStufeEltern] : const [kStufeFamilie];

  bool darfAnlegen(String audience) => stufenZumAnlegen.contains(audience);

  bool _eigen(String? besitzer) => besitzer != null && besitzer == ich;

  /// Umbenennen und Verschieben: Eltern alles, Kinder nur Eigenes.
  bool darfAendern(String? besitzer) => erwachsen || _eigen(besitzer);

  bool darfLoeschen(String? besitzer) => erwachsen || _eigen(besitzer);

  /// Eine neue Fassung legt ein Kind nur für eigene Dateien an.
  bool darfFassungHochladen(String? besitzer) => erwachsen || _eigen(besitzer);

  /// Die Freigabestufe ändern nur Eltern und Admins.
  bool get darfStufeAendern => erwachsen;

  /// Darf der Zielordner Ziel eines Eintrags mit dieser Stufe sein (für diese Person sichtbar, bei Stufe `family` selbst `family`)? `null` = oberste Ebene ist immer zulässig.
  bool darfZielOrdner(OrdnerZeile? ziel, String audienceDesEintrags) {
    if (ziel == null) return true;
    if (!darfSehen(ziel.audience)) return false;
    return audienceDesEintrags != kStufeFamilie || ziel.audience == kStufeFamilie;
  }
}
