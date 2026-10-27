// Familien-Status (Abschnitt 6o): Startseiten-Kachel "Status" (die Stati der Familie und "Mein Status setzen") und das Blatt zum Setzen. Alles in der Oberfläche rechnet nur
// über data/status/status_logik.dart; ist der Schalter "Familien-Status anzeigen" aus, wird nichts gezeichnet. Der Status steht nie in Wandtablet, Widget "Heute", Suche oder Push.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show UserDto;
import '../../data/auth/auth_state.dart';
import '../../data/lists/members.dart' show mitgliederProvider;
import '../../data/status/status_logik.dart';
import '../../data/status/status_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../lists/list_dialogs.dart' show AuswahlKnopf;

const _kleinStil = TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted);

/// Die Kachel "Status" (mobile und Desktop-Startseite). Bei ausgeschaltetem Schalter oder ohne Anmeldung wird nichts gezeichnet.
class StatusStartKarte extends ConsumerWidget {
  const StatusStartKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ich = ref.watch(authProvider.select((a) => a.user?.id));
    if (!ref.watch(statusAnzeigenProvider) || ich == null) return const SizedBox.shrink();
    final stati = ref.watch(familienStatusProvider);
    // die Mitgliederliste (Namen, Bilder) wird nur gebraucht und geladen, wenn es überhaupt einen Status zu zeigen gibt
    final mitglieder = stati.isEmpty ? const <UserDto>[] : (ref.watch(mitgliederProvider).value ?? const <UserDto>[]);
    final jetzt = ref.watch(statusUhrProvider).value ?? ref.watch(statusJetztProvider)();
    final nachId = {for (final u in mitglieder) u.id: u};
    // eigener Status zuerst, dann die anderen nach Name; Stati von Personen, die es nicht (mehr) gibt, zeigt die Kachel nie
    final eigener = stati.where((s) => s.userId == ich).firstOrNull;
    final andere = [
      for (final s in stati)
        if (s.userId != ich && nachId.containsKey(s.userId)) s,
    ]..sort((a, b) => nachId[a.userId]!.displayName.toLowerCase().compareTo(nachId[b.userId]!.displayName.toLowerCase()));
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MonoLabel('Status'),
          const SizedBox(height: 12),
          if (eigener == null && andere.isEmpty)
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('Gerade hat niemand einen Status gesetzt.', style: TextStyle(fontSize: 14, color: kTextMuted))),
          if (eigener != null) _StatusZeile(user: nachId[ich], name: 'Du', status: eigener, jetzt: jetzt),
          for (final s in andere) _StatusZeile(user: nachId[s.userId], name: nachId[s.userId]!.displayName, status: s, jetzt: jetzt),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              onPressed: () => unawaited(statusBlattOeffnen(context)),
              icon: Icon(eigener == null ? Icons.add_circle_outline : Icons.edit_outlined, size: 18),
              label: Text(eigener == null ? 'Mein Status setzen' : 'Meinen Status ändern'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusZeile extends StatelessWidget {
  final UserDto? user;
  final String name;
  final StatusEintrag status;
  final DateTime jetzt;
  const _StatusZeile({required this.user, required this.name, required this.status, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final bis = statusBisText(status.bis, jetzt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MergeSemantics(
        child: Semantics(
          label: '$name: ${status.text}, $bis',
          child: ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BenutzerAvatar(user: user, ersatzName: name, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: _kleinStil),
                      Text(status.text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: kTextStrong)),
                      Text(bis, style: _kleinStil),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Blatt zum Setzen, Ändern und Löschen des eigenen Status (mit `useRootNavigator: false`).
Future<void> statusBlattOeffnen(BuildContext context) => showModalBottomSheet<void>(
  useRootNavigator: false,
  context: context,
  isScrollControlled: true,
  builder: (_) => const _StatusBlatt(),
);

// Auswahl "Wie lange?": ein Ablauf oder "wie bisher" (nur beim Ändern eines Status mit Ende)
enum _Wahl { einStunde, dreiStunden, heuteAbend, morgenFrueh, ohneEnde, wieBisher }

class _StatusBlatt extends ConsumerStatefulWidget {
  const _StatusBlatt();

  @override
  ConsumerState<_StatusBlatt> createState() => _StatusBlattState();
}

class _StatusBlattState extends ConsumerState<_StatusBlatt> {
  final _text = TextEditingController();
  _Wahl? _wahl;
  String? _fehler;
  var _beschaeftigt = false;
  late final StatusEintrag? _eigener;
  late final DateTime _jetzt;

  @override
  void initState() {
    super.initState();
    _jetzt = ref.read(statusJetztProvider)();
    _eigener = ref.read(eigenerStatusProvider);
    final e = _eigener;
    if (e != null) {
      _text.text = e.text;
      _wahl = e.bis == null ? _Wahl.ohneEnde : _Wahl.wieBisher;
    } else {
      _wahl = _Wahl.dreiStunden;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  StatusAblauf _ablauf(_Wahl w) => switch (w) {
    _Wahl.einStunde => StatusAblauf.einStunde,
    _Wahl.dreiStunden => StatusAblauf.dreiStunden,
    _Wahl.heuteAbend => StatusAblauf.heuteAbend,
    _Wahl.morgenFrueh => StatusAblauf.morgenFrueh,
    _ => StatusAblauf.ohneEnde,
  };

  Future<void> _speichern() async {
    final text = statusTextPruefen(_text.text);
    if (text == null) {
      setState(() => _fehler = 'Bitte schreib einen kurzen Status mit höchstens $kStatusMaxZeichen Zeichen, ohne Zeilenumbruch.');
      return;
    }
    final w = _wahl ?? _Wahl.ohneEnde;
    final DateTime? bis = w == _Wahl.wieBisher ? _eigener?.bis : _ablauf(w).ende(_jetzt);
    // ein Ende, das schon vorbei ist ("wie bisher" lange nach dem Öffnen), gilt nicht mehr
    if (bis != null && !bis.isAfter(_jetzt)) {
      setState(() => _fehler = 'Das Ende liegt schon in der Vergangenheit. Bitte wähle ein neues.');
      return;
    }
    setState(() {
      _beschaeftigt = true;
      _fehler = null;
    });
    final ok = await ref.read(statusRepositoryProvider).setzen(text, bis);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _beschaeftigt = false;
        _fehler = 'Der Status konnte nicht gesetzt werden.';
      });
    }
  }

  Future<void> _loeschen() async {
    setState(() => _beschaeftigt = true);
    await ref.read(statusRepositoryProvider).loeschen();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final optionen = statusAblaufOptionen(_jetzt);
    final bisher = _eigener?.bis;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const MonoLabel('Status'),
            const SizedBox(height: 4),
            const Text('Was machst du gerade?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong)),
            const SizedBox(height: 14),
            Semantics(
              textField: true,
              label: 'Dein Status',
              child: TextField(
                controller: _text,
                maxLength: kStatusMaxZeichen,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: 'Dein Status', hintText: 'Zum Beispiel: Beim Sport'),
                onChanged: (_) => setState(() => _fehler = null),
                onSubmitted: (_) => unawaited(_speichern()),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in kStatusVorschlaege)
                  AuswahlKnopf(
                    text: v,
                    gewaehlt: _text.text.trim() == v,
                    onTap: () => setState(() {
                      _text.text = v;
                      _fehler = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const MonoLabel('Wie lange?'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (bisher != null && bisher.isAfter(_jetzt))
                  AuswahlKnopf(text: 'Wie bisher (${statusBisText(bisher, _jetzt)})', gewaehlt: _wahl == _Wahl.wieBisher, onTap: () => setState(() => _wahl = _Wahl.wieBisher)),
                for (final a in optionen)
                  AuswahlKnopf(text: a.label, gewaehlt: _wahl?.name == a.name, onTap: () => setState(() => _wahl = _Wahl.values.byName(a.name))),
              ],
            ),
            if (_fehler != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(liveRegion: true, child: Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 14))),
              ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: _beschaeftigt ? null : () => unawaited(_speichern()),
              child: const Text('Status setzen'),
            ),
            if (_eigener != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: _beschaeftigt ? null : () => unawaited(_loeschen()),
                  child: const Text('Status löschen'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
