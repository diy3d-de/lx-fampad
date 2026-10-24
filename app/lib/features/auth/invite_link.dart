// Einladungslinks: https://familyhub.lx-labs.dev/#/einladung/<token>. Das Token steht im URL-Fragment (nie im Pfad oder in
// der Query), damit es in keinem Server-, Proxy- oder Caddy-Log landet. Der Client liest es und sendet es nur im POST-Body.
import '../../constants.dart';

final _tokenMuster = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
final _fragmentMuster = RegExp(r'^#?/einladung/([A-Za-z0-9_-]{16,128})/?$');

/// Zieht das Token aus einem Link, einem Fragment (`#/einladung/<token>`) oder einem eingefügten reinen Token.
/// Gibt null zurück bei jeder anderen Form (kein Fragment, Token im Pfad oder in der Query, fremder Host, falsche Zeichen/Länge).
/// [erlaubterHost]: Hat der Link einen Host, muss er dazu passen (Standard: [kInviteHost]); null schaltet die Prüfung ab.
String? parseInviteToken(String eingabe, {String? erlaubterHost = kInviteHost}) {
  final s = eingabe.trim();
  if (s.isEmpty || s.length > 2048) return null;
  if (_tokenMuster.hasMatch(s)) return s; // nur das Token eingefügt

  final hash = s.indexOf('#');
  if (hash < 0) return null; // Token im Pfad/in der Query oder sonst kein Einladungslink: nicht annehmen
  final vorFragment = s.substring(0, hash);
  final fragment = s.substring(hash);
  if (vorFragment.isNotEmpty) {
    final uri = Uri.tryParse(vorFragment);
    if (uri == null) return null;
    if (uri.hasScheme) {
      if (uri.scheme != 'https') return null;
      if (erlaubterHost != null && uri.host.toLowerCase() != erlaubterHost.toLowerCase()) return null;
      if (uri.hasPort && uri.port != 443) return null;
      if (uri.userInfo.isNotEmpty) return null;
    } else {
      return null;
    }
    // Pfad darf nur die Wurzel sein; eine Query ist kein gültiger Einladungslink
    if ((uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery) return null;
  }
  final m = _fragmentMuster.firstMatch(fragment);
  return m?.group(1);
}

/// true, wenn das Fragment wie ein Einladungs-Fragment aussieht (auch mit ungültigem Token): wird dann aus der Adresszeile entfernt.
bool istEinladungsFragment(String fragment) => fragment.startsWith('#/einladung');

/// true, wenn der Link ein Einladungs-Fragment trägt (`…#/einladung…`). Alle anderen Links der Domain (Startseite, Pfade) sind keine Einladung.
bool istEinladungsLink(String link) {
  final hash = link.indexOf('#');
  return hash >= 0 && istEinladungsFragment(link.substring(hash));
}
