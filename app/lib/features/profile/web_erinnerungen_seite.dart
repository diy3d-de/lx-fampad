// Profil › Benachrichtigungen › Erinnerungen im Browser (nur Web-App): ein Schalter je Gerät (lokal, Standard aus), der beim Einschalten die Erlaubnis des Browsers
// anfragt (nie beim Start), ehrlich anzeigt, was der Browser erlaubt, und die Grenze nennt: nur solange die Web-App geöffnet ist. Die Schalter je Art gelten gleich.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/erinnerungen/browser_benachrichtigung.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart';
import '../../data/erinnerungen/web_erinnerung_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'erinnerungen_screen.dart' show ErinnerungArtSchalter;

const _klein = TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted);

class WebErinnerungenSeite extends ConsumerStatefulWidget {
  const WebErinnerungenSeite({super.key});

  @override
  ConsumerState<WebErinnerungenSeite> createState() => _WebErinnerungenSeiteState();
}

class _WebErinnerungenSeiteState extends ConsumerState<WebErinnerungenSeite> {
  bool _beschaeftigt = false;

  Future<void> _umschalten(bool an) async {
    setState(() => _beschaeftigt = true);
    try {
      final n = ref.read(webErinnerungAnProvider.notifier);
      if (an) {
        await n.einschalten();
      } else {
        await n.ausschalten();
      }
    } finally {
      if (mounted) setState(() => _beschaeftigt = false);
    }
  }

  Future<void> _erlauben() async {
    setState(() => _beschaeftigt = true);
    try {
      await ref.read(erinnerungDienstProvider).berechtigungAnfragen();
    } finally {
      if (mounted) setState(() => _beschaeftigt = false);
    }
  }

  Future<void> _test() async {
    final ok = await ref.read(erinnerungDienstProvider).testSenden();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(ok ? 'Die Testbenachrichtigung kommt in 10 Sekunden. Lass diese Seite geöffnet.' : 'Die Testbenachrichtigung konnte nicht geplant werden.')));
  }

  @override
  Widget build(BuildContext context) {
    final an = ref.watch(webErinnerungAnProvider);
    final erlaubnis = ref.watch(browserBenachrichtigungProvider).erlaubnis();
    return AuthSeite(
      label: 'Gerät',
      titel: 'Erinnerungen im Browser',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Erinnerungen werden in diesem Browser aus deinen Terminen und Aufgaben berechnet. Es läuft nichts über den Server, und es wird nichts verschickt. '
          'Die Benachrichtigung bleibt immer neutral: Titel, Namen und Orte stehen erst nach dem Öffnen in der App.',
          style: TextStyle(fontSize: 13, color: kTextMuted),
        ),
        const SizedBox(height: 12),
        LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: const Text('Erinnerungen im Browser', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Nur solange die Web-App geöffnet ist. Ist sie zu, kommt keine Erinnerung; verpasste zeigt sie dir beim nächsten Öffnen.', style: _klein),
            value: an,
            onChanged: _beschaeftigt ? null : (v) => unawaited(_umschalten(v)),
          ),
        ),
        if (an) ...[
          const SizedBox(height: 12),
          switch (erlaubnis) {
            BrowserErlaubnis.erlaubt => const MeldungsBox('Der Browser erlaubt Benachrichtigungen für diese Seite.', fehler: false),
            BrowserErlaubnis.offen => const MeldungsBox(
              'Der Browser hat noch nicht um Erlaubnis gefragt oder du hast die Frage geschlossen. Ohne Erlaubnis zeigt $kAppName Erinnerungen nur hier in der App.',
            ),
            BrowserErlaubnis.blockiert => const MeldungsBox(
              'Der Browser blockiert Benachrichtigungen für diese Seite. Erlaube sie in den Website-Einstellungen deines Browsers; bis dahin zeigt $kAppName Erinnerungen nur hier in der App.',
            ),
            BrowserErlaubnis.fehlt => const MeldungsBox('Dieser Browser kann keine Benachrichtigungen zeigen. Erinnerungen erscheinen nur hier in der App.'),
          },
          if (erlaubnis == BrowserErlaubnis.offen) ...[
            const SizedBox(height: 8),
            HauptKnopf(text: 'Benachrichtigungen erlauben', icon: Icons.notifications_active_outlined, laeuft: _beschaeftigt, onPressed: _erlauben),
          ],
          if (erlaubnis == BrowserErlaubnis.erlaubt) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Testbenachrichtigung in 10 Sekunden', icon: Icons.notifications_none, onPressed: _beschaeftigt ? null : _test),
          ],
        ],
        const SizedBox(height: 20),
        const MonoLabel('Was erinnert'),
        const SizedBox(height: 8),
        const ErinnerungArtSchalter(),
        const SizedBox(height: 12),
        const Text('Die Standard-Erinnerung für neue Termine stellst du unter Profil › Kalender ein.', style: TextStyle(fontSize: 12, color: kTextMuted)),
      ],
    );
  }
}
