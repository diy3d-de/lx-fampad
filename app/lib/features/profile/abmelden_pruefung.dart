// Rückfrage vor einem frei gewählten Abmelden. Abmelden beendet nur die Sitzung (und leert die zwischengespeicherten Daten): Der Personenschlüssel bleibt im
// Schlüsselspeicher dieses Geräts liegen und wird bei der nächsten Anmeldung derselben Person wieder benutzt. Die Rückfrage ist darum nur ein ruhiger Hinweis,
// keine Warnung; die harte Warnung gehört zu "Gerät abgeben" (Profil > Verschlüsselung), der einzigen Aktion, die den Schlüssel löscht.
// Gilt für "Abmelden", "Überall abmelden" und "Dieses Gerät abmelden"; Zwangsabmeldungen (401, Widerruf) fragen nie.
// Warten noch ungesendete Änderungen im Ausgang (Zähler des Sync-Dienstes, live) oder vom Server abgelehnte, warnt der Dialog mit der Anzahl und bietet "Erst synchronisieren"
// an: Beim Abmelden werden sie mit den lokalen Daten gelöscht (Lücke L-5). Ohne solche Änderungen bleibt es beim ruhigen Hinweis.
// Ob ein Schlüssel auf dem Gerät liegt, fragt die App direkt im Schlüsselspeicher; lässt sich das nicht klären, gilt "unbekannt, evtl. vorhanden" und nie "kein Schlüssel".
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/bytes.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/sync_state.dart';

/// Wie sicher die App weiß, ob auf diesem Gerät ein Personenschlüssel liegt.
enum SchluesselLage { keiner, vorhanden, unbekannt }

/// Fragt den Schlüsselspeicher des Geräts direkt (unabhängig vom Server): "keiner" nur, wenn er lesbar ist und weder den Schlüssel noch einen Zwischenstand
/// eines Schlüsselwechsels enthält; ein Lesefehler ergibt "unbekannt".
Future<SchluesselLage> schluesselLage(WidgetRef ref) async {
  final zustand = ref.read(e2eeProvider).status;
  if (zustand == E2eeStatus.bereit ||
      zustand == E2eeStatus.abweichend ||
      ref.read(e2eeProvider.notifier).lokalerSchluessel != null) {
    return SchluesselLage.vorhanden;
  }
  final id = ref.read(authProvider).user?.id;
  if (id == null) return SchluesselLage.unbekannt;
  try {
    final speicher = ref.read(schluesselSpeicherProvider);
    final haupt = await speicher.lesen(personenschluesselName(id));
    final alt = await speicher.lesen(personenschluesselAltName(id));
    final da = haupt != null || alt != null;
    if (haupt != null) loescheBytes(haupt);
    if (alt != null) loescheBytes(alt);
    return da ? SchluesselLage.vorhanden : SchluesselLage.keiner;
  } on Object {
    return SchluesselLage.unbekannt;
  }
}

ButtonStyle _stil(Color farbe) => TextButton.styleFrom(
  foregroundColor: farbe,
  minimumSize: const Size(48, 48),
);

/// Fragt vor dem Abmelden nach. Gibt true zurück, wenn abgemeldet werden soll. Mit (oder eventuell mit) Schlüssel auf dem Gerät steht im Dialog ein
/// ruhiger Hinweis, dass der Schlüssel hier bleibt. Ungesendete Änderungen (auch vom Server abgelehnte) werden live gezählt und genannt.
Future<bool> abmeldenBestaetigen(
  BuildContext context,
  WidgetRef ref, {
  required String titel,
  required String text,
  required String knopf,
  bool ueberall = false,
  bool? web,
}) async {
  final istWeb = web ?? kIsWeb;
  final lage = await schluesselLage(ref);
  if (!context.mounted) return false;
  final hinweis = switch (lage) {
    SchluesselLage.keiner => null,
    SchluesselLage.vorhanden =>
      'Dein Schlüssel bleibt auf diesem Gerät. Wenn du dich hier wieder anmeldest, sind deine Chats gleich wieder lesbar. '
          'Willst du das Gerät abgeben, nutze Profil › Verschlüsselung › Gerät abgeben.',
    SchluesselLage.unbekannt =>
      'Ein Schlüssel, der auf diesem Gerät liegt, bleibt hier; die App konnte ihn gerade nicht prüfen. '
          'Willst du das Gerät abgeben, nutze Profil › Verschlüsselung › Gerät abgeben.',
  };
  final ja = await showDialog<bool>(
    useRootNavigator: false,
    context: context,
    builder: (ctx) => _AbmeldeDialog(
      titel: titel,
      text: text,
      knopf: knopf,
      ueberall: ueberall,
      hinweis: hinweis,
      computerHinweis: istWeb && lage != SchluesselLage.keiner,
    ),
  );
  return ja == true;
}

