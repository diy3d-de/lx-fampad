// "Rückgängig"-Hinweis nach dem Löschen oder Erledigen: ein ruhiger Hinweis unten (SnackBar, ist selbst eine Live-Region) mit einer Handlung.
// Die Handlung läuft immer über die Repositories (also SyncStore.aendern/loeschen), nie am Sync-Kern vorbei. Ein gelöschter Datensatz bleibt auf
// dem Server ein Tombstone: "Rückgängig" legt ihn dann mit neuer ID wieder an (siehe `wiederherstellen` der Repositories).
import 'dart:async';

import 'package:flutter/material.dart';

import '../constants.dart';
import '../data/rueckgaengig_fehler.dart';

export '../data/rueckgaengig_fehler.dart' show RueckgaengigAbgelehnt;

/// Zeit, die der Hinweis steht.
const kRueckgaengigDauer = Duration(seconds: 6);

ScaffoldMessengerState? _offen;

/// Schließt einen noch offenen Rückgängig-Hinweis (Hook für das Leeren der lokalen Daten beim Abmelden und Personenwechsel).
void rueckgaengigSchliessen() {
  final m = _offen;
  _offen = null;
  if (m != null && m.mounted) m.clearSnackBars();
}

/// Zeigt [text] mit dem Knopf "Rückgängig"; ein Tipp ruft [rueckgaengig] einmal auf und schließt den Hinweis. Ein früherer Hinweis wird ersetzt.
/// Der Messenger wird vor dem Aufruf gegriffen, damit der Hinweis auch erscheint, wenn die Zeile gerade verschwindet. Die Handlung darf nichts über den
/// Zustand des Bildschirms lesen (kein `ref.read` des Bildschirms: nach dem Abmelden ist er weg), sondern nur über vorher geholte Werte laufen.
/// Wirft sie [RueckgaengigAbgelehnt], sagt ein zweiter Hinweis den Grund.
void rueckgaengigZeigen(BuildContext context, {required String text, required Future<void> Function() rueckgaengig}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  var benutzt = false;
  _offen = messenger;
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
            unawaited(_ausfuehren(messenger, rueckgaengig));
          },
        ),
      ),
    );
}

Future<void> _ausfuehren(ScaffoldMessengerState messenger, Future<void> Function() rueckgaengig) async {
  String? meldung;
  try {
    await rueckgaengig();
  } on RueckgaengigAbgelehnt catch (e) {
    meldung = e.meldung;
  } catch (_) {
    meldung = 'Rückgängig hat nicht geklappt.';
  }
  if (meldung == null || !messenger.mounted) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(meldung)));
}
