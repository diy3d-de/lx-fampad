// Globale Suche (Startseite): Termine, Aufgaben, Listen und Listeneinträge aus der lokalen Datenbank, ohne Server und auch offline. Ergebnisse nach
// Bereich gruppiert, Tippen springt in den Bereich bzw. öffnet die Aufgabe. Die Seite ist eine Unterseite (mobil Vollseite, im Desktop-Layout im
// Inhalts-Navigator der Shell). Die Eingabe wird nirgends gemerkt oder gesendet. Chat hat eine eigene Suche, Standort und Schlüssel gehören nicht dazu.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/calendar/termin_repository.dart';
import '../../data/lists/list_repository.dart';
import '../../data/suche/globale_suche.dart';
import '../../data/tasks/aufgabe_repository.dart';
import '../../ui/widgets.dart';
import '../calendar/calendar_state.dart';
import '../shell/shell_tab.dart';
import '../tasks/aufgabe_editor.dart';
import 'treffer_text.dart';

class SuchScreen extends ConsumerStatefulWidget {
  const SuchScreen({super.key});

  /// Öffnet die Suche; wie das Konto nur über diese Route (unbenannt).
  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const SuchScreen());

  @override
  ConsumerState<SuchScreen> createState() => _SuchScreenState();
}

class _SuchScreenState extends ConsumerState<SuchScreen> {
  final _feld = TextEditingController();
  final _fokus = FocusNode();
  Timer? _entprellen;
  String _eingabe = '';

  @override
  void dispose() {
    _entprellen?.cancel();
    _feld.dispose();
    _fokus.dispose();
    super.dispose();
  }

