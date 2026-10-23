// Profil > Startseite und Anzeige > Wandtablet-Modus: Einstellungen (lokal je Gerät) und "Jetzt starten".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/lists/list_repository.dart';
import '../../data/wandtablet/wandtablet_einstellungen.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'wandtablet_steuerung.dart';

class WandtabletEinstellungenScreen extends ConsumerWidget {
  const WandtabletEinstellungenScreen({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const WandtabletEinstellungenScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(wandtabletEinstellungenProvider);
    final n = ref.read(wandtabletEinstellungenProvider.notifier);
    final listen = (ref.watch(listenProvider).value ?? const <Liste>[]);
    // eine gewählte Liste, die es nicht mehr gibt, gilt als "keine"
    final gewaehlt = listen.any((l) => l.id == e.liste) ? e.liste : null;
    return AuthSeite(
      label: '// anzeige',
      titel: 'Wandtablet-Modus',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Eine Vollbild-Anzeige für ein Tablet an der Wand: Uhr, Termine heute und morgen, fällige Aufgaben, Müll, Wetter, Countdowns und Fristen. '
          'Nur Anzeige, nichts davon ist bedienbar. Chat, Standort und Schlüssel erscheinen nie. Beenden: die Uhr gedrückt halten.',
          style: TextStyle(color: kTextMuted, height: 1.4),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: () => unawaited(wandtabletStarten(context)),
            icon: const Icon(Icons.tv_outlined),
            label: const Text('Jetzt starten'),
          ),
        ),
        const SizedBox(height: 16),
        const MonoLabel('// dieses gerät'),
        const SizedBox(height: 8),
        _Schalter(
          icon: Icons.play_circle_outline,
          titel: 'Beim Start der App automatisch starten',
          untertitel: 'nach der anmeldung, nur auf diesem gerät',
          wert: e.autostart,
          onChanged: (v) => unawaited(n.autostartSetzen(v)),
        ),
        _Schalter(
          icon: Icons.bedtime_outlined,
          titel: 'Nachts dimmen',
          untertitel: '22 bis 6 uhr abgedunkelt, schont den bildschirm',
          wert: e.dimmen,
          onChanged: (v) => unawaited(n.dimmenSetzen(v)),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.shopping_basket_outlined, color: kAccent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String?>(
                    isExpanded: true,
                    value: gewaehlt,
                    underline: const SizedBox.shrink(),
                    dropdownColor: kSurface,
                    hint: const Text('Einkaufsliste anzeigen'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Keine Liste anzeigen')),
                      for (final l in listen) DropdownMenuItem<String?>(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => unawaited(n.listeSetzen(v)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Tipp: Lege für das Tablet ein eigenes Familienmitglied an (Rolle Kind oder Eltern, je nachdem, was die Wand zeigen soll). '
          'Die Anzeige folgt den Rechten der angemeldeten Person; einen Chat-Schlüssel braucht das Tablet nicht.',
          style: TextStyle(color: kTextMuted, fontSize: 13, height: 1.4),
        ),
      ],
    );
  }
}

class _Schalter extends StatelessWidget {
  final IconData icon;
  final String titel;
  final String untertitel;
  final bool wert;
  final ValueChanged<bool> onChanged;
  const _Schalter({required this.icon, required this.titel, required this.untertitel, required this.wert, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: LxCard(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        secondary: Icon(icon, color: kAccent, size: 22),
        title: Text(titel, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(untertitel, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
        value: wert,
        onChanged: onChanged,
      ),
    ),
  );
}
