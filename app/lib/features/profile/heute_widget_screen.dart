// Einstellungen des Startbildschirm-Widgets "Heute" (nur Android, nur dieses Gerät): Titel zeigen, Liste (z. B. Einkauf) und Hinweis zum Hinzufügen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/heute_widget/heute_widget_einstellungen.dart';
import '../../data/heute_widget/heute_widget_port.dart';
import '../../data/lists/list_repository.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;

class HeuteWidgetScreen extends ConsumerWidget {
  const HeuteWidgetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final einst = ref.watch(heuteWidgetEinstellungenProvider);
    final verfuegbar = ref.watch(heuteWidgetPortProvider).verfuegbar;
    final listen = ref.watch(listenProvider).value ?? const <Liste>[];
    final notifier = ref.read(heuteWidgetEinstellungenProvider.notifier);
    return AuthSeite(
      label: '// gerät',
      titel: 'Widget „Heute“',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (!verfuegbar)
          const MeldungsBox('Das Widget gibt es nur in der Android-App.', fehler: false)
        else ...[
          const Text(
            'Das Widget zeigt auf dem Startbildschirm deine heutigen Termine, fällige Aufgaben und auf Wunsch eine Liste. Es liest nur eine kleine Zusammenfassung, '
            'die die App auf diesem Gerät ablegt (nur für diese App lesbar); es läuft nichts über den Server. Beim Abmelden wird sie gelöscht.',
            style: TextStyle(fontSize: 13, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text('Titel im Widget zeigen', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                'aus: das Widget zeigt nur Uhrzeiten und neutrale Wörter („Termin“, „Aufgabe“), z. B. wenn der Startbildschirm für andere sichtbar ist',
                style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
              ),
              value: einst.titel,
              onChanged: (v) => unawaited(notifier.titelSetzen(v)),
            ),
          ),
          const SizedBox(height: 16),
          const MonoLabel('Liste im Widget'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AuswahlKnopf(text: 'Keine', gewaehlt: einst.liste == null, onTap: () => unawaited(notifier.listeSetzen(null))),
              for (final l in listen) AuswahlKnopf(text: l.name, gewaehlt: einst.liste == l.id, onTap: () => unawaited(notifier.listeSetzen(l.id))),
            ],
          ),
          const SizedBox(height: 16),
          const MeldungsBox(
            'So fügst du das Widget hinzu: Startbildschirm lange drücken, „Widgets“, „$kAppName“, „Heute“. Tippen auf die Termine öffnet den Kalender, '
            'auf die Aufgaben die Aufgaben, auf die Liste die Liste.',
            fehler: false,
          ),
        ],
      ],
    );
  }
}
