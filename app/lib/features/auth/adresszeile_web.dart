import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'invite_link.dart';

/// Ergebnis beim Lesen der Adresszeile: `null` = kein Einladungslink; sonst das Token (oder `token == null` bei ungültiger Form).
typedef AdresszeilenLink = ({String? token});

/// Liest ein Einladungs-Fragment und entfernt es sofort aus der Adresszeile (auch bei ungültigem Token).
AdresszeilenLink? einladungAusAdresszeileNehmen() {
  final loc = web.window.location;
  final hash = loc.hash;
  if (!istEinladungsFragment(hash)) return null;
  final token = parseInviteToken(hash, erlaubterHost: null);
  // Den vorhandenen History-Zustand mitgeben: Flutter hält darin seinen Verlaufszähler (sonst gerät die Zurück-Taste durcheinander)
  web.window.history.replaceState(web.window.history.state, '', '${loc.pathname}${loc.search}');
  return (token: token);
}

/// Wird ein Einladungslink in einen schon offenen Tab eingefügt (Fragment-Navigation im selben Dokument), wird er hier gelesen und
/// ebenfalls sofort aus der Adresszeile entfernt.
///
/// Gehört zu popstate UND hashchange: Flutters Web-Engine reagiert auf popstate und löst dabei selbst history.go(-1) aus. Dieser
/// Sprung ist asynchron, deshalb sieht ein popstate-Listener das Fragment noch sicher; bei hashchange könnte es schon weg sein
/// (dann ginge der Link verloren). Wer zuerst kommt, entfernt das Fragment; der zweite findet keins mehr.
void aufEinladungInAdresszeileHoeren(void Function(AdresszeilenLink link) beiLink) {
  final listener = ((web.Event _) {
    final l = einladungAusAdresszeileNehmen();
    if (l != null) beiLink(l);
  }).toJS;
  web.window.addEventListener('popstate', listener);
  web.window.addEventListener('hashchange', listener);
}
