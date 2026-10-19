// Benachrichtigungen (nur Android): Push an/aus für dieses Gerät, Status, Test-Wecker und die Anleitung für die ntfy-App.
// Push enthält nie Inhalte: der Server weckt nur, die App gleicht dann ab und zeigt selbst eine Benachrichtigung.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/push/push_plattform.dart';
import '../../data/push/push_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';

/// Adresse des selbst gehosteten ntfy-Servers (steht auch in docs und deploy/README.md).
const kNtfyServerUrl = 'https://ntfy.familie.lx-labs.dev';

class PushScreen extends ConsumerStatefulWidget {
  const PushScreen({super.key});

  @override
  ConsumerState<PushScreen> createState() => _PushScreenState();
}

class _PushScreenState extends ConsumerState<PushScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(pushProvider.notifier).laden());
    });
  }

  Future<void> _waehlen(List<String> liste) async {
    final gewaehlt = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: kSurface,
        title: const Text('Verteiler wählen'),
        children: [
          for (final v in liste)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(v),
              child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: Align(alignment: Alignment.centerLeft, child: Text(verteilerName(v)))),
            ),
        ],
      ),
    );
    if (gewaehlt != null && mounted) await ref.read(pushProvider.notifier).verteilerWaehlen(gewaehlt);
  }

  @override
  Widget build(BuildContext context) {
    final z = ref.watch(pushProvider);
    final c = ref.read(pushProvider.notifier);
    // Mehrere Verteiler: die Person soll wählen (einmalig nach dem Einschalten)
    if (z.auswahl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(pushProvider).auswahl.isNotEmpty) {
          final liste = ref.read(pushProvider).auswahl;
          ref.read(pushProvider.notifier).auswahlAbgeholt();
          unawaited(_waehlen(liste));
        }
      });
    }
    final bereit = z.gewuenscht && z.angemeldet;
    return AuthSeite(
      label: '// push',
      titel: 'Benachrichtigungen',
      maxBreite: kMaxContentWidth,
      kinder: [
        if (!z.unterstuetzt)
          const MeldungsBox('Benachrichtigungen per Push gibt es nur in der Android-App.', fehler: false)
        else ...[
          LxCard(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Auf diesem Gerät benachrichtigen', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text(
                          'Du wirst geweckt, wenn es Neues gibt. Der Inhalt bleibt auf dem Server.',
                          style: const TextStyle(fontSize: 12, color: kTextMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    label: 'Benachrichtigungen auf diesem Gerät',
                    toggled: z.gewuenscht,
                    child: Switch(
                      value: z.gewuenscht,
                      onChanged: z.beschaeftigt || !z.geladen ? null : (an) => unawaited(an ? c.einschalten() : c.ausschalten()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (z.fehler != null) ...[const SizedBox(height: 12), MeldungsBox(z.fehler!)],
          if (z.verteilerFehlt) ...[
            const SizedBox(height: 12),
            const MeldungsBox('Es ist keine ntfy-App installiert. Installiere sie (Anleitung unten) und schalte Benachrichtigungen dann erneut ein.'),
          ],
          if (!z.serverBereit) ...[
            const SizedBox(height: 12),
            const MeldungsBox('Der Server hat Push noch nicht eingerichtet. Frage den Admin der Familie.', fehler: false),
          ],
          const SizedBox(height: 20),
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          LxCard(
            child: Column(
              children: [
                _StatusZeile('Verteiler (ntfy-App)', z.verteiler != null ? verteilerName(z.verteiler!) : 'nicht gewählt', z.verteiler != null),
                _StatusZeile('Server bereit', z.serverBereit ? 'ja' : 'nein', z.serverBereit),
                _StatusZeile('Dieses Gerät angemeldet', z.angemeldet ? 'ja' : (z.gewuenscht ? 'wird angemeldet …' : 'aus'), z.angemeldet),
                _StatusZeile(
                  'Letzter Wecker',
                  z.letzterWecker == null ? 'noch keiner' : DateFormat('dd.MM. HH:mm', 'de_DE').format(z.letzterWecker!),
                  z.letzterWecker != null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ZweitKnopf(
            text: 'Test-Wecker senden',
            icon: Icons.notifications_active_outlined,
            onPressed: bereit && z.test != PushTest.laeuft && !z.beschaeftigt ? () => unawaited(c.testen()) : null,
          ),
          if (z.test != null) ...[const SizedBox(height: 8), _TestAnzeige(z.test!)],
        ],
        const SizedBox(height: 20),
        const MonoLabel('// einrichtung'),
        const SizedBox(height: 8),
        const LxCard(child: _Anleitung()),
      ],
    );
  }
}

class _StatusZeile extends StatelessWidget {
  final String titel;
  final String wert;
  final bool gut;
  const _StatusZeile(this.titel, this.wert, this.gut);

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 36),
    child: Row(
      children: [
        Icon(gut ? Icons.check_circle_outline : Icons.radio_button_unchecked, size: 18, color: gut ? kTerminal : kTextMuted),
        const SizedBox(width: 10),
        Expanded(child: Text(titel, style: const TextStyle(fontSize: 14))),
        const SizedBox(width: 8),
        Flexible(child: Text(wert, textAlign: TextAlign.right, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted))),
      ],
    ),
  );
}

class _TestAnzeige extends StatelessWidget {
  final PushTest test;
  const _TestAnzeige(this.test);

  @override
  Widget build(BuildContext context) => switch (test) {
    PushTest.laeuft => const MeldungsBox('Der Server sendet den Wecker … warte kurz.', fehler: false),
    PushTest.angekommen => const MeldungsBox(
      'Der Test-Wecker ist angekommen. Push funktioniert auf diesem Gerät.\n(Hinweis: Das heißt nur, dass etwas angekommen ist; ob es von deinem Server kam, zeigt der Test nicht.)',
      fehler: false,
    ),
    PushTest.nichtAngekommen => const MeldungsBox(
      'Der Server hat den Wecker gesendet, aber hier ist nichts angekommen. Prüfe die ntfy-App (Server, Benutzer) und die Akku-Einstellungen unten.',
    ),
    // die genaue Meldung steht schon oben (fehler)
    PushTest.serverFehler => const SizedBox.shrink(),
  };
}

class _Anleitung extends StatelessWidget {
  const _Anleitung();

  static const _schritte = <String>[
    '1. Installiere die ntfy-App (F-Droid, Google Play oder GitHub-Release). Sie überträgt die Wecker; Google-Dienste sind nicht beteiligt.',
    '2. Öffne die ntfy-App, dann Einstellungen, Standardserver: $kNtfyServerUrl (nicht ntfy.sh!).',
    '3. Melde dich dort mit dem Familien-Zugang an (Benutzer und Passwort bekommst du vom Admin der Familie).',
    '4. Schalte oben die Benachrichtigungen ein. Der Test-Wecker zeigt, ob alles ankommt.',
    'Akku: Erlaube der ntfy-App und lx-fampad unbegrenzten Akku-Betrieb. Samsung: Einstellungen, Akku, Hintergrundnutzungsbegrenzungen, "Nie schlafende Apps" (beide Apps eintragen) und "Automatische Sperre" für ntfy abschalten.',
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final s in _schritte) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s, style: const TextStyle(fontSize: 13, height: 1.4))),
      const Text(
        'Datenschutz: Die Wecker enthalten keinen Text, keinen Titel und keine Namen. Der ntfy-Server läuft selbst gehostet auf dem Familien-Server.',
        style: TextStyle(fontSize: 12, color: kTextMuted, height: 1.4),
      ),
    ],
  );
}