  void _geaendert(String t) {
    _entprellen?.cancel();
    _entprellen = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _eingabe = t);
    });
    setState(() {}); // Löschen-Knopf
  }

  void _leeren() {
    _entprellen?.cancel();
    _feld.clear();
    setState(() => _eingabe = '');
    _fokus.requestFocus();
  }

  /// Seite schließen und in den Bereich wechseln (Unterseiten der Desktop-Shell schließt der Bereichswechsel ohnehin; mobil bleibt die Seite sonst offen).
  void _inBereich(int tab, {void Function()? vorher}) {
    final waehlen = ref.read(shellTabProvider.notifier);
    final navigator = Navigator.of(context);
    vorher?.call();
    navigator.pop();
    waehlen.waehlen(tab);
  }

  void _oeffnen(SuchTreffer t) {
    switch (t.bereich) {
      case SuchBereich.termine:
        final kalender = ref.read(kalenderAuswahlProvider.notifier);
        final tag = t.datum;
        _inBereich(kKalenderTab, vorher: tag == null ? null : () => kalender.tag(tag));
      case SuchBereich.aufgaben:
        final a = ref.read(aufgabenProvider).value?.where((x) => x.id == t.id).firstOrNull;
        if (a != null) unawaited(aufgabeEditorOeffnen(context, aufgabe: a));
      case SuchBereich.listen:
      case SuchBereich.eintraege:
        final id = t.listId ?? t.id;
        final gewaehlt = ref.read(gewaehlteListeProvider.notifier);
        _inBereich(kListenTab, vorher: () => gewaehlt.waehlen(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final termine = ref.watch(termineProvider).value ?? const <Termin>[];
    final aufgaben = ref.watch(aufgabenProvider).value ?? const <Aufgabe>[];
    final listen = ref.watch(listenProvider).value ?? const <Liste>[];
    final eintraege = ref.watch(alleEintraegeProvider).value ?? const <Listeneintrag>[];
    final ergebnis = sucheGlobal(eingabe: _eingabe, termine: termine, aufgaben: aufgaben, listen: listen, eintraege: eintraege);
    final gesucht = _eingabe.trim().length >= kSucheMinZeichen;
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(tooltip: 'Zurück', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const MonoLabel('Suche'),
                          const SizedBox(height: 4),
                          Semantics(
                            header: true,
                            child: const Text('Suchen', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong)),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _feld,
                            focusNode: _fokus,
                            autofocus: true,
                            textInputAction: TextInputAction.search,
                            inputFormatters: [LengthLimitingTextInputFormatter(100)],
                            onChanged: _geaendert,
                            onSubmitted: (t) {
                              _entprellen?.cancel();
                              setState(() => _eingabe = t);
                            },
                            decoration: InputDecoration(
                              hintText: 'Termine, Aufgaben, Listen …',
                              prefixIcon: const Icon(Icons.search, size: 20),
                              suffixIcon: _feld.text.isEmpty
                                  ? null
                                  : IconButton(tooltip: 'Eingabe löschen', constraints: const BoxConstraints(minWidth: 44, minHeight: 44), icon: const Icon(Icons.close, size: 20), onPressed: _leeren),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: !gesucht
                          ? const EmptyState(icon: Icons.search, title: 'Wonach suchst du?', hint: 'Gesucht wird in Terminen, Aufgaben, Listen und ihren Einträgen. Alles bleibt auf diesem Gerät.')
                          : ergebnis.istLeer
                          ? const EmptyState(icon: Icons.search_off, title: 'Nichts gefunden', hint: 'Probiere ein anderes Wort oder weniger Wörter.')
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                              children: [for (final g in ergebnis.gruppen) _Gruppe(gruppe: g, onTap: _oeffnen)],
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _bereichName(SuchBereich b) => switch (b) {
  SuchBereich.termine => 'Termine',
  SuchBereich.aufgaben => 'Aufgaben',
  SuchBereich.listen => 'Listen',
  SuchBereich.eintraege => 'Listeneinträge',
};

class _Gruppe extends StatelessWidget {
  final SuchGruppe gruppe;
  final void Function(SuchTreffer) onTap;
  const _Gruppe({required this.gruppe, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: MonoLabel('${_bereichName(gruppe.bereich)} · ${gruppe.gesamt}')),
        const SizedBox(height: 6),
        for (final t in gruppe.treffer) SuchZeile(treffer: t, onTap: () => onTap(t)),
        if (gruppe.weitere > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text('und ${gruppe.weitere} weitere – grenze die Suche mit einem zusätzlichen Wort ein', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          ),
      ],
    ),
  );
}

/// Datum eines Treffers für die Zeile darunter (Wanduhr der Familienzone, Zeitangabe nur bei Terminen mit Uhrzeit).
String _datumText(SuchTreffer t) {
  final d = t.datum;
  if (d == null) return '';
  final tag = DateFormat('E, d. MMM y', 'de_DE').format(d).toLowerCase();
  final mitZeit = t.bereich == SuchBereich.termine && (d.hour != 0 || d.minute != 0);
  return mitZeit ? '$tag, ${DateFormat('HH:mm', 'de_DE').format(d)}' : tag;
}

class SuchZeile extends StatelessWidget {
  final SuchTreffer treffer;
  final VoidCallback onTap;
  const SuchZeile({super.key, required this.treffer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = treffer;
    final datum = _datumText(t);
    final unter = [if (datum.isNotEmpty) datum, if (t.zusatz.isNotEmpty) t.zusatz, if (t.erledigt) 'erledigt'].join(' · ');
    final bereich = switch (t.bereich) {
      SuchBereich.termine => 'Termin',
      SuchBereich.aufgaben => 'Aufgabe',
      SuchBereich.listen => 'Liste',
      SuchBereich.eintraege => 'Listeneintrag',
    };
    return Semantics(
      button: true,
      label: '$bereich: ${t.titel}${unter.isEmpty ? '' : ', $unter'}${t.auszug == null ? '' : ', ${t.auszug!.text}'}',
      excludeSemantics: true,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TrefferText(t.titel, t.titelBereiche, stil: TextStyle(fontSize: 15, color: t.erledigt ? kTextMuted : kTextStrong, decoration: t.erledigt ? TextDecoration.lineThrough : null)),
                if (unter.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(unter, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                ],
                if (t.auszug != null) ...[
                  const SizedBox(height: 4),
                  TrefferText(t.auszug!.text, t.auszug!.bereiche, stil: const TextStyle(fontSize: 13, color: kText), maxLines: 2),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
