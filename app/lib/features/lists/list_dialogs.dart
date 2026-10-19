// Dialoge und Blätter der Listen: neue Liste, Liste umbenennen/freigeben, Eintrag bearbeiten, Person zuweisen.
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/lists/list_repository.dart';
import '../../data/lists/list_rights.dart';
import '../../ui/widgets.dart';

/// Auswahl-Knopf (Art, Freigabe): mindestens 44 px hoch, wählbar per Tipp oder Tastatur (Tab, Leertaste/Enter); der Tastaturfokus ist sichtbar.
class AuswahlKnopf extends StatefulWidget {
  final String text;
  final bool gewaehlt;
  final VoidCallback onTap;
  const AuswahlKnopf({super.key, required this.text, required this.gewaehlt, required this.onTap});

  @override
  State<AuswahlKnopf> createState() => _AuswahlKnopfState();
}

class _AuswahlKnopfState extends State<AuswahlKnopf> {
  var _fokus = false;

  @override
  Widget build(BuildContext context) {
    final gewaehlt = widget.gewaehlt;
    return Semantics(
      button: true,
      selected: gewaehlt,
      label: widget.text,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onTap,
        onFocusChange: (f) => setState(() => _fokus = f),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: gewaehlt ? kAccentSoft : null,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _fokus ? kAccent : (gewaehlt ? kAccent.withValues(alpha: 0.4) : kBorder), width: _fokus ? 2 : 1),
          ),
          child: Text(widget.text, style: TextStyle(fontSize: 14, fontWeight: gewaehlt ? FontWeight.w600 : FontWeight.w400, color: gewaehlt ? kAccent : kTextMuted)),
        ),
      ),
    );
  }
}

class NeueListeAngaben {
  final String name;
  final ListenArt art;
  final ListenSicht sicht;
  const NeueListeAngaben(this.name, this.art, this.sicht);
}

/// Dialog "Neue Liste": Name, Art, bei Eltern auch die Freigabe.
Future<NeueListeAngaben?> neueListeDialog(BuildContext context, ListenRechte rechte) => showDialog<NeueListeAngaben>(
  context: context,
  builder: (_) => _NeueListe(rechte),
);

class _NeueListe extends StatefulWidget {
  final ListenRechte rechte;
  const _NeueListe(this.rechte);

  @override
  State<_NeueListe> createState() => _NeueListeState();
}

class _NeueListeState extends State<_NeueListe> {
  final _name = TextEditingController();
  var _art = ListenArt.shopping;
  var _sicht = ListenSicht.family;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _anlegen() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(NeueListeAngaben(name, _art, _sicht));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Neue Liste'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 100,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Name der Liste', counterText: ''),
            onSubmitted: (_) => _anlegen(),
          ),
          const SizedBox(height: 16),
          const MonoLabel('// art'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final a in ListenArt.values) AuswahlKnopf(text: a.label, gewaehlt: a == _art, onTap: () => setState(() => _art = a))],
          ),
          if (widget.rechte.freigaben.length > 1) ...[
            const SizedBox(height: 16),
            const MonoLabel('// sichtbar für'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final s in widget.rechte.freigaben) AuswahlKnopf(text: s.label, gewaehlt: s == _sicht, onTap: () => setState(() => _sicht = s))],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
      FilledButton(onPressed: _anlegen, child: const Text('Anlegen')),
    ],
  );
}

/// Einfacher Text-Dialog (Liste umbenennen). Liefert den neuen, nicht leeren Text.
Future<String?> textDialog(BuildContext context, {required String titel, required String label, String start = '', int maxLaenge = 100, String knopf = 'Speichern'}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(titel: titel, label: label, start: start, maxLaenge: maxLaenge, knopf: knopf),
    );

class _TextDialog extends StatefulWidget {
  final String titel;
  final String label;
  final String start;
  final int maxLaenge;
  final String knopf;
  const _TextDialog({required this.titel, required this.label, required this.start, required this.maxLaenge, required this.knopf});

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _c = TextEditingController(text: widget.start);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _fertig() {
    final t = _c.text.trim();
    if (t.isNotEmpty) Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.titel),
    content: TextField(
      controller: _c,
      autofocus: true,
      maxLength: widget.maxLaenge,
      decoration: InputDecoration(labelText: widget.label, counterText: ''),
      onSubmitted: (_) => _fertig(),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
      FilledButton(onPressed: _fertig, child: Text(widget.knopf)),
    ],
  );
}

/// Auswahl der Freigabe einer Liste ("Sichtbar für").
Future<ListenSicht?> sichtDialog(BuildContext context, ListenSicht aktuell) => showDialog<ListenSicht>(
  context: context,
  builder: (c) => AlertDialog(
    title: const Text('Sichtbar für'),
    content: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final s in ListenSicht.values) AuswahlKnopf(text: s.label, gewaehlt: s == aktuell, onTap: () => Navigator.of(c).pop(s))],
    ),
    actions: [TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('Abbrechen'))],
  ),
);

Future<bool> bestaetigen(BuildContext context, {required String titel, required String text, required String knopf}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(titel),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Abbrechen')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kDanger, foregroundColor: kOnAccent),
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(knopf),
          ),
        ],
      ),
    ) ??
    false;

/// Ergebnis des Eintrag-Blatts.
sealed class EintragAktion {}

class EintragSpeichern extends EintragAktion {
  final String text;
  EintragSpeichern(this.text);
}

class EintragLoeschen extends EintragAktion {}

/// Blatt "Eintrag bearbeiten": Text ändern oder den Eintrag löschen.
Future<EintragAktion?> eintragBlatt(BuildContext context, {required String text}) => showModalBottomSheet<EintragAktion>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _EintragBlatt(text: text),
);

class _EintragBlatt extends StatefulWidget {
  final String text;
  const _EintragBlatt({required this.text});

  @override
  State<_EintragBlatt> createState() => _EintragBlattState();
}

class _EintragBlattState extends State<_EintragBlatt> {
  late final _c = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _speichern() {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop(EintragSpeichern(t));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _c,
            autofocus: true,
            maxLength: 500,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Eintrag', counterText: ''),
            onSubmitted: (_) => _speichern(),
          ),
          const SizedBox(height: 12),
          // Wrap statt Row: bei großer Schrift rutscht ein Knopf in die nächste Zeile, statt zu überlaufen
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: kDanger),
                onPressed: () => Navigator.of(context).pop(EintragLoeschen()),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Löschen'),
              ),
              FilledButton(onPressed: _speichern, child: const Text('Speichern')),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Rückgabe des Zuweisen-Blatts: null = abgebrochen, [keinePerson] = Zuständigkeit entfernen.
const keinePerson = '';

Future<String?> zuweisenBlatt(BuildContext context, {required List<UserDto> personen, required String? aktuell}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: MonoLabel('// zuständig')),
          ListTile(
            minTileHeight: 52,
            leading: const Icon(Icons.person_off_outlined, color: kTextMuted),
            title: const Text('Niemand'),
            selected: aktuell == null,
            onTap: () => Navigator.of(c).pop(keinePerson),
          ),
          for (final p in personen)
            ListTile(
              minTileHeight: 52,
              leading: PersonAvatar(name: p.displayName, colorIndex: p.colorIndex, size: 32),
              title: Text(p.displayName),
              selected: p.id == aktuell,
              onTap: () => Navigator.of(c).pop(p.id),
            ),
        ],
      ),
    ),
  ),
);
