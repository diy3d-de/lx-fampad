// Profil > Benachrichtigungen > Wetter-Hinweise: je Hinweis (Frost, Regen, Wind, Hitze, Druckabfall) ein Schalter, lokal auf diesem Gerät. Die Seite sagt
// ehrlich, wie die Hinweise entstehen: die App prüft beim Abruf die Messwerte der eigenen Station, es gibt keinen Hintergrunddienst und keinen Push.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/wetter_hinweise.dart';
import '../../data/wetter/wetter_logik.dart' show WetterHinweisArt;
import '../../data/wetter/wetter_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';

class WetterHinweiseScreen extends ConsumerWidget {
  const WetterHinweiseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final einst = ref.watch(wetterHinweisEinstellungenProvider);
    final verfuegbar = ref.watch(wetterProvider.select((s) => s.dto?.verfuegbar ?? true));
    return AuthSeite(
      label: '// profil · benachrichtigungen',
      titel: 'Wetter-Hinweise',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Die App prüft die Messwerte der eigenen Station und zeigt lokal einen Hinweis. Es wird nichts an einen Server gemeldet.',
          style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
        ),
        const SizedBox(height: 8),
        Text(
          kIsWeb
              ? 'Im Browser erscheint nur die gelbe Karte auf der Startseite, solange die Seite offen ist; Benachrichtigungen gibt es in der Android-App.'
              : 'Ohne geöffnete App kommt kein Hinweis: die App prüft nur, solange sie läuft. Es gibt keinen Hintergrunddienst und keinen Push. Je Hinweis höchstens eine Benachrichtigung in 6 Stunden. Erlaubnis für Benachrichtigungen: Profil › Benachrichtigungen › Erinnerungen.',
          style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
        ),
        if (!verfuegbar) ...[
          const SizedBox(height: 12),
          const MeldungsBox('Das Wetter ist auf dem Server nicht eingeschaltet. Hinweise gibt es erst, wenn es eingerichtet ist.', fehler: false),
        ],
        const SizedBox(height: 16),
        const MonoLabel('// hinweise'),
        const SizedBox(height: 8),
        for (final art in WetterHinweisArt.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LxCard(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(art.titel, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(art.erklaerung, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                value: einst.an.contains(art),
                onChanged: einst.geladen ? (v) => unawaited(ref.read(wetterHinweisEinstellungenProvider.notifier).setzen(art, v)) : null,
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          'Auf der Startseite erscheint eine gelbe Karte, solange ein eingeschalteter Wert auffällt; sie verschwindet, wenn er sich normalisiert hat. Ein veralteter oder offline gespeicherter Stand löst nie einen Hinweis aus.',
          style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
        ),
      ],
    );
  }
}
