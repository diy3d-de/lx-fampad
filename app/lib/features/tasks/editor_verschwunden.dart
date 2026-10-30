// Der Editor einer Aufgabe oder Frist schließt sich, wenn sein Datensatz verschwindet (hier gelöscht oder von einem anderen Gerät): sonst bliebe im Zweispalter
// (und als Seite) ein Editor für etwas stehen, das es nicht mehr gibt. Nur wenn die Route gerade oben liegt, nie zusätzlich explizit poppen, wenn der Editor
// selbst gerade löscht ([selbstBeendet]) oder schon geschlossen ist. Ungespeicherte Eingaben schützt weiter `UngespeichertSchutz` (Rückfrage statt stillem Verwerfen).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/tasks/aufgabe_repository.dart' show aufgabenProvider;

mixin EditorSchliesstBeiLoeschung<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  var _geplant = false;

  /// Der Editor löscht oder speichert gerade selbst und schließt sich danach selbst.
  bool selbstBeendet = false;

  /// In `build` aufrufen; [id] null = neuer Datensatz (nichts zu prüfen).
  void pruefeVerschwunden(String? id) {
    if (id == null) return;
    final aufgaben = ref.watch(aufgabenProvider);
    if (selbstBeendet || _geplant || !aufgaben.hasValue || aufgaben.requireValue.any((a) => a.id == id)) return;
    _geplant = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || selbstBeendet) return;
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        unawaited(Navigator.of(context).maybePop());
      } else {
        _geplant = false; // gerade liegt etwas darüber (z. B. ein Dialog): beim nächsten Bauen noch einmal
      }
    });
  }
}
