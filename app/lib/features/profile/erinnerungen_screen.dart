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
    if (s == AppLifecycleState.resumed) {
      ref.invalidate(erinnerungStatusProvider);
      ref.invalidate(erinnerungDiagnoseProvider);
    }
  }

  void _hinweis(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Öffnet die Benachrichtigungseinstellungen; scheitert das, steht der Weg als Text da.
  Future<void> _einstellungen({bool alarme = false}) async {
    final port = ref.read(erinnerungPortProvider);
    bool ok;
    try {
      ok = alarme ? await port.alarmEinstellungenOeffnen() : await port.systemEinstellungenOeffnen();
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      _hinweis(
        alarme
            ? 'Die Einstellungen ließen sich nicht öffnen. Öffne die Android-Einstellungen, dort Apps, $kAppName, "Alarme & Erinnerungen".'
            : 'Die Einstellungen ließen sich nicht öffnen. Öffne die Android-Einstellungen, dort Apps, $kAppName, Benachrichtigungen.',
      );
    }
  }

  Future<void> _erlauben() async {
    setState(() => _beschaeftigt = true);
    try {
      await ref.read(erinnerungDienstProvider).berechtigungAnfragen();
    } finally {
      if (mounted) {
        setState(() => _beschaeftigt = false);
        ref.invalidate(erinnerungStatusProvider);
        ref.invalidate(erinnerungDiagnoseProvider);
      }
    }
  }

  Future<void> _test() async {
    final messenger = ScaffoldMessenger.of(context);
    final dienst = ref.read(erinnerungDienstProvider);
    setState(() => _beschaeftigt = true);
    try {
      // Frisch lesen (die Person kann die Erlaubnis in den Einstellungen geändert haben); keine versteckte Anfrage, die einen der zwei
      // Dialoge verbrauchen würde
      ref.invalidate(erinnerungStatusProvider);
      final status = await ref.read(erinnerungStatusProvider.future);
      if (!mounted) return;
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
            MeldungsBox(
              s.unbekannt
                  ? 'Ob Benachrichtigungen für $kAppName erlaubt sind, ließ sich nicht prüfen. Unten steht die Diagnose; du kannst es erneut versuchen '
                        'oder in den Android-Einstellungen nachsehen.'
                  : s.fragbar
                  ? 'Benachrichtigungen sind für $kAppName noch nicht erlaubt. Ohne diese Erlaubnis zeigt Android keine Erinnerungen an.'
                  : 'Benachrichtigungen sind für $kAppName ausgeschaltet, und Android fragt nicht mehr danach. Erlaube sie in den Android-Einstellungen '
                        '(Apps, $kAppName, Benachrichtigungen; auch die Kategorie "Terminerinnerungen" muss an sein). '
                        'Danach kommst du hierher zurück, die App erkennt die Änderung selbst.',
            ),
            const SizedBox(height: 8),
            if (s.fragbar) ...[
              HauptKnopf(text: 'Benachrichtigungen erlauben', icon: Icons.notifications_active_outlined, laeuft: _beschaeftigt, onPressed: _erlauben),
              const SizedBox(height: 4),
              LinkKnopf('Systemeinstellungen öffnen', onPressed: () => unawaited(_einstellungen())),
            ] else
              HauptKnopf(text: 'In den Einstellungen erlauben', icon: Icons.settings_outlined, onPressed: () => unawaited(_einstellungen())),
          ],
          if (s != null && s.erlaubt) ...[
            const SizedBox(height: 12),
            const MeldungsBox('Benachrichtigungen sind erlaubt.', fehler: false),
          ],
          if (s != null && !s.exakt) ...[
            const SizedBox(height: 12),
            const MeldungsBox(
              'Genaue Alarme ("Alarme & Erinnerungen") sind auf diesem Gerät nicht erlaubt. Erinnerungen können dadurch einige Minuten später kommen.',
              fehler: false,
            ),
            LinkKnopf('Alarme & Erinnerungen öffnen', onPressed: () => unawaited(_einstellungen(alarme: true))),
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
          ZweitKnopf(
            text: 'Testbenachrichtigung in 10 Sekunden',
            icon: Icons.notifications_none,
            onPressed: _beschaeftigt || (s != null && !s.erlaubt) ? null : _test,
          ),
          const SizedBox(height: 16),
          const _DiagnoseZeile(),
        ],
      ],
    );
  }
}

/// Kleine Diagnose: nur Zustände (keine Titel oder Inhalte), hilfreich bei der Fehlersuche.
class _DiagnoseZeile extends ConsumerWidget {
  const _DiagnoseZeile();

  static String _kanal(int k) => switch (k) {
    -1 => 'unbekannt',
    0 => 'aus',
    _ => 'an ($k)',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(erinnerungDiagnoseProvider).value;
    if (d == null) return const SizedBox.shrink();
    String ja(bool b) => b ? 'ja' : 'nein';
    return Semantics(
      label: 'Diagnose der Erinnerungen',
      child: Text(
        '// diagnose: erlaubt ${ja(d.erlaubt)} · kanal ${_kanal(d.kanal)} · genaue alarme ${ja(d.exakt)} · plugin ${ja(d.bereit)} · '
        'geplant ${d.geplant < 0 ? '?' : d.geplant}${d.fehler == null ? '' : ' · fehler ${d.fehler}'}',
        key: const Key('erinnerung-diagnose'),
        style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
      ),
    );
  }
}
