// Rückfrage vor einem frei gewählten Abmelden: Wer einen Personenschlüssel auf diesem Gerät hat, erfährt vorher ehrlich, dass er hier gelöscht wird
// und was danach bleibt. Gilt für "Abmelden", "Überall abmelden" und "Dieses Gerät abmelden"; Zwangsabmeldungen (401, Widerruf) fragen nie.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/crypto/e2ee_state.dart';
import 'pw_sicherung_screen.dart';
import 'verschluesselung_screen.dart';

/// Liegt auf diesem Gerät ein Personenschlüssel? (Zustand "bereit"/"abweichend" oder der Schlüssel ist geladen; ohne E2EE: nein.)
bool hatPersonenschluesselAufGeraet(WidgetRef ref) {
  final s = ref.read(e2eeProvider);
  return s.status == E2eeStatus.bereit ||
      s.status == E2eeStatus.abweichend ||
      ref.read(e2eeProvider.notifier).lokalerSchluessel != null;
}

/// Gibt es eine auf diesem Gerät vollständig bestätigte, noch gültige Passwort-Sicherung (Vermerk vorhanden, Server bietet sie an, nicht veraltet)?
bool hatBestaetigtePwSicherung(E2eeState s) =>
    s.pwSicherungVerfuegbar &&
    s.pwSicherungVersion != null &&
    s.pwSicherungVersion == s.serverSchluessel?.version &&
    !s.pwSicherungVeraltet;

/// Fragt vor dem Abmelden nach. Gibt true zurück, wenn abgemeldet werden soll. Ohne Personenschlüssel auf dem Gerät zeigt [ohneSchluessel] die bisherige
/// einfache Rückfrage. "Passwort-Sicherung anlegen" / "Erst sichern" öffnet den Ablauf und meldet nicht ab (false).
Future<bool> abmeldenBestaetigen(
  BuildContext context,
  WidgetRef ref, {
  required String titel,
  required String text,
  required String knopf,
  required Future<bool> Function() ohneSchluessel,
}) async {
  if (!hatPersonenschluesselAufGeraet(ref)) return ohneSchluessel();
  final s = ref.read(e2eeProvider);
  final pwOk = hatBestaetigtePwSicherung(s);
  // Ohne Passwort-Sicherung des Servers bleibt nur der Wiederherstellungsschlüssel: ist er gesichert (hatSicherung), genügt der ruhige Hinweis
  final warnen = !pwOk && (s.pwSicherungVerfuegbar || !s.hatSicherung);
  final antwort = await showDialog<String>(
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
          const SizedBox(height: 12),
          Text(
            pwOk
                ? 'Beim Abmelden wird dein Schlüssel von diesem Gerät gelöscht. Danach kommst du wieder an deine Chats mit deinem Passwort der Passwort-Sicherung, '
                      'mit einem anderen Gerät, das deinen Schlüssel hat, oder mit deinem Wiederherstellungsschlüssel, aber nur, wenn du ihn noch hast.'
                : 'Beim Abmelden wird dein Schlüssel von diesem Gerät gelöscht. Danach kommst du nur mit einem anderen Gerät, das deinen Schlüssel hat, '
                      'oder mit deinem Wiederherstellungsschlüssel wieder an deine Chats, aber nur, wenn du ihn noch hast.',
            style: const TextStyle(color: kTextMuted, height: 1.4),
          ),
          if (warnen) ...[
            const SizedBox(height: 12),
            Text(
              s.pwSicherungVerfuegbar
                  ? 'Du hast keine bestätigte Passwort-Sicherung. Lege sie vorher an: Profil › Verschlüsselung.'
                  : 'Dein Schlüssel ist nicht gesichert. Sichere ihn vorher: Profil › Verschlüsselung.',
              style: const TextStyle(color: kDanger, height: 1.4),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('abbrechen'),
          child: const Text('Abbrechen'),
        ),
        if (warnen)
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('sichern'),
            child: Text(
              s.pwSicherungVerfuegbar
                  ? 'Passwort-Sicherung anlegen'
                  : 'Erst sichern',
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('ja'),
          style: TextButton.styleFrom(foregroundColor: kDanger),
          child: Text(warnen ? 'Trotzdem abmelden' : knopf),
        ),
      ],
    ),
  );
  if (antwort == 'sichern' && context.mounted) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => s.pwSicherungVerfuegbar
            ? const PwSicherungScreen()
            : const VerschluesselungScreen(),
      ),
    );
    return false;
  }
  return antwort == 'ja';
}
