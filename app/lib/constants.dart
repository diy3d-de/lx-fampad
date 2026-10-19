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
const kAccent = Color(0xFF00F0FF); // Cyber Cyan
const kAccentStrong = Color(0xFF5CF6FF);
const kNeural = Color(0xFF7C3AED);
const kTerminal = Color(0xFF10B981); // Erfolg / online
const kWarn = Color(0xFFFEBC2E);
const kDanger = Color(0xFFFF5F57);
const kOnAccent = Color(0xFF04121B);
const kTextStrong = Color(0xFFFFFFFF); // Überschriften

/// Stärke des Hintergrund-Schimmers oben (wie lx-urlaubsplanung): Violett links, Cyan rechts.
const kGlowNeuralAlpha = 0.30;
const kGlowAccentAlpha = 0.09;

/// Breite, bis zu der der Inhalt wächst (Desktop/Tablet); darüber wird er zentriert (wie die Anmeldung).
const kMaxContentWidth = 720.0;

/// Weicher Akzent (rgba(0,240,255,0.12)) für Flächen und den Navigations-Indikator.
final kAccentSoft = kAccent.withValues(alpha: 0.12);

const kFontSans = 'Inter';
const kFontMono = 'JetBrainsMono';

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

Color personColor(int index) => personPalette[index % personPalette.length];

String personInitials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
}

/// Basisadresse des Servers. Im Web leer (gleiche Domain, Caddy leitet /api und /ws weiter);
/// für die Android-App beim Build setzen: --dart-define=API_BASE=https://familie.lx-labs.dev
const kApiBase = String.fromEnvironment('API_BASE', defaultValue: '');

/// Basisadresse des Update-Kanals (Manifest und APK liegen unter /releases/android/).
const kReleasesBase = String.fromEnvironment('RELEASES_BASE', defaultValue: 'https://familie.lx-labs.dev/releases');

/// Kennung des Web-Builds, gesetzt von deploy-web.sh (--dart-define=WEB_VERSION=...). Der Server meldet die
/// aktuelle Kennung in /api/v1/version (webVersion); weicht sie ab, erscheint "Neue Version - neu laden".
const kWebVersion = String.fromEnvironment('WEB_VERSION', defaultValue: '');

/// Obergrenze für die Größe einer Update-APK (Manifest und Download).
const kMaxApkBytes = 200 * 1024 * 1024;

/// Protokollversion, die diese App spricht (Server: PROTOCOL_VERSION). Ist sie kleiner als die Mindestversion
/// des Servers (minProtocolVersion), ist ein Update Pflicht.
const kProtocolVersion = 1;

/// Paketname der App; das signierte Update-Manifest muss genau diesen Namen tragen.
const kPackageName = 'dev.lx_labs.fampad';

/// Öffentlicher Ed25519-Schlüssel des Update-Kanals (32 Byte, Base64). PLATZHALTER: Der zugehörige private
/// Schlüssel existiert nicht, daher wird kein Manifest akzeptiert. Vor dem ersten Release durch den echten
/// Schlüssel ersetzen, siehe tools/README.md ("Update-Schlüssel erzeugen"). Der private Schlüssel gehört nie ins Repo.
const kUpdatePublicKey = 't0zasQh0NHzkm8Xk7o4+StCnrNd1+ewgY9U4EmlhF18=';

/// Kennung des Schlüssels (keyId im signierten Manifest); beim Schlüsselwechsel hochzählen.
const kUpdateKeyId = kPlatzhalterKeyId;

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
/// familie.lx-labs.dev). Er gehört zur selben Domain wie API_BASE; in AndroidManifest.xml (Intent-Filter) und MainActivity.kt steht
/// dieselbe Domain (deploy/README.md, Abschnitt 9).
const kInviteHost = String.fromEnvironment('INVITE_HOST', defaultValue: 'familie.lx-labs.dev');

/// Kennzeile unter der Anmeldung ("● host · tls 1.3"): Host aus API_BASE (Android) bzw. der Adresse der Seite (Web); die
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
  return '● $host${https ? ' · tls 1.3' : ''}';
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
];
