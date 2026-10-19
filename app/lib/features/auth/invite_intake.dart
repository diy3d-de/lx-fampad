import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ein eingegangener Einladungslink (Adresszeile im Web, Intent/Scan in der App), noch nicht verarbeitet.
/// [token] ist null, wenn der Link zwar wie ein Einladungslink aussah, aber ungültig war.
class EingehenderLink {
  final String? token;
  final int nr;
  const EingehenderLink(this.token, this.nr);
}

/// Nimmt Einladungslinks entgegen, bis die Oberfläche sie verarbeitet hat (Token liegt nur im Arbeitsspeicher).
class InviteIntake extends Notifier<EingehenderLink?> {
  final String? _anfang;
  final bool _anfangVorhanden;
  int _zaehler = 0;

  /// [anfang]: Link, mit dem der Start erfolgte (im Web schon aus der Adresszeile entfernt).
  InviteIntake({bool vorhanden = false, this._anfang}) : _anfangVorhanden = vorhanden;

  @override
  EingehenderLink? build() => _anfangVorhanden ? EingehenderLink(_anfang, ++_zaehler) : null;

  String? _letztesToken;
  DateTime _letzteZeit = DateTime.fromMillisecondsSinceEpoch(0);

  /// Meldet einen eingegangenen Link. Derselbe Link kurz hintereinander (Adresszeile und Routenmeldung des Browsers melden
  /// dasselbe Einfügen) zählt nur einmal.
  void eingegangen(String? token) {
    final jetzt = DateTime.now();
    final fenster = Duration(seconds: token == null ? 1 : 5);
    if (_letzteZeit.millisecondsSinceEpoch > 0 && token == _letztesToken && jetzt.difference(_letzteZeit) < fenster) return;
    _letztesToken = token;
    _letzteZeit = jetzt;
    state = EingehenderLink(token, ++_zaehler);
  }

  void verbraucht() => state = null;
}

final inviteIntakeProvider = NotifierProvider<InviteIntake, EingehenderLink?>(InviteIntake.new);
