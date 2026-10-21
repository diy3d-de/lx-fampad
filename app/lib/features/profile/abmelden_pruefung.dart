// Rückfrage vor einem frei gewählten Abmelden: Wer einen Personenschlüssel auf diesem Gerät hat, erfährt vorher ehrlich, dass er hier gelöscht wird
// und was danach bleibt. Gilt für "Abmelden", "Überall abmelden" und "Dieses Gerät abmelden"; Zwangsabmeldungen (401, Widerruf) fragen nie.
// Der Stand wird vorher frisch geladen; lässt er sich nicht klären (Schlüsselspeicher nicht lesbar, noch nicht geladen), gilt "unbekannt, evtl. vorhanden"
// und nie "kein Schlüssel".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/bytes.dart';
import '../../data/crypto/e2ee_state.dart';
import 'pw_sicherung_screen.dart';
import 'verschluesselung_screen.dart';

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

/// Gibt es eine auf diesem Gerät vollständig bestätigte, noch gültige Passwort-Sicherung (Vermerk vorhanden, Server bietet sie an, nicht veraltet)?
bool hatBestaetigtePwSicherung(E2eeState s) =>
    s.pwSicherungVerfuegbar &&
    s.pwSicherungVersion != null &&
    s.pwSicherungVersion == s.serverSchluessel?.version &&
    !s.pwSicherungVeraltet;

ButtonStyle _stil(Color farbe) => TextButton.styleFrom(
  foregroundColor: farbe,
  minimumSize: const Size(48, 48),
);

/// Fragt vor dem Abmelden nach. Gibt true zurück, wenn abgemeldet werden soll. Ohne Personenschlüssel auf dem Gerät zeigt [ohneSchluessel] die bisherige
/// einfache Rückfrage. "Passwort-Sicherung anlegen" / "Erst sichern" öffnet den Ablauf und meldet nicht ab (false).
Future<bool> abmeldenBestaetigen(
  BuildContext context,
  WidgetRef ref, {
  required String titel,
  required String text,
  required String knopf,
  required Future<bool> Function() ohneSchluessel,
  bool ueberall = false,
}) async {
  // zuerst der Schlüsselspeicher selbst: ohne Schlüssel (und lesbar) keine neue Rückfrage, auch wenn der Server nicht erreichbar ist
  if (await schluesselLage(ref) == SchluesselLage.keiner) {
    return ohneSchluessel();
  }
  if (!context.mounted) return false;
  // frischer Stand der Sicherung (auch wenn schon geladen); Zeitlimit und Fehler ergeben "unbekannt"/"unklar", nie "kein Schlüssel"
  try {
    await ref
        .read(e2eeProvider.notifier)
        .laden()
        .timeout(const Duration(seconds: 3));
  } on Object {
    // der Stand bleibt, wie er ist
  }
  if (!context.mounted) return false;
  final lage = await schluesselLage(ref);
  if (lage == SchluesselLage.keiner) return ohneSchluessel();
  if (!context.mounted) return false;
  final s = ref.read(e2eeProvider);
  final unbekannt = lage == SchluesselLage.unbekannt;
  // Server nicht erreichbar, Schlüssel aber lokal da: ob er gesichert ist, weiß die App gerade nicht
  final sicherungUnklar = !unbekannt && s.status == E2eeStatus.nichtVerfuegbar;
  final pwOk = !unbekannt && !sicherungUnklar && hatBestaetigtePwSicherung(s);
  // Ohne Passwort-Sicherung des Servers bleibt nur der Wiederherstellungsschlüssel: ist er gesichert (hatSicherung), genügt der ruhige Hinweis
  final warnen =
      !unbekannt &&
      !sicherungUnklar &&
      !pwOk &&
      (s.pwSicherungVerfuegbar || !s.hatSicherung);
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
          if (unbekannt)
            const Text(
              'Ob auf diesem Gerät ein Schlüssel liegt, ließ sich gerade nicht prüfen. Beim Abmelden wird er gelöscht, falls einer da ist.',
              style: TextStyle(color: kDanger, height: 1.4),
            )
          else ...[
            Text(
              pwOk
                  ? 'Beim Abmelden wird dein Schlüssel von diesem Gerät gelöscht. Danach kommst du wieder an deine Chats mit deinem Passwort der Passwort-Sicherung, '
                        'mit einem anderen Gerät, das deinen Schlüssel hat, oder mit deinem Wiederherstellungsschlüssel, aber nur, wenn du ihn noch hast.'
                  : 'Beim Abmelden wird dein Schlüssel von diesem Gerät gelöscht. Danach kommst du nur mit einem anderen Gerät, das deinen Schlüssel hat, '
                        'oder mit deinem Wiederherstellungsschlüssel wieder an deine Chats, aber nur, wenn du ihn noch hast.',
              style: const TextStyle(color: kTextMuted, height: 1.4),
            ),
            if (ueberall) ...[
              const SizedBox(height: 8),
              const Text(
                'Auch deine anderen Geräte werden abgemeldet; sie behalten den Schlüssel, solange du dich dort nicht selbst abmeldest oder die App-Daten löschst.',
                style: TextStyle(color: kTextMuted, height: 1.4),
              ),
            ],
            if (sicherungUnklar) ...[
              const SizedBox(height: 12),
              const Text(
                'Ob dein Schlüssel gesichert ist, ließ sich gerade nicht prüfen.',
                style: TextStyle(color: kTextMuted, height: 1.4),
              ),
            ],
            if (warnen) ...[
              const SizedBox(height: 12),
              Text(
                s.pwSicherungVerfuegbar
                    ? 'Auf diesem Gerät ist keine bestätigte Passwort-Sicherung vermerkt (vielleicht hast du sie auf einem anderen Gerät bestätigt). Lege sie sonst vorher an: Profil › Verschlüsselung.'
                    : 'Dein Schlüssel ist nicht gesichert. Sichere ihn vorher: Profil › Verschlüsselung.',
                style: const TextStyle(color: kDanger, height: 1.4),
              ),
            ],
          ],
        ],
      ),
      actionsOverflowButtonSpacing: 12,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('abbrechen'),
          style: _stil(kTextMuted),
          child: const Text('Abbrechen'),
        ),
        if (warnen)
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('sichern'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            child: Text(
              s.pwSicherungVerfuegbar
                  ? 'Passwort-Sicherung anlegen'
                  : 'Erst sichern',
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton(
            onPressed: () => Navigator.of(ctx).pop('ja'),
            style: _stil(kDanger),
            child: Text(
              warnen || unbekannt || sicherungUnklar
                  ? 'Trotzdem abmelden'
                  : knopf,
            ),
          ),
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
