// Einstellungen des Tagesbriefings: Schalter für die Startseiten-Kachel (Profil > Startseite und Anzeige) und für die Benachrichtigung am Morgen samt Uhrzeit
// (Profil > Benachrichtigungen, nur Android-App). Alles lokal auf diesem Gerät.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/tagesbriefing/briefing_einstellungen.dart';
import '../../ui/widgets.dart';

const _kleinStil = TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted);

/// Schalter "Tagesbriefing" für die Kachel "Heute im Überblick".
class BriefingKachelZeile extends ConsumerWidget {
  const BriefingKachelZeile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final an = ref.watch(briefingEinstellungenProvider.select((e) => e.kachelAn));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          secondary: const Icon(Icons.today_outlined, color: kAccent, size: 22),
          title: const Text('Tagesbriefing', style: TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Die Kachel „Heute im Überblick“ auf der Startseite, nur auf diesem Gerät', style: _kleinStil),
          value: an,
          onChanged: (v) => unawaited(ref.read(briefingEinstellungenProvider.notifier).kachelSetzen(v)),
        ),
      ),
    );
  }
}

/// "Morgens benachrichtigen" mit Uhrzeit (nur Android-App). Die Benachrichtigung nennt nur Zahlen, nie Titel oder Namen.
class BriefingMorgensZeile extends ConsumerWidget {
  const BriefingMorgensZeile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final einst = ref.watch(briefingEinstellungenProvider);
    final notifier = ref.read(briefingEinstellungenProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              secondary: const Icon(Icons.wb_twilight_outlined, color: kAccent, size: 22),
              title: const Text('Morgens benachrichtigen', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Eine kurze Übersicht des Tages, nur mit Zahlen („Heute: 3 Termine, 2 Aufgaben“), auf diesem Gerät', style: _kleinStil),
              value: einst.morgensAn,
              onChanged: (v) => unawaited(notifier.morgensSetzen(v)),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              enabled: einst.morgensAn,
              minVerticalPadding: 8,
              title: const Text('Uhrzeit', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Ohne Erlaubnis für Benachrichtigungen kommt nichts (Profil › Benachrichtigungen › Erinnerungen)', style: _kleinStil),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(8)),
                child: Text(briefingUhrzeit(einst.minuten), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, color: kTextStrong)),
              ),
              onTap: () async {
                final t = await showTimePicker(
                  context: context,
                  useRootNavigator: false,
                  initialTime: TimeOfDay(hour: einst.minuten ~/ 60, minute: einst.minuten % 60),
                  helpText: 'Uhrzeit des Tagesbriefings',
                );
                if (t != null) unawaited(notifier.zeitSetzen(t.hour * 60 + t.minute));
              },
            ),
          ],
        ),
      ),
    );
  }
}