class _AbmeldeDialog extends ConsumerStatefulWidget {
  final String titel;
  final String text;
  final String knopf;
  final bool ueberall;
  final String? hinweis;
  final bool computerHinweis;
  const _AbmeldeDialog({
    required this.titel,
    required this.text,
    required this.knopf,
    required this.ueberall,
    required this.hinweis,
    required this.computerHinweis,
  });

  @override
  ConsumerState<_AbmeldeDialog> createState() => _AbmeldeDialogState();
}

class _AbmeldeDialogState extends ConsumerState<_AbmeldeDialog> {
  bool _synchronisiert = false;

  Future<void> _synchronisieren() async {
    final sync = ref.read(syncProvider.notifier);
    setState(() => _synchronisiert = true);
    try {
      await sync.synchronisieren(manuell: true);
    } on Object {
      // der Zähler unten zeigt, was noch offen ist
    }
    if (mounted) setState(() => _synchronisiert = false);
  }

  @override
  Widget build(BuildContext context) {
    // live: der Zähler folgt dem Ausgang (Datenbank), auch während des Abgleichs
    final offen = ref.watch(syncProvider.select((s) => s.offeneAenderungen));
    final fehlerhaft = ref.watch(abgelehnteAenderungenProvider).value ?? 0;
    final verlust = offen > 0 || fehlerhaft > 0;
    return AlertDialog(
      title: Text(widget.titel),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.text),
          if (widget.ueberall) ...[
            const SizedBox(height: 8),
            const Text('Auch deine anderen Geräte werden abgemeldet; sie behalten ihren Schlüssel.', style: TextStyle(color: kTextMuted, height: 1.4)),
          ],
          if (offen > 0) ...[
            const SizedBox(height: 12),
            Text(ungesendetText(offen), style: const TextStyle(color: kWarn, height: 1.4)),
          ],
          if (fehlerhaft > 0) ...[
            const SizedBox(height: 12),
            Text(abgelehntText(fehlerhaft), style: const TextStyle(color: kWarn, height: 1.4)),
          ],
          if (widget.hinweis != null) ...[
            const SizedBox(height: 12),
            Text(widget.hinweis!, style: const TextStyle(color: kTextMuted, height: 1.4)),
          ],
          if (widget.computerHinweis) ...[
            const SizedBox(height: 8),
            const Text(
              'Auf einem gemeinsam genutzten Computer nutze „Gerät abgeben“: Normales Abmelden lässt den Schlüssel im Browser liegen.',
              style: TextStyle(color: kTextMuted, height: 1.4),
            ),
          ],
        ],
      ),
      actionsOverflowButtonSpacing: 12,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), style: _stil(kTextMuted), child: const Text('Abbrechen')),
        if (offen > 0)
          TextButton(
            onPressed: _synchronisiert ? null : _synchronisieren,
            style: _stil(kAccent),
            child: Text(_synchronisiert ? 'Synchronisiere …' : 'Erst synchronisieren'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: _stil(verlust ? kDanger : kAccent),
          child: Text(verlust ? '${widget.knopf} (Änderungen verwerfen)' : widget.knopf, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

/// Warnung vor dem Verlust noch nicht gesendeter Änderungen (Ausgang): Beim ausdrücklichen Abmelden und bei "Gerät abgeben" werden sie mit den lokalen Daten gelöscht.
String ungesendetText(int n) =>
    '${n == 1 ? 'Eine Änderung (z. B. eine Nachricht) wurde' : '$n Änderungen (z. B. Nachrichten) wurden'} noch nicht an den Server gesendet und '
    '${n == 1 ? 'geht' : 'gehen'} beim Abmelden verloren. Verbinde dich mit dem Netz und synchronisiere zuerst.';

/// Vom Server abgelehnte, nie gesendete Änderungen (Fehler an der Nachricht): Auch sie gehen beim Abmelden verloren; ein Abgleich ändert daran nichts.
String abgelehntText(int n) =>
    '${n == 1 ? '1 nicht gesendete Nachricht (Änderung) mit Fehler liegt noch auf diesem Gerät' : '$n nicht gesendete Nachrichten (Änderungen) mit Fehler liegen noch auf diesem Gerät'} '
    '(vom Server abgelehnt) und ${n == 1 ? 'geht' : 'gehen'} beim Abmelden ebenfalls verloren.';
