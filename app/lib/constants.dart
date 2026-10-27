// Design-Tokens und Konstanten. Farben und Schriften wie lx-labs.dev bzw. lx-urlaubsplanung
// (docs/PROJEKTBESCHREIBUNG.md, Abschnitt "Design"). Keine Farbwerte in Widgets: neue Farben nur hier.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const kBg = Color(0xFF090A0F);
const kBgElevated = Color(0xFF0E1017);
const kSurface = Color(0xFF13161F);
const kSurface2 = Color(0xFF1A1E29);
const kSurfaceHover = Color(0xFF212634);
const kBorder = Color(0xFF242936);
const kBorderSoft = Color(0xFF1B1F2B);
const kText = Color(0xFFE6E8EE);
const kTextMuted = Color(0xFF8B93A7);
const kTextFaint = Color(0xFF5D6578);
const kAccent = Color(0xFF6FCFD6); // gedämpftes Türkis (vorher Neon-Cyan 0xFF00F0FF)
const kAccentStrong = Color(0xFF93DDE2);
const kNeural = Color(0xFF7C3AED);
const kTerminal = Color(0xFF4FC99A); // Erfolg / online
const kWarn = Color(0xFFFEBC2E);
const kDanger = Color(0xFFFF5F57);
const kOnAccent = Color(0xFF0C1B1D);
const kTextStrong = Color(0xFFFFFFFF); // Überschriften
const kFeiertag = Color(0xFFFFB86B); // Feiertage im Kalender (dezent, nicht synchronisiert)
const kFerien = Color(0xFF60A5FA); // Schulferien im Kalender
const kGeburtstag = Color(0xFFD946EF); // Geburtstage (Fuchsia; bewusst nicht Pink #f472b6 = Personenfarbe 6 der personPalette)
const kWetterRegen = Color(0xFF6366F1); // Regenbalken im Wetter-Verlauf (Indigo)
const kWetterKalt = Color(0xFF38BDF8); // Tiefpunkt/fallend im Wetter-Verlauf (Hellblau)
/// Amtliche DWD-Warnstufen: 1 gelb (`kWarn`), 2 orange, 3 rot (`kDanger`), 4 violett (nie nur Farbe: die Stufe steht immer im Text).
const kWarnOrange = Color(0xFFFB923C);
const kWarnViolett = Color(0xFFC084FC);

/// Abfallarten (Müll-Kachel, Seite, Kalenderanzeige): je Art eine feste Farbe, nie als Hex im Widget.
const kMuellRest = Color(0xFF9AA3B8); // Restabfall (Grau-Blau)
const kMuellBio = Color(0xFF34D399); // Bioabfall (Grün)
const kMuellGelb = Color(0xFFFEBC2E); // Gelber Sack
const kMuellPapier = Color(0xFF60A5FA); // Altpapier (Blau)
const kMuellGruen = Color(0xFFA3E635); // Grünabfall (Gelbgrün)
const kMuellSonder = Color(0xFFFF5F57); // Sonderabfall (Rot)
const kMuellSperr = Color(0xFFA78BFA); // Sperrmüll (Violett)
const kMuellBaum = Color(0xFF2DD4BF); // Weihnachtsbäume (Türkis)
const kMuellSonst = Color(0xFF8B93A7); // alles Unbekannte ("Sonstiges")

/// Zählerarten (Zähler-Kacheln, Verlauf): je Art eine feste Farbe, nie als Hex im Widget. Strom nutzt `kWarn`.
const kZaehlerKalt = Color(0xFF38BDF8); // Kaltwasser (Blau)
const kZaehlerWarm = Color(0xFFFB7185); // Warmwasser (Rosé)
const kZaehlerGas = Color(0xFFFB923C); // Gas (Orange)
const kZaehlerWaerme = Color(0xFFA78BFA); // Wärmemenge (Violett)
const kZaehlerSolar = Color(0xFFA3E635); // Erzeugung/Solar (Gelbgrün)
const kZaehlerEigen = Color(0xFF8B93A7); // eigener Zähler (Grau)

/// Stärke des Hintergrund-Schimmers oben (wie lx-urlaubsplanung): Violett links, Cyan rechts.
const kGlowNeuralAlpha = 0.30;
const kGlowAccentAlpha = 0.09;

/// Breite, bis zu der der Inhalt wächst (Desktop/Tablet); darüber wird er zentriert (wie die Anmeldung).
const kMaxContentWidth = 720.0;

/// Weicher Akzent (12 % Deckkraft) für Flächen und den Navigations-Indikator.
final kAccentSoft = kAccent.withValues(alpha: 0.12);

const kFontSans = 'Inter';
/// Mono nur noch für echte Codes (Sicherheitscode, Schlüssel, Wiederherstellungs- und Einladungscodes, Seriennummern, Links).
const kFontMono = 'JetBrainsMono';

