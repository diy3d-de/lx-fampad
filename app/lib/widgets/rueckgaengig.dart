// "Rückgängig"-Hinweis nach dem Löschen oder Erledigen: ein ruhiger Hinweis unten (SnackBar, ist selbst eine Live-Region) mit einer Handlung.
// Die Handlung läuft immer über die Repositories (also SyncStore.aendern/loeschen), nie am Sync-Kern vorbei. Ein gelöschter Datensatz bleibt auf
// dem Server ein Tombstone: "Rückgängig" legt ihn dann mit neuer ID wieder an (siehe `wiederherstellen` der Repositories).
import 'dart:async';

import 'package:flutter/material.dart';

import '../constants.dart';

/// Zeit, die der Hinweis steht.
const kRueckgaengigDauer = Duration(seconds: 6);

/// Zeigt [text] mit dem Knopf "Rückgängig"; ein Tipp ruft [rueckgaengig] einmal auf und schließt den Hinweis. Ein früherer Hinweis wird ersetzt.
/// Der Messenger wird vor dem Aufruf gegriffen, damit der Hinweis auch erscheint, wenn die Zeile gerade verschwindet.
void rueckgaengigZeigen(BuildContext context, {required String text, required Future<void> Function() rueckgaengig}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  var benutzt = false;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: kRueckgaengigDauer,
        content: Text(text),
        action: SnackBarAction(
          label: 'Rückgängig',
          textColor: kAccent,
          onPressed: () {
            if (benutzt) return;
            benutzt = true;
            unawaited(rueckgaengig());
          },
        ),
      ),
    );
}
