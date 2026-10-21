// Oberfläche der Chat-Erweiterungen: Reaktionen (Auswahl, Chips unter der Nachricht), Umfrage (Karte, Editor) und die Leiste der angehefteten Nachrichten.
// Emojis sind System-Emojis (keine Pakete, keine Schriften aus dem Netz). Alle Tipp-Flächen sind mindestens 44 px hoch, die Beschriftungen für Screenreader deutsch.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/chat/chat_zusatz_inhalt.dart';
import '../../ui/widgets.dart';

/// Reihe der Schnellreaktionen im Nachrichtenmenü. [meine] ist das Emoji, mit dem die Person schon reagiert hat (erneutes Antippen nimmt es zurück).
class ReaktionsAuswahl extends StatelessWidget {
  final String? meine;
  final ValueChanged<String> onWaehlen;
  const ReaktionsAuswahl({super.key, required this.meine, required this.onWaehlen});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final e in kReaktionEmojis)
          Semantics(
            button: true,
            selected: meine == e,
            label: meine == e ? 'Reaktion $e zurücknehmen' : 'Mit $e reagieren',
            excludeSemantics: true,
            onTap: () => onWaehlen(e),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onWaehlen(e),
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: meine == e ? kAccentSoft : null, border: Border.all(color: meine == e ? kAccent : kSurface)),
                // fester Schriftgrad: die Auswahl soll bei großer Textskalierung nicht aus dem Rahmen laufen
                child: Text(e, textScaler: TextScaler.noScaling, style: const TextStyle(fontSize: 24)),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Reaktionen unter einer Nachricht: je Emoji ein Chip mit Zähler; ein Tipp setzt oder nimmt die eigene Reaktion zurück. Der Tooltip nennt, wer es gewählt hat.