/// Ziffern gleicher Breite (Uhrzeiten, Kennzahlen, Messwerte) in Inter statt Mono.
const kZiffern = <FontFeature>[FontFeature.tabularFigures()];

/// Personenfarben, je Familienmitglied fest (Kalender, Chat, Karte, Listen einheitlich).
const personPalette = <Color>[
  Color(0xFF38BDF8),
  Color(0xFF34D399),
  Color(0xFFFBBF24),
  Color(0xFFFB7185),
  Color(0xFFA78BFA),
  Color(0xFFF472B6),
  Color(0xFFA3E635),
  Color(0xFFFB923C),
  Color(0xFF2DD4BF),
  Color(0xFF818CF8),
];

/// Rufdienst (Termin-Farbe Nr. 11): kräftiges Alarmrot, bewusst anders als die rosé Personenfarbe 0xFFFB7185 und als `kDanger`.
const kTerminFarbeRufdienst = Color(0xFFE5322D);

/// Termin-Farben: je Termin optional EINE von 11 Farben mit festem Namen (Index 0 bis 10, wird als `farbe` synchronisiert).
/// Die ersten zehn sind genau die Werte von [personPalette], die elfte ist Rufdienst. Nie Namen oder Farben ändern oder umsortieren (Index = Wert am Server).
const kTerminFarben = <({String name, Color farbe})>[
  (name: 'Familie', farbe: Color(0xFF38BDF8)),
  (name: 'Schule', farbe: Color(0xFF34D399)),
  (name: 'Arbeit', farbe: Color(0xFFFBBF24)),
  (name: 'Arzt', farbe: Color(0xFFFB7185)),
  (name: 'Sport', farbe: Color(0xFFA78BFA)),
  (name: 'Freizeit', farbe: Color(0xFFF472B6)),
  (name: 'Haushalt', farbe: Color(0xFFA3E635)),
  (name: 'Urlaub', farbe: Color(0xFFFB923C)),
  (name: 'Besuch', farbe: Color(0xFF2DD4BF)),
  (name: 'Sonstiges', farbe: Color(0xFF818CF8)),
  (name: 'Rufdienst', farbe: kTerminFarbeRufdienst),
];

Color personColor(int index) => personPalette[index % personPalette.length];

String personInitials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
}

/// Basisadresse des Servers. Im Web leer (gleiche Domain, Caddy leitet /api und /ws weiter);
/// für die Android-App beim Build setzen: --dart-define=API_BASE=https://familyhub.lx-labs.dev
const kApiBase = String.fromEnvironment('API_BASE', defaultValue: '');

/// Basisadresse des Update-Kanals (Manifest und APK liegen unter /releases/android/).
const kReleasesBase = String.fromEnvironment('RELEASES_BASE', defaultValue: 'https://familyhub.lx-labs.dev/releases');

/// Kennung des Web-Builds, gesetzt von deploy-web.sh (--dart-define=WEB_VERSION=...). Der Server meldet die
/// aktuelle Kennung in /api/v1/version (webVersion); weicht sie ab, erscheint "Neue Version - neu laden".
const kWebVersion = String.fromEnvironment('WEB_VERSION', defaultValue: '');

/// Obergrenze für die Größe einer Update-APK (Manifest und Download).
const kMaxApkBytes = 60 * 1024 * 1024;

/// Protokollversion, die diese App spricht (Server: PROTOCOL_VERSION). Ist sie kleiner als die Mindestversion
/// des Servers (minProtocolVersion), ist ein Update Pflicht.
const kProtocolVersion = 1;

/// Paketname der App; das signierte Update-Manifest muss genau diesen Namen tragen.
/// Anzeigename der App in allen sichtbaren Texten (Paketname, Kanäle, Dienst- und Pfadnamen bleiben lx-fampad/fampad).
const kAppName = 'lx-familyhub';

const kPackageName = 'dev.lx_labs.fampad';

/// Stabiler Download-Link der Android-App (Alias auf die neueste APK, wird beim Release-Upload angelegt). Enthält nie ein Token.
const kApkDownloadUrl = 'https://familyhub.lx-labs.dev/releases/android/lx-familyhub-latest.apk';

/// Öffentlicher Ed25519-Schlüssel des Update-Kanals (32 Byte, Base64), erzeugt am 19.10.2026. Der private
/// Schlüssel liegt nur als CI-Secret UPDATE_SIGNING_KEY und in der Sicherung des Betreibers, nie im Repo.
const kUpdatePublicKey = 'kXAm22X6wnuxrYe/KEdukPD5r+pN4HpQHmUzDX3VoeM=';

/// Kennung des Schlüssels (keyId im signierten Manifest); beim Schlüsselwechsel hochzählen.
const kUpdateKeyId = 'fampad-1';

/// Kennung des Platzhalter-Schlüssels. Solange [kUpdateKeyId] diesen Wert hat, lehnt die App jedes Update-Manifest hart ab
/// (auch ein Manifest, das jemand mit dem Platzhalter-Schlüssel oder einer Schlüssel-ID "platzhalter" signiert).
const kPlatzhalterKeyId = 'platzhalter';

