// Dienst für das Android-Widget "Heute": baut aus den lokalen Daten die Anzeige-Zusammenfassung und gibt sie dem Port (app-privater Speicher auf der
// Kotlin-Seite). Nur Änderungen am Inhalt werden geschrieben (der Zeitstempel zählt nicht), gebündelt in einem kurzen Entprell-Takt, damit der Abgleich
// mit dem Server das Widget nicht im Sekundentakt aktualisiert. Abmelden und Personenwechsel löschen die Zusammenfassung (lokaleDatenWiper).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_database.dart';
import '../auth/auth_state.dart';
import '../calendar/termin_repository.dart';
import '../lists/list_repository.dart';
import '../tasks/aufgabe_repository.dart' show aufgabenProvider;
import 'heute_widget_einstellungen.dart';
import 'heute_widget_port.dart';
import 'heute_zusammenfassung.dart';

class HeuteWidgetDienst {
  final Ref _ref;
  final HeuteWidgetPort port;
  final Duration entprellung;
  final DateTime Function() _jetzt;
  Timer? _timer;
  String? _zuletzt; // Inhalt (ohne Zeitstempel) der zuletzt geschriebenen Zusammenfassung
  bool _beschaeftigt = false;
  bool _nochmal = false;

  HeuteWidgetDienst(this._ref, this.port, {this.entprellung = const Duration(seconds: 2), DateTime Function()? jetzt}) : _jetzt = jetzt ?? DateTime.now;

  /// Löst den Abgleich gebündelt aus.
  void entprellt() {
    if (!port.verfuegbar) return;
    _timer?.cancel();
    _timer = Timer(entprellung, () => unawaited(abgleichen()));
  }

  /// Baut die Zusammenfassung und schreibt sie, wenn sie sich geändert hat. Angemeldet: schreiben; abgemeldet: löschen; sonst (Start, Warten,
  /// Verbindungsfehler) nichts verändern.
  Future<void> abgleichen() async {
    if (!port.verfuegbar) return;
    if (_beschaeftigt) {
      _nochmal = true;
      return;
    }
    _beschaeftigt = true;
    try {
      do {
        _nochmal = false;
        final status = _ref.read(authProvider).status;
        if (status == AuthStatus.abgemeldet) {
          await loeschen();
          continue;
        }
        if (status != AuthStatus.angemeldet) continue;
        final einst = _ref.read(heuteWidgetEinstellungenProvider);
        final listen = _ref.read(listenProvider).value ?? const <Liste>[];
        final eintraege = _ref.read(alleEintraegeProvider).value ?? const <Listeneintrag>[];
        final liste = einst.liste == null ? null : listen.where((l) => l.id == einst.liste).firstOrNull;
        final json = heuteZusammenfassung(
          kalender: _ref.read(kalenderDatenProvider),
          aufgaben: _ref.read(aufgabenProvider).value ?? const <Aufgabe>[],
          jetzt: _jetzt(),
          titelAnzeigen: einst.titel,
          einkaufListe: liste?.name,
          einkaufEintraege: liste == null ? const [] : [for (final e in eintraege) if (e.listId == liste.id && e.doneAt == null) e],
        );
        final inhalt = ohneStand(json);
        if (inhalt == _zuletzt) continue;
        if (await port.schreiben(json)) _zuletzt = inhalt;
      } while (_nochmal);
    } catch (_) {
      // das Widget ist eine Zusatzanzeige: ein Fehler hier darf nie die App stören
    } finally {
      _beschaeftigt = false;
    }
  }

  /// Löscht die Zusammenfassung (Abmelden, anderes Konto, lokale Daten leeren).
  Future<void> loeschen() async {
    _timer?.cancel();
    _zuletzt = null;
    try {
      await port.loeschen();
    } catch (_) {
      // nichts weiter zu tun
    }
  }

  void beenden() => _timer?.cancel();
}

final heuteWidgetDienstProvider = Provider<HeuteWidgetDienst>((ref) {
  final dienst = HeuteWidgetDienst(ref, ref.watch(heuteWidgetPortProvider));
  ref.onDispose(dienst.beenden);
  return dienst;
});
