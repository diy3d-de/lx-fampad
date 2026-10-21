// Rückfrage vor einem frei gewählten Abmelden. Abmelden beendet nur die Sitzung (und leert die zwischengespeicherten Daten): Der Personenschlüssel bleibt im
// Schlüsselspeicher dieses Geräts liegen und wird bei der nächsten Anmeldung derselben Person wieder benutzt. Die Rückfrage ist darum nur ein ruhiger Hinweis,
// keine Warnung; die harte Warnung gehört zu "Gerät abgeben" (Profil > Verschlüsselung), der einzigen Aktion, die den Schlüssel löscht.
// Gilt für "Abmelden", "Überall abmelden" und "Dieses Gerät abmelden"; Zwangsabmeldungen (401, Widerruf) fragen nie.
// Ob ein Schlüssel auf dem Gerät liegt, fragt die App direkt im Schlüsselspeicher; lässt sich das nicht klären, gilt "unbekannt, evtl. vorhanden" und nie "kein Schlüssel".
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/bytes.dart';
import '../../data/crypto/e2ee_state.dart';

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
/// ruhiger Hinweis, dass der Schlüssel hier bleibt.
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
    builder: (ctx) => AlertDialog(
      title: Text(titel),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          if (ueberall) ...[
            const SizedBox(height: 8),
            const Text('Auch deine anderen Geräte werden abgemeldet; sie behalten ihren Schlüssel.', style: TextStyle(color: kTextMuted, height: 1.4)),
          ],
          if (hinweis != null) ...[
            const SizedBox(height: 12),
            Text(hinweis, style: const TextStyle(color: kTextMuted, height: 1.4)),
          ],
          if (istWeb && lage != SchluesselLage.keiner) ...[
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
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), style: _stil(kTextMuted), child: const Text('Abbrechen')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), style: _stil(kAccent), child: Text(knopf)),
      ],
    ),
  );
  return ja == true;
}