/// Prüft die Basisadressen: Außerhalb des Debug-Modus nur HTTPS (das `assert` allein würde im Release entfallen).
/// Im Android-Release muss API_BASE gesetzt sein (ohne sie gäbe es keinen Server; im Web ist sie bewusst leer).
/// Wirft [StateError] bei Klartext-Adressen oder fehlender Adresse. [debug] und [android] sind für Tests überschreibbar.
void pruefeBasisAdressen({bool? debug, bool? android, String api = kApiBase, String releases = kReleasesBase}) {
  if (debug ?? kDebugMode) return;
  final istAndroid = android ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  if (istAndroid && api.isEmpty) throw StateError('API_BASE fehlt: Android-Release mit --dart-define=API_BASE=https://… bauen');
  if (api.isNotEmpty && !api.startsWith('https://')) throw StateError('API_BASE muss mit https:// beginnen');
  if (!releases.startsWith('https://')) throw StateError('RELEASES_BASE muss mit https:// beginnen');
}

/// Methodenkanal zu MainActivity.kt (Version abfragen, APK installieren).
const kUpdateChannel = 'dev.lx_labs.fampad/update';

/// Methodenkanal zu MainActivity.kt für Gerätename, Bildschirmfoto-Schutz und Einladungs-Links.
const kSystemChannel = 'dev.lx_labs.fampad/system';

/// Host der Einladungslinks (`https://<host>/#/einladung/<token>`). Beim Build mit --dart-define=INVITE_HOST=… setzen (Standard:
/// familyhub.lx-labs.dev). Er gehört zur selben Domain wie API_BASE; in AndroidManifest.xml (Intent-Filter) und MainActivity.kt steht
/// dieselbe Domain (deploy/README.md, Abschnitt 9).
const kInviteHost = String.fromEnvironment('INVITE_HOST', defaultValue: 'familyhub.lx-labs.dev');

/// Kennzeile unter der Anmeldung ("host · verschlüsselt"): Host aus API_BASE (Android) bzw. der Adresse der Seite (Web); die
/// TLS-Angabe nur bei https. Parameter für Tests überschreibbar.
String serverKennzeile({String api = kApiBase, Uri? seite, bool? web}) {
  var host = '';
  var https = false;
  final u = api.isEmpty ? null : Uri.tryParse(api);
  if (u != null && u.host.isNotEmpty) {
    host = u.host;
    https = u.scheme == 'https';
  } else if (web ?? kIsWeb) {
    final s = seite ?? Uri.base;
    host = s.host;
    https = s.scheme == 'https';
  }
  if (host.isEmpty) {
    host = kInviteHost;
    https = true;
  }
  return https ? '$host · verschlüsselt' : host;
}

/// Navigationsziele (Reihenfolge = Reihenfolge in der NavigationBar).
class NavTab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const NavTab(this.label, this.icon, this.selectedIcon);
}

const kTabs = <NavTab>[
  NavTab('Start', Icons.home_outlined, Icons.home),
  NavTab('Kalender', Icons.calendar_month_outlined, Icons.calendar_month),
  NavTab('Chat', Icons.chat_bubble_outline, Icons.chat_bubble),
  NavTab('Dateien', Icons.folder_outlined, Icons.folder),
  NavTab('Listen', Icons.checklist_outlined, Icons.checklist),
  NavTab('Aufgaben', Icons.task_alt_outlined, Icons.task_alt),
];

/// Seitenleiste im Desktop-Layout: die Tabs der Navigationsleiste plus Standort und Wetter (mobil ist Standort eine Seite, die von der Startseite aus geöffnet wird).
const kDesktopTabs = <NavTab>[
  ...kTabs,
  NavTab('Standort', Icons.location_on_outlined, Icons.location_on),
  NavTab('Wetter', Icons.wb_sunny_outlined, Icons.wb_sunny),
  NavTab('Müll', Icons.delete_outline, Icons.delete),
  NavTab('Medikamente', Icons.medication_outlined, Icons.medication),
  NavTab('Zähler', Icons.speed_outlined, Icons.speed),
  NavTab('Tresor', Icons.lock_outline, Icons.lock),
  NavTab('Vorsorge', Icons.vaccines_outlined, Icons.vaccines),
];

/// Ab dieser Fensterbreite zeigt die App das Desktop-Layout (Seitenleiste, Karten-Raster); darunter bleibt es mobil.
const kDesktopBreakpoint = 900.0;

/// Inhaltsbreite der Startseite im Desktop-Layout (die übrigen Bereiche bleiben bei [kMaxContentWidth]).
const kMaxContentWidthDesktop = 1200.0;

/// Breite der Seitenleiste im Desktop-Layout.
const kSidebarWidth = 248.0;
