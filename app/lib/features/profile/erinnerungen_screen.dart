// Einstellungen der Terminerinnerungen (nur dieses Gerät): an/aus, Berechtigung, Standard-Vorlaufzeit für neue Termine, Hinweis zum
// Akkuschutz (Samsung u. a.) und eine Testbenachrichtigung. Im Web gibt es keine Erinnerungen, dort steht nur ein Hinweis.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart';
import '../../data/erinnerungen/erinnerung_einstellungen.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../calendar/calendar_state.dart' show erinnerungText;
import '../lists/list_dialogs.dart' show AuswahlKnopf;

class ErinnerungenScreen extends ConsumerStatefulWidget {
  const ErinnerungenScreen({super.key});

  @override
  ConsumerState<ErinnerungenScreen> createState() => _ErinnerungenScreenState();
}

class _ErinnerungenScreenState extends ConsumerState<ErinnerungenScreen> with WidgetsBindingObserver {
  bool _beschaeftigt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Zurück aus den Systemeinstellungen: Berechtigung neu lesen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) ref.invalidate(erinnerungStatusProvider);
  }

  Future<void> _erlauben() async {
    setState(() => _beschaeftigt = true);
    try {
      await ref.read(erinnerungDienstProvider).berechtigungAnfragen();
    } finally {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        ref.invalidate(erinnerungStatusProvider);
      }
    }
  }

  Future<void> _test() async {
    final messenger = ScaffoldMessenger.of(context);
    final dienst = ref.read(erinnerungDienstProvider);
    setState(() => _beschaeftigt = true);
    try {
      var status = await ref.read(erinnerungStatusProvider.future);
      if (!mounted) return;
      if (!status.erlaubt) {
        await dienst.berechtigungAnfragen();
        if (!mounted) return;
        ref.invalidate(erinnerungStatusProvider);
        status = await ref.read(erinnerungStatusProvider.future);
        if (!mounted) return;
      }
      if (!status.erlaubt) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Benachrichtigungen sind nicht erlaubt. Erlaube sie oben oder in den Systemeinstellungen.')));
        return;
      }
      final ok = await dienst.testSenden();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Die Testbenachrichtigung kommt in 10 Sekunden. Du kannst die App jetzt verlassen oder den Bildschirm sperren.'
                  : 'Die Testbenachrichtigung konnte nicht geplant werden.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _beschaeftigt = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(erinnerungStatusProvider);
    final einst = ref.watch(erinnerungEinstellungenProvider);
    final verfuegbar = status.value?.verfuegbar ?? true;
    final laedt = status.isLoading && !status.hasValue;
    final s = status.value;
    return AuthSeite(
      label: '// gerät',
      titel: 'Erinnerungen',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (!verfuegbar && !laedt) ...[
          const MeldungsBox(
            'Erinnerungen gibt es nur in der Android-App. Im Browser zeigt $kAppName keine Benachrichtigungen an.',
            fehler: false,
          ),
        ] else if (laedt) ...[
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
        ] else ...[
          const Text(
            'Erinnerungen werden auf diesem Gerät aus deinen Terminen berechnet. Es läuft nichts über den Server, und es wird nichts verschickt. '
            'Sie gelten für Termine, die du angelegt hast oder bei denen du Teilnehmer bist.',
            style: TextStyle(fontSize: 13, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text('Erinnerungen auf diesem Gerät', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Terminerinnerungen anzeigen', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              value: einst.an,
              onChanged: (v) => unawaited(ref.read(erinnerungEinstellungenProvider.notifier).anSetzen(v)),
            ),
          ),
          const SizedBox(height: 8),
          LxCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: const Text('Titel auf Sperrbildschirm zeigen', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text(
                'aus: gesperrt steht dort nur ein neutraler Hinweis, Titel und Ort erst nach dem Entsperren',
                style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
              ),
              value: einst.sperrbildschirmTitel,
              onChanged: (v) => unawaited(ref.read(erinnerungEinstellungenProvider.notifier).sperrbildschirmSetzen(v)),
            ),
          ),
          if (s != null && !s.erlaubt) ...[
            const SizedBox(height: 12),
            const MeldungsBox('Benachrichtigungen sind für $kAppName noch nicht erlaubt. Ohne diese Erlaubnis zeigt Android keine Erinnerungen an.'),
            const SizedBox(height: 8),
            HauptKnopf(text: 'Benachrichtigungen erlauben', icon: Icons.notifications_active_outlined, laeuft: _beschaeftigt, onPressed: _erlauben),
            const SizedBox(height: 4),
            LinkKnopf('Systemeinstellungen öffnen', onPressed: () => unawaited(ref.read(erinnerungPortProvider).systemEinstellungenOeffnen())),
          ],
          if (s != null && s.erlaubt && !s.exakt) ...[
            const SizedBox(height: 12),
            const MeldungsBox(
              'Genaue Alarme sind auf diesem Gerät nicht erlaubt. Erinnerungen können dadurch einige Minuten später kommen.',
              fehler: false,
            ),
          ],
          const SizedBox(height: 20),
          const MonoLabel('// vorlaufzeit für neue termine'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in kStandardVorlaeufe)
                AuswahlKnopf(
                  text: m == null ? 'Keine' : erinnerungText(m).replaceAll(' vorher', ''),
                  gewaehlt: einst.standardVorlauf == m,
                  onTap: () => unawaited(ref.read(erinnerungEinstellungenProvider.notifier).vorlaufSetzen(m)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Gilt nur als Vorgabe im Termin-Editor und nur auf diesem Gerät. Ganztägige Termine erinnern ab 09:00 Uhr: "1 Tag" bedeutet 09:00 Uhr am Vortag. Bei Terminen mit Uhrzeit heißt "1 Tag": am Vortag zur selben Uhrzeit.',
            style: TextStyle(fontSize: 12, color: kTextMuted),
          ),
          const SizedBox(height: 20),
          const MonoLabel('// pünktlich bleiben'),
          const SizedBox(height: 8),
          const LxCard(
            child: Text(
              'Manche Geräte (zum Beispiel von Samsung) schicken Apps im Hintergrund in den Ruhezustand und verzögern oder verschlucken dann '
              'Erinnerungen. Nimm $kAppName deshalb aus dem Akkuschutz: Einstellungen, Akku, Hintergrundnutzungsgrenzen, bei '
              '"Nie automatisch in Ruhezustand versetzte Apps" $kAppName hinzufügen, und die Funktion zum automatischen Ruhezustand ungenutzter Apps '
              'für $kAppName ausschalten. Die Bezeichnungen unterscheiden sich je nach Gerät und Android-Version.',
              style: TextStyle(fontSize: 13, color: kTextMuted),
            ),
          ),
          const SizedBox(height: 16),
          ZweitKnopf(text: 'Testbenachrichtigung in 10 Sekunden', icon: Icons.notifications_none, onPressed: _beschaeftigt ? null : _test),
        ],
      ],
    );
  }
}
