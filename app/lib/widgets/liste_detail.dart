// Zweispalter "Liste links, Detail rechts" für Bereiche mit Detailseiten (Aufgaben): wie der Chat ab einer Inhaltsbreite von [kListeDetailBreite], darunter bleibt es
// bei Liste, dann Detail als Vollseite (mobil unverändert). Rechts liegt ein eigener Navigator: Editoren und Detailseiten werden dort geöffnet (nicht über der
// ganzen Shell), `Navigator.of(context).pop()` in ihnen schließt nur die rechte Spalte, und dort aufgerufene Dialoge (`useRootNavigator: false`) und der
// UngespeichertSchutz der Editoren wirken in der rechten Spalte. Ohne geöffnetes Detail zeigt die Spalte den Leerzustand mit einer Handlung.
import 'dart:async';

import 'package:flutter/material.dart';

import '../constants.dart';

/// Ab dieser Breite des Inhaltsbereichs gibt es zwei Spalten.
const kListeDetailBreite = 700.0;

/// Breite der Listenspalte.
const kListeSpaltenBreite = 360.0;

/// Stellt der Liste die rechte Spalte zur Verfügung: Navigator-Schlüssel und die Kennung des geöffneten Eintrags (zum Hervorheben der Zeile).
class DetailSpalte extends InheritedNotifier<ValueNotifier<String?>> {
  final GlobalKey<NavigatorState> navigatorKey;
  const DetailSpalte({super.key, required this.navigatorKey, required ValueNotifier<String?> auswahl, required super.child}) : super(notifier: auswahl);

  static DetailSpalte? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DetailSpalte>();

  /// Kennung des Eintrags, dessen Detail rechts offen ist (null: keines).
  String? get auswahl => notifier?.value;

  /// Öffnet [route] in der rechten Spalte und merkt [id]. Ist dort schon etwas offen, wird es zuerst per `maybePop` geschlossen: ein Editor mit
  /// ungespeicherten Eingaben fragt nach (bei „Verwerfen“ schließt er sich selbst, dann wählt die Person noch einmal).
  Future<void> oeffnen(Route<void> route, {String? id}) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    if (nav.canPop()) {
      await nav.maybePop();
      if (nav.canPop()) return;
    }
    notifier?.value = id;
    await nav.push<void>(route);
  }
}

/// Öffnet [seite] als Detail: im Zweispalter in der rechten Spalte (Zeile [id] hervorgehoben), sonst wie bisher als Seite im Navigator der Umgebung
/// (mobil Vollseite, im Desktop-Layout ohne Zweispalter eine Unterseite des Inhaltsbereichs).
Future<void> detailOeffnen(BuildContext context, WidgetBuilder seite, {String? id}) {
  final spalte = DetailSpalte.maybeOf(context);
  if (spalte != null) return spalte.oeffnen(MaterialPageRoute<void>(builder: seite), id: id);
  return Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: seite));
}

class _Beobachter extends NavigatorObserver {
  final ValueNotifier<String?> auswahl;
  _Beobachter(this.auswahl);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // zurück auf die erste Seite (Leerzustand): nichts mehr ausgewählt
    if (previousRoute?.isFirst ?? false) scheduleMicrotask(() => auswahl.value = null);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isFirst ?? false) scheduleMicrotask(() => auswahl.value = null);
  }
}

/// Zweispalter: [liste] links, rechts ein Navigator mit [leer] als Grundzustand. Unter [kListeDetailBreite] nur die Liste.
class ListeDetail extends StatefulWidget {
  final Widget liste;

  /// Rechte Spalte ohne geöffnetes Detail (Leerzustand mit Handlung).
  final Widget leer;
  const ListeDetail({super.key, required this.liste, required this.leer});

  @override
  State<ListeDetail> createState() => _ListeDetailState();
}

class _ListeDetailState extends State<ListeDetail> {
  final _navKey = GlobalKey<NavigatorState>();
  final _auswahl = ValueNotifier<String?>(null);
  late final _beobachter = _Beobachter(_auswahl);

  @override
  void dispose() {
    _auswahl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (c.maxWidth < kListeDetailBreite) return widget.liste;
      return DetailSpalte(
        navigatorKey: _navKey,
        auswahl: _auswahl,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: kListeSpaltenBreite, child: widget.liste),
            const VerticalDivider(width: 1, color: kBorderSoft),
            Expanded(
              child: Navigator(
                key: _navKey,
                observers: [_beobachter],
                onGenerateRoute: (s) => PageRouteBuilder<void>(settings: s, pageBuilder: (_, _, _) => Material(type: MaterialType.transparency, child: widget.leer), transitionDuration: Duration.zero),
              ),
            ),
          ],
        ),
      );
    },
  );
}