class ReaktionsChips extends StatelessWidget {
  final List<ReaktionGruppe> gruppen;
  final String Function(String userId) name;
  final ValueChanged<String> onTap;
  const ReaktionsChips({super.key, required this.gruppen, required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: [
      for (final g in gruppen)
        Builder(
          builder: (context) {
            final namen = g.personen.map(name).join(', ');
            return Semantics(
              button: true,
              label: '${g.emoji} ${g.anzahl}, von $namen. ${g.ich ? 'Tippen nimmt deine Reaktion zurück' : 'Tippen, um auch so zu reagieren'}',
              excludeSemantics: true,
              onTap: () => onTap(g.emoji),
              child: Tooltip(
                message: namen,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onTap(g.emoji),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                    child: Center(
                      widthFactor: 1,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: g.ich ? kAccentSoft : kSurface,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: g.ich ? kAccent : kBorder),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(g.emoji, textScaler: TextScaler.noScaling, style: const TextStyle(fontSize: 15)),
                            const SizedBox(width: 4),
                            Text('${g.anzahl}', style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: g.ich ? kAccent : kTextMuted)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ],
  );
}

String _endeText(DateTime ende) => DateFormat('E, d. MMM, HH:mm', 'de_DE').format(ende);

/// Umfrage in der Nachrichtenblase: Frage, Antworten mit Balken, Zähler und den Namen derer, die gewählt haben; ein Tipp wählt oder nimmt eine Antwort zurück.
class UmfrageKarte extends StatelessWidget {
  final Umfrage umfrage;
  final UmfrageErgebnis ergebnis;
  final bool beendet;

  /// Noch nicht vom Server bestätigt: abstimmen geht erst danach.
  final bool wartet;
  final String Function(String userId) name;
  final ValueChanged<int> onWaehle;
  const UmfrageKarte({super.key, required this.umfrage, required this.ergebnis, required this.beendet, required this.wartet, required this.name, required this.onWaehle});

  @override
  Widget build(BuildContext context) {
    final summe = ergebnis.abstimmende;
    final aktiv = !beendet && !wartet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.poll_outlined, size: 16, color: kAccent),
            const SizedBox(width: 6),
            const Expanded(child: MonoLabel('umfrage', color: kAccent)),
          ],
        ),
        const SizedBox(height: 4),
        Text(umfrage.frage, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kTextStrong, height: 1.3)),
        const SizedBox(height: 6),
        for (var i = 0; i < umfrage.optionen.length; i++)
          _Option(
            text: umfrage.optionen[i],
            stimmen: ergebnis.stimmen(i),
            anteil: summe == 0 ? 0 : ergebnis.stimmen(i) / summe,
            gewaehlt: ergebnis.meine.contains(i),
            mehrfach: umfrage.mehrfach,
            aktiv: aktiv,
            namen: ergebnis.waehler[i].map(name).toList(),
            onTap: () => onWaehle(i),
          ),
        const SizedBox(height: 2),
        Text(
          [
            summe == 0 ? 'noch keine Stimmen' : (summe == 1 ? '1 Person hat abgestimmt' : '$summe Personen haben abgestimmt'),
            if (umfrage.mehrfach) 'mehrere Antworten möglich',
            if (beendet) 'beendet' else if (umfrage.ende != null) 'endet ${_endeText(umfrage.ende!)}',
          ].join(' · '),
          style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted, height: 1.4),
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  final String text;
  final int stimmen;
  final double anteil;
  final bool gewaehlt;
  final bool mehrfach;
  final bool aktiv;
  final List<String> namen;
  final VoidCallback onTap;
  const _Option({required this.text, required this.stimmen, required this.anteil, required this.gewaehlt, required this.mehrfach, required this.aktiv, required this.namen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final icon = mehrfach ? (gewaehlt ? Icons.check_box : Icons.check_box_outline_blank) : (gewaehlt ? Icons.radio_button_checked : Icons.radio_button_unchecked);
    final wer = namen.isEmpty ? '' : namen.join(', ');
    return Semantics(
      button: aktiv,
      selected: gewaehlt,
      label: '$text, $stimmen ${stimmen == 1 ? 'Stimme' : 'Stimmen'}${wer.isEmpty ? '' : ', von $wer'}${gewaehlt ? ', von dir gewählt' : ''}',
      hint: aktiv ? (gewaehlt ? 'Tippen nimmt deine Stimme zurück' : 'Tippen zum Abstimmen') : null,
      excludeSemantics: true,
      onTap: aktiv ? onTap : null,
      child: Tooltip(
        message: wer.isEmpty ? 'noch niemand' : wer,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: aktiv ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 20, color: gewaehlt ? kAccent : (aktiv ? kTextMuted : kTextFaint)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(text, style: const TextStyle(color: kText, height: 1.3))),
                      const SizedBox(width: 8),
                      Text('$stimmen', style: TextStyle(fontFamily: kFontMono, fontSize: 13, color: gewaehlt ? kAccent : kTextMuted)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: anteil, minHeight: 5, backgroundColor: kBorder, valueColor: AlwaysStoppedAnimation(gewaehlt ? kAccent : kNeural)),
                  ),
                  if (wer.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(wer, style: const TextStyle(fontSize: 12, color: kTextMuted, height: 1.3)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Eine angeheftete Nachricht in der Leiste und in der Liste.
class PinEintrag {
  final String nachrichtId;
  final String text;
  final String autor;

  /// Darf die angemeldete Person die Anheftung lösen?
  final bool darfLoesen;
  const PinEintrag({required this.nachrichtId, required this.text, required this.autor, required this.darfLoesen});
}

/// Leiste oben im Chat: die zuletzt angeheftete Nachricht; ein Tipp öffnet die Liste aller Anheftungen.
class PinLeiste extends StatelessWidget {
  final List<PinEintrag> pins;
  final VoidCallback onTap;
  const PinLeiste({super.key, required this.pins, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final erster = pins.first;
    return Semantics(
      button: true,
      label: pins.length == 1 ? 'Angeheftet: ${erster.text}' : '${pins.length} angeheftete Nachrichten, zuletzt: ${erster.text}',
      hint: 'Liste der angehefteten Nachrichten öffnen',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: const BoxDecoration(color: kSurface, border: Border(bottom: BorderSide(color: kBorderSoft))),
          child: Row(
            children: [
              const Icon(Icons.push_pin_outlined, size: 18, color: kAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MonoLabel(pins.length == 1 ? 'angeheftet' : 'angeheftet · ${pins.length}', color: kAccent),
                    Text(erster.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kText)),
                  ],
                ),
              ),
              const Icon(Icons.expand_more, size: 20, color: kTextMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wahl in der Pin-Liste: zur Nachricht springen oder die Anheftung lösen.
class PinWahl {
  final String nachrichtId;
  final bool loesen;
  const PinWahl(this.nachrichtId, {required this.loesen});
}

/// Liste der angehefteten Nachrichten; ein Tipp auf einen Eintrag springt zur Nachricht, das Kreuz löst die Anheftung (null: nichts gewählt).
Future<PinWahl?> pinListe(BuildContext context, List<PinEintrag> pins) => showModalBottomSheet<PinWahl>(
  context: context,
  backgroundColor: kSurface,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: MonoLabel('angeheftete nachrichten')),
          for (final p in pins)
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.push_pin_outlined, color: kAccent),
              title: Text(p.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kText)),
              subtitle: Text(p.autor, style: const TextStyle(color: kTextMuted)),
              trailing: p.darfLoesen
                  ? IconButton(tooltip: 'Anheftung lösen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.close), onPressed: () => Navigator.of(c).pop(PinWahl(p.nachrichtId, loesen: true)))
                  : null,
              onTap: () => Navigator.of(c).pop(PinWahl(p.nachrichtId, loesen: false)),
            ),
        ],
      ),
    ),
  ),
);

/// Eingabe für eine neue Umfrage.
class UmfrageEntwurf {
  final String frage;
  final List<String> optionen;
  final bool mehrfach;
  final DateTime? ende;
  const UmfrageEntwurf({required this.frage, required this.optionen, required this.mehrfach, this.ende});
}

/// Fragt Frage, 2 bis 6 Antworten, Mehrfachauswahl und ein optionales Ende ab; null bei Abbruch.
Future<UmfrageEntwurf?> umfrageErstellen(BuildContext context) => showModalBottomSheet<UmfrageEntwurf>(
  context: context,
  backgroundColor: kSurface,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const _UmfrageEditor(),
);

class _UmfrageEditor extends StatefulWidget {
  const _UmfrageEditor();

  @override
  State<_UmfrageEditor> createState() => _UmfrageEditorState();
}

class _UmfrageEditorState extends State<_UmfrageEditor> {
  final _frage = TextEditingController();
  final _optionen = [TextEditingController(), TextEditingController()];
  bool _mehrfach = false;
  DateTime? _ende;
  String? _fehler;

  @override
  void dispose() {
    _frage.dispose();
    for (final o in _optionen) {
      o.dispose();
    }
    super.dispose();
  }

  Future<void> _endeWaehlen() async {
    final jetzt = DateTime.now();
    final tag = await showDatePicker(context: context, initialDate: _ende ?? jetzt.add(const Duration(days: 1)), firstDate: jetzt, lastDate: jetzt.add(const Duration(days: 365)));
    if (tag == null || !mounted) return;
    final zeit = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_ende ?? jetzt.add(const Duration(hours: 1))));
    if (zeit == null || !mounted) return;
    final ende = DateTime(tag.year, tag.month, tag.day, zeit.hour, zeit.minute);
    setState(() {
      _ende = ende;
      _fehler = ende.isAfter(DateTime.now()) ? null : 'Das Ende muss in der Zukunft liegen.';
    });
  }

  void _senden() {
    final texte = [for (final o in _optionen) o.text];
    var fehler = umfrageFehler(_frage.text, texte);
    if (fehler == null && _ende != null && !_ende!.isAfter(DateTime.now())) fehler = 'Das Ende muss in der Zukunft liegen.';
    if (fehler != null) {
      setState(() => _fehler = fehler);
      return;
    }
    Navigator.of(context).pop(UmfrageEntwurf(frage: _frage.text, optionen: texte, mehrfach: _mehrfach, ende: _ende));
  }

  @override
  Widget build(BuildContext context) {
    final tastatur = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.92),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + tastatur),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(header: true, child: const Text('Umfrage erstellen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kTextStrong))),
              const SizedBox(height: 12),
              TextField(
                controller: _frage,
                maxLength: kMaxUmfrageFrage,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r]'))],
                decoration: const InputDecoration(labelText: 'Frage', hintText: 'z. B. Was essen wir?'),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _optionen.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _optionen[i],
                          maxLength: kMaxUmfrageOption,
                          textCapitalization: TextCapitalization.sentences,
                          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r]'))],
                          decoration: InputDecoration(labelText: 'Antwort ${i + 1}', counterText: ''),
                        ),
                      ),
                      if (_optionen.length > kMinUmfrageOptionen)
                        IconButton(
                          tooltip: 'Antwort ${i + 1} entfernen',
                          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => setState(() => _optionen.removeAt(i).dispose()),
                        ),
                    ],
                  ),
                ),
              if (_optionen.length < kMaxUmfrageOptionen)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => setState(() => _optionen.add(TextEditingController())),
                    icon: const Icon(Icons.add),
                    label: const Text('Antwort hinzufügen'),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mehrere Antworten erlauben'),
                value: _mehrfach,
                onChanged: (v) => setState(() => _mehrfach = v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                minTileHeight: 56,
                leading: const Icon(Icons.schedule),
                title: const Text('Ende'),
                subtitle: Text(_ende == null ? 'ohne Ende' : _endeText(_ende!), style: const TextStyle(color: kTextMuted)),
                trailing: _ende == null ? null : IconButton(tooltip: 'Ende entfernen', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), icon: const Icon(Icons.close), onPressed: () => setState(() => _ende = null)),
                onTap: _endeWaehlen,
              ),
              if (_fehler != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Semantics(liveRegion: true, child: Text(_fehler!, style: const TextStyle(color: kDanger))),
                ),
              const SizedBox(height: 8),
              FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: _senden, child: const Text('Umfrage senden')),
            ],
          ),
        ),
      ),
    );
  }
}
