// Zweispalter "Liste links, Detail rechts" für Bereiche mit Detailseiten (Aufgaben): nur im Desktop-Layout (Marke [DesktopShellMarke], ab 900 px Fensterbreite)
// und dort ab einer Inhaltsbreite von [kListeDetailBreite]; sonst (mobil, Tablet 700 bis 899 px, schmaler Inhalt) bleibt es bei Liste, dann Detail als Vollseite.
// Wird das Fenster schmaler, während rechts ein Detail (Editor) offen ist, bleibt es offen und füllt die ganze Breite (die Liste tritt zurück; nichts geht verloren).
// Zurück (Android, Browser) schließt zuerst das Detail rechts ([NavigatorPopHandler]), erst dann verlässt es den Bereich. Rechts liegt ein eigener Navigator: Editoren und Detailseiten werden dort geöffnet (nicht über der
// ganzen Shell), `Navigator.of(context).pop()` in ihnen schließt nur die rechte Spalte, und dort aufgerufene Dialoge (`useRootNavigator: false`) und der
// UngespeichertSchutz der Editoren wirken in der rechten Spalte. Ohne geöffnetes Detail zeigt die Spalte den Leerzustand mit einer Handlung.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../data/shell/detail_offen_state.dart';
import '../features/shell/desktop_shell.dart' show DesktopShellMarke;

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

  /// Ist rechts ein Detail über dem Leerzustand offen?
  final ValueNotifier<bool> offen;
  _Beobachter(this.auswahl, this.offen);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) scheduleMicrotask(() => offen.value = true);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // zurück auf die erste Seite (Leerzustand): nichts mehr ausgewählt
    if (previousRoute?.isFirst ?? false) {
      scheduleMicrotask(() {
        auswahl.value = null;
        offen.value = false;
      });
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isFirst ?? false) {
      scheduleMicrotask(() {
        auswahl.value = null;
        offen.value = false;
      });
    }
  }
}

/// Zweispalter: [liste] links, rechts ein Navigator mit [leer] als Grundzustand. Unter [kListeDetailBreite] nur die Liste.
class ListeDetail extends ConsumerStatefulWidget {
  final Widget liste;

  /// Rechte Spalte ohne geöffnetes Detail (Leerzustand mit Handlung).
  final Widget leer;
  const ListeDetail({super.key, required this.liste, required this.leer});

  @override
  ConsumerState<ListeDetail> createState() => _ListeDetailState();
}

class _ListeDetailState extends ConsumerState<ListeDetail> {
  final _navKey = GlobalKey<NavigatorState>();
  final _auswahl = ValueNotifier<String?>(null);
  final _offen = ValueNotifier<bool>(false);
  late final _beobachter = _Beobachter(_auswahl, _offen);
  late final ProviderContainer _container = ProviderScope.containerOf(context, listen: false);

  @override
  void initState() {
    super.initState();
    _offen.addListener(_melden);
  }

  // die Shell erfährt, dass rechts ein Detail offen ist (Zurück schließt dann zuerst das Detail)
  void _melden() => Future.microtask(() {
    try {
      _container.read(detailOffenProvider.notifier).setzen(_offen.value);
    } catch (_) {
      // Container schon weg (Fenster zu)
    }
  });

  @override
  void dispose() {
    _offen.removeListener(_melden);
    if (_offen.value) _offen.value = false;
    _melden();
    _auswahl.dispose();
    _offen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Zwei Spalten gibt es nur im Desktop-Layout; mobil und auf dem Tablet (700 bis 899 px) bleibt es bei Liste, dann Detail als Vollseite
    if (!DesktopShellMarke.vorhanden(context)) return widget.liste;
    return LayoutBuilder(
      builder: (context, c) => ValueListenableBuilder<bool>(
        valueListenable: _offen,
        builder: (context, offen, _) {
          final breit = c.maxWidth >= kListeDetailBreite;
          if (!breit && !offen) return widget.liste;
          // der Schlüssel am Navigator hält die offene Seite (und ihre Eingaben) beim Wechsel zwischen den Anordnungen
          final detail = NavigatorPopHandler(
            enabled: offen,
            onPopWithResult: (_) => unawaited(_navKey.currentState?.maybePop()),
            child: Navigator(
              key: _navKey,
              observers: [_beobachter],
              onGenerateRoute: (s) => PageRouteBuilder<void>(settings: s, pageBuilder: (_, _, _) => Material(type: MaterialType.transparency, child: widget.leer), transitionDuration: Duration.zero),
            ),
          );
          return DetailSpalte(
            navigatorKey: _navKey,
            auswahl: _auswahl,
            child: breit
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: kListeSpaltenBreite, child: widget.liste),
                      const VerticalDivider(width: 1, color: kBorderSoft),
                      Expanded(child: detail),
                    ],
                  )
                : detail,
          );
        },
      ),
    );
  }
}
